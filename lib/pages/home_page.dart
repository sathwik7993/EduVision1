import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/sheet_service.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';
import 'account_page.dart';
import 'my_sheets_page.dart';
import 'scan_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _savedCount = 0;
  bool _loadingCount = true;

  @override
  void initState() {
    super.initState();
    _refreshCount();
  }

  Future<void> _refreshCount() async {
    final rows = await SheetService.instance.readAll();
    if (!mounted) return;
    setState(() {
      _savedCount = rows.length;
      _loadingCount = false;
    });
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => page),
    );
    // Counts change while the user is away on either screen.
    if (mounted) _refreshCount();
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthService.instance.currentUser;
    final name = user?.displayName?.split(' ').first ??
        user?.email?.split('@').first ??
        'there';

    return GlassScaffold(
      body: RefreshIndicator(
        onRefresh: _refreshCount,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.md,
            MediaQuery.paddingOf(context).top + AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.xl,
          ),
          children: [
            EntranceFade(index: 0, child: _buildHeader(context, name)),
            const SizedBox(height: AppSpacing.lg),
            EntranceFade(index: 1, child: _buildScanCard()),
            const SizedBox(height: AppSpacing.md),
            EntranceFade(index: 2, child: _buildStat()),
            const SizedBox(height: AppSpacing.md),
            EntranceFade(
              index: 3,
              child: Row(
                children: [
                  Expanded(
                    child: _TileCard(
                      icon: Icons.table_chart_outlined,
                      title: 'My sheets',
                      caption: 'View & export',
                      onTap: () => _open(const MySheetsPage()),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: _TileCard(
                      icon: Icons.person_outline,
                      title: 'Account',
                      caption: 'Profile & sign out',
                      onTap: () => _open(const AccountPage()),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, String name) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Hello, $name',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 2),
              Text('Ready to digitise some mark sheets?',
                  style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
        GlassCard(
          onTap: () => _open(const AccountPage()),
          radius: AppRadius.pill,
          padding: const EdgeInsets.all(12),
          child: const Icon(Icons.person_outline, color: AppColors.ink),
        ),
      ],
    );
  }

  /// The primary action gets a solid, saturated card rather than glass -- on a
  /// screen where everything is translucent, opacity is what signals priority.
  Widget _buildScanCard() {
    return GestureDetector(
      onTap: () => _open(const ScanPage()),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.xl),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.primary, AppColors.violet],
          ),
          boxShadow: AppShadows.raised,
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.20),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: const Icon(Icons.document_scanner_outlined,
                  color: Colors.white, size: 30),
            ),
            const SizedBox(width: AppSpacing.md),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Scan a sheet',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.4,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Capture, check, then save to Excel',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_rounded, color: Colors.white),
          ],
        ),
      ),
    );
  }

  Widget _buildStat() {
    return GlassCard(
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.teal.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: const Icon(Icons.fact_check_outlined, color: AppColors.teal),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text('Results saved',
                style: Theme.of(context).textTheme.titleMedium),
          ),
          if (_loadingCount)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Text(
              '$_savedCount',
              style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w700,
                letterSpacing: -1,
              ),
            ),
        ],
      ),
    );
  }
}

class _TileCard extends StatelessWidget {
  const _TileCard({
    required this.icon,
    required this.title,
    required this.caption,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String caption;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 26, color: AppColors.primary),
          const SizedBox(height: AppSpacing.md),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 2),
          Text(
            caption,
            style: const TextStyle(fontSize: 12, color: AppColors.inkFaint),
          ),
        ],
      ),
    );
  }
}
