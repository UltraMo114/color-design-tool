import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:colordesign_tool_core/src/common/util.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math.dart' show Vector3;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/native_camera_channel.dart';

enum ChartTemplate { mcc4x6, pmcc5x6 }

class CameraCalibrationScreen extends StatefulWidget {
  const CameraCalibrationScreen({super.key});

  @override
  State<CameraCalibrationScreen> createState() => _CameraCalibrationScreenState();
}

class _CameraCalibrationScreenState extends State<CameraCalibrationScreen> {
  ChartTemplate _template = ChartTemplate.pmcc5x6;
  int _rows = 5;
  int _cols = 6;
  int _rotation = 0; // 0,1,2,3 => 0,90,180,270
  bool _flipH = false;
  bool _flipV = false;
  Rect? _normalizedRoi;
  Offset? _dragStartNormalized;
  ui.Image? _jpegPreviewImage;
  double? _decodedImageWidth;
  double? _decodedImageHeight;

  CameraCaptureResult? _captureResult;
  bool _busy = false;
  String? _error;

  // Reference XYZ for each patch (row-major), units 0..1 or 0..100 both ok (will be normalized consistently)
  List<List<double>>? _refXyz;
  String? _refName;

  // Latest solved CCM 3x3 (row-major camRGB->XYZ)
  List<double>? _solvedCamToXyz;
  double? _meanDeltaE;
  double? _maxDeltaE;

  @override
  void initState() {
    super.initState();
    _loadDefaultRef();
  }

  Future<void> _loadDefaultRef() async {
    try {
      if (_template == ChartTemplate.pmcc5x6) {
        final raw = await rootBundle.loadString('assets/calibration/pmc_xyz.csv');
        final xyz = _parseXyzCsv(raw);
        setState(() {
          _rows = 5;
          _cols = 6;
          _refXyz = xyz;
          _refName = 'PMCC (assets)';
        });
      } else {
        // Try optional MCC asset; user can import if absent.
        try {
          final raw = await rootBundle.loadString('assets/calibration/mcc_xyz.csv');
          final xyz = _parseXyzCsv(raw);
          setState(() {
            _rows = 4;
            _cols = 6;
            _refXyz = xyz;
            _refName = 'MCC (assets)';
          });
        } catch (_) {
          setState(() {
            _rows = 4;
            _cols = 6;
            _refXyz = null;
            _refName = 'MCC: please import CSV';
          });
        }
      }
    } catch (e) {
      setState(() {
        _refXyz = null;
        _refName = 'Failed to load reference: $e';
      });
    }
  }

  List<List<double>> _parseXyzCsv(String raw) {
    final lines = raw.split(RegExp(r'\r?\n'));
    final out = <List<double>>[];
    for (final line in lines) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final parts = t.split(RegExp(r'[;,\t, ]+'));
      if (parts.length < 3) continue;
      final x = double.tryParse(parts[0]);
      final y = double.tryParse(parts[1]);
      final z = double.tryParse(parts[2]);
      if (x == null || y == null || z == null) continue;
      out.add([x, y, z]);
    }
    if (out.isEmpty) {
      throw StateError('No XYZ rows parsed');
    }
    return out;
  }

  Future<void> _pickReferenceCsv() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowMultiple: false,
      allowedExtensions: const ['csv', 'txt'],
    );
    final filePath = res?.files.single.path;
    if (filePath == null) return;
    try {
      final content = await File(filePath).readAsString();
      final xyz = _parseXyzCsv(content);
      setState(() {
        _refXyz = xyz;
        _refName = p.basename(filePath);
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to parse CSV: $e')),
      );
    }
  }

  Future<void> _startCapture() async {
    setState(() {
      _busy = true;
      _error = null;
      _normalizedRoi = null;
      _jpegPreviewImage?.dispose();
      _jpegPreviewImage = null;
      _decodedImageWidth = null;
      _decodedImageHeight = null;
      _solvedCamToXyz = null;
      _meanDeltaE = null;
      _maxDeltaE = null;
    });
    try {
      final result = await NativeCameraChannel.instance.startCapture();
      if (!mounted) return;
      setState(() {
        _captureResult = result;
      });
      await _decodePreviewImage(result.jpegPath);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
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
    } catch (e) {
      debugPrint('decode JPEG failed: $e');
    }
  }

  void _startRoi(DragStartDetails details, BoxConstraints constraints) {
    _dragStartNormalized = _boxToImageNormalized(details.localPosition, constraints);
    _updateRoi(details.localPosition, constraints);
  }

  void _updateRoi(Offset localPosition, BoxConstraints constraints) {
    final normalizedStart =
        _dragStartNormalized ?? _boxToImageNormalized(localPosition, constraints);
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

  Offset _boxToImageNormalized(Offset position, BoxConstraints constraints) {
    final size = _effectiveDisplaySize();
    final boxWidth = constraints.maxWidth;
    final boxHeight = constraints.maxHeight;
    if (boxWidth <= 0 || boxHeight <= 0 || size.width <= 0 || size.height <= 0) {
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
    if (boxWidth <= 0 || boxHeight <= 0 || size.width <= 0 || size.height <= 0) {
      return Rect.zero;
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
      final normalized = ((orientationValue.toInt() % 360) + 360) % 360;
      return normalized == 90 || normalized == 270;
    }
    return false;
  }

  double _computePreviewAspectRatio() {
    final size = _effectiveDisplaySize();
    if (size.width > 0 && size.height > 0) {
      return size.width / size.height;
    }
    return 4 / 3;
  }

  double? _metadataDouble(Map<String, dynamic> metadata, String key) {
    final value = metadata[key];
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  Future<Directory> _getDumpDirectory() async {
    final external = await getExternalStorageDirectories(type: StorageDirectory.documents);
    final baseDir = (external != null && external.isNotEmpty)
        ? external.first
        : await getApplicationDocumentsDirectory();
    final target = Directory(p.join(baseDir.path, 'roi_exports'));
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    return target;
  }

  Future<void> _computeAndSave({bool saveOnly = false}) async {
    if (_captureResult == null || _normalizedRoi == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Capture and draw ROI first')),
      );
      return;
    }
    final refs = _refXyz;
    if (refs == null || refs.length < _rows * _cols) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Missing reference XYZ; import or select template')),
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _solvedCamToXyz = null;
      _meanDeltaE = null;
      _maxDeltaE = null;
    });
    try {
      final capture = _captureResult!;
      final roi = _normalizedRoi!;
      final patchRects = _makePatchRects(roi, _rows, _cols, _rotation, _flipH, _flipV);
      final linearRgbs = <List<double>>[];
      for (final rect in patchRects) {
        final res = await NativeCameraChannel.instance.processRoi(
          capture: capture,
          normalizedRoi: rect,
          mode: 'raw',
          skipWhiteBalance: true,
        );
        if (res.rawRgb.length < 3 && res.linearRgb.length < 3) {
          throw StateError('ROI returned no RAW linear RGB');
        }
        final rr = (res.rawRgb.length >= 3) ? res.rawRgb : res.linearRgb;
        linearRgbs.add([rr[0], rr[1], rr[2]]);
      }
      // Solve least squares for camRGB->XYZ
      final M = _solveLeastSquares3x3(linearRgbs, refs.take(patchRects.length).toList());
      // Evaluate Î”E76
      final e = _evaluateDeltaE(M, linearRgbs, refs.take(patchRects.length).toList());
      setState(() {
        _solvedCamToXyz = M;
        _meanDeltaE = e.$1;
        _maxDeltaE = e.$2;
      });
      if (!saveOnly) return;
      await _saveMatrixCsv(M);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved CCM to roi_exports/roi_custom_ccm.csv')),
      );
    } catch (e, st) {
      debugPrint('compute CCM failed: $e\n$st');
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveMatrixCsv(List<double> M) async {
    final dir = await _getDumpDirectory();
    final file = File(p.join(dir.path, 'roi_custom_ccm.csv'));
    final content = M.map((v) => v.toString()).join(',');
    await file.writeAsString(content);
  }

  List<Rect> _makePatchRects(
    Rect roi,
    int rows,
    int cols,
    int rotationQuarter,
    bool flipH,
    bool flipV,
  ) {
    final list = <Rect>[];
    final cellW = (roi.right - roi.left) / cols;
    final cellH = (roi.bottom - roi.top) / rows;
    // shrink factor to sample center region
    const shrink = 0.6; // keep 60% of cell width/height
    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        final mapped = _mapIndex(r, c, rows, cols, rotationQuarter, flipH, flipV);
        final rr = mapped.$1;
        final cc = mapped.$2;
        final left = roi.left + cc * cellW;
        final top = roi.top + rr * cellH;
        final right = left + cellW;
        final bottom = top + cellH;
        final cx = (left + right) / 2;
        final cy = (top + bottom) / 2;
        final w2 = cellW * shrink / 2;
        final h2 = cellH * shrink / 2;
        list.add(Rect.fromLTRB(cx - w2, cy - h2, cx + w2, cy + h2));
      }
    }
    return list;
  }

  (int, int) _mapIndex(
    int r,
    int c,
    int rows,
    int cols,
    int rotationQuarter,
    bool flipH,
    bool flipV,
  ) {
    int rr = r;
    int cc = c;
    if (flipH) cc = cols - 1 - cc;
    if (flipV) rr = rows - 1 - rr;
    for (int k = 0; k < ((rotationQuarter % 4) + 4) % 4; k++) {
      final nr = cc;
      final nc = rows - 1 - rr;
      rr = nr;
      cc = nc;
      final t = rows;
      rows = cols;
      cols = t;
    }
    return (rr, cc);
  }

  List<double> _solveLeastSquares3x3(List<List<double>> camRgb, List<List<double>> xyz) {
    // Build R^T R and R^T X
    double r00 = 0, r01 = 0, r02 = 0, r11 = 0, r12 = 0, r22 = 0;
    double x00 = 0, x01 = 0, x02 = 0; // column X for X
    double y00 = 0, y01 = 0, y02 = 0; // column X for Y
    double z00 = 0, z01 = 0, z02 = 0; // column X for Z
    for (int i = 0; i < camRgb.length; i++) {
      final r = camRgb[i][0];
      final g = camRgb[i][1];
      final b = camRgb[i][2];
      final X = xyz[i][0];
      final Y = xyz[i][1];
      final Z = xyz[i][2];
      r00 += r * r; r01 += r * g; r02 += r * b; r11 += g * g; r12 += g * b; r22 += b * b;
      x00 += r * X; x01 += g * X; x02 += b * X;
      y00 += r * Y; y01 += g * Y; y02 += b * Y;
      z00 += r * Z; z01 += g * Z; z02 += b * Z;
    }
    final RtR = [
      r00, r01, r02,
      r01, r11, r12,
      r02, r12, r22,
    ];
    final inv = _invert3x3(RtR) ?? RtR; // fallback to RtR (shouldn't happen often)
    List<double> mult(List<double> A, List<double> b) {
      return [
        A[0]*b[0] + A[1]*b[1] + A[2]*b[2],
        A[3]*b[0] + A[4]*b[1] + A[5]*b[2],
        A[6]*b[0] + A[7]*b[1] + A[8]*b[2],
      ];
    }
    final m0 = mult(inv, [x00, x01, x02]);
    final m1 = mult(inv, [y00, y01, y02]);
    final m2 = mult(inv, [z00, z01, z02]);
    return [
      m0[0], m0[1], m0[2],
      m1[0], m1[1], m1[2],
      m2[0], m2[1], m2[2],
    ];
  }

  (double, double) _evaluateDeltaE(List<double> M, List<List<double>> camRgb, List<List<double>> xyzRef) {
    double sum = 0;
    double maxE = 0;
    final white = Vector3(0.95047, 1.0, 1.08883);
    for (int i = 0; i < camRgb.length; i++) {
      final r = camRgb[i];
      final x = [
        M[0]*r[0] + M[1]*r[1] + M[2]*r[2],
        M[3]*r[0] + M[4]*r[1] + M[5]*r[2],
        M[6]*r[0] + M[7]*r[1] + M[8]*r[2],
      ];
      final vEst = Vector3(x[0].toDouble(), x[1].toDouble(), x[2].toDouble());
      final vRef = Vector3(xyzRef[i][0].toDouble(), xyzRef[i][1].toDouble(), xyzRef[i][2].toDouble());
      final labEst = xyzToLab(vEst, white);
      final labRef = xyzToLab(vRef, white);
      final dE = math.sqrt(
        math.pow(labEst.x - labRef.x, 2) +
        math.pow(labEst.y - labRef.y, 2) +
        math.pow(labEst.z - labRef.z, 2),
      );
      sum += dE;
      if (dE > maxE) maxE = dE;
    }
    return (sum / camRgb.length, maxE);
  }

  List<double>? _invert3x3(List<double> m) {
    if (m.length < 9) return null;
    final a = m[0], b = m[1], c = m[2];
    final d = m[3], e = m[4], f = m[5];
    final g = m[6], h = m[7], i = m[8];
    final A = (e * i - f * h);
    final B = -(d * i - f * g);
    final C = (d * h - e * g);
    final D = -(b * i - c * h);
    final E = (a * i - c * g);
    final F = -(a * h - b * g);
    final G = (b * f - c * e);
    final H = -(a * f - c * d);
    final I = (a * e - b * d);
    final det = a * A + b * B + c * C;
    if (det.abs() < 1e-12) return null;
    final invDet = 1.0 / det;
    return [
      A * invDet, D * invDet, G * invDet,
      B * invDet, E * invDet, H * invDet,
      C * invDet, F * invDet, I * invDet,
    ];
  }

  @override
  void dispose() {
    _jpegPreviewImage?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Camera Calibration'),
        actions: [
          IconButton(
            tooltip: 'Capture',
            onPressed: _busy ? null : _startCapture,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.camera),
          ),
          IconButton(
            tooltip: 'Import Reference CSV',
            onPressed: _busy ? null : _pickReferenceCsv,
            icon: const Icon(Icons.file_open),
          ),
          IconButton(
            tooltip: 'Compute',
            onPressed: _busy ? null : () => _computeAndSave(saveOnly: false),
            icon: const Icon(Icons.calculate),
          ),
          IconButton(
            tooltip: 'Save & Apply',
            onPressed: _busy || _solvedCamToXyz == null ? null : () => _computeAndSave(saveOnly: true),
            icon: const Icon(Icons.save_alt),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            Container(
              width: double.infinity,
              color: Colors.red.withOpacity(0.08),
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        SegmentedButton<ChartTemplate>(
                          segments: const [
                            ButtonSegment(value: ChartTemplate.mcc4x6, label: Text('MCC 4x6')),
                            ButtonSegment(value: ChartTemplate.pmcc5x6, label: Text('PMCC 5x6')),
                          ],
                          selected: {_template},
                          onSelectionChanged: (v) {
                            setState(() => _template = v.first);
                            _loadDefaultRef();
                          },
                        ),
                        const SizedBox(width: 12),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 360),
                          child: Text(
                            _refName ?? 'No reference',
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Rotate 90¡ã',
                  onPressed: () => setState(() => _rotation = (_rotation + 1) % 4),
                  icon: const Icon(Icons.rotate_90_degrees_ccw),
                ),
                IconButton(
                  tooltip: 'Flip H',
                  onPressed: () => setState(() => _flipH = !_flipH),
                  icon: Icon(_flipH ? Icons.flip : Icons.flip_outlined),
                ),
                IconButton(
                  tooltip: 'Flip V',
                  onPressed: () => setState(() => _flipV = !_flipV),
                  icon: const Icon(Icons.flip_camera_android_outlined),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _buildPreview(),
            ),
          ),
          if (_solvedCamToXyz != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Row(
                children: [
                  Text('Î”E mean: ${_meanDeltaE?.toStringAsFixed(2) ?? '-'}  max: ${_maxDeltaE?.toStringAsFixed(2) ?? '-'}'),
                  const Spacer(),
                  Text('CCM: ${_solvedCamToXyz!.map((e) => e.toStringAsFixed(4)).join(', ')}'),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    final img = _jpegPreviewImage;
    if (img == null) {
      return const Center(
        child: Text('Capture a frame, then draw ROI over the chart'),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        return AspectRatio(
          aspectRatio: _computePreviewAspectRatio(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (d) => _startRoi(d, constraints),
            onPanUpdate: (d) => _updateRoi(d.localPosition, constraints),
            onPanEnd: (_) => _endRoi(),
            child: CustomPaint(
              painter: _PreviewPainter(
                image: img,
                roi: _normalizedRoi != null ? _imageRectToDisplayRect(_normalizedRoi!, constraints) : null,
                rows: _rows,
                cols: _cols,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PreviewPainter extends CustomPainter {
  _PreviewPainter({
    required this.image,
    required this.roi,
    required this.rows,
    required this.cols,
  });

  final ui.Image image;
  final Rect? roi;
  final int rows;
  final int cols;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    final src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final dst = _letterboxDst(size, image.width.toDouble(), image.height.toDouble());
    canvas.drawImageRect(image, src, dst, paint);

    if (roi != null) {
      final r = roi!;
      final rectPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.tealAccent;
      canvas.drawRect(r, rectPaint);

      // grid
      final gridPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.tealAccent.withOpacity(0.7);
      final cellW = (r.right - r.left) / cols;
      final cellH = (r.bottom - r.top) / rows;
      for (int c = 1; c < cols; c++) {
        final x = r.left + c * cellW;
        canvas.drawLine(Offset(x, r.top), Offset(x, r.bottom), gridPaint);
      }
      for (int rr = 1; rr < rows; rr++) {
        final y = r.top + rr * cellH;
        canvas.drawLine(Offset(r.left, y), Offset(r.right, y), gridPaint);
      }
    }
  }

  Rect _letterboxDst(Size box, double iw, double ih) {
    final scale = math.max(box.width / iw, box.height / ih);
    final sw = iw * scale;
    final sh = ih * scale;
    final dx = (sw - box.width) / 2;
    final dy = (sh - box.height) / 2;
    return Rect.fromLTWH(-dx, -dy, sw, sh);
  }

  @override
  bool shouldRepaint(covariant _PreviewPainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.roi != roi ||
        oldDelegate.rows != rows ||
        oldDelegate.cols != cols;
  }
}


