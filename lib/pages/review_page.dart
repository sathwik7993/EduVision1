import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/scan_result.dart';
import '../models/sheet_template.dart';
import '../services/correction_store.dart';
import '../services/roster_service.dart';
import '../services/scan_validator.dart';
import '../services/sheet_service.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';

/// Confirm-or-correct step between OCR and the workbook.
///
/// This exists because the previous flow wrote whatever OCR produced -- often
/// "Not Found" and "0" -- directly into the spreadsheet with no way for the
/// teacher to notice. Nothing is saved from here until every field is either
/// high-confidence or explicitly confirmed.
class ReviewPage extends StatefulWidget {
  const ReviewPage({
    super.key,
    required this.result,
    required this.engineName,
    required this.engineReadsHandwriting,
    this.template = SheetTemplate.defaults,
    this.roster,
    this.alreadySaved = const {},
  });

  final ScanResult result;
  final String engineName;
  final bool engineReadsHandwriting;
  final SheetTemplate template;
  final Roster? roster;
  final Set<String> alreadySaved;

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  /// Recognizer output plus the teacher's edits. Validation is re-run on it
  /// after every edit, so a corrected Part-A immediately re-checks the
  /// written grand total.
  late ScanResult _base = widget.result;
  late ScanResult _result = _validate(_base);

  late final TextEditingController _reg =
      TextEditingController(text: _result.registrationNo.value);
  late final TextEditingController _partA =
      TextEditingController(text: _result.partA.value);
  late final TextEditingController _partB =
      TextEditingController(text: _result.partB.value);
  late final List<TextEditingController> _questions = [
    for (final q in _result.questions) TextEditingController(text: q.field.value),
  ];
  late final List<TextEditingController> _written = [
    for (final w in _result.writtenTotals)
      TextEditingController(text: w.field.value),
  ];

  bool _saving = false;
  bool _showRaw = false;

  @override
  void dispose() {
    for (final c in [_reg, _partA, _partB, ..._questions, ..._written]) {
      c.dispose();
    }
    super.dispose();
  }

  ScanResult _validate(ScanResult base) => ScanValidator.validate(
        base,
        widget.template,
        roster: widget.roster,
        alreadySaved: widget.alreadySaved,
      );

  void _update(ScanResult base) {
    setState(() {
      _base = base;
      _result = _validate(base);
    });
  }

  /// The teacher's value replaces the reading but keeps its crop, so the
  /// pair can be stored as a labelled sample.
  ExtractedField _manual(ExtractedField old, String value) =>
      ExtractedField.manual(value, crop: old.crop);

  void _onRegChanged(String value) => _update(_base.copyWith(
      registrationNo:
          _manual(_base.registrationNo, value.trim().toUpperCase())));

  void _onPartAChanged(String value) =>
      _update(_base.copyWith(partA: _manual(_base.partA, value.trim())));

  void _onPartBChanged(String value) =>
      _update(_base.copyWith(partB: _manual(_base.partB, value.trim())));

  void _onQuestionChanged(int i, String value) {
    final qs = [..._base.questions];
    qs[i] = qs[i].withField(_manual(qs[i].field, value.trim()));
    _update(_base.copyWith(questions: qs));
  }

  void _onWrittenChanged(int i, String value) {
    final ws = [..._base.writtenTotals];
    ws[i] = ws[i].withField(_manual(ws[i].field, value.trim()));
    _update(_base.copyWith(writtenTotals: ws));
  }

  /// "This reading is right" without retyping it.
  void _confirm(TextEditingController controller, ValueChanged<String> onChanged,
      [String? value]) {
    final v = value ?? controller.text;
    controller.text = v;
    onChanged(v);
  }

  Future<void> _save() async {
    final reg = _reg.text.trim();
    if (reg.isEmpty) {
      _toast('Enter a registration number before saving.');
      return;
    }
    final blocking = ScanValidator.blockingErrors(_result, widget.template);
    if (blocking.isNotEmpty) {
      _toast(blocking.join('\n'));
      return;
    }

    setState(() => _saving = true);
    try {
      final service = SheetService.instance;

      // One row per student. Re-scanning the same sheet replaces its row;
      // the old "add anyway" option produced duplicate rows.
      var overwrite = false;
      if (await service.containsRegistration(reg)) {
        if (!mounted) return;
        final replace = await _askOverwrite(reg);
        if (replace != true) {
          if (mounted) setState(() => _saving = false);
          return;
        }
        overwrite = true;
      }

      final outcome = await service.save(_result, overwrite: overwrite);
      try {
        await CorrectionStore.instance.record(
          original: widget.result,
          reviewed: _result,
          templateId: widget.template.id,
        );
      } on Exception catch (e) {
        // Labelled samples are a bonus; never lose a save over them.
        debugPrint('Could not store labelled crops: $e');
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
      if (outcome == SaveOutcome.updated) {
        _toast('Updated the existing row for $reg.');
      }
    } on Exception catch (e) {
      // Save failures used to be swallowed entirely.
      if (mounted) _toast('Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool?> _askOverwrite(String reg) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        backgroundColor: Colors.white,
        title: const Text('Already scanned'),
        content: Text(
          '$reg is already in the results sheet.\n\n'
          'Replace the existing row with these marks?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final pending = _result.fieldsNeedingReview;

    return GlassScaffold(
      title: 'Check the details',
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.md,
          MediaQuery.paddingOf(context).top + kToolbarHeight + AppSpacing.md,
          AppSpacing.md,
          AppSpacing.md + MediaQuery.viewInsetsOf(context).bottom,
        ),
        children: [
          EntranceFade(index: 0, child: _buildBanner(pending)),
          const SizedBox(height: AppSpacing.md),
          if (_result.imagePath != null) ...[
            EntranceFade(index: 1, child: _buildPreview()),
            const SizedBox(height: AppSpacing.md),
          ],
          EntranceFade(index: 2, child: _buildFields()),
          const SizedBox(height: AppSpacing.md),
          if (_result.questions.isNotEmpty ||
              _result.writtenTotals.isNotEmpty) ...[
            EntranceFade(index: 3, child: _buildExtraMarks()),
            const SizedBox(height: AppSpacing.md),
          ],
          EntranceFade(index: 3, child: _buildTotal()),
          const SizedBox(height: AppSpacing.md),
          EntranceFade(index: 4, child: _buildRawText()),
          const SizedBox(height: AppSpacing.lg),
          EntranceFade(index: 5, child: _buildSaveButton()),
          const SizedBox(height: AppSpacing.lg),
        ],
      ),
    );
  }

  Widget _buildBanner(List<String> pending) {
    final clean = pending.isEmpty;
    final color = clean ? AppColors.success : AppColors.warning;

    return GlassCard(
      radius: AppRadius.lg,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Icon(
              clean ? Icons.verified_outlined : Icons.error_outline,
              color: color,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  clean ? 'Read with high confidence' : 'Needs your check',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  clean
                      ? 'Confirm the values below, then save.'
                      : 'Could not read ${pending.join(', ')} reliably. '
                          'Check each one against the sheet.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (!widget.engineReadsHandwriting) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    '${widget.engineName} reads printed text only — always '
                    'verify handwritten marks yourself.',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.inkFaint,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    return GlassCard(
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: SizedBox(
            width: double.infinity,
            child: Image.file(
              File(_result.imagePath!),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox(
                height: 120,
                child: Center(child: Text('Preview unavailable')),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static final _markFormatters = [
    FilteringTextInputFormatter.digitsOnly,
    LengthLimitingTextInputFormatter(3),
  ];
  static const _markKeyboard = TextInputType.numberWithOptions(signed: false);

  Widget _buildFields() {
    return GlassCard(
      child: Column(
        children: [
          _FieldRow(
            label: 'Registration No',
            controller: _reg,
            field: _result.registrationNo,
            onChanged: _onRegChanged,
            onConfirm: (v) => _confirm(_reg, _onRegChanged, v),
            keyboardType: TextInputType.visiblePassword,
            formatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
              LengthLimitingTextInputFormatter(20),
              _UpperCaseFormatter(),
            ],
          ),
          const Divider(height: AppSpacing.lg),
          _FieldRow(
            label: 'Part-A marks',
            controller: _partA,
            field: _result.partA,
            onChanged: _onPartAChanged,
            onConfirm: (v) => _confirm(_partA, _onPartAChanged, v),
            keyboardType: _markKeyboard,
            formatters: _markFormatters,
          ),
          const Divider(height: AppSpacing.lg),
          _FieldRow(
            label: 'Part-B marks',
            controller: _partB,
            field: _result.partB,
            onChanged: _onPartBChanged,
            onConfirm: (v) => _confirm(_partB, _onPartBChanged, v),
            keyboardType: _markKeyboard,
            formatters: _markFormatters,
          ),
        ],
      ),
    );
  }

  /// Per-question marks and totals written on the sheet. A blank cell is
  /// normal here, so these rows only ask for attention when doubtful.
  Widget _buildExtraMarks() {
    final rows = <Widget>[];
    void add(LabelledMark m, TextEditingController c, ValueChanged<String> on) {
      if (rows.isNotEmpty) rows.add(const Divider(height: AppSpacing.lg));
      rows.add(_FieldRow(
        label: m.part.isEmpty ? m.label : '${m.label} (Part-${m.part})',
        controller: c,
        field: m.field,
        blankIsFine: !m.needsReview,
        onChanged: on,
        onConfirm: (v) => _confirm(c, on, v),
        keyboardType: _markKeyboard,
        formatters: _markFormatters,
      ));
    }

    for (var i = 0; i < _result.questions.length; i++) {
      add(_result.questions[i], _questions[i], (v) => _onQuestionChanged(i, v));
    }
    for (var i = 0; i < _result.writtenTotals.length; i++) {
      add(_result.writtenTotals[i], _written[i], (v) => _onWrittenChanged(i, v));
    }
    return GlassCard(child: Column(children: rows));
  }

  Widget _buildTotal() {
    return GlassCard(
      opacity: 0.78,
      child: Row(
        children: [
          const Icon(Icons.functions, color: AppColors.primary),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Grand total',
                    style: Theme.of(context).textTheme.titleMedium),
                const Text(
                  'Calculated from Part-A + Part-B, never read from the page',
                  style: TextStyle(fontSize: 12, color: AppColors.inkFaint),
                ),
              ],
            ),
          ),
          AnimatedSwitcher(
            duration: AppMotion.fast,
            child: Text(
              '${_result.total}',
              key: ValueKey(_result.total),
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w700,
                letterSpacing: -1,
                color: AppColors.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRawText() {
    if (_result.rawText.trim().isEmpty) return const SizedBox.shrink();

    return GlassCard(
      opacity: 0.5,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      // ExpansionTile draws its own dividers, which fight the glass edge.
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: AppSpacing.sm),
          initiallyExpanded: _showRaw,
          onExpansionChanged: (v) => setState(() => _showRaw = v),
          title: const Text(
            'What the scanner read',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.inkMuted,
            ),
          ),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                _result.rawText,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  fontFamily: 'monospace',
                  color: AppColors.inkMuted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSaveButton() {
    return FilledButton.icon(
      onPressed: _saving ? null : _save,
      icon: _saving
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.check_rounded),
      label: Text(_saving ? 'Saving…' : 'Save to results sheet'),
    );
  }
}

/// One labelled input with a confidence badge, the crop the model read, and
/// any validation issue.
class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.label,
    required this.controller,
    required this.field,
    required this.onChanged,
    required this.onConfirm,
    required this.keyboardType,
    required this.formatters,
    this.blankIsFine = false,
  });

  final String label;
  final TextEditingController controller;
  final ExtractedField field;
  final ValueChanged<String> onChanged;

  /// Accept a value as correct (the reading, or a suggestion).
  final ValueChanged<String?> onConfirm;
  final TextInputType keyboardType;
  final List<TextInputFormatter> formatters;
  final bool blankIsFine;

  bool get _needsReview => !blankIsFine && field.needsReview;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            _confidenceBadge(),
          ],
        ),
        if (field.crop != null) ...[
          const SizedBox(height: AppSpacing.sm),
          // Exactly what the model saw, so the teacher compares like with
          // like instead of hunting for the field on the full photo.
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: Image.memory(
              field.crop!,
              height: 44,
              fit: BoxFit.contain,
              alignment: Alignment.centerLeft,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: controller,
          onChanged: onChanged,
          keyboardType: keyboardType,
          inputFormatters: formatters,
          textCapitalization: TextCapitalization.characters,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
          decoration: InputDecoration(
            hintText: blankIsFine ? 'Blank' : 'Tap to enter',
            suffixIcon: _needsReview
                ? const Icon(Icons.edit_outlined, color: AppColors.warning)
                : null,
          ),
        ),
        if (!field.edited && field.issue != null) ...[
          const SizedBox(height: 6),
          Text(
            field.issue!,
            style: const TextStyle(fontSize: 12, color: AppColors.danger),
          ),
        ],
        if (_needsReview && (field.suggestion != null || !field.isEmpty))
          Wrap(
            spacing: AppSpacing.sm,
            children: [
              if (field.suggestion != null)
                TextButton.icon(
                  onPressed: () => onConfirm(field.suggestion),
                  icon: const Icon(Icons.auto_fix_high, size: 16),
                  label: Text('Use ${field.suggestion}'),
                ),
              if (!field.isEmpty)
                TextButton.icon(
                  onPressed: () => onConfirm(null),
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Matches the sheet'),
                ),
            ],
          ),
      ],
    );
  }

  Widget _confidenceBadge() {
    if (field.edited) {
      return const GlassBadge(
        label: 'Entered by you',
        color: AppColors.primary,
        icon: Icons.person_outline,
      );
    }
    if (field.isEmpty && blankIsFine) {
      return const GlassBadge(
        label: 'Blank',
        color: AppColors.inkMuted,
        icon: Icons.remove,
      );
    }
    if (field.isEmpty) {
      return const GlassBadge(
        label: 'Not found',
        color: AppColors.danger,
        icon: Icons.search_off,
      );
    }
    if (_needsReview) {
      return GlassBadge(
        label: field.issue != null && field.confidence >= ExtractedField.trustedAbove
            ? 'Check'
            : 'Low • ${(field.confidence * 100).round()}%',
        color: AppColors.warning,
        icon: Icons.warning_amber_rounded,
      );
    }
    return GlassBadge(
      label: '${(field.confidence * 100).round()}%',
      color: AppColors.success,
      icon: Icons.check_circle_outline,
    );
  }
}

class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return newValue.copyWith(text: newValue.text.toUpperCase());
  }
}
