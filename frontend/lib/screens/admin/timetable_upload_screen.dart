import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
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
        _errorMessage = 'Could not load colleges: $e';
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

  void _back() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Upload Timetable')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_errorMessage != null) _buildErrorBanner(),
            _buildDetailsForm(),
            const SizedBox(height: 24),
            if (_preview == null) ...[
              _buildInputSection(),
              const SizedBox(height: 24),
              _buildParseButton(),
            ] else
              _buildPreview(),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorBanner() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          _errorMessage!,
          style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
        ),
      ),
    );
  }

  Widget _buildDetailsForm() {
    final locked = _preview != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Timetable details', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
          controller: _courseController,
          enabled: !locked,
          decoration: const InputDecoration(
            labelText: 'Course',
            hintText: 'e.g. Physics Hons',
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<int>(
          value: _selectedYear,
          decoration: const InputDecoration(labelText: 'Year'),
          items: const [1, 2, 3]
              .map((y) => DropdownMenuItem(value: y, child: Text('Year $y')))
              .toList(),
          onChanged: locked ? null : (v) => setState(() => _selectedYear = v),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _sectionController,
          enabled: !locked,
          decoration: const InputDecoration(
            labelText: 'Section',
            hintText: 'e.g. B',
          ),
        ),
        const SizedBox(height: 12),
        if (_loadingColleges)
          const LinearProgressIndicator()
        else
          DropdownButtonFormField<String>(
            value: _selectedCollegeId,
            decoration: const InputDecoration(labelText: 'College'),
            items: _colleges
                .map(
                  (c) => DropdownMenuItem<String>(
                    value: c['id'] as String,
                    child: Text((c['name'] as String?) ?? c['id'] as String),
                  ),
                )
                .toList(),
            onChanged: locked ? null : (v) => setState(() => _selectedCollegeId = v),
          ),
      ],
    );
  }

  Widget _buildInputSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Timetable source', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<_InputMode>(
          segments: const [
            ButtonSegment(
              value: _InputMode.file,
              label: Text('Upload file'),
              icon: Icon(Icons.upload_file),
            ),
            ButtonSegment(
              value: _InputMode.text,
              label: Text('Paste text'),
              icon: Icon(Icons.text_snippet),
            ),
          ],
          selected: {_inputMode},
          onSelectionChanged: (selection) {
            setState(() {
              _inputMode = selection.first;
              // enforce "pick one" — clear the other input when switching
              if (_inputMode == _InputMode.file) {
                _textController.clear();
              } else {
                _pickedFile = null;
              }
            });
          },
        ),
        const SizedBox(height: 12),
        if (_inputMode == _InputMode.file)
          OutlinedButton.icon(
            onPressed: _pickFile,
            icon: const Icon(Icons.attach_file),
            label: Text(
              _pickedFile == null ? 'Choose file (.jpg, .png, .pdf)' : _pickedFile!.name,
              overflow: TextOverflow.ellipsis,
            ),
          )
        else
          TextField(
            controller: _textController,
            maxLines: 6,
            decoration: const InputDecoration(
              hintText: 'Paste timetable text here...',
              border: OutlineInputBorder(),
            ),
          ),
      ],
    );
  }

  Widget _buildParseButton() {
    return FilledButton(
      onPressed: _isParsing ? null : _parseTimetable,
      child: _isParsing
          ? const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 12),
                Text('Parsing with AI...'),
              ],
            )
          : const Text('Parse Timetable'),
    );
  }

  Widget _buildPreview() {
    final preview = _preview!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${preview.slots.length} slots parsed for ${preview.course} '
          'Year ${preview.year} Section ${preview.section}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('Day')),
              DataColumn(label: Text('Start Time')),
              DataColumn(label: Text('End Time')),
              DataColumn(label: Text('Subject')),
            ],
            rows: preview.slots
                .map(
                  (slot) => DataRow(
                    cells: [
                      DataCell(Text(_dayNames[slot.dayOfWeek])),
                      DataCell(Text(slot.startTime)),
                      DataCell(Text(slot.endTime)),
                      DataCell(Text(slot.subject ?? '—')),
                    ],
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'source_json_id: ${preview.sourceJsonId}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
        ),
        const SizedBox(height: 24),
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
              child: FilledButton(
                onPressed: _isSaving ? null : _confirmAndSave,
                child: _isSaving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Confirm & Save'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
