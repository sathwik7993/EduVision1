import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/sheet_template.dart';
import '../services/roster_service.dart';
import '../services/template_store.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';
import 'template_editor_page.dart';

/// Sheet layouts (one per college or exam) and the class roster.
class TemplatesPage extends StatefulWidget {
  const TemplatesPage({super.key});

  @override
  State<TemplatesPage> createState() => _TemplatesPageState();
}

class _TemplatesPageState extends State<TemplatesPage> {
  List<SheetTemplate> _templates = const [];
  String? _activeId;
  Roster _roster = Roster.empty;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final templates = await TemplateStore.instance.all();
    final activeId = await TemplateStore.instance.activeId();
    final roster = await RosterService.instance.load();
    if (!mounted) return;
    setState(() {
      _templates = templates;
      _activeId = activeId;
      _roster = roster;
      _loading = false;
    });
  }

  Future<void> _edit([SheetTemplate? template]) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TemplateEditorPage(template: template)),
    );
    _refresh();
  }

  Future<void> _delete(SheetTemplate template) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text('Delete template?'),
        content: Text('"${template.name}" and its boxes will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await TemplateStore.instance.delete(template.id);
    final image = template.sampleImagePath;
    if (image != null) {
      try {
        await File(image).delete();
      } on FileSystemException {
        // Already gone.
      }
    }
    _refresh();
  }

  Future<void> _importRoster() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['xlsx'],
      );
      final path = file?.path;
      if (path == null) return;
      final roster = Roster.fromExcel(await File(path).readAsBytes());
      if (roster.isEmpty) {
        _toast('No registration numbers found in that file.');
        return;
      }
      await RosterService.instance.save(roster);
      _toast('Imported ${roster.registrations.length} students.');
      _refresh();
    } on Exception catch (e) {
      _toast('Could not read that file: $e');
    }
  }

  Future<void> _clearRoster() async {
    await RosterService.instance.clear();
    _refresh();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      title: 'Sheet templates',
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('New template'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.md,
                MediaQuery.paddingOf(context).top + kToolbarHeight + AppSpacing.md,
                AppSpacing.md,
                96,
              ),
              children: [
                _buildIntro(),
                const SizedBox(height: AppSpacing.md),
                for (final t in _templates) ...[
                  _buildTemplate(t),
                  const SizedBox(height: AppSpacing.sm),
                ],
                const SizedBox(height: AppSpacing.md),
                _buildRoster(),
              ],
            ),
    );
  }

  Widget _buildIntro() {
    return GlassCard(
      opacity: 0.5,
      child: Text(
        _templates.isEmpty
            ? 'Every college prints a different sheet. Photograph one sample, '
                'draw a box around each field once, and every later scan of '
                'that layout reads handwriting from those boxes, on this phone.'
            : 'The selected template is used for every scan. Without one, only '
                'printed text can be read.',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }

  Widget _buildTemplate(SheetTemplate t) {
    final active = t.id == _activeId;
    return GlassCard(
      onTap: () async {
        await TemplateStore.instance.setActive(active ? null : t.id);
        _refresh();
      },
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          Icon(
            active ? Icons.radio_button_checked : Icons.radio_button_off,
            color: active ? AppColors.primary : AppColors.inkFaint,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.name, style: Theme.of(context).textTheme.titleMedium),
                Text(
                  '${t.fields.length} boxes · Part-A /${t.partAMax} · '
                  'Part-B /${t.partBMax}',
                  style: const TextStyle(fontSize: 12, color: AppColors.inkFaint),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _edit(t),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(t),
          ),
        ],
      ),
    );
  }

  Widget _buildRoster() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Class roster', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            _roster.isEmpty
                ? 'Optional. Import the class list (.xlsx) and every '
                    'registration number is checked against it.'
                : '${_roster.registrations.length} students. Numbers not on '
                    'the list are flagged, with the closest match suggested.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: _importRoster,
                icon: const Icon(Icons.upload_file),
                label: Text(_roster.isEmpty ? 'Import' : 'Replace'),
              ),
              if (!_roster.isEmpty) ...[
                const SizedBox(width: AppSpacing.sm),
                TextButton(onPressed: _clearRoster, child: const Text('Clear')),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
