import 'package:flutter/material.dart';

import 'admin/timetable_upload_screen.dart';

/// TODO: club/event admin tools (create event, manage budget, etc).
class AdminScreen extends StatelessWidget {
  const AdminScreen({super.key});

  Future<void> _openTimetableUpload(BuildContext context) async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const TimetableUploadScreen()),
    );
    if (result != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Admin')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Admin — placeholder'),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.upload_file),
              label: const Text('Upload Timetable'),
              onPressed: () => _openTimetableUpload(context),
            ),
          ],
        ),
      ),
    );
  }
}
