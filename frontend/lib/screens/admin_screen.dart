import 'package:flutter/material.dart';

import 'admin/timetable_upload_screen.dart';

/// TODO: club/event admin tools (create event, manage budget, etc). The
/// "Admin tools" list below is where those will live alongside timetable
/// upload as they're built.
class AdminScreen extends StatelessWidget {
  const AdminScreen({super.key});

  Future<void> _openTimetableUpload(BuildContext context) async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const TimetableUploadScreen()),
    );
    if (result != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(child: Text(result)),
            ],
          ),
          backgroundColor: Colors.green.shade700,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Admin')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Admin tools', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Club and event management tools for admins.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              leading: CircleAvatar(
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(Icons.upload_file, color: theme.colorScheme.onPrimaryContainer),
              ),
              title: const Text('Upload Timetable'),
              subtitle: const Text('Parse a section\'s timetable with AI and add it to the system'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openTimetableUpload(context),
            ),
          ),
        ],
      ),
    );
  }
}
