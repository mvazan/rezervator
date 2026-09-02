import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart' show today;
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/matches_screen.dart';

void main() {
  const admin = Profile(
    id: 'admin1',
    displayName: 'Správce',
    email: 'admin@example.com',
    role: Role.admin,
    status: ProfileStatus.approved,
  );
  const uklidType = PrioritySlotType(
    id: 't-uklid',
    name: 'Úklid před zápasem',
    builtin: true,
  );

  Widget app({List<PrioritySlot> slots = const []}) {
    return ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(admin)),
        prioritySlotsProvider.overrideWithValue(slots),
        slotTypesProvider.overrideWith(
          (ref) => Stream.value(const [PrioritySlot.fallbackMatchType]),
        ),
      ],
      child: const MaterialApp(home: MatchesScreen()),
    );
  }

  // One fixture per test: a second pumpWidget does not swap ProviderScope
  // overrides.
  testWidgets('lists matches newest first with their prep and away notes; '
      'úklid children and other blockages belong elsewhere', (tester) async {
    final soon = today().addDays(3);
    final later = today().addDays(10);
    await tester.pumpWidget(app(slots: [
      PrioritySlot(
        id: 'm1',
        date: soon,
        startsAt: const HourMinute(18, 0),
        endsAt: const HourMinute(21, 0),
        type: PrioritySlot.fallbackMatchType,
        homeTeam: 'KK Veverky',
        awayTeam: 'KK Slavoj',
        prepMinutes: 30,
      ),
      // m1's auto-managed úklid child — hidden.
      PrioritySlot(
        id: 'u1',
        date: soon,
        startsAt: const HourMinute(17, 30),
        endsAt: const HourMinute(18, 0),
        type: uklidType,
        parentId: 'm1',
      ),
      PrioritySlot(
        id: 'm2',
        date: later,
        startsAt: const HourMinute(10, 0),
        endsAt: const HourMinute(13, 0),
        type: PrioritySlot.fallbackMatchType,
        awayTeam: 'Sokol Lhota',
        isAway: true,
        description: 'odjezd v 8:00',
      ),
      // A manual blockage — the Výjimky dnů screen's business.
      PrioritySlot(
        id: 'b1',
        date: soon,
        startsAt: const HourMinute(10, 0),
        endsAt: const HourMinute(12, 0),
        type: uklidType,
      ),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('Zápasy'), findsOneWidget);
    expect(find.textContaining('KK Veverky – KK Slavoj'), findsOneWidget);
    expect(find.text('úklid 30 min před'), findsOneWidget);
    expect(find.textContaining('Sokol Lhota'), findsOneWidget);
    expect(
      find.text('venku — neblokuje kuželnu · odjezd v 8:00'),
      findsOneWidget,
    );
    expect(find.textContaining('17:30–18:00'), findsNothing);
    expect(find.textContaining('10:00–12:00'), findsNothing);

    // Newest first.
    final laterY = tester.getTopLeft(find.textContaining('Sokol Lhota')).dy;
    final soonY = tester.getTopLeft(find.textContaining('KK Slavoj')).dy;
    expect(laterY, lessThan(soonY));
  });

  testWidgets('empty state', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Zatím žádné zápasy.'), findsOneWidget);
    expect(find.text('Přidat zápas'), findsOneWidget);
  });

  testWidgets('Přidat zápas opens the match dialog', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Přidat zápas'));
    await tester.pumpAndSettle();

    // The dialog's title (the FAB label underneath reads the same).
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Přidat zápas'),
      ),
      findsOneWidget,
    );
    expect(find.text('Datum'), findsOneWidget);
    expect(find.text('Domácí'), findsOneWidget);
    expect(find.text('Hosté'), findsOneWidget);
    expect(find.text('Úklid před zápasem'), findsOneWidget);
    expect(find.text('Uložit'), findsOneWidget);
  });
}
