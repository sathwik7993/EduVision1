import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:eduvision_0_1/models/scan_result.dart';
import 'package:eduvision_0_1/models/sheet_template.dart';
import 'package:eduvision_0_1/services/recognition/crop_preprocessor.dart';
import 'package:eduvision_0_1/services/recognition/ctc_decoder.dart';
import 'package:eduvision_0_1/services/recognition/onnx_recognizer.dart';
import 'package:eduvision_0_1/services/recognition/page_aligner.dart';
import 'package:flutter_test/flutter_test.dart';

/// A white sheet with dark "ink" rectangles at the given normalised boxes.
GrayImage canonicalPage(List<Rect> inked, {int w = 420, int h = 594}) {
  final page = GrayImage(w, h)..pixels.fillRange(0, w * h, 235);
  for (final r in inked) {
    for (var y = (r.top * h).round(); y < (r.bottom * h).round(); y++) {
      for (var x = (r.left * w).round(); x < (r.right * w).round(); x++) {
        page.pixels[y * w + x] = 30;
      }
    }
  }
  return page;
}

/// Photographs [page] onto a dark desk with its corners at [corners], by
/// splatting an oversampled grid through the forward mapping.
GrayImage photograph(GrayImage page, List<Offset> corners,
    {int w = 640, int h = 800}) {
  final photo = GrayImage(w, h)..pixels.fillRange(0, w * h, 60);
  final map = PageHomography.fromCorners(corners);
  final su = page.width * 3, sv = page.height * 3;
  for (var j = 0; j < sv; j++) {
    final v = (j + 0.5) / sv;
    for (var i = 0; i < su; i++) {
      final u = (i + 0.5) / su;
      final p = map.map(u, v);
      final x = p.dx.floor(), y = p.dy.floor();
      if (x < 0 || y < 0 || x >= w || y >= h) continue;
      photo.pixels[y * w + x] =
          page.at((u * page.width).floor(), (v * page.height).floor());
    }
  }
  return photo;
}

double meanAbsDiff(GrayImage a, GrayImage b) {
  var sum = 0.0;
  for (var i = 0; i < a.pixels.length; i++) {
    sum += (a.pixels[i] - b.pixels[i]).abs();
  }
  return sum / a.pixels.length;
}

void main() {
  group('CropPreprocessor', () {
    test('matches the Python prep() the model was trained with', () {
      final cases = (jsonDecode(
        File('test/fixtures/prep_parity.json').readAsStringSync(),
      ) as List)
          .cast<Map<String, dynamic>>();
      expect(cases, isNotEmpty);

      for (final c in cases) {
        final crop = GrayImage(
          c['width'] as int,
          c['height'] as int,
          base64Decode(c['pixels'] as String),
        );
        final expected =
            base64Decode(c['expected'] as String).buffer.asFloat32List();
        final input = CropPreprocessor.prepare(crop);

        expect(input.width, c['outWidth']);
        var worst = 0.0;
        for (var i = 0; i < expected.length; i++) {
          final d = (input.data[i] - expected[i]).abs();
          if (d > worst) worst = d;
        }
        // Rounding differs (OpenCV resizes in fixed point), so allow a
        // small per-pixel deviation; a wrong axis or inversion is ~1.0.
        expect(worst, lessThan(0.06), reason: 'case ${c['width']}x${c['height']}');
      }
    });

    test('pads width to a multiple of 4 and inverts ink to high values', () {
      final crop = GrayImage(50, 20)..pixels.fillRange(0, 1000, 255);
      crop.pixels[10 * 50 + 25] = 0;
      final input = CropPreprocessor.prepare(crop);
      expect(input.width % 4, 0);
      expect(input.data.reduce((a, b) => a > b ? a : b), greaterThan(0.5));
    });
  });

  group('CtcDecoder', () {
    // Classes: 0 blank, 1..10 digits, 11.. letters.
    Float32List frames(List<Map<int, double>> rows) {
      const classes = 37;
      final out = Float32List(rows.length * classes);
      for (var t = 0; t < rows.length; t++) {
        final rest = 1 - rows[t].values.fold(0.0, (a, b) => a + b);
        for (var c = 0; c < classes; c++) {
          out[t * classes + c] = rest / (classes - rows[t].length);
        }
        rows[t].forEach((c, p) => out[t * classes + c] = p);
      }
      return out;
    }

    test('collapses repeats and drops blanks', () {
      // "3", "3", blank, "3", "8" -> "338"
      final probs = frames([
        {4: 0.9},
        {4: 0.95},
        {0: 0.9},
        {4: 0.9},
        {9: 0.85},
      ]);
      final r = CtcDecoder.decode(probs, 5, 37);
      expect(r.text, '338');
    });

    test('confidence is the least certain character, not the mean', () {
      final probs = frames([
        {4: 0.99},
        {0: 0.99},
        {9: 0.55},
      ]);
      final r = CtcDecoder.decode(probs, 3, 37);
      expect(r.text, '38');
      expect(r.confidence, lessThan(0.7));
    });

    test('digit-only decoding cannot emit a letter', () {
      // The model's favourite is "S" (class 29) but "5" is close behind.
      final probs = frames([
        {29: 0.6, 6: 0.35},
      ]);
      expect(CtcDecoder.decode(probs, 1, 37).text, 'S');
      final digits = CtcDecoder.decode(probs, 1, 37, allowed: digitCharset);
      expect(digits.text, '5');
    });

    test('an empty box decodes to empty text', () {
      final r = CtcDecoder.decode(frames([{0: 0.97}, {0: 0.99}]), 2, 37);
      expect(r.text, isEmpty);
      expect(r.confidence, greaterThan(0.9));
    });
  });

  group('PageAligner', () {
    test('homography maps the unit square onto the page corners', () {
      final corners = [
        const Offset(50, 40),
        const Offset(560, 80),
        const Offset(600, 760),
        const Offset(20, 700),
      ];
      final h = PageHomography.fromCorners(corners);
      expect(h.map(0, 0), offsetMoreOrLessEquals(corners[0], epsilon: 1e-6));
      expect(h.map(1, 0), offsetMoreOrLessEquals(corners[1], epsilon: 1e-6));
      expect(h.map(1, 1), offsetMoreOrLessEquals(corners[2], epsilon: 1e-6));
      expect(h.map(0, 1), offsetMoreOrLessEquals(corners[3], epsilon: 1e-6));
    });

    test('finds the corners of a skewed sheet on a desk', () {
      final corners = [
        const Offset(80, 60),
        const Offset(570, 95),
        const Offset(600, 740),
        const Offset(50, 710),
      ];
      final photo = photograph(canonicalPage(const []), corners);
      final found = PageAligner.detectPage(photo)!;
      for (var i = 0; i < 4; i++) {
        expect((found[i] - corners[i]).distance, lessThan(12),
            reason: 'corner $i: ${found[i]} vs ${corners[i]}');
      }
    });

    test('treats a frame-filling page as already cropped', () {
      final full = canonicalPage(const [Rect.fromLTRB(0.3, 0.3, 0.5, 0.35)]);
      expect(PageAligner.detectPage(full), isNull);
    });

    test('a template box yields the same crop from two different photos', () {
      // The plan's step-1 check: boxes drawn once reproduce the same field
      // after a re-scan at another angle.
      const mark = Rect.fromLTRB(0.62, 0.80, 0.70, 0.84);
      const box = Rect.fromLTRB(0.58, 0.77, 0.74, 0.87);
      final page = canonicalPage(const [mark, Rect.fromLTRB(0.1, 0.1, 0.5, 0.13)]);

      GrayImage cropFrom(List<Offset> corners) {
        final photo = photograph(page, corners);
        final found = PageAligner.detectPage(photo)!;
        return PageAligner.sampleRegion(
          photo,
          PageHomography.fromCorners(found),
          box,
          width: 64,
        );
      }

      final a = cropFrom(const [
        Offset(60, 50), Offset(580, 70), Offset(590, 760), Offset(40, 740)]);
      final b = cropFrom(const [
        Offset(120, 90), Offset(540, 60), Offset(610, 700), Offset(90, 770)]);
      expect(a.width, b.width);
      expect(a.height, b.height);
      expect(meanAbsDiff(a, b), lessThan(25));

      // And the crop really contains the ink: its centre is dark.
      expect(a.at(a.width ~/ 2, a.height ~/ 2), lessThan(100));
    });
  });

  group('OnnxSheetRecognizer.assemble', () {
    FieldCrop crop(FieldKind kind, {String label = '', String part = 'A'}) =>
        FieldCrop(
          TemplateField(
            kind: kind,
            box: const Rect.fromLTRB(0, 0, 0.1, 0.1),
            label: label,
            part: part,
          ),
          ModelInput(Float32List(32 * 16), 16),
          Uint8List(0),
        );

    test('reads boxed fields and strips leading zeros from marks', () {
      final result = OnnxSheetRecognizer.assemble([
        (crop(FieldKind.registration), const CtcReading('21B01A0512', 0.95)),
        (crop(FieldKind.partA), const CtcReading('05', 0.9)),
        (crop(FieldKind.partB), const CtcReading('41', 0.6)),
      ]);
      expect(result.registrationNo.value, '21B01A0512');
      expect(result.partA.value, '5');
      expect(result.partB.needsReview, isTrue);
      expect(result.total, 46);
    });

    test('derives a missing part total from its questions', () {
      final result = OnnxSheetRecognizer.assemble([
        (crop(FieldKind.question, label: 'Q1'), const CtcReading('4', 0.97)),
        (crop(FieldKind.question, label: 'Q2'), const CtcReading('7', 0.83)),
        (crop(FieldKind.question, label: 'Q3', part: 'B'),
            const CtcReading('10', 0.9)),
      ]);
      expect(result.partA.value, '11');
      // As confident as the least confident question.
      expect(result.partA.confidence, closeTo(0.83, 1e-9));
      expect(result.partB.value, '10');
      expect(result.questions, hasLength(3));
    });

    test('an unreadable question makes the derived total unreadable', () {
      final result = OnnxSheetRecognizer.assemble([
        (crop(FieldKind.question, label: 'Q1'), const CtcReading('4', 0.97)),
        (crop(FieldKind.question, label: 'Q2'), const CtcReading('', 0.9)),
      ]);
      expect(result.partA.isEmpty, isTrue);
      expect(result.partA.needsReview, isTrue);
    });
  });

  test('a validation issue forces review even at high confidence', () {
    const field = ExtractedField(value: '38', confidence: 0.99, issue: 'x');
    expect(field.needsReview, isTrue);
  });
}
