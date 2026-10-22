import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/scan_result.dart';
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
  });

  final ScanResult result;
  final String engineName;
  final bool engineReadsHandwriting;

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  late ScanResult _result = widget.result;
  late final TextEditingController _reg =
      TextEditingController(text: _result.registrationNo.value);
  late final TextEditingController _partA =
      TextEditingController(text: _result.partA.value);
  late final TextEditingController _partB =
      TextEditingController(text: _result.partB.value);

  bool _saving = false;
  bool _showRaw = false;

  @override
  void dispose() {
    _reg.dispose();
    _partA.dispose();
    _partB.dispose();
    super.dispose();
  }

  void _onRegChanged(String value) {
    setState(() {
      _result = _result.copyWith(
        registrationNo: ExtractedField.manual(value.trim().toUpperCase()),
      );
    });
  }

  void _onPartAChanged(String value) {
    setState(() {
      _result = _result.copyWith(partA: ExtractedField.manual(value.trim()));
    });
  }

  void _onPartBChanged(String value) {
    setState(() {
      _result = _result.copyWith(partB: ExtractedField.manual(value.trim()));
    });
  }

  Future<void> _save() async {
    final reg = _reg.text.trim();
    if (reg.isEmpty) {
      _toast('Enter a registration number before saving.');
      return;
    }

    setState(() => _saving = true);
    try {
      final service = SheetService.instance;

      // Explicit duplicate handling. The old flow appended blindly, so
      // re-scanning a sheet silently produced two rows for one student.
      var overwrite = false;
      if (await service.containsRegistration(reg)) {
        if (!mounted) return;
        final choice = await _askOverwrite(reg);
        if (choice == null) {
          if (mounted) setState(() => _saving = false);
          return;
        }
        overwrite = choice;
      }

      final outcome = await service.save(_result, overwrite: overwrite);
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
          'Replace the existing row, or add this as a separate entry?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Add anyway'),
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
                          'Type the correct value for each.',
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

  Widget _buildFields() {
    return GlassCard(
      child: Column(
        children: [
          _FieldRow(
            label: 'Registration No',
            controller: _reg,
            field: _result.registrationNo,
            onChanged: _onRegChanged,
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
            keyboardType: const TextInputType.numberWithOptions(signed: false),
            formatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(3),
            ],
          ),
          const Divider(height: AppSpacing.lg),
          _FieldRow(
            label: 'Part-B marks',
            controller: _partB,
            field: _result.partB,
            onChanged: _onPartBChanged,
            keyboardType: const TextInputType.numberWithOptions(signed: false),
            formatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(3),
            ],
          ),
        ],
      ),
    );
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

/// One labelled input with a confidence badge.
class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.label,
    required this.controller,
    required this.field,
    required this.onChanged,
    required this.keyboardType,
    required this.formatters,
  });

  final String label;
  final TextEditingController controller;
  final ExtractedField field;
  final ValueChanged<String> onChanged;
  final TextInputType keyboardType;
  final List<TextInputFormatter> formatters;

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
            hintText: 'Tap to enter',
            suffixIcon: field.needsReview
                ? const Icon(Icons.edit_outlined, color: AppColors.warning)
                : null,
          ),
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
    if (field.isEmpty) {
      return const GlassBadge(
        label: 'Not found',
        color: AppColors.danger,
        icon: Icons.search_off,
      );
    }
    if (field.needsReview) {
      return GlassBadge(
        label: 'Low • ${(field.confidence * 100).round()}%',
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
