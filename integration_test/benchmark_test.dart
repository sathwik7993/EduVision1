import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:eduvision_0_1/models/scan_result.dart';
import 'package:eduvision_0_1/models/sheet_template.dart';
import 'package:eduvision_0_1/services/recognition/crop_preprocessor.dart';
import 'package:eduvision_0_1/services/recognition/ctc_decoder.dart';
import 'package:eduvision_0_1/services/recognition/onnx_recognizer.dart';
import 'package:eduvision_0_1/services/recognition/page_aligner.dart';
import 'package:eduvision_0_1/services/recognition/page_loader.dart';
import 'package:eduvision_0_1/services/recognition/text_normalizer.dart';
import 'package:eduvision_0_1/services/scan_validator.dart';
import 'package:eduvision_0_1/services/template_builder.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// On-device benchmark: ONNX field model vs ML Kit on labelled crops, and the
/// full pipeline (anchor alignment included) on the real sample photos.
///
/// Prepare the data with training/real_eval/export_bench.py and adb push it
/// to the app's external files dir, then:
///   `flutter test integration_test/benchmark_test.dart -d DEVICE`
/// Results are printed and written next to the data (results_*.json).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory bench;
  setUpAll(() async {
    bench = Directory('${(await getExternalStorageDirectory())!.path}/bench');
  });

  GrayImage loadGray(String path) {
    final decoded = img.decodeImage(File(path).readAsBytesSync())!;
    return GrayImage.fromRgba(
      decoded.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba),
      decoded.width,
      decoded.height,
    );
  }

  testWidgets('crops: ONNX field model vs ML Kit', (tester) async {
    final labelsFile = File('${bench.path}/labels.json');
    if (!labelsFile.existsSync()) {
      markTestSkipped('No ${labelsFile.path}; run export_bench.py and adb push.');
      return;
    }
    final labels = (jsonDecode(labelsFile.readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();
    final model = await OrtFieldModel.load();
    final mlKit = TextRecognizer(script: TextRecognitionScript.latin);
    final stats = <String, Map<String, num>>{};

    for (final item in labels) {
      final path = '${bench.path}/crops/${item['file']}';
      final isReg = item['kind'] == 'reg';
      final label = item['label'] as String;
      final source = item['source'] as String;
      final s = stats.putIfAbsent(source, () => {
            'n': 0, 'onnxOk': 0, 'onnxAuto': 0, 'onnxSilent': 0, 'onnxMs': 0,
            'mlkitOk': 0, 'mlkitMs': 0,
          });

      final clock = Stopwatch()..start();
      final input = CropPreprocessor.prepare(loadGray(path));
      final out = await model.run(input);
      final r = isReg
          ? (source == 'real'
              ? CtcDecoder.decodeMasked(out.probs, out.frames, out.classes, 'DDADDADDXX')
              : CtcDecoder.decode(out.probs, out.frames, out.classes))
          : CtcDecoder.decode(out.probs, out.frames, out.classes,
              allowed: digitCharset);
      final onnxMs = clock.elapsedMicroseconds / 1000;
      var onnxText = r.text;
      if (!isReg && onnxText.isNotEmpty) {
        onnxText = int.tryParse(onnxText)?.toString() ?? onnxText;
      }

      clock
        ..reset()
        ..start();
      final read = await mlKit.processImage(InputImage.fromFilePath(path));
      final mlkitMs = clock.elapsedMicroseconds / 1000;
      String mlkitText;
      if (isReg) {
        mlkitText = TextNormalizer.cleanRegistration(read.text);
      } else {
        mlkitText = '';
        for (final token in read.text.split(RegExp(r'\s+'))) {
          final d = TextNormalizer.coerceToDigits(token);
          if (d != null && d.length <= 3) {
            mlkitText = int.parse(d).toString();
            break;
          }
        }
      }

      final accepted = r.confidence >= ExtractedField.trustedAbove;
      s['n'] = s['n']! + 1;
      s['onnxOk'] = s['onnxOk']! + (onnxText == label ? 1 : 0);
      s['onnxAuto'] = s['onnxAuto']! + (accepted ? 1 : 0);
      s['onnxSilent'] = s['onnxSilent']! + (accepted && onnxText != label ? 1 : 0);
      s['onnxMs'] = s['onnxMs']! + onnxMs;
      s['mlkitOk'] = s['mlkitOk']! + (mlkitText == label ? 1 : 0);
      s['mlkitMs'] = s['mlkitMs']! + mlkitMs;
      if (source == 'real') {
        debugPrint('real ${item['file']} label="$label" onnx="$onnxText" '
            '(${(r.confidence * 100).round()}%) mlkit="$mlkitText"');
      }
    }
    await model.close();
    await mlKit.close();

    debugPrint('source | n | ONNX exact | ONNX auto-accept | ONNX silent err | '
        'ONNX ms/crop | ML Kit exact | ML Kit ms/crop');
    stats.forEach((source, s) {
      final n = s['n']!;
      String pct(num v) => '${(100 * v / n).toStringAsFixed(1)}%';
      debugPrint('$source | $n | ${pct(s['onnxOk']!)} | ${pct(s['onnxAuto']!)} | '
          '${pct(s['onnxSilent']!)} | ${(s['onnxMs']! / n).toStringAsFixed(1)} | '
          '${pct(s['mlkitOk']!)} | ${(s['mlkitMs']! / n).toStringAsFixed(1)}');
    });
    File('${bench.path}/results_crops.json').writeAsStringSync(jsonEncode(stats));
  });

  testWidgets('real photos: full pipeline with a template from one sample',
      (tester) async {
    final annFile = File('${bench.path}/photos/annotations.json');
    if (!annFile.existsSync()) {
      markTestSkipped('No ${annFile.path}; run export_bench.py and adb push.');
      return;
    }
    final ann = (jsonDecode(annFile.readAsStringSync()) as Map)
        .cast<String, dynamic>()
      ..removeWhere((k, _) => k.startsWith('_'));

    // The teacher's one-time setup, done on the cleanest full-page photo:
    // deskew it, record anchors, and draw the boxes (here: the hand boxes,
    // mapped into the deskewed page space).
    const reference = 'WhatsApp Image 2026-10-22 at 12.13.33 PM.jpeg';
    final refPath = '${bench.path}/photos/$reference';
    final sample = await TemplateBuilder.prepare(refPath, 'bench_cat');
    final refGray = await PageLoader.load(refPath);
    final corners = PageAligner.detectPage(refGray) ??
        [
          Offset.zero,
          Offset(refGray.width.toDouble(), 0),
          Offset(refGray.width.toDouble(), refGray.height.toDouble()),
          Offset(0, refGray.height.toDouble()),
        ];
    final toPage = PageHomography.fit(corners, const [
      Offset(0, 0), Offset(1, 0), Offset(1, 1), Offset(0, 1)])!;
    final kinds = {
      'registration': FieldKind.registration,
      'partA': FieldKind.partA,
      'partB': FieldKind.partB,
      'grandTotal': FieldKind.writtenTotal,
      'totalInWords': FieldKind.writtenTotal,
    };
    final fields = <TemplateField>[
      for (final MapEntry(key: name, value: entry)
          in (ann[reference] as Map).cast<String, dynamic>().entries)
        () {
          final b = ((entry as List)[0] as List).cast<num>();
          final tl = toPage.map(b[0].toDouble(), b[1].toDouble());
          final br = toPage.map(b[2].toDouble(), b[3].toDouble());
          return TemplateField(
            kind: kinds[name]!,
            box: Rect.fromPoints(tl, br),
            label: name == 'grandTotal'
                ? 'Grand total'
                : name == 'totalInWords'
                    ? 'Total in words'
                    : '',
          );
        }(),
    ];
    final template = SheetTemplate(
      id: 'bench_cat',
      name: 'CAT answer book',
      fields: fields,
      anchors: sample.anchors,
      registrationMask: 'DDADDADDXX',
      partAMax: 40,
      partBMax: 80,
    );
    debugPrint('template: ${fields.length} boxes, ${sample.anchors.length} anchors');

    final recognizer = await OnnxSheetRecognizer.load();
    var fieldsTotal = 0, fieldsOk = 0, auto = 0, silent = 0;
    final rows = <Map<String, Object?>>[];
    for (final MapEntry(key: name, value: truth) in ann.entries) {
      final raw = await recognizer.recognize('${bench.path}/photos/$name',
          template: template);
      final result = ScanValidator.validate(raw, template);
      final read = <String, ExtractedField>{
        'registration': result.registrationNo,
        'partA': result.partA,
        'partB': result.partB,
        for (final w in result.writtenTotals)
          w.label == 'Grand total' ? 'grandTotal' : 'totalInWords': w.field,
      };
      for (final MapEntry(key: field, value: entry)
          in (truth as Map).cast<String, dynamic>().entries) {
        final label = (entry as List)[1] as String;
        final got = read[field]!;
        final ok = got.value == label;
        final needsReview = field == 'grandTotal' || field == 'totalInWords'
            ? result.writtenTotals
                .firstWhere((w) => (w.label == 'Grand total') == (field == 'grandTotal'))
                .needsReview
            : got.needsReview;
        fieldsTotal++;
        if (ok) fieldsOk++;
        if (!needsReview) auto++;
        if (!needsReview && !ok) silent++;
        rows.add({
          'photo': name.split(' at ').last,
          'field': field,
          'label': label,
          'read': got.value,
          'confidence': got.confidence,
          'issue': got.issue,
          'review': needsReview,
        });
        debugPrint('${name.split(' at ').last} $field label="$label" '
            'read="${got.value}" ${(got.confidence * 100).round()}% '
            '${needsReview ? 'REVIEW' : 'auto'} ${got.issue ?? ''}');
      }
      debugPrint('  ${raw.rawText.split('\n').first} ${raw.timingsMs}');
      rows.add({'photo': name, 'timings': raw.timingsMs, 'alignment': raw.rawText.split('\n').first});
    }
    await recognizer.dispose();
    debugPrint('fields $fieldsTotal: exact $fieldsOk, auto-accepted $auto, '
        'silent errors $silent');
    File('${bench.path}/results_e2e.json').writeAsStringSync(jsonEncode(rows));
  });
}
