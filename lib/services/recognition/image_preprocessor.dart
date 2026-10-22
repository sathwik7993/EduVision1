import 'dart:io';
import 'dart:isolate';

import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Which enhancement was applied to produce a candidate image.
enum PreprocessVariant {
  /// EXIF-baked and resized only. Best for clean, well-lit printed text.
  plain,

  /// Grayscale + histogram normalisation + contrast lift. Best for pen ink on
  /// off-white paper under classroom lighting.
  enhanced,

  /// High-contrast near-binary. Best for faint pencil, worst for shadows.
  binarized,
}

class PreprocessedImage {
  const PreprocessedImage({required this.path, required this.variant});

  final String path;
  final PreprocessVariant variant;
}

/// Offline image conditioning that runs before OCR.
///
/// The single biggest cheap accuracy win here is producing *several* variants
/// and OCRing each: a contrast curve that rescues faint pencil ruins a photo
/// with a shadow across it, and vice versa. The recognizer scores the results
/// and keeps the best, so we never have to guess which curve a given photo
/// needed.
abstract final class ImagePreprocessor {
  /// ML Kit gains nothing above roughly this resolution and gets noticeably
  /// slower, but going too low destroys thin pen strokes.
  static const _maxEdge = 2200;

  static Future<List<PreprocessedImage>> buildVariants(String sourcePath) async {
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;

    // Isolate.run keeps decode/resize/filter work off the UI isolate. Without
    // this, a 12MP photo freezes the preview for a second or more.
    return Isolate.run(() => _work(sourcePath, dir.path, stamp));
  }

  static List<PreprocessedImage> _work(
    String sourcePath,
    String tempDir,
    int stamp,
  ) {
    final decoded = img.decodeImage(File(sourcePath).readAsBytesSync());
    if (decoded == null) {
      return [PreprocessedImage(path: sourcePath, variant: PreprocessVariant.plain)];
    }

    // Cameras record rotation in EXIF rather than rotating pixels. Re-encoding
    // without baking it in would hand OCR a sideways page.
    var base = img.bakeOrientation(decoded);

    final longEdge = base.width > base.height ? base.width : base.height;
    if (longEdge > _maxEdge) {
      final scale = _maxEdge / longEdge;
      base = img.copyResize(
        base,
        width: (base.width * scale).round(),
        height: (base.height * scale).round(),
        interpolation: img.Interpolation.cubic,
      );
    }

    final out = <PreprocessedImage>[];

    String write(img.Image image, PreprocessVariant variant) {
      final path = '$tempDir${Platform.pathSeparator}scan_${stamp}_${variant.name}.jpg';
      File(path).writeAsBytesSync(img.encodeJpg(image, quality: 92));
      return path;
    }

    out.add(
      PreprocessedImage(
        path: write(base, PreprocessVariant.plain),
        variant: PreprocessVariant.plain,
      ),
    );

    // Enhanced: flatten to luminance, stretch the histogram so paper goes to
    // true white and ink to true black, then a modest contrast lift.
    final enhanced = img.adjustColor(
      img.normalize(img.grayscale(base.clone()), min: 0, max: 255),
      contrast: 1.35,
      brightness: 1.04,
    );
    out.add(
      PreprocessedImage(
        path: write(enhanced, PreprocessVariant.enhanced),
        variant: PreprocessVariant.enhanced,
      ),
    );

    // Binarized: aggressive curve for faint pencil. Not a hard threshold --
    // a true 1-bit image throws away the stroke antialiasing that ML Kit's
    // character classifier relies on.
    final binarized = img.adjustColor(
      img.normalize(img.grayscale(base.clone()), min: 0, max: 255),
      contrast: 2.6,
      brightness: 1.10,
    );
    out.add(
      PreprocessedImage(
        path: write(binarized, PreprocessVariant.binarized),
        variant: PreprocessVariant.binarized,
      ),
    );

    return out;
  }

  /// Rotate a capture by 90 degree steps, for the manual "rotate" control on
  /// the review screen.
  static Future<String> rotate(String path, int quarterTurns) async {
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return Isolate.run(() {
      final decoded = img.decodeImage(File(path).readAsBytesSync());
      if (decoded == null) return path;
      final rotated = img.copyRotate(decoded, angle: 90.0 * quarterTurns);
      final out = '${dir.path}${Platform.pathSeparator}rot_$stamp.jpg';
      File(out).writeAsBytesSync(img.encodeJpg(rotated, quality: 92));
      return out;
    });
  }

  /// Best-effort cleanup of the temp variants once a scan is committed.
  static Future<void> discard(Iterable<String> paths) async {
    for (final path in paths) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // Temp dir is reclaimed by the OS anyway.
      }
    }
  }
}
