// Widget tests for the JSON-import screen — Supabase is left
// uninitialized (same approach as the other timetable screen tests), so
// the college load fails fast into its error/retry state without any
// network call.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clubster/screens/admin/timetable_json_import_screen.dart';

void main() {
  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: TimetableJsonImportScreen()),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders the prompt, college picker, and import section', (tester) async {
    await pumpScreen(tester);

    expect(find.text('Get JSON from an AI chatbot'), findsOneWidget);
    expect(find.text('Copy Prompt'), findsOneWidget);
    expect(find.text('College'), findsOneWidget);
    expect(find.text('Import JSON'), findsOneWidget);
    expect(find.text('Load JSON'), findsOneWidget);
  });

  testWidgets('Load JSON with nothing provided asks to select a college first', (tester) async {
    await pumpScreen(tester);

    await tester.ensureVisible(find.text('Load JSON'));
    await tester.tap(find.text('Load JSON'));
    await tester.pumpAndSettle();

    expect(find.text('Please select a college.'), findsOneWidget);
  });

  testWidgets('switching to paste mode shows a JSON text field', (tester) async {
    await pumpScreen(tester);

    expect(find.text('Choose .json file'), findsOneWidget);

    await tester.ensureVisible(find.text('Paste JSON'));
    await tester.tap(find.text('Paste JSON'));
    await tester.pumpAndSettle();

    expect(find.text('Choose .json file'), findsNothing);
    expect(find.text('Paste the JSON here...'), findsOneWidget);
  });
}
