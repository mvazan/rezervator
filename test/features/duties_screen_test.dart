import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/duties_screen.dart';

/// Klubovna → Služby (0050): my duty on top, who serves now, the plan ahead
/// in date order, the past collapsed, my periods highlighted. Read-only;
/// only the admin gets „Spravovat“. Today is Wednesday 7. 10. 2026.
void main() {
  Profile profile(String id, String name, {Role role = Role.player}) => Profile(
    id: id,
    displayName: name,
    email: '$id@example.com',
    role: role,
    status: ProfileStatus.approved,
  );
  final me = profile('me', 'Jan Novák');
  final admin = profile('me', 'Jan Novák', role: Role.admin);

  const players = [
    PlayerName(id: 'me', displayName: 'Jan Novák'),
    PlayerName(id: 'jana', displayName: 'Jana Nováková'),
    PlayerName(id: 'petr', displayName: 'Petr Svoboda'),
    PlayerName(id: 'cenek', displayName: 'Čeněk Dvořák'),
    PlayerName(id: 'cyril', displayName: 'Cyril Hudec'),
    PlayerName(id: 'bohous', displayName: 'Bohumil Kroupa', hasAccount: false),
  ];

  final past = DutyPeriod(
    id: 'past',
    startsOn: Day(2026, 9, 28),
    endsOn: Day(2026, 10, 4),
  );
  final now = DutyPeriod(
    id: 'now',
    startsOn: Day(2026, 10, 5),
    endsOn: Day(2026, 10, 11),
  );
  final next1 = DutyPeriod(
    id: 'next1',
    startsOn: Day(2026, 10, 12),
    endsOn: Day(2026, 10, 18),
    note: 'posvícení',
  );
  final next2 = DutyPeriod(
    id: 'next2',
    startsOn: Day(2026, 10, 19),
    endsOn: Day(2026, 10, 25),
  );
  final empty = DutyPeriod(
    id: 'empty',
    startsOn: Day(2026, 10, 26),
    endsOn: Day(2026, 11, 1),
  );

  List<DutyAssignment> assign(Map<String, List<String>> who) => [
    for (final e in who.entries)
      for (final user in e.value) DutyAssignment(periodId: e.key, userId: user),
  ];

  Widget app({
    Profile? profile,
    List<DutyPeriod>? periods,
    Map<String, List<String>>? who,
    ScheduleSettings settings = ScheduleSettings.defaults,
  }) => ProviderScope(
    overrides: [
      myProfileProvider.overrideWith((ref) => Stream.value(profile ?? me)),
      nowProvider.overrideWith(
        (ref) => Stream.value(DateTime(2026, 10, 7, 18, 0)),
      ),
      dutyPeriodsProvider.overrideWith(
        (ref) => Stream.value(periods ?? [next2, past, now, empty, next1]),
      ),
      dutyAssignmentsProvider.overrideWith(
        (ref) => Stream.value(
          assign(
            who ??
                {
                  'past': ['jana'],
                  'now': ['me', 'jana'],
                  'next1': ['petr', 'cenek', 'cyril'],
                  'next2': ['me', 'bohous'],
                },
          ),
        ),
      ),
      playersProvider.overrideWith((ref) async => players),
      settingsProvider.overrideWith((ref) => Stream.value(settings)),
    ],
    child: MaterialApp(
      home: DutiesScreen(
        adminPage: (_) => const Scaffold(body: Text('Správa služeb')),
      ),
    ),
  );

  ScheduleSettings reminder(int days) => ScheduleSettings(
    laneCount: 4,
    trainingWeekdays: const {1, 2, 4},
    bookingHorizonDays: 14,
    maxActiveReservations: 2,
    dutyReminderEnabled: true,
    dutyReminderDays: days,
  );

  Finder rich(String text) => find.text(text, findRichText: true);

  // A ProviderScope keeps its container across a rebuild in place, so a
  // second app with other overrides needs a fresh tree.
  Future<void> fresh(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox());

  testWidgets('on duty: my card says until when and who is with me', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Právě sloužíš — do ne 11. 10.'), findsOneWidget);
    expect(find.text('spolu s: Jana Nováková'), findsOneWidget);
    expect(find.textContaining('Tvoje příští služba'), findsNothing);
    // The reminder is off by default.
    expect(find.textContaining('Připomínku'), findsNothing);
  });

  testWidgets('the reminder line says the lead the admin set', (tester) async {
    await tester.pumpWidget(app(settings: reminder(2)));
    await tester.pumpAndSettle();
    expect(find.text('Připomínku dostaneš 2 dny předem.'), findsOneWidget);

    await fresh(tester);
    await tester.pumpWidget(app(settings: reminder(7)));
    await tester.pumpAndSettle();
    expect(find.text('Připomínku dostaneš týden předem.'), findsOneWidget);
  });

  testWidgets('on duty with nothing ahead: no reminder line', (tester) async {
    await tester.pumpWidget(
      app(
        periods: [now],
        who: {
          'now': ['me', 'jana'],
        },
        settings: reminder(2),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Právě sloužíš — do ne 11. 10.'), findsOneWidget);
    expect(find.textContaining('Připomínku'), findsNothing);
  });

  testWidgets('off duty with one ahead: my next duty', (tester) async {
    await tester.pumpWidget(
      app(
        who: {
          'now': ['jana'],
          'next2': ['me'],
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Tvoje příští služba: po 19. 10. – ne 25. 10.'),
      findsOneWidget,
    );
    expect(find.textContaining('Právě sloužíš'), findsNothing);
  });

  testWidgets('no duty of mine: no card of mine', (tester) async {
    await tester.pumpWidget(
      app(
        who: {
          'now': ['jana'],
        },
        settings: reminder(1),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Právě sloužíš'), findsNothing);
    expect(find.textContaining('Tvoje příští služba'), findsNothing);
    expect(find.textContaining('Připomínku'), findsNothing);
  });

  testWidgets('„Teď slouží“ names who serves now, hidden when it is only me', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        who: {
          'now': ['petr', 'jana'],
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Teď slouží: Jana Nováková a Petr Svoboda'),
      findsOneWidget,
    );
    expect(find.text('do ne 11. 10.'), findsOneWidget);

    await fresh(tester);
    await tester.pumpWidget(
      app(
        who: {
          'now': ['me'],
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Teď slouží'), findsNothing);
    expect(find.text('Právě sloužíš — do ne 11. 10.'), findsOneWidget);
  });

  testWidgets('the plan ahead in date order, names Czech-sorted, an empty '
      'one „Neobsazeno“', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    final ranges = [
      'po 12. 10. – ne 18. 10. · posvícení',
      'po 19. 10. – ne 25. 10.',
      'po 26. 10. – ne 1. 11.',
    ];
    final ys = [for (final r in ranges) tester.getTopLeft(find.text(r)).dy];
    expect(ys, orderedEquals([...ys]..sort()));
    // The running one sits in the cards above, not in the list.
    expect(find.text('po 5. 10. – ne 11. 10.'), findsNothing);
    expect(rich('Cyril Hudec, Čeněk Dvořák, Petr Svoboda'), findsOneWidget);
    expect(find.text('Neobsazeno'), findsOneWidget);
  });

  testWidgets('only my periods are highlighted: stripe, „ty“ and the chip', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Tvoje služba'), findsOneWidget);
    expect(find.byKey(const ValueKey('duty-mine-next2')), findsOneWidget);
    expect(find.byKey(const ValueKey('duty-mine-next1')), findsNothing);
    expect(rich('ty, Bohumil Kroupa'), findsOneWidget);

    final bold = <TextSpan>[];
    tester.widget<RichText>(rich('ty, Bohumil Kroupa')).text.visitChildren((
      span,
    ) {
      if (span is TextSpan && span.text == 'ty') bold.add(span);
      return true;
    });
    expect(bold.single.style!.fontWeight, FontWeight.w700);

    final stripe = tester.widget<Container>(
      find.byKey(const ValueKey('duty-mine-next2')),
    );
    final border = (stripe.decoration! as BoxDecoration).border! as Border;
    expect(border.left.width, 4);
    expect(
      border.left.color,
      Theme.of(tester.element(find.byType(DutiesScreen))).colorScheme.primary,
    );
  });

  testWidgets('past duties stay collapsed under „Minulé služby“', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Minulé služby'), findsOneWidget);
    expect(find.text('po 28. 9. – ne 4. 10.'), findsNothing);

    await tester.scrollUntilVisible(find.text('Minulé služby'), 200);
    await tester.tap(find.text('Minulé služby'));
    await tester.pumpAndSettle();
    expect(find.text('po 28. 9. – ne 4. 10.'), findsOneWidget);
  });

  testWidgets('nothing planned: the empty state and the footer', (
    tester,
  ) async {
    await tester.pumpWidget(app(periods: const [], who: const {}));
    await tester.pumpAndSettle();

    expect(find.text('Služby zatím nejsou naplánované.'), findsOneWidget);
    expect(find.text('Minulé služby'), findsNothing);
    expect(
      find.text(
        'Během služby můžeš rezervovat a rušit tréninky ostatním a upravovat '
        'bloky v jednotlivých dnech.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('„Spravovat“ only for the admin, opening Správa → Služby', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('Spravovat'), findsNothing);

    await fresh(tester);
    await tester.pumpWidget(app(profile: admin));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Spravovat'));
    await tester.pumpAndSettle();
    expect(find.text('Správa služeb'), findsOneWidget);
  });
}
