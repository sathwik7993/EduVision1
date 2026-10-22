import 'dart:math' as math;
import 'dart:typed_data';

import 'page_aligner.dart';

/// Model input for one field crop: float32 [1, 1, 32, width].
class ModelInput {
  const ModelInput(this.data, this.width);

  final Float32List data;
  final int width;

  static const height = 32;
}

/// Turns a grayscale field crop into the field model's input.
///
/// This is a contract with `prep()` in
/// training/recognizer/eduvision_recognizer.py: resize to height 32 keeping
/// aspect (area interpolation when shrinking, like OpenCV's INTER_AREA),
/// invert so ink is high, min-max stretch, pad width to a multiple of 4.
/// test/crop_preprocessor_test.dart checks it against Python output.
abstract final class CropPreprocessor {
  static const minWidth = 16;
  static const maxWidth = 512;

  static ModelInput prepare(GrayImage crop) {
    const h = ModelInput.height;
    final w = (crop.width * h / math.max(crop.height, 1))
        .round()
        .clamp(minWidth, maxWidth);
    final resized = (w <= crop.width && h <= crop.height)
        ? _resizeArea(crop, w, h)
        : _resizeLinear(crop, w, h);

    var lo = double.infinity, hi = -double.infinity;
    for (var i = 0; i < resized.length; i++) {
      final v = 1.0 - resized[i] / 255.0;
      resized[i] = v;
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    final range = hi - lo + 1e-3;

    final padded = w + ((4 - w % 4) % 4);
    final out = Float32List(h * padded);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        out[y * padded + x] = (resized[y * w + x] - lo) / range;
      }
    }
    return ModelInput(out, padded);
  }

  /// Exact-overlap box filter: each output pixel is the area-weighted mean of
  /// the source pixels it covers.
  static Float32List _resizeArea(GrayImage src, int outW, int outH) {
    final xs = _weights(src.width, outW);
    final ys = _weights(src.height, outH);
    final out = Float32List(outW * outH);
    for (var y = 0; y < outH; y++) {
      for (var x = 0; x < outW; x++) {
        var acc = 0.0, total = 0.0;
        for (final (sy, wy) in ys[y]) {
          for (final (sx, wx) in xs[x]) {
            final w = wx * wy;
            acc += src.at(sx, sy) * w;
            total += w;
          }
        }
        out[y * outW + x] = acc / total;
      }
    }
    return out;
  }

  static List<List<(int, double)>> _weights(int inSize, int outSize) {
    final scale = inSize / outSize;
    return List.generate(outSize, (o) {
      final start = o * scale, end = (o + 1) * scale;
      final taps = <(int, double)>[];
      for (var s = start.floor(); s < end.ceil() && s < inSize; s++) {
        final overlap = math.min(end, s + 1.0) - math.max(start, s.toDouble());
        if (overlap > 1e-6) taps.add((s, overlap));
      }
      return taps;
    });
  }

  /// Half-pixel-centred bilinear, matching OpenCV's INTER_LINEAR.
  static Float32List _resizeLinear(GrayImage src, int outW, int outH) {
    final out = Float32List(outW * outH);
    final sx = src.width / outW, sy = src.height / outH;
    for (var y = 0; y < outH; y++) {
      final fy = (y + 0.5) * sy - 0.5;
      for (var x = 0; x < outW; x++) {
        out[y * outW + x] = src.sample((x + 0.5) * sx - 0.5, fy);
      }
    }
    return out;
  }
}
