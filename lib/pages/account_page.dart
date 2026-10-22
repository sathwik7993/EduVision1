import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/auth_service.dart';
import '../services/sheet_service.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';

class AccountPage extends StatelessWidget {
  const AccountPage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = AuthService.instance.currentUser;

    return GlassScaffold(
      title: 'Account',
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.md,
          MediaQuery.paddingOf(context).top + kToolbarHeight + AppSpacing.md,
          AppSpacing.md,
          AppSpacing.xl,
        ),
        children: [
          if (user == null)
            const _Empty()
          else ...[
            EntranceFade(index: 0, child: _Profile(user: user)),
            const SizedBox(height: AppSpacing.md),
            EntranceFade(index: 1, child: _Details(user: user)),
            const SizedBox(height: AppSpacing.md),
            EntranceFade(index: 2, child: const _DataSection()),
            const SizedBox(height: AppSpacing.lg),
            EntranceFade(index: 3, child: const _SignOutButton()),
          ],
        ],
      ),
    );
  }
}

class _Profile extends StatelessWidget {
  const _Profile({required this.user});

  final User user;

  @override
  Widget build(BuildContext context) {
    final email = user.email ?? '';
    final name = user.displayName ??
        (email.isNotEmpty ? email.split('@').first : 'Teacher');
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final photo = user.photoURL;

    return GlassCard(
      radius: AppRadius.xl,
      child: Column(
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.primary, AppColors.violet],
              ),
              boxShadow: AppShadows.card,
            ),
            clipBehavior: Clip.antiAlias,
            child: photo != null
                ? Image.network(
                    photo,
                    fit: BoxFit.cover,
                    // Avatar is remote; this app must work offline.
                    errorBuilder: (_, _, _) => _Initial(initial),
                  )
                : _Initial(initial),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(name, style: Theme.of(context).textTheme.titleLarge),
          if (email.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(email, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}

class _Initial extends StatelessWidget {
  const _Initial(this.letter);

  final String letter;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        letter,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 34,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.user});

  final User user;

  @override
  Widget build(BuildContext context) {
    final uid = user.uid;
    final verified = user.emailVerified;

    return GlassCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Column(
        children: [
          _Tile(
            icon: Icons.email_outlined,
            label: 'Email',
            value: user.email ?? 'Not available',
            trailing: GlassBadge(
              label: verified ? 'Verified' : 'Unverified',
              color: verified ? AppColors.success : AppColors.warning,
            ),
          ),
          const Divider(),
          _Tile(
            icon: Icons.fingerprint,
            label: 'User ID',
            value: uid,
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: uid));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('User ID copied')),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}

class _DataSection extends StatelessWidget {
  const _DataSection();

  Future<void> _clear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        title: const Text('Delete all results?'),
        content: const Text(
          'This permanently removes every saved result from this device. '
          'Export or share the sheet first if you still need it.',
        ),
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
            child: const Text('Delete all'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await SheetService.instance.deleteWorkbook();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All saved results deleted.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Column(
        children: [
          _Tile(
            icon: Icons.ios_share,
            label: 'Export results',
            value: 'Send the workbook by email or Drive',
            onTap: () => SheetService.instance.share(),
          ),
          const Divider(),
          _Tile(
            icon: Icons.delete_outline,
            label: 'Delete all results',
            value: 'Clears the workbook on this device',
            danger: true,
            onTap: () => _clear(context),
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.label,
    required this.value,
    this.trailing,
    this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.danger : AppColors.primary;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: danger ? AppColors.danger : AppColors.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.inkFaint),
                  ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

class _SignOutButton extends StatelessWidget {
  const _SignOutButton();

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      // No manual navigation afterwards: AuthGate reacts to the auth stream and
      // swaps the screen. The old code pushed LoginPage on top of the gate.
      onPressed: () => AuthService.instance.signOut(),
      style: FilledButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.danger,
        elevation: 0,
      ),
      icon: const Icon(Icons.logout),
      label: const Text('Sign out'),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(top: 80),
      child: Center(child: Text('No user is signed in.')),
    );
  }
}
