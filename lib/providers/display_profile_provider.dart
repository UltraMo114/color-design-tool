import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math.dart' show Vector3;

import 'package:colordesign_tool_core/src/utils/display_model.dart';
import 'package:colordesign_tool_core/src/utils/gog_display_model.dart';
import 'package:colordesign_tool_core/src/models/color_stimulus.dart';

enum DisplayProfileType { srgb, calibrated }

/// App-wide color display mapping profile manager.
/// - Provides sRGB and Calibrated (GOG) profiles.
/// - Optionally enforces a fixed system brightness while active.
class DisplayProfileProvider extends ChangeNotifier {
  DisplayProfileProvider() {
    // Default to sRGB profile and apply default brightness policy.
    // Errors from platform brightness are non-fatal.
    unawaited(_init());
  }

  final DisplayModel _srgbModel = DisplayModel('srgb');
  GogDisplayModel? _gogModel;
  String? _gogError;

  DisplayProfileType _type = DisplayProfileType.srgb;

  // Brightness control
  bool _controlBrightness = true;
  double _brightnessLevel = 0.7; // 70% by default

  // Shared platform channel used elsewhere in the app
  static const MethodChannel _channel = MethodChannel('color_camera');

  DisplayProfileType get type => _type;
  bool get controlBrightness => _controlBrightness;
  double get brightnessLevel => _brightnessLevel;
  GogDisplayModel? get gogModel => _gogModel;
  String? get gogError => _gogError;

  /// Load calibrated GOG profile from bundled assets (CSV).
  Future<void> loadCalibratedFromAssets() async {
    try {
      final raw = await rootBundle.loadString('assets/display_gog_model.csv');
      _gogModel = GogDisplayModel.fromCsvString(raw);
      _gogError = null;
    } catch (e) {
      _gogModel = null;
      _gogError = e.toString();
    }
  }

  Future<void> _init() async {
    await loadCalibratedFromAssets();
    if (_gogModel != null) {
      _type = DisplayProfileType.calibrated;
    }
    await _applyBrightness();
    notifyListeners();
  }

  /// Switch current profile. When selecting calibrated, ensures model is loaded.
  Future<void> setType(DisplayProfileType next) async {
    if (next == DisplayProfileType.calibrated && _gogModel == null) {
      await loadCalibratedFromAssets();
    }
    // Fallback to sRGB if calibrated failed to load
    _type = (next == DisplayProfileType.calibrated && _gogModel == null)
        ? DisplayProfileType.srgb
        : next;
    await _applyBrightness();
    notifyListeners();
  }

  /// Enable/disable fixed brightness and/or change the level (0..1).
  Future<void> setBrightnessControl({required bool enable, double? level}) async {
    _controlBrightness = enable;
    if (level != null) {
      _brightnessLevel = level.clamp(0.0, 1.0);
    }
    await _applyBrightness();
    notifyListeners();
  }

  /// Applies the brightness policy through the platform channel.
  Future<void> _applyBrightness() async {
    try {
      if (_controlBrightness) {
        await _channel.invokeMethod('setFixedBrightness', _brightnessLevel);
      } else {
        await _channel.invokeMethod('setFixedBrightness', null);
      }
    } catch (_) {
      // Ignore on unsupported platforms.
    }
  }

  /// Map XYZ (0..100) to non-linear RGB codes (0..1) using the active profile.
  Vector3 mapXyzToRgb(Vector3 xyz) {
    if (_type == DisplayProfileType.calibrated && _gogModel != null) {
      return _gogModel!.xyzToRgb(xyz);
    }
    return _srgbModel.xyzToRgb(xyz);
  }

  /// Convenience: compute a Flutter Color for given ColorStimulus using active profile.
  Color colorForStimulus(ColorStimulus s) {
    final v = s.scientific_core.xyz_value;
    final xyz = Vector3(v[0], v[1], v[2]);
    final rgb = mapXyzToRgb(xyz);
    final clamped = rgb.clone()..clamp(Vector3.zero(), Vector3.all(1.0));
    return Color.fromRGBO(
      (clamped.x * 255).round(),
      (clamped.y * 255).round(),
      (clamped.z * 255).round(),
      1,
    );
  }

  /// True if any channel is outside [0,1] or NaN.
  bool isOutOfGamut(Vector3 rgb) {
    return rgb.x.isNaN ||
        rgb.y.isNaN ||
        rgb.z.isNaN ||
        rgb.x <= 0 ||
        rgb.y <= 0 ||
        rgb.z <= 0 ||
        rgb.x > 1 ||
        rgb.y > 1 ||
        rgb.z > 1;
  }
}
