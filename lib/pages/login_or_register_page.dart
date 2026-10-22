import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'login_page.dart';
import 'register_page.dart';

/// Owns the login/register toggle.
///
/// Previously each page also pushed the other onto the navigator, so the two
/// mechanisms fought and the back stack grew a new page on every switch.
class LoginOrRegisterPage extends StatefulWidget {
  const LoginOrRegisterPage({super.key});

  @override
  State<LoginOrRegisterPage> createState() => _LoginOrRegisterPageState();
}

class _LoginOrRegisterPageState extends State<LoginOrRegisterPage> {
  bool _showLogin = true;

  void _toggle() => setState(() => _showLogin = !_showLogin);

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: AppMotion.normal,
      switchInCurve: AppMotion.curve,
      switchOutCurve: AppMotion.curve,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0.06, 0),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: _showLogin
          ? LoginPage(key: const ValueKey('login'), onTap: _toggle)
          : RegisterPage(key: const ValueKey('register'), onTap: _toggle),
    );
  }
}
