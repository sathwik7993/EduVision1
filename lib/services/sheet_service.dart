import 'dart:io';

import 'package:excel/excel.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/scan_result.dart';

/// One committed row in the workbook.
class SheetRow {
  const SheetRow({
    required this.registrationNo,
    required this.partA,
    required this.partB,
    required this.total,
    required this.scannedAt,
  });

  final String registrationNo;
  final int partA;
  final int partB;
  final int total;
  final DateTime? scannedAt;
}

enum SaveOutcome { inserted, updated }

/// Reads and writes the results workbook.
///
/// Replaces the two divergent copies of `SheetManager` that previously lived in
/// both `scan_page.dart` and `sheet_manager.dart`.
class SheetService {
  SheetService._();
  static final instance = SheetService._();

  static const fileName = 'exam_results.xlsx';
  static const _sheetName = 'Results';
  static const _headers = [
    'Registration No',
    'Part-A',
    'Part-B',
    'Total',
    'Scanned At',
  ];

  /// App documents rather than `getExternalStorageDirectory()`: that returned a
  /// path the user could not reach from a file manager, was wiped on uninstall,
  /// and is null on several platforms. The file leaves the app via [share]
  /// instead, which needs no storage permission at all.
  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$fileName');
  }

  Future<String> filePath() async => (await _file()).path;

  Future<bool> exists() async => (await _file()).exists();

  Future<Excel> _open() async {
    final file = await _file();
    if (await file.exists()) {
      try {
        return Excel.decodeBytes(await file.readAsBytes());
      } on Exception {
        // A truncated or corrupt workbook should not brick the app; start a
        // fresh one and let the old file be overwritten on next save.
        return _createWorkbook();
      }
    }
    return _createWorkbook();
  }

  Excel _createWorkbook() {
    final excel = Excel.createExcel();
    // createExcel() seeds a sheet called "Sheet1". Renaming keeps a single
    // sheet -- indexing excel['Results'] directly would leave an empty
    // "Sheet1" sitting alongside it.
    excel.rename(excel.getDefaultSheet()!, _sheetName);
    excel[_sheetName].appendRow(
      _headers.map<CellValue?>(TextCellValue.new).toList(),
    );
    return excel;
  }

  Future<void> _flush(Excel excel) async {
    final bytes = excel.encode();
    if (bytes == null) {
      throw const FileSystemException('Could not encode the workbook');
    }
    final file = await _file();
    await file.writeAsBytes(bytes, flush: true);
  }

  /// Returns the row index (1-based, header excluded) of an existing entry for
  /// [registrationNo], or null.
  int? _findRow(Sheet sheet, String registrationNo) {
    final needle = registrationNo.trim().toUpperCase();
    for (var i = 1; i < sheet.rows.length; i++) {
      final cell = sheet.rows[i].isEmpty ? null : sheet.rows[i][0];
      final value = cell?.value?.toString().trim().toUpperCase();
      if (value != null && value.isNotEmpty && value == needle) return i;
    }
    return null;
  }

  /// True if this registration number is already in the workbook.
  ///
  /// The scan page checks this *before* saving so the teacher gets an explicit
  /// "already scanned -- overwrite?" prompt rather than silently accumulating
  /// duplicate rows, which the old implementation did.
  Future<bool> containsRegistration(String registrationNo) async {
    if (registrationNo.trim().isEmpty) return false;
    final excel = await _open();
    final sheet = excel[_sheetName];
    return _findRow(sheet, registrationNo) != null;
  }

  /// Commits a verified [ScanResult]. Overwrites an existing row for the same
  /// registration number when [overwrite] is set.
  Future<SaveOutcome> save(ScanResult result, {bool overwrite = false}) async {
    final excel = await _open();
    final sheet = excel[_sheetName];

    // Marks are written as numbers, not strings. The old code stored them as
    // text, which made Excel refuse to SUM or AVERAGE the columns.
    final row = <CellValue?>[
      TextCellValue(result.registrationNo.value.trim().toUpperCase()),
      IntCellValue(result.partAValue),
      IntCellValue(result.partBValue),
      IntCellValue(result.total),
      TextCellValue(DateTime.now().toIso8601String()),
    ];

    final existing = _findRow(sheet, result.registrationNo.value);
    if (existing != null && overwrite) {
      for (var c = 0; c < row.length; c++) {
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: existing))
            .value = row[c];
      }
      await _flush(excel);
      return SaveOutcome.updated;
    }

    sheet.appendRow(row);
    await _flush(excel);
    return SaveOutcome.inserted;
  }

  /// All committed rows, newest last.
  Future<List<SheetRow>> readAll() async {
    final file = await _file();
    if (!await file.exists()) return const [];

    final excel = await _open();
    final sheet = excel.tables[_sheetName];
    if (sheet == null) return const [];

    final rows = <SheetRow>[];
    for (var i = 1; i < sheet.rows.length; i++) {
      final cells = sheet.rows[i];
      if (cells.isEmpty) continue;

      String at(int index) =>
          index < cells.length ? (cells[index]?.value?.toString() ?? '') : '';

      final reg = at(0).trim();
      if (reg.isEmpty) continue;

      rows.add(
        SheetRow(
          registrationNo: reg,
          partA: int.tryParse(at(1).trim()) ?? 0,
          partB: int.tryParse(at(2).trim()) ?? 0,
          total: int.tryParse(at(3).trim()) ?? 0,
          scannedAt: DateTime.tryParse(at(4).trim()),
        ),
      );
    }
    return rows;
  }

  Future<void> deleteRegistration(String registrationNo) async {
    final excel = await _open();
    final sheet = excel[_sheetName];
    final index = _findRow(sheet, registrationNo);
    if (index == null) return;
    sheet.removeRow(index);
    await _flush(excel);
  }

  Future<void> deleteWorkbook() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }

  /// Opens in whatever spreadsheet app is installed. Returns an error message
  /// on failure, or null on success -- the old version silently did nothing
  /// when no handler existed.
  Future<String?> openExternally() async {
    final file = await _file();
    if (!await file.exists()) return 'No results have been saved yet.';

    final result = await OpenFile.open(
      file.path,
      type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
    if (result.type == ResultType.done) return null;
    if (result.type == ResultType.noAppToOpen) {
      return 'No spreadsheet app installed. Use Share to send the file instead.';
    }
    return result.message;
  }

  /// Hands the workbook to the system share sheet (email, Drive, WhatsApp).
  /// This is how the file actually gets off the device.
  Future<void> share() async {
    final file = await _file();
    if (!await file.exists()) return;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        subject: 'Exam results',
        text: 'Exam results exported from EduVision.',
      ),
    );
  }
}
