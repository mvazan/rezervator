import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/clubs_screen.dart';
import 'package:rezervator/features/admin/widgets/form_fields.dart';

/// Smoke test for the clubs admin list: renders for an admin, shows its
/// empty state, and the FAB opens the add dialog (never saved — that would
/// hit the RPC).
void main() {
  const admin = Profile(
    id: 'admin1',
    displayName: 'Správce',
    email: 'admin@example.com',
    role: Role.admin,
    status: ProfileStatus.approved,
  );

  const clubs = [
    Club(id: 'c1', name: 'Sokol Dlouhá Lhota', colorIndex: 1),
    Club(id: 'c2', name: 'Veverky', colorIndex: 2),
  ];

  // One ProviderScope per test: a second pumpWidget does not swap overrides.
  Widget app(List<Club> clubs) => ProviderScope(
        overrides: [
          myProfileProvider.overrideWith((ref) => Stream.value(admin)),
          clubsProvider.overrideWith((ref) => Stream.value(clubs)),
        ],
        child: const MaterialApp(home: ClubsScreen()),
      );

  testWidgets('renders the title and one row per club for an admin',
      (tester) async {
    await tester.pumpWidget(app(clubs));
    await tester.pumpAndSettle();

    expect(find.text('Oddíly'), findsOneWidget);
    expect(find.text('Sokol Dlouhá Lhota'), findsOneWidget);
    expect(find.text('Veverky'), findsOneWidget);
    expect(find.byType(ColorDot), findsNWidgets(2));
    expect(find.byIcon(Icons.delete_outline), findsNWidgets(2));
    expect(find.text('Zatím žádné oddíly.'), findsNothing);
  });

  testWidgets('shows the empty state without clubs', (tester) async {
    await tester.pumpWidget(app(const []));
    await tester.pumpAndSettle();

    expect(find.text('Oddíly'), findsOneWidget);
    expect(find.text('Zatím žádné oddíly.'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('the FAB opens the add dialog', (tester) async {
    await tester.pumpWidget(app(clubs));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.text('Přidat oddíl')),
      findsOneWidget,
    );
    expect(find.text('Název'), findsOneWidget);
    expect(find.text('Uložit'), findsOneWidget);

    await tester.tap(find.text('Zrušit'));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
  });

  testWidgets('an empty name is refused before anything is saved',
      (tester) async {
    await tester.pumpWidget(app(clubs));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    expect(find.text('Vyplň název oddílu.'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget); // still open
  });
}
