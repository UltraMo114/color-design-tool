package com.example.color_design_tool

import android.app.Activity
import android.content.Intent
import android.view.WindowManager
import android.os.Bundle
import com.example.color_design_tool.camera.NativeCameraCaptureActivity
import com.example.color_design_tool.camera.RawRoiProcessor
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

  private val cameraChannelName = "color_camera"
  private val cameraRequestCode = 0xCC01
  private var pendingResult: MethodChannel.Result? = null
  private val roiExecutor = Executors.newSingleThreadExecutor()

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, cameraChannelName).setMethodCallHandler(::onMethodCall)
  }

  override fun onDestroy() {
    super.onDestroy()
    roiExecutor.shutdown()
  }

  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
    super.onActivityResult(requestCode, resultCode, data)
    if (requestCode != cameraRequestCode) {
      return
    }
    val callback = pendingResult ?: return
    pendingResult = null
    if (resultCode == Activity.RESULT_OK) {
      val jpegPath = data?.getStringExtra(NativeCameraCaptureActivity.EXTRA_JPEG_PATH)
      val dngPath = data?.getStringExtra(NativeCameraCaptureActivity.EXTRA_DNG_PATH)
      val rawBufferPath = data?.getStringExtra(NativeCameraCaptureActivity.EXTRA_RAW_BUFFER_PATH)
      if (jpegPath.isNullOrEmpty() || dngPath.isNullOrEmpty() || rawBufferPath.isNullOrEmpty()) {
        callback.error("invalid_native_result", "Native camera returned empty file paths.", null)
      } else {
        callback.success(
          mapOf(
            "jpegPath" to jpegPath,
            "dngPath" to dngPath,
            "rawBufferPath" to rawBufferPath,
            "metadata" to bundleToMap(data?.getBundleExtra(NativeCameraCaptureActivity.EXTRA_METADATA)),
          ),
        )
      }
    } else {
      val message = data?.getStringExtra(NativeCameraCaptureActivity.EXTRA_ERROR) ?: "capture_cancelled|Capture cancelled"
      val parts = message.split("|", limit = 2)
      val code = parts.firstOrNull().orEmpty().ifEmpty { "capture_cancelled" }
      val errorMessage = parts.getOrNull(1) ?: "Capture cancelled"
      callback.error(code, errorMessage, null)
    }
  }

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "startCapture" -> launchCameraCapture(result)
      "processRoi" -> handleProcessRoi(call, result)
      "setFixedBrightness" -> handleSetFixedBrightness(call, result)
      else -> result.notImplemented()
    }
  }

  private fun launchCameraCapture(result: MethodChannel.Result) {
    if (pendingResult != null) {
      result.error("capture_in_progress", "A capture request is already pending.", null)
      return
    }
    val intent = Intent(this, NativeCameraCaptureActivity::class.java)
    pendingResult = result
    runCatching {
      startActivityForResult(intent, cameraRequestCode)
    }.onFailure {
      pendingResult = null
      result.error("launch_failed", it.message, null)
    }
  }

  private fun handleProcessRoi(call: MethodCall, result: MethodChannel.Result) {
    val args = call.arguments as? Map<*, *>
    if (args == null) {
      result.error("invalid_arguments", "Expected a map payload.", null)
      return
    }
    roiExecutor.execute {
      runCatching {
        RawRoiProcessor(applicationContext, args).process()
      }.onSuccess {
        runOnUiThread { result.success(it) }
      }.onFailure {
        runOnUiThread { result.error("roi_processing_failed", it.message, null) }
      }
    }
  }

  private fun handleSetFixedBrightness(call: MethodCall, result: MethodChannel.Result) {
    val levelAny = call.arguments
    val brightness = when (levelAny) {
      null -> null
      is Number -> levelAny.toFloat().coerceIn(0.0f, 1.0f)
      else -> null
    }
    val lp = window.attributes
    lp.screenBrightness = brightness ?: WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
    window.attributes = lp
    result.success(null)
  }

  private fun bundleToMap(bundle: Bundle?): Map<String, Any?> {
    if (bundle == null) return emptyMap()
    val map = mutableMapOf<String, Any?>()
    for (key in bundle.keySet()) {
      when (val value = bundle.get(key)) {
        is IntArray -> map[key] = value.map { it }
        is DoubleArray -> map[key] = value.map { it }
        else -> map[key] = value
      }
    }
    return map
  }
}
