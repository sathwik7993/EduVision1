import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../theme/app_theme.dart';
import '../widgets/auth_scaffold.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.onTap});

  /// Switches to the register page. Supplied by [LoginOrRegisterPage].
  final VoidCallback onTap;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _showPassword = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  // Navigation after sign-in is deliberately absent: AuthGate listens to
  // authStateChanges and swaps the screen itself. The old code pushed HomePage
  // manually on top of the gate, which then rebuilt underneath it.
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on AuthCancelled {
      // User dismissed the Google sheet.
    } on AuthFailure catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _resetPassword() async {
    await _run(() async {
      await AuthService.instance.sendPasswordReset(_email.text);
      _toast('Password reset link sent to ${_email.text.trim()}');
    });
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Welcome back',
      subtitle: 'Sign in to scan and export exam results.',
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
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _run(
            () => AuthService.instance
                .signIn(email: _email.text, password: _password.text),
          ),
          trailing: IconButton(
            icon: Icon(
              _showPassword ? Icons.visibility_off : Icons.visibility,
            ),
            onPressed: () => setState(() => _showPassword = !_showPassword),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _busy ? null : _resetPassword,
            child: const Text('Forgot password?'),
          ),
        ),
      ],
      primaryLabel: 'Sign in',
      onPrimary: () => _run(
        () => AuthService.instance
            .signIn(email: _email.text, password: _password.text),
      ),
      onGoogle: () => _run(AuthService.instance.signInWithGoogle),
      footerText: 'Not a member? ',
      footerAction: 'Register now',
      onFooter: widget.onTap,
    );
  }
}
