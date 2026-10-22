import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:image_picker/image_picker.dart';

import '../models/sheet_template.dart';
import '../services/template_builder.dart';
import '../services/template_store.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';

/// Draw the field boxes for one sheet layout, once, on a sample sheet.
class TemplateEditorPage extends StatefulWidget {
  const TemplateEditorPage({super.key, this.template});

  /// Null to create a new template.
  final SheetTemplate? template;

  @override
  State<TemplateEditorPage> createState() => _TemplateEditorPageState();
}

class _TemplateEditorPageState extends State<TemplateEditorPage> {
  late final String _id =
      widget.template?.id ?? 't${DateTime.now().millisecondsSinceEpoch}';
  late final _name = TextEditingController(text: widget.template?.name ?? '');
  late final _partAMax =
      TextEditingController(text: '${widget.template?.partAMax ?? 40}');
  late final _partBMax =
      TextEditingController(text: '${widget.template?.partBMax ?? 60}');
  late final _mask =
      TextEditingController(text: widget.template?.registrationMask ?? '');

  late List<TemplateField> _fields = [...?widget.template?.fields];
  late List<TemplateAnchor> _anchors = [...?widget.template?.anchors];
  late String? _imagePath = widget.template?.sampleImagePath;
  Size? _imageSize;

  bool _preparing = false;
  bool _drawMode = true;
  Offset? _dragStart;
  Rect? _dragRect;

  @override
  void initState() {
    super.initState();
    _readImageSize();
  }

  @override
  void dispose() {
    for (final c in [_name, _partAMax, _partBMax, _mask]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _readImageSize() async {
    final path = _imagePath;
    if (path == null || !File(path).existsSync()) return;
    final image = await decodeImageFromList(await File(path).readAsBytes());
    if (!mounted) return;
    setState(() =>
        _imageSize = Size(image.width.toDouble(), image.height.toDouble()));
    image.dispose();
  }

  Future<void> _pickSample(Future<String?> Function() source) async {
    final String? path;
    try {
      path = await source();
    } on PlatformException catch (e) {
      _toast('Could not get a photo: ${e.message ?? e.code}');
      return;
    }
    if (path == null) return;
    setState(() => _preparing = true);
    try {
      final sample = await TemplateBuilder.prepare(path, _id);
      // The page image is rewritten under the same name; evict the old one.
      imageCache.clear();
      if (!mounted) return;
      setState(() {
        _imagePath = sample.imagePath;
        _imageSize = sample.size;
        _anchors = sample.anchors;
        _fields = [];
      });
      if (sample.anchors.length < 4) {
        _toast('Few printed labels found on this sheet. Scans will align by '
            'the page edges, so photograph the whole page.');
      }
    } on Exception catch (e) {
      _toast('Could not prepare that photo: $e');
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<String?> _fromScanner() async {
    final scanner = DocumentScanner(
      options: DocumentScannerOptions(mode: ScannerMode.base, pageLimit: 1),
    );
    try {
      final result = await scanner.scanDocument();
      return (result.images ?? const []).firstOrNull;
    } finally {
      await scanner.close();
    }
  }

  Future<String?> _fromPicker(ImageSource source) async =>
      (await ImagePicker().pickImage(source: source, imageQuality: 100))?.path;

  Future<void> _addField(Rect box) async {
    final kind = await showModalBottomSheet<FieldKind>(
      context: context,
      backgroundColor: Colors.white,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('What is in this box?')),
            for (final k in FieldKind.values)
              ListTile(
                leading: Icon(_iconFor(k)),
                title: Text(k.label),
                onTap: () => Navigator.of(context).pop(k),
              ),
          ],
        ),
      ),
    );
    if (kind == null || !mounted) return;

    var field = TemplateField(kind: kind, box: box);
    if (kind == FieldKind.question || kind == FieldKind.writtenTotal) {
      final details = await _askDetails(kind);
      if (details == null) return;
      field = details(box);
    }
    setState(() => _fields = [..._fields, field]);
  }

  /// Label, part and maximum for a question; label for a written total.
  Future<TemplateField Function(Rect)?> _askDetails(FieldKind kind) {
    final isQuestion = kind == FieldKind.question;
    final questions = _fields.where((f) => f.kind == FieldKind.question).length;
    final label = TextEditingController(
        text: isQuestion ? 'Q${questions + 1}' : 'Total in words');
    final max = TextEditingController();
    var part = 'A';
    return showDialog<TemplateField Function(Rect)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          backgroundColor: Colors.white,
          title: Text(kind.label),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: label,
                decoration: const InputDecoration(labelText: 'Label'),
              ),
              if (isQuestion) ...[
                const SizedBox(height: AppSpacing.sm),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'A', label: Text('Part-A')),
                    ButtonSegment(value: 'B', label: Text('Part-B')),
                  ],
                  selected: {part},
                  onSelectionChanged: (s) => setLocal(() => part = s.first),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: max,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration:
                      const InputDecoration(labelText: 'Max marks (optional)'),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: () => Navigator.of(context).pop(
                (Rect box) => TemplateField(
                  kind: kind,
                  box: box,
                  label: label.text.trim(),
                  part: part,
                  maxMarks: int.tryParse(max.text),
                ),
              ),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final a = int.tryParse(_partAMax.text);
    final b = int.tryParse(_partBMax.text);
    final mask = _mask.text.trim().toUpperCase();
    if (_name.text.trim().isEmpty) return _toast('Give the template a name.');
    if (_fields.isEmpty) return _toast('Draw at least one box.');
    if (a == null || b == null) return _toast('Enter the maximum marks.');
    if (mask.isNotEmpty && !RegExp(r'^[DAX]+$').hasMatch(mask)) {
      return _toast('Format uses D (digit), A (letter) and X (either) only.');
    }
    await TemplateStore.instance.save(SheetTemplate(
      id: _id,
      name: _name.text.trim(),
      fields: _fields,
      anchors: _anchors,
      sampleImagePath: _imagePath,
      registrationMask: mask.isEmpty ? null : mask,
      partAMax: a,
      partBMax: b,
    ));
    if (mounted) Navigator.of(context).pop();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top + kToolbarHeight;
    return GlassScaffold(
      title: widget.template == null ? 'New template' : 'Edit template',
      actions: [
        if (_imagePath != null)
          IconButton(
            tooltip: _drawMode ? 'Zoom and pan' : 'Draw boxes',
            icon: Icon(_drawMode ? Icons.pan_tool_outlined : Icons.crop_square),
            onPressed: () => setState(() => _drawMode = !_drawMode),
          ),
        TextButton(onPressed: _save, child: const Text('Save')),
      ],
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            AppSpacing.md, top + AppSpacing.md, AppSpacing.md, AppSpacing.xl),
        children: [
          _buildSettings(),
          const SizedBox(height: AppSpacing.md),
          if (_preparing)
            const GlassCard(
              child: Column(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: AppSpacing.md),
                  Text('Straightening the page and finding printed labels'),
                ],
              ),
            )
          else if (_imagePath == null || _imageSize == null)
            _buildSourcePicker()
          else ...[
            Text(
              _drawMode
                  ? 'Drag over a field to draw its box. Include some margin.'
                  : 'Pinch to zoom, drag to move. Switch back to draw.',
              style: const TextStyle(color: AppColors.inkMuted),
            ),
            const SizedBox(height: AppSpacing.sm),
            _buildCanvas(),
            const SizedBox(height: AppSpacing.sm),
            _buildFieldList(),
            TextButton.icon(
              onPressed: _replaceSample,
              icon: const Icon(Icons.refresh),
              label: const Text('Use a different sample sheet'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSettings() {
    InputDecoration deco(String label, [String? hint]) =>
        InputDecoration(labelText: label, hintText: hint);
    return GlassCard(
      child: Column(
        children: [
          TextField(
            controller: _name,
            decoration: deco('Name', 'e.g. CMR CAT answer book'),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _partAMax,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: deco('Part-A max'),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: TextField(
                  controller: _partBMax,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: deco('Part-B max'),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _mask,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[dDaAxX]')),
            ],
            decoration: deco(
              'Registration number format (optional)',
              'D digit · A letter · X either, e.g. DDADDADDXX',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourcePicker() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Choose a sample sheet',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
            'Any one filled-in sheet of this layout. A flat, straight, '
            'well-lit photo of the whole page works best.',
            style: TextStyle(color: AppColors.inkMuted),
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
          onPressed: () => _pickSample(_fromScanner),
          icon: const Icon(Icons.crop_free_rounded),
          label: const Text('Document scanner'),
        ),
        const SizedBox(height: AppSpacing.sm),
        OutlinedButton.icon(
          onPressed: () => _pickSample(() => _fromPicker(ImageSource.camera)),
          icon: const Icon(Icons.photo_camera_outlined),
          label: const Text('Camera'),
        ),
        const SizedBox(height: AppSpacing.sm),
        OutlinedButton.icon(
          onPressed: () => _pickSample(() => _fromPicker(ImageSource.gallery)),
          icon: const Icon(Icons.photo_library_outlined),
          label: const Text('Gallery'),
        ),
        ],
      ),
    );
  }

  Future<void> _replaceSample() async {
    final source = await showModalBottomSheet<Future<String?> Function()>(
      context: context,
      backgroundColor: Colors.white,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('Replacing the sample clears the boxes.')),
            ListTile(
              leading: const Icon(Icons.crop_free_rounded),
              title: const Text('Document scanner'),
              onTap: () => Navigator.of(context).pop(_fromScanner),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Camera'),
              onTap: () => Navigator.of(context)
                  .pop(() => _fromPicker(ImageSource.camera)),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Gallery'),
              onTap: () => Navigator.of(context)
                  .pop(() => _fromPicker(ImageSource.gallery)),
            ),
          ],
        ),
      ),
    );
    if (source != null) await _pickSample(source);
  }

  Widget _buildCanvas() {
    final size = _imageSize!;
    return GlassCard(
      padding: const EdgeInsets.all(AppSpacing.xs),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: InteractiveViewer(
          maxScale: 6,
          panEnabled: !_drawMode,
          scaleEnabled: !_drawMode,
          child: AspectRatio(
            aspectRatio: size.width / size.height,
            child: LayoutBuilder(
              builder: (context, c) {
                Offset norm(Offset p) => Offset(
                      (p.dx / c.maxWidth).clamp(0.0, 1.0),
                      (p.dy / c.maxHeight).clamp(0.0, 1.0),
                    );
                return GestureDetector(
                  onPanStart: _drawMode
                      ? (d) => setState(() {
                            _dragStart = norm(d.localPosition);
                            _dragRect = null;
                          })
                      : null,
                  onPanUpdate: _drawMode
                      ? (d) => setState(() => _dragRect =
                          Rect.fromPoints(_dragStart!, norm(d.localPosition)))
                      : null,
                  onPanEnd: _drawMode
                      ? (_) {
                          final r = _dragRect;
                          setState(() => _dragRect = null);
                          // Ignore accidental taps.
                          if (r != null && r.width > 0.01 && r.height > 0.005) {
                            _addField(r);
                          }
                        }
                      : null,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.file(File(_imagePath!), fit: BoxFit.fill),
                      CustomPaint(
                        painter: _BoxPainter(_fields, _dragRect, _anchors),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFieldList() {
    if (_fields.isEmpty) {
      return const Text(
        'No boxes yet. Draw at least the registration number and the totals.',
        style: TextStyle(color: AppColors.inkFaint, fontSize: 12),
      );
    }
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      children: [
        for (var i = 0; i < _fields.length; i++)
          InputChip(
            avatar: Icon(_iconFor(_fields[i].kind), size: 16),
            label: Text(_fields[i].title),
            onDeleted: () => setState(() => _fields = [..._fields]..removeAt(i)),
          ),
      ],
    );
  }

  static IconData _iconFor(FieldKind kind) => switch (kind) {
        FieldKind.registration => Icons.badge_outlined,
        FieldKind.partA || FieldKind.partB => Icons.functions,
        FieldKind.question => Icons.looks_one_outlined,
        FieldKind.writtenTotal => Icons.edit_note,
      };
}

class _BoxPainter extends CustomPainter {
  _BoxPainter(this.fields, this.drag, this.anchors);

  final List<TemplateField> fields;
  final Rect? drag;
  final List<TemplateAnchor> anchors;

  @override
  void paint(Canvas canvas, Size size) {
    Rect scale(Rect r) => Rect.fromLTRB(r.left * size.width,
        r.top * size.height, r.right * size.width, r.bottom * size.height);

    // Printed labels used for alignment, faintly, so the teacher can see
    // whether the sheet has enough of them.
    final anchorPaint = Paint()
      ..color = AppColors.teal.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final a in anchors) {
      final xs = a.corners.map((c) => c.dx), ys = a.corners.map((c) => c.dy);
      canvas.drawRect(
        scale(Rect.fromLTRB(xs.reduce(math.min), ys.reduce(math.min),
            xs.reduce(math.max), ys.reduce(math.max))),
        anchorPaint,
      );
    }

    final stroke = Paint()
      ..color = AppColors.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final fill = Paint()..color = AppColors.primary.withValues(alpha: 0.12);
    for (final f in fields) {
      final r = scale(f.box);
      canvas.drawRect(r, fill);
      canvas.drawRect(r, stroke);
      final text = TextPainter(
        text: TextSpan(
          text: f.title,
          style: const TextStyle(
            fontSize: 10,
            color: Colors.white,
            backgroundColor: AppColors.primary,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, r.topLeft - Offset(0, text.height));
    }
    if (drag != null) {
      canvas.drawRect(scale(drag!), stroke..color = AppColors.warning);
    }
  }

  @override
  bool shouldRepaint(_BoxPainter old) =>
      old.fields != fields || old.drag != drag || old.anchors != anchors;
}
