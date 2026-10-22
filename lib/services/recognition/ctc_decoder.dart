import 'dart:typed_data';

/// Characters the field model emits; class i+1 is [charset][i], class 0 is
/// the CTC blank. Must match CHARSET in training/recognizer.
const fieldModelCharset = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
const digitCharset = '0123456789';

class CtcReading {
  const CtcReading(this.text, this.confidence);

  final String text;

  /// Minimum per-character probability -- one doubtful digit makes the whole
  /// mark doubtful, which a mean would hide.
  final double confidence;
}

/// Greedy CTC decoding restricted to the characters a field may contain.
///
/// Restricting the charset is the cheapest accuracy gain available: a mark
/// box can only hold digits, so an "S" vs "5" confusion simply cannot occur.
/// Probabilities are renormalised over the allowed classes before decoding.
abstract final class CtcDecoder {
  static CtcReading decode(
    Float32List probs,
    int frames,
    int classes, {
    String allowed = fieldModelCharset,
  }) {
    final keep = <int>[0];
    for (final ch in allowed.split('')) {
      final i = fieldModelCharset.indexOf(ch);
      if (i >= 0) keep.add(i + 1);
    }

    final text = StringBuffer();
    final confidences = <double>[];
    var prev = 0;
    var minBlank = 1.0;
    for (var t = 0; t < frames; t++) {
      final row = t * classes;
      var sum = 0.0;
      for (final k in keep) {
        sum += probs[row + k];
      }
      if (sum <= 0) sum = 1e-9;
      var best = 0;
      var bestP = -1.0;
      for (var j = 0; j < keep.length; j++) {
        final p = probs[row + keep[j]] / sum;
        if (p > bestP) {
          bestP = p;
          best = j;
        }
      }
      final blankP = probs[row] / sum;
      if (blankP < minBlank) minBlank = blankP;

      if (best != 0 && best != prev) {
        text.write(fieldModelCharset[keep[best] - 1]);
        confidences.add(bestP);
      } else if (best != 0 && best == prev && bestP > confidences.last) {
        confidences[confidences.length - 1] = bestP;
      }
      prev = best;
    }

    if (confidences.isEmpty) {
      // An empty box is only as trustworthy as its least certain blank frame.
      return CtcReading('', frames == 0 ? 0 : minBlank);
    }
    return CtcReading(
      text.toString(),
      confidences.reduce((a, b) => a < b ? a : b),
    );
  }
}
