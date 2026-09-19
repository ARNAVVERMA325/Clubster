// Shared pieces between the timetable-entry screens (AI upload, manual
// entry, JSON import) — they all end up building the same request shape
// for POST /api/timetables/confirm, and share the college picker, error
// handling, and day-grouped slot display.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/supabase_config.dart';

/// Matches the backend's day-of-week convention (routers/timetables.py):
/// 0=Sunday .. 6=Saturday. This is NOT the same convention timetable_slots
/// stores internally (0=Monday) — that conversion happens server-side in
/// core/timetable_inserter.py.
const List<String> dayNames = [
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
int weekOrder(int dayOfWeekSundayZero) => (dayOfWeekSundayZero + 6) % 7;

/// Inverse of [weekOrder]: given a Monday-first display position
/// (0=Monday..6=Sunday), returns the day-of-week value the API expects
/// (0=Sunday..6=Saturday).
int dayOfWeekFromWeekOrder(int order) => (order + 1) % 7;

class TimetableSlot {
  final int dayOfWeek;
  final String startTime;
  final String endTime;
  final String? subject;

  TimetableSlot({
    required this.dayOfWeek,
    required this.startTime,
    required this.endTime,
    this.subject,
  });

  factory TimetableSlot.fromJson(Map<String, dynamic> json) {
    return TimetableSlot(
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

/// Groups slots by day, sorted Monday-first, each day's slots sorted by
/// start time.
List<MapEntry<int, List<TimetableSlot>>> groupSlotsByDay(List<TimetableSlot> slots) {
  final byDay = <int, List<TimetableSlot>>{};
  for (final slot in slots) {
    byDay.putIfAbsent(slot.dayOfWeek, () => []).add(slot);
  }
  for (final daySlots in byDay.values) {
    daySlots.sort((a, b) => a.startTime.compareTo(b.startTime));
  }
  final entries = byDay.entries.toList()
    ..sort((a, b) => weekOrder(a.key).compareTo(weekOrder(b.key)));
  return entries;
}

/// Renders slots grouped by day (Monday-first) as compact rows. Pass
/// [trailingBuilder] to add a per-slot action (e.g. a delete button in the
/// manual-entry screen) — omit it for a read-only preview.
class DayGroupedSlots extends StatelessWidget {
  const DayGroupedSlots({
    super.key,
    required this.slots,
    this.trailingBuilder,
    this.emptyMessage = 'No time slots.',
  });

  final List<TimetableSlot> slots;
  final Widget Function(TimetableSlot slot)? trailingBuilder;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grouped = groupSlotsByDay(slots);

    if (grouped.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text(
            emptyMessage,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: grouped.map((entry) => _dayGroup(context, entry.key, entry.value)).toList(),
    );
  }

  Widget _dayGroup(BuildContext context, int dayOfWeek, List<TimetableSlot> daySlots) {
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
          ...daySlots.map(
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
                    child:
                        Text('${slot.startTime} – ${slot.endTime}', style: theme.textTheme.bodyMedium),
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
                  if (trailingBuilder != null) trailingBuilder!(slot),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final RegExp _timePattern = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');

class ImportedTimetable {
  final String course;
  final int year;
  final String section;
  final List<TimetableSlot> slots;

  ImportedTimetable({
    required this.course,
    required this.year,
    required this.section,
    required this.slots,
  });
}

/// Thrown by [parseTimetableJson] with a specific, user-facing message
/// naming exactly what's wrong with the JSON.
class TimetableJsonFormatException implements Exception {
  TimetableJsonFormatException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Validates and parses timetable JSON produced by an external AI chatbot
/// (ChatGPT, Gemini, Claude, ...) using [externalAiPrompt] — the same
/// shape and day-of-week convention (0=Sunday..6=Saturday) as the
/// backend's own Claude-powered parser
/// (routers/timetables.py's CUSTOM_TIMETABLE_PROMPT). Throws
/// [TimetableJsonFormatException] on the first problem found.
ImportedTimetable parseTimetableJson(String raw) {
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    throw TimetableJsonFormatException("That's not valid JSON.");
  }

  if (decoded is! Map<String, dynamic>) {
    throw TimetableJsonFormatException(
      'Expected a JSON object with course/year/section/slots.',
    );
  }

  final course = decoded['course'];
  if (course is! String || course.trim().isEmpty) {
    throw TimetableJsonFormatException('"course" must be a non-empty string.');
  }

  final year = decoded['year'];
  if (year is! int) {
    throw TimetableJsonFormatException('"year" must be a whole number.');
  }

  final section = decoded['section'];
  if (section is! String || section.trim().isEmpty) {
    throw TimetableJsonFormatException('"section" must be a non-empty string.');
  }

  final rawSlots = decoded['slots'];
  if (rawSlots is! List) {
    throw TimetableJsonFormatException('"slots" must be a list.');
  }

  final slots = <TimetableSlot>[];
  for (var i = 0; i < rawSlots.length; i++) {
    final entry = rawSlots[i];
    if (entry is! Map<String, dynamic>) {
      throw TimetableJsonFormatException('slots[$i] must be a JSON object.');
    }

    final dayOfWeek = entry['day_of_week'];
    if (dayOfWeek is! int || dayOfWeek < 0 || dayOfWeek > 6) {
      throw TimetableJsonFormatException(
        'slots[$i].day_of_week must be a number 0-6 (0=Sunday).',
      );
    }

    final startTime = entry['start_time'];
    if (startTime is! String || !_timePattern.hasMatch(startTime)) {
      throw TimetableJsonFormatException(
        'slots[$i].start_time must be a 24-hour time like "09:00".',
      );
    }

    final endTime = entry['end_time'];
    if (endTime is! String || !_timePattern.hasMatch(endTime)) {
      throw TimetableJsonFormatException(
        'slots[$i].end_time must be a 24-hour time like "10:00".',
      );
    }

    if (endTime.compareTo(startTime) <= 0) {
      throw TimetableJsonFormatException('slots[$i].end_time must be after start_time.');
    }

    final subject = entry['subject'];
    if (subject != null && subject is! String) {
      throw TimetableJsonFormatException('slots[$i].subject must be a string or null.');
    }

    slots.add(TimetableSlot(
      dayOfWeek: dayOfWeek,
      startTime: startTime,
      endTime: endTime,
      subject: subject as String?,
    ));
  }

  return ImportedTimetable(
    course: course.trim(),
    year: year,
    section: section.trim(),
    slots: slots,
  );
}

/// The exact prompt to paste into an external AI chatbot (ChatGPT, Gemini,
/// Claude, ...) alongside a timetable photo — identical to the backend's
/// own CUSTOM_TIMETABLE_PROMPT (routers/timetables.py) so the JSON it
/// returns is guaranteed compatible with [parseTimetableJson] and
/// POST /api/timetables/confirm.
const String externalAiPrompt = '''
You are a timetable parser for Delhi University colleges. Your job is to
extract class schedules from messy, handwritten, or formatted timetables
and return structured JSON.

Input: A timetable for one section (e.g., "Physics Hons, Section B, Year 1")

Output: A JSON object with this exact structure:
{
  "course": "Physics Hons",
  "year": 1,
  "section": "B",
  "slots": [
    {
      "day_of_week": 1,
      "start_time": "09:00",
      "end_time": "10:00",
      "subject": "Mechanics" or null if unlabeled
    },
    ...
  ]
}

Rules:
- day_of_week: 0=Sunday, 1=Monday, ..., 6=Saturday
- Times in 24-hour format (HH:MM)
- Ignore lunch breaks, assembly, holidays
- If a time slot is empty/free, do NOT include it
- If subject is unclear, use null
- Return ONLY valid JSON, no other text

Example input: "Mon 9-10 Mechanics, Tue 9-11 Practicals Lab, Wed 2-3 Tutorial"
Example output: {"course": "Physics Hons", "year": 1, "section": "B",
"slots": [{"day_of_week": 1, "start_time": "09:00", "end_time": "10:00",
"subject": "Mechanics"}, ...]}''';

/// Extracts a human-readable message from a non-200 backend response,
/// handling all the `detail` shapes the API can send: a plain string, the
/// `{"error", "reason"}` validation shape, or FastAPI's default
/// request-validation list shape.
String extractHttpErrorMessage(http.Response response) {
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

/// A dismissible error banner used by both timetable screens.
class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
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
          Expanded(child: Text(message, style: TextStyle(color: scheme.onErrorContainer))),
          InkWell(
            onTap: onDismiss,
            borderRadius: BorderRadius.circular(16),
            child: Icon(Icons.close, color: scheme.onErrorContainer, size: 18),
          ),
        ],
      ),
    );
  }
}

/// A numbered section card — gives a form a step-by-step feel without a
/// full wizard/stepper widget. Used by both timetable screens.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.step,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.child,
  });

  final int step;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
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
                Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
                if (trailing != null) trailing!,
              ],
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 38),
                child: Text(
                  subtitle!,
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
}

/// A College dropdown that loads its own options from Supabase (`colleges`
/// table) and manages its loading/error/retry state internally — used by
/// both timetable screens.
class CollegeDropdownField extends StatefulWidget {
  const CollegeDropdownField({
    super.key,
    required this.onChanged,
    this.initialValue,
    this.enabled = true,
  });

  final ValueChanged<String?> onChanged;
  final String? initialValue;
  final bool enabled;

  @override
  State<CollegeDropdownField> createState() => _CollegeDropdownFieldState();
}

class _CollegeDropdownFieldState extends State<CollegeDropdownField> {
  List<Map<String, dynamic>> _colleges = [];
  bool _loading = true;
  String? _error;
  String? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialValue;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows =
          await supabase.from('colleges').select('id, name').order('name', ascending: true);
      if (!mounted) return;
      setState(() {
        _colleges = List<Map<String, dynamic>>.from(rows);
        _loading = false;
        // TODO: default this to the logged-in admin's own college once a
        // user-profile fetch (users -> college_id) exists, instead of
        // leaving it for them to pick every time.
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load colleges: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 12),
            Text('Loading colleges...'),
          ],
        ),
      );
    }

    if (_error != null) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(child: Text(_error!, style: Theme.of(context).textTheme.bodySmall)),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }

    return DropdownButtonFormField<String>(
      initialValue: _selected,
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
      onChanged: widget.enabled
          ? (v) {
              setState(() => _selected = v);
              widget.onChanged(v);
            }
          : null,
    );
  }
}
