import 'package:eduvision_0_1/models/scan_result.dart';
import 'package:eduvision_0_1/services/recognition/text_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeLabel', () {
    test('folds the punctuation and casing OCR varies on', () {
      // These are all the same label as far as matching is concerned; the old
      // regex `Registered No\W*(\S+)` only matched the first.
      const variants = [
        'Registered No.',
        'REGISTERED NO :',
        'Registered  No',
        'registered no.:',
      ];
      for (final variant in variants) {
        expect(TextNormalizer.normalizeLabel(variant), 'registered no');
      }
    });
  });

  group('similarity', () {
    test('tolerates a single-character OCR slip', () {
      expect(
        TextNormalizer.similarity('registered no', 'reglstered no'),
        greaterThan(0.9),
      );
    });

    test('separates genuinely different labels', () {
      expect(
        TextNormalizer.similarity('part-a total', 'part-b total'),
        lessThan(0.95),
      );
    });
  });

  group('coerceToDigits', () {
    test('repairs letters OCR substitutes for digits', () {
      expect(TextNormalizer.coerceToDigits('3B'), '38');
      expect(TextNormalizer.coerceToDigits('S0'), '50');
      expect(TextNormalizer.coerceToDigits('l2'), '12');
      expect(TextNormalizer.coerceToDigits('O'), '0');
    });

    test('passes clean digits through untouched', () {
      expect(TextNormalizer.coerceToDigits('42'), '42');
    });

    test('refuses tokens that are not numeric at all', () {
      // Returning null here is what stops "Total" being saved as a mark.
      expect(TextNormalizer.coerceToDigits('Total'), isNull);
      expect(TextNormalizer.coerceToDigits('part'), isNull);
    });
  });

  group('cleanRegistration', () {
    test('strips separators OCR inserts', () {
      expect(TextNormalizer.cleanRegistration('21b0-1a 0512'), '21B01A0512');
    });
  });

  group('ExtractedField', () {
    test('flags low-confidence readings for review', () {
      const field = ExtractedField(value: '38', confidence: 0.5);
      expect(field.needsReview, isTrue);
    });

    test('sends a 0.88 reading to review (a real sheet: "10" read as "20")', () {
      const field = ExtractedField(value: '20', confidence: 0.88);
      expect(field.needsReview, isTrue);
    });

    test('trusts high-confidence readings', () {
      const field = ExtractedField(value: '38', confidence: 0.95);
      expect(field.needsReview, isFalse);
    });

    test('always trusts a value the teacher typed', () {
      const field = ExtractedField.manual('38');
      expect(field.needsReview, isFalse);
      expect(field.edited, isTrue);
    });

    test('flags an empty reading regardless of confidence', () {
      const field = ExtractedField(value: '', confidence: 1.0);
      expect(field.needsReview, isTrue);
    });
  });

  group('ScanResult', () {
    ScanResult build({
      String reg = '21B01A0512',
      String a = '30',
      String b = '40',
      double confidence = 0.95,
    }) {
      return ScanResult(
        registrationNo: ExtractedField(value: reg, confidence: confidence),
        partA: ExtractedField(value: a, confidence: confidence),
        partB: ExtractedField(value: b, confidence: confidence),
      );
    }

    test('derives the total rather than reading it off the page', () {
      expect(build(a: '30', b: '40').total, 70);
    });

    test('treats an unreadable mark as zero without crashing', () {
      expect(build(a: '', b: '40').total, 40);
    });

    test('is ready to save only when every field is trusted', () {
      expect(build().isReadyToSave, isTrue);
      expect(build(confidence: 0.4).isReadyToSave, isFalse);
    });

    test('is never ready to save without a registration number', () {
      expect(build(reg: '').isReadyToSave, isFalse);
    });

    test('names each field that still needs checking', () {
      final result = ScanResult(
        registrationNo: const ExtractedField(value: 'X1', confidence: 0.95),
        partA: const ExtractedField(value: '', confidence: 0),
        partB: const ExtractedField(value: '40', confidence: 0.3),
      );
      expect(result.fieldsNeedingReview, ['Part-A', 'Part-B']);
    });

    test('a manual correction clears the review flag', () {
      final corrected = build(confidence: 0.2).copyWith(
        registrationNo: const ExtractedField.manual('21B01A0512'),
        partA: const ExtractedField.manual('30'),
        partB: const ExtractedField.manual('40'),
      );
      expect(corrected.isReadyToSave, isTrue);
      expect(corrected.total, 70);
    });
  });
}
