import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/scan_result.dart';

/// Keeps every reviewed field crop with its confirmed value, on the device.
///
/// Each save on the review screen yields labelled examples: the crop the
/// model read, what it predicted, and what the teacher confirmed. Corrected
/// crops are the hard cases a fine-tune needs; confirmed ones let accuracy on
/// real sheets be measured instead of guessed. Nothing is uploaded.
class CorrectionStore {
  CorrectionStore({Future<Directory> Function()? directory})
      : _directory = directory ?? getApplicationDocumentsDirectory;

  static final instance = CorrectionStore();

  static const folder = 'labelled_crops';
  static const indexFile = 'labels.jsonl';

  final Future<Directory> Function() _directory;

  Future<Directory> _dir() async {
    final base = await _directory();
    final dir = Directory('${base.path}${Platform.pathSeparator}$folder');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Records each field of [reviewed] that has a crop. [original] is the
  /// recognizer output before the teacher touched it. Returns how many
  /// samples were written.
  Future<int> record({
    required ScanResult original,
    required ScanResult reviewed,
    required String templateId,
  }) async {
    final pairs = <(String, ExtractedField, ExtractedField)>[
      ('registration', original.registrationNo, reviewed.registrationNo),
      ('partA', original.partA, reviewed.partA),
      ('partB', original.partB, reviewed.partB),
      for (var i = 0;
          i < original.questions.length && i < reviewed.questions.length;
          i++)
        (
          'question:${original.questions[i].label}',
          original.questions[i].field,
          reviewed.questions[i].field,
        ),
    ];

    final dir = await _dir();
    final index = File('${dir.path}${Platform.pathSeparator}$indexFile');
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final lines = StringBuffer();
    var written = 0;

    for (final (key, before, after) in pairs) {
      final crop = before.crop;
      if (crop == null) continue;
      final name = '${stamp}_${key.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_')}.png';
      await File('${dir.path}${Platform.pathSeparator}$name').writeAsBytes(crop);
      lines.writeln(jsonEncode({
        'file': name,
        'field': key,
        'template': templateId,
        'predicted': before.value,
        'confidence': before.confidence,
        'label': after.value,
        'corrected': after.value != before.value,
        'at': DateTime.now().toIso8601String(),
      }));
      written++;
    }

    if (written > 0) {
      await index.writeAsString(lines.toString(), mode: FileMode.append, flush: true);
    }
    return written;
  }

  /// All recorded samples, oldest first.
  Future<List<Map<String, Object?>>> readAll() async {
    final dir = await _dir();
    final index = File('${dir.path}${Platform.pathSeparator}$indexFile');
    if (!await index.exists()) return const [];
    return [
      for (final line in await index.readAsLines())
        if (line.trim().isNotEmpty) (jsonDecode(line) as Map).cast<String, Object?>(),
    ];
  }
}
