// Unit tests for parseTimetableJson — the client-side validator for JSON
// an admin gets from an external AI chatbot (ChatGPT/Gemini/Claude) and
// imports via TimetableJsonImportScreen. No widgets involved, so these
// run fast and cover every rejection path precisely.

import 'package:flutter_test/flutter_test.dart';

import 'package:clubster/screens/admin/timetable_common.dart';

const validJson = '''
{
  "course": "Physics Hons",
  "year": 1,
  "section": "B",
  "slots": [
    {"day_of_week": 1, "start_time": "09:00", "end_time": "10:00", "subject": "Mechanics"},
    {"day_of_week": 2, "start_time": "09:00", "end_time": "11:00", "subject": null}
  ]
}
''';

void main() {
  test('parses valid JSON into course/year/section/slots', () {
    final result = parseTimetableJson(validJson);

    expect(result.course, 'Physics Hons');
    expect(result.year, 1);
    expect(result.section, 'B');
    expect(result.slots, hasLength(2));
    expect(result.slots[0].dayOfWeek, 1);
    expect(result.slots[0].subject, 'Mechanics');
    expect(result.slots[1].subject, isNull);
  });

  test('rejects text that is not JSON at all', () {
    expect(
      () => parseTimetableJson('not json at all'),
      throwsA(isA<TimetableJsonFormatException>()),
    );
  });

  test('rejects a JSON array instead of an object', () {
    expect(
      () => parseTimetableJson('[1, 2, 3]'),
      throwsA(
        isA<TimetableJsonFormatException>().having(
          (e) => e.message,
          'message',
          contains('course/year/section/slots'),
        ),
      ),
    );
  });

  test('rejects a missing/empty course', () {
    const json = '{"course": "", "year": 1, "section": "B", "slots": []}';
    expect(
      () => parseTimetableJson(json),
      throwsA(
        isA<TimetableJsonFormatException>()
            .having((e) => e.message, 'message', contains('"course"')),
      ),
    );
  });

  test('rejects a non-integer year', () {
    const json = '{"course": "Physics", "year": "1", "section": "B", "slots": []}';
    expect(
      () => parseTimetableJson(json),
      throwsA(
        isA<TimetableJsonFormatException>().having((e) => e.message, 'message', contains('"year"')),
      ),
    );
  });

  test('rejects a day_of_week out of range', () {
    const json = '''
    {"course": "Physics", "year": 1, "section": "B", "slots": [
      {"day_of_week": 7, "start_time": "09:00", "end_time": "10:00"}
    ]}
    ''';
    expect(
      () => parseTimetableJson(json),
      throwsA(
        isA<TimetableJsonFormatException>()
            .having((e) => e.message, 'message', contains('day_of_week')),
      ),
    );
  });

  test('rejects a malformed time string', () {
    const json = '''
    {"course": "Physics", "year": 1, "section": "B", "slots": [
      {"day_of_week": 1, "start_time": "9:00", "end_time": "10:00"}
    ]}
    ''';
    expect(
      () => parseTimetableJson(json),
      throwsA(
        isA<TimetableJsonFormatException>()
            .having((e) => e.message, 'message', contains('start_time')),
      ),
    );
  });

  test('rejects end_time not after start_time', () {
    const json = '''
    {"course": "Physics", "year": 1, "section": "B", "slots": [
      {"day_of_week": 1, "start_time": "10:00", "end_time": "09:00"}
    ]}
    ''';
    expect(
      () => parseTimetableJson(json),
      throwsA(
        isA<TimetableJsonFormatException>()
            .having((e) => e.message, 'message', contains('after start_time')),
      ),
    );
  });

  test('rejects a non-string, non-null subject', () {
    const json = '''
    {"course": "Physics", "year": 1, "section": "B", "slots": [
      {"day_of_week": 1, "start_time": "09:00", "end_time": "10:00", "subject": 42}
    ]}
    ''';
    expect(
      () => parseTimetableJson(json),
      throwsA(
        isA<TimetableJsonFormatException>().having((e) => e.message, 'message', contains('subject')),
      ),
    );
  });

  test('accepts an empty slots list', () {
    const json = '{"course": "Physics", "year": 1, "section": "B", "slots": []}';
    final result = parseTimetableJson(json);
    expect(result.slots, isEmpty);
  });
}
