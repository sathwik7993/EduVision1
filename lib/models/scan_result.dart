import 'dart:typed_data';

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
    this.issue,
    this.suggestion,
    this.crop,
  });

  const ExtractedField.empty()
      : value = '',
        confidence = 0,
        rawText = null,
        edited = false,
        issue = null,
        suggestion = null,
        crop = null;

  /// A value the teacher typed or corrected by hand is authoritative.
  const ExtractedField.manual(this.value, {this.crop})
      : confidence = 1,
        rawText = null,
        edited = true,
        issue = null,
        suggestion = null;

  final String value;

  /// 0.0 - 1.0.
  final double confidence;

  /// The unmodified OCR text this was derived from, kept for debugging and to
  /// show the teacher what the model actually saw.
  final String? rawText;

  final bool edited;

  /// Why validation doubts this value ("above the maximum of 40", "not in the
  /// class roster"). A flagged value always goes to review, whatever its
  /// confidence.
  final String? issue;

  /// A likely correction, e.g. the closest registration number on the roster.
  final String? suggestion;

  /// PNG of the exact pixels the model read. Shown on the review screen and
  /// kept, with the confirmed value, as a labelled sample on the device.
  final Uint8List? crop;

  static const trustedAbove = 0.80;

  bool get isEmpty => value.trim().isEmpty;
  bool get needsReview =>
      !edited && (isEmpty || confidence < trustedAbove || issue != null);

  ExtractedField copyWith({
    String? value,
    double? confidence,
    bool? edited,
    String? issue,
    String? suggestion,
  }) {
    return ExtractedField(
      value: value ?? this.value,
      confidence: confidence ?? this.confidence,
      rawText: rawText,
      edited: edited ?? this.edited,
      issue: issue ?? this.issue,
      suggestion: suggestion ?? this.suggestion,
      crop: crop,
    );
  }
}

/// One per-question mark read from a template box.
class QuestionMark {
  const QuestionMark({
    required this.label,
    required this.part,
    required this.field,
    this.maxMarks,
  });

  final String label;

  /// 'A' or 'B'.
  final String part;
  final int? maxMarks;
  final ExtractedField field;

  int get value => int.tryParse(field.value.trim()) ?? 0;

  QuestionMark withField(ExtractedField field) => QuestionMark(
        label: label,
        part: part,
        maxMarks: maxMarks,
        field: field,
      );
}

/// One scanned exam sheet, before it is committed to the workbook.
class ScanResult {
  const ScanResult({
    required this.registrationNo,
    required this.partA,
    required this.partB,
    this.questions = const [],
    this.imagePath,
    this.rawText = '',
    this.timingsMs = const {},
  });

  const ScanResult.blank()
      : registrationNo = const ExtractedField.empty(),
        partA = const ExtractedField.empty(),
        partB = const ExtractedField.empty(),
        questions = const [],
        imagePath = null,
        rawText = '',
        timingsMs = const {};

  final ExtractedField registrationNo;
  final ExtractedField partA;
  final ExtractedField partB;

  /// Per-question marks, when the template has question boxes. Used to
  /// cross-check the part totals.
  final List<QuestionMark> questions;
  final String? imagePath;

  /// Full OCR dump, shown behind a "what the scanner read" disclosure so a
  /// teacher can see why a field came out wrong.
  final String rawText;

  /// Per-stage latency of this scan (decode, align, inference, ...), so speed
  /// on a real device is measured rather than assumed.
  final Map<String, int> timingsMs;

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
      !questions.any((q) => q.field.needsReview) &&
      registrationNo.value.trim().isNotEmpty;

  List<String> get fieldsNeedingReview => [
        if (registrationNo.needsReview) 'Registration No',
        if (partA.needsReview) 'Part-A',
        if (partB.needsReview) 'Part-B',
        for (final q in questions)
          if (q.field.needsReview) q.label,
      ];

  ScanResult copyWith({
    ExtractedField? registrationNo,
    ExtractedField? partA,
    ExtractedField? partB,
    List<QuestionMark>? questions,
  }) {
    return ScanResult(
      registrationNo: registrationNo ?? this.registrationNo,
      partA: partA ?? this.partA,
      partB: partB ?? this.partB,
      questions: questions ?? this.questions,
      imagePath: imagePath,
      rawText: rawText,
      timingsMs: timingsMs,
    );
  }
}
