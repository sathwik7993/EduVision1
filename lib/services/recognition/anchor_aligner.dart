import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../../models/sheet_template.dart';
import 'page_aligner.dart';
import 'text_normalizer.dart';

/// A printed text line found on an image: its text and corner points (TL,
/// TR, BR, BL) in image pixels.
class TextLineHit {
  const TextLineHit(this.text, this.corners);

  final String text;
  final List<Offset> corners;

  Offset get centre => Offset(
        corners.fold(0.0, (s, c) => s + c.dx) / 4,
        corners.fold(0.0, (s, c) => s + c.dy) / 4,
      );
}

/// Reads printed text lines. Behind an interface so alignment logic is
/// testable without ML Kit.
abstract interface class TextLineReader {
  Future<List<TextLineHit>> read(GrayImage image);

  Future<void> close();
}

/// ML Kit's on-device Latin model, fed the already-decoded grayscale page.
///
/// The gray bytes are passed as the Y plane of an NV21 frame with neutral
/// chroma, so ML Kit works in exactly the pixel space the field crops are
/// cut from -- no second JPEG decode, no EXIF or scale bookkeeping.
class MlKitLineReader implements TextLineReader {
  final TextRecognizer _recognizer =
      TextRecognizer(script: TextRecognitionScript.latin);

  @override
  Future<List<TextLineHit>> read(GrayImage image) async {
    final w = image.width & ~1, h = image.height & ~1; // NV21 needs even sizes
    final nv21 = Uint8List(w * h + w * h ~/ 2)..fillRange(w * h, w * h + w * h ~/ 2, 128);
    for (var y = 0; y < h; y++) {
      nv21.setRange(y * w, y * w + w, image.pixels, y * image.width);
    }
    final recognized = await _recognizer.processImage(
      InputImage.fromBytes(
        bytes: nv21,
        metadata: InputImageMetadata(
          size: Size(w.toDouble(), h.toDouble()),
          rotation: InputImageRotation.rotation0deg,
          format: InputImageFormat.nv21,
          bytesPerRow: w,
        ),
      ),
    );
    return [
      for (final block in recognized.blocks)
        for (final line in block.lines)
          if (line.cornerPoints.length == 4)
            TextLineHit(line.text, [
              for (final p in line.cornerPoints)
                Offset(p.x.toDouble(), p.y.toDouble()),
            ]),
    ];
  }

  @override
  Future<void> close() => _recognizer.close();
}

/// Registers a photo onto a template by matching printed text lines.
abstract final class AnchorAligner {
  static const maxAnchors = 40;

  /// Chooses anchors from the lines read on a deskewed sample page of size
  /// [width] x [height]: printed-looking lines whose text occurs once.
  static List<TemplateAnchor> pickAnchors(
    List<TextLineHit> lines,
    int width,
    int height,
  ) {
    final counts = <String, int>{};
    for (final l in lines) {
      final key = TextNormalizer.normalizeLabel(l.text);
      counts[key] = (counts[key] ?? 0) + 1;
    }
    final anchors = <TemplateAnchor>[];
    for (final l in lines) {
      final key = TextNormalizer.normalizeLabel(l.text);
      if (counts[key] != 1 || key.replaceAll(RegExp(r'[^a-z]'), '').length < 4) {
        continue;
      }
      anchors.add(TemplateAnchor(key, [
        for (final c in l.corners) Offset(c.dx / width, c.dy / height),
      ]));
    }
    // Keep a vertical spread: alignment needs anchors near the marks slip
    // too, not only the header.
    anchors.sort((a, b) => a.corners[0].dy.compareTo(b.corners[0].dy));
    if (anchors.length <= maxAnchors) return anchors;
    final step = anchors.length / maxAnchors;
    return [for (var i = 0; i < maxAnchors; i++) anchors[(i * step).floor()]];
  }

  /// Homography from template page coordinates to photo pixels, or null when
  /// too few anchors agree (then the caller falls back to corner detection).
  static PageHomography? align(
    List<TemplateAnchor> anchors,
    List<TextLineHit> photoLines,
  ) {
    final byText = {for (final a in anchors) a.text: a};
    final seen = <String, int>{};
    for (final l in photoLines) {
      final key = TextNormalizer.normalizeLabel(l.text);
      seen[key] = (seen[key] ?? 0) + 1;
    }
    final pairs = <(TemplateAnchor, TextLineHit)>[];
    for (final l in photoLines) {
      final key = TextNormalizer.normalizeLabel(l.text);
      final a = byText[key];
      if (a != null && seen[key] == 1) pairs.add((a, l));
    }
    if (pairs.length < 4) return null;

    // RANSAC over triples of lines (12 point pairs each). A wrong match --
    // the same word printed elsewhere, a misread -- is voted out.
    final diag = _diagonal(photoLines);
    final tolerance = diag * 0.015;
    final rng = math.Random(7);
    var best = <int>[];
    final trials = math.min(300, pairs.length * pairs.length * pairs.length);
    for (var t = 0; t < trials; t++) {
      final pick = <int>{};
      while (pick.length < 3) {
        pick.add(rng.nextInt(pairs.length));
      }
      final h = _fitPairs([for (final i in pick) pairs[i]]);
      if (h == null) continue;
      final inliers = [
        for (var i = 0; i < pairs.length; i++)
          if (_error(h, pairs[i]) < tolerance) i,
      ];
      if (inliers.length > best.length) best = inliers;
    }
    if (best.length < 4) return null;

    // The inliers must span the page; four anchors in one header row would
    // extrapolate badly down to the marks slip.
    final ys = best.map((i) => pairs[i].$1.corners[0].dy);
    final xs = best.expand((i) => pairs[i].$1.corners.map((c) => c.dx));
    if (ys.reduce(math.max) - ys.reduce(math.min) < 0.3 ||
        xs.reduce(math.max) - xs.reduce(math.min) < 0.3) {
      return null;
    }
    return _fitPairs([for (final i in best) pairs[i]]);
  }

  static PageHomography? _fitPairs(List<(TemplateAnchor, TextLineHit)> pairs) {
    return PageHomography.fit(
      [for (final (a, _) in pairs) ...a.corners],
      [for (final (_, l) in pairs) ...l.corners],
    );
  }

  static double _error(PageHomography h, (TemplateAnchor, TextLineHit) pair) {
    final (a, l) = pair;
    final c = Offset(
      a.corners.fold(0.0, (s, p) => s + p.dx) / 4,
      a.corners.fold(0.0, (s, p) => s + p.dy) / 4,
    );
    return (h.map(c.dx, c.dy) - l.centre).distance;
  }

  static double _diagonal(List<TextLineHit> lines) {
    var maxX = 1.0, maxY = 1.0;
    for (final l in lines) {
      for (final c in l.corners) {
        maxX = math.max(maxX, c.dx);
        maxY = math.max(maxY, c.dy);
      }
    }
    return math.sqrt(maxX * maxX + maxY * maxY);
  }
}
