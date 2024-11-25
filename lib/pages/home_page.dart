import 'package:eduvision_0_1/pages/login_page.dart';
import 'package:eduvision_0_1/pages/account_page.dart'; // Import the AccountPage here
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'scan_page.dart';
import 'my_sheets_page.dart'; // Import MySheetsPage here

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  void _openScanPage(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const ScanPage()),
    );
  }

  void _openMySheets(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const MySheetsPage()), // Navigate to MySheetsPage
    );
  }

  void _openAccount(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const AccountPage()), // Navigate to AccountPage
    );
  }

  Widget _buildFeatureCard({
    required String title,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.grey.withOpacity(0.1),
              spreadRadius: 0,
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(
              child: Center(
                child: Icon(
                  icon,
                  size: 64,
                  color: Colors.grey[800],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF2D3436),
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    User? user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      backgroundColor: Colors.grey[100], // Light grey background for contrast
      appBar: AppBar(
        title: const Text('Home'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              if (context.mounted) {
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(
                      builder: (context) => LoginPage(onTap: () {})),
                );
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              user != null ? 'Welcome, ${user.email}' : 'Welcome, Guest',
              style: const TextStyle(fontSize: 20),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: GridView.count(
                crossAxisCount: 2,
                mainAxisSpacing: 20,
                crossAxisSpacing: 20,
                children: [
                  _buildFeatureCard(
                    title: 'Scan Page',
                    icon: Icons.document_scanner,
                    onTap: () => _openScanPage(context),
                  ),
                  _buildFeatureCard(
                    title: 'My Sheets',
                    icon: Icons.table_chart,
                    onTap: () => _openMySheets(context), // Open MySheetsPage here
                  ),
                  _buildFeatureCard(
                    title: 'Account',
                    icon: Icons.account_circle,
                    onTap: () => _openAccount(context), // Navigate to AccountPage
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
