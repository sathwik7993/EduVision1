import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../theme/app_theme.dart';
import '../widgets/auth_scaffold.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key, required this.onTap});

  /// Switches back to the login page. Supplied by [LoginOrRegisterPage].
  final VoidCallback onTap;

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _showPassword = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on AuthCancelled {
      // User dismissed the Google sheet.
    } on AuthFailure catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() => _run(
        () => AuthService.instance.register(
          email: _email.text,
          password: _password.text,
          confirmPassword: _confirm.text,
        ),
      );

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Create account',
      subtitle: 'Set up EduVision to start digitising mark sheets.',
      busy: _busy,
      fields: [
        AuthField(
          controller: _email,
          label: 'Email',
          icon: Icons.alternate_email,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: AppSpacing.md),
        AuthField(
          controller: _password,
          label: 'Password',
          icon: Icons.lock_outline,
          obscure: !_showPassword,
          textInputAction: TextInputAction.next,
          trailing: IconButton(
            icon: Icon(
              _showPassword ? Icons.visibility_off : Icons.visibility,
            ),
            onPressed: () => setState(() => _showPassword = !_showPassword),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        AuthField(
          controller: _confirm,
          label: 'Confirm password',
          icon: Icons.lock_reset_outlined,
          obscure: !_showPassword,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
      ],
      primaryLabel: 'Create account',
      onPrimary: _submit,
      onGoogle: () => _run(AuthService.instance.signInWithGoogle),
      footerText: 'Already a member? ',
      footerAction: 'Sign in',
      onFooter: widget.onTap,
    );
  }
}
