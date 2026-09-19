import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../core/api_config.dart';
import '../../core/supabase_config.dart';
import 'timetable_common.dart';

enum _JsonInputMode { file, paste }

/// Lets an admin get timetable JSON from an AI chatbot they already have
/// access to (ChatGPT, Gemini, Claude.ai, ...) — for free, in that tool's
/// own chat UI — then import the result here. No Anthropic API key, no
/// per-upload cost: this screen never calls any AI itself. It validates
/// the JSON locally and posts straight to POST /api/timetables/confirm,
/// same as the manual-entry screen.
class TimetableJsonImportScreen extends StatefulWidget {
  const TimetableJsonImportScreen({super.key});

  @override
  State<TimetableJsonImportScreen> createState() => _TimetableJsonImportScreenState();
}

class _TimetableJsonImportScreenState extends State<TimetableJsonImportScreen> {
  final _jsonTextController = TextEditingController();

  String? _selectedCollegeId;
  _JsonInputMode _inputMode = _JsonInputMode.file;
  PlatformFile? _pickedFile;

  bool _isSaving = false;
  String? _errorMessage;
  ImportedTimetable? _imported;

  @override
  void dispose() {
    _jsonTextController.dispose();
    super.dispose();
  }

  Future<void> _pickJsonFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true, // required for web, where there is no filesystem path
    );
    if (result == null || result.files.isEmpty) return;

    setState(() {
      _pickedFile = result.files.single;
      _errorMessage = null;
    });
  }

  void _copyPrompt() {
    Clipboard.setData(const ClipboardData(text: externalAiPrompt));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Prompt copied — paste it into your AI chat'), duration: Duration(seconds: 2)),
    );
  }

  Future<void> _loadJson() async {
    if (_selectedCollegeId == null) {
      setState(() => _errorMessage = 'Please select a college.');
      return;
    }

    final hasFile = _pickedFile != null;
    final hasText = _jsonTextController.text.trim().isNotEmpty;
    if (!hasFile && !hasText) {
      setState(() => _errorMessage = 'Choose a .json file or paste the JSON text.');
      return;
    }
    if (hasFile && hasText) {
      setState(() => _errorMessage = 'Provide either a file or pasted JSON, not both.');
      return;
    }

    setState(() => _errorMessage = null);

    try {
      String raw;
      if (_pickedFile != null) {
        final bytes = _pickedFile!.bytes;
        if (bytes == null) {
          throw Exception('Could not read the selected file.');
        }
        raw = utf8.decode(bytes);
      } else {
        raw = _jsonTextController.text.trim();
      }

      final imported = parseTimetableJson(raw);
      setState(() => _imported = imported);
    } on TimetableJsonFormatException catch (e) {
      setState(() => _errorMessage = e.message);
    } catch (e) {
      setState(() => _errorMessage = 'Could not read that JSON: $e');
    }
  }

  void _editAgain() => setState(() => _imported = null);

  void _back() => Navigator.of(context).pop();

  Future<void> _saveTimetable() async {
    final imported = _imported;
    if (imported == null || _selectedCollegeId == null) return;

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      final uri = Uri.parse('${ApiConfig.baseUrl}/timetables/confirm');
      final token = supabase.auth.currentSession?.accessToken;

      final response = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'college_id': _selectedCollegeId,
          'course': imported.course,
          'year': imported.year,
          'section': imported.section,
          'slots': imported.slots.map((s) => s.toJson()).toList(),
        }),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        Navigator.of(context).pop(
          'Timetable saved: ${json['sections_created']} section(s) created, '
          '${json['slots_inserted']} slot(s) inserted.',
        );
      } else {
        setState(() => _errorMessage = 'Save failed: ${extractHttpErrorMessage(response)}');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Save failed: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Import Timetable JSON')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 720;
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: isWide ? 640 : double.infinity),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_errorMessage != null) ...[
                        ErrorBanner(
                          message: _errorMessage!,
                          onDismiss: () => setState(() => _errorMessage = null),
                        ),
                        const SizedBox(height: 16),
                      ],
                      SectionCard(
                        step: 1,
                        title: 'Get JSON from an AI chatbot',
                        subtitle: 'Free — uses an AI tool you already have access to, not this app.',
                        child: _buildPromptSection(),
                      ),
                      const SizedBox(height: 16),
                      SectionCard(
                        step: 2,
                        title: 'College',
                        child: CollegeDropdownField(
                          enabled: _imported == null,
                          initialValue: _selectedCollegeId,
                          onChanged: (v) => setState(() => _selectedCollegeId = v),
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (_imported == null) ...[
                        SectionCard(
                          step: 3,
                          title: 'Import JSON',
                          subtitle: 'Upload the .json file, or paste what the AI returned.',
                          child: _buildImportSection(),
                        ),
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          onPressed: _loadJson,
                          icon: const Icon(Icons.playlist_add_check),
                          label: const Text('Load JSON'),
                          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                        ),
                      ] else
                        SectionCard(
                          step: 3,
                          title: 'Review timetable',
                          trailing: TextButton.icon(
                            onPressed: _isSaving ? null : _editAgain,
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            label: const Text('Edit'),
                          ),
                          child: _buildReview(),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildPromptSection() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '1. Open ChatGPT, Gemini, or Claude.\n'
          '2. Upload your timetable photo and paste this prompt.\n'
          '3. Copy the JSON it replies with.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        Container(
          constraints: const BoxConstraints(maxHeight: 160),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              externalAiPrompt,
              style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _copyPrompt,
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copy Prompt'),
        ),
      ],
    );
  }

  Widget _buildImportSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<_JsonInputMode>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: _JsonInputMode.file,
              label: Text('Upload .json'),
              icon: Icon(Icons.upload_file_outlined),
            ),
            ButtonSegment(
              value: _JsonInputMode.paste,
              label: Text('Paste JSON'),
              icon: Icon(Icons.content_paste),
            ),
          ],
          selected: {_inputMode},
          onSelectionChanged: (selection) {
            setState(() {
              _inputMode = selection.first;
              _errorMessage = null;
              if (_inputMode == _JsonInputMode.file) {
                _jsonTextController.clear();
              } else {
                _pickedFile = null;
              }
            });
          },
        ),
        const SizedBox(height: 14),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          child: _inputMode == _JsonInputMode.file
              ? _buildFilePicker(key: const ValueKey('file'))
              : TextField(
                  key: const ValueKey('paste'),
                  controller: _jsonTextController,
                  maxLines: 8,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  decoration: const InputDecoration(
                    hintText: 'Paste the JSON here...',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildFilePicker({Key? key}) {
    final theme = Theme.of(context);
    if (_pickedFile == null) {
      return OutlinedButton.icon(
        key: key,
        onPressed: _pickJsonFile,
        icon: const Icon(Icons.attach_file),
        label: const Text('Choose .json file'),
      );
    }
    return Container(
      key: key,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.description_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _pickedFile!.name,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            tooltip: 'Remove file',
            onPressed: () => setState(() => _pickedFile = null),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  Widget _buildReview() {
    final imported = _imported!;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.fact_check_outlined, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${imported.slots.length} slot${imported.slots.length == 1 ? '' : 's'} imported',
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '${imported.course} · Year ${imported.year} · Section ${imported.section}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        DayGroupedSlots(slots: imported.slots),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _isSaving ? null : _back,
                child: const Text('Back'),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                onPressed: _isSaving ? null : _saveTimetable,
                icon: _isSaving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.check),
                label: Text(_isSaving ? 'Saving...' : 'Confirm & Save'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
