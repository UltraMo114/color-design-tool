import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:colordesign_tool_core/src/io/qtx_parser.dart';
import 'package:colordesign_tool_core/src/models/color_stimulus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ColorLibrarySource {
  const ColorLibrarySource({
    required this.id,
    required this.path,
    this.enabled = true,
  });

  final String id;
  final String path;
  final bool enabled;
}

class ColorLibraryMatch {
  ColorLibraryMatch({
    required this.stimulus,
    required this.deltaE,
    required this.libraryId,
  });

  final ColorStimulus stimulus;
  final double deltaE;
  final String libraryId;
}

class _LibraryEntry {
  _LibraryEntry({
    required this.stimulus,
    required this.libraryId,
    required this.l,
    required this.a,
    required this.b,
  });

  final ColorStimulus stimulus;
  final String libraryId;
  final double l;
  final double a;
  final double b;
}

/// Simple in-memory color library backed by one or more QTX files.
///
/// This service keeps the parsed [ColorStimulus] objects and their Lab
/// coordinates in memory and provides ΔE76 search over the combined set.
class ColorLibraryService {
  ColorLibraryService({required List<ColorLibrarySource> sources})
      : _sources = List.unmodifiable(sources);

  /// Convenience factory that wires in a fixed set of preset QTX files
  /// under `../ColorDesignTool/preset_qtx`.
  ///
  /// This is primarily for development and can be extended later to support
  /// user-specified libraries.
  factory ColorLibraryService.withPresetQtx() {
    const base = '../ColorDesignTool/preset_qtx';
    return ColorLibraryService(
      sources: const [
        ColorLibrarySource(
          id: 'sCAM_JCH_250',
          path: '$base/sCAM_JCH_250colors.QTX',
        ),
        ColorLibrarySource(
          id: 'sCAM_JCh_ab_61',
          path: '$base/sCAM_JCh_ab_61colors.QTX',
        ),
        ColorLibrarySource(
          id: 'final_DCh',
          path: '$base/final_DCh_colors.QTX',
        ),
        ColorLibrarySource(
          id: 'H_plane_10deg_250',
          path: '$base/H_plane_10deg_250colors_from_YP.QTX',
        ),
      ],
    );
  }

  /// Factory that loads QTX files bundled as Flutter assets under `assets/qtx/`.
  ///
  /// Uses a lazy copy-once strategy: on first load, each asset is copied to the
  /// application documents directory (under `qtx/`) and then read from there
  /// using the existing file-based parser.
  factory ColorLibraryService.withBundledQtx() {
    // Keep the list in sync with pubspec assets (assets/qtx/...).
    // Use stable IDs without spaces for display grouping.
    return ColorLibraryService(
      sources: const [
        ColorLibrarySource(
          id: 'Munsell_1560',
          path: 'asset:assets/qtx/Munsell_1560colors.QTX',
        ),
        ColorLibrarySource(
          id: 'NCS_1749',
          path: 'asset:assets/qtx/NCS_1749colors.QTX',
        ),
        ColorLibrarySource(
          id: 'Pantone_Polyester_1925',
          path: 'asset:assets/qtx/Pantone polyester1925colors.QTX',
        ),
        ColorLibrarySource(
          id: 'Color2',
          path: 'asset:assets/qtx/color2.qtx',
        ),
      ],
    );
  }

  final List<ColorLibrarySource> _sources;
  final List<_LibraryEntry> _entries = [];

  bool _loaded = false;
  String? _lastError;
  Future<void>? _loadingFuture;

  bool get isLoaded => _loaded;

  String? get lastError => _lastError;

  int get entryCount => _entries.length;

  List<ColorLibrarySource> get sources => _sources;

  /// Ensures that all configured sources are parsed and available in memory.
  ///
  /// Safe to call multiple times; concurrent callers share the same load
  /// operation.
  Future<void> ensureLoaded() {
    if (_loaded) {
      return Future<void>.value();
    }
    final existing = _loadingFuture;
    if (existing != null) {
      return existing;
    }
    final future = _loadInternal();
    _loadingFuture = future;
    future.whenComplete(() {
      _loadingFuture = null;
    });
    return future;
  }

  Future<void> _loadInternal() async {
    if (_loaded) {
      return;
    }
    _lastError = null;
    _entries.clear();

    try {
      for (final src in _sources.where((s) => s.enabled)) {
        final effectivePath = await _resolvePath(src.path);
        final stimuli = await createStimuliFromQtx(effectivePath);
        if (stimuli.isEmpty) {
          debugPrint(
            'ColorLibraryService: no entries loaded from ${src.path}',
          );
          continue;
        }
        for (final s in stimuli) {
          final lab = s.appearance?.lab_value;
          if (lab == null || lab.length < 3) {
            continue;
          }
          _entries.add(
            _LibraryEntry(
              stimulus: s,
              libraryId: src.id,
              l: lab[0],
              a: lab[1],
              b: lab[2],
            ),
          );
        }
        debugPrint(
          'ColorLibraryService: loaded ${stimuli.length} colors from ${src.id}',
        );
      }
      _loaded = true;
      debugPrint(
        'ColorLibraryService: total loaded entries = ${_entries.length}',
      );
    } catch (e, stack) {
      _lastError = e.toString();
      debugPrint('ColorLibraryService: failed to load libraries: $e');
      debugPrint('$stack');
      rethrow;
    }
  }

  /// Returns all colors from the library whose CIELAB ΔE76 distance from
  /// [target] is less than or equal to [threshold].
  ///
  /// Colors are sorted by increasing ΔE. If [limit] is provided and the
  /// number of matches exceeds it, only the closest [limit] matches are
  /// returned.
  ///
  /// [ensureLoaded] must be called successfully before using this method.
  List<ColorLibraryMatch> findMatches({
    required ColorStimulus target,
    required double threshold,
    int? limit,
  }) {
    if (!_loaded) {
      throw StateError(
        'ColorLibraryService.findMatches called before libraries were loaded.',
      );
    }

    final lab = target.appearance?.lab_value;
    if (lab == null || lab.length < 3) {
      return const [];
    }
    final l0 = lab[0];
    final a0 = lab[1];
    final b0 = lab[2];

    if (threshold <= 0) {
      return const [];
    }
    final thr2 = threshold * threshold;

    final matches = <ColorLibraryMatch>[];
    for (final entry in _entries) {
      final dl = entry.l - l0;
      final da = entry.a - a0;
      final db = entry.b - b0;
      final dist2 = dl * dl + da * da + db * db;
      if (dist2 <= thr2) {
        matches.add(
          ColorLibraryMatch(
            stimulus: entry.stimulus,
            deltaE: math.sqrt(dist2),
            libraryId: entry.libraryId,
          ),
        );
      }
    }

    matches.sort((a, b) => a.deltaE.compareTo(b.deltaE));
    if (limit != null && limit > 0 && matches.length > limit) {
      return matches.sublist(0, limit);
    }
    return matches;
  }

  /// Resolves a configured source path to a concrete local file path.
  ///
  /// - If the path starts with `asset:` it copies the asset to
  ///   `<app-documents>/qtx/<basename>` on first use and returns that path.
  /// - Otherwise returns the path unchanged.
  Future<String> _resolvePath(String configuredPath) async {
    const prefix = 'asset:';
    if (!configuredPath.startsWith(prefix)) {
      return configuredPath;
    }
    final assetKey = configuredPath.substring(prefix.length);

    // Determine destination path under app documents/qtx/
    final docsDir = await getApplicationDocumentsDirectory();
    final targetDir = Directory(p.join(docsDir.path, 'qtx'));
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }
    final fileName = p.basename(assetKey);
    final outPath = p.join(targetDir.path, fileName);
    final outFile = File(outPath);
    if (!await outFile.exists()) {
      try {
        final data = await rootBundle.load(assetKey);
        await outFile.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      } catch (e) {
        debugPrint('ColorLibraryService: failed to materialize asset $assetKey: $e');
        rethrow;
      }
    }
    return outPath;
  }
}
