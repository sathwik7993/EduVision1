/// How much the recognizer trusts a single extracted field.
///
/// This drives the review screen: anything below [ExtractedField.trustedAbove]
/// is surfaced for the teacher to confirm before it can be saved.
class ExtractedField {
  const ExtractedField({
    required this.value,
    required this.confidence,
    this.rawText,
    this.edited = false,
  });

  const ExtractedField.empty()
      : value = '',
        confidence = 0,
        rawText = null,
        edited = false;

  /// A value the teacher typed or corrected by hand is authoritative.
  const ExtractedField.manual(this.value)
      : confidence = 1,
        rawText = null,
        edited = true;

  final String value;

  /// 0.0 - 1.0.
  final double confidence;

  /// The unmodified OCR text this was derived from, kept for debugging and to
  /// show the teacher what the model actually saw.
  final String? rawText;

  final bool edited;

  static const trustedAbove = 0.80;

  bool get isEmpty => value.trim().isEmpty;
  bool get needsReview => !edited && (isEmpty || confidence < trustedAbove);

  ExtractedField copyWith({String? value, double? confidence, bool? edited}) {
    return ExtractedField(
      value: value ?? this.value,
      confidence: confidence ?? this.confidence,
      rawText: rawText,
      edited: edited ?? this.edited,
    );
  }
}

/// One scanned exam sheet, before it is committed to the workbook.
class ScanResult {
  const ScanResult({
    required this.registrationNo,
    required this.partA,
    required this.partB,
    this.imagePath,
    this.rawText = '',
  });

  const ScanResult.blank()
      : registrationNo = const ExtractedField.empty(),
        partA = const ExtractedField.empty(),
        partB = const ExtractedField.empty(),
        imagePath = null,
        rawText = '';

  final ExtractedField registrationNo;
  final ExtractedField partA;
  final ExtractedField partB;
  final String? imagePath;

  /// Full OCR dump, shown behind a "what the scanner read" disclosure so a
  /// teacher can see why a field came out wrong.
  final String rawText;

  int get partAValue => int.tryParse(partA.value.trim()) ?? 0;
  int get partBValue => int.tryParse(partB.value.trim()) ?? 0;

  /// Always derived, never recognized -- reading a handwritten total and
  /// trusting it would let arithmetic errors on the paper into the workbook.
  int get total => partAValue + partBValue;

  /// True when every field is either high-confidence or teacher-confirmed.
  bool get isReadyToSave =>
      !registrationNo.needsReview &&
      !partA.needsReview &&
      !partB.needsReview &&
      registrationNo.value.trim().isNotEmpty;

  List<String> get fieldsNeedingReview => [
        if (registrationNo.needsReview) 'Registration No',
        if (partA.needsReview) 'Part-A',
        if (partB.needsReview) 'Part-B',
      ];

  ScanResult copyWith({
    ExtractedField? registrationNo,
    ExtractedField? partA,
    ExtractedField? partB,
  }) {
    return ScanResult(
      registrationNo: registrationNo ?? this.registrationNo,
      partA: partA ?? this.partA,
      partB: partB ?? this.partB,
      imagePath: imagePath,
      rawText: rawText,
    );
  }
}
