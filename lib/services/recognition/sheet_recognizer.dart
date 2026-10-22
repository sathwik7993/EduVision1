import '../../models/scan_result.dart';

/// Describes the exam sheet being scanned.
///
/// Extraction quality depends far more on knowing what to expect than on the
/// OCR engine itself: knowing Part-A is out of 40 lets us reject a misread "80"
/// outright, and knowing the registration format lets us repair confusable
/// characters positionally.
class SheetTemplate {
  const SheetTemplate({
    this.registrationLabels = const [
      'registered no',
      'registration no',
      'reg no',
      'regd no',
      'roll no',
      'hall ticket',
      'hall ticket no',
      'student id',
    ],
    this.partALabels = const [
      'part-a total',
      'part a total',
      'parta total',
      'total part-a',
      'section a total',
      'part-a',
      'part a',
    ],
    this.partBLabels = const [
      'part-b total',
      'part b total',
      'partb total',
      'total part-b',
      'section b total',
      'part-b',
      'part b',
    ],
    this.partAMax = 40,
    this.partBMax = 60,
    this.registrationLength,
    this.registrationPattern,
  });

  final List<String> registrationLabels;
  final List<String> partALabels;
  final List<String> partBLabels;

  /// Used to reject impossible readings.
  final int partAMax;
  final int partBMax;

  /// Exact expected length of the registration number, when fixed. Enables
  /// positional character repair (e.g. a letter read where a digit belongs).
  final int? registrationLength;

  /// Overrides the default "6-15 alphanumeric with at least two digits" rule.
  final RegExp? registrationPattern;

  static const defaults = SheetTemplate();

  SheetTemplate copyWith({int? partAMax, int? partBMax, int? registrationLength}) {
    return SheetTemplate(
      registrationLabels: registrationLabels,
      partALabels: partALabels,
      partBLabels: partBLabels,
      partAMax: partAMax ?? this.partAMax,
      partBMax: partBMax ?? this.partBMax,
      registrationLength: registrationLength ?? this.registrationLength,
      registrationPattern: registrationPattern,
    );
  }
}

/// A pluggable exam-sheet reader.
///
/// The UI depends only on this interface, so the recognition strategy can be
/// swapped -- ML Kit today, a TFLite handwritten-digit classifier for boxed
/// fields next -- without touching the scan or review screens.
abstract interface class SheetRecognizer {
  /// Shown in the UI so the teacher knows which engine produced a reading.
  String get displayName;

  /// True when this engine can read handwriting, as opposed to printed text
  /// only. Drives the "handwriting not supported" warning on the review screen.
  bool get supportsHandwriting;

  Future<ScanResult> recognize(String imagePath, {SheetTemplate template});

  Future<void> dispose();
}
