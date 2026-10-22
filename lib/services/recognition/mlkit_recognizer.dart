import 'dart:ui';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../../models/scan_result.dart';
import 'image_preprocessor.dart';
import 'sheet_recognizer.dart';
import 'text_normalizer.dart';

/// A single field reading produced from one image variant.
class _Candidate {
  const _Candidate(this.value, this.confidence, this.raw);

  final String value;
  final double confidence;
  final String raw;

  static const none = _Candidate('', 0, '');
}

/// Offline recognizer built on ML Kit's on-device Latin text model.
///
/// Two things make this substantially better than the original implementation,
/// which flattened everything to one string and ran three regexes over it:
///
/// 1. **Layout-aware extraction.** Values are located relative to their label's
///    bounding box (same line to the right, else the line below), so a value
///    that OCR emits on a separate line from its label is still found.
/// 2. **Cross-variant voting.** The same page is read three times under
///    different contrast curves; when two variants agree on a value that is
///    much stronger evidence than any single read, and confidence is raised
///    accordingly.
///
/// It still cannot read free-form handwriting -- ML Kit's model is trained on
/// printed text. [supportsHandwriting] reports that honestly so the UI can
/// tell the teacher to verify every handwritten field.
class MlKitSheetRecognizer implements SheetRecognizer {
  MlKitSheetRecognizer();

  final TextRecognizer _recognizer =
      TextRecognizer(script: TextRecognitionScript.latin);

  @override
  String get displayName => 'On-device (ML Kit)';

  @override
  bool get supportsHandwriting => false;

  @override
  Future<void> dispose() => _recognizer.close();

  @override
  Future<ScanResult> recognize(
    String imagePath, {
    SheetTemplate template = SheetTemplate.defaults,
  }) async {
    final variants = await ImagePreprocessor.buildVariants(imagePath);

    final regCandidates = <_Candidate>[];
    final partACandidates = <_Candidate>[];
    final partBCandidates = <_Candidate>[];
    var bestRawText = '';

    for (final variant in variants) {
      final RecognizedText recognized;
      try {
        recognized = await _recognizer.processImage(
          InputImage.fromFilePath(variant.path),
        );
      } on Exception {
        continue; // A failed variant should not sink the whole scan.
      }

      final lines = _flattenLines(recognized);
      if (recognized.text.length > bestRawText.length) {
        bestRawText = recognized.text;
      }

      regCandidates.add(_extractRegistration(lines, template));
      partACandidates.add(
        _extractNumber(lines, template.partALabels, template.partAMax),
      );
      partBCandidates.add(
        _extractNumber(lines, template.partBLabels, template.partBMax),
      );
    }

    // Temp variants are no longer needed; the original capture is kept for the
    // review screen.
    await ImagePreprocessor.discard(variants.map((v) => v.path));

    return ScanResult(
      registrationNo: _vote(regCandidates),
      partA: _vote(partACandidates),
      partB: _vote(partBCandidates),
      imagePath: imagePath,
      rawText: bestRawText,
    );
  }

  /// Combine per-variant readings. Agreement between variants is the strongest
  /// signal available offline, so it outweighs any single variant's own score.
  ExtractedField _vote(List<_Candidate> candidates) {
    final valid = candidates.where((c) => c.value.isNotEmpty).toList();
    if (valid.isEmpty) return const ExtractedField.empty();

    final tally = <String, List<_Candidate>>{};
    for (final candidate in valid) {
      tally.putIfAbsent(candidate.value, () => []).add(candidate);
    }

    MapEntry<String, List<_Candidate>>? best;
    var bestScore = -1.0;
    for (final entry in tally.entries) {
      final peak = entry.value
          .map((c) => c.confidence)
          .reduce((a, b) => a > b ? a : b);
      // Each additional agreeing variant closes ~35% of the remaining gap to 1.
      var score = peak;
      for (var i = 1; i < entry.value.length; i++) {
        score += (1 - score) * 0.35;
      }
      if (score > bestScore) {
        bestScore = score;
        best = entry;
      }
    }

    return ExtractedField(
      value: best!.key,
      confidence: bestScore.clamp(0.0, 1.0),
      rawText: best.value.first.raw,
    );
  }

  List<_Line> _flattenLines(RecognizedText recognized) {
    final lines = <_Line>[];
    for (final block in recognized.blocks) {
      for (final line in block.lines) {
        lines.add(_Line(line.text, line.boundingBox));
      }
    }
    // Reading order: top to bottom, then left to right.
    lines.sort((a, b) {
      final dy = a.box.top.compareTo(b.box.top);
      return dy != 0 ? dy : a.box.left.compareTo(b.box.left);
    });
    return lines;
  }

  /// Locate the line whose text best matches any of [labels].
  ({_Line line, String remainder, double score})? _findLabel(
    List<_Line> lines,
    List<String> labels,
  ) {
    ({_Line line, String remainder, double score})? best;

    for (final line in lines) {
      final normalized = TextNormalizer.normalizeLabel(line.text);
      if (normalized.isEmpty) continue;

      for (final label in labels) {
        // Prefer a clean substring hit; it also tells us where the value starts.
        final index = normalized.indexOf(label);
        if (index >= 0) {
          final remainder = normalized.substring(index + label.length).trim();
          if (best == null || best.score < 1.0) {
            best = (line: line, remainder: remainder, score: 1.0);
          }
          continue;
        }

        // Otherwise allow a fuzzy match against the leading portion of the
        // line, which is where a label sits.
        final head = normalized.length > label.length + 4
            ? normalized.substring(0, label.length + 4)
            : normalized;
        final similarity = TextNormalizer.similarity(head, label);
        if (similarity >= 0.78 && (best == null || similarity > best.score)) {
          final remainder = normalized.length > label.length
              ? normalized.substring(label.length).trim()
              : '';
          best = (line: line, remainder: remainder, score: similarity);
        }
      }
    }
    return best;
  }

  /// Extract a bounded integer associated with [labels].
  _Candidate _extractNumber(List<_Line> lines, List<String> labels, int max) {
    final match = _findLabel(lines, labels);
    if (match == null) return _Candidate.none;

    // Penalty for having matched the label only approximately.
    final labelPenalty = (1 - match.score) * 0.5;

    // 1. Value on the same line, after the label.
    final inline = _firstNumber(match.remainder, max);
    if (inline != null) {
      return _Candidate(
        inline.value,
        (0.92 - labelPenalty - inline.penalty).clamp(0.0, 1.0),
        match.remainder,
      );
    }

    // 2. Value on the same visual row but emitted as a separate line -- common
    //    when the label is printed and the mark is handwritten far to the right.
    final sameRow = _linesOnRow(lines, match.line)
        .where((l) => l.box.left > match.line.box.left);
    for (final line in sameRow) {
      final found = _firstNumber(TextNormalizer.normalizeLabel(line.text), max);
      if (found != null) {
        return _Candidate(
          found.value,
          (0.84 - labelPenalty - found.penalty).clamp(0.0, 1.0),
          line.text,
        );
      }
    }

    // 3. Value on the next line below, horizontally overlapping the label.
    final below = _linesBelow(lines, match.line);
    for (final line in below.take(2)) {
      final found = _firstNumber(TextNormalizer.normalizeLabel(line.text), max);
      if (found != null) {
        return _Candidate(
          found.value,
          (0.70 - labelPenalty - found.penalty).clamp(0.0, 1.0),
          line.text,
        );
      }
    }

    return _Candidate.none;
  }

  /// First plausible integer in [text], repaired and range-checked.
  ({String value, double penalty})? _firstNumber(String text, int max) {
    if (text.trim().isEmpty) return null;

    for (final token in text.split(RegExp(r'\s+'))) {
      if (token.isEmpty) continue;

      // Strip a leading separator OCR keeps from "Total : 38".
      final cleaned = token.replaceAll(RegExp(r'^[:\-=.]+'), '');
      if (cleaned.isEmpty) continue;

      final digits = TextNormalizer.coerceToDigits(cleaned);
      if (digits == null || digits.isEmpty) continue;

      // A mark is at most three digits; anything longer is a misread of
      // something else on the page (a date, a registration number).
      if (digits.length > 3) continue;

      final parsed = int.tryParse(digits);
      if (parsed == null) continue;
      // Out-of-range readings are rejected outright rather than saved with low
      // confidence -- a mark above the maximum is definitely wrong.
      if (parsed > max) continue;

      final penalty = TextNormalizer.repairRatio(cleaned, digits) * 0.45;
      return (value: parsed.toString(), penalty: penalty);
    }
    return null;
  }

  _Candidate _extractRegistration(List<_Line> lines, SheetTemplate template) {
    final pattern = template.registrationPattern ??
        RegExp(r'^(?=.*\d.*\d)[A-Z0-9]{6,15}$');

    ({String value, double confidence, String raw})? best;

    void consider(String token, double baseConfidence, String raw) {
      final cleaned = TextNormalizer.cleanRegistration(token);
      if (cleaned.length < 6) return;
      if (!pattern.hasMatch(cleaned)) return;

      var confidence = baseConfidence;
      final expected = template.registrationLength;
      if (expected != null) {
        if (cleaned.length != expected) {
          // Wrong length usually means a merged or split token.
          confidence -= 0.30;
        } else {
          confidence += 0.05;
        }
      }
      if (best == null || confidence > best!.confidence) {
        best = (value: cleaned, confidence: confidence.clamp(0.0, 1.0), raw: raw);
      }
    }

    final match = _findLabel(lines, template.registrationLabels);
    if (match != null) {
      final labelPenalty = (1 - match.score) * 0.5;

      for (final token in match.remainder.split(RegExp(r'\s+'))) {
        consider(token, 0.93 - labelPenalty, match.remainder);
      }
      if (best == null) {
        for (final line in _linesOnRow(lines, match.line)) {
          for (final token in line.text.split(RegExp(r'\s+'))) {
            consider(token, 0.85 - labelPenalty, line.text);
          }
        }
      }
      if (best == null) {
        for (final line in _linesBelow(lines, match.line).take(2)) {
          for (final token in line.text.split(RegExp(r'\s+'))) {
            consider(token, 0.72 - labelPenalty, line.text);
          }
        }
      }
    }

    // Last resort: any token anywhere that looks like a registration number.
    // Low confidence, so the review screen will always flag it.
    if (best == null) {
      for (final line in lines) {
        for (final token in line.text.split(RegExp(r'\s+'))) {
          consider(token, 0.45, line.text);
        }
      }
    }

    if (best == null) return _Candidate.none;
    return _Candidate(best!.value, best!.confidence, best!.raw);
  }

  /// Lines sharing a horizontal band with [anchor], left to right.
  List<_Line> _linesOnRow(List<_Line> lines, _Line anchor) {
    final tolerance = anchor.box.height * 0.6;
    final centre = anchor.box.center.dy;
    final result = lines
        .where((l) => l != anchor && (l.box.center.dy - centre).abs() <= tolerance)
        .toList()
      ..sort((a, b) => a.box.left.compareTo(b.box.left));
    return result;
  }

  /// Lines starting below [anchor] that overlap it horizontally, nearest first.
  List<_Line> _linesBelow(List<_Line> lines, _Line anchor) {
    final result = lines.where((l) {
      if (l == anchor) return false;
      if (l.box.top < anchor.box.bottom - anchor.box.height * 0.3) return false;
      final overlap = (l.box.right < anchor.box.left || l.box.left > anchor.box.right);
      return !overlap;
    }).toList()
      ..sort((a, b) => a.box.top.compareTo(b.box.top));
    return result;
  }
}

class _Line {
  const _Line(this.text, this.box);

  final String text;
  final Rect box;
}
