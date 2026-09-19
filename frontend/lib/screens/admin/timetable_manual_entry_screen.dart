import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/api_config.dart';
import '../../core/supabase_config.dart';
import 'timetable_common.dart';

/// Lets an admin build a timetable by hand — no AI, no Anthropic API key,
/// no per-upload cost. Posts straight to POST /api/timetables/confirm
/// (the same endpoint the AI-upload screen's "Confirm & Save" step uses),
/// skipping the Claude parse entirely.
class TimetableManualEntryScreen extends StatefulWidget {
  const TimetableManualEntryScreen({super.key});

  @override
  State<TimetableManualEntryScreen> createState() => _TimetableManualEntryScreenState();
}

class _TimetableManualEntryScreenState extends State<TimetableManualEntryScreen> {
  final _courseController = TextEditingController();
  final _sectionController = TextEditingController();
  final _subjectController = TextEditingController();

  int? _selectedYear;
  String? _selectedCollegeId;

  int _addDayOrder = 0; // Monday-first display index into dayOfWeekFromWeekOrder
  TimeOfDay? _addStartTime;
  TimeOfDay? _addEndTime;

  final List<TimetableSlot> _slots = [];

  bool _isSaving = false;
  String? _errorMessage;

  @override
  void dispose() {
    _courseController.dispose();
    _sectionController.dispose();
    _subjectController.dispose();
    super.dispose();
  }

  String _formatTimeOfDay(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _pickTime({required bool isStart}) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: (isStart ? _addStartTime : _addEndTime) ?? TimeOfDay.now(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _addStartTime = picked;
      } else {
        _addEndTime = picked;
      }
    });
  }

  void _addSlot() {
    final start = _addStartTime;
    final end = _addEndTime;
    if (start == null || end == null) {
      setState(() => _errorMessage = 'Pick a start and end time.');
      return;
    }
    final startStr = _formatTimeOfDay(start);
    final endStr = _formatTimeOfDay(end);
    if (endStr.compareTo(startStr) <= 0) {
      setState(() => _errorMessage = 'End time must be after start time.');
      return;
    }

    setState(() {
      _slots.add(
        TimetableSlot(
          dayOfWeek: dayOfWeekFromWeekOrder(_addDayOrder),
          startTime: startStr,
          endTime: endStr,
          subject: _subjectController.text.trim().isEmpty ? null : _subjectController.text.trim(),
        ),
      );
      _subjectController.clear();
      _addStartTime = null;
      _addEndTime = null;
      _errorMessage = null;
    });
  }

  void _removeSlot(TimetableSlot slot) => setState(() => _slots.remove(slot));

  String? _validate() {
    if (_courseController.text.trim().isEmpty ||
        _selectedYear == null ||
        _sectionController.text.trim().isEmpty) {
      return 'Course, year, and section are required.';
    }
    if (_selectedCollegeId == null) {
      return 'Please select a college.';
    }
    if (_slots.isEmpty) {
      return 'Add at least one time slot.';
    }
    return null;
  }

  Future<void> _saveTimetable() async {
    final validationError = _validate();
    if (validationError != null) {
      setState(() => _errorMessage = validationError);
      return;
    }

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
          'course': _courseController.text.trim(),
          'year': _selectedYear,
          'section': _sectionController.text.trim(),
          'slots': _slots.map((s) => s.toJson()).toList(),
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
      appBar: AppBar(title: const Text('Enter Timetable Manually')),
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
                        title: 'Timetable details',
                        subtitle: 'No AI involved — what you enter here is exactly what gets saved.',
                        child: _buildDetailsForm(),
                      ),
                      const SizedBox(height: 16),
                      SectionCard(
                        step: 2,
                        title: 'Time slots',
                        subtitle: '${_slots.length} slot${_slots.length == 1 ? '' : 's'} added',
                        child: _buildSlotsSection(),
                      ),
                      const SizedBox(height: 20),
                      _buildSaveButton(),
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

  Widget _buildDetailsForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _courseController,
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
                onChanged: (v) => setState(() => _selectedYear = v),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _sectionController,
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
        CollegeDropdownField(onChanged: (v) => setState(() => _selectedCollegeId = v)),
      ],
    );
  }

  Widget _buildSlotsSection() {
    final theme = Theme.of(context);
    final grouped = groupSlotsByDay(_slots);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<int>(
          initialValue: _addDayOrder,
          decoration: const InputDecoration(
            labelText: 'Day',
            prefixIcon: Icon(Icons.calendar_today_outlined),
          ),
          items: List.generate(7, (order) {
            final day = dayOfWeekFromWeekOrder(order);
            return DropdownMenuItem(value: order, child: Text(dayNames[day]));
          }),
          onChanged: (v) => setState(() => _addDayOrder = v ?? 0),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pickTime(isStart: true),
                icon: const Icon(Icons.schedule_outlined, size: 18),
                label: Text(_addStartTime == null ? 'Start time' : _formatTimeOfDay(_addStartTime!)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pickTime(isStart: false),
                icon: const Icon(Icons.schedule_outlined, size: 18),
                label: Text(_addEndTime == null ? 'End time' : _formatTimeOfDay(_addEndTime!)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _subjectController,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Subject (optional)',
            hintText: 'e.g. Mechanics',
            prefixIcon: Icon(Icons.menu_book_outlined),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _addSlot,
          icon: const Icon(Icons.add),
          label: const Text('Add Slot'),
        ),
        const SizedBox(height: 16),
        if (grouped.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Text(
                'No slots added yet.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          )
        else
          ...grouped.map((entry) => _buildDayGroup(entry.key, entry.value)),
      ],
    );
  }

  Widget _buildDayGroup(int dayOfWeek, List<TimetableSlot> slots) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              dayNames[dayOfWeek],
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.bold),
            ),
          ),
          ...slots.map(
            (slot) => Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
                    child: Text('${slot.startTime} – ${slot.endTime}', style: theme.textTheme.bodyMedium),
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
                  IconButton(
                    tooltip: 'Remove slot',
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close),
                    onPressed: () => _removeSlot(slot),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSaveButton() {
    return FilledButton.icon(
      onPressed: _isSaving ? null : _saveTimetable,
      icon: _isSaving
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            )
          : const Icon(Icons.check),
      label: Text(_isSaving ? 'Saving...' : 'Save Timetable'),
      style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
    );
  }
}
