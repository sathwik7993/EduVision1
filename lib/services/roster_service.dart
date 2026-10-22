import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';

import 'recognition/text_normalizer.dart';

/// The registration numbers of one class, imported from the college's Excel
/// list. Used only to check readings; it never leaves the device.
class Roster {
  Roster(Iterable<String> registrations)
      : registrations = registrations.toSet();

  static final empty = Roster(const []);

  final Set<String> registrations;

  bool get isEmpty => registrations.isEmpty;

  bool contains(String reg) =>
      registrations.contains(TextNormalizer.cleanRegistration(reg));

  /// The roster entry within [maxEdits] character edits of [reg], or null if
  /// there is none or the nearest is ambiguous. Ambiguity matters: two
  /// students one digit apart must not be "corrected" into each other.
  String? closest(String reg, {int maxEdits = 2}) {
    final needle = TextNormalizer.cleanRegistration(reg);
    if (needle.isEmpty) return null;
    String? best;
    var bestDistance = maxEdits + 1;
    var tie = false;
    for (final candidate in registrations) {
      final d = TextNormalizer.editDistance(needle, candidate);
      if (d < bestDistance) {
        best = candidate;
        bestDistance = d;
        tie = false;
      } else if (d == bestDistance) {
        tie = true;
      }
    }
    return tie ? null : best;
  }

  /// Reads the registration column from the first sheet of [bytes].
  ///
  /// The column is the one whose header mentions reg/roll/hall ticket/id;
  /// without such a header, the first column is used.
  factory Roster.fromExcel(List<int> bytes) {
    final excel = Excel.decodeBytes(bytes);
    if (excel.tables.isEmpty) return Roster.empty;
    final rows = excel.tables.values.first.rows;
    if (rows.isEmpty) return Roster.empty;

    String text(Data? cell) => cell?.value?.toString().trim() ?? '';

    var column = 0;
    var start = 0;
    final header = rows.first;
    for (var c = 0; c < header.length; c++) {
      final label = TextNormalizer.normalizeLabel(text(header[c]));
      if (RegExp(r'\b(reg|regd|registration|registered|roll|hall|id|htno)\b')
          .hasMatch(label)) {
        column = c;
        start = 1;
        break;
      }
    }

    final regs = <String>[];
    for (var r = start; r < rows.length; r++) {
      if (column >= rows[r].length) continue;
      final value = TextNormalizer.cleanRegistration(text(rows[r][column]));
      // Skips a header that did not match, blank rows and serial numbers.
      if (value.length >= 4 && RegExp(r'\d').hasMatch(value)) regs.add(value);
    }
    return Roster(regs);
  }
}

/// Persists the active class roster as JSON in app storage.
class RosterService {
  RosterService({Future<Directory> Function()? directory})
      : _directory = directory ?? getApplicationDocumentsDirectory;

  static final instance = RosterService();

  final Future<Directory> Function() _directory;

  Future<File> _file() async {
    final dir = await _directory();
    return File('${dir.path}${Platform.pathSeparator}class_roster.json');
  }

  Future<Roster> load() async {
    final file = await _file();
    if (!await file.exists()) return Roster.empty;
    try {
      final list = (jsonDecode(await file.readAsString()) as List).cast<String>();
      return Roster(list);
    } on FormatException {
      return Roster.empty;
    }
  }

  Future<void> save(Roster roster) async {
    final file = await _file();
    await file.writeAsString(jsonEncode(roster.registrations.toList()));
  }

  Future<void> clear() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }
}
