import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../../core/api_config.dart';
import '../../core/supabase_config.dart';

const int _maxFileBytes = 5 * 1024 * 1024;

// Matches the backend's parser convention (routers/timetables.py):
// 0=Sunday .. 6=Saturday. This is NOT the same convention timetable_slots
// stores internally (0=Monday) — that conversion happens server-side.
const List<String> _dayNames = [
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
];

/// Where a day falls in a Monday-first week, for display order only
/// (0=Monday..6=Sunday) — the API's own 0=Sunday convention is untouched.
int _weekOrder(int dayOfWeekSundayZero) => (dayOfWeekSundayZero + 6) % 7;

enum _InputMode { file, text }

class ParsedSlotPreview {
  final int dayOfWeek;
  final String startTime;
  final String endTime;
  final String? subject;

  ParsedSlotPreview({
    required this.dayOfWeek,
    required this.startTime,
    required this.endTime,
    this.subject,
  });

  factory ParsedSlotPreview.fromJson(Map<String, dynamic> json) {
    return ParsedSlotPreview(
      dayOfWeek: json['day_of_week'] as int,
      startTime: json['start_time'] as String,
      endTime: json['end_time'] as String,
      subject: json['subject'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'day_of_week': dayOfWeek,
        'start_time': startTime,
        'end_time': endTime,
        'subject': subject,
      };
}

class TimetablePreview {
  final String course;
  final int year;
  final String section;
  final List<ParsedSlotPreview> slots;
  final String sourceJsonId;

  TimetablePreview({
    required this.course,
    required this.year,
    required this.section,
    required this.slots,
    required this.sourceJsonId,
  });

  factory TimetablePreview.fromJson(Map<String, dynamic> json) {
    return TimetablePreview(
      course: json['course'] as String,
      year: json['year'] as int,
      section: json['section'] as String,
      slots: (json['parsed_slots'] as List)
          .map((e) => ParsedSlotPreview.fromJson(e as Map<String, dynamic>))
          .toList(),
      sourceJsonId: json['source_json_id'] as String,
    );
  }

  /// Slots grouped by day and sorted for display: Monday-first week order,
  /// then by start time within each day.
  List<MapEntry<int, List<ParsedSlotPreview>>> get groupedByDay {
    final byDay = <int, List<ParsedSlotPreview>>{};
    for (final slot in slots) {
      byDay.putIfAbsent(slot.dayOfWeek, () => []).add(slot);
    }
    for (final daySlots in byDay.values) {
      daySlots.sort((a, b) => a.startTime.compareTo(b.startTime));
    }
    final entries = byDay.entries.toList()
      ..sort((a, b) => _weekOrder(a.key).compareTo(_weekOrder(b.key)));
    return entries;
  }
}

/// Lets an admin upload a timetable (image, PDF, or pasted text), preview
/// what Claude parsed out of it, and confirm before it's written to
/// `sections` / `timetable_slots`.
///
/// The Course/Year/Section fields above the upload area are admin-filled
/// hints for their own reference (compare against the parsed result below)
/// — they are NOT sent to the backend. The backend determines course,
/// year, and section by having Claude read the uploaded content itself
/// (see POST /api/timetables/upload), so what's saved is whatever it
/// parsed, not what's typed here.
class TimetableUploadScreen extends StatefulWidget {
  const TimetableUploadScreen({super.key});

  @override
  State<TimetableUploadScreen> createState() => _TimetableUploadScreenState();
}

class _TimetableUploadScreenState extends State<TimetableUploadScreen> {
  final _courseController = TextEditingController();
  final _sectionController = TextEditingController();
  final _textController = TextEditingController();

  int? _selectedYear;
  String? _selectedCollegeId;
  List<Map<String, dynamic>> _colleges = [];
  bool _loadingColleges = true;
  String? _collegesError;

  _InputMode _inputMode = _InputMode.file;
  PlatformFile? _pickedFile;

  bool _isParsing = false;
  bool _isSaving = false;
  String? _errorMessage;
  TimetablePreview? _preview;

  @override
  void initState() {
    super.initState();
    _loadColleges();
  }

  @override
  void dispose() {
    _courseController.dispose();
    _sectionController.dispose();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _loadColleges() async {
    setState(() {
      _loadingColleges = true;
      _collegesError = null;
    });
    try {
      final rows =
          await supabase.from('colleges').select('id, name').order('name', ascending: true);
      if (!mounted) return;
      setState(() {
        _colleges = List<Map<String, dynamic>>.from(rows);
        _loadingColleges = false;
        // TODO: default this to the logged-in admin's own college once a
        // user-profile fetch (users -> college_id) exists, instead of
        // leaving it for them to pick every time.
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingColleges = false;
        _collegesError = 'Could not load colleges: $e';
      });
    }
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'pdf'],
      withData: true, // required for web, where there is no filesystem path
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    if (file.size > _maxFileBytes) {
      setState(() => _errorMessage = 'File too large. Max 5MB.');
      return;
    }

    setState(() {
      _pickedFile = file;
      _errorMessage = null;
    });
  }

  MediaType _mediaTypeFor(String? extension) {
    switch (extension?.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return MediaType('image', 'jpeg');
      case 'png':
        return MediaType('image', 'png');
      case 'pdf':
        return MediaType('application', 'pdf');
      default:
        return MediaType('application', 'octet-stream');
    }
  }

  String? _validate() {
    if (_courseController.text.trim().isEmpty ||
        _selectedYear == null ||
        _sectionController.text.trim().isEmpty) {
      return 'Course, year, and section are required.';
    }
    if (_selectedCollegeId == null) {
      return 'Please select a college.';
    }

    final hasFile = _pickedFile != null;
    final hasText = _textController.text.trim().isNotEmpty;
    if (!hasFile && !hasText) {
      return 'Upload a file or paste timetable text.';
    }
    if (hasFile && hasText) {
      return 'Provide either a file or pasted text, not both.';
    }
    if (hasFile && _pickedFile!.size > _maxFileBytes) {
      return 'File too large. Max 5MB.';
    }
    return null;
  }

  String _extractErrorMessage(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final detail = decoded['detail'];
        if (detail is String) return detail;
        if (detail is Map) {
          final error = detail['error'];
          final reason = detail['reason'];
          if (error != null) {
            return reason != null ? '$error: $reason' : '$error';
          }
        }
        if (detail is List && detail.isNotEmpty) {
          // FastAPI's default request-validation shape:
          // {"detail": [{"loc": [...], "msg": "...", ...}, ...]}
          final messages = detail
              .map((e) => e is Map ? e['msg']?.toString() : e.toString())
              .whereType<String>()
              .toList();
          if (messages.isNotEmpty) return messages.join('; ');
        }
      }
    } catch (_) {
      // not JSON — fall through to the raw body below
    }
    return response.body.isNotEmpty
        ? response.body
        : 'Request failed (${response.statusCode})';
  }

  Future<void> _parseTimetable() async {
    final validationError = _validate();
    if (validationError != null) {
      setState(() => _errorMessage = validationError);
      return;
    }

    setState(() {
      _isParsing = true;
      _errorMessage = null;
      _preview = null;
    });

    try {
      final uri = Uri.parse('${ApiConfig.baseUrl}/timetables/upload');
      final request = http.MultipartRequest('POST', uri)
        ..fields['college_id'] = _selectedCollegeId!
        ..fields['dry_run'] = 'true';

      if (_pickedFile != null) {
        final bytes = _pickedFile!.bytes;
        if (bytes == null) {
          throw Exception('Could not read the selected file.');
        }
        request.files.add(
          http.MultipartFile.fromBytes(
            'file',
            bytes,
            filename: _pickedFile!.name,
            contentType: _mediaTypeFor(_pickedFile!.extension),
          ),
        );
      } else {
        request.fields['text'] = _textController.text.trim();
      }

      final token = supabase.auth.currentSession?.accessToken;
      if (token != null) {
        request.headers['Authorization'] = 'Bearer $token';
      }

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (!mounted) return;

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() => _preview = TimetablePreview.fromJson(json));
      } else {
        setState(() => _errorMessage = _extractErrorMessage(response));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Parse failed: $e');
    } finally {
      if (mounted) setState(() => _isParsing = false);
    }
  }

  Future<void> _confirmAndSave() async {
    final preview = _preview;
    if (preview == null || _selectedCollegeId == null) return;

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
          'course': preview.course,
          'year': preview.year,
          'section': preview.section,
          'slots': preview.slots.map((s) => s.toJson()).toList(),
          'source_json_id': preview.sourceJsonId,
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
        setState(() => _errorMessage = 'Save failed: ${_extractErrorMessage(response)}');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Save failed: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _editAgain() => setState(() => _preview = null);

  void _back() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Upload Timetable')),
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
                        _buildErrorBanner(),
                        const SizedBox(height: 16),
                      ],
                      _sectionCard(
                        step: 1,
                        title: 'Timetable details',
                        subtitle: 'For your reference — the AI reads these from the upload itself.',
                        child: _buildDetailsForm(),
                      ),
                      const SizedBox(height: 16),
                      if (_preview == null) ...[
                        _sectionCard(
                          step: 2,
                          title: 'Timetable source',
                          subtitle: 'Upload a file or paste the timetable as text.',
                          child: _buildInputSection(),
                        ),
                        const SizedBox(height: 20),
                        _buildParseButton(),
                      ] else ...[
                        _sectionCard(
                          step: 2,
                          title: 'Review parsed timetable',
                          subtitle: null,
                          trailing: TextButton.icon(
                            onPressed: _isSaving ? null : _editAgain,
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            label: const Text('Edit'),
                          ),
                          child: _buildPreview(),
                        ),
                      ],
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

  Widget _buildErrorBanner() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: scheme.onErrorContainer, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _errorMessage!,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
          InkWell(
            onTap: () => setState(() => _errorMessage = null),
            borderRadius: BorderRadius.circular(16),
            child: Icon(Icons.close, color: scheme.onErrorContainer, size: 18),
          ),
        ],
      ),
    );
  }

  /// A numbered section card — gives the form a step-by-step feel without a
  /// full wizard/stepper widget.
  Widget _sectionCard({
    required int step,
    required String title,
    String? subtitle,
    Widget? trailing,
    required Widget child,
  }) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 13,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Text(
                    '$step',
                    style: TextStyle(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
                if (trailing != null) trailing,
              ],
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 38),
                child: Text(
                  subtitle,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }

  Widget _buildDetailsForm() {
    final locked = _preview != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _courseController,
          enabled: !locked,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Course',
            hintText: 'e.g. Physics Hons',
            prefixIcon: Icon(Icons.school_outlined),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: _selectedYear,
                decoration: const InputDecoration(
                  labelText: 'Year',
                  prefixIcon: Icon(Icons.numbers),
                ),
                items: const [1, 2, 3]
                    .map((y) => DropdownMenuItem(value: y, child: Text('Year $y')))
                    .toList(),
                onChanged: locked ? null : (v) => setState(() => _selectedYear = v),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _sectionController,
                enabled: !locked,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Section',
                  hintText: 'e.g. B',
                  prefixIcon: Icon(Icons.class_outlined),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _buildCollegeField(locked),
      ],
    );
  }

  Widget _buildCollegeField(bool locked) {
    if (_loadingColleges) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('Loading colleges...'),
          ],
        ),
      );
    }

    if (_collegesError != null) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _collegesError!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            TextButton(onPressed: _loadColleges, child: const Text('Retry')),
          ],
        ),
      );
    }

    return DropdownButtonFormField<String>(
      initialValue: _selectedCollegeId,
      decoration: const InputDecoration(
        labelText: 'College',
        prefixIcon: Icon(Icons.location_city_outlined),
      ),
      isExpanded: true,
      items: _colleges
          .map(
            (c) => DropdownMenuItem<String>(
              value: c['id'] as String,
              child: Text(
                (c['name'] as String?) ?? c['id'] as String,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
          .toList(),
      onChanged: locked ? null : (v) => setState(() => _selectedCollegeId = v),
    );
  }

  Widget _buildInputSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<_InputMode>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: _InputMode.file,
              label: Text('Upload file'),
              icon: Icon(Icons.upload_file_outlined),
            ),
            ButtonSegment(
              value: _InputMode.text,
              label: Text('Paste text'),
              icon: Icon(Icons.text_snippet_outlined),
            ),
          ],
          selected: {_inputMode},
          onSelectionChanged: (selection) {
            setState(() {
              _inputMode = selection.first;
              _errorMessage = null;
              // enforce "pick one" — clear the other input when switching
              if (_inputMode == _InputMode.file) {
                _textController.clear();
              } else {
                _pickedFile = null;
              }
            });
          },
        ),
        const SizedBox(height: 14),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          child: _inputMode == _InputMode.file
              ? _buildFilePicker(key: const ValueKey('file'))
              : TextField(
                  key: const ValueKey('text'),
                  controller: _textController,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    hintText: 'Paste timetable text here...',
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
      return InkWell(
        key: key,
        onTap: _pickFile,
        borderRadius: BorderRadius.circular(12),
        child: DottedBorderBox(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Column(
              children: [
                Icon(Icons.cloud_upload_outlined, size: 32, color: theme.colorScheme.primary),
                const SizedBox(height: 8),
                Text('Tap to choose a file', style: theme.textTheme.bodyMedium),
                const SizedBox(height: 2),
                Text(
                  '.jpg, .png, or .pdf — max 5MB',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
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
          Icon(_iconForFile(_pickedFile!.extension), color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _pickedFile!.name,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  _formatBytes(_pickedFile!.size),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Choose a different file',
            onPressed: _pickFile,
            icon: const Icon(Icons.swap_horiz),
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

  IconData _iconForFile(String? extension) {
    switch (extension?.toLowerCase()) {
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      default:
        return Icons.image_outlined;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Widget _buildParseButton() {
    return FilledButton.icon(
      onPressed: _isParsing ? null : _parseTimetable,
      icon: _isParsing
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            )
          : const Icon(Icons.auto_awesome),
      label: Text(_isParsing ? 'Parsing with AI...' : 'Parse Timetable'),
      style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
    );
  }

  Widget _buildPreview() {
    final preview = _preview!;
    final grouped = preview.groupedByDay;
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
                      '${preview.slots.length} slot${preview.slots.length == 1 ? '' : 's'} parsed',
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '${preview.course} · Year ${preview.year} · Section ${preview.section}',
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
        if (grouped.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                'No time slots were found. Try a clearer photo, or paste the\n'
                'timetable as text instead.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          )
        else
          ...grouped.map((entry) => _buildDayGroup(entry.key, entry.value)),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.tag, size: 14, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Flexible(
              child: SelectableText(
                preview.sourceJsonId,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontSize: 11),
              ),
            ),
            IconButton(
              tooltip: 'Copy id',
              iconSize: 14,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: preview.sourceJsonId));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied id to clipboard'), duration: Duration(seconds: 1)),
                );
              },
            ),
          ],
        ),
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
                onPressed: _isSaving ? null : _confirmAndSave,
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

  Widget _buildDayGroup(int dayOfWeek, List<ParsedSlotPreview> slots) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              _dayNames[dayOfWeek],
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ...slots.map(
            (slot) => Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(Icons.schedule, size: 16, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 108,
                    child: Text(
                      '${slot.startTime} – ${slot.endTime}',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      slot.subject ?? 'Unlabeled',
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontStyle: slot.subject == null ? FontStyle.italic : FontStyle.normal,
                        color: slot.subject == null ? theme.colorScheme.onSurfaceVariant : null,
                      ),
                    ),
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

/// A lightweight dashed-border drop-zone look for the file picker tap
/// target, without pulling in an extra package just for this.
class DottedBorderBox extends StatelessWidget {
  const DottedBorderBox({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedBorderPainter(color: Theme.of(context).colorScheme.outlineVariant),
      child: child,
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      const Radius.circular(12),
    );
    final path = Path()..addRRect(rrect);
    final dashed = _dashPath(path, dashLength: 6, gapLength: 4);
    canvas.drawPath(dashed, paint);
  }

  Path _dashPath(Path source, {required double dashLength, required double gapLength}) {
    final dest = Path();
    for (final metric in source.computeMetrics()) {
      var distance = 0.0;
      var draw = true;
      while (distance < metric.length) {
        final length = draw ? dashLength : gapLength;
        if (draw) {
          dest.addPath(metric.extractPath(distance, distance + length), Offset.zero);
        }
        distance += length;
        draw = !draw;
      }
    }
    return dest;
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) => oldDelegate.color != color;
}
