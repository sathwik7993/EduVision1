import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:eduvision_0_1/pages/home_page.dart'; // Update with your project name
import 'package:eduvision_0_1/pages/login_page.dart'; // Update with your project name

class AuthPage extends StatelessWidget {
  const AuthPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            // Show a loading spinner while waiting for authentication state
            return const Center(child: CircularProgressIndicator());
          } else if (snapshot.hasError) {
            // Handle error in auth state
            return Center(
              child: Text('Error: ${snapshot.error}'),
            );
          } else if (snapshot.hasData) {
            // User is authenticated
            return const HomePage();
          } else {
            // User is not authenticated, show login page
            return LoginPage(
              onTap: () {
                // You can add navigation or any action here for the "Register now" button
                print('Register now pressed');
              },
            );
          }
        },
      ),
    );
  }
}
