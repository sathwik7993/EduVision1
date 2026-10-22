import 'dart:io';

import 'package:eduvision_0_1/services/recognition/page_aligner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Page detection on the owner's real photos (sample_images/, private repo
/// only). Skipped when the folder is absent, e.g. in a public clone or CI.
void main() {
  final dir = Directory('sample_images');
  final photos = dir.existsSync()
      ? (dir.listSync().whereType<File>().where((f) => f.path.endsWith('.jpeg')).toList()
        ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];

  test('page-corner detection on the real sample photos', () {
    for (final f in photos) {
      final decoded = img.decodeJpg(f.readAsBytesSync())!;
      final gray = GrayImage.fromRgba(
        decoded.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba),
        decoded.width,
        decoded.height,
      );
      final corners = PageAligner.detectPage(gray);
      // Printed for docs/PROGRESS.md; whether a quad is found depends on the
      // photo, and anchors (not corners) are the primary alignment.
      // ignore: avoid_print
      print('${f.uri.pathSegments.last}: ${decoded.width}x${decoded.height} '
          '-> ${corners?.map((c) => '(${c.dx.round()},${c.dy.round()})').join(' ') ?? 'no page edge (whole frame used)'}');
    }
  }, skip: photos.isEmpty ? 'sample_images/ not present' : false);
}
