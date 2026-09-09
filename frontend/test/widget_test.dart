// Widget tests for the admin timetable upload screen.
//
// These deliberately never initialize Supabase or hit the network:
// Supabase.instance throws when uninitialized, and
// TimetableUploadScreen._loadColleges() catches that (like any other
// college-load failure) and settles into its error state with a Retry
// button — so these tests exercise real widget rendering and the client-
// side validation logic without any I/O, and stay fast and deterministic.
//
// The form is taller than the default 800x600 test surface, so most taps
// go through `tapAfterScrollingIntoView` rather than a bare `tester.tap` —
// on a real device this is just an ordinary scroll, but a widget test
// won't auto-scroll for you before tapping.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clubster/screens/admin/timetable_upload_screen.dart';

void main() {
  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: TimetableUploadScreen()),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapAfterScrollingIntoView(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('renders the details form and source picker', (tester) async {
    await pumpScreen(tester);

    expect(find.text('Timetable details'), findsOneWidget);
    expect(find.text('Course'), findsOneWidget);
    expect(find.text('Year'), findsOneWidget);
    expect(find.text('Section'), findsOneWidget);
    expect(find.text('Timetable source'), findsOneWidget);
    expect(find.text('Parse Timetable'), findsOneWidget);

    // colleges failed to load (Supabase isn't initialized in this test) —
    // the screen should show that error state with a way to retry, not crash.
    expect(find.textContaining('Could not load colleges'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('tapping Parse with everything empty shows the required-fields error',
      (tester) async {
    await pumpScreen(tester);

    await tapAfterScrollingIntoView(tester, find.text('Parse Timetable'));

    expect(find.text('Course, year, and section are required.'), findsOneWidget);
  });

  testWidgets('with course/year/section filled but no college, asks to pick a college',
      (tester) async {
    await pumpScreen(tester);

    await tester.enterText(find.widgetWithText(TextField, 'Course'), 'Physics Hons');
    await tester.enterText(find.widgetWithText(TextField, 'Section'), 'B');

    await tapAfterScrollingIntoView(tester, find.byType(DropdownButtonFormField<int>));
    await tester.tap(find.text('Year 1').last);
    await tester.pumpAndSettle();

    // College's dropdown has no items in this test (load failed, no
    // network) — so it's the one field left unset, and that's the
    // validation message that should surface.
    await tapAfterScrollingIntoView(tester, find.text('Parse Timetable'));

    expect(find.text('Please select a college.'), findsOneWidget);
  });

  testWidgets('switching between file and text source swaps the input widget',
      (tester) async {
    await pumpScreen(tester);

    // defaults to file mode
    expect(find.text('Tap to choose a file'), findsOneWidget);
    expect(find.text('Paste timetable text here...'), findsNothing);

    await tapAfterScrollingIntoView(tester, find.text('Paste text'));

    expect(find.text('Tap to choose a file'), findsNothing);
    expect(find.text('Paste timetable text here...'), findsOneWidget);
  });

  testWidgets('Back button pops the screen', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const TimetableUploadScreen()),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Upload Timetable'), findsOneWidget);

    // Back button only appears once a preview exists — before that, the
    // AppBar's own back arrow is the way out.
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Upload Timetable'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });
}
