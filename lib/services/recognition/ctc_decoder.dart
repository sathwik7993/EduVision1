import 'dart:math' as math;
import 'dart:typed_data';

/// Characters the field model emits; class i+1 is [charset][i], class 0 is
/// the CTC blank. Must match CHARSET in training/recognizer.
const fieldModelCharset = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
const digitCharset = '0123456789';
const letterCharset = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';

class CtcReading {
  const CtcReading(this.text, this.confidence, [this.spans = const []]);

  final String text;

  /// Minimum per-character probability -- one doubtful digit makes the whole
  /// mark doubtful, which a mean would hide.
  final double confidence;

  /// Frames that produced each character, for positional re-decoding.
  final List<List<int>> spans;
}

/// Greedy CTC decoding restricted to the characters a field may contain.
///
/// Restricting the charset is the cheapest accuracy gain available: a mark
/// box can only hold digits, so an "S" vs "5" confusion simply cannot occur.
///
/// Confidence uses the model's raw probability, deliberately not renormalised
/// over the allowed classes: if the model put 60% on "S", the "5" chosen in
/// its place is only 35% certain, and that doubt must reach the review gate.
abstract final class CtcDecoder {
  static CtcReading decode(
    Float32List probs,
    int frames,
    int classes, {
    String allowed = fieldModelCharset,
  }) {
    final keep = _classes(allowed);
    final allowedSet = keep.toSet();

    final text = StringBuffer();
    final confidences = <double>[];
    final spans = <List<int>>[];
    var prev = 0;
    var minBlank = 1.0;
    // Strongest evidence for a character the field cannot hold. If the model
    // was sure of an "S" somewhere, dropping it must not leave a confident
    // reading behind.
    var dropped = 0.0;
    for (var t = 0; t < frames; t++) {
      final row = t * classes;
      var best = 0;
      var bestP = -1.0;
      for (var j = 0; j < keep.length; j++) {
        final p = probs[row + keep[j]];
        if (p > bestP) {
          bestP = p;
          best = j;
        }
      }
      final blankP = probs[row];
      if (blankP < minBlank) minBlank = blankP;
      for (var c = 1; c < classes; c++) {
        final p = probs[row + c];
        if (p > dropped && p > bestP && !allowedSet.contains(c)) dropped = p;
      }

      if (best != 0 && best != prev) {
        text.write(fieldModelCharset[keep[best] - 1]);
        confidences.add(bestP);
        spans.add([t]);
      } else if (best != 0 && best == prev) {
        spans.last.add(t);
        if (bestP > confidences.last) confidences[confidences.length - 1] = bestP;
      }
      prev = best;
    }

    if (confidences.isEmpty) {
      // An empty box is only as trustworthy as its least certain blank frame.
      return CtcReading('', frames == 0 ? 0 : math.min(minBlank, 1 - dropped));
    }
    return CtcReading(
      text.toString(),
      math.min(confidences.reduce(math.min), 1 - dropped),
      spans,
    );
  }

  /// Decodes a registration number against a positional [mask] (D digit,
  /// A letter, X either). When the model found exactly one character per
  /// mask position, each position is re-chosen from its allowed class using
  /// the same frames -- "23H51A66D9" with an "8" read where a letter must be
  /// becomes the best letter for those frames, at that letter's (lower)
  /// probability. Otherwise the plain reading is returned for validation to
  /// flag as incomplete.
  static CtcReading decodeMasked(
    Float32List probs,
    int frames,
    int classes,
    String mask,
  ) {
    final plain = decode(probs, frames, classes);
    if (plain.text.length != mask.length) return plain;

    final text = StringBuffer();
    var confidence = 1.0;
    for (var i = 0; i < mask.length; i++) {
      final allowed = switch (mask[i].toUpperCase()) {
        'D' => digitCharset,
        'A' => letterCharset,
        _ => fieldModelCharset,
      };
      final keep = _classes(allowed);
      var bestChar = plain.text[i];
      var bestP = -1.0;
      for (final t in plain.spans[i]) {
        final row = t * classes;
        for (var j = 1; j < keep.length; j++) {
          final p = probs[row + keep[j]];
          if (p > bestP) {
            bestP = p;
            bestChar = fieldModelCharset[keep[j] - 1];
          }
        }
      }
      text.write(bestChar);
      if (bestP < confidence) confidence = bestP;
    }
    return CtcReading(text.toString(), confidence, plain.spans);
  }

  static List<int> _classes(String allowed) => [
        0,
        for (final ch in allowed.split(''))
          if (fieldModelCharset.contains(ch)) fieldModelCharset.indexOf(ch) + 1,
      ];
}
