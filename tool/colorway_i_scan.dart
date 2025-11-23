import 'dart:io';
import 'dart:math' as math;

import 'package:colordesign_tool_core/src/common/util.dart';
import 'package:colordesign_tool_core/src/utils/config.dart';
import 'package:colordesign_tool_core/src/utils/display_model.dart';
import 'package:vector_math/vector_math.dart';

const int _cells = 5;
const int _step = 3;
const double _abRange = 2.0 * _step;
const List<double> _iSamples = [0.0, 50.0, 75.0];
final _display = DisplayModel('srgb');

double _jFromI(double i) {
  final params = scamSurroundParams[globalViewingConditions.surround.toLowerCase()];
  if (params == null) {
    throw ArgumentError('Unsupported surround: ${globalViewingConditions.surround}');
  }
  final n = globalViewingConditions.yb / globalViewingConditions.xyzw.y;
  final z = 1.48 + math.sqrt(n);
  final ratio = (i / 100.0).clamp(0.0, 1.0);
  if (ratio == 0) return 0.0;
  return 100.0 * math.pow(ratio, params.c * z);
}

bool _isOutOfGamut(Vector3 rgb) {
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

String _fmt(double value) => value.toStringAsFixed(12);

void _writeCsv(double iValue) {
  final j = _jFromI(iValue);
  final fileName = 'tool/colorway_I${iValue.toStringAsFixed(0)}.csv';
  final file = File(fileName)..createSync(recursive: true);
  final sink = file.openWrite();
  sink.writeln([
    'I',
    'J',
    'ix',
    'iy',
    'a',
    'b',
    'C',
    'h',
    'X',
    'Y',
    'Z',
    'rgb_r',
    'rgb_g',
    'rgb_b',
    'is_out_of_gamut',
  ].join(','));

  for (var iy = 0; iy < _cells; iy++) {
    for (var ix = 0; ix < _cells; ix++) {
      final nx = ((ix + 0.5) / _cells) * 2 - 1;
      final ny = (1 - (iy + 0.5) / _cells) * 2 - 1;
      final a = nx * _abRange;
      final b = ny * _abRange;
      final c = math.sqrt(a * a + b * b);
      double h = c == 0 ? 0.0 : math.atan2(b, a) * 180.0 / math.pi;
      if (h < 0) h += 360.0;

      final xyz = scamToXyz(
        jch: Vector3(j, c, h),
        xyz_w: globalViewingConditions.xyzw,
        y_b: globalViewingConditions.yb,
        l_a: globalViewingConditions.la,
        surround: globalViewingConditions.surround,
      );
      final rgb = _display.xyzToRgb(xyz);
      final oog = _isOutOfGamut(rgb);

      sink.writeln([
        _fmt(iValue),
        _fmt(j),
        '$ix',
        '$iy',
        _fmt(a),
        _fmt(b),
        _fmt(c),
        _fmt(h),
        _fmt(xyz.x),
        _fmt(xyz.y),
        _fmt(xyz.z),
        _fmt(rgb.x),
        _fmt(rgb.y),
        _fmt(rgb.z),
        oog.toString(),
      ].join(','));
    }
  }

  sink.close();
  print('I=$iValue → $fileName (${_cells * _cells} rows)');
}

Future<void> main() async {
  for (final i in _iSamples) {
    _writeCsv(i);
  }
}
