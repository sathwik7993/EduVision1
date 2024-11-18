import 'package:flutter/material.dart';
import 'sheet_manager.dart'; // Import the SheetManager class

class MySheetsPage extends StatelessWidget {
  const MySheetsPage({super.key});

  void _openExcelFile() {
    SheetManager.viewSheet();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Sheets'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.table_chart,
                size: 80,
                color: Colors.blue[700],
              ),
              const SizedBox(height: 20),
              const Text(
                'View your saved student exam data in the Excel sheet.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18.0,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _openExcelFile,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open Excel Sheet'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  textStyle: const TextStyle(fontSize: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
