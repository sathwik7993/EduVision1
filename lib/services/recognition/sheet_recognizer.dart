import '../../models/scan_result.dart';
import '../../models/sheet_template.dart';

export '../../models/sheet_template.dart';

/// A pluggable exam-sheet reader.
///
/// The UI depends only on this interface, so the recognition strategy can be
/// swapped -- ML Kit for label-matched printed sheets, the on-device ONNX
/// field model for templates with drawn boxes -- without touching the scan or
/// review screens.
abstract interface class SheetRecognizer {
  /// Shown in the UI so the teacher knows which engine produced a reading.
  String get displayName;

  /// True when this engine can read handwriting, as opposed to printed text
  /// only. Drives the "handwriting not supported" warning on the review screen.
  bool get supportsHandwriting;

  Future<ScanResult> recognize(String imagePath, {SheetTemplate template});

  Future<void> dispose();
}
