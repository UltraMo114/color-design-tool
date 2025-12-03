import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:vector_math/vector_math.dart' show Vector3;

import '../providers/palette_provider.dart';
import '../providers/display_profile_provider.dart';
import 'package:colordesign_tool_core/src/common/util.dart';
import 'package:colordesign_tool_core/src/utils/config.dart';
import 'package:colordesign_tool_core/src/utils/display_model.dart';
import 'package:colordesign_tool_core/src/utils/gog_display_model.dart';
import 'package:colordesign_tool_core/src/algorithms/color_stimuli.dart';
import 'package:colordesign_tool_core/src/models/color_stimulus.dart';

import 'camera_capture_screen.dart';

final DisplayModel _srgbModel = DisplayModel('srgb');

class ColorwayScreen extends StatefulWidget {
  const ColorwayScreen({super.key});

  @override
  State<ColorwayScreen> createState() => _ColorwayScreenState();
}

enum ColorwayMode { ab, ch }

class _ColorwayScreenState extends State<ColorwayScreen> {
  // Fixed I (sUCS) value, adjustable via slider
  double jValue = 50.0;

  // Grid parameters
  static const int _defaultCells = 5;

  ColorwayMode mode = ColorwayMode.ab;
  int step = 3; // 1..5 grid step size

  // Display mapping is now app-wide via DisplayProfileProvider.

  // Last selected point in Lab (a*, b*) so it persists across modes
  double? selA;
  double? selB;
  double? selJ;
  double? selC;
  double? selH;

  // Translate tap into Lab a*,b* in current range
  double get abRange => 2.0 * step; // [-2*step, +2*step]

  double get chMax => 4.0 * step; // [0, 4*step]

  int get cells => _defaultCells;

  Widget _modeMenu(BuildContext context) {
    final profile = context.watch<DisplayProfileProvider>();
    return PopupMenuButton<DisplayProfileType>(
      tooltip: 'Display mode',
      initialValue: profile.type,
      onSelected: (t) async {
        await profile.setType(t);
      },
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: DisplayProfileType.srgb,
          child: Text('sRGB'),
        ),
        PopupMenuItem(
          value: DisplayProfileType.calibrated,
          child: Text('Calibrated'),
        ),
      ],
      icon: const Icon(Icons.tune),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Colorway'),
        actions: [
          _modeMenu(context),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Lightness (J)'),
                      Row(
                        children: [
                          Expanded(
                            child: Slider(
                              min: 0,
                              max: 100,
                              value: jValue,
                              onChanged: (v) => setState(() {
                                jValue = v;
                                if (selJ != null) {
                                  selJ = v;
                                }
                              }),
                            ),
                          ),
                          SizedBox(
                            width: 44,
                            child: Text(
                              jValue.toStringAsFixed(0),
                              textAlign: TextAlign.right,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                IconButton(
                  tooltip: 'Camera Capture',
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const CameraCaptureScreen(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.camera_alt_outlined),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed:
                      (mode == ColorwayMode.ab &&
                              selA != null &&
                              selB != null) ||
                              (mode == ColorwayMode.ch &&
                                      selC != null &&
                                      selH != null)
                          ? () {
                              if (mode == ColorwayMode.ab) {
                                final stim = _stimulusFromJab(jValue, selA!, selB!);
                                context
                                    .read<PaletteProvider>()
                                    .addStimulusToNextEmpty(stim);
                              } else {
                                final stim = _stimulusFromJch(jValue, selC!, selH!);
                                context
                                    .read<PaletteProvider>()
                                    .addStimulusToNextEmpty(stim);
                              }
                            }
                          : null,
                  child: const Text('Push'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                ToggleButtons(
                  isSelected: [
                    mode == ColorwayMode.ab,
                    mode == ColorwayMode.ch,
                  ],
                  onPressed: (i) => setState(
                    () => mode = i == 0 ? ColorwayMode.ab : ColorwayMode.ch,
                  ),
                  constraints: const BoxConstraints(
                    minHeight: 36,
                    minWidth: 48,
                  ),
                  children: const [Text('ab'), Text('Ch')],
                ),
                const Spacer(),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = math.min(
                  constraints.maxWidth,
                  constraints.maxHeight,
                );
                final padding = (constraints.maxWidth - size) / 2;
                return Stack(
                  children: [
                    Positioned(
                      left: padding,
                      top: 0,
                      width: size,
                      height: size,
                      child: _PlaneCanvas(
                        jValue: jValue,
                        cells: cells,
                        abRange: abRange,
                        cMax: chMax,
                        mode: mode,
                        selA: selA,
                        selB: selB,
                        selJ: selJ,
                        selC: selC,
                        selH: selH,
                        onPick: (first, second) async {
                          if (mode == ColorwayMode.ab) {
                            setState(() {
                              selA = first;
                              selB = second;
                              selJ = null;
                              selC = null;
                              selH = null;
                            });
                          } else {
                            setState(() {
                              selC = first;
                              selH = second;
                              selJ = jValue;
                              selA = null;
                              selB = null;
                            });
                          }
                        },
                      ),
                    ),
                    // Mini palette overlay (bottom-right)
                    Positioned(
                      left: padding + 8,
                      bottom: 8,
                    child: _ScamPanel(
                      mode: mode,
                      jValue: jValue,
                      selA: selA,
                      selB: selB,
                      selJ: selJ,
                      selC: selC,
                      selH: selH,
                    ),
                    ),
                    Positioned(
                      right: padding + 8,
                      bottom: 8,
                      child: const _MiniPalette(),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Text('Step'),
                const SizedBox(width: 12),
                Expanded(
                  child: Slider(
                    min: 1,
                    max: 15,
                    divisions: 14,
                    value: step.toDouble(),
                    label: step.toString(),
                    onChanged: (v) => setState(() => step = v.round()),
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text(step.toString(), textAlign: TextAlign.right),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  ColorStimulus _stimulusFromJab(double j, double a, double b) {
    final jClamped = j.clamp(0.0, 100.0);
    final chroma = math.sqrt(a * a + b * b);
    double hue = chroma == 0 ? 0.0 : math.atan2(b, a) * 180 / math.pi;
    if (hue < 0) hue += 360;
    final stim = jchToColorstimulus(jch: Vector3(jClamped, chroma, hue));
    return _withDisplayMapping(stim);
  }

  ColorStimulus _stimulusFromJch(double j, double c, double h) {
    final stim = jchToColorstimulus(jch: Vector3(j, c, h));
    return _withDisplayMapping(stim);
  }

  ColorStimulus _withDisplayMapping(ColorStimulus stim) {
    final xyz = stim.scientific_core.xyz_value;
    final xyzVec = Vector3(xyz[0], xyz[1], xyz[2]);
    final profile = context.read<DisplayProfileProvider>();
    final rgb = profile.mapXyzToRgb(xyzVec);
    final clamped = rgb.clone()..clamp(Vector3.zero(), Vector3.all(1.0));
    final rep = DisplayRepresentation(
      color_space_name: 'sRGB',
      rgb_values: [clamped.x, clamped.y, clamped.z],
      is_out_of_gamut: _isOutOfGamut(rgb),
    );
    // Overwrite the 'sRGB' slot so the UI uses the currently selected mapping.
    stim.display_representations['sRGB'] = rep;
    return stim;
  }
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

class _PlaneCanvas extends StatelessWidget {
  final double jValue;
  final int cells;
  final double abRange;
  final double cMax;
  final ColorwayMode mode;
  final double? selA;
  final double? selB;
  final double? selJ;
  final double? selC;
  final double? selH;
  final void Function(double first, double second) onPick;

  const _PlaneCanvas({
    required this.jValue,
    required this.cells,
    required this.abRange,
    required this.cMax,
    required this.mode,
    required this.selA,
    required this.selB,
    required this.selJ,
    required this.selC,
    required this.selH,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) {
        final box = context.findRenderObject() as RenderBox;
        final size = box.size;
        final local = d.localPosition;
        final xN = (local.dx / size.width).clamp(0.0, 1.0);
        final yN = (local.dy / size.height).clamp(0.0, 1.0);
        if (mode == ColorwayMode.ab) {
          final a = (xN * 2 - 1) * abRange;
          final b = ((1 - yN) * 2 - 1) * abRange;
          onPick(a, b);
        } else {
          // CH mode: x -> chroma, y -> hue
          final c = xN * cMax;
          final h = (1 - yN) * 360.0;
          onPick(c, h);
        }
      },
      child: CustomPaint(
        painter: _PlanePainter(
          jValue: jValue,
          cells: cells,
          abRange: abRange,
          cMax: cMax,
          mode: mode,
          selA: selA,
          selB: selB,
          selJ: selJ,
          selC: selC,
          selH: selH,
          mapXyzToRgb: context.read<DisplayProfileProvider>().mapXyzToRgb,
        ),
      ),
    );
  }
}

class _PlanePainter extends CustomPainter {
  final double jValue;
  final int cells;
  final double abRange;
  final double cMax;
  final ColorwayMode mode;
  final double? selA;
  final double? selB;
  final double? selJ;
  final double? selC;
  final double? selH;
  final Vector3 Function(Vector3 xyz) mapXyzToRgb;

  _PlanePainter({
    required this.jValue,
    required this.cells,
    required this.abRange,
    required this.cMax,
    required this.mode,
    required this.selA,
    required this.selB,
    required this.selJ,
    required this.selC,
    required this.selH,
    required this.mapXyzToRgb,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cellW = size.width / cells;
    final cellH = size.height / cells;
    final wp = globalViewingConditions.xyzw;
    final paint = Paint();
    final j = jValue.clamp(0.0, 100.0);

    for (int iy = 0; iy < cells; iy++) {
      for (int ix = 0; ix < cells; ix++) {
        Vector3 jch;
        if (mode == ColorwayMode.ab) {
          final nx = ((ix + 0.5) / cells) * 2 - 1;
          final ny = (1 - (iy + 0.5) / cells) * 2 - 1;
          final a = nx * abRange;
          final b = ny * abRange;
          final chroma = math.sqrt(a * a + b * b);
          double hue = chroma == 0 ? 0.0 : math.atan2(b, a) * 180 / math.pi;
          if (hue < 0) hue += 360;
          jch = Vector3(j, chroma, hue);
        } else {
          final xN = (ix + 0.5) / cells;
          final yN = (iy + 0.5) / cells;
          final chroma = xN * cMax;
          final hue = (1 - yN) * 360.0;
          jch = Vector3(j, chroma, hue);
        }

        final xyz = scamToXyz(
          jch: jch,
          xyz_w: wp,
          y_b: globalViewingConditions.yb,
          l_a: globalViewingConditions.la,
          surround: globalViewingConditions.surround,
        );
        final rgb = mapXyzToRgb(xyz);

        final isOOG = _isOutOfGamut(rgb);
        rgb.clamp(Vector3.zero(), Vector3.all(1.0));

        final color = isOOG
            ? const Color(0xFF808080)
            : Color.fromRGBO(
                (rgb.x * 255).round(),
                (rgb.y * 255).round(),
                (rgb.z * 255).round(),
                1,
              );
        paint.color = color;
        canvas.drawRect(
          Rect.fromLTWH(ix * cellW, iy * cellH, cellW + 0.5, cellH + 0.5),
          paint,
        );
      }
    }

    _drawAxesAndTicks(canvas, size);

    if (mode == ColorwayMode.ab && selA != null && selB != null) {
      final marker = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white;
      final marker2 = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = Colors.black.withOpacity(0.6);

      final xN = ((selA! / abRange) + 1) / 2;
      final yN = 1 - ((selB! / abRange) + 1) / 2;
      final px = xN * size.width;
      final py = yN * size.height;
      canvas.drawCircle(Offset(px, py), 7, marker2);
      canvas.drawCircle(Offset(px, py), 5, marker);
    }

    if (mode == ColorwayMode.ch && selC != null && selH != null) {
      final marker = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white;
      final marker2 = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = Colors.black.withOpacity(0.6);
      final xN = (selC!.clamp(0.0, cMax) / cMax);
      final yN = 1 - (selH!.clamp(0.0, 360.0) / 360.0);
      final px = xN * size.width;
      final py = yN * size.height;
      canvas.drawCircle(Offset(px, py), 7, marker2);
      canvas.drawCircle(Offset(px, py), 5, marker);
    }
  }

  @override
  bool shouldRepaint(covariant _PlanePainter old) {
    return old.jValue != jValue ||
        old.cells != cells ||
        old.abRange != abRange ||
        old.cMax != cMax ||
        old.mode != mode ||
        old.selA != selA ||
        old.selB != selB ||
        old.selJ != selJ ||
        old.selC != selC ||
        old.selH != selH;
  }

  void _drawAxesAndTicks(Canvas canvas, Size size) {
    final axis = Paint()
      ..color = Colors.black.withOpacity(0.35)
      ..strokeWidth = 1;

    final textPaint =
        (String s, Offset p, {TextAlign align = TextAlign.center}) {
          final tp = TextPainter(
            text: TextSpan(
              text: s,
              style: const TextStyle(fontSize: 11, color: Colors.black87),
            ),
            textAlign: align,
            textDirection: TextDirection.ltr,
          )..layout();
          tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
        };

    if (mode == ColorwayMode.ab) {
      final cx = size.width / 2;
      final cy = size.height / 2;
      canvas.drawLine(Offset(cx, 0), Offset(cx, size.height), axis);
      canvas.drawLine(Offset(0, cy), Offset(size.width, cy), axis);

      final values = [-2, -1, 0, 1, 2].map((k) => k * abRange / 2).toList();
      for (var i = 0; i < values.length; i++) {
        final v = values[i];
        final x = ((v + abRange) / (2 * abRange)) * size.width;
        canvas.drawLine(Offset(x, cy - 4), Offset(x, cy + 4), axis);
        textPaint(v.toStringAsFixed(0), Offset(x, size.height - 10));
        final y = ((abRange - v) / (2 * abRange)) * size.height;
        canvas.drawLine(Offset(cx - 4, y), Offset(cx + 4, y), axis);
        textPaint(v.toStringAsFixed(0), Offset(12, y));
      }
      textPaint('a', Offset(size.width / 2, size.height - 26));
      textPaint('b', Offset(14, size.height / 2 - 18));
      textPaint('Greener', Offset(30, size.height - 26));
      textPaint('Redder', Offset(size.width - 30, size.height - 26));
      textPaint('Bluer', Offset(28, size.height - 10));
      textPaint('Yellow', Offset(36, 12));
    } else {
      canvas.drawLine(
        Offset(0, size.height - 1),
        Offset(size.width, size.height - 1),
        axis,
      );
      canvas.drawLine(Offset(0, 0), Offset(size.width, 0), axis);
      canvas.drawLine(Offset(0, 0), Offset(0, size.height), axis);
      canvas.drawLine(
        Offset(size.width - 1, 0),
        Offset(size.width - 1, size.height),
        axis,
      );
      canvas.drawLine(
        Offset(size.width / 2, 0),
        Offset(size.width / 2, size.height),
        axis,
      );

      for (int i = 0; i <= 4; i++) {
        final cVal = i * (cMax / 4);
        final x = (i / 4) * size.width;
        textPaint(cVal.toStringAsFixed(0), Offset(x, size.height - 12));
      }
      const hues = [0, 90, 180, 270, 360];
      for (final h in hues) {
        final y = (1 - h / 360) * size.height;
        textPaint(h.toString(), Offset(20, y));
      }
      textPaint('C', Offset(size.width / 2, size.height - 26));
      textPaint('Hue', Offset(32, 12));
    }
  }
}

class _MiniPalette extends StatelessWidget {
  const _MiniPalette();

  @override
  Widget build(BuildContext context) {
    final p = context.watch<PaletteProvider>();
    const cols = 5;
    const rows = 4;
    const cell = 22.0;
    final items = List.generate(20, (i) {
      final s = p.getColorAt(i);
      final rep = s.display_representations['sRGB'];
      Color color;
      if (rep == null) {
        color = Colors.grey;
      } else {
        final r = (rep.rgb_values[0] * 255).clamp(0, 255).round();
        final g = (rep.rgb_values[1] * 255).clamp(0, 255).round();
        final b = (rep.rgb_values[2] * 255).clamp(0, 255).round();
        color = Color.fromRGBO(r, g, b, 1);
      }
      return Container(
        width: cell,
        height: cell,
        decoration: BoxDecoration(
          color: color,
          border: Border.all(color: Colors.black12),
        ),
      );
    });

    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.black12),
        ),
        child: SizedBox(
          width: cols * cell + (cols - 1) * 2,
          height: rows * cell + (rows - 1) * 2,
          child: GridView.count(
            crossAxisCount: cols,
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
            physics: const NeverScrollableScrollPhysics(),
            children: items,
          ),
        ),
      ),
    );
  }
}

class _ScamPanel extends StatelessWidget {
  final ColorwayMode mode;
  final double jValue;
  final double? selA;
  final double? selB;
  final double? selJ;
  final double? selC;
  final double? selH;

  const _ScamPanel({
    required this.mode,
    required this.jValue,
    required this.selA,
    required this.selB,
    required this.selJ,
    required this.selC,
    required this.selH,
  });

  @override
  Widget build(BuildContext context) {
    final info = _buildInfo(context);
    final previewColor = info?.previewColor ?? Colors.grey;

    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 190,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.black12),
        ),
        child: info == null
            ? const Text('Tap a cell', style: TextStyle(fontSize: 12))
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 36,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: previewColor,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.black12),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'JCh ${info.j.toStringAsFixed(1)}, ${info.c.toStringAsFixed(1)}, ${info.h.toStringAsFixed(1)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  Text('Display ${info.hex}', style: const TextStyle(fontSize: 12)),
                ],
              ),
      ),
    );
  }

  _ColorInfo? _buildInfo(BuildContext context) {
    Vector3? jch;
    if (mode == ColorwayMode.ab) {
      if (selA == null || selB == null) return null;
      final j = jValue.clamp(0.0, 100.0);
      final c = math.sqrt(selA! * selA! + selB! * selB!);
      var h = c == 0 ? 0.0 : math.atan2(selB!, selA!) * 180 / math.pi;
      if (h < 0) h += 360;
      jch = Vector3(j, c, h);
    } else {
      if (selC == null || selH == null) return null;
      final j = (selJ ?? jValue).clamp(0.0, 100.0);
      jch = Vector3(j, selC!, selH!);
    }
    final xyz = scamToXyz(
      jch: jch,
      xyz_w: globalViewingConditions.xyzw,
      y_b: globalViewingConditions.yb,
      l_a: globalViewingConditions.la,
      surround: globalViewingConditions.surround,
    );
    final profile = context.read<DisplayProfileProvider>();
    final rgb = profile.mapXyzToRgb(xyz);
    final clamped = rgb.clone()..clamp(Vector3.zero(), Vector3.all(1.0));
    final color = Color.fromRGBO(
      (clamped.x * 255).round(),
      (clamped.y * 255).round(),
      (clamped.z * 255).round(),
      1,
    );
    return _ColorInfo(
      j: jch.x,
      c: jch.y,
      h: jch.z,
      hex: _rgbVecToHex(clamped),
      previewColor: color,
    );
  }
}

class _ColorInfo {
  final double j;
  final double c;
  final double h;
  final String hex;
  final Color previewColor;

  _ColorInfo({
    required this.j,
    required this.c,
    required this.h,
    required this.hex,
    required this.previewColor,
  });
}

String _rgbVecToHex(Vector3 rgb) {
  final r = (rgb.x * 255)
      .clamp(0, 255)
      .round()
      .toRadixString(16)
      .padLeft(2, '0');
  final g = (rgb.y * 255)
      .clamp(0, 255)
      .round()
      .toRadixString(16)
      .padLeft(2, '0');
  final b = (rgb.z * 255)
      .clamp(0, 255)
      .round()
      .toRadixString(16)
      .padLeft(2, '0');
  return '#${(r + g + b).toUpperCase()}';
}
