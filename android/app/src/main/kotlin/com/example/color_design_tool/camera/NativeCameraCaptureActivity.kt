package com.example.color_design_tool.camera

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.DngCreator
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.CaptureFailure
import android.hardware.camera2.params.ColorSpaceTransform
import android.hardware.camera2.params.RggbChannelVector
import android.media.Image
import android.media.ImageReader
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Rational
import android.util.Size
import android.view.Surface
import android.view.TextureView
import android.view.WindowManager
import android.widget.Button
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.example.color_design_tool.R
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference
import kotlin.io.use

class NativeCameraCaptureActivity : AppCompatActivity() {

    companion object {
        const val EXTRA_JPEG_PATH = "jpegPath"
        const val EXTRA_DNG_PATH = "dngPath"
        const val EXTRA_RAW_BUFFER_PATH = "rawBufferPath"
        const val EXTRA_METADATA = "metadata"
        const val EXTRA_ERROR = "error"

        private const val TAG = "NativeCameraCapture"
        private const val REQUEST_CAMERA_PERMISSION = 401
    }

    private lateinit var previewTexture: TextureView
    private lateinit var statusText: TextView
    private lateinit var captureButton: Button
    private lateinit var closeButton: Button

    private lateinit var cameraManager: CameraManager
    private var cameraDevice: CameraDevice? = null
    private var previewSession: CameraCaptureSession? = null
    private var previewRequestBuilder: CaptureRequest.Builder? = null
    private var characteristics: CameraCharacteristics? = null
    private var cameraId: String? = null
    private var previewSize: Size? = null
    private var jpegSize: Size? = null
    private var rawSize: Size? = null
    private var jpegReader: ImageReader? = null
    private var rawReader: ImageReader? = null
    private var backgroundThread: HandlerThread? = null
    private var backgroundHandler: Handler? = null
    private val latestCaptureResult = AtomicReference<TotalCaptureResult?>()
    private val captureLock = Any()
    private var currentCapture = CapturePaths()
    private var hasFinished = false
    private var isCapturing = false
    private val ioExecutor = Executors.newSingleThreadExecutor()

    private val outputDir: File by lazy {
        val base = getExternalFilesDir(Environment.DIRECTORY_PICTURES) ?: filesDir
        File(base, "colorway_camera").apply { if (!exists()) mkdirs() }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(R.layout.activity_native_camera_capture)
        cameraManager = getSystemService(Context.CAMERA_SERVICE) as CameraManager

        previewTexture = findViewById(R.id.previewTexture)
        statusText = findViewById(R.id.statusText)
        captureButton = findViewById(R.id.captureButton)
        closeButton = findViewById(R.id.closeButton)

        previewTexture.surfaceTextureListener = surfaceTextureListener
        captureButton.isEnabled = false
        captureButton.setOnClickListener { takePhoto() }
        closeButton.setOnClickListener { finishWithError("capture_cancelled", "User cancelled capture") }
    }

    override fun onResume() {
        super.onResume()
        startBackgroundThread()
        ensurePermissionAndStart()
    }

    override fun onPause() {
        ioExecutor.shutdown()
        closeCamera()
        stopBackgroundThread()
        super.onPause()
    }

    override fun onDestroy() {
        super.onDestroy()
        closeCamera()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_CAMERA_PERMISSION) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                ensurePermissionAndStart()
            } else {
                finishWithError("camera_permission_denied", "Camera permission is required.")
            }
        }
    }

    private fun ensurePermissionAndStart() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            if (previewTexture.isAvailable) {
                openCamera(previewTexture.width, previewTexture.height)
            } else {
                previewTexture.surfaceTextureListener = surfaceTextureListener
            }
        } else {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.CAMERA), REQUEST_CAMERA_PERMISSION)
        }
    }

    private fun openCamera(width: Int, height: Int) {
        try {
            val selectedId = chooseCameraId()
            if (selectedId == null) {
                finishWithError("raw_not_supported", "No camera with RAW capability found.")
                return
            }
            cameraId = selectedId
            characteristics = cameraManager.getCameraCharacteristics(selectedId)
            setupImageReaders()
            configurePreviewSize(width, height)
            if (ActivityCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
                return
            }
            cameraManager.openCamera(selectedId, stateCallback, backgroundHandler)
            updateStatus("Opening camera…")
        } catch (ex: CameraAccessException) {
            Log.e(TAG, "Failed to open camera", ex)
            finishWithError("camera_access_error", ex.message ?: "Camera access error")
        } catch (ex: Exception) {
            Log.e(TAG, "Unexpected error opening camera", ex)
            finishWithError("camera_open_error", ex.message ?: "Unable to open camera")
        }
    }

    private fun chooseCameraId(): String? {
        val ids = runCatching { cameraManager.cameraIdList }.getOrElse {
            Log.e(TAG, "Unable to list camera IDs", it)
            return null
        }
        ids.forEach { id ->
            val chars = cameraManager.getCameraCharacteristics(id)
            val facing = chars.get(CameraCharacteristics.LENS_FACING)
            val caps = chars.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)
            if (facing == CameraCharacteristics.LENS_FACING_BACK &&
                caps?.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_RAW) == true
            ) {
                return id
            }
        }
        return null
    }

    private fun setupImageReaders() {
        val chars = characteristics ?: return
        val configMap = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val jpegOutputSize = chooseLargest(configMap?.getOutputSizes(ImageFormat.JPEG))
        val rawOutputSize = chooseLargest(configMap?.getOutputSizes(ImageFormat.RAW_SENSOR))
        if (rawOutputSize == null) {
            throw IllegalStateException("RAW capture is not supported by this camera.")
        }
        if (jpegOutputSize == null) {
            throw IllegalStateException("JPEG capture is not supported by this camera.")
        }

        jpegSize = jpegOutputSize
        rawSize = rawOutputSize

        jpegReader?.close()
        rawReader?.close()

        jpegReader = ImageReader.newInstance(jpegOutputSize.width, jpegOutputSize.height, ImageFormat.JPEG, 2).apply {
            setOnImageAvailableListener(jpegListener, backgroundHandler)
        }
        rawReader = ImageReader.newInstance(rawOutputSize.width, rawOutputSize.height, ImageFormat.RAW_SENSOR, 2).apply {
            setOnImageAvailableListener(rawListener, backgroundHandler)
        }
    }

    private fun configurePreviewSize(width: Int, height: Int) {
        val chars = characteristics ?: return
        val config = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val surfaceSizes = config?.getOutputSizes(SurfaceTexture::class.java)
        previewSize = chooseLargest(surfaceSizes) ?: Size(width, height)
    }

    private fun createCameraPreviewSession() {
        val device = cameraDevice ?: return
        val texture = previewTexture.surfaceTexture ?: return
        val previewDimensions = previewSize ?: Size(previewTexture.width, previewTexture.height)
        texture.setDefaultBufferSize(previewDimensions.width, previewDimensions.height)
        val previewSurface = Surface(texture)
        val jpegSurface = jpegReader?.surface
        val rawSurface = rawReader?.surface
        if (jpegSurface == null || rawSurface == null) {
            finishWithError("surface_error", "Image readers not ready.")
            return
        }
        previewRequestBuilder = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
            addTarget(previewSurface)
            set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
        }

        try {
            device.createCaptureSession(
                listOf(previewSurface, jpegSurface, rawSurface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        previewSession = session
                        try {
                            previewRequestBuilder?.build()?.let {
                                session.setRepeatingRequest(it, null, backgroundHandler)
                            }
                            runOnUiThread {
                                captureButton.isEnabled = true
                            }
                            updateStatus("Ready to capture")
                        } catch (ex: CameraAccessException) {
                            Log.e(TAG, "Failed to start preview", ex)
                            finishWithError("preview_error", ex.message ?: "Unable to start preview")
                        }
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        finishWithError("preview_config_error", "Failed to configure camera preview.")
                    }
                },
                backgroundHandler,
            )
        } catch (ex: CameraAccessException) {
            Log.e(TAG, "Error creating preview session", ex)
            finishWithError("preview_session_error", ex.message ?: "Failed to create session")
        }
    }

    private fun takePhoto() {
        if (isCapturing) return
        val device = cameraDevice
        val session = previewSession
        val jpegSurface = jpegReader?.surface
        val rawSurface = rawReader?.surface
        if (device == null || session == null || jpegSurface == null || rawSurface == null) {
            finishWithError("capture_unavailable", "Camera capture not ready.")
            return
        }
        isCapturing = true
        latestCaptureResult.set(null)
        synchronized(captureLock) {
            currentCapture = CapturePaths()
        }
        updateStatus("Capturing…")
        runOnUiThread { captureButton.isEnabled = false }

        try {
            val captureBuilder = device.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE).apply {
                addTarget(jpegSurface)
                addTarget(rawSurface)
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                val orientation = characteristics?.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
                set(CaptureRequest.JPEG_ORIENTATION, orientation)
            }
            session.stopRepeating()
            session.capture(captureBuilder.build(), captureCallback, backgroundHandler)
        } catch (ex: CameraAccessException) {
            Log.e(TAG, "Capture failed", ex)
            finishWithError("capture_failure", ex.message ?: "Failed to capture frame")
        }
    }

    private fun onCaptureComplete(result: TotalCaptureResult) {
        latestCaptureResult.set(result)
        resumePreview()
    }

    private fun resumePreview() {
        try {
            previewRequestBuilder?.build()?.let {
                previewSession?.setRepeatingRequest(it, null, backgroundHandler)
            }
        } catch (ex: CameraAccessException) {
            Log.w(TAG, "Failed to resume preview", ex)
        }
    }

    private fun onJpegReady(image: Image) {
        ioExecutor.execute {
            try {
                val file = saveJpeg(image)
                Log.d(TAG, "JPEG saved to ${file.absolutePath}")
                var shouldFinish = false
                synchronized(captureLock) {
                    currentCapture = currentCapture.copy(jpegPath = file.absolutePath)
                    shouldFinish = currentCapture.isComplete()
                }
                if (shouldFinish) {
                    finishWithSuccess()
                }
            } catch (ex: IOException) {
                Log.e(TAG, "Failed to save JPEG", ex)
                finishWithError("jpeg_write_error", ex.message ?: "JPEG write failed")
            } finally {
                image.close()
            }
        }
    }

    private fun onRawReady(image: Image) {
        ioExecutor.execute {
            try {
                val result = awaitCaptureResult()
                val rawInfo = saveRawPlane(image)
                val file = saveDng(image, result)
                Log.d(TAG, "DNG saved to ${file.absolutePath}")
                var shouldFinish = false
                synchronized(captureLock) {
                    currentCapture = currentCapture.copy(
                        dngPath = file.absolutePath,
                        rawBufferPath = rawInfo.path,
                        rowStride = rawInfo.rowStride,
                        pixelStride = rawInfo.pixelStride,
                    )
                    shouldFinish = currentCapture.isComplete()
                }
                if (shouldFinish) {
                    finishWithSuccess()
                }
            } catch (ex: Exception) {
                Log.e(TAG, "Failed to save DNG", ex)
                finishWithError("dng_write_error", ex.message ?: "DNG write failed")
            } finally {
                image.close()
            }
        }
    }

    private fun awaitCaptureResult(timeoutMs: Long = 2000): TotalCaptureResult {
        val start = System.currentTimeMillis()
        while (System.currentTimeMillis() - start <= timeoutMs) {
            latestCaptureResult.get()?.let { return it }
            Thread.sleep(10)
        }
        return latestCaptureResult.get()
            ?: throw IllegalStateException("Capture metadata unavailable for RAW conversion.")
    }

    private fun finishWithSuccess() {
        if (hasFinished) return
        val capture = synchronized(captureLock) { currentCapture }
        val jpegPath = capture.jpegPath
        val dngPath = capture.dngPath
        val rawPlanePath = capture.rawBufferPath
        if (jpegPath.isNullOrEmpty() || dngPath.isNullOrEmpty() || rawPlanePath.isNullOrEmpty()) {
            return
        }
        hasFinished = true
        isCapturing = false
        updateStatus("Capture complete")
        val metadata = buildMetadataBundle()
        runOnUiThread {
            val data = Intent().apply {
                putExtra(EXTRA_JPEG_PATH, jpegPath)
                putExtra(EXTRA_DNG_PATH, dngPath)
                putExtra(EXTRA_RAW_BUFFER_PATH, rawPlanePath)
                putExtra(EXTRA_METADATA, metadata)
            }
            setResult(Activity.RESULT_OK, data)
            finish()
        }
    }

    private fun finishWithError(code: String, message: String) {
        if (hasFinished) return
        hasFinished = true
        runOnUiThread {
            val data = Intent().apply {
                putExtra(EXTRA_ERROR, "$code|$message")
            }
            setResult(Activity.RESULT_CANCELED, data)
            finish()
        }
    }

    private fun updateStatus(message: String) {
        runOnUiThread { statusText.text = message }
    }

    private fun closeCamera() {
        previewSession?.close()
        previewSession = null
        cameraDevice?.close()
        cameraDevice = null
        jpegReader?.close()
        jpegReader = null
        rawReader?.close()
        rawReader = null
    }

    private fun startBackgroundThread() {
        if (backgroundThread != null) return
        backgroundThread = HandlerThread("CameraBackground").also {
            it.start()
            backgroundHandler = Handler(it.looper)
        }
    }

    private fun stopBackgroundThread() {
        backgroundThread?.quitSafely()
        try {
            backgroundThread?.join()
        } catch (ex: InterruptedException) {
            Log.w(TAG, "Interrupted while stopping background thread", ex)
        }
        backgroundThread = null
        backgroundHandler = null
    }

    private fun chooseLargest(sizes: Array<Size>?): Size? {
        return sizes?.maxByOrNull { it.width.toLong() * it.height }
    }

    private fun saveJpeg(image: Image): File {
        val buffer: ByteBuffer = image.planes[0].buffer
        val bytes = ByteArray(buffer.remaining())
        buffer.get(bytes)
        val file = createOutputFile("jpg")
        FileOutputStream(file).use { it.write(bytes) }
        return file
    }

    private fun saveDng(image: Image, result: TotalCaptureResult): File {
        val chars = characteristics ?: throw IllegalStateException("Missing camera characteristics")
        val file = createOutputFile("dng")
        FileOutputStream(file).use { output ->
            DngCreator(chars, result).use { creator ->
                creator.setDescription("ColorWay Camera Capture")
                creator.writeImage(output, image)
            }
        }
        return file
    }

    private data class RawPlaneInfo(val path: String, val rowStride: Int, val pixelStride: Int)

    private fun saveRawPlane(image: Image): RawPlaneInfo {
        val plane = image.planes.firstOrNull()
            ?: throw IllegalStateException("RAW plane unavailable")
        val buffer = plane.buffer
        buffer.rewind()
        val bytes = ByteArray(buffer.remaining())
        buffer.get(bytes)
        buffer.rewind()
        val file = createOutputFile("raw16")
        FileOutputStream(file).use { it.write(bytes) }
        return RawPlaneInfo(
            path = file.absolutePath,
            rowStride = plane.rowStride,
            pixelStride = plane.pixelStride,
        )
    }

    private fun createOutputFile(extension: String): File {
        val timestamp = System.currentTimeMillis()
        return File(outputDir, "capture_$timestamp.$extension")
    }

    private fun buildMetadataBundle(): Bundle {
        val bundle = Bundle()
        val chars = characteristics
        val activeArray = chars?.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
        if (activeArray != null) {
            bundle.putInt(MetadataKeys.ACTIVE_ARRAY_WIDTH, activeArray.width())
            bundle.putInt(MetadataKeys.ACTIVE_ARRAY_HEIGHT, activeArray.height())
        }
        jpegSize?.let {
            bundle.putInt(MetadataKeys.JPEG_WIDTH, it.width)
            bundle.putInt(MetadataKeys.JPEG_HEIGHT, it.height)
        }
        rawSize?.let {
            bundle.putInt(MetadataKeys.RAW_WIDTH, it.width)
            bundle.putInt(MetadataKeys.RAW_HEIGHT, it.height)
        }
        previewSize?.let {
            bundle.putInt(MetadataKeys.PREVIEW_WIDTH, it.width)
            bundle.putInt(MetadataKeys.PREVIEW_HEIGHT, it.height)
        }
        bundle.putLong(MetadataKeys.TIMESTAMP, System.currentTimeMillis())
        bundle.putString(MetadataKeys.CAMERA_ID, cameraId)
        chars?.get(CameraCharacteristics.SENSOR_ORIENTATION)?.let {
            bundle.putInt(MetadataKeys.SENSOR_ORIENTATION, it)
        }
        chars?.get(CameraCharacteristics.SENSOR_INFO_WHITE_LEVEL)?.let {
            bundle.putInt(MetadataKeys.WHITE_LEVEL, it)
        }
        chars?.get(CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT)?.let {
            bundle.putInt(MetadataKeys.CFA_PATTERN, it)
        }
        chars?.get(CameraCharacteristics.SENSOR_BLACK_LEVEL_PATTERN)?.let { pattern ->
            val arr = IntArray(4)
            pattern.copyTo(arr, 0)
            bundle.putIntArray(MetadataKeys.BLACK_LEVEL_PATTERN, arr)
        }
        chars?.get(CameraCharacteristics.SENSOR_COLOR_TRANSFORM1)?.let {
            val matrix = it.toDoubleArray()
            bundle.putDoubleArray("colorMatrix1", matrix)
            bundle.putDoubleArray(MetadataKeys.SENSOR_COLOR_TRANSFORM1, matrix)
        }
        chars?.get(CameraCharacteristics.SENSOR_COLOR_TRANSFORM2)?.let {
            val matrix = it.toDoubleArray()
            bundle.putDoubleArray("colorMatrix2", matrix)
            bundle.putDoubleArray(MetadataKeys.SENSOR_COLOR_TRANSFORM2, matrix)
        }
        chars?.get(CameraCharacteristics.SENSOR_FORWARD_MATRIX1)?.let {
            val matrix = it.toDoubleArray()
            bundle.putDoubleArray("forwardMatrix1", matrix)
            bundle.putDoubleArray(MetadataKeys.SENSOR_FORWARD_MATRIX1, matrix)
        }
        chars?.get(CameraCharacteristics.SENSOR_FORWARD_MATRIX2)?.let {
            val matrix = it.toDoubleArray()
            bundle.putDoubleArray("forwardMatrix2", matrix)
            bundle.putDoubleArray(MetadataKeys.SENSOR_FORWARD_MATRIX2, matrix)
        }
        chars?.get(CameraCharacteristics.SENSOR_CALIBRATION_TRANSFORM1)?.let {
            bundle.putDoubleArray(MetadataKeys.SENSOR_CALIBRATION_TRANSFORM1, it.toDoubleArray())
        }
        chars?.get(CameraCharacteristics.SENSOR_CALIBRATION_TRANSFORM2)?.let {
            bundle.putDoubleArray(MetadataKeys.SENSOR_CALIBRATION_TRANSFORM2, it.toDoubleArray())
        }
        val referenceIlluminant1 = chars?.get(CameraCharacteristics.SENSOR_REFERENCE_ILLUMINANT1)?.toInt() ?: 17
        val referenceIlluminant2 = chars?.get(CameraCharacteristics.SENSOR_REFERENCE_ILLUMINANT2)?.toInt() ?: 21
        bundle.putInt("referenceIlluminant1", referenceIlluminant1)
        bundle.putInt("referenceIlluminant2", referenceIlluminant2)
        bundle.putInt(MetadataKeys.SENSOR_REFERENCE_ILLUMINANT1, referenceIlluminant1)
        bundle.putInt(MetadataKeys.SENSOR_REFERENCE_ILLUMINANT2, referenceIlluminant2)
        val capture = synchronized(captureLock) { currentCapture }
        capture.rowStride?.let { bundle.putInt(MetadataKeys.ROW_STRIDE, it) }
        capture.pixelStride?.let { bundle.putInt(MetadataKeys.PIXEL_STRIDE, it) }
        capture.rawBufferPath?.let { bundle.putString(MetadataKeys.RAW_BUFFER_PATH, it) }
        latestCaptureResult.get()?.let { result ->
            result.get(CaptureResult.COLOR_CORRECTION_GAINS)?.let {
                bundle.putDoubleArray(MetadataKeys.COLOR_CORRECTION_GAINS, it.toDoubleArray())
            }
            result.get(CaptureResult.COLOR_CORRECTION_TRANSFORM)?.let {
                bundle.putDoubleArray(MetadataKeys.COLOR_CORRECTION_TRANSFORM, it.toDoubleArray())
            }
            result.get(CaptureResult.SENSOR_NEUTRAL_COLOR_POINT)?.let {
                bundle.putDoubleArray(MetadataKeys.AS_SHOT_NEUTRAL, rationalArrayToDouble(it))
            }
        }
        return bundle
    }

    private val surfaceTextureListener = object : TextureView.SurfaceTextureListener {
        override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
            openCamera(width, height)
        }

        override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) = Unit

        override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
            return false
        }

        override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit
    }

    private val stateCallback = object : CameraDevice.StateCallback() {
        override fun onOpened(device: CameraDevice) {
            cameraDevice = device
            createCameraPreviewSession()
        }

        override fun onDisconnected(device: CameraDevice) {
            device.close()
            cameraDevice = null
            finishWithError("camera_disconnected", "Camera disconnected.")
        }

        override fun onError(device: CameraDevice, error: Int) {
            Log.e(TAG, "Camera error: $error")
            device.close()
            cameraDevice = null
            finishWithError("camera_state_error", "Camera state error: $error")
        }
    }

    private val captureCallback = object : CameraCaptureSession.CaptureCallback() {
        override fun onCaptureCompleted(
            session: CameraCaptureSession,
            request: CaptureRequest,
            result: TotalCaptureResult,
        ) {
            onCaptureComplete(result)
        }

        override fun onCaptureFailed(session: CameraCaptureSession, request: CaptureRequest, failure: CaptureFailure) {
            Log.e(TAG, "Capture failed: ${failure.reason}")
            finishWithError("capture_failed", "Camera capture failed: ${failure.reason}")
        }
    }

    private val jpegListener = ImageReader.OnImageAvailableListener { reader ->
        val image = reader.acquireLatestImage() ?: return@OnImageAvailableListener
        onJpegReady(image)
    }

    private val rawListener = ImageReader.OnImageAvailableListener { reader ->
        val image = reader.acquireLatestImage() ?: return@OnImageAvailableListener
        onRawReady(image)
    }

    private data class CapturePaths(
        val jpegPath: String? = null,
        val dngPath: String? = null,
        val rawBufferPath: String? = null,
        val rowStride: Int? = null,
        val pixelStride: Int? = null,
    ) {
        fun isComplete(): Boolean = !jpegPath.isNullOrEmpty() && !dngPath.isNullOrEmpty() && !rawBufferPath.isNullOrEmpty()
    }

    private fun RggbChannelVector.toDoubleArray(): DoubleArray = doubleArrayOf(
        this.red.toDouble(),
        this.greenEven.toDouble(),
        this.greenOdd.toDouble(),
        this.blue.toDouble(),
    )

    private fun ColorSpaceTransform.toDoubleArray(): DoubleArray {
        val result = DoubleArray(9)
        for (row in 0 until 3) {
            for (col in 0 until 3) {
                val idx = row * 3 + col
                val rational = this.getElement(row, col)
                result[idx] = rational.numerator.toDouble() / rational.denominator.toDouble()
            }
        }
        return result
    }

    private fun rationalArrayToDouble(array: Array<Rational>): DoubleArray {
        val doubles = DoubleArray(array.size)
        for (i in array.indices) {
            doubles[i] = array[i].toDouble()
        }
        return doubles
    }
}
