import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:eduvision_0_1/models/scan_result.dart';
import 'package:eduvision_0_1/models/sheet_template.dart';
import 'package:eduvision_0_1/services/correction_store.dart';
import 'package:eduvision_0_1/services/roster_service.dart';
import 'package:eduvision_0_1/services/scan_validator.dart';
import 'package:eduvision_0_1/services/template_store.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';

ExtractedField f(String v, [double c = 0.95]) =>
    ExtractedField(value: v, confidence: c);

LabelledMark q(String label, String v, {String part = 'A', int? max, double c = 0.95}) =>
    LabelledMark(label: label, part: part, maxMarks: max, field: f(v, c));

/// One example template: the CAT answer-book cover from sample_images/.
/// Not hard-coded anywhere in the app -- it is just a saved template.
const cat = SheetTemplate(
  id: 'cat',
  name: 'CAT answer book',
  partAMax: 40,
  partBMax: 80,
  registrationMask: 'DDADDADDXX',
  fields: [
    TemplateField(kind: FieldKind.registration, box: Rect.fromLTRB(0.58, 0.18, 0.95, 0.21)),
    TemplateField(kind: FieldKind.partA, box: Rect.fromLTRB(0.8, 0.73, 0.93, 0.77)),
    TemplateField(kind: FieldKind.partB, box: Rect.fromLTRB(0.8, 0.8, 0.93, 0.84)),
  ],
);

ScanResult sheet({
  String reg = '23H51A66D9',
  String a = '10',
  String b = '20',
  List<LabelledMark> questions = const [],
  List<LabelledMark> written = const [],
}) =>
    ScanResult(
      registrationNo: f(reg),
      partA: f(a),
      partB: f(b),
      questions: questions,
      writtenTotals: written,
    );

void main() {
  group('ScanValidator on the sample-sheet cases', () {
    test('(c) a consistent sheet passes untouched', () {
      final r = ScanValidator.validate(
        sheet(written: [q('Grand total', '30', part: '')]),
        cat,
      );
      expect(r.isReadyToSave, isTrue);
      expect(r.total, 30);
    });

    test('(a) Part-B 80 is fine when the template says the max is 80', () {
      final r = ScanValidator.validate(sheet(a: '40', b: '80'), cat);
      expect(r.partB.issue, isNull);
      // The library default (60) would have rejected it.
      final strict = ScanValidator.validate(
          sheet(a: '40', b: '80'), cat.copyWith(partBMax: 60));
      expect(strict.partB.issue, contains('maximum of 60'));
      expect(strict.isReadyToSave, isFalse);
    });

    test('(b) a written total that disagrees with Part-A + Part-B is flagged', () {
      final r = ScanValidator.validate(
        sheet(a: '40', b: '80', written: [
          q('Grand total', '', part: ''), // blank cell: fine
          q('Total in words', '30', part: ''),
        ]),
        cat,
      );
      expect(r.writtenTotals[0].needsReview, isFalse);
      expect(r.writtenTotals[1].field.issue, contains('120'));
      expect(r.isReadyToSave, isFalse);
      // The workbook still gets the derived sum, never the written figure.
      expect(r.total, 120);
    });

    test('(d) a registration number with only "23" filled is incomplete', () {
      final r = ScanValidator.validate(sheet(reg: '23'), cat);
      expect(r.registrationNo.issue, contains('Incomplete: read 2 of 10'));
      expect(r.isReadyToSave, isFalse);
    });

    test('a letter where the mask needs a digit is flagged', () {
      final r = ScanValidator.validate(sheet(reg: '2BH51A66D9'), cat);
      expect(r.registrationNo.issue, contains('format'));
    });

    test('(e) an empty marks slip needs the teacher', () {
      final r = ScanValidator.validate(sheet(a: '', b: ''), cat);
      expect(r.fieldsNeedingReview, containsAll(['Part-A', 'Part-B']));
    });

    test('(f) a registration number already saved is flagged', () {
      final r = ScanValidator.validate(sheet(), cat,
          alreadySaved: {'23H51A66D9'});
      expect(r.registrationNo.issue, contains('Already in the results sheet'));
    });

    test('question marks must add up to a boxed part total', () {
      final template = cat.copyWith(fields: [
        ...cat.fields,
        const TemplateField(kind: FieldKind.question, box: Rect.zero, label: 'Q1'),
      ]);
      final r = ScanValidator.validate(
        sheet(a: '10', questions: [q('Q1', '4'), q('Q2', '5'), q('Q3', '')]),
        template,
      );
      expect(r.partA.issue, contains('add up to 9'));
      expect(r.questions.first.needsReview, isTrue);

      final ok = ScanValidator.validate(
        sheet(a: '9', questions: [q('Q1', '4'), q('Q2', '5'), q('Q3', '')]),
        template,
      );
      expect(ok.partA.issue, isNull);

      // Only totals filled: no sum check, no flags.
      final totalsOnly = ScanValidator.validate(
        sheet(a: '9', questions: [q('Q1', ''), q('Q2', '')]),
        template,
      );
      expect(totalsOnly.isReadyToSave, isTrue);
    });

    test('a question above its own maximum is flagged', () {
      final r = ScanValidator.validate(
          sheet(questions: [q('Q1', '7', max: 5)]), cat);
      expect(r.questions.single.field.issue, contains('maximum of 5'));
    });

    test('a registration number between the mark gate and 0.95 goes to review', () {
      final r = ScanValidator.validate(
          sheet().copyWith(registrationNo: f('23H51A66D9', 0.9)), cat);
      expect(r.registrationNo.issue, contains('Not certain enough'));
      expect(r.registrationNo.needsReview, isTrue);
    });

    test('a value the teacher typed is never flagged', () {
      final r = ScanValidator.validate(
        sheet().copyWith(registrationNo: const ExtractedField.manual('23')),
        cat,
      );
      expect(r.registrationNo.issue, isNull);
    });

    test('validation is idempotent', () {
      final once = ScanValidator.validate(sheet(reg: '23'), cat);
      final twice = ScanValidator.validate(once, cat);
      expect(twice.registrationNo.issue, isNot(contains(';')));
    });

    test('blocking errors catch a typed mark above the maximum', () {
      final r = sheet().copyWith(partA: const ExtractedField.manual('45'));
      expect(ScanValidator.blockingErrors(r, cat), ['Part-A: Above the maximum of 40']);
    });
  });

  group('Roster', () {
    test('flags an unknown number and suggests the closest one', () {
      final roster = Roster(['23H51A66D9', '23H51A66K1', '23H53A66D9']);
      final r = ScanValidator.validate(sheet(reg: '23H51A66D8'), cat,
          roster: roster);
      expect(r.registrationNo.issue, contains('Not on the class roster'));
      expect(r.registrationNo.suggestion, '23H51A66D9');
    });

    test('does not suggest when two students are equally close', () {
      final roster = Roster(['23H51A6601', '23H51A6603']);
      expect(roster.closest('23H51A6602'), isNull);
    });

    test('imports the registration column from an Excel list', () {
      final excel = Excel.createExcel();
      final sheetName = excel.getDefaultSheet()!;
      excel[sheetName]
        ..appendRow([TextCellValue('S.No'), TextCellValue('Name'), TextCellValue('Roll No')])
        ..appendRow([IntCellValue(1), TextCellValue('A'), TextCellValue('23h51a66d9')])
        ..appendRow([IntCellValue(2), TextCellValue('B'), TextCellValue(' 23H51A66K1 ')])
        ..appendRow([IntCellValue(3), TextCellValue('C'), TextCellValue('')]);
      final roster = Roster.fromExcel(excel.encode()!);
      expect(roster.registrations, {'23H51A66D9', '23H51A66K1'});
    });
  });

  group('Local storage', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('eduvision_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('templates round-trip and the newest becomes active', () async {
      final store = TemplateStore(directory: () async => dir);
      expect((await store.active()).hasBoxes, isFalse);

      final withAnchors = SheetTemplate(
        id: 'cat',
        name: cat.name,
        fields: cat.fields,
        partAMax: 40,
        partBMax: 80,
        registrationMask: 'DDADDADDXX',
        anchors: const [
          TemplateAnchor('grand total', [Offset(0.7, 0.86), Offset(0.78, 0.86),
            Offset(0.78, 0.89), Offset(0.7, 0.89)]),
        ],
      );
      await store.save(withAnchors);
      await store.save(const SheetTemplate(id: 'other', name: 'Other'));
      await store.setActive('cat');

      final active = await store.active();
      expect(active.name, 'CAT answer book');
      expect(active.partBMax, 80);
      expect(active.registrationMask, 'DDADDADDXX');
      expect(active.fields[1].kind, FieldKind.partA);
      expect(active.fields[1].box, cat.fields[1].box);
      expect(active.anchors.single.corners[2], const Offset(0.78, 0.89));

      await store.delete('cat');
      expect((await store.all()).map((t) => t.id), ['other']);
      expect((await store.active()).id, 'default');
    });

    test('corrections are kept as labelled crops on the device', () async {
      final store = CorrectionStore(directory: () async => dir);
      final crop = Uint8List.fromList([137, 80, 78, 71]);
      final original = ScanResult(
        registrationNo: ExtractedField(value: '23H51A66D8', confidence: 0.7, crop: crop),
        partA: ExtractedField(value: '10', confidence: 0.95, crop: crop),
        partB: const ExtractedField.empty(),
      );
      final reviewed = original.copyWith(
        registrationNo: const ExtractedField.manual('23H51A66D9'),
      );

      final written = await store.record(
          original: original, reviewed: reviewed, templateId: 'cat');
      expect(written, 2); // partB had no crop

      final rows = await store.readAll();
      expect(rows.first['predicted'], '23H51A66D8');
      expect(rows.first['label'], '23H51A66D9');
      expect(rows.first['corrected'], isTrue);
      expect(rows.last['corrected'], isFalse);
      expect(
        File('${dir.path}/${CorrectionStore.folder}/${rows.first['file']}')
            .existsSync(),
        isTrue,
      );
    });
  });
}
