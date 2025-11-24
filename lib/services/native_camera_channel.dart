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
      debug: map['rawRect'] is Map
          ? Map<String, dynamic>.from(map['rawRect'] as Map)
          : const {},
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
}

/// Wraps the native MethodChannel that drives the Camera2 JPEG+DNG capture flow.
class NativeCameraChannel {
  NativeCameraChannel._();

  static final NativeCameraChannel instance = NativeCameraChannel._();

  static const MethodChannel _channel = MethodChannel('color_camera');

  static MethodChannel get channel => _channel;

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
}
