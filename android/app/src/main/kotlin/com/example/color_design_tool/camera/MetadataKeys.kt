package com.example.color_design_tool.camera

/**
 * Centralized keys for the metadata Bundle produced by NativeCameraCaptureActivity
 * and consumed by RawRoiProcessor. Keep these synchronized with both sides.
 *
 * All dimensions are in pixels unless otherwise noted.
 */
object MetadataKeys {
    // Active sensor array size (CameraCharacteristics)
    const val ACTIVE_ARRAY_WIDTH = "activeArrayWidth"
    const val ACTIVE_ARRAY_HEIGHT = "activeArrayHeight"

    // Captured JPEG size
    const val JPEG_WIDTH = "jpegWidth"
    const val JPEG_HEIGHT = "jpegHeight"

    // Captured RAW size (RAW_SENSOR stream)
    const val RAW_WIDTH = "rawWidth"
    const val RAW_HEIGHT = "rawHeight"

    // Preview (TextureView) size
    const val PREVIEW_WIDTH = "previewWidth"
    const val PREVIEW_HEIGHT = "previewHeight"

    // General properties
    const val TIMESTAMP = "timestamp"                // Unix millis
    const val CAMERA_ID = "cameraId"
    const val SENSOR_ORIENTATION = "sensorOrientation" // degrees 0/90/180/270

    // RAW sensor configuration
    const val WHITE_LEVEL = "whiteLevel"             // 16-bit white level
    const val CFA_PATTERN = "cfaPattern"             // CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT
    const val BLACK_LEVEL_PATTERN = "blackLevelPattern" // int[4] order: R, Gr, Gb, B

    // RAW plane buffer layout
    const val ROW_STRIDE = "rowStride"
    const val PIXEL_STRIDE = "pixelStride"
    const val RAW_BUFFER_PATH = "rawBufferPath"       // .raw16 file path

    // Per-capture white balance and color transforms
    const val COLOR_CORRECTION_GAINS = "colorCorrectionGains"       // [r, gEven, gOdd, b]
    const val COLOR_CORRECTION_TRANSFORM = "colorCorrectionTransform" // 3x3 row-major double[9]
    const val AS_SHOT_NEUTRAL = "asShotNeutral"       // [r, g, b] reciprocal gains

    // Static camera matrices (from CameraCharacteristics) exposed for debugging/logging
    const val SENSOR_FORWARD_MATRIX1 = "sensorForwardMatrix1"       // FloatArray (3x3)
    const val SENSOR_FORWARD_MATRIX2 = "sensorForwardMatrix2"       // FloatArray (3x3)
    const val SENSOR_COLOR_TRANSFORM1 = "sensorColorTransform1"     // FloatArray (3x3) - fallback
    const val SENSOR_COLOR_TRANSFORM2 = "sensorColorTransform2"     // FloatArray (3x3) - fallback
    const val SENSOR_REFERENCE_ILLUMINANT1 = "sensorReferenceIlluminant1" // Int (e.g., 17 for StdA)
    const val SENSOR_REFERENCE_ILLUMINANT2 = "sensorReferenceIlluminant2" // Int (e.g., 21 for D65)
    const val SENSOR_CALIBRATION_TRANSFORM1 = "sensorCalibrationTransform1" // FloatArray (3x3) - Optional
    const val SENSOR_CALIBRATION_TRANSFORM2 = "sensorCalibrationTransform2" // FloatArray (3x3) - Optional
}
