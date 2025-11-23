import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:vector_math/vector_math.dart' show Vector3;

import '../providers/palette_provider.dart';
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

enum ColorwayMode { ab, lc }
enum DisplayMappingMode { srgb, calibrated }

class _ColorwayScreenState extends State<ColorwayScreen> {
  // Fixed I (sUCS) value, adjustable via slider
  double iValue = 60.0;

  // Grid parameters
  static const int _defaultCells = 5;

  ColorwayMode mode = ColorwayMode.ab;
  double hueDeg = 0.0; // for LC mode, fixed hue (0..360)
  int step = 3; // 1..5 grid step size

  // Display mapping mode (sRGB preset vs calibrated GOG model)
  DisplayMappingMode mappingMode = DisplayMappingMode.srgb;
  GogDisplayModel? _gogModel;
  String? _gogError;

  // Last selected point in Lab (a*, b*) so it persists across modes
  double? selA;
  double? selB;
  double? selJ;
  double? selC;

  // Translate tap into Lab a*,b* in current range
  double get abRange => 2.0 * step; // [-2*step, +2*step]

  double get chMax => 4.0 * step; // [0, 4*step]

  int get cells => _defaultCells;

  Future<void> _ensureGogLoaded() async {
    if (_gogModel != null) return;
    final raw = await rootBundle.loadString('assets/display_gog_model.csv');
    _gogModel = GogDisplayModel.fromCsvString(raw);
  }

  Widget _modeMenu() {
    return PopupMenuButton<DisplayMappingMode>(
      tooltip: 'Display mode',
      initialValue: mappingMode,
      onSelected: (m) async {
        if (m == DisplayMappingMode.calibrated) {
          try {
            await _ensureGogLoaded();
            if (!mounted) return;
            setState(() {
              mappingMode = m;
              _gogError = null;
            });
          } catch (e) {
            if (!mounted) return;
            setState(() {
              mappingMode = DisplayMappingMode.srgb;
              _gogError = 'Failed to load calibrated model: $e';
            });
          }
        } else {
          setState(() {
            mappingMode = m;
          });
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: DisplayMappingMode.srgb,
          child: Text('sRGB'),
        ),
        PopupMenuItem(
          value: DisplayMappingMode.calibrated,
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
          _modeMenu(),
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
                      const Text('I'),
                      Row(
                        children: [
                          Expanded(
                            child: Slider(
                              min: 0,
                              max: 100,
                              value: iValue,
                              onChanged: (v) => setState(() => iValue = v),
                            ),
                          ),
                          SizedBox(
                            width: 44,
                            child: Text(
                              iValue.toStringAsFixed(0),
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
                          (mode == ColorwayMode.lc &&
                              selJ != null &&
                              selC != null)
                      ? () {
                          if (mode == ColorwayMode.ab) {
                            final stim = _stimulusFromIab(iValue, selA!, selB!);
                            context
                                .read<PaletteProvider>()
                                .addStimulusToNextEmpty(stim);
                          } else {
                            final stim = _stimulusFromJch(selJ!, selC!, hueDeg);
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
                    mode == ColorwayMode.lc,
                  ],
                  onPressed: (i) => setState(
                    () => mode = i == 0 ? ColorwayMode.ab : ColorwayMode.lc,
                  ),
                  constraints: const BoxConstraints(
                    minHeight: 36,
                    minWidth: 48,
                  ),
                  children: const [Text('ab'), Text('L-C')],
                ),
                if (mode == ColorwayMode.lc) ...[
                  const SizedBox(width: 16),
                  const Text('Hue'),
                  Expanded(
                    child: Slider(
                      min: 0,
                      max: 360,
                      value: hueDeg,
                      onChanged: (v) => setState(() => hueDeg = v),
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    child: Text(
                      hueDeg.toStringAsFixed(0),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ] else
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
                        iValue: iValue,
                        cells: cells,
                        abRange: abRange,
                        cMax: chMax,
                        mode: mode,
                        hueDeg: hueDeg,
                        selA: selA,
                        selB: selB,
                        selJ: selJ,
                        selC: selC,
                        onPick: (a, b) async {
                          if (mode == ColorwayMode.ab) {
                            setState(() {
                              selA = a;
                              selB = b;
                              selJ = null;
                              selC = null;
                            });
                          } else {
                            // For LC mode, onPick receives J (vertical) and C (horizontal)
                            final J = a;
                            final C = b;
                            setState(() {
                              selJ = J;
                              selC = C;
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
                        iValue: iValue,
                        selA: selA,
                        selB: selB,
                        selJ: selJ,
                        selC: selC,
                        hueDeg: hueDeg,
                        mappingMode: mappingMode,
                        gogModel: _gogModel,
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

  ColorStimulus _stimulusFromIab(double i, double a, double b) {
    final vc = globalViewingConditions;
    final surroundParams = scamSurroundParams[vc.surround.toLowerCase()];
    if (surroundParams == null) {
      throw ArgumentError('Unsupported surround ${vc.surround}');
    }
    final n = vc.yb / vc.xyzw.y;
    final z = 1.48 + math.sqrt(n);
    final iClamped = i.clamp(0.0, 100.0);
    final ratio = (iClamped / 100.0).clamp(0.0, 1.0);
    final j = ratio == 0 ? 0.0 : 100.0 * math.pow(ratio, surroundParams.c * z);
    final chroma = math.sqrt(a * a + b * b);
    double hue = chroma == 0 ? 0.0 : math.atan2(b, a) * 180 / math.pi;
    if (hue < 0) hue += 360;
    final stim = jchToColorstimulus(jch: Vector3(j.toDouble(), chroma, hue));
    return _withDisplayMapping(stim);
  }

  ColorStimulus _stimulusFromJch(double j, double c, double h) {
    final stim = jchToColorstimulus(jch: Vector3(j, c, h));
    return _withDisplayMapping(stim);
  }

  ColorStimulus _withDisplayMapping(ColorStimulus stim) {
    final xyz = stim.scientific_core.xyz_value;
    final xyzVec = Vector3(xyz[0], xyz[1], xyz[2]);
    Vector3 rgb;
    if (mappingMode == DisplayMappingMode.calibrated && _gogModel != null) {
      rgb = _gogModel!.xyzToRgb(xyzVec);
    } else {
      rgb = _srgbModel.xyzToRgb(xyzVec);
    }
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
  final double iValue;
  final int cells;
  final double abRange;
  final double cMax;
  final ColorwayMode mode;
  final double hueDeg;
  final double? selA;
  final double? selB;
  final double? selJ;
  final double? selC;
  final void Function(double a, double b) onPick;

  const _PlaneCanvas({
    required this.iValue,
    required this.cells,
    required this.abRange,
    required this.cMax,
    required this.mode,
    required this.hueDeg,
    required this.selA,
    required this.selB,
    required this.selJ,
    required this.selC,
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
          // LC mode: X axis is Chroma (C), Y axis is Lightness (J)
          final C = xN * cMax; // 0..cMax left->right
          final J = (1 - yN) * 100.0; // 0..100 bottom->top
          onPick(J, C);
        }
      },
      child: CustomPaint(
        painter: _PlanePainter(
          iValue: iValue,
          cells: cells,
          abRange: abRange,
          cMax: cMax,
          mode: mode,
          hueDeg: hueDeg,
          selA: selA,
          selB: selB,
          selJ: selJ,
          selC: selC,
        ),
      ),
    );
  }
}

class _PlanePainter extends CustomPainter {
  final double iValue;
  final int cells;
  final double abRange;
  final double cMax;
  final ColorwayMode mode;
  final double hueDeg;
  final double? selA;
  final double? selB;
  final double? selJ;
  final double? selC;

  _PlanePainter({
    required this.iValue,
    required this.cells,
    required this.abRange,
    required this.cMax,
    required this.mode,
    required this.hueDeg,
    required this.selA,
    required this.selB,
    required this.selJ,
    required this.selC,
  }) : _surroundParams =
           scamSurroundParams[globalViewingConditions.surround.toLowerCase()] {
    if (_surroundParams == null) {
      throw ArgumentError(
        'Unsupported surround: ${globalViewingConditions.surround}',
      );
    }
    final n = globalViewingConditions.yb / globalViewingConditions.xyzw.y;
    _zFactor = 1.48 + math.sqrt(n);
  }

  final ScamSurroundParams? _surroundParams;
  late final double _zFactor;

  @override
  void paint(Canvas canvas, Size size) {
    final cellW = size.width / cells;
    final cellH = size.height / cells;
    final wp = globalViewingConditions.xyzw;
    final paint = Paint();
    final surroundParams = _surroundParams!;
    final iClamped = iValue.clamp(0.0, 100.0);
    final iRatio = (iClamped / 100.0).clamp(0.0, 1.0);
    final jValue = iRatio == 0
        ? 0.0
        : 100.0 * math.pow(iRatio, surroundParams.c * _zFactor);

    for (int iy = 0; iy < cells; iy++) {
      for (int ix = 0; ix < cells; ix++) {
        double a, b;
        if (mode == ColorwayMode.ab) {
          final nx = ((ix + 0.5) / cells) * 2 - 1;
          final ny = (1 - (iy + 0.5) / cells) * 2 - 1;
          a = nx * abRange;
          b = ny * abRange;
        } else {
          final xN = (ix + 0.5) / cells;
          final yN = (iy + 0.5) / cells; // 0 top
          final C = xN * cMax; // X maps to chroma
          final J = (1 - yN) * 100.0; // Y maps to lightness
          // jch -> xyz, then to rgb
          final xyz = scamToXyz(
            jch: Vector3(J, C, hueDeg),
            xyz_w: globalViewingConditions.xyzw,
            y_b: globalViewingConditions.yb,
            l_a: globalViewingConditions.la,
            surround: globalViewingConditions.surround,
          );
          final rgb = _srgbModel.xyzToRgb(xyz);
          final isOOG = _isOutOfGamut(rgb);
          rgb.clamp(Vector3.zero(), Vector3.all(1.0));
          final color = isOOG
              ? const Color(0xFF808080) // Lab(50,0,0) neutral gray
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
          continue; // skip Lab branch drawing below
        }

        final chroma = math.sqrt(a * a + b * b);
        double hue = chroma == 0 ? 0.0 : math.atan2(b, a) * 180 / math.pi;
        if (hue < 0) hue += 360;
        final xyz = scamToXyz(
          jch: Vector3(jValue.toDouble(), chroma, hue),
          xyz_w: wp,
          y_b: globalViewingConditions.yb,
          l_a: globalViewingConditions.la,
          surround: globalViewingConditions.surround,
        );
        final rgb = _srgbModel.xyzToRgb(xyz);

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

    // Draw axes + tick labels
    _drawAxesAndTicks(canvas, size);

    // Draw selected marker if available
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
      // Outline then white circle to pop on any background
      canvas.drawCircle(Offset(px, py), 7, marker2);
      canvas.drawCircle(Offset(px, py), 5, marker);
    }

    if (mode == ColorwayMode.lc && selJ != null && selC != null) {
      final marker = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white;
      final marker2 = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = Colors.black.withOpacity(0.6);
      // Map LC mode selection back to screen: X=C, Y=J
      final xN = (selC!.clamp(0.0, cMax) / cMax);
      final yN = 1 - (selJ!.clamp(0.0, 100.0) / 100.0);
      final px = xN * size.width;
      final py = yN * size.height;
      canvas.drawCircle(Offset(px, py), 7, marker2);
      canvas.drawCircle(Offset(px, py), 5, marker);
    }
  }

  @override
  bool shouldRepaint(covariant _PlanePainter old) {
    return old.iValue != iValue ||
        old.cells != cells ||
        old.abRange != abRange ||
        old.cMax != cMax ||
        old.mode != mode ||
        old.hueDeg != hueDeg ||
        old.selA != selA ||
        old.selB != selB ||
        old.selJ != selJ ||
        old.selC != selC;
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
      // Axes
      final cx = size.width / 2;
      final cy = size.height / 2;
      canvas.drawLine(Offset(cx, 0), Offset(cx, size.height), axis); // a=0
      canvas.drawLine(Offset(0, cy), Offset(size.width, cy), axis); // b=0

      // Ticks at -2*step, -step, 0, +step, +2*step
      final values = [-2, -1, 0, 1, 2].map((k) => k * abRange / 2).toList();
      for (var i = 0; i < values.length; i++) {
        final v = values[i];
        // x ticks (a)
        final x = ((v + abRange) / (2 * abRange)) * size.width;
        canvas.drawLine(Offset(x, cy - 4), Offset(x, cy + 4), axis);
        textPaint(v.toStringAsFixed(0), Offset(x, size.height - 10));
        // y ticks (b)
        final y = ((abRange - v) / (2 * abRange)) * size.height;
        canvas.drawLine(Offset(cx - 4, y), Offset(cx + 4, y), axis);
        textPaint(v.toStringAsFixed(0), Offset(12, y));
      }
      // Axis labels and hints
      textPaint('a', Offset(size.width / 2, size.height - 26));
      textPaint('b', Offset(14, size.height / 2 - 18));
      textPaint('Greener', Offset(30, size.height - 26));
      textPaint('Redder', Offset(size.width - 30, size.height - 26));
      textPaint('Bluer', Offset(28, size.height - 10));
      textPaint('Yellow', Offset(36, 12));
    } else {
      // LC mode
      // Baselines J=0(bottom), J=50(mid), J=100(top)
      canvas.drawLine(
        Offset(0, size.height - 1),
        Offset(size.width, size.height - 1),
        axis,
      );
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        axis,
      );
      canvas.drawLine(Offset(0, 0), Offset(size.width, 0), axis);
      // C=0(left), mid, max(right)
      canvas.drawLine(Offset(0, 0), Offset(0, size.height), axis);
      canvas.drawLine(
        Offset(size.width / 2, 0),
        Offset(size.width / 2, size.height),
        axis,
      );
      canvas.drawLine(
        Offset(size.width - 1, 0),
        Offset(size.width - 1, size.height),
        axis,
      );

      // Ticks labels along C axis: 0, step, 2*step, 3*step, 4*step
      for (int i = 0; i < 5; i++) {
        final cVal = i * (cMax / 4);
        final x = (i / 4) * size.width;
        textPaint(cVal.toStringAsFixed(0), Offset(x, size.height - 12));
      }
      // Ticks labels along J axis: 0,25,50,75,100
      const js = [0, 25, 50, 75, 100];
      for (int i = 0; i < js.length; i++) {
        final y = (1 - js[i] / 100) * size.height;
        textPaint(js[i].toString(), Offset(20, y));
      }
      textPaint('C', Offset(size.width / 2, size.height - 26));
      textPaint('J', Offset(14, size.height / 2 - 18));
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
  final double iValue;
  final double? selA;
  final double? selB;
  final double? selJ;
  final double? selC;
  final double hueDeg;
  final DisplayMappingMode mappingMode;
  final GogDisplayModel? gogModel;

  const _ScamPanel({
    required this.mode,
    required this.iValue,
    required this.selA,
    required this.selB,
    required this.selJ,
    required this.selC,
    required this.hueDeg,
    required this.mappingMode,
    required this.gogModel,
  });

  @override
  Widget build(BuildContext context) {
    final info = _buildInfo();
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
                  Text(
                    'sRGB ${info.hex}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
      ),
    );
  }

  _ColorInfo? _buildInfo() {
    Vector3? jch;
    if (mode == ColorwayMode.ab) {
      if (selA == null || selB == null) return null;
      final vc = globalViewingConditions;
      final params = scamSurroundParams[vc.surround.toLowerCase()];
      if (params == null) return null;
      final n = vc.yb / vc.xyzw.y;
      final z = 1.48 + math.sqrt(n);
      final ratio = (iValue.clamp(0.0, 100.0) / 100.0).clamp(0.0, 1.0);
      final j = ratio == 0 ? 0.0 : 100.0 * math.pow(ratio, params.c * z);
      final c = math.sqrt(selA! * selA! + selB! * selB!);
      var h = c == 0 ? 0.0 : math.atan2(selB!, selA!) * 180 / math.pi;
      if (h < 0) h += 360;
      jch = Vector3(j.toDouble(), c, h);
    } else {
      if (selJ == null || selC == null) return null;
      jch = Vector3(selJ!, selC!, hueDeg);
    }
    final xyz = scamToXyz(
      jch: jch,
      xyz_w: globalViewingConditions.xyzw,
      y_b: globalViewingConditions.yb,
      l_a: globalViewingConditions.la,
      surround: globalViewingConditions.surround,
    );
    Vector3 rgb;
    if (mappingMode == DisplayMappingMode.calibrated && gogModel != null) {
      rgb = gogModel!.xyzToRgb(xyz);
    } else {
      rgb = _srgbModel.xyzToRgb(xyz);
    }
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
