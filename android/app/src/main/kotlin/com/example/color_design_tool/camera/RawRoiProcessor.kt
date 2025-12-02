package com.example.color_design_tool.camera

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Color
import android.graphics.PointF
import android.graphics.Rect
import android.graphics.RectF
import android.hardware.camera2.CameraCharacteristics
import android.util.Base64
import android.util.Log
import androidx.exifinterface.media.ExifInterface
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import java.util.Locale
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.io.walkTopDown
import kotlin.text.Charsets
import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

class RawRoiProcessor(
    private val context: Context,
    private val args: Map<*, *>,
) {
    companion object {
        private val D50_WHITE = doubleArrayOf(0.9642, 1.0, 0.8251)
        private val D65_WHITE = doubleArrayOf(0.95047, 1.0, 1.08883)
        private val BRADFORD = doubleArrayOf(
            0.8951, 0.2664, -0.1614,
            -0.7502, 1.7135, 0.0367,
            0.0389, -0.0685, 1.0296,
        )
        private val BRADFORD_INV = doubleArrayOf(
            0.9869929, -0.1470543, 0.1599627,
            0.4323053, 0.5183603, 0.0492912,
            -0.0085287, 0.0400428, 0.9684867,
        )
        // Default Camera RGB -> XYZ matrix used when no per-capture
        // color correction transform is available.
        private val RAWPY_CAM_TO_XYZ = doubleArrayOf(
            0.45454840, 0.10688300, 0.07675672,
            0.07543547, 0.41522814, 0.08160625,
            0.06060502, 0.15949116, 0.73257329,
        )
        private val RAWPY_XYZ_TO_CAM = doubleArrayOf(
            2.31151874, -0.52441404, -0.18377565,
            -0.39944759, 2.60659054, -0.24851274,
            -0.10426435, -0.52410596, 1.43435930,
        )
        private const val RAW_DUMP_CHUNK_BYTES = 8192
        // ExifInterface 1.3.x misses DNG tag constants; resolve with reflection + string fallback for compatibility.
        private fun resolveExifTag(fieldName: String, fallback: String): String {
            return runCatching {
                ExifInterface::class.java.getField(fieldName).get(null) as? String
            }.getOrNull() ?: fallback
        }

        private val DNG_TAG_COLOR_MATRIX1 = resolveExifTag("TAG_COLOR_MATRIX1", "ColorMatrix1")
        private val DNG_TAG_COLOR_MATRIX2 = resolveExifTag("TAG_COLOR_MATRIX2", "ColorMatrix2")
        private val DNG_TAG_FORWARD_MATRIX1 = resolveExifTag("TAG_FORWARD_MATRIX1", "ForwardMatrix1")
        private val DNG_TAG_FORWARD_MATRIX2 = resolveExifTag("TAG_FORWARD_MATRIX2", "ForwardMatrix2")
        private val DNG_TAG_AS_SHOT_NEUTRAL = resolveExifTag("TAG_AS_SHOT_NEUTRAL", "AsShotNeutral")
        private val DNG_TAG_CALIBRATION_ILLUMINANT1 =
            resolveExifTag("TAG_CALIBRATION_ILLUMINANT1", "CalibrationIlluminant1")
        private val DNG_TAG_CALIBRATION_ILLUMINANT2 =
            resolveExifTag("TAG_CALIBRATION_ILLUMINANT2", "CalibrationIlluminant2")
        private val CFA_NAME_TO_PATTERN = mapOf(
            "RGGB" to CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_RGGB,
            "GRBG" to CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_GRBG,
            "GBRG" to CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_GBRG,
            "BGGR" to CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_BGGR,
        )
        private val CFA_PHASE_SHIFT_SUPPORTED = setOf(
            CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_RGGB,
            CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_GRBG,
            CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_GBRG,
            CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_BGGR,
        )
    }

    enum class RoiProcessingMode {
        RAW, JPEG, BOTH;

        fun includesRaw(): Boolean = this == RAW || this == BOTH
        fun includesJpeg(): Boolean = this == JPEG || this == BOTH

        companion object {
            fun from(value: Any?): RoiProcessingMode {
                val normalized = value?.toString()?.lowercase(Locale.US)
                return when (normalized) {
                    "jpeg" -> JPEG
                    "both" -> BOTH
                    "raw" -> RAW
                    else -> BOTH
                }
            }
        }
    }

    private val debugOptions = DebugConfig.from(args["debugConfig"]).let { config ->
        if (config.dumpIntermediateImages) config else config.copy(dumpIntermediateImages = true)
    }

    private fun computeRawRectForLogging(
        normalizedRoi: RectF,
        metadata: Map<String, Any?>,
        jpegOrientationDeg: Int,
    ): Rect? {
        val rawWidth = metadata[MetadataKeys.RAW_WIDTH].toIntOrDefault(metadata[MetadataKeys.ACTIVE_ARRAY_WIDTH])
        val rawHeight = metadata[MetadataKeys.RAW_HEIGHT].toIntOrDefault(metadata[MetadataKeys.ACTIVE_ARRAY_HEIGHT])
        if (rawWidth <= 0 || rawHeight <= 0) return null
        // normalizedRoi is expressed in the same upright coordinate system as the
        // JPEG preview. To map it into RAW buffer coordinates we need to apply
        // the same rotation that we use when mapping the ROI into JPEG pixel
        // space (see computeJpegStats). Previously this used the inverse
        // rotation, which effectively rotated the ROI an extra 90° and caused
        // RAW and JPEG pipelines to sample different physical regions.
        val rotated = rotateRect(normalizedRoi, jpegOrientationDeg)
        val rect = mapRect(rotated, rawWidth, rawHeight)
        return if (rect.width() <= 1 || rect.height() <= 1) null else rect
    }

    private fun buildRawPipelineContext(
        rawPath: String,
        roi: Rect,
        metadata: Map<String, Any?>,
        asShotNeutral: DoubleArray?,
        transposeCcm: Boolean,
    ): RawPipelineConfig {
        val rowStride = metadata[MetadataKeys.ROW_STRIDE].toIntOrDefault(-1)
        val pixelStride = metadata[MetadataKeys.PIXEL_STRIDE].toIntOrDefault(-1)
        if (rowStride <= 0 || pixelStride <= 0) {
            throw IllegalArgumentException("Missing RAW stride metadata")
        }
        val whiteLevel = metadata[MetadataKeys.WHITE_LEVEL].toIntOrDefault(0).coerceAtLeast(1)
        val blackPattern = (metadata[MetadataKeys.BLACK_LEVEL_PATTERN] as? List<*>)
            ?.mapNotNull { (it as? Number)?.toInt() } ?: listOf(0, 0, 0, 0)
        val cfaPattern = metadata[MetadataKeys.CFA_PATTERN].toIntOrDefault(
            CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_RGGB,
        )
        val colorTransform = selectWorkingColorTransform(metadata, transposeCcm)
        val baseMatrix = colorTransform.matrix.copyOf()
        val camToXyzMatrix = if (colorTransform.requiresInverse) {
            invert3x3(baseMatrix) ?: baseMatrix
        } else {
            baseMatrix
        }
        val xyzToCamMatrix = colorTransform.inverseMatrix?.copyOf() ?: invert3x3(camToXyzMatrix)
        val colorMatrixOriginal = colorTransform.inverseMatrix?.copyOf() ?: baseMatrix
        val colorCorrectionGains = metadata.toDoubleArray(MetadataKeys.COLOR_CORRECTION_GAINS)
        val argSkip = (args["skipWhiteBalance"] as? Boolean) == true
        val skipWb = argSkip
        return RawPipelineConfig(
            rawPath = rawPath,
            roi = roi,
            rowStride = rowStride,
            pixelStride = pixelStride,
            cfaPattern = cfaPattern,
            blackLevels = blackPattern,
            whiteLevel = whiteLevel,
            asShotNeutral = asShotNeutral,
            colorCorrectionGains = colorCorrectionGains,
            camToXyzMatrix = camToXyzMatrix,
            xyzToCamMatrix = xyzToCamMatrix,
            colorMatrixSource = colorTransform.source,
            colorMatrixOriginal = colorMatrixOriginal,
            skipWhiteBalance = skipWb,
        )
    }

    private fun runRawPipeline(
        config: RawPipelineConfig,
        metadata: Map<String, Any?>,
    ): RawPipelineResult {
        val pipelineMetadata = buildPipelineMetadata(config, metadata)
        val rawBuffer = loadRawRoi(config)
        val context = PipelineContext(
            rawBuffer = rawBuffer,
            width = config.roi.width(),
            height = config.roi.height(),
            metadata = pipelineMetadata,
            debugConfig = debugOptions,
        )
        val executor = PipelineExecutor(
            listOf(
                DemosaicStage(),
                WhiteBalanceStage(),
                ColorCorrectionStage(),
                GammaStage(),
            ),
        )
        val finalBitmap = executor.execute(context)
        val cameraSample = context.cameraSample ?: ChannelAverages(0.0, 0.0, 0.0, 0.0)
        val balancedSample = context.balancedSample ?: cameraSample
        val xyzSample = context.xyzSample ?: doubleArrayOf(0.0, 0.0, 0.0)
        val debugPackagePath = if (debugOptions.shouldDumpArtifacts()) {
            dumpDebugPackage(
                config = config,
                pipelineMetadata = pipelineMetadata,
                rawBuffer = rawBuffer,
                debugArtifacts = context.debugArtifacts,
                captureMetadata = metadata,
            )
        } else {
            null
        }
        return RawPipelineResult(
            cameraRgb = cameraSample,
            balancedRgb = balancedSample,
            whiteBalanceGains = pipelineMetadata.whiteBalanceGains,
            xyz = xyzSample,
            camToXyzMatrix = pipelineMetadata.colorMatrix,
            xyzToCamMatrix = pipelineMetadata.xyzToCamMatrix,
            colorMatrixSource = pipelineMetadata.colorMatrixSource,
            colorMatrixOriginal = pipelineMetadata.colorMatrixOriginal.copyOf(),
            previewBitmap = finalBitmap,
            debugPackagePath = debugPackagePath,
            debugArtifacts = context.debugArtifacts.toMap(),
        )
    }

    private fun loadRawRoi(config: RawPipelineConfig): ShortArray {
        val width = config.roi.width()
        val height = config.roi.height()
        val buffer = ShortArray(width * height)
        FileInputStream(config.rawPath).use { input ->
            val mapped = input.channel.map(
                FileChannel.MapMode.READ_ONLY,
                0,
                input.channel.size(),
            ).order(ByteOrder.LITTLE_ENDIAN)
            for (y in 0 until height) {
                val rowBase = (config.roi.top + y) * config.rowStride
                for (x in 0 until width) {
                    val column = config.roi.left + x
                    val index = rowBase + column * config.pixelStride
                    val targetIndex = y * width + x
                    if (index >= 0 && index + 2 <= mapped.capacity()) {
                        buffer[targetIndex] = mapped.getShort(index)
                    } else {
                        buffer[targetIndex] = 0
                    }
                }
            }
        }
        return buffer
    }

    private fun buildPipelineMetadata(
        config: RawPipelineConfig,
        metadata: Map<String, Any?>,
    ): CameraMetadata {
        val whiteBalanceGains = if (config.skipWhiteBalance) {
            doubleArrayOf(1.0, 1.0, 1.0)
        } else {
            extractWhiteBalanceGains(
                metadata = metadata,
                asShotNeutral = config.asShotNeutral,
                colorCorrectionGains = config.colorCorrectionGains,
            )
        }
        val forcedCfaPattern = parseForceCfaPattern(args["forceCfaPattern"])
        val effectiveCfaPattern = computeEffectiveCfaPattern(config.cfaPattern, config.roi, forcedCfaPattern)
        val interpolatedMatrix = calculateInterpolatedMatrix(
            metadata = metadata,
            asShotNeutral = config.asShotNeutral,
            fallbackMatrix = config.camToXyzMatrix,
            fallbackSource = config.colorMatrixSource,
        )
        val matrixCopy = interpolatedMatrix.matrix.copyOf()
        val xyzToCam = invert3x3(matrixCopy) ?: config.xyzToCamMatrix
        val blackLevels = IntArray(4) { index ->
            config.blackLevels.getOrNull(index) ?: config.blackLevels.lastOrNull() ?: 0
        }
        val gamma = (args["gamma"] as? Number)?.toDouble() ?: 2.2
        return CameraMetadata(
            cfaPattern = effectiveCfaPattern,
            blackLevels = blackLevels,
            whiteLevel = config.whiteLevel,
            colorMatrix = matrixCopy,
            colorMatrixSource = interpolatedMatrix.source,
            xyzToCamMatrix = xyzToCam,
            colorMatrixOriginal = config.colorMatrixOriginal.copyOf(),
            whiteBalanceGains = whiteBalanceGains,
            skipWhiteBalance = config.skipWhiteBalance,
            gamma = gamma,
        )
    }

    private fun parseForceCfaPattern(rawValue: Any?): Int? {
        return when (rawValue) {
            null -> null
            is Number -> rawValue.toInt()
            is String -> {
                val normalized = rawValue.trim()
                if (normalized.isEmpty()) return null
                normalized.toIntOrNull() ?: CFA_NAME_TO_PATTERN[normalized.uppercase(Locale.US)]
            }
            else -> null
        }
    }

    private fun computeEffectiveCfaPattern(basePattern: Int, roi: Rect, forcedPattern: Int?): Int {
        forcedPattern?.let { return it }
        if (basePattern !in CFA_PHASE_SHIFT_SUPPORTED) return basePattern
        // CameraCharacteristics CFA enums 0..3 map to a 2-bit Bayer tile, so XOR against
        // ROI parity (bit0=horizontal, bit1=vertical) to track the local origin shift.
        val horizontalShift = roi.left and 1
        val verticalShift = (roi.top and 1) shl 1
        val shiftMask = horizontalShift or verticalShift
        return basePattern xor shiftMask
    }

    private data class RawPipelineConfig(
        val rawPath: String,
        val roi: Rect,
        val rowStride: Int,
        val pixelStride: Int,
        val cfaPattern: Int,
        val blackLevels: List<Int>,
        val whiteLevel: Int,
        val asShotNeutral: DoubleArray?,
        val colorCorrectionGains: DoubleArray?,
        val camToXyzMatrix: DoubleArray,
        val xyzToCamMatrix: DoubleArray?,
        val colorMatrixSource: String,
        val colorMatrixOriginal: DoubleArray,
        val skipWhiteBalance: Boolean,
    )

    private data class RawPipelineResult(
        val cameraRgb: ChannelAverages,
        val balancedRgb: ChannelAverages,
        val whiteBalanceGains: DoubleArray,
        val xyz: DoubleArray,
        val camToXyzMatrix: DoubleArray,
        val xyzToCamMatrix: DoubleArray?,
        val colorMatrixSource: String,
        val colorMatrixOriginal: DoubleArray,
        val previewBitmap: Bitmap?,
        val debugPackagePath: String?,
        val debugArtifacts: Map<String, Bitmap>,
    )

    private data class MatrixComputationResult(
        val matrix: DoubleArray,
        val source: String,
    )

    private data class CalibrationEntry(
        val index: Int,
        val name: String,
        val cct: Double,
        val colorMatrix: DoubleArray,
        val cameraCalibration: DoubleArray,
    )

    private data class IlluminantInfo(
        val name: String,
        val cct: Double?,
    )

    private val ILLUMINANT_INFO = mapOf(
        0 to IlluminantInfo("Unknown", null),
        1 to IlluminantInfo("Daylight", 5500.0),
        2 to IlluminantInfo("Fluorescent", 4200.0),
        3 to IlluminantInfo("Tungsten", 2850.0),
        4 to IlluminantInfo("Flash", 6000.0),
        9 to IlluminantInfo("Fine Weather", 5500.0),
        10 to IlluminantInfo("Cloudy", 6500.0),
        11 to IlluminantInfo("Shade", 7500.0),
        12 to IlluminantInfo("Daylight Fluorescent", 6500.0),
        13 to IlluminantInfo("Day White Fluorescent", 7000.0),
        14 to IlluminantInfo("Cool White Fluorescent", 4200.0),
        15 to IlluminantInfo("White Fluorescent", 3500.0),
        16 to IlluminantInfo("Warm White Fluorescent", 3000.0),
        17 to IlluminantInfo("Standard Light A", 2856.0),
        18 to IlluminantInfo("Standard Light B", 4874.0),
        19 to IlluminantInfo("Standard Light C", 6774.0),
        20 to IlluminantInfo("D55", 5500.0),
        21 to IlluminantInfo("D65", 6504.0),
        22 to IlluminantInfo("D75", 7500.0),
        23 to IlluminantInfo("D50", 5003.0),
        24 to IlluminantInfo("ISO Studio Tungsten", 3200.0),
        255 to IlluminantInfo("Other", null),
    )

    private fun calculateInterpolatedMatrix(
        metadata: Map<String, Any?>,
        asShotNeutral: DoubleArray?,
        fallbackMatrix: DoubleArray,
        fallbackSource: String,
    ): MatrixComputationResult {
        val calibrations = gatherCalibrationEntries(metadata)
        val analogBalance = buildAnalogBalanceMatrix(metadata)
        val cameraNeutral = asShotNeutral ?: metadata.toDoubleArray(MetadataKeys.AS_SHOT_NEUTRAL)
        tryInterpolateColorMatrix(calibrations, analogBalance, cameraNeutral)?.let { return it }
        if (calibrations.isNotEmpty()) {
            val entry = calibrations.first()
            composeCameraToXyz(analogBalance, entry.cameraCalibration, entry.colorMatrix)?.let { matrix ->
                return MatrixComputationResult(matrix, "colorMatrix${entry.index}")
            }
        }

        val forward1 = metadata.matrixForKey(MetadataKeys.SENSOR_FORWARD_MATRIX1, "forwardMatrix1")
        val forward2 = metadata.matrixForKey(MetadataKeys.SENSOR_FORWARD_MATRIX2, "forwardMatrix2")
        if (forward1 != null && forward2 != null) {
            val matrix = interpolateMatrices(forward1, forward2, 0.5)
            return MatrixComputationResult(matrix, "forwardMatrix_blend")
        }
        if (forward1 != null) {
            return MatrixComputationResult(forward1.copy3x3() ?: forward1, "forwardMatrix1")
        }
        if (forward2 != null) {
            return MatrixComputationResult(forward2.copy3x3() ?: forward2, "forwardMatrix2")
        }

        metadata.toDoubleArray(MetadataKeys.COLOR_CORRECTION_TRANSFORM)?.copy3x3()?.let {
            return MatrixComputationResult(it, "colorCorrectionTransform")
        }

        return MatrixComputationResult(fallbackMatrix.copy3x3() ?: fallbackMatrix, fallbackSource)
    }

    private fun tryInterpolateColorMatrix(
        calibrations: List<CalibrationEntry>,
        analogBalance: DoubleArray,
        cameraNeutral: DoubleArray?,
    ): MatrixComputationResult? {
        if (calibrations.isEmpty()) return null
        val neutral = cameraNeutral?.takeIf { it.size >= 3 }?.copyOf(3) ?: return null
        val initialXy = calibrations.firstNotNullOfOrNull { entry ->
            cameraNeutralToXy(neutral, entry.colorMatrix)
        } ?: (0.3127 to 0.3290)
        var xy = initialXy
        var finalLow = calibrations.first()
        var finalHigh = calibrations.last()
        var finalWeight = 0.0
        repeat(10) {
            val cctEstimate = xyToCct(xy.first, xy.second)
            val (low, high, weight) = selectCalibrationPair(calibrations, cctEstimate)
            val blendedColorMatrix = interpolateMatrices(low.colorMatrix, high.colorMatrix, weight)
            val blendedCalibration = interpolateMatrices(low.cameraCalibration, high.cameraCalibration, weight)
            val xyzToCamera = matrixDot(analogBalance, matrixDot(blendedCalibration, blendedColorMatrix)) ?: return null
            val cameraToXyz = invert3x3(xyzToCamera) ?: return null
            val xyz = multiplyMatrixVector(cameraToXyz, neutral) ?: return null
            val sum = xyz.sum()
            if (abs(sum) < 1e-9) return null
            val newX = xyz[0] / sum
            val newY = xyz[1] / sum
            finalLow = low
            finalHigh = high
            finalWeight = weight
            if (abs(newX - xy.first) < 1e-6 && abs(newY - xy.second) < 1e-6) {
                xy = newX to newY
                return@repeat
            }
            xy = newX to newY
        }
        val blendedColorMatrix = interpolateMatrices(finalLow.colorMatrix, finalHigh.colorMatrix, finalWeight)
        val blendedCalibration = interpolateMatrices(finalLow.cameraCalibration, finalHigh.cameraCalibration, finalWeight)
        val xyzToCamera = matrixDot(analogBalance, matrixDot(blendedCalibration, blendedColorMatrix)) ?: return null
        val cameraToXyz = invert3x3(xyzToCamera) ?: return null
        return MatrixComputationResult(cameraToXyz, "colorMatrix_interpolated")
    }

    private fun gatherCalibrationEntries(metadata: Map<String, Any?>): List<CalibrationEntry> {
        val entries = mutableListOf<CalibrationEntry>()
        for (index in 1..3) {
            val colorMatrix = sensorColorTransformKey(index)?.let { key ->
                metadata.matrixForKey(key, "colorMatrix$index")
            } ?: metadata.matrixForKey("colorMatrix$index")
            if (colorMatrix == null) continue
            val calibrationMatrix = sensorCalibrationKey(index)?.let { key ->
                metadata.matrixForKey(key, "cameraCalibration$index")
            } ?: metadata.matrixForKey("cameraCalibration$index")
            val illuminant = resolveIlluminant(metadata, index) ?: continue
            val entry = CalibrationEntry(
                index = index,
                name = illuminant.name,
                cct = illuminant.cct ?: continue,
                colorMatrix = colorMatrix,
                cameraCalibration = calibrationMatrix ?: identityMatrix(),
            )
            entries += entry
        }
        return entries.sortedBy { it.cct }
    }

    private fun resolveIlluminant(metadata: Map<String, Any?>, index: Int): IlluminantInfo? {
        val keys = mutableListOf(
            "calibrationIlluminant$index",
            "referenceIlluminant$index",
        )
        when (index) {
            1 -> keys += MetadataKeys.SENSOR_REFERENCE_ILLUMINANT1
            2 -> keys += MetadataKeys.SENSOR_REFERENCE_ILLUMINANT2
            else -> keys += "sensorReferenceIlluminant$index"
        }
        for (key in keys) {
            val raw = metadata[key]
            val value = when (raw) {
                is Number -> raw.toInt()
                is String -> raw.toIntOrNull()
                else -> null
            } ?: continue
            val info = ILLUMINANT_INFO[value]
            if (info?.cct != null) {
                return info
            }
        }
        return null
    }

    private fun sensorColorTransformKey(index: Int): String? = when (index) {
        1 -> MetadataKeys.SENSOR_COLOR_TRANSFORM1
        2 -> MetadataKeys.SENSOR_COLOR_TRANSFORM2
        else -> "sensorColorTransform$index"
    }

    private fun sensorCalibrationKey(index: Int): String? = when (index) {
        1 -> MetadataKeys.SENSOR_CALIBRATION_TRANSFORM1
        2 -> MetadataKeys.SENSOR_CALIBRATION_TRANSFORM2
        else -> "sensorCalibrationTransform$index"
    }

    private fun buildAnalogBalanceMatrix(metadata: Map<String, Any?>): DoubleArray {
        val analog = metadata.toDoubleArray("analogBalance")
            ?: metadata.toDoubleArray("AnalogBalance")
        val matrix = DoubleArray(9) { 0.0 }
        for (index in 0 until 3) {
            matrix[index * 3 + index] = analog?.getOrNull(index) ?: 1.0
        }
        return matrix
    }

    private fun composeCameraToXyz(
        analogBalance: DoubleArray,
        cameraCalibration: DoubleArray?,
        colorMatrix: DoubleArray,
    ): DoubleArray? {
        val calibration = cameraCalibration ?: identityMatrix()
        val xyzToCamera = matrixDot(analogBalance, matrixDot(calibration, colorMatrix)) ?: return null
        return invert3x3(xyzToCamera)
    }

    private fun selectCalibrationPair(
        calibrations: List<CalibrationEntry>,
        cctEstimate: Double?,
    ): Triple<CalibrationEntry, CalibrationEntry, Double> {
        if (calibrations.size == 1 || cctEstimate == null) {
            val entry = calibrations.first()
            return Triple(entry, entry, 0.0)
        }
        if (cctEstimate <= calibrations.first().cct) {
            val entry = calibrations.first()
            return Triple(entry, entry, 0.0)
        }
        if (cctEstimate >= calibrations.last().cct) {
            val entry = calibrations.last()
            return Triple(entry, entry, 0.0)
        }
        for (i in 0 until calibrations.lastIndex) {
            val low = calibrations[i]
            val high = calibrations[i + 1]
            if (cctEstimate in low.cct..high.cct) {
                val denom = (1.0 / high.cct) - (1.0 / low.cct)
                val weight = if (abs(denom) < 1e-9) {
                    0.0
                } else {
                    ((1.0 / cctEstimate) - (1.0 / low.cct)) / denom
                }
                return Triple(low, high, weight.coerceIn(0.0, 1.0))
            }
        }
        val low = calibrations[calibrations.lastIndex - 1]
        val high = calibrations.last()
        return Triple(low, high, 1.0)
    }

    private fun xyToCct(x: Double, y: Double): Double? {
        val denom = 0.1858 - y
        if (abs(denom) < 1e-9) return null
        val n = (x - 0.3320) / denom
        val cct = 449.0 * n.pow(3) + 3525.0 * n.pow(2) + 6823.3 * n + 5520.33
        return cct.takeIf { it > 0.0 }
    }

    private fun cameraNeutralToXy(
        cameraNeutral: DoubleArray?,
        colorMatrix: DoubleArray?,
    ): Pair<Double, Double>? {
        if (cameraNeutral == null || colorMatrix == null) return null
        if (cameraNeutral.size < 3 || colorMatrix.size < 9) return null
        val inverse = invert3x3(colorMatrix) ?: return null
        val vector = DoubleArray(3) { index -> cameraNeutral.getOrNull(index) ?: return null }
        val xyz = multiplyMatrixVector(inverse, vector) ?: return null
        val sum = xyz.sum()
        if (abs(sum) < 1e-9) return null
        val x = xyz[0] / sum
        val y = xyz[1] / sum
        if (!x.isFinite() || !y.isFinite() || x <= 0.0 || y <= 0.0) return null
        return x to y
    }

    private fun matrixDot(left: DoubleArray?, right: DoubleArray?): DoubleArray? {
        if (left == null || right == null) return null
        if (left.size < 9 || right.size < 9) return null
        val result = DoubleArray(9)
        for (row in 0 until 3) {
            for (col in 0 until 3) {
                var sum = 0.0
                for (k in 0 until 3) {
                    sum += left[row * 3 + k] * right[k * 3 + col]
                }
                result[row * 3 + col] = sum
            }
        }
        return result
    }

    private fun multiplyMatrixVector(matrix: DoubleArray?, vector: DoubleArray): DoubleArray? {
        if (matrix == null || matrix.size < 9 || vector.size < 3) return null
        val x = matrix[0] * vector[0] + matrix[1] * vector[1] + matrix[2] * vector[2]
        val y = matrix[3] * vector[0] + matrix[4] * vector[1] + matrix[5] * vector[2]
        val z = matrix[6] * vector[0] + matrix[7] * vector[1] + matrix[8] * vector[2]
        return doubleArrayOf(x, y, z)
    }

    private fun identityMatrix(): DoubleArray {
        return doubleArrayOf(
            1.0, 0.0, 0.0,
            0.0, 1.0, 0.0,
            0.0, 0.0, 1.0,
        )
    }

    private fun enrichMetadataWithDng(
        dngPath: String?,
        metadata: Map<String, Any?>,
    ): Map<String, Any?> {
        if (dngPath.isNullOrEmpty()) return metadata
        val exif = runCatching { ExifInterface(dngPath) }.getOrNull() ?: return metadata
        val enriched = metadata.toMutableMap()
        fun putIfPresent(key: String, value: DoubleArray?) {
            if (value != null && value.isNotEmpty()) {
                enriched[key] = value
            }
        }
        fun parseDoubleArray(tag: String): DoubleArray? {
            val raw = exif.getAttribute(tag) ?: return null
            val parts = raw.replace(",", " ").trim().split(Regex("\\s+"))
            val doubles = parts.mapNotNull { part ->
                when {
                    part.contains("/") -> {
                        val frac = part.split("/")
                        if (frac.size == 2) {
                            val num = frac[0].toDoubleOrNull()
                            val den = frac[1].toDoubleOrNull()
                            if (num != null && den != null && den != 0.0) num / den else null
                        } else null
                    }
                    else -> part.toDoubleOrNull()
                }
            }
            return if (doubles.isEmpty()) null else doubles.toDoubleArray()
        }

        putIfPresent("colorMatrix1", parseDoubleArray(DNG_TAG_COLOR_MATRIX1))
        putIfPresent("colorMatrix2", parseDoubleArray(DNG_TAG_COLOR_MATRIX2))
        putIfPresent("forwardMatrix1", parseDoubleArray(DNG_TAG_FORWARD_MATRIX1))
        putIfPresent("forwardMatrix2", parseDoubleArray(DNG_TAG_FORWARD_MATRIX2))
        putIfPresent("asShotNeutral", parseDoubleArray(DNG_TAG_AS_SHOT_NEUTRAL))

        exif.getAttributeInt(DNG_TAG_CALIBRATION_ILLUMINANT1, -1).takeIf { it >= 0 }?.let {
            enriched["referenceIlluminant1"] = it
        }
        exif.getAttributeInt(DNG_TAG_CALIBRATION_ILLUMINANT2, -1).takeIf { it >= 0 }?.let {
            enriched["referenceIlluminant2"] = it
        }
        return enriched
    }

    fun process(): Map<String, Any?> {
        val mode = RoiProcessingMode.from(args["mode"])
        val normalizedRoi = (args["normalizedRoi"] as? Map<*, *>)?.let { map ->
            RectF(
                map["left"].toFloatOrZero(),
                map["top"].toFloatOrZero(),
                map["right"].toFloatOrOne(),
                map["bottom"].toFloatOrOne(),
            )
        } ?: throw IllegalArgumentException("normalizedRoi missing")
        val metadata = (args["metadata"] as? Map<*, *>)?.mapKeys { it.key.toString() }
            ?: throw IllegalArgumentException("metadata missing")
        // DNG enrichment removed
        val workingMetadata = metadata

        val jpegPath = args["jpegPath"] as? String

        val jpegOrientationDeg = readJpegOrientationDegrees(jpegPath)
        val asShotNeutral = workingMetadata.toDoubleArray(MetadataKeys.AS_SHOT_NEUTRAL)
            ?: metadata.toDoubleArray(MetadataKeys.AS_SHOT_NEUTRAL)
        val rawPath = if (mode.includesRaw()) {
            args["rawBufferPath"] as? String
                ?: throw IllegalArgumentException("rawBufferPath missing")
        } else {
            null
        }

        val rawRect = if (mode.includesRaw()) {
            computeRawRectForLogging(
                normalizedRoi = normalizedRoi,
                metadata = workingMetadata,
                jpegOrientationDeg = jpegOrientationDeg,
            )
        } else {
            null
        }

        val rawContext = if (mode.includesRaw()) {
            val transposeCcm = false
            buildRawPipelineContext(
                rawPath = rawPath!!,
                roi = rawRect ?: throw IllegalArgumentException("Invalid RAW dimensions"),
                metadata = workingMetadata,
                asShotNeutral = asShotNeutral,
                transposeCcm = transposeCcm,
            )
        } else {
            null
        }
        val rawResult = rawContext?.let { runRawPipeline(it, workingMetadata) }
        val jpegStats = if (mode.includesJpeg()) {
            computeJpegStats(jpegPath, normalizedRoi, jpegOrientationDeg)
        } else {
            null
        }
        val rawRectMap = rawRect?.toMap()
        val debugPayload = buildDebugPayload(rawRectMap, rawResult)

        return mapOf(
            "xyz" to rawResult?.xyz.nonNegativeList(),
            "linearRgb" to rawResult?.balancedRgb?.toRgbList().orEmptyList(),
            "rawRgb" to rawResult?.cameraRgb?.toRgbList().orEmptyList(),
            "whiteBalanceGains" to rawResult?.whiteBalanceGains?.toList().orEmptyList(),
            "jpegSrgb" to jpegStats?.srgb?.toListOrEmpty(),
            "jpegLinearRgb" to jpegStats?.linear?.toListOrEmpty(),
            "jpegXyz" to jpegStats?.xyz?.toListOrEmpty(),
            "camToXyzMatrix" to rawResult?.camToXyzMatrix?.toList().orEmptyList(),
            "xyzToCamMatrix" to rawResult?.xyzToCamMatrix?.toList().orEmptyList(),
            "colorMatrixSource" to (rawResult?.colorMatrixSource ?: ""),
            "rawRect" to (rawRectMap ?: emptyMap<String, Any?>()),
            "debug" to debugPayload,
        )
    }

    private fun buildDebugPayload(
        rawRect: Map<String, Any?>?,
        rawResult: RawPipelineResult?,
    ): Map<String, Any?> {
        val payload = mutableMapOf<String, Any?>()
        if (!rawRect.isNullOrEmpty()) {
            payload["rawRect"] = rawRect
        }
        if (rawResult != null) {
            rawResult.debugPackagePath?.let { payload["debugPackagePath"] = it }
            rawResult.previewBitmap?.let { bitmap ->
                encodeBitmapToBase64(bitmap)?.let { payload["finalImage"] = it }
                bitmap.recycle()
            }
            if (rawResult.debugArtifacts.isNotEmpty()) {
                val encodedStages = encodeArtifacts(rawResult.debugArtifacts)
                if (encodedStages.isNotEmpty()) {
                    payload["stages"] = encodedStages
                }
            }
        }
        return payload
    }

    private fun dumpDebugPackage(
        config: RawPipelineConfig,
        pipelineMetadata: CameraMetadata,
        rawBuffer: ShortArray,
        debugArtifacts: Map<String, Bitmap>,
        captureMetadata: Map<String, Any?>,
    ): String? {
        val externalRoot = runCatching { context.getExternalFilesDir(null) }.getOrNull()
        val debugRoot = when {
            externalRoot != null -> File(externalRoot, "debug_captures")
            else -> File(config.rawPath).parentFile ?: context.filesDir
        }
        if (!debugRoot.exists() && !debugRoot.mkdirs()) {
            Log.w("RawRoiProcessor", "Unable to create debug root: ${debugRoot.absolutePath}")
            return null
        }
        val timestamp = System.currentTimeMillis()
        val captureDir = File(debugRoot, "debug_capture_$timestamp")
        if (!captureDir.exists() && !captureDir.mkdirs()) {
            Log.w("RawRoiProcessor", "Unable to create debug capture dir: ${captureDir.absolutePath}")
            return null
        }
        return runCatching {
            val metadataFile = File(captureDir, "metadata.json")
            val rawFile = File(captureDir, "input.raw")
            writeMetadataJson(metadataFile, config, pipelineMetadata, captureMetadata)
            writeRawInput(rawFile, rawBuffer)
            val writtenStages = writeStageArtifacts(captureDir, debugArtifacts)
            val metadataReady = metadataFile.exists() && rawFile.exists()
            val stagesReady = debugArtifacts.isEmpty() || (
                writtenStages.size == debugArtifacts.size &&
                    writtenStages.all { it.parentFile == captureDir && it.exists() }
                )
            if (!metadataReady || !stagesReady) {
                throw IllegalStateException("Debug dump missing required artifacts.")
            }
            val zipFile = File(debugRoot, "debug_capture_${timestamp}.zip")
            zipDirectory(captureDir, zipFile)
            zipFile.absolutePath
        }.onFailure {
            Log.w("RawRoiProcessor", "Debug dump failed: ${it.message}", it)
        }.getOrNull()
    }

    private fun writeMetadataJson(
        target: File,
        config: RawPipelineConfig,
        pipelineMetadata: CameraMetadata,
        captureMetadata: Map<String, Any?>,
    ) {
        val asShotNeutral = config.asShotNeutral ?: captureMetadata.toDoubleArray(MetadataKeys.AS_SHOT_NEUTRAL)
        val wbDumpGains = gainsFromAsShotNeutral(asShotNeutral)
        val json = JSONObject().apply {
            put("width", config.roi.width())
            put("height", config.roi.height())
            put("whiteLevel", pipelineMetadata.whiteLevel)
            put("blackLevel", JSONArray().apply {
                pipelineMetadata.blackLevels.forEach { put(it) }
            })
            put("wbGains", buildWhiteBalanceJson(pipelineMetadata, config, wbDumpGains))
            asShotNeutral?.let { values ->
                put("asShotNeutral", JSONArray().apply { values.forEach { put(it) } })
            }
            put("ccm", buildCcmJson(pipelineMetadata.colorMatrix))
            put("colorSpace", determineColorSpaceName(captureMetadata))
        }
        FileOutputStream(target).use { stream ->
            stream.write(json.toString(2).toByteArray(Charsets.UTF_8))
        }
    }

    private fun buildWhiteBalanceJson(
        metadata: CameraMetadata,
        config: RawPipelineConfig,
        overrideGains: DoubleArray?,
    ): JSONObject {
        val wb = overrideGains ?: metadata.whiteBalanceGains
        val colorGains = config.colorCorrectionGains
        val green = wb.valueAtOrDefault(1, 1.0)
        val gEven = colorGains.valueAt(1) ?: green
        val gOdd = colorGains.valueAt(2) ?: gEven
        return JSONObject().apply {
            put("r", wb.valueAtOrDefault(0, 1.0))
            put("g", green)
            put("b", wb.valueAtOrDefault(2, 1.0))
            put("gEven", gEven)
            put("gOdd", gOdd)
        }
    }

    private fun buildCcmJson(matrix: DoubleArray): JSONArray {
        val rows = JSONArray()
        for (row in 0 until 3) {
            val rowArray = JSONArray()
            for (col in 0 until 3) {
                val index = row * 3 + col
                rowArray.put(if (index in matrix.indices) matrix[index] else 0.0)
            }
            rows.put(rowArray)
        }
        return rows
    }

    private fun determineColorSpaceName(captureMetadata: Map<String, Any?>): String {
        val argValue = args["colorSpace"]?.toString()?.takeIf { it.isNotBlank() }
        val metadataValue = captureMetadata["colorSpace"]?.toString()?.takeIf { it.isNotBlank() }
        return argValue ?: metadataValue ?: "sRGB"
    }

    private fun writeRawInput(target: File, data: ShortArray) {
        FileOutputStream(target).use { stream ->
            val byteBuffer = ByteBuffer.allocate(RAW_DUMP_CHUNK_BYTES).order(ByteOrder.LITTLE_ENDIAN)
            for (value in data) {
                if (byteBuffer.remaining() < java.lang.Short.BYTES) {
                    stream.write(byteBuffer.array(), 0, byteBuffer.position())
                    byteBuffer.clear()
                }
                byteBuffer.putShort(value)
            }
            val remaining = byteBuffer.position()
            if (remaining > 0) {
                stream.write(byteBuffer.array(), 0, remaining)
            }
        }
    }

    private fun writeStageArtifacts(targetDir: File, artifacts: Map<String, Bitmap>): List<File> {
        val written = mutableListOf<File>()
        var index = 0
        for ((stageName, bitmap) in artifacts) {
            val safeName = sanitizeStageName(stageName)
            val fileName = String.format(Locale.US, "stage_%02d_%s.png", index, safeName)
            val file = File(targetDir, fileName)
            FileOutputStream(file).use { stream ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
            }
            written.add(file)
            index++
        }
        return written
    }

    private fun sanitizeStageName(stageName: String): String {
        val normalized = stageName.lowercase(Locale.US).replace(Regex("[^a-z0-9]+"), "_")
        return normalized.trim('_').ifEmpty { "stage" }
    }

    private fun zipDirectory(sourceDir: File, zipFile: File) {
        if (zipFile.exists()) {
            zipFile.delete()
        }
        ZipOutputStream(FileOutputStream(zipFile)).use { zip ->
            sourceDir.walkTopDown()
                .filter { it.isFile }
                .forEach { file ->
                    val relative = sourceDir.toURI().relativize(file.toURI()).path
                    val entryName = if (relative.isNullOrEmpty()) {
                        file.name
                    } else {
                        "${sourceDir.name}/$relative"
                    }
                    zip.putNextEntry(ZipEntry(entryName))
                    file.inputStream().use { input ->
                        input.copyTo(zip)
                    }
                    zip.closeEntry()
                }
        }
    }

    private fun readJpegOrientationDegrees(jpegPath: String?): Int {
        if (jpegPath.isNullOrEmpty()) return 0
        return runCatching {
            val exif = ExifInterface(jpegPath)
            when (exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                ExifInterface.ORIENTATION_ROTATE_180 -> 180
                ExifInterface.ORIENTATION_ROTATE_90 -> 270
                ExifInterface.ORIENTATION_ROTATE_270 -> 90
                else -> 0
            }
        }.getOrElse { 0 }
    }

    private fun invertRotationDegrees(degrees: Int): Int {
        val normalized = (degrees % 360 + 360) % 360
        return (360 - normalized) % 360
    }

    private fun rotateRect(rect: RectF, orientation: Int): RectF {
        val points = listOf(
            PointF(rect.left, rect.top),
            PointF(rect.right, rect.top),
            PointF(rect.left, rect.bottom),
            PointF(rect.right, rect.bottom),
        ).map { rotatePoint(it, orientation) }
        val minX = points.minOf { it.x }
        val maxX = points.maxOf { it.x }
        val minY = points.minOf { it.y }
        val maxY = points.maxOf { it.y }
        return RectF(minX, minY, maxX, maxY)
    }

    private fun mapRect(rect: RectF, rawWidth: Int, rawHeight: Int): Rect {
        val left = (rect.left.coerceIn(0f, 1f) * rawWidth).toInt().coerceIn(0, rawWidth - 1)
        val right = (rect.right.coerceIn(0f, 1f) * rawWidth).toInt().coerceIn(left + 1, rawWidth)
        val top = (rect.top.coerceIn(0f, 1f) * rawHeight).toInt().coerceIn(0, rawHeight - 1)
        val bottom = (rect.bottom.coerceIn(0f, 1f) * rawHeight).toInt().coerceIn(top + 1, rawHeight)
        return Rect(left, top, right, bottom)
    }

    private fun rotatePoint(p: PointF, orientation: Int): PointF {
        val sanitized = (orientation % 360 + 360) % 360
        return when (sanitized) {
            90 -> PointF(1f - p.y, p.x)
            180 -> PointF(1f - p.x, 1f - p.y)
            270 -> PointF(p.y, 1f - p.x)
            else -> PointF(p.x, p.y)
        }
    }

    private data class ChannelAccumulator(var sum: Double = 0.0, var count: Long = 0)

    data class ChannelAverages(
        val red: Double,
        val greenR: Double,
        val greenB: Double,
        val blue: Double,
    ) {
        fun greenAverage(): Double = (greenR + greenB) / 2.0

        fun toRgbList(): List<Double> = listOf(red, greenAverage(), blue)

        fun toRgbVector(): DoubleArray = doubleArrayOf(red, greenAverage(), blue)

        fun toCfaVector(): DoubleArray = doubleArrayOf(red, greenR, greenB, blue)
    }

    private data class JpegStats(
        val srgb: DoubleArray,
        val linear: DoubleArray,
        val xyz: DoubleArray,
    )

    data class PipelineContext(
        val rawBuffer: ShortArray,
        val width: Int,
        val height: Int,
        val metadata: CameraMetadata,
        val debugConfig: DebugConfig = DebugConfig(),
        val debugArtifacts: MutableMap<String, Bitmap> = mutableMapOf(),
    ) {
        var cameraSample: ChannelAverages? = null
        var balancedSample: ChannelAverages? = null
        var xyzSample: DoubleArray? = null
        var linearRgb: DoubleArray? = null
        var srgbSample: DoubleArray? = null

        fun recordStage(stageName: String, bitmap: Bitmap) {
            if (!debugConfig.shouldDumpArtifacts()) return
            val safeConfig = bitmap.config ?: Bitmap.Config.ARGB_8888
            debugArtifacts[stageName] = bitmap.copy(safeConfig, false)
        }
    }

    data class CameraMetadata(
        val cfaPattern: Int,
        val blackLevels: IntArray,
        val whiteLevel: Int,
        val colorMatrix: DoubleArray,
        val colorMatrixSource: String,
        val xyzToCamMatrix: DoubleArray?,
        val colorMatrixOriginal: DoubleArray,
        val whiteBalanceGains: DoubleArray,
        val skipWhiteBalance: Boolean,
        val gamma: Double,
    )

    data class DebugConfig(
        val dumpIntermediateImages: Boolean = false,
        val bypassColorCorrection: Boolean = false,
    ) {
        fun shouldSkipStage(stageName: String): Boolean {
            return bypassColorCorrection && stageName == "ColorCorrectionStage"
        }

        fun shouldDumpArtifacts(): Boolean = dumpIntermediateImages

        companion object {
            fun from(source: Any?): DebugConfig {
                val map = source as? Map<*, *> ?: return DebugConfig()
                return DebugConfig(
                    dumpIntermediateImages = map["dumpIntermediateImages"].toBooleanStrict(),
                    bypassColorCorrection = map["bypassCCM"].toBooleanStrict(),
                )
            }
        }
    }

    private interface PipelineStage {
        val name: String
        fun process(input: Bitmap, context: PipelineContext): Bitmap
    }

    private class PipelineExecutor(
        private val stages: List<PipelineStage>,
    ) {
        fun execute(context: PipelineContext): Bitmap {
            val safeWidth = context.width.coerceAtLeast(1)
            val safeHeight = context.height.coerceAtLeast(1)
            var bitmap = Bitmap.createBitmap(safeWidth, safeHeight, Bitmap.Config.ARGB_8888)
            for (stage in stages) {
                if (context.debugConfig.shouldSkipStage(stage.name)) {
                    continue
                }
                bitmap = stage.process(bitmap, context)
                context.recordStage(stage.name, bitmap)
            }
            return bitmap
        }
    }

    private fun ChannelAccumulator.average(): Double {
        return if (count == 0L) 0.0 else sum / count
    }

    private fun resolveCfaChannel(pattern: Int, x: Int, y: Int): Int {
        val evenRow = (y and 1) == 0
        val evenCol = (x and 1) == 0
        return when (pattern) {
            CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_BGGR -> when {
                evenRow && evenCol -> 3
                evenRow && !evenCol -> 2
                !evenRow && evenCol -> 1
                else -> 0
            }
            CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_GRBG -> when {
                evenRow && evenCol -> 1
                evenRow && !evenCol -> 0
                !evenRow && evenCol -> 3
                else -> 2
            }
            CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_GBRG -> when {
                evenRow && evenCol -> 2
                evenRow && !evenCol -> 3
                !evenRow && evenCol -> 0
                else -> 1
            }
            else -> when {
                evenRow && evenCol -> 0
                evenRow && !evenCol -> 1
                !evenRow && evenCol -> 2
                else -> 3
            }
        }
    }

    private inner class DemosaicStage : PipelineStage {
        override val name: String = "DemosaicStage"

        private val neighborOffsets = listOf(
            0 to 0,
            -1 to 0,
            1 to 0,
            0 to -1,
            0 to 1,
            -1 to -1,
            -1 to 1,
            1 to -1,
            1 to 1,
        )

        override fun process(input: Bitmap, context: PipelineContext): Bitmap {
            val width = context.width
            val height = context.height
            if (width <= 0 || height <= 0) return input
            val normalized = DoubleArray(context.rawBuffer.size)
            val accumulators = Array(4) { ChannelAccumulator() }
            val metadata = context.metadata
            val whiteLevel = metadata.whiteLevel.toDouble().coerceAtLeast(1.0)
            for (y in 0 until height) {
                for (x in 0 until width) {
                    val index = y * width + x
                    val channel = resolveCfaChannel(metadata.cfaPattern, x, y)
                    val rawValue = if (index in context.rawBuffer.indices) {
                        context.rawBuffer[index].toInt() and 0xFFFF
                    } else {
                        0
                    }
                    val black = metadata.blackLevels.getOrElse(channel) { 0 }
                    val corrected = (rawValue - black).coerceAtLeast(0)
                    val channelRange = (metadata.whiteLevel - black).coerceAtLeast(1)
                    val normalizedValue = corrected.toDouble() / channelRange.toDouble()
                    normalized[index] = normalizedValue
                    accumulators[channel].sum += normalizedValue
                    accumulators[channel].count++
                }
            }
            val pixels = IntArray(width * height)
            for (y in 0 until height) {
                for (x in 0 until width) {
                    val channel = resolveCfaChannel(metadata.cfaPattern, x, y)
                    val rgb = demosaicPixel(
                        normalized = normalized,
                        width = width,
                        height = height,
                        x = x,
                        y = y,
                        pattern = metadata.cfaPattern,
                        centerChannel = channel,
                    )
                    pixels[y * width + x] = rgb.toColorInt()
                }
            }
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            bitmap.setPixels(pixels, 0, width, 0, 0, width, height)
            val averages = ChannelAverages(
                red = accumulators[0].average(),
                greenR = accumulators[1].average(),
                greenB = accumulators[2].average(),
                blue = accumulators[3].average(),
            )
            context.cameraSample = averages
            context.balancedSample = averages
            return bitmap
        }

        private fun demosaicPixel(
            normalized: DoubleArray,
            width: Int,
            height: Int,
            x: Int,
            y: Int,
            pattern: Int,
            centerChannel: Int,
        ): DoubleArray {
            val index = y * width + x
            val center = normalized.getOrElse(index) { 0.0 }
            val red = if (centerChannel == 0) center else sampleChannel(normalized, width, height, x, y, pattern, 0)
            val green = if (centerChannel == 1 || centerChannel == 2) {
                center
            } else {
                sampleGreen(normalized, width, height, x, y, pattern)
            }
            val blue = if (centerChannel == 3) center else sampleChannel(normalized, width, height, x, y, pattern, 3)
            return doubleArrayOf(red, green, blue)
        }

        private fun sampleChannel(
            normalized: DoubleArray,
            width: Int,
            height: Int,
            x: Int,
            y: Int,
            pattern: Int,
            targetChannel: Int,
        ): Double {
            var sum = 0.0
            var count = 0
            for ((dx, dy) in neighborOffsets) {
                val nx = x + dx
                val ny = y + dy
                if (nx in 0 until width && ny in 0 until height) {
                    val channel = resolveCfaChannel(pattern, nx, ny)
                    if (channel == targetChannel) {
                        sum += normalized[ny * width + nx]
                        count++
                    }
                }
            }
            return if (count == 0) normalized[y * width + x] else sum / count
        }

        private fun sampleGreen(
            normalized: DoubleArray,
            width: Int,
            height: Int,
            x: Int,
            y: Int,
            pattern: Int,
        ): Double {
            var sum = 0.0
            var count = 0
            for ((dx, dy) in neighborOffsets) {
                val nx = x + dx
                val ny = y + dy
                if (nx in 0 until width && ny in 0 until height) {
                    val channel = resolveCfaChannel(pattern, nx, ny)
                    if (channel == 1 || channel == 2) {
                        sum += normalized[ny * width + nx]
                        count++
                    }
                }
            }
            return if (count == 0) normalized[y * width + x] else sum / count
        }
    }

    private inner class WhiteBalanceStage : PipelineStage {
        override val name: String = "WhiteBalanceStage"

        override fun process(input: Bitmap, context: PipelineContext): Bitmap {
            val sample = context.balancedSample ?: context.cameraSample ?: return input
            val gains = context.metadata.whiteBalanceGains
            val corrected = if (context.metadata.skipWhiteBalance) {
                sample
            } else {
                applyGains(sample, gains)
            }
            context.balancedSample = corrected
            val bitmap = corrected.toBitmap(context.width, context.height)
            return bitmap
        }

        private fun applyGains(sample: ChannelAverages, gains: DoubleArray): ChannelAverages {
            val rGain = gains.getOrElse(0) { 1.0 }
            val gGain = gains.getOrElse(1) { 1.0 }
            val bGain = gains.getOrElse(2) { 1.0 }
            return ChannelAverages(
                red = sample.red * rGain,
                greenR = sample.greenR * gGain,
                greenB = sample.greenB * gGain,
                blue = sample.blue * bGain,
            )
        }
    }

    private inner class ColorCorrectionStage : PipelineStage {
        override val name: String = "ColorCorrectionStage"

        override fun process(input: Bitmap, context: PipelineContext): Bitmap {
            val sample = context.balancedSample ?: return input
            val xyz = multiplyMatrix(context.metadata.colorMatrix, sample)
            val clamped = DoubleArray(xyz.size) { index -> max(0.0, xyz.getOrElse(index) { 0.0 }) }
            context.xyzSample = clamped
            val linear = xyzToSrgbLinear(clamped).map { max(0.0, it) }.toDoubleArray()
            context.linearRgb = linear
            val bitmap = createSolidBitmap(context.width, context.height, linear)
            return bitmap
        }

        private fun multiplyMatrix(matrix: DoubleArray, sample: ChannelAverages): DoubleArray {
            if (matrix.size < 9) return sample.toRgbVector()
            val vector = sample.toRgbVector()
            val x = matrix[0] * vector[0] + matrix[1] * vector[1] + matrix[2] * vector[2]
            val y = matrix[3] * vector[0] + matrix[4] * vector[1] + matrix[5] * vector[2]
            val z = matrix[6] * vector[0] + matrix[7] * vector[1] + matrix[8] * vector[2]
            return doubleArrayOf(x, y, z)
        }
    }

    private inner class GammaStage : PipelineStage {
        override val name: String = "GammaStage"

        override fun process(input: Bitmap, context: PipelineContext): Bitmap {
            val linear = context.linearRgb ?: context.balancedSample?.toRgbVector() ?: return input
            val corrected = DoubleArray(linear.size) { index ->
                applyGammaCurve(linear.getOrElse(index) { 0.0 }, context.metadata.gamma)
            }
            context.srgbSample = corrected
            val bitmap = createSolidBitmap(context.width, context.height, corrected)
            return bitmap
        }
    }

    private fun encodeArtifacts(artifacts: Map<String, Bitmap>): Map<String, String> {
        val encoded = mutableMapOf<String, String>()
        for ((stage, bitmap) in artifacts) {
            val data = encodeBitmapToBase64(bitmap)
            if (data != null) {
                encoded[stage] = data
            }
            bitmap.recycle()
        }
        return encoded
    }

    private fun encodeBitmapToBase64(bitmap: Bitmap): String? {
        return runCatching {
            ByteArrayOutputStream().use { stream ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
                Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)
            }
        }.getOrNull()
    }

    private fun createSolidBitmap(width: Int, height: Int, vector: DoubleArray): Bitmap {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val color = vector.toColorInt()
        val pixels = IntArray(width * height) { color }
        bitmap.setPixels(pixels, 0, width, 0, 0, width, height)
        return bitmap
    }

    private fun ChannelAverages.toBitmap(width: Int, height: Int): Bitmap {
        return createSolidBitmap(width, height, toRgbVector())
    }

    private fun DoubleArray.toColorInt(): Int {
        val r = (getOrElse(0) { 0.0 }.coerceIn(0.0, 1.0) * 255.0).roundToInt()
        val g = (getOrElse(1) { 0.0 }.coerceIn(0.0, 1.0) * 255.0).roundToInt()
        val b = (getOrElse(2) { 0.0 }.coerceIn(0.0, 1.0) * 255.0).roundToInt()
        return Color.argb(255, r, g, b)
    }

    private fun xyzToSrgbLinear(xyz: DoubleArray): DoubleArray {
        val x = xyz.getOrElse(0) { 0.0 }
        val y = xyz.getOrElse(1) { 0.0 }
        val z = xyz.getOrElse(2) { 0.0 }
        val r = 3.2406 * x - 1.5372 * y - 0.4986 * z
        val g = -0.9689 * x + 1.8758 * y + 0.0415 * z
        val b = 0.0557 * x - 0.2040 * y + 1.0570 * z
        return doubleArrayOf(r, g, b)
    }

    private fun applyGammaCurve(value: Double, gamma: Double): Double {
        if (gamma <= 0.0) return value.coerceIn(0.0, 1.0)
        val clamped = value.coerceIn(0.0, 1.0)
        return clamped.pow(1.0 / gamma)
    }

    private fun interpolateMatrices(matrix1: DoubleArray, matrix2: DoubleArray, weight: Double): DoubleArray {
        val clampedWeight = weight.coerceIn(0.0, 1.0)
        val result = DoubleArray(9)
        for (index in 0 until 9) {
            val a = matrix1.getOrNull(index) ?: 0.0
            val b = matrix2.getOrNull(index) ?: 0.0
            result[index] = (1.0 - clampedWeight) * a + clampedWeight * b
        }
        return result
    }

    private fun invert3x3(matrix: DoubleArray): DoubleArray? {
        if (matrix.size < 9) return null
        val a = matrix[0]
        val b = matrix[1]
        val c = matrix[2]
        val d = matrix[3]
        val e = matrix[4]
        val f = matrix[5]
        val g = matrix[6]
        val h = matrix[7]
        val i = matrix[8]
        val det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        if (abs(det) < 1e-9) return null
        val invDet = 1.0 / det
        return doubleArrayOf(
            (e * i - f * h) * invDet,
            (c * h - b * i) * invDet,
            (b * f - c * e) * invDet,
            (f * g - d * i) * invDet,
            (a * i - c * g) * invDet,
            (c * d - a * f) * invDet,
            (d * h - e * g) * invDet,
            (b * g - a * h) * invDet,
            (a * e - b * d) * invDet,
        )
    }

    private fun adaptToD65(
        xyz: DoubleArray,
        sourceWhite: DoubleArray,
        targetWhite: DoubleArray,
    ): DoubleArray {
        if (xyz.size < 3) return xyz
        fun multiply3(matrix: DoubleArray, vector: DoubleArray): DoubleArray {
            val x = matrix[0] * vector[0] + matrix[1] * vector[1] + matrix[2] * vector[2]
            val y = matrix[3] * vector[0] + matrix[4] * vector[1] + matrix[5] * vector[2]
            val z = matrix[6] * vector[0] + matrix[7] * vector[1] + matrix[8] * vector[2]
            return doubleArrayOf(x, y, z)
        }
        val srcCone = multiply3(BRADFORD, sourceWhite)
        val dstCone = multiply3(BRADFORD, targetWhite)
        val scale = doubleArrayOf(
            if (srcCone[0] != 0.0) dstCone[0] / srcCone[0] else 1.0,
            if (srcCone[1] != 0.0) dstCone[1] / srcCone[1] else 1.0,
            if (srcCone[2] != 0.0) dstCone[2] / srcCone[2] else 1.0,
        )
        val cone = multiply3(BRADFORD, xyz)
        val adapted = doubleArrayOf(
            cone[0] * scale[0],
            cone[1] * scale[1],
            cone[2] * scale[2],
        )
        return multiply3(BRADFORD_INV, adapted)
    }

    // rawpy sandbox pipeline removed

    private fun computeJpegStats(
        jpegPath: String?,
        normalizedRoi: RectF,
        orientation: Int,
    ): JpegStats? {
        if (jpegPath.isNullOrEmpty()) return null
        val file = File(jpegPath)
        if (!file.exists()) return null
        var inputStream: FileInputStream? = null
        var decoder: BitmapRegionDecoder? = null
        return runCatching {
            inputStream = FileInputStream(file)
            decoder = BitmapRegionDecoder.newInstance(inputStream!!.fd, false)
            val decoderRef = decoder ?: return null
            val roiRect = mapRect(
                rotateRect(normalizedRoi, orientation),
                decoderRef.width,
                decoderRef.height,
            )
            if (roiRect.width() <= 0 || roiRect.height() <= 0) return null
            val options = BitmapFactory.Options().apply {
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
            val bitmap = decoderRef.decodeRegion(roiRect, options) ?: return null
            val stats = bitmap.computeAverageSrgb()
            bitmap.recycle()
            stats
        }.onFailure {
            Log.w("RawRoiProcessor", "JPEG stats failed: ${it.message}")
        }.also {
            decoder?.recycle()
            inputStream?.closeQuietly()
        }.getOrNull()
    }

    private fun Bitmap.computeAverageSrgb(): JpegStats {
        val pixels = IntArray(width * height)
        getPixels(pixels, 0, width, 0, 0, width, height)
        var sumR = 0.0
        var sumG = 0.0
        var sumB = 0.0
        for (pixel in pixels) {
            sumR += ((pixel shr 16) and 0xFF)
            sumG += ((pixel shr 8) and 0xFF)
            sumB += (pixel and 0xFF)
        }
        val count = pixels.size.coerceAtLeast(1)
        val avgSrgb = doubleArrayOf(
            sumR / count / 255.0,
            sumG / count / 255.0,
            sumB / count / 255.0,
        )
        val linear = doubleArrayOf(
            srgbGammaToLinear(avgSrgb[0]),
            srgbGammaToLinear(avgSrgb[1]),
            srgbGammaToLinear(avgSrgb[2]),
        )
        val xyz = multiplySrgbToXyz(linear)
        return JpegStats(
            srgb = avgSrgb,
            linear = linear,
            xyz = xyz,
        )
    }

    private fun srgbGammaToLinear(value: Double): Double {
        return if (value <= 0.04045) {
            value / 12.92
        } else {
            ((value + 0.055) / 1.055).pow(2.4)
        }
    }

    private fun multiplySrgbToXyz(rgbLinear: DoubleArray): DoubleArray {
        val r = rgbLinear[0]
        val g = rgbLinear[1]
        val b = rgbLinear[2]
        val x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
        val y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        val z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
        return doubleArrayOf(x, y, z)
    }

    private fun FileInputStream.closeQuietly() {
        runCatching { close() }
    }

    private fun DoubleArray?.nonNegativeList(): List<Double> {
        val source = this ?: return emptyList()
        return List(source.size) { index -> max(0.0, source[index]) }
    }

    private fun List<Double>?.orEmptyList(): List<Double> = this ?: emptyList()

    private fun Rect.toMap(): Map<String, Any?> = mapOf(
        "left" to left,
        "top" to top,
        "right" to right,
        "bottom" to bottom,
    )

    private fun Any?.toFloatOrZero(): Float = (this as? Number)?.toFloat() ?: 0f

    private fun Any?.toFloatOrOne(): Float = (this as? Number)?.toFloat() ?: 1f

    private fun Any?.toIntOrDefault(fallback: Any?): Int {
        return when (this) {
            is Number -> this.toInt()
            else -> (fallback as? Number)?.toInt() ?: 0
        }
    }

    private fun Map<String, Any?>.toDoubleArray(key: String): DoubleArray? {
        val value = this[key] ?: return null
        return when (value) {
            is DoubleArray -> value
            is FloatArray -> value.map { it.toDouble() }.toDoubleArray()
            is IntArray -> value.map { it.toDouble() }.toDoubleArray()
            is List<*> -> value.mapNotNull { (it as? Number)?.toDouble() }.toDoubleArray()
            else -> null
        }
    }

    private fun Map<String, Any?>.matrixForKey(key: String, vararg fallbacks: String): DoubleArray? {
        val keys = arrayOf(key, *fallbacks)
        for (candidate in keys) {
            val matrix = this.toDoubleArray(candidate)?.copy3x3()
            if (matrix != null) return matrix
        }
        return null
    }

    private fun DoubleArray.copy3x3(): DoubleArray? {
        if (this.size < 9) return null
        return this.copyOf(9)
    }

    private fun DoubleArray.valueAtOrDefault(index: Int, fallback: Double): Double {
        return if (index in indices) this[index] else fallback
    }

    private fun DoubleArray?.valueAt(index: Int): Double? {
        if (this == null) return null
        return if (index in this.indices) this[index] else null
    }

    private fun extractWhiteBalanceGains(
        metadata: Map<String, Any?>,
        asShotNeutral: DoubleArray?,
        colorCorrectionGains: DoubleArray?,
    ): DoubleArray {
        val neutralSource = asShotNeutral ?: metadata.toDoubleArray(MetadataKeys.AS_SHOT_NEUTRAL)
        gainsFromAsShotNeutral(neutralSource)?.let { return it }

        val ccGains = colorCorrectionGains ?: metadata.toDoubleArray(MetadataKeys.COLOR_CORRECTION_GAINS)
        gainsFromColorCorrection(ccGains)?.let { return it }

        val wbGains = metadata.toDoubleArray("wbGains")
        gainsFromWbTag(wbGains)?.let { return it }

        return doubleArrayOf(1.0, 1.0, 1.0)
    }

    private fun gainsFromAsShotNeutral(neutral: DoubleArray?): DoubleArray? {
        if (neutral == null || neutral.size < 3) return null
        val safe = DoubleArray(3) { index ->
            val value = neutral.getOrElse(index) { 1.0 }
            max(value, 1e-6)
        }
        return doubleArrayOf(1.0 / safe[0], 1.0 / safe[1], 1.0 / safe[2])
    }

    private fun gainsFromColorCorrection(gains: DoubleArray?): DoubleArray? {
        if (gains == null || gains.isEmpty()) return null
        val r = gains.getOrNull(0) ?: return null
        val gEven = gains.getOrNull(1) ?: return null
        val gOdd = gains.getOrNull(2) ?: gEven
        val b = gains.getOrNull(3) ?: return null
        val g = (gEven + gOdd) / 2.0
        return doubleArrayOf(r, g, b)
    }

    private fun gainsFromWbTag(values: DoubleArray?): DoubleArray? {
        if (values == null || values.isEmpty()) return null
        return when {
            values.size >= 4 -> {
                val r = values.getOrNull(0) ?: return null
                val gEven = values.getOrNull(1) ?: return null
                val gOdd = values.getOrNull(2) ?: gEven
                val b = values.getOrNull(3) ?: return null
                doubleArrayOf(r, (gEven + gOdd) / 2.0, b)
            }
            values.size >= 3 -> doubleArrayOf(values[0], values[1], values[2])
            else -> null
        }
    }

    private data class ColorTransform(
        val matrix: DoubleArray,
        val requiresInverse: Boolean,
        val source: String,
        val inverseMatrix: DoubleArray? = null,
    )

    private fun selectWorkingColorTransform(
        metadata: Map<String, Any?>,
        transpose: Boolean,
    ): ColorTransform {
        // 0) Highest priority: caller-provided custom 3x3 (row-major, cam->XYZ)
        runCatching {
            val candidate = (args["customCamToXyz"] as? List<*>)
                ?.mapNotNull { (it as? Number)?.toDouble() }
                ?.toDoubleArray()
            if (candidate != null && candidate.size >= 9) {
                val m = if (transpose) transpose3x3(candidate) else candidate.copyOf()
                return ColorTransform(
                    matrix = m,
                    requiresInverse = false,
                    source = if (transpose) "customCamToXyz_T" else "customCamToXyz",
                )
            }
        }
        metadata.toDoubleArray(MetadataKeys.COLOR_CORRECTION_TRANSFORM)?.let {
            if (!isIdentity3x3(it)) {
                val m = if (transpose) transpose3x3(it) else it
                return ColorTransform(m, requiresInverse = false, source = if (transpose) "colorCorrectionTransform_T" else "colorCorrectionTransform")
            }
        }
        val base = if (transpose) transpose3x3(RAWPY_CAM_TO_XYZ) else RAWPY_CAM_TO_XYZ.copyOf()
        val inv = if (transpose) transpose3x3(RAWPY_XYZ_TO_CAM) else RAWPY_XYZ_TO_CAM.copyOf()
        return ColorTransform(
            matrix = base,
            requiresInverse = false,
            source = if (transpose) "default_static_T" else "default_static",
            inverseMatrix = inv,
        )
    }

    private fun DoubleArray?.toListOrEmpty(): List<Double> = this?.toList() ?: emptyList()

    private fun isIdentity3x3(matrix: DoubleArray, epsilon: Double = 1e-3): Boolean {
        if (matrix.size < 9) return false
        val identity = doubleArrayOf(
            1.0, 0.0, 0.0,
            0.0, 1.0, 0.0,
            0.0, 0.0, 1.0,
        )
        for (index in identity.indices) {
            if (abs(matrix[index] - identity[index]) > epsilon) {
                return false
            }
        }
        return true
    }

    private fun transpose3x3(matrix: DoubleArray): DoubleArray {
        if (matrix.size < 9) return matrix.copyOf()
        return doubleArrayOf(
            matrix[0], matrix[3], matrix[6],
            matrix[1], matrix[4], matrix[7],
            matrix[2], matrix[5], matrix[8],
        )
    }
}

private fun Any?.toBooleanStrict(): Boolean {
    return when (this) {
        is Boolean -> this
        is Number -> this.toDouble() != 0.0
        is String -> this.equals("true", ignoreCase = true) || this == "1"
        else -> false
    }
}
