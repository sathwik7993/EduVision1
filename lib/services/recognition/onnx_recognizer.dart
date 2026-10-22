import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

import '../../models/scan_result.dart';
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
  const FieldCrop(this.field, this.input, this.png);

  final TemplateField field;
  final ModelInput input;
  final Uint8List png;
}

/// Reads handwritten fields from template boxes with the on-device model.
///
/// Pipeline: native decode -> page corner detection -> per-box perspective
/// sampling -> CRNN -> charset-constrained CTC decode. Confidence is the
/// minimum per-character probability, so one doubtful digit sends the field
/// to review.
class OnnxSheetRecognizer implements SheetRecognizer {
  OnnxSheetRecognizer(this._model);

  /// Throws if the model asset is missing or the runtime cannot load it; the
  /// caller falls back to ML Kit.
  static Future<OnnxSheetRecognizer> load() async =>
      OnnxSheetRecognizer(await OrtFieldModel.load());

  final FieldModel _model;

  @override
  String get displayName => 'On-device handwriting model';

  @override
  bool get supportsHandwriting => true;

  @override
  Future<void> dispose() => _model.close();

  @override
  Future<ScanResult> recognize(
    String imagePath, {
    SheetTemplate template = SheetTemplate.defaults,
  }) async {
    if (!template.hasBoxes) {
      throw StateError('Template "${template.name}" has no field boxes.');
    }
    final total = Stopwatch()..start();

    final page = await PageLoader.load(imagePath);
    final decodeMs = total.elapsedMilliseconds;

    final fields = template.fields;
    final crops = await Isolate.run(() => extractCrops(page, fields));
    final alignMs = total.elapsedMilliseconds - decodeMs;

    final readings = <(FieldCrop, CtcReading)>[];
    for (final crop in crops) {
      final out = await _model.run(crop.input);
      final allowed = crop.field.kind == FieldKind.registration
          ? fieldModelCharset
          : digitCharset;
      readings.add((
        crop,
        CtcDecoder.decode(out.probs, out.frames, out.classes, allowed: allowed),
      ));
    }
    final inferMs = total.elapsedMilliseconds - decodeMs - alignMs;

    final timings = {
      'decode': decodeMs,
      'align+crop': alignMs,
      'inference': inferMs,
      'fields': crops.length,
      'total': total.elapsedMilliseconds,
    };
    debugPrint('OnnxSheetRecognizer timings (ms): $timings');
    return assemble(readings, imagePath: imagePath, timingsMs: timings);
  }

  /// Runs in a background isolate: page detection and crop sampling are the
  /// only CPU-heavy Dart work in the pipeline.
  static List<FieldCrop> extractCrops(
    GrayImage page,
    List<TemplateField> fields,
  ) {
    final corners = PageAligner.detectPage(page);
    final homography = corners == null
        ? PageHomography.identity(page.width, page.height)
        : PageHomography.fromCorners(corners);

    return [
      for (final field in fields)
        () {
          final crop = PageAligner.sampleRegion(
            page,
            homography,
            PageAligner.pad(field.box),
          );
          final png = img.encodePng(
            img.Image.fromBytes(
              width: crop.width,
              height: crop.height,
              bytes: crop.pixels.buffer,
              numChannels: 1,
            ),
          );
          return FieldCrop(field, CropPreprocessor.prepare(crop), png);
        }(),
    ];
  }

  /// Maps per-box readings onto a [ScanResult]. A part total with no box of
  /// its own is the sum of that part's question boxes, and is only as
  /// confident as the least confident question.
  @visibleForTesting
  static ScanResult assemble(
    List<(FieldCrop, CtcReading)> readings, {
    String? imagePath,
    Map<String, int> timingsMs = const {},
  }) {
    ExtractedField toField(FieldCrop crop, CtcReading r) {
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

    final questions = [
      for (final (crop, r) in readings)
        if (crop.field.kind == FieldKind.question)
          QuestionMark(
            label: crop.field.label.isEmpty ? 'Q' : crop.field.label,
            part: crop.field.part,
            maxMarks: crop.field.maxMarks,
            field: toField(crop, r),
          ),
    ];

    ExtractedField partTotal(FieldKind kind, String part) {
      final boxed = single(kind);
      if (boxed != null) return boxed;
      final qs = questions.where((q) => q.part == part).toList();
      if (qs.isEmpty) return const ExtractedField.empty();
      final unreadable = qs.any((q) => q.field.isEmpty);
      return ExtractedField(
        value: unreadable ? '' : '${qs.fold(0, (s, q) => s + q.value)}',
        confidence:
            qs.map((q) => q.field.confidence).reduce((a, b) => a < b ? a : b),
        rawText: 'Sum of ${qs.map((q) => q.label).join(' + ')}',
      );
    }

    final raw = StringBuffer();
    for (final (crop, r) in readings) {
      raw.writeln('${crop.field.title}: "${r.text}" '
          '(${(r.confidence * 100).round()}%)');
    }
    if (timingsMs.isNotEmpty) raw.writeln('Timings (ms): $timingsMs');

    return ScanResult(
      registrationNo: single(FieldKind.registration) ??
          const ExtractedField.empty(),
      partA: partTotal(FieldKind.partA, 'A'),
      partB: partTotal(FieldKind.partB, 'B'),
      questions: questions,
      imagePath: imagePath,
      rawText: raw.toString().trim(),
      timingsMs: timingsMs,
    );
  }
}
