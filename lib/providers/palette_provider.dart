import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math.dart' show Vector3;

// Importing internal modules from the core package.
import 'package:colordesign_tool_core/src/state/palette_manager.dart';
import 'package:colordesign_tool_core/src/models/color_stimulus.dart';
import 'package:colordesign_tool_core/src/algorithms/color_stimuli.dart';
import 'package:colordesign_tool_core/src/io/qtx_parser.dart';
import '../services/persistence.dart';
import '../services/reflectance_service.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

class PaletteProvider extends ChangeNotifier {
  final BufferPaletteManager _manager = BufferPaletteManager();

  // Current sRGB input (0..255)
  int r = 120;
  int g = 120;
  int b = 120;

  int? _focusedIndex;
  int? _pendingReplaceIndex;

  int? get primarySelection => _focusedIndex;
  int? get pendingReplaceIndex => _pendingReplaceIndex;

  PaletteProvider() {
    _init();
  }

  Future<void> _init() async {
    await PaletteStorage.instance.init();
    // Load saved entries and restore into palette
    final raw = PaletteStorage.instance.loadRaw();
    for (final item in raw) {
      final pos = item['position'] as int;
      final stim = mapToStimulus(
        Map<String, dynamic>.from(item['stimulus'] as Map),
      );
      if (pos >= 0 && pos < 20) {
        _manager.addColorToPosition(pos, stim);
      }
    }
    notifyListeners();
  }

  // UI helpers
  Color get previewColor => Color.fromRGBO(r, g, b, 1);
  String get hex =>
      '#'
              '${r.toRadixString(16).padLeft(2, '0')}'
              '${g.toRadixString(16).padLeft(2, '0')}'
              '${b.toRadixString(16).padLeft(2, '0')}'
          .toUpperCase();

  void setR(int value) {
    r = value.clamp(0, 255);
    notifyListeners();
  }

  void setG(int value) {
    g = value.clamp(0, 255);
    notifyListeners();
  }

  void setB(int value) {
    b = value.clamp(0, 255);
    notifyListeners();
  }

  // Palette operations
  ColorStimulus getColorAt(int position) =>
      _manager.getColorAtPosition(position);

  bool isPositionEmpty(int position) => _manager.isPositionEmpty(position);

  void addCurrentColorToNextEmpty() {
    final stimulus = _createStimulusFromCurrentRGB();
    addStimulusToNextEmpty(stimulus, allowReplace: true);
  }

  /// Adds a given [ColorStimulus] to the next empty position.
  /// When [allowReplace] is true and there is a pending replace target,
  /// the stimulus replaces that slot instead.
  int addStimulusToNextEmpty(ColorStimulus stimulus,
      {bool allowReplace = false}) {
    if (allowReplace) {
      final target = _pendingReplaceIndex;
      if (target != null) {
        if (target >= 0 && target < 20) {
          _manager.addColorToPosition(target, stimulus);
          _focusedIndex = target;
        }
        _pendingReplaceIndex = null;
        _persist();
        notifyListeners();
        return target ?? -1;
      }
    }
    final pos = _manager.getNextEmptyPosition();
    if (pos == -1) return -1;
    _manager.addColorToPosition(pos, stimulus);
    _focusNextAvailableSlot();
    _persist();
    notifyListeners();
    return pos;
  }

  void removeAt(int position) {
    if (position < 0 || position >= 20) return;
    _manager.removeColorFromPosition(position);
    if (_focusedIndex == position) {
      _focusedIndex = null;
    }
    if (_pendingReplaceIndex == position) {
      _pendingReplaceIndex = null;
    }
    _persist();
    notifyListeners();
  }

  void replaceColorAt(int position, ColorStimulus stimulus) {
    if (position < 0 || position >= 20) return;
    _manager.addColorToPosition(position, stimulus);
    _focusedIndex = position;
    _persist();
    notifyListeners();
  }

  void selectSingle(int position) {
    if (position < 0 || position >= 20) return;
    _pendingReplaceIndex = null;
    _focusedIndex = position;
    notifyListeners();
  }

  void clear() {
    for (var i = 0; i < 20; i++) {
      if (!isPositionEmpty(i)) {
        _manager.removeColorFromPosition(i);
      }
    }
    _focusedIndex = null;
    _pendingReplaceIndex = null;
    _persist();
    notifyListeners();
  }

  int? beginAdjustSelected() {
    final index = _focusedIndex;
    if (index == null || isPositionEmpty(index)) return null;
    _pendingReplaceIndex = index;
    notifyListeners();
    return index;
  }

  void cancelPendingAdjust(int index) {
    if (_pendingReplaceIndex == index) {
      _pendingReplaceIndex = null;
      notifyListeners();
    }
  }

  void _focusNextAvailableSlot() {
    final next = _manager.getNextEmptyPosition();
    _focusedIndex = next >= 0 ? next : null;
  }

  PaletteMatch? findClosestByDeltaE(Vector3 lab, double threshold) {
    double bestDelta = double.infinity;
    int bestIndex = -1;
    for (var i = 0; i < 20; i++) {
      if (isPositionEmpty(i)) continue;
      final s = _manager.getColorAtPosition(i);
      final appearance = s.appearance;
      if (appearance == null || appearance.lab_value.length < 3) continue;
      final other = Vector3(
        appearance.lab_value[0],
        appearance.lab_value[1],
        appearance.lab_value[2],
      );
      final delta = _deltaE2000(lab, other);
      if (delta < bestDelta) {
        bestDelta = delta;
        bestIndex = i;
      }
    }
    if (bestIndex == -1 || bestDelta > threshold) return null;
    return PaletteMatch(index: bestIndex, deltaE: bestDelta);
  }

  ColorStimulus? get focusedStimulus {
    final index = _focusedIndex;
    if (index == null || isPositionEmpty(index)) return null;
    return _manager.getColorAtPosition(index);
  }

  // Create ColorStimulus from current sRGB (0..255)
  ColorStimulus _createStimulusFromCurrentRGB() {
    final vec = Vector3(r / 255.0, g / 255.0, b / 255.0);
    return srgbToColorstimulus(rgb: vec);
  }

  // Import QTX file and fill next empty slots sequentially
  Future<int> importQtx(String path) async {
    try {
      final stimuli = await createStimuliFromQtx(path);
      int added = 0;
      for (final s in stimuli) {
        final pos = _manager.getNextEmptyPosition();
        if (pos == -1) break;
        _manager.addColorToPosition(pos, s);
        added++;
      }
      if (added > 0) _persist();
      if (added > 0) notifyListeners();
      return added;
    } catch (_) {
      return 0;
    }
  }

  void _persist() {
    final entries = <Map<String, dynamic>>[];
    for (var i = 0; i < 20; i++) {
      if (!isPositionEmpty(i)) {
        final s = _manager.getColorAtPosition(i);
        entries.add({'position': i, 'stimulus': stimulusToMap(s, position: i)});
      }
    }
    PaletteStorage.instance.save(entries);
  }

  double _deltaE2000(Vector3 a, Vector3 b) {
    const double deg2rad = math.pi / 180.0;
    const double pow25to7 = 6103515625.0; // 25^7 for the compensation term

    final l1 = a.x;
    final a1 = a.y;
    final b1 = a.z;
    final l2 = b.x;
    final a2 = b.y;
    final b2 = b.z;

    final c1 = math.sqrt(a1 * a1 + b1 * b1);
    final c2 = math.sqrt(a2 * a2 + b2 * b2);
    final cMean = (c1 + c2) / 2.0;
    final cMean7 = math.pow(cMean, 7).toDouble();
    final g = 0.5 * (1 - math.sqrt(cMean7 / (cMean7 + pow25to7)));

    final a1Prime = (1 + g) * a1;
    final a2Prime = (1 + g) * a2;
    final c1Prime = math.sqrt(a1Prime * a1Prime + b1 * b1);
    final c2Prime = math.sqrt(a2Prime * a2Prime + b2 * b2);

    final h1Prime = _calcHuePrime(b1, a1Prime);
    final h2Prime = _calcHuePrime(b2, a2Prime);

    final deltaLPrime = l2 - l1;
    final deltaCPrime = c2Prime - c1Prime;

    double deltaHuePrime;
    if (c1Prime * c2Prime == 0) {
      deltaHuePrime = 0;
    } else {
      deltaHuePrime = h2Prime - h1Prime;
      if (deltaHuePrime > 180) {
        deltaHuePrime -= 360;
      } else if (deltaHuePrime < -180) {
        deltaHuePrime += 360;
      }
    }
    final deltaHPrime = 2 *
        math.sqrt(c1Prime * c2Prime) *
        math.sin(deltaHuePrime * deg2rad / 2);

    final lMean = (l1 + l2) / 2.0;
    final cPrimeMean = (c1Prime + c2Prime) / 2.0;

    double hMean;
    final hDiff = (h1Prime - h2Prime).abs();
    if (c1Prime * c2Prime == 0) {
      hMean = h1Prime + h2Prime;
    } else if (hDiff <= 180) {
      hMean = (h1Prime + h2Prime) / 2.0;
    } else if (h1Prime + h2Prime < 360) {
      hMean = (h1Prime + h2Prime + 360) / 2.0;
    } else {
      hMean = (h1Prime + h2Prime - 360) / 2.0;
    }

    final t = 1 -
        0.17 * math.cos((hMean - 30) * deg2rad) +
        0.24 * math.cos((2 * hMean) * deg2rad) +
        0.32 * math.cos((3 * hMean + 6) * deg2rad) -
        0.20 * math.cos((4 * hMean - 63) * deg2rad);

    final hMeanOffset = (hMean - 275) / 25.0;
    final deltaTheta = 30 * math.exp(-(hMeanOffset * hMeanOffset));
    final cPrimeMean7 = math.pow(cPrimeMean, 7).toDouble();
    final rc =
        2 * math.sqrt(cPrimeMean7 / (cPrimeMean7 + pow25to7));
    final lMeanDiff = lMean - 50;
    final lMeanDiff2 = lMeanDiff * lMeanDiff;
    final sl = 1 + (0.015 * lMeanDiff2) / math.sqrt(20 + lMeanDiff2);
    final sc = 1 + 0.045 * cPrimeMean;
    final sh = 1 + 0.015 * cPrimeMean * t;
    final rt = -rc * math.sin(2 * deltaTheta * deg2rad);

    final lTerm = deltaLPrime / sl;
    final cTerm = deltaCPrime / sc;
    final hTerm = deltaHPrime / sh;

    return math.sqrt(
      lTerm * lTerm + cTerm * cTerm + hTerm * hTerm + rt * cTerm * hTerm,
    );
  }

  double _calcHuePrime(double b, double aPrime) {
    if (aPrime == 0 && b == 0) {
      return 0;
    }
    final hue = math.atan2(b, aPrime) * 180 / math.pi;
    return hue >= 0 ? hue : hue + 360;
  }

  // Export current non-empty palette to app documents directory, returns file path
  Future<String?> exportQtx() async {
    final stimuli = <ColorStimulus>[];
    for (var i = 0; i < 20; i++) {
      if (!isPositionEmpty(i)) {
        stimuli.add(_manager.getColorAtPosition(i));
      }
    }
    if (stimuli.isEmpty) return null;

    final reflectanceService = ReflectanceService();
    final enriched = stimuli
        .map((stimulus) => reflectanceService.ensureSpectralData(stimulus))
        .toList(growable: false);

    final dir = await getApplicationDocumentsDirectory();
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    final path = '${dir.path}${Platform.pathSeparator}palette_$ts.qtx';
    await saveStimuliToQtx(path, enriched);
    return path;
  }

  @override
  void dispose() {
    PaletteStorage.instance.dispose();
    super.dispose();
  }
}

class PaletteMatch {
  PaletteMatch({required this.index, required this.deltaE});
  final int index;
  final double deltaE;
}
