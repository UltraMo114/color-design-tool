import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math.dart' show Vector3;

// Importing internal modules from the core package.
import 'package:colordesign_tool_core/src/state/palette_manager.dart';
import 'package:colordesign_tool_core/src/models/color_stimulus.dart';
import 'package:colordesign_tool_core/src/algorithms/color_stimuli.dart';
import 'package:colordesign_tool_core/src/io/qtx_parser.dart';
import '../services/persistence.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

class PaletteProvider extends ChangeNotifier {
  final BufferPaletteManager _manager = BufferPaletteManager();

  // Current sRGB input (0..255)
  int r = 120;
  int g = 120;
  int b = 120;

  int? _focusedIndex;

  int? get primarySelection => _focusedIndex;

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
    final pos = _manager.getNextEmptyPosition();
    if (pos == -1) return;
    final stimulus = _createStimulusFromCurrentRGB();
    _manager.addColorToPosition(pos, stimulus);
    _focusedIndex = pos;
    _persist();
    notifyListeners();
  }

  /// Adds a given [ColorStimulus] to the next empty position. Returns position or -1.
  int addStimulusToNextEmpty(ColorStimulus stimulus) {
    final pos = _manager.getNextEmptyPosition();
    if (pos == -1) return -1;
    _manager.addColorToPosition(pos, stimulus);
    _focusedIndex = pos;
    _persist();
    notifyListeners();
    return pos;
  }

  void removeAt(int position) {
    _manager.removeColorFromPosition(position);
    if (_focusedIndex == position) {
      _focusedIndex = null;
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
    if (position < 0 || position >= 20 || isPositionEmpty(position)) return;
    _focusedIndex = position;
    notifyListeners();
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
      final delta = _deltaE76(lab, other);
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

  double _deltaE76(Vector3 a, Vector3 b) {
    final dl = a.x - b.x;
    final da = a.y - b.y;
    final db = a.z - b.z;
    return math.sqrt(dl * dl + da * da + db * db);
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

    final dir = await getApplicationDocumentsDirectory();
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    final path = '${dir.path}${Platform.pathSeparator}palette_$ts.qtx';
    await saveStimuliToQtx(path, stimuli);
    return path;
  }
}

class PaletteMatch {
  PaletteMatch({required this.index, required this.deltaE});
  final int index;
  final double deltaE;
}
