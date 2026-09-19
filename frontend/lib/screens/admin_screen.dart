import 'package:flutter/material.dart';

import 'admin/timetable_json_import_screen.dart';
import 'admin/timetable_manual_entry_screen.dart';
import 'admin/timetable_upload_screen.dart';

/// TODO: club/event admin tools (create event, manage budget, etc). The
/// "Admin tools" list below is where those will live alongside the
/// timetable tools as they're built.
class AdminScreen extends StatelessWidget {
  const AdminScreen({super.key});

  Future<void> _openScreen(BuildContext context, Widget screen) async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => screen),
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
          _ToolTile(
            icon: Icons.auto_awesome,
            title: 'Upload Timetable',
            subtitle: 'Parse a section\'s timetable with AI and add it to the system',
            onTap: () => _openScreen(context, const TimetableUploadScreen()),
          ),
          const SizedBox(height: 12),
          _ToolTile(
            icon: Icons.content_paste_go,
            title: 'Import Timetable JSON',
            subtitle: 'Parse with ChatGPT/Gemini/Claude yourself, then import the JSON — free',
            onTap: () => _openScreen(context, const TimetableJsonImportScreen()),
          ),
          const SizedBox(height: 12),
          _ToolTile(
            icon: Icons.edit_calendar_outlined,
            title: 'Enter Timetable Manually',
            subtitle: 'Type in a section\'s time slots directly — no AI, free',
            onTap: () => _openScreen(context, const TimetableManualEntryScreen()),
          ),
        ],
      ),
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(icon, color: theme.colorScheme.onPrimaryContainer),
        ),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
