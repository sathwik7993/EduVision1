// ignore_for_file: prefer_const_constructors

import 'package:eduvision_0_1/pages/login_page.dart';
import 'package:eduvision_0_1/pages/register_page.dart'; // Import RegisterPage here
import 'package:flutter/material.dart';

class LoginOrRegisterPage extends StatefulWidget {
  const LoginOrRegisterPage({super.key});

  @override
  State<LoginOrRegisterPage> createState() => _LoginOrRegisterPageState();
}

class _LoginOrRegisterPageState extends State<LoginOrRegisterPage> {
  // Initially show the login page
  bool showLoginPage = true;

  // Toggle between login and register page
  void togglePages() {
    setState(() {
      showLoginPage = !showLoginPage;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedSwitcher(
        duration: Duration(milliseconds: 300), // Smooth animation
        transitionBuilder: (Widget child, Animation<double> animation) {
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(1, 0), // Slide in from right
              end: Offset.zero,
            ).animate(animation),
            child: child,
          );
        },
        child: showLoginPage
            ? LoginPage(
                key: ValueKey<bool>(
                    showLoginPage), // Unique key for AnimatedSwitcher
                onTap: togglePages, // Toggle to RegisterPage
              )
            : RegisterPage(
                key: ValueKey<bool>(
                    showLoginPage), // Unique key for AnimatedSwitcher
                onTap: togglePages, // Toggle back to LoginPage
              ),
      ),
    );
  }
}
