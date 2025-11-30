import 'package:colordesign_tool_core/src/models/color_stimulus.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:vector_math/vector_math.dart' show Vector3;

import '../providers/display_profile_provider.dart';

import '../services/color_library_service.dart';

class ColorLibrarySearchScreen extends StatefulWidget {
  const ColorLibrarySearchScreen({
    super.key,
    required this.target,
  });

  final ColorStimulus target;

  @override
  State<ColorLibrarySearchScreen> createState() =>
      _ColorLibrarySearchScreenState();
}

class _ColorLibrarySearchScreenState extends State<ColorLibrarySearchScreen> {
  double _threshold = 2.0;
  bool _loading = true;
  String? _error;
  List<ColorLibraryMatch> _matches = const [];
  List<ColorLibraryMatch> _allMatches = const [];
  List<ColorLibrarySource> _sources = const [];
  static const String _allSourcesKey = '__all__';
  String? _selectedLibraryId;

  @override
  void initState() {
    super.initState();
    _runSearch();
  }

  Future<void> _runSearch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final service = context.read<ColorLibraryService>();
      await service.ensureLoaded();
      final enabledSources =
          service.sources.where((s) => s.enabled).toList(growable: false);
      final matches = service.findMatches(
        target: widget.target,
        threshold: _threshold,
      );
      if (!mounted) return;
      setState(() {
        _sources = enabledSources;
        if (_selectedLibraryId != null &&
            !_sources.any((s) => s.id == _selectedLibraryId)) {
          _selectedLibraryId = null;
        }
        _allMatches = matches;
        _matches = _filterMatches(_selectedLibraryId);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lab = widget.target.appearance?.lab_value;
    final profile = context.read<DisplayProfileProvider>();
    final v = widget.target.scientific_core.xyz_value;
    final vec = profile.mapXyzToRgb(Vector3(v[0], v[1], v[2]))
      ..clamp(Vector3.zero(), Vector3.all(1.0));
    final targetColor = Color.fromRGBO(
      (vec.x * 255).clamp(0, 255).round(),
      (vec.y * 255).clamp(0, 255).round(),
      (vec.z * 255).clamp(0, 255).round(),
      1,
    );

    final labText = lab == null
        ? '--'
        : 'L ${lab[0].toStringAsFixed(2)}  '
            'a ${lab[1].toStringAsFixed(2)}  '
            'b ${lab[2].toStringAsFixed(2)}';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Database Matches'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: targetColor,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.black26),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.target.u_name ?? 'Selected Color',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        labText,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                const Text('ΔE76 threshold'),
                const SizedBox(width: 12),
                Expanded(
                  child: Slider(
                    min: 0.5,
                    max: 5.0,
                    divisions: 9,
                    label: _threshold.toStringAsFixed(1),
                    value: _threshold,
                    onChanged: (v) {
                      setState(() {
                        _threshold = v;
                      });
                    },
                    onChangeEnd: (_) => _runSearch(),
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text(
                    _threshold.toStringAsFixed(1),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
          if (_sources.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  const Text('Source'),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _selectedLibraryId ?? _allSourcesKey,
                      items: [
                        DropdownMenuItem<String>(
                          value: _allSourcesKey,
                          child: const Text('All databases'),
                        ),
                        ..._sources.map(
                          (s) => DropdownMenuItem<String>(
                            value: s.id,
                            child: Text(s.id),
                          ),
                        ),
                      ],
                      onChanged: (value) {
                        setState(() {
                          _selectedLibraryId =
                              value == _allSourcesKey ? null : value;
                          _matches = _filterMatches(_selectedLibraryId);
                        });
                      },
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: _buildBody(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _error!,
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.red),
          ),
        ),
      );
    }
    if (_matches.isEmpty) {
      return Center(
        child: Text(
          'No matches found in the current libraries.',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemBuilder: (context, index) {
        final match = _matches[index];
        final s = match.stimulus;
        final profile = context.read<DisplayProfileProvider>();
        final v = s.scientific_core.xyz_value;
        final vec = profile.mapXyzToRgb(Vector3(v[0], v[1], v[2]))
          ..clamp(Vector3.zero(), Vector3.all(1.0));
        final lab = s.appearance?.lab_value;

        final color = Color.fromRGBO(
          (vec.x * 255).clamp(0, 255).round(),
          (vec.y * 255).clamp(0, 255).round(),
          (vec.z * 255).clamp(0, 255).round(),
          1,
        );

        final labText = lab == null
            ? '--'
            : 'L ${lab[0].toStringAsFixed(2)}  '
                'a ${lab[1].toStringAsFixed(2)}  '
                'b ${lab[2].toStringAsFixed(2)}';

        final name = s.source.s_name ?? s.u_name ?? s.id;

        return ListTile(
          leading: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.black26),
            ),
          ),
          title: Text(name),
          subtitle: Text(
            'ΔE76 ${match.deltaE.toStringAsFixed(2)}   $labText\n'
            'Source: ${match.libraryId}',
            style: theme.textTheme.bodySmall,
          ),
        );
      },
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemCount: _matches.length,
    );
  }

  List<ColorLibraryMatch> _filterMatches(String? libraryId) {
    if (libraryId == null) {
      return List<ColorLibraryMatch>.from(_allMatches);
    }
    return _allMatches
        .where((m) => m.libraryId == libraryId)
        .toList(growable: false);
  }
}
