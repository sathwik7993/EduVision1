import '../models/scan_result.dart';
import '../models/sheet_template.dart';
import 'recognition/text_normalizer.dart';
import 'roster_service.dart';

/// Cross-checks a recognised sheet against what is possible on paper.
///
/// Every rule here only ever *adds* doubt: a failed check attaches an
/// [ExtractedField.issue], which forces review whatever the model's
/// confidence. Nothing is auto-corrected; a roster match is offered as a
/// suggestion the teacher has to accept.
abstract final class ScanValidator {
  /// Stricter than [ExtractedField.trustedAbove]: see [_checkRegistration].
  static const registrationTrustedAbove = 0.95;

  static ScanResult validate(
    ScanResult result,
    SheetTemplate template, {
    Roster? roster,
    Set<String> alreadySaved = const {},
  }) {
    final questions = [
      for (final q in result.questions)
        q.withField(_flag(q.field, _overMax(q.field, q.maxMarks))),
    ];

    var partA = _flag(result.partA, _overMax(result.partA, template.partAMax));
    var partB = _flag(result.partB, _overMax(result.partB, template.partBMax));

    // Per-question marks must add up to a part total written in its own box.
    // A total derived from the questions is a sum by construction.
    for (final part in const ['A', 'B']) {
      final kind = part == 'A' ? FieldKind.partA : FieldKind.partB;
      if (!template.fields.any((f) => f.kind == kind)) continue;
      final qs = [
        for (var i = 0; i < questions.length; i++)
          if (questions[i].part == part) i,
      ];
      final total = part == 'A' ? partA : partB;
      // All cells blank is the common "examiner filled only the totals" case.
      // Otherwise a blank cell is an unattempted question and counts as 0.
      if (qs.isEmpty ||
          total.isEmpty ||
          qs.every((i) => questions[i].field.isEmpty)) {
        continue;
      }
      final sum = qs.fold(0, (s, i) => s + questions[i].value);
      final written = int.tryParse(total.value) ?? -1;
      if (sum == written) continue;
      final issue = 'Question marks add up to $sum, but the Part-$part '
          'total reads $written';
      for (final i in qs) {
        questions[i] = questions[i].withField(_flag(questions[i].field, issue));
      }
      if (part == 'A') {
        partA = _flag(partA, issue);
      } else {
        partB = _flag(partB, issue);
      }
    }

    // A total the examiner wrote must agree with Part-A + Part-B. The
    // workbook always gets the derived sum; a disagreement means a mark (or
    // the examiner's arithmetic) is wrong, and the teacher must look.
    final derived = (int.tryParse(partA.value) ?? 0) +
        (int.tryParse(partB.value) ?? 0);
    final written = [
      for (final w in result.writtenTotals)
        w.field.isEmpty || int.tryParse(w.field.value) == derived
            ? w
            : w.withField(_flag(
                w.field,
                '${w.label} reads ${w.field.value}, but Part-A + Part-B '
                '= $derived',
              )),
    ];

    return result.copyWith(
      writtenTotals: written,
      registrationNo: _checkRegistration(
        result.registrationNo,
        template,
        roster ?? Roster.empty,
        alreadySaved,
      ),
      partA: partA,
      partB: partB,
      questions: questions,
    );
  }

  /// Problems that block saving even after the teacher has typed a value: a
  /// mark above its maximum cannot be right.
  static List<String> blockingErrors(ScanResult result, SheetTemplate template) {
    return [
      if (_overMax(result.partA, template.partAMax) case final e?) 'Part-A: $e',
      if (_overMax(result.partB, template.partBMax) case final e?) 'Part-B: $e',
      for (final q in result.questions)
        if (_overMax(q.field, q.maxMarks) case final e?) '${q.label}: $e',
    ];
  }

  static ExtractedField _checkRegistration(
    ExtractedField field,
    SheetTemplate template,
    Roster roster,
    Set<String> alreadySaved,
  ) {
    if (field.isEmpty || field.edited) return field;
    final reg = TextNormalizer.cleanRegistration(field.value);
    final issues = <String>[];
    String? suggestion;

    final mask = template.registrationMask;
    final length = template.registrationLength ??
        (mask == null || mask.isEmpty ? null : mask.length);
    if (length != null && reg.length < length) {
      issues.add('Incomplete: read ${reg.length} of $length characters');
    } else if (length != null && reg.length > length) {
      issues.add('Expected $length characters, read ${reg.length}');
    } else if (mask != null && mask.isNotEmpty && !_matchesMask(reg, mask)) {
      issues.add('Does not match the format $mask');
    } else if (mask == null || mask.isEmpty) {
      final pattern = template.registrationPattern ??
          SheetTemplate.defaultRegistrationPattern;
      if (!pattern.hasMatch(reg)) {
        issues.add('Does not match the registration number format');
      }
    }

    if (!roster.isEmpty && !roster.contains(reg)) {
      suggestion = roster.closest(reg);
      issues.add('Not on the class roster');
    }

    // Ten characters give ten chances to misread one, and a one-digit misread
    // of a roll number is usually another real student, so the roster cannot
    // catch it. On the synthetic eval, 0.80 let ~2.5% of registration numbers
    // through wrong; 0.95 let ~0.15% through.
    if (field.confidence >= ExtractedField.trustedAbove &&
        field.confidence < registrationTrustedAbove) {
      issues.add('Not certain enough for a registration number');
    }

    // A second sheet with the same number is more often a misread of a
    // neighbouring student than a genuine re-scan.
    if (alreadySaved.contains(reg)) {
      issues.add('Already in the results sheet');
    }

    if (issues.isEmpty) return field;
    return _flag(field, issues.join('; '), suggestion: suggestion);
  }

  /// D digit, A letter, X either.
  static bool _matchesMask(String reg, String mask) {
    for (var i = 0; i < mask.length; i++) {
      final isDigit = RegExp(r'\d').hasMatch(reg[i]);
      switch (mask[i].toUpperCase()) {
        case 'D' when !isDigit:
        case 'A' when isDigit:
          return false;
      }
    }
    return true;
  }

  static String? _overMax(ExtractedField field, int? max) {
    if (max == null || field.isEmpty) return null;
    final value = int.tryParse(field.value.trim());
    if (value == null) return 'Not a number';
    return value > max ? 'Above the maximum of $max' : null;
  }

  static ExtractedField _flag(
    ExtractedField field,
    String? issue, {
    String? suggestion,
  }) {
    // Re-validating an already validated result must not stack duplicates.
    if (issue == null || field.edited || (field.issue?.contains(issue) ?? false)) {
      return field;
    }
    final combined = field.issue == null ? issue : '${field.issue}; $issue';
    return ExtractedField(
      value: field.value,
      confidence: field.confidence,
      rawText: field.rawText,
      issue: combined,
      suggestion: suggestion ?? field.suggestion,
      crop: field.crop,
    );
  }
}
