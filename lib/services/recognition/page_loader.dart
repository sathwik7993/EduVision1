import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'page_aligner.dart';

/// Decodes a photo to grayscale using the platform's native image decoder.
///
/// `package:image` decodes JPEG in pure Dart, which takes over a second for a
/// 12MP photo on an entry-level phone -- most of the 2 s budget. The engine's
/// decoder is native, honours EXIF orientation, and can downscale while
/// decoding.
abstract final class PageLoader {
  /// Enough for ~40 px tall handwritten marks on an A4 page; more only costs
  /// time.
  static const maxEdge = 2000;

  static Future<GrayImage> load(String path, {int maxEdge = maxEdge}) async {
    final bytes = await File(path).readAsBytes();
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final longest = math.max(descriptor.width, descriptor.height);
    // Only the width is constrained so the aspect ratio survives an EXIF
    // rotation (the descriptor reports pre-rotation dimensions).
    final codec = await descriptor.instantiateCodec(
      targetWidth: longest > maxEdge
          ? (descriptor.width * maxEdge / longest).round()
          : null,
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) throw const FormatException('Could not decode image');
      return GrayImage.fromRgba(
        data.buffer.asUint8List(),
        image.width,
        image.height,
      );
    } finally {
      image.dispose();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }
}
