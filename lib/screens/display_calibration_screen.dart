import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/native_camera_channel.dart';

class DisplayCalibrationScreen extends StatefulWidget {
  const DisplayCalibrationScreen({super.key});

  @override
  State<DisplayCalibrationScreen> createState() =>
      _DisplayCalibrationScreenState();
}

class _DisplayCalibrationScreenState extends State<DisplayCalibrationScreen> {
  static const String _assetPath = 'assets/rgb96.csv';
  static final MethodChannel _channel = NativeCameraChannel.channel;

  final FocusNode _focusNode = FocusNode();
  List<Color> _patches = const [];
  int _index = 0;
  bool _initialized = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initCalibration();
  }

  Future<void> _initCalibration() async {
    try {
      await _setCalibrationBrightness(true);
      final patches = await _loadPatches();
      if (!mounted) {
        return;
      }
      setState(() {
        _patches = patches;
        _initialized = true;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Failed to init calibration: $e';
        _initialized = true;
      });
    }
  }

  Future<void> _setCalibrationBrightness(bool enable) async {
    final level = enable ? 0.5 : null;
    await _channel.invokeMethod('setFixedBrightness', level);
  }

  Future<List<Color>> _loadPatches() async {
    final raw = await rootBundle.loadString(_assetPath);
    final lines = raw.split(RegExp(r'\r?\n'));
    final colors = <Color>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final parts = trimmed.split(RegExp(r'[,\t; ]+'));
      if (parts.length < 3) {
        continue;
      }
      final r = int.tryParse(parts[0]);
      final g = int.tryParse(parts[1]);
      final b = int.tryParse(parts[2]);
      if (r == null || g == null || b == null) {
        continue;
      }
      colors.add(Color.fromARGB(255, r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255)));
    }
    if (colors.isEmpty) {
      throw StateError('No valid RGB entries found in $_assetPath.');
    }
    return colors;
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _setCalibrationBrightness(false);
    super.dispose();
  }

  void _handleNextPatch() {
    if (_patches.isEmpty) {
      return;
    }
    if (_index + 1 >= _patches.length) {
      Navigator.of(context).maybePop();
    } else {
      setState(() {
        _index += 1;
      });
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _handleNextPatch();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);
    final isLandscape = mediaQuery.size.width > mediaQuery.size.height;

    Widget body;
    if (!_initialized) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_error!, style: theme.textTheme.bodyMedium),
        ),
      );
    } else {
      final color = _patches[_index];
      body = Container(
        color: color,
        child: Align(
          alignment: isLandscape ? Alignment.bottomLeft : Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.4),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: DefaultTextStyle(
                  style: theme.textTheme.labelMedium!.copyWith(
                    color: Colors.white,
                  ),
                  child: Text(
                    'Patch ${_index + 1}/${_patches.length}  '
                    'RGB(${color.red},${color.green},${color.blue})\n'
                    'Press ENTER / tap to advance',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        focusNode: _focusNode,
        onKeyEvent: _handleKey,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _handleNextPatch,
          child: SafeArea(child: body),
        ),
      ),
    );
  }
}
