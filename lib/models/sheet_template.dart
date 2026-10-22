import 'dart:ui';

/// What a template box contains.
enum FieldKind {
  registration('Registration No'),
  partA('Part-A total'),
  partB('Part-B total'),
  question('Question mark'),

  /// A total the examiner wrote (grand-total cell, "total in words" line).
  /// Never used as the total -- only cross-checked against Part-A + Part-B.
  writtenTotal('Written grand total');

  const FieldKind(this.label);
  final String label;
}

/// One box the teacher drew on a sample sheet.
///
/// [box] is normalised to the deskewed page (0..1 on both axes), so the same
/// template works for any camera resolution and any page crop.
class TemplateField {
  const TemplateField({
    required this.kind,
    required this.box,
    this.label = '',
    this.part = 'A',
    this.maxMarks,
  });

  final FieldKind kind;
  final Rect box;

  /// Question label ("Q1", "3b"); empty for the other kinds.
  final String label;

  /// Which part a question belongs to: 'A' or 'B'.
  final String part;

  /// Per-question maximum, when known.
  final int? maxMarks;

  /// Short display name for lists and review rows.
  String get title => switch (kind) {
        FieldKind.question =>
          '${label.isEmpty ? 'Question' : label} (Part-$part)',
        FieldKind.writtenTotal when label.isNotEmpty => label,
        _ => kind.label,
      };

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'box': [box.left, box.top, box.right, box.bottom],
        'label': label,
        'part': part,
        'maxMarks': maxMarks,
      };

  factory TemplateField.fromJson(Map<String, Object?> json) {
    final b = (json['box']! as List).cast<num>();
    return TemplateField(
      kind: FieldKind.values.byName(json['kind']! as String),
      box: Rect.fromLTRB(
        b[0].toDouble(),
        b[1].toDouble(),
        b[2].toDouble(),
        b[3].toDouble(),
      ),
      label: (json['label'] as String?) ?? '',
      part: (json['part'] as String?) ?? 'A',
      maxMarks: (json['maxMarks'] as num?)?.toInt(),
    );
  }
}

/// A line of printed text on the sample sheet ("Part-A Total", "GRAND
/// TOTAL"), used to register later photos onto the template.
///
/// Printed labels are what ML Kit reads reliably, and matching them by content
/// works even when a photo cuts off the page edges, which defeats corner
/// detection.
class TemplateAnchor {
  const TemplateAnchor(this.text, this.corners);

  /// Normalised with TextNormalizer.normalizeLabel.
  final String text;

  /// TL, TR, BR, BL in normalised page coordinates.
  final List<Offset> corners;

  Map<String, Object?> toJson() => {
        'text': text,
        'corners': [for (final c in corners) ...[c.dx, c.dy]],
      };

  factory TemplateAnchor.fromJson(Map<String, Object?> json) {
    final c = (json['corners']! as List).cast<num>();
    return TemplateAnchor(json['text']! as String, [
      for (var i = 0; i < 8; i += 2) Offset(c[i].toDouble(), c[i + 1].toDouble()),
    ]);
  }
}

/// Describes the exam sheet being scanned.
///
/// Extraction quality depends far more on knowing what to expect than on the
/// OCR engine itself: knowing Part-A is out of 40 lets us reject a misread "80"
/// outright, and knowing the registration format lets us repair confusable
/// characters positionally.
///
/// Layouts vary by college, so a template can also carry [fields]: boxes the
/// teacher drew once on a sample sheet. With boxes, the on-device handwriting
/// model reads each field directly; without them, the label-matching ML Kit
/// path is used.
class SheetTemplate {
  const SheetTemplate({
    this.id = 'default',
    this.name = 'Default',
    this.fields = const [],
    this.anchors = const [],
    this.sampleImagePath,
    this.registrationMask,
    this.registrationLabels = const [
      'registered no',
      'registration no',
      'reg no',
      'regd no',
      'roll no',
      'hall ticket',
      'hall ticket no',
      'student id',
    ],
    this.partALabels = const [
      'part-a total',
      'part a total',
      'parta total',
      'total part-a',
      'section a total',
      'part-a',
      'part a',
    ],
    this.partBLabels = const [
      'part-b total',
      'part b total',
      'partb total',
      'total part-b',
      'section b total',
      'part-b',
      'part b',
    ],
    this.partAMax = 40,
    this.partBMax = 60,
    this.registrationLength,
    this.registrationPattern,
  });

  final String id;
  final String name;
  final List<TemplateField> fields;
  final List<TemplateAnchor> anchors;

  /// The deskewed sample sheet the boxes were drawn on (app storage).
  final String? sampleImagePath;

  /// Character class per position of the registration number: D digit,
  /// A letter, X either -- e.g. "DDADDADDXX" for 23H51A66K1. Lets the decoder
  /// repair a letter read where a digit must be (and vice versa) from the
  /// model's own second choice, and flags an incomplete number.
  final String? registrationMask;

  final List<String> registrationLabels;
  final List<String> partALabels;
  final List<String> partBLabels;

  /// Used to reject impossible readings.
  final int partAMax;
  final int partBMax;

  /// Exact expected length of the registration number, when fixed. Enables
  /// positional character repair (e.g. a letter read where a digit belongs).
  final int? registrationLength;

  /// Overrides the default "6-15 alphanumeric with at least two digits" rule.
  final RegExp? registrationPattern;

  static const defaults = SheetTemplate();

  static final defaultRegistrationPattern =
      RegExp(r'^(?=.*\d.*\d)[A-Z0-9]{6,15}$');

  /// True when the teacher has drawn boxes, so the field model can be used.
  bool get hasBoxes => fields.isNotEmpty;

  SheetTemplate copyWith({
    String? id,
    String? name,
    List<TemplateField>? fields,
    int? partAMax,
    int? partBMax,
    int? registrationLength,
    RegExp? registrationPattern,
  }) {
    return SheetTemplate(
      id: id ?? this.id,
      name: name ?? this.name,
      fields: fields ?? this.fields,
      anchors: anchors,
      sampleImagePath: sampleImagePath,
      registrationMask: registrationMask,
      registrationLabels: registrationLabels,
      partALabels: partALabels,
      partBLabels: partBLabels,
      partAMax: partAMax ?? this.partAMax,
      partBMax: partBMax ?? this.partBMax,
      registrationLength: registrationLength ?? this.registrationLength,
      registrationPattern: registrationPattern ?? this.registrationPattern,
    );
  }

  /// Label synonyms are not persisted: they are app defaults, not something a
  /// teacher edits per college.
  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'fields': fields.map((f) => f.toJson()).toList(),
        'anchors': anchors.map((a) => a.toJson()).toList(),
        'sampleImagePath': sampleImagePath,
        'registrationMask': registrationMask,
        'partAMax': partAMax,
        'partBMax': partBMax,
        'registrationLength': registrationLength,
        'registrationPattern': registrationPattern?.pattern,
      };

  factory SheetTemplate.fromJson(Map<String, Object?> json) {
    final pattern = json['registrationPattern'] as String?;
    return SheetTemplate(
      id: json['id']! as String,
      name: json['name']! as String,
      fields: ((json['fields'] as List?) ?? const [])
          .map((f) => TemplateField.fromJson((f as Map).cast<String, Object?>()))
          .toList(),
      anchors: ((json['anchors'] as List?) ?? const [])
          .map((a) => TemplateAnchor.fromJson((a as Map).cast<String, Object?>()))
          .toList(),
      sampleImagePath: json['sampleImagePath'] as String?,
      registrationMask: json['registrationMask'] as String?,
      partAMax: (json['partAMax'] as num?)?.toInt() ?? 40,
      partBMax: (json['partBMax'] as num?)?.toInt() ?? 60,
      registrationLength: (json['registrationLength'] as num?)?.toInt(),
      registrationPattern:
          pattern == null || pattern.isEmpty ? null : RegExp(pattern),
    );
  }
}
