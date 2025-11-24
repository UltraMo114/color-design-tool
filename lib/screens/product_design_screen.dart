import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
  int _slots = 2; // 1..4
  String _pattern = 'square'; // square | circle | triangle
  double _scale = 0.15; // total content area ratio
  int? _selected; // -1 background, 0..3 slots

  ColorStimulus? _background;
  final List<ColorStimulus?> _stimuli = List<ColorStimulus?>.filled(4, null);

  // Metrics (simple approximations until exact algorithm is ported)
  double? _wc, _hl, _ap, _ch;

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
                      setState(() {
                        if (_selected == -1) {
                          _background = chosen;
                        } else if (_selected != null) {
                          _stimuli[_selected!] = chosen;
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
          ? Colors.grey.shade200
          : profile.colorForStimulus(_background!);

      return GestureDetector(
        onTap: () async {
          final chosen = await _pickFromBuffer(context);
          if (chosen == null) return;
          setState(() {
            _background = chosen;
            _selected = -1;
            _recalcMetrics();
          });
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
                      final chosen = await _pickFromBuffer(context);
                      if (chosen == null) return;
                      setState(() {
                        _stimuli[i] = chosen;
                        _selected = i;
                        _recalcMetrics();
                      });
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
