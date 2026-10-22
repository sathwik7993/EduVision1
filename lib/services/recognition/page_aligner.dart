import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

/// 8-bit grayscale image, row-major. Small and isolate-friendly: the whole
/// geometry pipeline runs on this rather than on `package:image` objects.
class GrayImage {
  GrayImage(this.width, this.height, [Uint8List? pixels])
      : pixels = pixels ?? Uint8List(width * height);

  final int width;
  final int height;
  final Uint8List pixels;

  int at(int x, int y) => pixels[y * width + x];

  /// From RGBA bytes (as produced by `ui.Image.toByteData`). Uses the same
  /// luma weights as OpenCV's `COLOR_RGB2GRAY`, which the training data used.
  factory GrayImage.fromRgba(Uint8List rgba, int width, int height) {
    final out = Uint8List(width * height);
    for (var i = 0, p = 0; i < out.length; i++, p += 4) {
      out[i] = (rgba[p] * 299 + rgba[p + 1] * 587 + rgba[p + 2] * 114) ~/ 1000;
    }
    return GrayImage(width, height, out);
  }

  /// Bilinear sample with edge clamping.
  double sample(double x, double y) {
    final cx = x.clamp(0.0, width - 1.0);
    final cy = y.clamp(0.0, height - 1.0);
    final x0 = cx.floor();
    final y0 = cy.floor();
    final x1 = math.min(x0 + 1, width - 1);
    final y1 = math.min(y0 + 1, height - 1);
    final fx = cx - x0;
    final fy = cy - y0;
    final top = at(x0, y0) * (1 - fx) + at(x1, y0) * fx;
    final bottom = at(x0, y1) * (1 - fx) + at(x1, y1) * fx;
    return top * (1 - fy) + bottom * fy;
  }
}

/// Maps normalised page coordinates (u, v in 0..1) to source-image pixels.
///
/// Built from the four page corners (Heckbert's square-to-quad mapping), so a
/// template box drawn on one deskewed sample lands on the same paper region
/// in any later photo of the same layout.
class PageHomography {
  PageHomography._(this._a, this._b, this._c, this._d, this._e, this._f,
      this._g, this._h);

  /// Corners in order: top-left, top-right, bottom-right, bottom-left.
  factory PageHomography.fromCorners(List<Offset> corners) {
    final x0 = corners[0].dx, y0 = corners[0].dy;
    final x1 = corners[1].dx, y1 = corners[1].dy;
    final x2 = corners[2].dx, y2 = corners[2].dy;
    final x3 = corners[3].dx, y3 = corners[3].dy;

    final dx3 = x0 - x1 + x2 - x3;
    final dy3 = y0 - y1 + y2 - y3;
    if (dx3.abs() < 1e-9 && dy3.abs() < 1e-9) {
      return PageHomography._(x1 - x0, x2 - x1, x0, y1 - y0, y2 - y1, y0, 0, 0);
    }
    final dx1 = x1 - x2, dx2 = x3 - x2;
    final dy1 = y1 - y2, dy2 = y3 - y2;
    final det = dx1 * dy2 - dx2 * dy1;
    final g = (dx3 * dy2 - dx2 * dy3) / det;
    final h = (dx1 * dy3 - dx3 * dy1) / det;
    return PageHomography._(
      x1 - x0 + g * x1,
      x3 - x0 + h * x3,
      x0,
      y1 - y0 + g * y1,
      y3 - y0 + h * y3,
      y0,
      g,
      h,
    );
  }

  /// The whole image is the page (already cropped, e.g. by the document
  /// scanner).
  factory PageHomography.identity(int width, int height) =>
      PageHomography.fromCorners([
        Offset.zero,
        Offset(width.toDouble(), 0),
        Offset(width.toDouble(), height.toDouble()),
        Offset(0, height.toDouble()),
      ]);

  final double _a, _b, _c, _d, _e, _f, _g, _h;

  Offset map(double u, double v) {
    final w = _g * u + _h * v + 1;
    return Offset((_a * u + _b * v + _c) / w, (_d * u + _e * v + _f) / w);
  }
}

/// Page detection and region sampling, in pure Dart.
///
/// The ML Kit document scanner already returns a flat, cropped page; this is
/// the fallback for the in-app camera and gallery imports, and for devices
/// without Play services. Pure Dart rather than OpenCV keeps the APK small,
/// and only the template regions are resampled, never the whole 12MP frame.
abstract final class PageAligner {
  /// Detection runs on a thumbnail; paper-vs-desk does not need detail.
  static const _detectEdge = 320;

  /// Finds the sheet as the largest bright region and returns its corners
  /// (TL, TR, BR, BL) in [image] pixels, or null when no clear page boundary
  /// exists -- either no paper found, or the paper already fills the frame.
  static List<Offset>? detectPage(GrayImage image) {
    final scale = math.max(image.width, image.height) / _detectEdge;
    final step = math.max(1.0, scale);
    final w = (image.width / step).floor();
    final h = (image.height / step).floor();
    if (w < 8 || h < 8) return null;

    // Box-average down-sample.
    final small = Uint8List(w * h);
    final block = step.ceil();
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final sx = (x * step).floor(), sy = (y * step).floor();
        var sum = 0, n = 0;
        for (var dy = 0; dy < block && sy + dy < image.height; dy++) {
          for (var dx = 0; dx < block && sx + dx < image.width; dx++) {
            sum += image.at(sx + dx, sy + dy);
            n++;
          }
        }
        small[y * w + x] = sum ~/ n;
      }
    }

    final threshold = _otsu(small);
    final mask = Uint8List(w * h);
    for (var i = 0; i < mask.length; i++) {
      mask[i] = small[i] > threshold ? 1 : 0;
    }

    // Largest 4-connected bright component.
    final labels = Int32List(w * h);
    var bestLabel = 0, bestSize = 0, next = 0;
    final stack = <int>[];
    for (var i = 0; i < mask.length; i++) {
      if (mask[i] == 0 || labels[i] != 0) continue;
      next++;
      var size = 0;
      stack.add(i);
      labels[i] = next;
      while (stack.isNotEmpty) {
        final p = stack.removeLast();
        size++;
        final px = p % w, py = p ~/ w;
        void visit(int q) {
          if (mask[q] == 1 && labels[q] == 0) {
            labels[q] = next;
            stack.add(q);
          }
        }

        if (px > 0) visit(p - 1);
        if (px < w - 1) visit(p + 1);
        if (py > 0) visit(p - w);
        if (py < h - 1) visit(p + w);
      }
      if (size > bestSize) {
        bestSize = size;
        bestLabel = next;
      }
    }

    final fraction = bestSize / (w * h);
    if (fraction < 0.15 || fraction > 0.92) return null;

    // Extreme points along the diagonals are the corners of a roughly
    // upright quadrilateral. Text inside the page is a hole in the component
    // and does not move them.
    var tl = 0, br = 0, tr = 0, bl = 0;
    var minSum = 1 << 30, maxSum = -1, maxDiff = -(1 << 30), minDiff = 1 << 30;
    for (var i = 0; i < labels.length; i++) {
      if (labels[i] != bestLabel) continue;
      final x = i % w, y = i ~/ w;
      final s = x + y, d = x - y;
      if (s < minSum) (minSum, tl) = (s, i);
      if (s > maxSum) (maxSum, br) = (s, i);
      if (d > maxDiff) (maxDiff, tr) = (d, i);
      if (d < minDiff) (minDiff, bl) = (d, i);
    }

    Offset back(int i) =>
        Offset(((i % w) + 0.5) * step, ((i ~/ w) + 0.5) * step);
    final corners = [back(tl), back(tr), back(br), back(bl)];

    // Reject degenerate quads (e.g. a page rotated ~45 degrees, where the
    // diagonal extremes collapse onto the same side).
    if (_area(corners) < bestSize * step * step * 0.6) return null;
    return corners;
  }

  /// Samples [box] (normalised page coordinates) into an upright crop.
  ///
  /// Output resolution follows the source: a field that spans 40 px in the
  /// photo is sampled at about 40 px, capped at [maxHeight] so a close-up
  /// does not waste time on detail the 32 px model input throws away.
  static GrayImage sampleRegion(
    GrayImage source,
    PageHomography page,
    Rect box, {
    int maxHeight = 96,
    int? width,
  }) {
    final tl = page.map(box.left, box.top);
    final tr = page.map(box.right, box.top);
    final bl = page.map(box.left, box.bottom);
    final br = page.map(box.right, box.bottom);
    var outW = width ?? (((tr - tl).distance + (br - bl).distance) / 2).round();
    var outH = width != null
        ? (outW * (((bl - tl).distance + (br - tr).distance) /
                    ((tr - tl).distance + (br - bl).distance)))
            .round()
        : (((bl - tl).distance + (br - tr).distance) / 2).round();
    if (width == null && outH > maxHeight) {
      outW = (outW * maxHeight / outH).round();
      outH = maxHeight;
    }
    outW = math.max(outW, 4);
    outH = math.max(outH, 4);

    final out = GrayImage(outW, outH);
    for (var j = 0; j < outH; j++) {
      final v = box.top + (j + 0.5) / outH * box.height;
      for (var i = 0; i < outW; i++) {
        final u = box.left + (i + 0.5) / outW * box.width;
        final p = page.map(u, v);
        out.pixels[j * outW + i] = source.sample(p.dx - 0.5, p.dy - 0.5).round();
      }
    }
    return out;
  }

  /// Grows a box by [fraction] of its size on each side, clamped to the page.
  /// Absorbs the small misalignment left after deskew.
  static Rect pad(Rect box, [double fraction = 0.06]) {
    final dx = box.width * fraction, dy = box.height * fraction;
    return Rect.fromLTRB(
      math.max(0, box.left - dx),
      math.max(0, box.top - dy),
      math.min(1, box.right + dx),
      math.min(1, box.bottom + dy),
    );
  }

  static int _otsu(Uint8List pixels) {
    final hist = List<int>.filled(256, 0);
    for (final p in pixels) {
      hist[p]++;
    }
    final total = pixels.length;
    var sumAll = 0.0;
    for (var i = 0; i < 256; i++) {
      sumAll += i * hist[i];
    }
    var sumB = 0.0, wB = 0, best = 0.0, threshold = 127;
    for (var t = 0; t < 256; t++) {
      wB += hist[t];
      if (wB == 0) continue;
      final wF = total - wB;
      if (wF == 0) break;
      sumB += t * hist[t];
      final mB = sumB / wB, mF = (sumAll - sumB) / wF;
      final between = wB * wF * (mB - mF) * (mB - mF);
      if (between > best) {
        best = between;
        threshold = t;
      }
    }
    return threshold;
  }

  static double _area(List<Offset> q) {
    var a = 0.0;
    for (var i = 0; i < q.length; i++) {
      final p = q[i], n = q[(i + 1) % q.length];
      a += p.dx * n.dy - n.dx * p.dy;
    }
    return a.abs() / 2;
  }
}
