import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:colordesign_tool_core/src/algorithms/color_stimuli.dart';
import 'package:colordesign_tool_core/src/common/util.dart';
import 'package:colordesign_tool_core/src/utils/config.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:vector_math/vector_math.dart' show Vector3;

import '../providers/palette_provider.dart';
import '../services/native_camera_channel.dart';
import 'display_calibration_screen.dart';

enum RoiMode { raw, jpeg }

class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({super.key});

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen> {
  static const bool _showRoiDataPanel = false;
  // Custom 3x3 CCM (cam_to_xyz) loaded from a CSV file in the ROI
  // export directory. When this is absent, RAW mode is disabled to
  // avoid using an uncalibrated pipeline.
  static const String _customCcmFilename = 'roi_custom_ccm.csv';
  bool _isCapturing = false;
  bool _isProcessing = false;
  CameraCaptureResult? _captureResult;
  String? _error;
  RoiMode _mode = RoiMode.raw;
  Rect? _normalizedRoi;
  Offset? _dragStartNormalized;
  double _deltaEThreshold = 2.0;
  List<double>? _lastXyz;
  List<double>? _lastLinearRgb;
  List<double>? _lastRawRgb;
  List<double>? _lastWbGains;
  List<double>? _lastRawpyXyz;
  List<double>? _lastRawpySrgb;
  List<double>? _lastJpegSrgb;
  List<double>? _lastJpegLinearRgb;
  List<double>? _lastJpegXyz;
  Map<String, dynamic>? _lastRawRect;
  final List<_RoiDumpRecord> _roiLog = [];
  ui.Image? _jpegPreviewImage;
  double? _decodedImageWidth;
  double? _decodedImageHeight;
  List<double>? _customCamToXyz;
  int _calibrationTapCount = 0;
  DateTime? _lastCalibrationTap;

  bool get _hasCustomCcm =>
      _customCamToXyz != null && _customCamToXyz!.length == 9;

  @override
  void initState() {
    super.initState();
    _loadCustomCcm();
  }

  @override
  void dispose() {
    _jpegPreviewImage?.dispose();
    super.dispose();
  }

  Future<void> _handleCapture() async {
    setState(() {
      _isCapturing = true;
      _error = null;
    });

    try {
      final result = await NativeCameraChannel.instance.startCapture();
      if (!mounted) return;
      setState(() {
        _captureResult = result;
        _normalizedRoi = null;
        _lastXyz = null;
        _lastLinearRgb = null;
        _lastRawRgb = null;
        _lastWbGains = null;
        _lastRawpyXyz = null;
        _lastRawpySrgb = null;
        _lastJpegSrgb = null;
        _lastJpegLinearRgb = null;
        _lastJpegXyz = null;
        _lastRawRect = null;
        _roiLog.clear();
        _jpegPreviewImage?.dispose();
        _jpegPreviewImage = null;
        _decodedImageWidth = null;
        _decodedImageHeight = null;
      });
      _decodePreviewImage(result.jpegPath);
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _error = '${e.code}: ${e.message}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() => _isCapturing = false);
      }
    }
  }

  Future<void> _decodePreviewImage(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _jpegPreviewImage?.dispose();
        _jpegPreviewImage = frame.image;
        _decodedImageWidth = frame.image.width.toDouble();
        _decodedImageHeight = frame.image.height.toDouble();
      });
    } catch (e, stack) {
      debugPrint('Failed to decode JPEG for ROI preview: $e');
      debugPrint('$stack');
    }
  }

  void _startRoi(DragStartDetails details, BoxConstraints constraints) {
    _dragStartNormalized = _boxToImageNormalized(
      details.localPosition,
      constraints,
    );
    _updateRoi(details.localPosition, constraints);
  }

  void _updateRoi(Offset localPosition, BoxConstraints constraints) {
    final normalizedStart =
        _dragStartNormalized ??
        _boxToImageNormalized(localPosition, constraints);
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;
    if (width <= 0 || height <= 0) return;

    final normalizedCurrent = _boxToImageNormalized(localPosition, constraints);

    final left = math.min(normalizedStart.dx, normalizedCurrent.dx);
    final top = math.min(normalizedStart.dy, normalizedCurrent.dy);
    final right = math.max(normalizedStart.dx, normalizedCurrent.dx);
    final bottom = math.max(normalizedStart.dy, normalizedCurrent.dy);

    setState(() {
      _normalizedRoi = Rect.fromLTRB(left, top, right, bottom);
    });
  }

  void _endRoi() {
    _dragStartNormalized = null;
  }

  Future<void> _confirmRoi({bool autoTriggered = false}) async {
    if (_isProcessing) return;
    final capture = _captureResult;
    final roi = _normalizedRoi;
    if (capture == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Capture a frame first')));
      return;
    }
    if (roi == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Draw an ROI on the preview')),
      );
      return;
    }
    setState(() {
      _isProcessing = true;
      _error = null;
    });
    try {
      final targetMode = _mode;
      // Always request BOTH so CSV/analysis包含RAW+JPEG，UI仍按当前模式显示所选数据。
      final roiResult = await NativeCameraChannel.instance.processRoi(
        capture: capture,
        normalizedRoi: roi,
        mode: 'both',
      );
      final selectedXyz = targetMode == RoiMode.raw
          ? roiResult.xyz
          : roiResult.jpegXyz;
      if (selectedXyz.isEmpty) {
        throw StateError('Selected mode $targetMode returned no XYZ data.');
      }
      final xyzVec = Vector3.array(selectedXyz);
      final scaledXyz = xyzVec..scale(100.0);
      final lab = xyzToLab(scaledXyz, globalViewingConditions.xyzw);
      final stimulus = labToColorstimulus(lab: lab);
      final palette = context.read<PaletteProvider>();
      final match = palette.findClosestByDeltaE(lab, _deltaEThreshold);
      String feedback;
      if (match != null) {
        palette.replaceColorAt(match.index, stimulus);
        feedback =
            'Matched slot #${match.index + 1} (ΔE ${match.deltaE.toStringAsFixed(2)})';
      } else {
        final position = palette.addStimulusToNextEmpty(stimulus);
        if (position == -1) {
          throw StateError('Palette is full. Remove a swatch to add more.');
        }
        feedback = 'Added to slot #${position + 1}.';
      }
      final rawRectNums = _extractRawRect(roiResult.debug);
      final logEntry = _RoiDumpRecord(
        timestamp: DateTime.now(),
        normalizedRoi: roi,
        rawRect: rawRectNums,
        rawRgb: roiResult.rawRgb,
        linearRgb: roiResult.linearRgb,
        xyz: roiResult.xyz,
        wbGains: roiResult.whiteBalanceGains,
        rawpyXyz: roiResult.rawpyXyz,
        rawpySrgb: roiResult.rawpySrgb,
        jpegSrgb: roiResult.jpegSrgb,
        jpegLinear: roiResult.jpegLinearRgb,
        jpegXyz: roiResult.jpegXyz,
        camToXyzMatrix: roiResult.camToXyzMatrix,
        xyzToCamMatrix: roiResult.xyzToCamMatrix,
        colorMatrixSource: roiResult.colorMatrixSource,
        colorMatrixOriginal: roiResult.colorMatrixOriginal,
        rawpyError: roiResult.rawpyError,
        colorCorrectionTransform: roiResult.colorCorrectionTransform,
        colorMatrix1: roiResult.colorMatrix1,
        colorMatrix2: roiResult.colorMatrix2,
        sensorColorTransform1: roiResult.sensorColorTransform1,
        sensorColorTransform2: roiResult.sensorColorTransform2,
        forwardMatrix1: roiResult.forwardMatrix1,
        forwardMatrix2: roiResult.forwardMatrix2,
      );
      if (!mounted) return;
      setState(() {
        if (targetMode == RoiMode.raw) {
          _lastXyz = [scaledXyz.x, scaledXyz.y, scaledXyz.z];
          _lastLinearRgb = roiResult.linearRgb.isEmpty
              ? null
              : roiResult.linearRgb;
          _lastRawRgb = roiResult.rawRgb.isEmpty ? null : roiResult.rawRgb;
          _lastWbGains = roiResult.whiteBalanceGains.isEmpty
              ? null
              : roiResult.whiteBalanceGains;
          _lastRawpyXyz = roiResult.rawpyXyz.isEmpty
              ? null
              : roiResult.rawpyXyz;
          _lastRawpySrgb = roiResult.rawpySrgb.isEmpty
              ? null
              : roiResult.rawpySrgb;
          _lastJpegSrgb = null;
          _lastJpegLinearRgb = null;
          _lastJpegXyz = null;
        } else {
          _lastJpegSrgb = roiResult.jpegSrgb.isEmpty
              ? null
              : roiResult.jpegSrgb;
          _lastJpegLinearRgb = roiResult.jpegLinearRgb.isEmpty
              ? null
              : roiResult.jpegLinearRgb;
          _lastJpegXyz = roiResult.jpegXyz.isEmpty ? null : roiResult.jpegXyz;
          _lastXyz = null;
          _lastLinearRgb = null;
          _lastRawRgb = null;
          _lastWbGains = null;
          _lastRawpyXyz = null;
          _lastRawpySrgb = null;
        }
        _lastRawRect = Map<String, dynamic>.from(rawRectNums);
        if (!autoTriggered) {
          _roiLog.add(logEntry);
        }
      });
      if (!autoTriggered) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(feedback)));
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _error = '${e.code}: ${e.message}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _dumpRoiLog() async {
    if (_roiLog.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前没有 ROI 数据可导出')));
      return;
    }
    try {
      final dir = await _getDumpDirectory();
      final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
      final file = File(p.join(dir.path, 'roi_dump_$ts.csv'));
      final buffer = StringBuffer()
        ..writeln(
          'timestamp,roi_left,roi_top,roi_right,roi_bottom,raw_left,raw_top,raw_right,raw_bottom,raw_r,raw_g,raw_b,linear_r,linear_g,linear_b,xyz_x,xyz_y,xyz_z,wb_r_gain,wb_g_gain,wb_b_gain,rawpy_x,rawpy_y,rawpy_z,rawpy_srgb_r,rawpy_srgb_g,rawpy_srgb_b,jpeg_srgb_r,jpeg_srgb_g,jpeg_srgb_b,jpeg_linear_r,jpeg_linear_g,jpeg_linear_b,jpeg_xyz_x,jpeg_xyz_y,jpeg_xyz_z,cam_to_xyz_m00,cam_to_xyz_m01,cam_to_xyz_m02,cam_to_xyz_m10,cam_to_xyz_m11,cam_to_xyz_m12,cam_to_xyz_m20,cam_to_xyz_m21,cam_to_xyz_m22,xyz_to_cam_m00,xyz_to_cam_m01,xyz_to_cam_m02,xyz_to_cam_m10,xyz_to_cam_m11,xyz_to_cam_m12,xyz_to_cam_m20,xyz_to_cam_m21,xyz_to_cam_m22,color_matrix_source,color_matrix_raw_m00,color_matrix_raw_m01,color_matrix_raw_m02,color_matrix_raw_m10,color_matrix_raw_m11,color_matrix_raw_m12,color_matrix_raw_m20,color_matrix_raw_m21,color_matrix_raw_m22,rawpy_error,color_correction_m00,color_correction_m01,color_correction_m02,color_correction_m10,color_correction_m11,color_correction_m12,color_correction_m20,color_correction_m21,color_correction_m22,color_matrix1_m00,color_matrix1_m01,color_matrix1_m02,color_matrix1_m03,color_matrix1_m10,color_matrix1_m11,color_matrix1_m12,color_matrix1_m13,color_matrix1_m20,color_matrix1_m21,color_matrix1_m22,color_matrix1_m23,color_matrix2_m00,color_matrix2_m01,color_matrix2_m02,color_matrix2_m03,color_matrix2_m10,color_matrix2_m11,color_matrix2_m12,color_matrix2_m13,color_matrix2_m20,color_matrix2_m21,color_matrix2_m22,color_matrix2_m23,sensor_color_transform1_m00,sensor_color_transform1_m01,sensor_color_transform1_m02,sensor_color_transform1_m03,sensor_color_transform1_m10,sensor_color_transform1_m11,sensor_color_transform1_m12,sensor_color_transform1_m13,sensor_color_transform1_m20,sensor_color_transform1_m21,sensor_color_transform1_m22,sensor_color_transform1_m23,sensor_color_transform2_m00,sensor_color_transform2_m01,sensor_color_transform2_m02,sensor_color_transform2_m03,sensor_color_transform2_m10,sensor_color_transform2_m11,sensor_color_transform2_m12,sensor_color_transform2_m13,sensor_color_transform2_m20,sensor_color_transform2_m21,sensor_color_transform2_m22,sensor_color_transform2_m23,forward_matrix1_m00,forward_matrix1_m01,forward_matrix1_m02,forward_matrix1_m03,forward_matrix1_m10,forward_matrix1_m11,forward_matrix1_m12,forward_matrix1_m13,forward_matrix1_m20,forward_matrix1_m21,forward_matrix1_m22,forward_matrix1_m23,forward_matrix2_m00,forward_matrix2_m01,forward_matrix2_m02,forward_matrix2_m03,forward_matrix2_m10,forward_matrix2_m11,forward_matrix2_m12,forward_matrix2_m13,forward_matrix2_m20,forward_matrix2_m21,forward_matrix2_m22,forward_matrix2_m23',
        );
      for (final entry in _roiLog) {
        buffer.writeln(entry.toCsvRow());
      }
      await file.writeAsString(buffer.toString());
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ROI 数据已导出：${file.path}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出失败: $e')));
    }
  }

  Map<String, num> _extractRawRect(Map<String, dynamic>? rawRect) {
    return {
      'left': (rawRect?['left'] as num?) ?? 0,
      'top': (rawRect?['top'] as num?) ?? 0,
      'right': (rawRect?['right'] as num?) ?? 0,
      'bottom': (rawRect?['bottom'] as num?) ?? 0,
    };
  }

  Future<Directory> _getDumpDirectory() async {
    final external = await getExternalStorageDirectories(
      type: StorageDirectory.documents,
    );
    final baseDir = (external != null && external.isNotEmpty)
        ? external.first
        : await getApplicationDocumentsDirectory();
    final target = Directory(p.join(baseDir.path, 'roi_exports'));
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    return target;
  }

  Future<void> _loadCustomCcm() async {
    try {
      final dir = await _getDumpDirectory();
      final file = File(p.join(dir.path, _customCcmFilename));
      if (!await file.exists()) {
        if (mounted) {
          setState(() => _customCamToXyz = null);
        }
        return;
      }
      final raw = await file.readAsString();
      final firstLine = raw
          .split(RegExp(r'\r?\n'))
          .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
      final tokens = firstLine
          .split(RegExp(r'[,\s]+'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty);
      final values = <double>[];
      for (final token in tokens) {
        final v = double.tryParse(token);
        if (v != null) {
          values.add(v);
        }
        if (values.length == 9) break;
      }
      if (mounted) {
        setState(() {
          _customCamToXyz = values.length == 9 ? values : null;
        });
      }
    } catch (e, stack) {
      debugPrint('Failed to load custom CCM CSV: $e');
      debugPrint('$stack');
      if (mounted) {
        setState(() => _customCamToXyz = null);
      }
    }
  }

  List<String> _formatVector(List<double>? values, List<String> labels) {
    if (values == null || values.isEmpty) return const [];
    final length = math.min(values.length, labels.length);
    return List.generate(
      length,
      (index) => '${labels[index]}: ${values[index].toStringAsFixed(4)}',
    );
  }

  double _computePreviewAspectRatio() {
    final size = _effectiveDisplaySize();
    if (size.width > 0 && size.height > 0) {
      return size.width / size.height;
    }
    return 4 / 3;
  }

  Offset _boxToImageNormalized(Offset position, BoxConstraints constraints) {
    final size = _effectiveDisplaySize();
    final boxWidth = constraints.maxWidth;
    final boxHeight = constraints.maxHeight;
    if (boxWidth <= 0 ||
        boxHeight <= 0 ||
        size.width <= 0 ||
        size.height <= 0) {
      return Offset.zero;
    }
    final imageWidth = size.width;
    final imageHeight = size.height;
    final scale = math.max(boxWidth / imageWidth, boxHeight / imageHeight);
    final scaledWidth = imageWidth * scale;
    final scaledHeight = imageHeight * scale;
    final offsetX = (scaledWidth - boxWidth) / 2;
    final offsetY = (scaledHeight - boxHeight) / 2;
    final x = ((position.dx + offsetX) / scaledWidth).clamp(0.0, 1.0);
    final y = ((position.dy + offsetY) / scaledHeight).clamp(0.0, 1.0);
    return Offset(x, y);
  }

  Rect _imageRectToDisplayRect(Rect normalized, BoxConstraints constraints) {
    final size = _effectiveDisplaySize();
    final boxWidth = constraints.maxWidth;
    final boxHeight = constraints.maxHeight;
    if (boxWidth <= 0 ||
        boxHeight <= 0 ||
        size.width <= 0 ||
        size.height <= 0) {
      return Rect.fromLTWH(0, 0, 0, 0);
    }
    final imageWidth = size.width;
    final imageHeight = size.height;
    final scale = math.max(boxWidth / imageWidth, boxHeight / imageHeight);
    final scaledWidth = imageWidth * scale;
    final scaledHeight = imageHeight * scale;
    final offsetX = (scaledWidth - boxWidth) / 2;
    final offsetY = (scaledHeight - boxHeight) / 2;

    double left = normalized.left * scaledWidth - offsetX;
    double top = normalized.top * scaledHeight - offsetY;
    double right = normalized.right * scaledWidth - offsetX;
    double bottom = normalized.bottom * scaledHeight - offsetY;

    left = left.clamp(0.0, boxWidth);
    right = right.clamp(0.0, boxWidth);
    top = top.clamp(0.0, boxHeight);
    bottom = bottom.clamp(0.0, boxHeight);

    return Rect.fromLTRB(left, top, right, bottom);
  }

  Size _effectiveDisplaySize() {
    if (_decodedImageWidth != null && _decodedImageHeight != null) {
      return Size(_decodedImageWidth!, _decodedImageHeight!);
    }
    final metadata = _captureResult?.metadata;
    if (metadata != null) {
      double? width =
          _metadataDouble(metadata, 'jpegWidth') ??
          _metadataDouble(metadata, 'previewWidth') ??
          _metadataDouble(metadata, 'rawWidth');
      double? height =
          _metadataDouble(metadata, 'jpegHeight') ??
          _metadataDouble(metadata, 'previewHeight') ??
          _metadataDouble(metadata, 'rawHeight');
      if (width != null && height != null && width > 0 && height > 0) {
        final swapped = _shouldSwapOrientation(metadata: metadata);
        if (swapped) {
          final temp = width;
          width = height;
          height = temp;
        }
        return Size(width, height);
      }
    }
    return const Size(4, 3);
  }

  bool _shouldSwapOrientation({Map<String, dynamic>? metadata}) {
    final source = metadata ?? _captureResult?.metadata;
    final orientationValue = source?['sensorOrientation'];
    if (orientationValue is num) {
      final normalized =
          ((orientationValue.toInt() % 360) + 360) % 360; // keep positive
      return normalized == 90 || normalized == 270;
    }
    return false;
  }

  double? _metadataDouble(Map<String, dynamic> metadata, String key) {
    final value = metadata[key];
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _handleTitleTap,
            child: const Text('Camera Capture'),
          ),
          actions: [
            TextButton.icon(
              onPressed: _isCapturing ? null : _handleCapture,
              icon: _isCapturing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.camera),
              label: const Text('Capture'),
            ),
          ],
        ),
      body: Column(
        children: [
          if (_error != null)
            Container(
              width: double.infinity,
              color: Colors.red.withValues(alpha: 0.08),
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _buildPreviewArea(),
            ),
          ),
          Expanded(flex: 2, child: _buildBottomPanel()),
        ],
      ),
      );
    }

    void _handleTitleTap() {
      final now = DateTime.now();
      final lastTap = _lastCalibrationTap;
      if (lastTap == null || now.difference(lastTap).inSeconds > 2) {
        _calibrationTapCount = 0;
      }
      _lastCalibrationTap = now;
      _calibrationTapCount += 1;
      if (_calibrationTapCount >= 10) {
        _calibrationTapCount = 0;
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const DisplayCalibrationScreen(),
          ),
        );
      }
    }

  Widget _buildPreviewArea() {
    final result = _captureResult;
    return LayoutBuilder(
      builder: (context, constraints) {
        Widget previewChild;
        if (result == null) {
          previewChild = Container(
            color: Colors.black12,
            child: const Center(
              child: Text(
                'Preview will show the live camera feed once connected.',
              ),
            ),
          );
        } else {
          final file = File(result.jpegPath);
          previewChild = ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(file, fit: BoxFit.cover),
          );
        }

        final roiRect = _normalizedRoi;

        return GestureDetector(
          onPanStart: result == null
              ? null
              : (details) => _startRoi(details, constraints),
          onPanUpdate: result == null
              ? null
              : (details) => _updateRoi(details.localPosition, constraints),
          onPanEnd: result == null ? null : (_) => _endRoi(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(child: previewChild),
              if (roiRect != null)
                Builder(
                  builder: (context) {
                    final displayRect = _imageRectToDisplayRect(
                      roiRect,
                      constraints,
                    );
                    return Positioned(
                      left: displayRect.left,
                      top: displayRect.top,
                      width: displayRect.width,
                      height: displayRect.height,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: Colors.orangeAccent,
                            width: 3,
                          ),
                          color: Colors.orangeAccent.withValues(alpha: 0.15),
                        ),
                      ),
                    );
                  },
                ),
              if (roiRect != null && _jpegPreviewImage != null)
                Positioned(
                  right: 16,
                  bottom: 16,
                  width: math.min(220, constraints.maxWidth * 0.5),
                  child: _RoiPreviewCard(
                    image: _jpegPreviewImage!,
                    normalizedRoi: roiRect,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBottomPanel() {
    final result = _captureResult;
    final roiRect = _normalizedRoi;
    final theme = Theme.of(context);
    final canConfirm = !_isProcessing && result != null && roiRect != null;

    String _rectValue(String key) {
      final rawRect = _lastRawRect;
      final value = rawRect?[key];
      if (value is num) {
        if (value == value.roundToDouble()) {
          return value.toStringAsFixed(0);
        }
        return value.toStringAsFixed(2);
      }
      return '--';
    }

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: const [
          BoxShadow(
            blurRadius: 10,
            color: Colors.black12,
            offset: Offset(0, -2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('ROI Mode'),
                ToggleButtons(
                  isSelected: [_mode == RoiMode.raw, _mode == RoiMode.jpeg],
                  onPressed: (index) {
                    final selected = index == 0 ? RoiMode.raw : RoiMode.jpeg;
                    if (selected == _mode) return;
                    if (selected == RoiMode.raw && !_hasCustomCcm) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'RAW mode requires a calibrated 3x3 CCM CSV. '
                            'Place roi_custom_ccm.csv in the roi_exports folder.',
                          ),
                        ),
                      );
                      return;
                    }
                    setState(() => _mode = selected);
                    if (_captureResult != null && _normalizedRoi != null) {
                      _confirmRoi(autoTriggered: true);
                    }
                  },
                  children: const [
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text('RAW'),
                    ),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text('JPEG'),
                    ),
                  ],
                ),
              ],
            ),
            if (!_hasCustomCcm)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'RAW mode disabled: add roi_custom_ccm.csv to enable calibrated RAW.',
                  style: TextStyle(fontSize: 12, color: Colors.redAccent),
                ),
              ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_showRoiDataPanel) ...[
                      if (result == null) ...[
                        const Text(
                          'No capture yet. Tap Capture to grab JPEG + DNG.',
                        ),
                      ] else ...[
                        _MetadataTile(
                          title: 'File paths',
                          lines: [
                            'JPEG: ${result.jpegPath}',
                            'DNG: ${result.dngPath}',
                            'RAW: ${result.rawBufferPath}',
                          ],
                        ),
                        const SizedBox(height: 8),
                        _MetadataTile(
                          title: 'Metadata',
                          lines: result.metadata.entries
                              .map((e) => '${e.key}: ${e.value}')
                              .toList(),
                        ),
                      ],
                      const SizedBox(height: 12),
                      if (_mode == RoiMode.raw) ...[
                        if (_lastXyz != null)
                          _MetadataTile(
                            title: 'Last XYZ',
                            lines: [
                              'X: ${_lastXyz![0].toStringAsFixed(4)}',
                              'Y: ${_lastXyz![1].toStringAsFixed(4)}',
                              'Z: ${_lastXyz![2].toStringAsFixed(4)}',
                            ],
                          ),
                        if (_lastRawRgb != null) ...[
                          const SizedBox(height: 8),
                          _MetadataTile(
                            title: 'Raw RGB (avg, normalized)',
                            lines: _formatVector(_lastRawRgb, const [
                              'R',
                              'G',
                              'B',
                            ]),
                          ),
                        ],
                        if (_lastLinearRgb != null) ...[
                          const SizedBox(height: 8),
                          _MetadataTile(
                            title: 'Balanced RGB (post WB)',
                            lines: _formatVector(_lastLinearRgb, const [
                              'R',
                              'G',
                              'B',
                            ]),
                          ),
                        ],
                        if (_lastWbGains != null) ...[
                          const SizedBox(height: 8),
                          _MetadataTile(
                            title: 'WB gains',
                            lines: _formatVector(_lastWbGains, const [
                              'R gain',
                              'G gain',
                              'B gain',
                            ]),
                          ),
                        ],
                        if (_lastRawpyXyz != null) ...[
                          const SizedBox(height: 8),
                          _MetadataTile(
                            title: 'Rawpy XYZ (0-1)',
                            lines: [
                              'X: ${_lastRawpyXyz![0].toStringAsFixed(4)}',
                              'Y: ${_lastRawpyXyz![1].toStringAsFixed(4)}',
                              'Z: ${_lastRawpyXyz![2].toStringAsFixed(4)}',
                            ],
                          ),
                        ],
                        if (_lastRawpySrgb != null) ...[
                          const SizedBox(height: 8),
                          _MetadataTile(
                            title: 'Rawpy sRGB (gamma)',
                            lines: _formatVector(_lastRawpySrgb, const [
                              'R',
                              'G',
                              'B',
                            ]),
                          ),
                        ],
                      ] else ...[
                        if (_lastJpegSrgb != null) ...[
                          _MetadataTile(
                            title: 'JPEG sRGB (gamma)',
                            lines: _formatVector(_lastJpegSrgb, const [
                              'R',
                              'G',
                              'B',
                            ]),
                          ),
                        ],
                        if (_lastJpegLinearRgb != null) ...[
                          const SizedBox(height: 8),
                          _MetadataTile(
                            title: 'JPEG linear RGB',
                            lines: _formatVector(_lastJpegLinearRgb, const [
                              'R',
                              'G',
                              'B',
                            ]),
                          ),
                        ],
                        if (_lastJpegXyz != null) ...[
                          const SizedBox(height: 8),
                          _MetadataTile(
                            title: 'JPEG XYZ (0-1)',
                            lines: [
                              'X: ${_lastJpegXyz![0].toStringAsFixed(4)}',
                              'Y: ${_lastJpegXyz![1].toStringAsFixed(4)}',
                              'Z: ${_lastJpegXyz![2].toStringAsFixed(4)}',
                            ],
                          ),
                        ],
                      ],
                      if (roiRect != null) ...[
                        const SizedBox(height: 12),
                        _MetadataTile(
                          title: 'Normalized ROI (0-1)',
                          lines: [
                            'Left: ${roiRect!.left.toStringAsFixed(3)}',
                            'Top: ${roiRect.top.toStringAsFixed(3)}',
                            'Right: ${roiRect.right.toStringAsFixed(3)}',
                            'Bottom: ${roiRect.bottom.toStringAsFixed(3)}',
                          ],
                        ),
                        if (_lastRawRect != null) ...[
                          const SizedBox(height: 8),
                          _MetadataTile(
                            title: 'RAW buffer ROI (px)',
                            lines: [
                              'Left: ${_rectValue('left')}',
                              'Top: ${_rectValue('top')}',
                              'Right: ${_rectValue('right')}',
                              'Bottom: ${_rectValue('bottom')}',
                            ],
                          ),
                        ],
                      ],
                      if (result != null && roiRect == null) ...[
                        const SizedBox(height: 12),
                        const Text(
                          'Draw an ROI on the preview to enable processing.',
                        ),
                      ],
                      const SizedBox(height: 16),
                    ] else ...[
                      const SizedBox(height: 4),
                    ],
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('ΔE threshold'),
                        Text(_deltaEThreshold.toStringAsFixed(1)),
                      ],
                    ),
                    Slider(
                      value: _deltaEThreshold,
                      min: 0.5,
                      max: 10,
                      divisions: 95,
                      label: _deltaEThreshold.toStringAsFixed(1),
                      onChanged: (value) =>
                          setState(() => _deltaEThreshold = value),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: canConfirm ? () => _confirmRoi() : null,
                            icon: _isProcessing
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.check),
                            label: Text(
                              _isProcessing ? 'Processing...' : 'Confirm ROI',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: _roiLog.isEmpty ? null : _dumpRoiLog,
                          icon: const Icon(Icons.archive_outlined),
                          label: Text('Export CSV (${_roiLog.length})'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_roiLog.isNotEmpty)
                      Text(
                        'Saved ROI entries: ${_roiLog.length}',
                        style: theme.textTheme.bodySmall,
                      ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('ΔE threshold'),
                        Text(_deltaEThreshold.toStringAsFixed(1)),
                      ],
                    ),
                    Slider(
                      value: _deltaEThreshold,
                      min: 0.5,
                      max: 10,
                      divisions: 95,
                      label: _deltaEThreshold.toStringAsFixed(1),
                      onChanged: (value) =>
                          setState(() => _deltaEThreshold = value),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: canConfirm ? () => _confirmRoi() : null,
                            icon: _isProcessing
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.check),
                            label: Text(
                              _isProcessing ? 'Processing...' : 'Confirm ROI',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: _roiLog.isEmpty ? null : _dumpRoiLog,
                          icon: const Icon(Icons.archive_outlined),
                          label: Text('Export CSV (${_roiLog.length})'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_roiLog.isNotEmpty)
                      Text(
                        'Saved ROI entries: ${_roiLog.length}',
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetadataTile extends StatelessWidget {
  const _MetadataTile({required this.title, required this.lines});

  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          for (int i = 0; i < lines.length; i++) ...[
            SelectableText(lines[i]),
            if (i != lines.length - 1) const SizedBox(height: 2),
          ],
        ],
      ),
    );
  }
}

class _RoiPreviewCard extends StatelessWidget {
  const _RoiPreviewCard({required this.image, required this.normalizedRoi});

  final ui.Image image;
  final Rect normalizedRoi;

  @override
  Widget build(BuildContext context) {
    final clamped = Rect.fromLTRB(
      normalizedRoi.left.clamp(0.0, 1.0),
      normalizedRoi.top.clamp(0.0, 1.0),
      normalizedRoi.right.clamp(0.0, 1.0),
      normalizedRoi.bottom.clamp(0.0, 1.0),
    );
    if (clamped.width <= 0 || clamped.height <= 0) {
      return const SizedBox.shrink();
    }
    final imageRect = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final source = Rect.fromLTRB(
      clamped.left * image.width,
      clamped.top * image.height,
      clamped.right * image.width,
      clamped.bottom * image.height,
    ).intersect(imageRect);
    if (source.isEmpty) {
      return const SizedBox.shrink();
    }
    final aspectRatio = source.height == 0 ? 1.0 : source.width / source.height;
    return Card(
      color: Colors.black.withOpacity(0.65),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'ROI 预览',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            AspectRatio(
              aspectRatio: aspectRatio,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CustomPaint(
                  painter: _RoiPreviewPainter(image: image, sourceRect: source),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '确认 ROI 是否与预期区域一致。',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoiPreviewPainter extends CustomPainter {
  _RoiPreviewPainter({required this.image, required this.sourceRect});

  final ui.Image image;
  final Rect sourceRect;

  @override
  void paint(Canvas canvas, Size size) {
    final dst = Offset.zero & size;
    final paint = Paint();
    canvas.drawImageRect(image, sourceRect, dst, paint);
    canvas.drawRect(
      dst.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withOpacity(0.8),
    );
  }

  @override
  bool shouldRepaint(covariant _RoiPreviewPainter oldDelegate) {
    return oldDelegate.image != image || oldDelegate.sourceRect != sourceRect;
  }
}

class _RoiDumpRecord {
  _RoiDumpRecord({
    required this.timestamp,
    required this.normalizedRoi,
    required this.rawRect,
    required this.rawRgb,
    required this.linearRgb,
    required this.xyz,
    required this.wbGains,
    required this.rawpyXyz,
    required this.rawpySrgb,
    required this.jpegSrgb,
    required this.jpegLinear,
    required this.jpegXyz,
    required this.camToXyzMatrix,
    required this.xyzToCamMatrix,
    required this.colorMatrixSource,
    required this.colorMatrixOriginal,
    required this.rawpyError,
    required this.colorCorrectionTransform,
    required this.colorMatrix1,
    required this.colorMatrix2,
    required this.sensorColorTransform1,
    required this.sensorColorTransform2,
    required this.forwardMatrix1,
    required this.forwardMatrix2,
  });

  final DateTime timestamp;
  final Rect normalizedRoi;
  final Map<String, num> rawRect;
  final List<double> rawRgb;
  final List<double> linearRgb;
  final List<double> xyz;
  final List<double> wbGains;
  final List<double> rawpyXyz;
  final List<double> rawpySrgb;
  final List<double> jpegSrgb;
  final List<double> jpegLinear;
  final List<double> jpegXyz;
  final List<double> camToXyzMatrix;
  final List<double> xyzToCamMatrix;
  final String colorMatrixSource;
  final List<double> colorMatrixOriginal;
  final String rawpyError;
  final List<double> colorCorrectionTransform;
  final List<double> colorMatrix1;
  final List<double> colorMatrix2;
  final List<double> sensorColorTransform1;
  final List<double> sensorColorTransform2;
  final List<double> forwardMatrix1;
  final List<double> forwardMatrix2;

  String toCsvRow() {
    final values = <String>[
      timestamp.toIso8601String(),
      normalizedRoi.left.toStringAsFixed(4),
      normalizedRoi.top.toStringAsFixed(4),
      normalizedRoi.right.toStringAsFixed(4),
      normalizedRoi.bottom.toStringAsFixed(4),
      '${rawRect['left']}',
      '${rawRect['top']}',
      '${rawRect['right']}',
      '${rawRect['bottom']}',
      _valueOrEmpty(rawRgb, 0),
      _valueOrEmpty(rawRgb, 1),
      _valueOrEmpty(rawRgb, 2),
      _valueOrEmpty(linearRgb, 0),
      _valueOrEmpty(linearRgb, 1),
      _valueOrEmpty(linearRgb, 2),
      _valueOrEmpty(xyz, 0),
      _valueOrEmpty(xyz, 1),
      _valueOrEmpty(xyz, 2),
      _valueOrEmpty(wbGains, 0),
      _valueOrEmpty(wbGains, 1),
      _valueOrEmpty(wbGains, 2),
      _valueOrEmpty(rawpyXyz, 0),
      _valueOrEmpty(rawpyXyz, 1),
      _valueOrEmpty(rawpyXyz, 2),
      _valueOrEmpty(rawpySrgb, 0),
      _valueOrEmpty(rawpySrgb, 1),
      _valueOrEmpty(rawpySrgb, 2),
      _valueOrEmpty(jpegSrgb, 0),
      _valueOrEmpty(jpegSrgb, 1),
      _valueOrEmpty(jpegSrgb, 2),
      _valueOrEmpty(jpegLinear, 0),
      _valueOrEmpty(jpegLinear, 1),
      _valueOrEmpty(jpegLinear, 2),
      _valueOrEmpty(jpegXyz, 0),
      _valueOrEmpty(jpegXyz, 1),
      _valueOrEmpty(jpegXyz, 2),
    ];
    values.addAll(_matrixValues(camToXyzMatrix, expected: 9));
    values.addAll(_matrixValues(xyzToCamMatrix, expected: 9));
    values.add(colorMatrixSource);
    values.addAll(_matrixValues(colorMatrixOriginal, expected: 9));
    values.add(rawpyError);
    values.addAll(_matrixValues(colorCorrectionTransform, expected: 9));
    values.addAll(_matrixValues(colorMatrix1, expected: 12));
    values.addAll(_matrixValues(colorMatrix2, expected: 12));
    values.addAll(_matrixValues(sensorColorTransform1, expected: 12));
    values.addAll(_matrixValues(sensorColorTransform2, expected: 12));
    values.addAll(_matrixValues(forwardMatrix1, expected: 12));
    values.addAll(_matrixValues(forwardMatrix2, expected: 12));
    return values.join(',');
  }

  String _valueOrEmpty(List<double> data, int index) {
    if (index >= data.length) return '';
    return data[index].toStringAsFixed(6);
  }

  List<String> _matrixValues(List<double> matrix, {required int expected}) {
    final entries = <String>[];
    for (var i = 0; i < expected; i++) {
      entries.add(i < matrix.length ? matrix[i].toStringAsFixed(6) : '');
    }
    return entries;
  }
}
