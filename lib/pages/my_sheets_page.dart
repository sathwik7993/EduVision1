import 'package:flutter/material.dart';

import '../services/sheet_service.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';

/// Lists what has actually been saved.
///
/// The old version was a static illustration with a single "Open Excel Sheet"
/// button that silently did nothing when no file existed or no spreadsheet app
/// was installed.
class MySheetsPage extends StatefulWidget {
  const MySheetsPage({super.key});

  @override
  State<MySheetsPage> createState() => _MySheetsPageState();
}

class _MySheetsPageState extends State<MySheetsPage> {
  late Future<List<SheetRow>> _rows;

  @override
  void initState() {
    super.initState();
    _rows = SheetService.instance.readAll();
  }

  void _reload() {
    setState(() => _rows = SheetService.instance.readAll());
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _open() async {
    final error = await SheetService.instance.openExternally();
    if (error != null) _toast(error);
  }

  Future<void> _delete(SheetRow row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        title: const Text('Remove entry'),
        content: Text('Delete the saved result for ${row.registrationNo}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              minimumSize: const Size(0, 44),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await SheetService.instance.deleteRegistration(row.registrationNo);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      title: 'My sheets',
      actions: [
        IconButton(
          tooltip: 'Share',
          icon: const Icon(Icons.ios_share),
          onPressed: () => SheetService.instance.share(),
        ),
        IconButton(
          tooltip: 'Open in spreadsheet app',
          icon: const Icon(Icons.open_in_new),
          onPressed: _open,
        ),
      ],
      body: FutureBuilder<List<SheetRow>>(
        future: _rows,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _Empty(
              icon: Icons.error_outline,
              title: 'Could not read the sheet',
              body: '${snapshot.error}',
            );
          }

          final rows = snapshot.data ?? const <SheetRow>[];
          if (rows.isEmpty) {
            return const _Empty(
              icon: Icons.table_chart_outlined,
              title: 'Nothing saved yet',
              body: 'Scanned results will appear here once you save '
                  'your first exam sheet.',
            );
          }

          return ListView.separated(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.md,
              MediaQuery.paddingOf(context).top + kToolbarHeight + AppSpacing.md,
              AppSpacing.md,
              AppSpacing.xl,
            ),
            itemCount: rows.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: EntranceFade(child: _buildSummary(rows)),
                );
              }
              final row = rows[index - 1];
              return EntranceFade(
                index: index.clamp(0, 6),
                child: _RowCard(row: row, onDelete: () => _delete(row)),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildSummary(List<SheetRow> rows) {
    final average = rows.isEmpty
        ? 0
        : (rows.map((r) => r.total).reduce((a, b) => a + b) / rows.length)
            .round();

    return GlassCard(
      child: Row(
        children: [
          _Metric(label: 'Students', value: '${rows.length}'),
          const _VDivider(),
          _Metric(label: 'Average', value: '$average'),
          const _VDivider(),
          _Metric(
            label: 'Highest',
            value: '${rows.map((r) => r.total).reduce((a, b) => a > b ? a : b)}',
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: -1,
            ),
          ),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(fontSize: 12, color: AppColors.inkFaint)),
        ],
      ),
    );
  }
}

class _VDivider extends StatelessWidget {
  const _VDivider();

  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 34, color: AppColors.hairline);
}

class _RowCard extends StatelessWidget {
  const _RowCard({required this.row, required this.onDelete});

  final SheetRow row;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.registrationNo,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Part-A ${row.partA}   ·   Part-B ${row.partB}',
                  style: const TextStyle(
                      fontSize: 12.5, color: AppColors.inkMuted),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${row.total}',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.8,
                ),
              ),
              const Text('total',
                  style: TextStyle(fontSize: 11, color: AppColors.inkFaint)),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline,
                size: 20, color: AppColors.inkFaint),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: GlassCard(
          radius: AppRadius.xl,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 46, color: AppColors.inkFaint),
              const SizedBox(height: AppSpacing.md),
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: AppSpacing.sm),
              Text(
                body,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
