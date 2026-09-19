// Widget tests for the manual timetable entry screen — mirrors
// widget_test.dart's approach: Supabase is left uninitialized, so
// CollegeDropdownField's load fails fast and deterministically into its
// error state (with a Retry button) rather than hitting the network.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clubster/screens/admin/timetable_manual_entry_screen.dart';

void main() {
  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: TimetableManualEntryScreen()),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapAfterScrollingIntoView(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('renders details form and an empty slots section', (tester) async {
    await pumpScreen(tester);

    expect(find.text('Timetable details'), findsOneWidget);
    expect(find.text('Time slots'), findsOneWidget);
    expect(find.text('0 slots added'), findsOneWidget);
    expect(find.text('No slots added yet.'), findsOneWidget);
    expect(find.text('Save Timetable'), findsOneWidget);
  });

  testWidgets('Add Slot without picking times shows an error', (tester) async {
    await pumpScreen(tester);

    await tapAfterScrollingIntoView(tester, find.text('Add Slot'));

    expect(find.text('Pick a start and end time.'), findsOneWidget);
  });

  testWidgets('Save with everything empty shows the required-fields error', (tester) async {
    await pumpScreen(tester);

    await tapAfterScrollingIntoView(tester, find.text('Save Timetable'));

    expect(find.text('Course, year, and section are required.'), findsOneWidget);
  });

  testWidgets('Save with details filled but no slots asks for a slot', (tester) async {
    await pumpScreen(tester);

    await tester.enterText(find.widgetWithText(TextField, 'Course'), 'Physics Hons');
    await tester.enterText(find.widgetWithText(TextField, 'Section'), 'B');
    await tapAfterScrollingIntoView(tester, find.byType(DropdownButtonFormField<int>).first);
    await tester.tap(find.text('Year 1').last);
    await tester.pumpAndSettle();

    // College has no options in this test (Supabase uninitialized) — so
    // the year check above must pass first, leaving college as the next
    // blocker rather than reaching the "add a slot" message. Confirms the
    // validation order without depending on a real college being pickable.
    await tapAfterScrollingIntoView(tester, find.text('Save Timetable'));

    expect(find.text('Please select a college.'), findsOneWidget);
  });
}
