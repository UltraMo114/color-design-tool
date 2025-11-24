package com.example.color_design_tool.camera

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.PointF
import android.graphics.Rect
import android.graphics.RectF
import android.hardware.camera2.CameraCharacteristics
import android.util.Log
import androidx.exifinterface.media.ExifInterface
import java.io.File
import java.io.FileInputStream
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import java.util.Locale
import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

class RawRoiProcessor(
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
        )
    }

    private fun runRawPipeline(
        config: RawPipelineConfig,
        metadata: Map<String, Any?>,
    ): RawPipelineResult {
        val cameraRgb = accumulateRaw(
            rawPath = config.rawPath,
            roi = config.roi,
            rowStride = config.rowStride,
            pixelStride = config.pixelStride,
            cfaPattern = config.cfaPattern,
            blackLevels = config.blackLevels,
            whiteLevel = config.whiteLevel,
        )
        val whiteBalanceGains = extractWhiteBalanceGains(
            config.colorCorrectionGains,
            config.asShotNeutral,
        )
        val balancedRgb = applyWhiteBalance(cameraRgb, whiteBalanceGains)
        // val fallbackXyz = adaptToD65(multiplyColorMatrix(config.camToXyzMatrix, balancedRgb), D50_WHITE, D65_WHITE)
        val fallbackXyz = multiplyColorMatrix(config.camToXyzMatrix, balancedRgb)
        val xyz = fallbackXyz
        val clamped = DoubleArray(xyz.size) { index -> max(0.0, xyz[index]) }
        return RawPipelineResult(
            cameraRgb = cameraRgb,
            balancedRgb = balancedRgb,
            whiteBalanceGains = whiteBalanceGains,
            xyz = clamped,
            camToXyzMatrix = config.camToXyzMatrix,
            xyzToCamMatrix = config.xyzToCamMatrix,
            colorMatrixSource = config.colorMatrixSource,
            colorMatrixOriginal = config.colorMatrixOriginal,
        )
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
    )

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
            val transposeCcm = true
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
            "rawRect" to (rawRect?.toMap() ?: emptyMap<String, Any?>()),
        )
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

    private data class ChannelAverages(
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

    private fun accumulateRaw(
        rawPath: String,
        roi: Rect,
        rowStride: Int,
        pixelStride: Int,
        cfaPattern: Int,
        blackLevels: List<Int>,
        whiteLevel: Int,
    ): ChannelAverages {
        FileInputStream(rawPath).use { input ->
            val buffer = input.channel.map(
                FileChannel.MapMode.READ_ONLY,
                0,
                input.channel.size(),
            ).order(ByteOrder.LITTLE_ENDIAN)
            val offsetX = roi.left
            val offsetY = roi.top
            val width = roi.width()
            val height = roi.height()
            val accumulators = arrayOf(
                ChannelAccumulator(),
                ChannelAccumulator(),
                ChannelAccumulator(),
                ChannelAccumulator(),
            )
            for (y in 0 until height) {
                val rowBase = (offsetY + y) * rowStride
                for (x in 0 until width) {
                    val column = offsetX + x
                    val index = rowBase + column * pixelStride
                    if (index < 0 || index + 2 > buffer.capacity()) continue
                    val value = buffer.getShort(index).toInt() and 0xFFFF
                    val channel = resolveCfaChannel(cfaPattern, column, offsetY + y)
                    val black = blackLevels.getOrNull(channel) ?: 0
                    val corrected = (value - black).coerceAtLeast(0)
                    val normalized = corrected.toDouble() / whiteLevel.toDouble()
                    accumulators[channel].sum += normalized
                    accumulators[channel].count++
                }
            }
            return ChannelAverages(
                red = accumulators[0].average(),
                greenR = accumulators[1].average(),
                greenB = accumulators[2].average(),
                blue = accumulators[3].average(),
            )
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

    private fun applyWhiteBalance(sample: ChannelAverages, gains: DoubleArray): ChannelAverages {
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

    private fun multiplyColorMatrix(matrix: DoubleArray, sample: ChannelAverages): DoubleArray {
        if (matrix.size < 9) return sample.toRgbVector()
        val vector = sample.toRgbVector()
        val x = matrix[0] * vector[0] + matrix[1] * vector[1] + matrix[2] * vector[2]
        val y = matrix[3] * vector[0] + matrix[4] * vector[1] + matrix[5] * vector[2]
        val z = matrix[6] * vector[0] + matrix[7] * vector[1] + matrix[8] * vector[2]
        return doubleArrayOf(x, y, z)
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

    private fun extractWhiteBalanceGains(
        colorCorrectionGains: DoubleArray?,
        asShotNeutral: DoubleArray?,
    ): DoubleArray {
        if (colorCorrectionGains != null && colorCorrectionGains.isNotEmpty()) {
            val r = colorCorrectionGains.getOrNull(0) ?: 1.0
            val gEven = colorCorrectionGains.getOrNull(1) ?: 1.0
            val gOdd = colorCorrectionGains.getOrNull(2) ?: gEven
            val b = colorCorrectionGains.getOrNull(3) ?: 1.0
            val g = (gEven + gOdd) / 2.0
            return doubleArrayOf(r, g, b)
        }
        val neutral = asShotNeutral ?: doubleArrayOf(1.0, 1.0, 1.0)
        val r = if (neutral.isNotEmpty() && neutral[0] != 0.0) 1.0 / neutral[0] else 1.0
        val g = if (neutral.size > 1 && neutral[1] != 0.0) 1.0 / neutral[1] else 1.0
        val b = if (neutral.size > 2 && neutral[2] != 0.0) 1.0 / neutral[2] else 1.0
        return doubleArrayOf(r, g, b)
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
