import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/slot_types_screen.dart';

/// Smoke test for the priority-slot types admin list: renders for an admin,
/// shows its empty state, and the FAB opens the add dialog with the lane
/// chips sized by the settings (never saved — that would hit the RPC).
void main() {
  const admin = Profile(
    id: 'admin1',
    displayName: 'Správce',
    email: 'admin@example.com',
    role: Role.admin,
    status: ProfileStatus.approved,
  );

  const settings = ScheduleSettings(
    laneCount: 4,
    trainingWeekdays: {1, 2, 4},
    bookingHorizonDays: 14,
    maxActiveReservations: 3,
  );

  const types = [
    PrioritySlotType(
      id: 't1',
      name: 'Zápas',
      isMatch: true,
      builtin: true,
    ),
    PrioritySlotType(id: 't2', name: 'Liga', colorIndex: 3, lanes: [1, 2]),
  ];

  // One ProviderScope per test: a second pumpWidget does not swap overrides.
  Widget app(List<PrioritySlotType> types) => ProviderScope(
        overrides: [
          myProfileProvider.overrideWith((ref) => Stream.value(admin)),
          slotTypesProvider.overrideWith((ref) => Stream.value(types)),
          settingsProvider.overrideWith((ref) => Stream.value(settings)),
        ],
        child: const MaterialApp(home: SlotTypesScreen()),
      );

  testWidgets('renders the title and one row per type for an admin',
      (tester) async {
    await tester.pumpWidget(app(types));
    await tester.pumpAndSettle();

    expect(find.text('Typy blokací'), findsOneWidget);
    expect(find.text('Zápas'), findsOneWidget);
    expect(find.text('celá kuželna · zápas (týmy + příprava drah)'),
        findsOneWidget);
    expect(find.text('Liga'), findsOneWidget);
    expect(find.text('dráhy 1, 2'), findsOneWidget);
    // Both are editable; only the non-builtin one can be deleted.
    expect(find.byIcon(Icons.edit_outlined), findsNWidgets(2));
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
  });

  testWidgets('shows the empty state without types', (tester) async {
    await tester.pumpWidget(app(const []));
    await tester.pumpAndSettle();

    expect(find.text('Typy blokací'), findsOneWidget);
    expect(find.text('Zatím žádné typy.'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('the FAB opens the add dialog; lane chips follow the settings',
      (tester) async {
    await tester.pumpWidget(app(types));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.text('Přidat typ')),
      findsOneWidget,
    );
    expect(find.text('Název'), findsOneWidget);
    expect(find.text('Celá kuželna'), findsOneWidget);
    expect(find.text('Dráha 1'), findsNothing); // whole alley by default

    await tester.tap(find.text('Celá kuželna'));
    await tester.pumpAndSettle();
    for (var lane = 1; lane <= 4; lane++) {
      expect(find.text('Dráha $lane'), findsOneWidget);
    }
    expect(find.text('Dráha 5'), findsNothing);

    await tester.tap(find.text('Zrušit'));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
  });

  testWidgets('an empty name is refused before anything is saved',
      (tester) async {
    await tester.pumpWidget(app(types));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    expect(find.text('Vyplň název.'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget); // still open
  });
}
