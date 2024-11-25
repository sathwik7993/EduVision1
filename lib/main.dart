// ignore_for_file: unused_import, avoid_print, prefer_const_constructors

import 'package:eduvision_0_1/pages/auth_page.dart';
import 'package:eduvision_0_1/pages/home_page.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'firebase_options.dart'; // This is for Firebase initialization

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    print('Firebase initialized successfully.');
  } catch (e) {
    // Handle error during Firebase initialization
    print('Error initializing Firebase: $e');
  }

  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const AuthWrapper(), // Reference AuthWrapper to manage user sessions
    );
  }
}

/// AuthWrapper widget to handle user state
class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        // Check the authentication state
        if (snapshot.connectionState == ConnectionState.waiting) {
          // Display loading indicator while waiting
          return const Center(child: CircularProgressIndicator());
        } else if (snapshot.hasData) {
          // User is logged in
          return HomePage(); // Replace with your actual HomePage widget
        } else {
          // User is not logged in
          return const AuthPage(); // Your authentication page
        }
      },
    );
  }
}
