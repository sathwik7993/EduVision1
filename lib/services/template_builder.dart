import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../models/sheet_template.dart';
import 'recognition/anchor_aligner.dart';
import 'recognition/page_aligner.dart';
import 'recognition/page_loader.dart';

/// A sample sheet turned into the page space a template is drawn in.
class PreparedSample {
  const PreparedSample(this.imagePath, this.size, this.anchors);

  /// Deskewed page image the teacher draws boxes on.
  final String imagePath;
  final Size size;
  final List<TemplateAnchor> anchors;
}

/// Prepares a sample photo for the template editor: deskew it, store it
/// locally, and record the printed text lines later scans align against.
abstract final class TemplateBuilder {
  static const pageWidth = 1000;

  static Future<PreparedSample> prepare(
    String photoPath,
    String templateId, {
    TextLineReader? lines,
  }) async {
    final photo = await PageLoader.load(photoPath);
    final page = await Isolate.run(() => deskew(photo));

    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}${Platform.pathSeparator}templates');
    await folder.create(recursive: true);
    final path = '${folder.path}${Platform.pathSeparator}$templateId.jpg';
    final jpg = await Isolate.run(() => img.encodeJpg(
          img.Image.fromBytes(
            width: page.width,
            height: page.height,
            bytes: page.pixels.buffer,
            numChannels: 1,
          ),
          quality: 88,
        ));
    await File(path).writeAsBytes(jpg, flush: true);

    var anchors = const <TemplateAnchor>[];
    final reader = lines ?? MlKitLineReader();
    try {
      anchors = AnchorAligner.pickAnchors(
        await reader.read(page),
        page.width,
        page.height,
      );
    } on Exception {
      // Without anchors, scans fall back to page-corner alignment.
    } finally {
      if (lines == null) await reader.close();
    }
    return PreparedSample(
      path,
      Size(page.width.toDouble(), page.height.toDouble()),
      anchors,
    );
  }

  /// Flattens the photographed page to [pageWidth] pixels wide. When no page
  /// edge is found (the sheet fills the frame, or came from the document
  /// scanner) the frame itself is the page.
  static GrayImage deskew(GrayImage photo) {
    final corners = PageAligner.detectPage(photo);
    final homography = corners == null
        ? PageHomography.identity(photo.width, photo.height)
        : PageHomography.fromCorners(corners);
    final c = corners ??
        [
          Offset.zero,
          Offset(photo.width.toDouble(), 0),
          Offset(photo.width.toDouble(), photo.height.toDouble()),
          Offset(0, photo.height.toDouble()),
        ];
    final w = ((c[1] - c[0]).distance + (c[2] - c[3]).distance) / 2;
    final h = ((c[3] - c[0]).distance + (c[2] - c[1]).distance) / 2;
    return PageAligner.sampleRegion(
      photo,
      homography,
      const Rect.fromLTRB(0, 0, 1, 1),
      width: pageWidth,
      height: (pageWidth * h / w).round(),
    );
  }
}
