import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/native_camera_channel.dart';

class CameraCaptureDebugScreen extends StatefulWidget {
  const CameraCaptureDebugScreen({super.key});

  @override
  State<CameraCaptureDebugScreen> createState() =>
      _CameraCaptureDebugScreenState();
}

class _CameraCaptureDebugScreenState extends State<CameraCaptureDebugScreen> {
  CameraCaptureResult? _result;
  bool _isCapturing = false;
  String? _error;
  bool _bypassCcm = false;
  String? _metadataDumpPath;
  String? _metadataDumpError;

  @override
  void initState() {
    super.initState();
    _pushDebugConfig();
  }

  Map<String, dynamic> get _debugConfig => {'bypassCCM': _bypassCcm};

  void _pushDebugConfig() {
    NativeCameraChannel.instance.updateDebugConfig(_debugConfig);
  }

  void _updateDebugConfig({bool? bypassCcm}) {
    setState(() {
      if (bypassCcm != null) {
        _bypassCcm = bypassCcm;
      }
    });
    _pushDebugConfig();
  }

  Future<void> _startCapture() async {
    setState(() {
      _isCapturing = true;
      _error = null;
      _metadataDumpPath = null;
      _metadataDumpError = null;
    });

    try {
      final result = await NativeCameraChannel.instance.startCapture();
      String? metadataPath;
      String? metadataError;
      try {
        metadataPath = await _dumpMetadataToJson(result);
      } catch (err) {
        metadataError = err.toString();
        debugPrint('Failed to dump capture metadata: $metadataError');
      }
      if (!mounted) return;
      setState(() {
        _result = result;
        _metadataDumpPath = metadataPath;
        _metadataDumpError = metadataError;
      });
      if (metadataPath != null) {
        _showSnackBar('Metadata saved to $metadataPath');
      } else if (metadataError != null) {
        _showSnackBar('Failed to save metadata JSON');
      }
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

  Future<String?> _dumpMetadataToJson(CameraCaptureResult capture) async {
    if (capture.metadata.isEmpty) {
      return null;
    }
    final dngFile = File(capture.dngPath);
    final directory = dngFile.parent;
    final baseName = dngFile.uri.pathSegments.isNotEmpty
        ? dngFile.uri.pathSegments.last
        : 'capture';
    final dotIndex = baseName.lastIndexOf('.');
    final stem = dotIndex == -1 ? baseName : baseName.substring(0, dotIndex);
    final file = File(
      '${directory.path}/'
      '${stem}_metadata.json',
    );
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(capture.metadata));
    return file.path;
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('Camera Capture Debug')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'This stub screen calls the native Camera2 pipeline to capture JPEG + DNG.',
          ),
          const SizedBox(height: 12),
          _buildDebugConfigSection(),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _isCapturing ? null : _startCapture,
            icon: const Icon(Icons.camera_alt_outlined),
            label: const Text('Start Native Capture'),
          ),
          const SizedBox(height: 12),
          if (_isCapturing) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            const Text('Capturing...'),
          ],
          if (_error != null) ...[
            Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 8),
          ],
          if (result != null) ...[
            _ResultTile(label: 'JPEG Path', value: result.jpegPath),
            _ResultTile(label: 'DNG Path', value: result.dngPath),
            _ResultTile(label: 'RAW Buffer Path', value: result.rawBufferPath),
            if (result.metadata.isNotEmpty)
              _ResultTile(
                label: 'Metadata JSON',
                value:
                    _metadataDumpPath ??
                    (_metadataDumpError != null
                        ? 'Failed: $_metadataDumpError'
                        : 'Metadata not saved'),
              ),
            const SizedBox(height: 8),
            Text('Metadata', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            if (result.metadata.isEmpty)
              const Text('No metadata returned.')
            else
              ...result.metadata.entries.map(
                (entry) =>
                    _ResultTile(label: entry.key, value: '${entry.value}'),
              ),
            const SizedBox(height: 12),
            _buildJpegPreview(result.jpegPath),
          ],
        ],
      ),
    );
  }

  Widget _buildDebugConfigSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Pipeline Debug Options',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Bypass CCM'),
          subtitle: const Text('Skip the Color Correction stage.'),
          value: _bypassCcm,
          onChanged: (value) => _updateDebugConfig(bypassCcm: value),
        ),
      ],
    );
  }

  Widget _buildJpegPreview(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      return _ResultTile(
        label: 'JPEG Preview',
        value: 'File not found ($path)',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('JPEG Preview'),
        const SizedBox(height: 4),
        AspectRatio(
          aspectRatio: 4 / 3,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(file, fit: BoxFit.cover),
          ),
        ),
      ],
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.black12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          SelectableText(value),
        ],
      ),
    );
  }
}
