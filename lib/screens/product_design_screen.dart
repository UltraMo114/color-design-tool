import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:vector_math/vector_math.dart' show Vector3;

import 'package:colordesign_tool_core/src/common/util.dart' show labToXyz;
import 'package:colordesign_tool_core/src/models/color_stimulus.dart';
import '../providers/palette_provider.dart';
import '../providers/display_profile_provider.dart';
import '../utils/color_metrics.dart';

class ProductDesignScreen extends StatefulWidget {
  const ProductDesignScreen({super.key});

  @override
  State<ProductDesignScreen> createState() => _ProductDesignScreenState();
}

class _ProductDesignScreenState extends State<ProductDesignScreen> {
  static const List<double> _defaultReferenceWhite = [95.047, 100.0, 108.883];
  static const int _defaultObserverAngle = 2;
  static const double _defaultAdaptingLuminance = 64.0;
  static const double _defaultBackgroundLuminance = 20.0;
  static const String _defaultSurround = 'avg';

  int _slots = 2; // 1..4
  String _pattern = 'square'; // square | circle | triangle
  double _scale = 0.15; // total content area ratio
  int? _selected; // -1 background, 0..3 slots

  ColorStimulus? _background;
  double _backgroundLightness = 50;
  final List<ColorStimulus?> _stimuli = List<ColorStimulus?>.filled(4, null);

  // Metrics (simple approximations until exact algorithm is ported)
  double? _wc, _hl, _ap, _ch;

  @override
  void initState() {
    super.initState();
    _background = _stimulusFromLab(
      l: _backgroundLightness,
      a: 0,
      b: 0,
      sourceLabel: 'Background',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Product Design')),
      body: LayoutBuilder(builder: (context, constraints) {
        // 上中下布局：顶部参数区 / 中间颜色排布预览 / 底部指标
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: _buildTopControls(context),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: _buildPreview(context),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: _buildMetrics(context),
            ),
          ],
        );
      }),
    );
  }

  Widget _buildTopControls(BuildContext context) {
    // 两行：第一行 Selector + Pattern；第二行 Size + Transform
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _labeled(
              'Selector',
              DropdownButton<int>(
                value: _slots,
                items: const [1, 2, 3, 4]
                    .map((v) => DropdownMenuItem(value: v, child: Text('$v')))
                    .toList(),
                onChanged: (v) => setState(() {
                  _slots = v ?? 2;
                  _recalcMetrics();
                }),
              ),
            ),
            const SizedBox(width: 16),
            _labeled(
              'Pattern',
              DropdownButton<String>(
                value: _pattern,
                items: const ['square', 'circle', 'triangle']
                    .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                    .toList(),
                onChanged: (v) => setState(() => _pattern = v ?? 'square'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  const SizedBox(width: 4),
                  const Text('Size'),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Slider(
                      min: 0.05,
                      max: 0.5,
                      divisions: 45,
                      value: _scale,
                      label: _scale.toStringAsFixed(2),
                      onChanged: (v) => setState(() => _scale = v),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: _selected == null
                  ? null
                  : () async {
                      // If there is a focused color in buffer use it; otherwise open picker
                      final pp = context.read<PaletteProvider>();
                      ColorStimulus? chosen = pp.focusedStimulus;
                      chosen ??= await _pickFromBuffer(context);
                      if (chosen == null) return;
                      final picked = chosen;
                      setState(() {
                        if (_selected == -1) {
                          _background = picked;
                          final lab = picked.appearance?.lab_value;
                          if (lab != null && lab.length >= 3) {
                            _backgroundLightness =
                                lab[0].clamp(0.0, 100.0).toDouble();
                          }
                        } else if (_selected != null) {
                          _stimuli[_selected!] = picked;
                        }
                        _recalcMetrics();
                      });
                  },
              child: const Text('Transform'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _metricRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 160, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w500))),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Widget _buildPreview(BuildContext context) {
    final profile = context.watch<DisplayProfileProvider>();
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final height = constraints.maxHeight;
      final padding = 20.0;
      final innerW = width - padding * 2;
      final innerH = height - padding * 2;

      // Target square side by area, clamp to available cell
      final targetArea = width * height * _scale / _slots;
      final sideByArea = math.sqrt(targetArea);

      final layout = <int, List<int>>{1: [1, 1], 2: [2, 1], 3: [3, 1], 4: [2, 2]}[_slots]!;
      final cols = layout[0];
      final rows = layout[1];
      const spacing = 15.0;
      final cellW = (innerW - (cols - 1) * spacing) / cols;
      final cellH = (innerH - (rows - 1) * spacing) / rows;
      final side = math.min(sideByArea, math.min(cellW, cellH));

      final bgColor = _background == null
          ? Colors.grey.shade400
          : profile.colorForStimulus(_background!);

      return GestureDetector(
        onTap: () async {
          setState(() {
            _selected = -1;
          });
          await _showBackgroundLightnessSheet();
        },
        child: Container(
          color: bgColor,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: cols * side + (cols - 1) * spacing,
                maxHeight: rows * side + (rows - 1) * spacing,
              ),
              child: Wrap(
                spacing: spacing,
                runSpacing: spacing,
                alignment: WrapAlignment.center,
                children: List.generate(_slots, (i) {
                  final isSel = _selected == i;
                  final stim = _stimuli[i];
                  final color = stim == null
                      ? Colors.grey.shade500
                      : profile.colorForStimulus(stim);
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () async {
                      setState(() {
                        _selected = i;
                      });
                      await _showForegroundEditor(i);
                    },
                    child: Container(
                      width: side,
                      height: side,
                      decoration: _shapeDecoration(
                        _pattern,
                        color: color,
                        border:
                            Border.all(color: isSel ? Colors.black : Colors.black54, width: 1),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      );
    });
  }

  Decoration _shapeDecoration(String pattern, {required Color color, Border? border}) {
    switch (pattern) {
      case 'circle':
        return BoxDecoration(color: color, shape: BoxShape.circle, border: border);
      case 'triangle':
        // Approximate triangle by clipping via ShapeDecoration (isosceles-up)
        return ShapeDecoration(
          color: color,
          shape: _TriangleBorder(side: border?.top.width ?? 0, color: border?.top.color ?? Colors.transparent),
        );
      case 'square':
      default:
        return BoxDecoration(color: color, borderRadius: BorderRadius.circular(4), border: border);
    }
  }

  // Bottom metrics section
  Widget _buildMetrics(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Emotion Metrics', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        _metricRow('Warm/Cool (WC)', _formatOrNA(_wc)),
        _metricRow('Heavy/Light (HL)', _formatOrNA(_hl)),
        _metricRow('Active/Passive (AP)', _formatOrNA(_ap)),
        _metricRow('Harmony (CH)', _formatOrNA(_ch)),
      ],
    );
  }

  String _formatOrNA(double? v) => v == null ? 'N/A' : v.toStringAsFixed(3);

  void _recalcMetrics() {
    // Build active list: background + slots[0.._slots-1]
    final active = <ColorStimulus>[];
    if (_background != null && _background!.appearance != null) active.add(_background!);
    for (var i = 0; i < _slots; i++) {
      final s = _stimuli[i];
      if (s != null && s.appearance != null) active.add(s);
    }
    if (active.length < 2) {
      _wc = _hl = _ap = _ch = null;
      return;
    }
    double wc = 0, hl = 0, ap = 0, ch = 0;
    int pairs = 0;
    for (var i = 0; i < active.length; i++) {
      for (var j = i + 1; j < active.length; j++) {
        final a = active[i].appearance!.lab_value;
        final b = active[j].appearance!.lab_value;
        if (a.length < 3 || b.length < 3) continue;
        final res = calculateColorMetrics([a[0], a[1], a[2]], [b[0], b[1], b[2]]);
        wc += res['WC']!;
        hl += res['HL']!;
        ap += res['AP']!;
        ch += res['CH']!;
        pairs++;
      }
    }
    if (pairs > 0) {
      _wc = wc / pairs;
      _hl = hl / pairs;
      _ap = ap / pairs;
      _ch = ch / pairs;
    } else {
      _wc = _hl = _ap = _ch = null;
    }
  }

  // Small helper to place a text label next to a control.
  Widget _labeled(String label, Widget control) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        const SizedBox(width: 8),
        control,
      ],
    );
  }

  List<double> _labValuesOrDefault(
    ColorStimulus? stimulus, {
    double fallbackL = 50,
    double fallbackA = 0,
    double fallbackB = 0,
  }) {
    final lab = stimulus?.appearance?.lab_value;
    if (lab == null || lab.length < 3) {
      return [fallbackL, fallbackA, fallbackB];
    }
    return [lab[0], lab[1], lab[2]];
  }

  ColorStimulus _stimulusFromLab({
    required double l,
    required double a,
    required double b,
    ColorStimulus? template,
    String sourceLabel = 'Custom',
  }) {
    final referenceWhite = template == null
        ? List<double>.from(_defaultReferenceWhite)
        : List<double>.from(template.scientific_core.reference_white_xyz);
    final xyzVec =
        labToXyz(Vector3(l, a, b), Vector3(referenceWhite[0], referenceWhite[1], referenceWhite[2]));
    final sci = ScientificData(
      xyz_value: [xyzVec.x, xyzVec.y, xyzVec.z],
      observer_angle:
          template?.scientific_core.observer_angle ?? _defaultObserverAngle,
      reference_white_xyz: referenceWhite,
      adapting_luminance_La:
          template?.scientific_core.adapting_luminance_La ?? _defaultAdaptingLuminance,
      background_luminance_Yb:
          template?.scientific_core.background_luminance_Yb ?? _defaultBackgroundLuminance,
      surround_condition:
          template?.scientific_core.surround_condition ?? _defaultSurround,
    );
    final chroma = math.sqrt(a * a + b * b);
    var hue = math.atan2(b, a) * 180 / math.pi;
    if (hue.isNaN) {
      hue = 0;
    } else if (hue < 0) {
      hue += 360;
    }
    final appearance = AppearanceData(
      lab_value: [l, a, b],
      JCh: [l, chroma, hue],
      NCS_name: template?.appearance?.NCS_name ?? 'Custom',
      depth_description: template?.appearance?.depth_description ?? 'Custom',
      classification: template?.appearance?.classification ?? 'Custom',
    );
    final metadata =
        Map<String, dynamic>.from(template?.metadata ?? const <String, dynamic>{});
    final source = template?.source ??
        SourceInfo(
          type: 'MANUAL',
          origin_identifier: sourceLabel,
          s_name: null,
        );
    return ColorStimulus(
      source: source,
      scientific_core: sci,
      appearance: appearance,
      metadata: metadata,
    );
  }

  void _updateBackgroundLightness(double lightness) {
    final currentLab = _labValuesOrDefault(
      _background,
      fallbackL: lightness,
      fallbackA: 0,
      fallbackB: 0,
    );
    final updated = _stimulusFromLab(
      l: lightness,
      a: currentLab[1],
      b: currentLab[2],
      template: _background,
      sourceLabel: 'Background',
    );
    setState(() {
      _backgroundLightness = lightness;
      _background = updated;
      _recalcMetrics();
    });
  }

  Future<void> _showBackgroundLightnessSheet() async {
    double sliderValue =
        (_background?.appearance?.lab_value[0] ?? _backgroundLightness)
            .clamp(0.0, 100.0)
            .toDouble();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, sheetSetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Background Lightness',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 12),
                    Slider(
                      min: 0,
                      max: 100,
                      value: sliderValue,
                      onChanged: (value) {
                        sheetSetState(() => sliderValue = value);
                        _updateBackgroundLightness(value);
                      },
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text('L* ${sliderValue.toStringAsFixed(1)}'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showForegroundEditor(int index) async {
    final rootContext = context;
    final lab = _labValuesOrDefault(_stimuli[index]);
    double l = lab[0].clamp(0.0, 100.0).toDouble();
    double aValue = lab[1].clamp(-128.0, 128.0).toDouble();
    double bValue = lab[2].clamp(-128.0, 128.0).toDouble();

    await showModalBottomSheet<void>(
      context: rootContext,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, sheetSetState) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 16,
                  bottom: 16 + MediaQuery.of(sheetContext).viewInsets.bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Adjust Slot ${index + 1}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () async {
                        final chosen = await _pickFromBuffer(rootContext);
                        if (chosen == null || !mounted) return;
                        setState(() {
                          _stimuli[index] = chosen;
                          _recalcMetrics();
                        });
                        final newLab = chosen.appearance?.lab_value;
                        if (newLab != null && newLab.length >= 3) {
                          sheetSetState(() {
                            l = newLab[0].clamp(0.0, 100.0).toDouble();
                            aValue = newLab[1].clamp(-128.0, 128.0).toDouble();
                            bValue = newLab[2].clamp(-128.0, 128.0).toDouble();
                          });
                        }
                      },
                      icon: const Icon(Icons.layers),
                      label: const Text('Select from Buffer'),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Modify Color',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    _labSlider(
                      label: 'L*',
                      min: 0,
                      max: 100,
                      value: l,
                      onChanged: (value) {
                        sheetSetState(() => l = value);
                        _updateForegroundLab(index, value, aValue, bValue);
                      },
                    ),
                    _labSlider(
                      label: 'a*',
                      min: -128,
                      max: 128,
                      value: aValue,
                      onChanged: (value) {
                        sheetSetState(() => aValue = value);
                        _updateForegroundLab(index, l, value, bValue);
                      },
                    ),
                    _labSlider(
                      label: 'b*',
                      min: -128,
                      max: 128,
                      value: bValue,
                      onChanged: (value) {
                        sheetSetState(() => bValue = value);
                        _updateForegroundLab(index, l, aValue, value);
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _updateForegroundLab(int index, double l, double a, double b) {
    final updated = _stimulusFromLab(
      l: l,
      a: a,
      b: b,
      template: _stimuli[index],
      sourceLabel: 'Slot ${index + 1}',
    );
    setState(() {
      _stimuli[index] = updated;
      _recalcMetrics();
    });
  }

  Widget _labSlider({
    required String label,
    required double min,
    required double max,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(label),
          ),
          Expanded(
            child: Slider(
              min: min,
              max: max,
              value: value,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              value.toStringAsFixed(1),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Future<ColorStimulus?> _pickFromBuffer(BuildContext context) async {
    return showModalBottomSheet<ColorStimulus?>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final pp = context.watch<PaletteProvider>();
        final dp = context.watch<DisplayProfileProvider>();
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Select from Buffer', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              Flexible(
                child: GridView.builder(
                  shrinkWrap: true,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 1,
                  ),
                  itemCount: 20,
                  itemBuilder: (context, index) {
                    final isEmpty = pp.isPositionEmpty(index);
                    Color color = Colors.transparent;
                    if (!isEmpty) {
                      color = dp.colorForStimulus(pp.getColorAt(index));
                    }
                    return InkWell(
                      onTap: isEmpty
                          ? null
                          : () => Navigator.of(context).pop(pp.getColorAt(index)),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isEmpty ? Colors.transparent : color,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.black26),
                        ),
                        child: isEmpty
                            ? const Center(child: Icon(Icons.add, color: Colors.black26))
                            : null,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TriangleBorder extends ShapeBorder {
  final double side;
  final Color color;
  const _TriangleBorder({this.side = 0, this.color = Colors.transparent});

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    final path = Path();
    path.moveTo(rect.center.dx, rect.top);
    path.lineTo(rect.right, rect.bottom);
    path.lineTo(rect.left, rect.bottom);
    path.close();
    return path;
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side <= 0) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = side
      ..color = color;
    final path = getOuterPath(rect);
    canvas.drawPath(path, paint);
  }

  @override
  ShapeBorder scale(double t) => this;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => getOuterPath(rect);
}
