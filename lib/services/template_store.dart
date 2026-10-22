import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/sheet_template.dart';

/// Per-college sheet templates, kept on the device as one JSON file.
///
/// Nothing here leaves the phone: a template is just box coordinates plus the
/// mark limits, and it never contains student data.
class TemplateStore {
  TemplateStore({Future<Directory> Function()? directory})
      : _directory = directory ?? getApplicationDocumentsDirectory;

  static final instance = TemplateStore();

  static const fileName = 'sheet_templates.json';

  final Future<Directory> Function() _directory;

  Future<File> _file() async {
    final dir = await _directory();
    return File('${dir.path}${Platform.pathSeparator}$fileName');
  }

  Future<({List<SheetTemplate> templates, String? activeId})> _read() async {
    final file = await _file();
    if (!await file.exists()) return (templates: <SheetTemplate>[], activeId: null);
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      final templates = ((json['templates'] as List?) ?? const [])
          .map((t) => SheetTemplate.fromJson((t as Map).cast<String, Object?>()))
          .toList();
      return (templates: templates, activeId: json['activeId'] as String?);
    } on FormatException {
      // A corrupt file should not brick scanning; the teacher redraws boxes.
      return (templates: <SheetTemplate>[], activeId: null);
    }
  }

  Future<void> _write(List<SheetTemplate> templates, String? activeId) async {
    final file = await _file();
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      'activeId': activeId,
      'templates': templates.map((t) => t.toJson()).toList(),
    }), flush: true);
    // Rename is atomic, so a crash mid-write cannot leave half a file.
    await tmp.rename(file.path);
  }

  Future<List<SheetTemplate>> all() async => (await _read()).templates;

  /// The template scans use. Falls back to the label-matching defaults.
  Future<SheetTemplate> active() async {
    final data = await _read();
    for (final t in data.templates) {
      if (t.id == data.activeId) return t;
    }
    return SheetTemplate.defaults;
  }

  Future<String?> activeId() async => (await _read()).activeId;

  Future<void> setActive(String? id) async {
    final data = await _read();
    await _write(data.templates, id);
  }

  /// Inserts or replaces by id. A newly saved template becomes active, since
  /// the teacher just drew it for the sheets in front of them.
  Future<void> save(SheetTemplate template) async {
    final data = await _read();
    final list = [...data.templates];
    final index = list.indexWhere((t) => t.id == template.id);
    if (index >= 0) {
      list[index] = template;
    } else {
      list.add(template);
    }
    await _write(list, template.id);
  }

  Future<void> delete(String id) async {
    final data = await _read();
    final list = data.templates.where((t) => t.id != id).toList();
    await _write(list, data.activeId == id ? null : data.activeId);
  }
}
