import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

import '../../models/scan_result.dart';
import 'anchor_aligner.dart';
import 'crop_preprocessor.dart';
import 'ctc_decoder.dart';
import 'page_aligner.dart';
import 'page_loader.dart';
import 'sheet_recognizer.dart';

/// Per-frame class probabilities for one crop, row-major [frames, classes].
class FieldModelOutput {
  const FieldModelOutput(this.probs, this.frames, this.classes);

  final Float32List probs;
  final int frames;
  final int classes;
}

/// The field model behind an interface, so recognition logic is unit-testable
/// without the native ONNX runtime.
abstract interface class FieldModel {
  Future<FieldModelOutput> run(ModelInput input);

  Future<void> close();
}

/// The CRNN from training/recognizer, run by ONNX Runtime on the CPU.
class OrtFieldModel implements FieldModel {
  OrtFieldModel._(this._session);

  /// Versioned file name: flutter_onnxruntime caches the extracted asset by
  /// name, so shipping a retrained model under the same name would keep
  /// loading the old one.
  static const asset = 'assets/models/field_recognizer_v1.onnx';

  final OrtSession _session;

  static Future<OrtFieldModel> load() async {
    final session = await OnnxRuntime().createSessionFromAsset(
      asset,
      // Two threads: entry-level phones have big.LITTLE cores, and more
      // threads than big cores makes a model this small slower, not faster.
      options: OrtSessionOptions(intraOpNumThreads: 2),
    );
    return OrtFieldModel._(session);
  }

  @override
  Future<FieldModelOutput> run(ModelInput input) async {
    final tensor = await OrtValue.fromList(
      input.data,
      [1, 1, ModelInput.height, input.width],
    );
    Map<String, OrtValue>? outputs;
    try {
      outputs = await _session.run({'input': tensor});
      final probs = outputs['probs']!;
      final flat = await probs.asFlattenedList();
      return FieldModelOutput(
        Float32List.fromList([for (final v in flat) (v as num).toDouble()]),
        probs.shape[1],
        probs.shape[2],
      );
    } finally {
      await tensor.dispose();
      for (final value in outputs?.values ?? const <OrtValue>[]) {
        await value.dispose();
      }
    }
  }

  @override
  Future<void> close() => _session.close();
}

/// One template field, cut out of the photo and ready for the model.
class FieldCrop {
  const FieldCrop(this.field, this.input, this.png, {this.outside = false});

  final TemplateField field;
  final ModelInput input;
  final Uint8List png;

  /// The box falls (partly) outside the photo, e.g. the slip was cut off.
  /// Whatever the model reads there is meaningless.
  final bool outside;
}

/// How a photo was registered onto the template, best first.
enum PageAlignment { anchors, pageCorners, none }

/// Reads handwritten fields from template boxes with the on-device model.
///
/// Pipeline: native decode -> registration onto the template (printed-text
/// anchors, else page corners, else the whole frame) -> per-box perspective
/// sampling -> CRNN -> charset-constrained CTC decode. Confidence is the
/// minimum per-character probability, so one doubtful digit sends the field
/// to review.
class OnnxSheetRecognizer implements SheetRecognizer {
  OnnxSheetRecognizer(this._model, [this._lines]);

  /// Throws if the model asset is missing or the runtime cannot load it; the
  /// caller falls back to ML Kit.
  static Future<OnnxSheetRecognizer> load() async =>
      OnnxSheetRecognizer(await OrtFieldModel.load(), MlKitLineReader());

  final FieldModel _model;
  final TextLineReader? _lines;

  @override
  String get displayName => 'On-device handwriting model';

  @override
  bool get supportsHandwriting => true;

  @override
  Future<void> dispose() async {
    await _model.close();
    await _lines?.close();
  }

  @override
  Future<ScanResult> recognize(
    String imagePath, {
    SheetTemplate template = SheetTemplate.defaults,
  }) async {
    if (!template.hasBoxes) {
      throw StateError('Template "${template.name}" has no field boxes.');
    }
    final clock = Stopwatch()..start();
    final timings = <String, int>{};
    var last = 0;
    void lap(String stage) {
      timings[stage] = clock.elapsedMilliseconds - last;
      last = clock.elapsedMilliseconds;
    }

    final page = await PageLoader.load(imagePath);
    lap('decode');

    final (homography, alignment) = await locatePage(page, template, _lines);
    lap('align');

    final fields = template.fields;
    final crops =
        await Isolate.run(() => extractCrops(page, homography, fields));
    lap('crop');

    final readings = <(FieldCrop, CtcReading)>[];
    for (final crop in crops) {
      final out = await _model.run(crop.input);
      readings.add((crop, read(out, crop.field, template)));
    }
    lap('inference');
    timings['fields'] = crops.length;
    timings['total'] = clock.elapsedMilliseconds;

    debugPrint('OnnxSheetRecognizer ${alignment.name} timings (ms): $timings');
    return assemble(
      readings,
      imagePath: imagePath,
      timingsMs: timings,
      alignment: alignment,
    );
  }

  /// Registers [page] onto the template's page space.
  static Future<(PageHomography, PageAlignment)> locatePage(
    GrayImage page,
    SheetTemplate template,
    TextLineReader? lines,
  ) async {
    if (lines != null && template.anchors.isNotEmpty) {
      try {
        final hits = await lines.read(page);
        final h = AnchorAligner.align(template.anchors, hits);
        if (h != null) return (h, PageAlignment.anchors);
      } on Exception catch (e) {
        debugPrint('Anchor alignment failed: $e');
      }
    }
    final corners = await Isolate.run(() => PageAligner.detectPage(page));
    if (corners != null) {
      return (PageHomography.fromCorners(corners), PageAlignment.pageCorners);
    }
    return (
      PageHomography.identity(page.width, page.height),
      PageAlignment.none,
    );
  }

  /// Decodes one crop with the charset its field allows.
  static CtcReading read(
    FieldModelOutput out,
    TemplateField field,
    SheetTemplate template,
  ) {
    if (field.kind != FieldKind.registration) {
      return CtcDecoder.decode(out.probs, out.frames, out.classes,
          allowed: digitCharset);
    }
    final mask = template.registrationMask;
    return mask == null || mask.isEmpty
        ? CtcDecoder.decode(out.probs, out.frames, out.classes)
        : CtcDecoder.decodeMasked(out.probs, out.frames, out.classes, mask);
  }

  /// Runs in a background isolate: crop sampling is the CPU-heavy Dart work.
  static List<FieldCrop> extractCrops(
    GrayImage page,
    PageHomography homography,
    List<TemplateField> fields,
  ) {
    return [
      for (final field in fields)
        () {
          final box = PageAligner.pad(field.box);
          final crop = PageAligner.sampleRegion(page, homography, box);
          final tolX = page.width * 0.01, tolY = page.height * 0.01;
          final outside = [
            box.topLeft,
            box.topRight,
            box.bottomLeft,
            box.bottomRight,
          ].map((c) => homography.map(c.dx, c.dy)).any((p) =>
              p.dx < -tolX ||
              p.dy < -tolY ||
              p.dx > page.width + tolX ||
              p.dy > page.height + tolY);
          final png = img.encodePng(
            img.Image.fromBytes(
              width: crop.width,
              height: crop.height,
              bytes: crop.pixels.buffer,
              numChannels: 1,
            ),
          );
          return FieldCrop(field, CropPreprocessor.prepare(crop), png,
              outside: outside);
        }(),
    ];
  }

  /// Maps per-box readings onto a [ScanResult]. A part total with no box of
  /// its own is the sum of that part's question boxes (blank cells count as
  /// 0), and is only as confident as the least confident question.
  @visibleForTesting
  static ScanResult assemble(
    List<(FieldCrop, CtcReading)> readings, {
    String? imagePath,
    Map<String, int> timingsMs = const {},
    PageAlignment alignment = PageAlignment.none,
  }) {
    ExtractedField toField(FieldCrop crop, CtcReading r) {
      if (crop.outside) {
        return ExtractedField(
          value: '',
          confidence: 0,
          rawText: r.text,
          issue: 'Not in the photo: rescan the whole page or type it',
          crop: crop.png,
        );
      }
      var value = r.text;
      if (crop.field.kind != FieldKind.registration && value.isNotEmpty) {
        value = int.tryParse(value)?.toString() ?? value; // "05" -> "5"
      }
      return ExtractedField(
        value: value,
        confidence: r.confidence,
        rawText: r.text,
        crop: crop.png,
      );
    }

    ExtractedField? single(FieldKind kind) {
      for (final (crop, r) in readings) {
        if (crop.field.kind == kind) return toField(crop, r);
      }
      return null;
    }

    List<LabelledMark> marks(FieldKind kind, String fallback) => [
          for (final (crop, r) in readings)
            if (crop.field.kind == kind)
              LabelledMark(
                label: crop.field.label.isEmpty ? fallback : crop.field.label,
                part: kind == FieldKind.question ? crop.field.part : '',
                maxMarks: crop.field.maxMarks,
                field: toField(crop, r),
              ),
        ];
    final questions = marks(FieldKind.question, 'Q');
    final written = marks(FieldKind.writtenTotal, 'Grand total');

    ExtractedField partTotal(FieldKind kind, String part) {
      final boxed = single(kind);
      if (boxed != null) return boxed;
      final qs = questions.where((q) => q.part == part).toList();
      if (qs.isEmpty) return const ExtractedField.empty();
      final allBlank = qs.every((q) => q.field.isEmpty);
      return ExtractedField(
        value: allBlank ? '' : '${qs.fold(0, (s, q) => s + q.value)}',
        confidence:
            qs.map((q) => q.field.confidence).reduce((a, b) => a < b ? a : b),
        rawText: 'Sum of ${qs.map((q) => q.label).join(' + ')}',
      );
    }

    final raw = StringBuffer('Alignment: ${alignment.name}\n');
    for (final (crop, r) in readings) {
      raw.writeln('${crop.field.title}: "${r.text}" '
          '(${(r.confidence * 100).round()}%)');
    }
    if (timingsMs.isNotEmpty) raw.writeln('Timings (ms): $timingsMs');

    return ScanResult(
      registrationNo:
          single(FieldKind.registration) ?? const ExtractedField.empty(),
      partA: partTotal(FieldKind.partA, 'A'),
      partB: partTotal(FieldKind.partB, 'B'),
      questions: questions,
      writtenTotals: written,
      imagePath: imagePath,
      rawText: raw.toString().trim(),
      timingsMs: timingsMs,
    );
  }
}
