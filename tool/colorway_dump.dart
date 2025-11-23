import 'dart:io';
import 'dart:math' as math;

import 'package:colordesign_tool_core/src/common/util.dart';
import 'package:colordesign_tool_core/src/utils/config.dart';
import 'package:colordesign_tool_core/src/utils/display_model.dart';
import 'package:vector_math/vector_math.dart';

const int _cells = 5;
const int _step = 3;
const double _iValue = 60.0;
const double _hueDeg = 0.0;
const double _abRange = 2.0 * _step;
const double _cMax = 4.0 * _step;

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

final _display = DisplayModel('srgb');

String _fmt(double value) => value.toStringAsFixed(12);

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

void _writeRow(IOSink sink, {
  required String mode,
  required int ix,
  required int iy,
  required double? iInput,
  required double j,
  required double a,
  required double b,
  required double c,
  required double h,
}) {
  final xyz = scamToXyz(
    jch: Vector3(j, c, h),
    xyz_w: globalViewingConditions.xyzw,
    y_b: globalViewingConditions.yb,
    l_a: globalViewingConditions.la,
    surround: globalViewingConditions.surround,
  );
  final rgb = _display.xyzToRgb(xyz);
  final rgbClamped = rgb.clone()..clamp(Vector3.zero(), Vector3.all(1.0));
  final oog = _isOutOfGamut(rgb);

  final fields = <String>[
    mode,
    '$ix',
    '$iy',
    iInput == null ? '' : _fmt(iInput),
    _fmt(j),
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
    _fmt(rgbClamped.x),
    _fmt(rgbClamped.y),
    _fmt(rgbClamped.z),
    oog.toString(),
  ];
  sink.writeln(fields.join(','));
}

Future<void> main() async {
  final file = File('tool/colorway_dump_flutter.csv');
  file.createSync(recursive: true);
  final sink = file.openWrite();
  sink.writeln(
    [
      'mode',
      'ix',
      'iy',
      'I_input',
      'J',
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
      'rgb_r_clamped',
      'rgb_g_clamped',
      'rgb_b_clamped',
      'is_out_of_gamut',
    ].join(','),
  );

  final jFromI = _jFromI(_iValue);
  for (var iy = 0; iy < _cells; iy++) {
    for (var ix = 0; ix < _cells; ix++) {
      final nx = ((ix + 0.5) / _cells) * 2 - 1;
      final ny = (1 - (iy + 0.5) / _cells) * 2 - 1;
      final a = nx * _abRange;
      final b = ny * _abRange;
      final c = math.sqrt(a * a + b * b);
      double h = c == 0 ? 0.0 : _deg(math.atan2(b, a));
      if (h < 0) h += 360;
      _writeRow(
        sink,
        mode: 'Iab',
        ix: ix,
        iy: iy,
        iInput: _iValue,
        j: jFromI,
        a: a,
        b: b,
        c: c,
        h: h,
      );
    }
  }

  for (var iy = 0; iy < _cells; iy++) {
    for (var ix = 0; ix < _cells; ix++) {
      final xNorm = (ix + 0.5) / _cells;
      final yNorm = (iy + 0.5) / _cells;
      final c = xNorm * _cMax;
      final j = (1 - yNorm) * 100.0;
      final a = c * math.cos(_rad(_hueDeg));
      final b = c * math.sin(_rad(_hueDeg));
      _writeRow(
        sink,
        mode: 'LC',
        ix: ix,
        iy: iy,
        iInput: null,
        j: j,
        a: a,
        b: b,
        c: c,
        h: _hueDeg,
      );
    }
  }

  await sink.flush();
  await sink.close();
  print('Wrote ${_cells * _cells * 2} rows to ${file.path}');
}
double _deg(num radians) => radians * 180.0 / math.pi;
double _rad(num degrees) => degrees * math.pi / 180.0;
