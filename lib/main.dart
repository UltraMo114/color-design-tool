import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:colordesign_tool_core/src/models/color_stimulus.dart';

import 'providers/palette_provider.dart';
import 'screens/camera_capture_screen.dart';
import 'screens/colorway_screen.dart';
import 'screens/color_library_search_screen.dart';
import 'services/color_library_service.dart';
import 'package:path/path.dart' as path;

void main() {
  runApp(const CDTApp());
}

class CDTApp extends StatelessWidget {
  const CDTApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => PaletteProvider()),
        Provider<ColorLibraryService>(
          create: (_) => ColorLibraryService.withPresetQtx(),
        ),
      ],
      child: MaterialApp(
        title: 'Color Design Tool',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          useMaterial3: true,
        ),
        home: const PaletteScreen(),
      ),
    );
  }
}

class PaletteScreen extends StatelessWidget {
  const PaletteScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<PaletteProvider>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('ColorWay Buffer'),
        actions: [
          IconButton(
            tooltip: 'Camera Capture',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CameraCaptureScreen()),
              );
            },
            icon: const Icon(Icons.camera_alt_outlined),
          ),
          IconButton(
            tooltip: 'Colorway',
            onPressed: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const ColorwayScreen()));
            },
            icon: const Icon(Icons.palette_outlined),
          ),
          IconButton(
            tooltip: 'Import QTX',
            onPressed: () async {
              final res = await FilePicker.platform.pickFiles(
                type: FileType.custom,
                allowMultiple: false,
                allowedExtensions: const ['qtx', 'cxf', 'cxf3', 'txt'],
              );
              final filePath = res?.files.single.path;
              if (filePath == null) return;
              final added = await context.read<PaletteProvider>().importQtx(
                filePath,
              );
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    added > 0 ? 'Imported $added colors' : 'No colors imported',
                  ),
                ),
              );
            },
            icon: const Icon(Icons.folder_open),
          ),
          IconButton(
            tooltip: 'Export QTX',
            onPressed: () async {
              final filePath = await context
                  .read<PaletteProvider>()
                  .exportQtx();
              if (filePath == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('No colors to export')),
                );
              } else {
                final fileName = path.basename(filePath);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Exported to $fileName (app documents)'),
                  ),
                );
              }
            },
            icon: const Icon(Icons.save_alt),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Expanded(child: _PaletteGrid(provider: provider)),
            const SizedBox(height: 12),
            _ColorAttributeCard(provider: provider),
          ],
        ),
      ),
    );
  }
}

class _PaletteGrid extends StatelessWidget {
  const _PaletteGrid({required this.provider});

  final PaletteProvider provider;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 5,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemCount: 20,
      itemBuilder: (context, index) {
        final isEmpty = provider.isPositionEmpty(index);
        final isSelected = provider.primarySelection == index;
        final color = isEmpty
            ? Colors.transparent
            : _colorFromStimulus(provider.getColorAt(index));
        return InkWell(
          onTap: isEmpty ? null : () => provider.selectSingle(index),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              color: isEmpty ? Colors.transparent : color,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isSelected ? Colors.black : Colors.black26,
                width: isSelected ? 2 : 1,
              ),
            ),
            child: isEmpty
                ? const Center(child: Icon(Icons.add, color: Colors.black26))
                : null,
          ),
        );
      },
    );
  }

  Color _colorFromStimulus(ColorStimulus stimulus) {
    final rep = stimulus.display_representations['sRGB'];
    if (rep == null) return Colors.grey;
    return Color.fromRGBO(
      (rep.rgb_values[0] * 255).clamp(0, 255).round(),
      (rep.rgb_values[1] * 255).clamp(0, 255).round(),
      (rep.rgb_values[2] * 255).clamp(0, 255).round(),
      1,
    );
  }
}

class _ColorAttributeCard extends StatelessWidget {
  const _ColorAttributeCard({required this.provider});

  final PaletteProvider provider;

  @override
  Widget build(BuildContext context) {
    final index = provider.primarySelection;
    ColorStimulus? stimulus;
    if (index != null && !provider.isPositionEmpty(index)) {
      stimulus = provider.getColorAt(index);
    }

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: stimulus == null
            ? const Text(
                'Select a color from the palette to inspect its attributes.',
              )
            : _buildContent(stimulus),
      ),
    );
  }

  Widget _buildContent(ColorStimulus stimulus) {
    final appearance = stimulus.appearance;
    final jch = appearance?.JCh;
    final lab = appearance?.lab_value;
    final srgb = stimulus.display_representations['sRGB'];

    final sCamText = jch == null
        ? '--'
        : 'I ${jch[0].toStringAsFixed(2)}  C ${jch[1].toStringAsFixed(2)}  h ${jch[2].toStringAsFixed(2)}';
    final labText = lab == null
        ? '--'
        : 'L ${lab[0].toStringAsFixed(2)}  a ${lab[1].toStringAsFixed(2)}  b ${lab[2].toStringAsFixed(2)}';
    final srgbText = srgb == null
        ? '--'
        : 'R ${(srgb.rgb_values[0] * 255).clamp(0, 255).round()}  '
              'G ${(srgb.rgb_values[1] * 255).clamp(0, 255).round()}  '
              'B ${(srgb.rgb_values[2] * 255).clamp(0, 255).round()}';

    return Builder(
      builder: (context) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              stimulus.u_name ?? 'Untitled Color',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            _detailRow('sCAM Iab', sCamText),
            _detailRow('CIELAB Lab', labText),
            _detailRow('sRGB', srgbText),
            _detailRow('Source', stimulus.source.type),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          ColorLibrarySearchScreen(target: stimulus),
                    ),
                  );
                },
                child: const Text('Search in QTX database'),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
