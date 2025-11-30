import 'dart:io';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:colordesign_tool_core/src/models/color_stimulus.dart';

class PaletteStorage {
  static final PaletteStorage instance = PaletteStorage._();
  PaletteStorage._();

  static const String _boxName = 'cdt_palette';
  static const String _key = 'palette_v1';

  Box? _box;
  bool _hiveInitialized = false;
  final bool _useInMemoryStore =
      Platform.environment.containsKey('FLUTTER_TEST');
  List<Map<String, dynamic>> _memoryEntries = [];

  Future<void> init() async {
    if (_useInMemoryStore) {
      return;
    }
    if (_box != null) return;
    if (!_hiveInitialized) {
      await Hive.initFlutter();
      _hiveInitialized = true;
    }
    _box = await Hive.openBox(_boxName);
  }

  Future<void> dispose() async {
    if (_useInMemoryStore) {
      _memoryEntries = [];
      return;
    }
    if (_box != null) {
      await _box!.close();
      _box = null;
    }
    if (_hiveInitialized) {
      await Hive.close();
    }
  }

  Future<void> save(List<Map<String, dynamic>> entries) async {
    if (_useInMemoryStore) {
      _memoryEntries =
          entries.map((e) => Map<String, dynamic>.from(e)).toList(growable: false);
      return;
    }
    await _box?.put(_key, entries);
  }

  List<Map<String, dynamic>> loadRaw() {
    if (_useInMemoryStore) {
      return _memoryEntries
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
    }
    final data = _box?.get(_key);
    if (data is List) {
      return data.cast<Map>().map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    return [];
  }
}

// --- Simple manual serialization for ColorStimulus and nested types ---

Map<String, dynamic> stimulusToMap(ColorStimulus s, {required int position}) {
  return {
    'position': position,
    'id': s.id,
    'u_name': s.u_name,
    'source': {
      'type': s.source.type,
      'origin_identifier': s.source.origin_identifier,
      's_name': s.source.s_name,
    },
    'scientific_core': {
      'xyz_value': s.scientific_core.xyz_value,
      'observer_angle': s.scientific_core.observer_angle,
      'reference_white_xyz': s.scientific_core.reference_white_xyz,
      'adapting_luminance_La': s.scientific_core.adapting_luminance_La,
      'background_luminance_Yb': s.scientific_core.background_luminance_Yb,
      'surround_condition': s.scientific_core.surround_condition,
    },
    'appearance': s.appearance == null
        ? null
        : {
            'lab_value': s.appearance!.lab_value,
            'JCh': s.appearance!.JCh,
            'NCS_name': s.appearance!.NCS_name,
            'depth_description': s.appearance!.depth_description,
            'classification': s.appearance!.classification,
          },
    'display_representations': s.display_representations.map((k, v) => MapEntry(k, {
          'color_space_name': v.color_space_name,
          'rgb_values': v.rgb_values,
          'is_out_of_gamut': v.is_out_of_gamut,
        })),
    'metadata': s.metadata,
  };
}

ColorStimulus mapToStimulus(Map<String, dynamic> m) {
  final source = SourceInfo(
    type: m['source']['type'] as String,
    origin_identifier: m['source']['origin_identifier'] as String?,
    s_name: m['source']['s_name'] as String?,
  );
  final sci = ScientificData(
    xyz_value: (m['scientific_core']['xyz_value'] as List).cast<double>(),
    observer_angle: m['scientific_core']['observer_angle'] as int,
    reference_white_xyz: (m['scientific_core']['reference_white_xyz'] as List).cast<double>(),
    adapting_luminance_La: (m['scientific_core']['adapting_luminance_La'] as num).toDouble(),
    background_luminance_Yb: (m['scientific_core']['background_luminance_Yb'] as num).toDouble(),
    surround_condition: m['scientific_core']['surround_condition'] as String,
  );
  AppearanceData? app;
  if (m['appearance'] != null) {
    final a = m['appearance'] as Map<String, dynamic>;
    app = AppearanceData(
      lab_value: (a['lab_value'] as List).cast<double>(),
      JCh: (a['JCh'] as List).cast<double>(),
      NCS_name: a['NCS_name'] as String,
      depth_description: a['depth_description'] as String,
      classification: a['classification'] as String,
    );
  }
  final disp = <String, DisplayRepresentation>{};
  (m['display_representations'] as Map<String, dynamic>).forEach((k, v) {
    final mv = v as Map;
    disp[k] = DisplayRepresentation(
      color_space_name: mv['color_space_name'] as String,
      rgb_values: (mv['rgb_values'] as List).cast<double>(),
      is_out_of_gamut: mv['is_out_of_gamut'] as bool,
    );
  });

  return ColorStimulus(
    id: m['id'] as String?,
    u_name: m['u_name'] as String?,
    source: source,
    scientific_core: sci,
    appearance: app,
    display_representations: disp,
    metadata: Map<String, dynamic>.from(m['metadata'] as Map),
  );
}
