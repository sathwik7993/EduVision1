import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'glass.dart';

/// Shared chrome for the login and register screens.
///
/// Both pages previously carried their own near-identical 180-line build
/// method with slightly different styling.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.fields,
    required this.primaryLabel,
    required this.onPrimary,
    required this.onGoogle,
    required this.footerText,
    required this.footerAction,
    required this.onFooter,
    this.busy = false,
  });

  final String title;
  final String subtitle;
  final List<Widget> fields;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final VoidCallback onGoogle;
  final String footerText;
  final String footerAction;
  final VoidCallback onFooter;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    EntranceFade(index: 0, child: _buildMark(context)),
                    const SizedBox(height: AppSpacing.xl),
                    EntranceFade(index: 1, child: _buildCard(context)),
                    const SizedBox(height: AppSpacing.lg),
                    EntranceFade(index: 2, child: _buildFooter(context)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMark(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.primary, AppColors.violet],
            ),
            boxShadow: AppShadows.raised,
          ),
          child: const Icon(Icons.document_scanner_outlined,
              color: Colors.white, size: 36),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: AppSpacing.xs),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }

  Widget _buildCard(BuildContext context) {
    return GlassCard(
      radius: AppRadius.xl,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        children: [
          ...fields,
          const SizedBox(height: AppSpacing.md),
          FilledButton(
            onPressed: busy ? null : onPrimary,
            child: busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(primaryLabel),
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              const Expanded(child: Divider()),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: Text(
                  'or',
                  style: TextStyle(
                    color: AppColors.inkFaint,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const Expanded(child: Divider()),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          _GoogleButton(onTap: busy ? null : onGoogle),
        ],
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(footerText, style: Theme.of(context).textTheme.bodyMedium),
        GestureDetector(
          onTap: onFooter,
          child: Text(
            footerAction,
            style: const TextStyle(
              color: AppColors.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class AuthField extends StatelessWidget {
  const AuthField({
    super.key,
    required this.controller,
    required this.label,
    required this.icon,
    this.obscure = false,
    this.keyboardType,
    this.textInputAction,
    this.trailing,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool obscure;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Widget? trailing;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      autocorrect: false,
      enableSuggestions: !obscure,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        suffixIcon: trailing,
      ),
    );
  }
}

class _GoogleButton extends StatelessWidget {
  const _GoogleButton({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.5 : 1,
      child: GlassCard(
        onTap: onTap ?? () {},
        radius: AppRadius.md,
        opacity: 0.85,
        padding: const EdgeInsets.symmetric(vertical: 15),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              'lib/images/google_L.png',
              height: 22,
              // The asset may be missing in a stripped build; fall back rather
              // than throwing a render exception across the whole card.
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.g_mobiledata, size: 26),
            ),
            const SizedBox(width: AppSpacing.md),
            const Text(
              'Continue with Google',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
