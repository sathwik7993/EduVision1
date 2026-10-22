import 'dart:math' as math;
import 'dart:ui';

import '../../models/sheet_template.dart';
import 'anchor_aligner.dart';

/// Finds the handwritten fields on a photo from the printed labels next to
/// them, so a sheet can be read without a hand-drawn template.
///
/// Each box is placed relative to its label in units of the label's own size,
/// which keeps it right on cropped, zoomed or low-resolution photos. The
/// offsets come from the CAT answer-book layout in `sample_images/`: on those
/// 9 photos every field was found and 30/34 were read right with the v4
/// model (training/real_eval, docs/PROGRESS.md). A layout with other wording
/// finds nothing here and needs a template drawn in the editor.
abstract final class FieldLocator {
  /// Normalised boxes (0..1 of [width] x [height]) for the fields found.
  static List<TemplateField> locate(
    List<TextLineHit> lines,
    int width,
    int height,
  ) {
    final labels = [
      for (final l in lines) (key: _key(l.text), box: _bounds(l.corners)),
    ];

    // Shortest matching line first: "Registered No." beats the instructions
    // sentence that mentions the registered number.
    ({String key, Rect box})? find(bool Function(String key) test) {
      final hits = labels.where((l) => test(l.key)).toList()
        ..sort((a, b) {
          final byLength = a.key.length.compareTo(b.key.length);
          return byLength != 0 ? byLength : a.box.top.compareTo(b.box.top);
        });
      return hits.isEmpty ? null : hits.first;
    }

    final fields = <TemplateField>[];
    void add(FieldKind kind, Rect box) {
      fields.add(TemplateField(
        kind: kind,
        box: Rect.fromLTRB(
          box.left / width,
          box.top / height,
          box.right / width,
          box.bottom / height,
        ),
      ));
    }

    // The number is written on the same row, right of the label.
    if (find((k) => k.startsWith('registeredno')) case final reg?) {
      final b = reg.box, c = b.center.dy;
      add(
        FieldKind.registration,
        Rect.fromLTRB(
            b.right, c - 0.9 * b.height, b.right + 2.9 * b.width, c + 0.7 * b.height),
      );
    }

    // Part totals are written in the cell under their label.
    for (final (key, kind) in const [
      ('partatotal', FieldKind.partA),
      ('partbtotal', FieldKind.partB),
    ]) {
      final hit = find((k) => k.startsWith(key) && k.length <= key.length + 3);
      if (hit == null) continue;
      final b = hit.box;
      add(
        kind,
        Rect.fromLTRB(b.left - 0.1 * b.width, b.bottom, b.right + 0.05 * b.width,
            b.bottom + 2.6 * b.height),
      );
    }

    // "GRAND" over "TOTAL" left of the cell; the grand total is only ever a
    // cross-check against Part-A + Part-B.
    if (find((k) => k == 'grand' || k == 'grandtotal') case final grand?) {
      var b = grand.box;
      for (final l in labels) {
        final below = l.box.top >= b.top && l.box.top - b.bottom < b.height;
        final overlaps = math.min(l.box.right, b.right) > math.max(l.box.left, b.left);
        if (l.key == 'total' && below && overlaps) b = b.expandToInclude(l.box);
      }
      add(
        FieldKind.writtenTotal,
        Rect.fromLTRB(b.right + 0.35 * b.width, b.top - 0.35 * b.height,
            b.right + 2.2 * b.width, b.bottom + 0.35 * b.height),
      );
    }
    return fields;
  }

  static String _key(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  static Rect _bounds(List<Offset> corners) => Rect.fromLTRB(
        corners.map((c) => c.dx).reduce(math.min),
        corners.map((c) => c.dy).reduce(math.min),
        corners.map((c) => c.dx).reduce(math.max),
        corners.map((c) => c.dy).reduce(math.max),
      );
}
