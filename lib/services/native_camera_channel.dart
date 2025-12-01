import 'dart:async';
import 'dart:ui';

import 'package:flutter/services.dart';

/// Represents the payload returned by the native camera capture pipeline.
class CameraCaptureResult {
  CameraCaptureResult({
    required this.jpegPath,
    required this.dngPath,
    required this.rawBufferPath,
    required this.metadata,
  });

  factory CameraCaptureResult.fromMap(Map<String, dynamic> map) {
    final metadata = map['metadata'];
    return CameraCaptureResult(
      jpegPath: map['jpegPath'] as String,
      dngPath: map['dngPath'] as String,
      rawBufferPath: map['rawBufferPath'] as String,
      metadata: metadata is Map
          ? Map<String, dynamic>.from(metadata)
          : const {},
    );
  }

  final String jpegPath;
  final String dngPath;
  final String rawBufferPath;
  final Map<String, dynamic> metadata;
}

class CameraRoiResult {
  CameraRoiResult({
    required this.xyz,
    required this.linearRgb,
    required this.rawRgb,
    required this.whiteBalanceGains,
    required this.jpegSrgb,
    required this.jpegLinearRgb,
    required this.jpegXyz,
    required this.camToXyzMatrix,
    required this.xyzToCamMatrix,
    required this.colorMatrixSource,
    required this.debug,
  });

  factory CameraRoiResult.fromMap(Map<String, dynamic> map) {
    return CameraRoiResult(
      xyz: _parseDoubleList(map['xyz']),
      linearRgb: _parseDoubleList(map['linearRgb']),
      rawRgb: _parseDoubleList(map['rawRgb']),
      whiteBalanceGains: _parseDoubleList(map['whiteBalanceGains']),
      jpegSrgb: _parseDoubleList(map['jpegSrgb']),
      jpegLinearRgb: _parseDoubleList(map['jpegLinearRgb']),
      jpegXyz: _parseDoubleList(map['jpegXyz']),
      camToXyzMatrix: _parseDoubleList(map['camToXyzMatrix']),
      xyzToCamMatrix: _parseDoubleList(map['xyzToCamMatrix']),
      colorMatrixSource: (map['colorMatrixSource'] as String?) ?? '',
      debug: _parseDebugPayload(map),
    );
  }

  final List<double> xyz;
  final List<double> linearRgb;
  final List<double> rawRgb;
  final List<double> whiteBalanceGains;
  final List<double> jpegSrgb;
  final List<double> jpegLinearRgb;
  final List<double> jpegXyz;
  final List<double> camToXyzMatrix;
  final List<double> xyzToCamMatrix;
  final String colorMatrixSource;
  final Map<String, dynamic> debug;

  static List<double> _parseDoubleList(dynamic source) {
    if (source is List) {
      return source
          .whereType<num>()
          .map((e) => e.toDouble())
          .toList(growable: false);
    }
    return const [];
  }

  static Map<String, dynamic> _parseDebugPayload(Map<String, dynamic> source) {
    final rawDebug = source['debug'];
    if (rawDebug is Map) {
      return Map<String, dynamic>.from(rawDebug as Map);
    }
    final rawRect = source['rawRect'];
    if (rawRect is Map) {
      return {
        'rawRect': Map<String, dynamic>.from(rawRect as Map),
      };
    }
    return const {};
  }
}

/// Wraps the native MethodChannel that drives the Camera2 JPEG+DNG capture flow.
class NativeCameraChannel {
  NativeCameraChannel._();

  static final NativeCameraChannel instance = NativeCameraChannel._();

  static const MethodChannel _channel = MethodChannel('color_camera');
  Map<String, dynamic> _debugConfig = const <String, dynamic>{};

  static MethodChannel get channel => _channel;

  void updateDebugConfig(Map<String, dynamic> config) {
    _debugConfig = Map<String, dynamic>.from(config);
  }

  Future<CameraCaptureResult> startCapture() async {
    final result = await _channel.invokeMethod<dynamic>('startCapture');
    if (result is! Map) {
      throw PlatformException(
        code: 'invalid-payload',
        message: 'Expected a map from native camera capture, got $result',
      );
    }
    return CameraCaptureResult.fromMap(Map<String, dynamic>.from(result));
  }

  Future<CameraRoiResult> processRoi({
    required CameraCaptureResult capture,
    required Rect normalizedRoi,
    required String mode,
    bool transposeCcm = false,
    List<double>? customCamToXyz,
    bool skipWhiteBalance = false,
    Map<String, dynamic>? debugConfig,
  }) async {
    final payload = {
      'dngPath': capture.dngPath,
      'jpegPath': capture.jpegPath,
      'rawBufferPath': capture.rawBufferPath,
      'metadata': capture.metadata,
      'normalizedRoi': {
        'left': normalizedRoi.left,
        'top': normalizedRoi.top,
        'right': normalizedRoi.right,
        'bottom': normalizedRoi.bottom,
      },
      'mode': mode,
      'transposeCcm': transposeCcm,
      'skipWhiteBalance': skipWhiteBalance,
      if (customCamToXyz != null && customCamToXyz.length >= 9)
        'customCamToXyz': customCamToXyz,
      ..._buildDebugPayload(debugConfig),
    };
    final result = await _channel.invokeMethod<dynamic>('processRoi', payload);
    if (result is! Map) {
      throw PlatformException(
        code: 'invalid-payload',
        message: 'Expected ROI map result, received $result',
      );
    }
    return CameraRoiResult.fromMap(Map<String, dynamic>.from(result));
  }

  Map<String, dynamic> _buildDebugPayload(Map<String, dynamic>? overrides) {
    final merged = <String, dynamic>{..._debugConfig};
    if (overrides != null) {
      merged.addAll(overrides);
    }
    merged.removeWhere((key, value) => value is! bool);
    return merged.isEmpty ? const {} : {'debugConfig': merged};
  }
}
