import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/clubhouse_screen.dart';

/// The Klubovna hub: its two entries, the shell's trailing icons riding
/// along on the same header, and the shared HubMenu's list/grid breakpoint
/// (below vs at/above 840 dp).
void main() {
  // HomeShell always wraps its body in a Scaffold — reproduced here so the
  // hub's ListTiles/Cards find the Material ancestor they need, same as in
  // the real app.
  Widget app({List<Widget> trailing = const []}) => ProviderScope(
    overrides: [venuesProvider.overrideWith((ref) => Stream.value(const <Venue>[]))],
    child: MaterialApp(
      home: Scaffold(body: ClubhouseScreen(trailing: trailing)),
    ),
  );

  void narrow(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  void wide(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('shows the Výsledky and Kuželny entries with their subtitles', (
    tester,
  ) async {
    narrow(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Výsledky'), findsOneWidget);
    expect(find.text('Zápasy a výsledky našich týmů'), findsOneWidget);
    expect(find.text('Kuželny'), findsOneWidget);
    expect(find.text('Kontakty a vybavení kuželen'), findsOneWidget);
    expect(find.byIcon(Icons.scoreboard_outlined), findsOneWidget);
    expect(find.byIcon(Icons.location_on_outlined), findsOneWidget);
  });

  testWidgets('below 840 dp the hub renders a list', (tester) async {
    narrow(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.byType(ListView), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
    expect(find.byType(ListTile), findsNWidgets(2));
  });

  testWidgets('at 840 dp and above the hub renders a card grid', (
    tester,
  ) async {
    wide(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.byType(GridView), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
    expect(find.byType(Card), findsNWidgets(2));
  });

  testWidgets(
    'tapping Výsledky opens the real results screen, Kuželny opens the '
    'real venues screen',
    (tester) async {
      narrow(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Výsledky'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Výsledky'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Kuželny'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Kuželny'), findsOneWidget);
    },
  );

  testWidgets('the shell\'s trailing actions ride along on the header', (
    tester,
  ) async {
    narrow(tester);
    await tester.pumpWidget(app(trailing: const [Icon(Icons.person)]));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.person), findsOneWidget);
  });
}
