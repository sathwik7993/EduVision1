import 'dart:io';
import 'package:excel/excel.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';

class SheetManager {
  static const String sheetFileName = 'results.xlsx';
  static Future<String?> getSheetPath() async {
    final Directory? directory = await getExternalStorageDirectory();
    if (directory != null) {
      return '${directory.path}/$sheetFileName';
    }
    return null;
  }

  static Future<void> appendToSheet(
      String regNo, String partAMarks, String partBMarks, String totalMarks) async {
    final filePath = await getSheetPath();
    if (filePath != null) {
      File file = File(filePath);
      Excel excel;
      if (await file.exists()) {
        var bytes = file.readAsBytesSync();
        excel = Excel.decodeBytes(bytes);
      } else {
        excel = Excel.createExcel(); // Create if doesn't exist
      }

      Sheet sheetObject = excel['Sheet1'];
      sheetObject.appendRow([regNo, partAMarks, partBMarks, totalMarks]);

      final fileBytes = excel.encode();
      if (fileBytes != null) {
        await file.writeAsBytes(fileBytes);
      }
    }
  }

  static Future<void> viewSheet() async {
    final filePath = await getSheetPath();
    if (filePath != null && await File(filePath).exists()) {
      OpenFile.open(filePath);
    }
  }
}
