import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/duties.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/admin_screen.dart';
import 'package:rezervator/features/admin/duties_admin_screen.dart';
import 'package:rezervator/features/admin/duties_history_screen.dart';
import 'package:rezervator/features/admin/widgets/duty_admin_api.dart';
import 'package:rezervator/features/admin/widgets/duty_generator_dialog.dart';

/// Správa → Služby (0050): the admin's plan, the assign sheet, the season
/// overview, the reminder setting and the seasons — every write through an
/// injected [DutyAdminApi], so each test sees exactly what would go to the
/// server. Today is Wednesday 7. 10. 2026 throughout.
void main() {
  const admin = Profile(
    id: 'admin',
    displayName: 'Správce',
    email: 'admin@example.com',
    role: Role.admin,
    status: ProfileStatus.approved,
  );
  const jan = Profile(
    id: 'jan',
    displayName: 'Jan Novák',
    email: 'jan@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
  );
  const jana = Profile(
    id: 'jana',
    displayName: 'Jana Nováková',
    email: 'jana@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
  );
  const petr = Profile(
    id: 'petr',
    displayName: 'Petr Svoboda',
    email: 'petr@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
    nick: 'Péťa',
  );
  const zdenek = Profile(
    id: 'zdenek',
    displayName: 'Zdeněk Šimek',
    email: 'zdenek@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
  );
  const cenek = Profile(
    id: 'cenek',
    displayName: 'Čeněk Dvořák',
    email: 'cenek@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
  );
  const cyril = Profile(
    id: 'cyril',
    displayName: 'Cyril Hudec',
    email: 'cyril@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
  );
  const bohous = Profile(
    id: 'bohous',
    displayName: 'Bohumil Kroupa',
    email: '',
    role: Role.player,
    status: ProfileStatus.approved,
    hasAccount: false,
  );
  const kiosk = Profile(
    id: 'kiosk',
    displayName: 'Tablet',
    email: 'kiosk@example.com',
    role: Role.kiosk,
    status: ProfileStatus.approved,
  );
  const pending = Profile(
    id: 'pending',
    displayName: 'Nový Hráč',
    email: 'novy@example.com',
    role: Role.player,
    status: ProfileStatus.pending,
  );
  const profiles = [
    admin,
    jan,
    jana,
    petr,
    zdenek,
    cenek,
    cyril,
    bohous,
    kiosk,
    pending,
  ];

  final p0 = DutyPeriod(
    id: 'p0',
    startsOn: Day(2026, 8, 24),
    endsOn: Day(2026, 8, 30),
  );
  final p1 = DutyPeriod(
    id: 'p1',
    startsOn: Day(2026, 9, 21),
    endsOn: Day(2026, 9, 27),
  );
  final p2 = DutyPeriod(
    id: 'p2',
    startsOn: Day(2026, 9, 28),
    endsOn: Day(2026, 10, 4),
  );
  final p3 = DutyPeriod(
    id: 'p3',
    startsOn: Day(2026, 10, 5),
    endsOn: Day(2026, 10, 11),
    note: 'mimo so',
  );
  final p4 = DutyPeriod(
    id: 'p4',
    startsOn: Day(2026, 10, 12),
    endsOn: Day(2026, 10, 18),
  );
  final p5 = DutyPeriod(
    id: 'p5',
    startsOn: Day(2026, 10, 19),
    endsOn: Day(2026, 10, 25),
  );
  final periods = [p0, p1, p2, p3, p4, p5];
  const assignments = [
    DutyAssignment(periodId: 'p0', userId: 'jana'),
    DutyAssignment(periodId: 'p1', userId: 'petr'),
    DutyAssignment(periodId: 'p2', userId: 'jana'),
    DutyAssignment(periodId: 'p2', userId: 'bohous'),
    DutyAssignment(periodId: 'p3', userId: 'jana'),
    DutyAssignment(periodId: 'p3', userId: 'jan'),
    DutyAssignment(periodId: 'p5', userId: 'petr'),
  ];
  final seasons = [DutySeason(startedOn: Day(2026, 9, 1), name: '2026/27')];
  const settings = ScheduleSettings(
    laneCount: 4,
    trainingWeekdays: {1, 2, 4},
    bookingHorizonDays: 14,
    maxActiveReservations: 3,
    tenantId: 't1',
    dutyReminderDays: 2,
  );

  late List<String> log;
  setUp(() => log = []);

  DutyAdminApi api() => DutyAdminApi(
    generate:
        ({required Day from, required int days, required Day until}) async {
          log.add('generate ${from.toSql()} $days ${until.toSql()}');
          return (created: 36, skipped: 0);
        },
    savePeriod:
        ({
          String? id,
          required Day startsOn,
          required Day endsOn,
          String note = '',
        }) async {
          log.add('save $id ${startsOn.toSql()} ${endsOn.toSql()} $note');
          return id ?? 'new';
        },
    deletePeriod: (id) async => log.add('delete $id'),
    deleteUnassigned: (from) async {
      log.add('deleteUnassigned ${from.toSql()}');
      return 1;
    },
    setAssignees: (periodId, userIds) async =>
        log.add('assign $periodId ${userIds.join(',')}'),
    startSeason: (startedOn, name) async =>
        log.add('season ${startedOn.toSql()} $name'),
    deleteSeason: (startedOn) async => log.add('undo ${startedOn.toSql()}'),
    setReminder: (enabled, days, {required tenantId}) async =>
        log.add('reminder $enabled $days $tenantId'),
  );

  // One ProviderScope per test: a second pumpWidget does not swap overrides.
  Widget app({
    Widget? home,
    Profile me = admin,
    List<DutyPeriod>? dutyPeriods,
    List<DutyAssignment> dutyAssignments = assignments,
    List<DutySeason>? dutySeasons,
    ScheduleSettings? scheduleSettings = settings,
    List<Profile>? everyone,
    List<Club> clubs = const [],
  }) => ProviderScope(
    overrides: [
      myProfileProvider.overrideWith((ref) => Stream.value(me)),
      profilesProvider.overrideWith(
        (ref) => Stream.value(everyone ?? profiles),
      ),
      clubsProvider.overrideWith((ref) => Stream.value(clubs)),
      dutyPeriodsProvider.overrideWith(
        (ref) => Stream.value(dutyPeriods ?? periods),
      ),
      dutyAssignmentsProvider.overrideWith(
        (ref) => Stream.value(dutyAssignments),
      ),
      dutySeasonsProvider.overrideWith((ref) async => dutySeasons ?? seasons),
      settingsProvider.overrideWith((ref) => Stream.value(scheduleSettings)),
      nowProvider.overrideWith(
        (ref) => Stream.value(DateTime(2026, 10, 7, 12)),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('cs')],
      home: home ?? DutiesAdminScreen(api: api()),
    ),
  );

  /// Tall enough that the lazy list builds everything down to Přehled
  /// sezóny, and a bottom sheet lists every player.
  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Finder tileOf(String title) => find.widgetWithText(ListTile, title);

  Finder menuOf(String title) => find.descendant(
    of: tileOf(title),
    matching: find.byType(PopupMenuButton<String>),
  );

  Finder inSheet(Finder finder) =>
      find.descendant(of: find.byType(BottomSheet), matching: finder);

  Finder inDialog(Finder finder) =>
      find.descendant(of: find.byType(AlertDialog), matching: finder);

  group('dutyPlanPreview', () {
    DutyPlan plan(int created, {int skipped = 0, int? clipped}) => DutyPlan(
      periods: [
        for (var i = 0; i < created; i++)
          (startsOn: Day(2026, 1, 1), endsOn: Day(2026, 1, 1)),
      ],
      skipped: skipped,
      lastClippedDays: clipped,
    );

    test("the spec's sentence", () {
      expect(
        dutyPlanPreview(plan(40, skipped: 2, clipped: 3)),
        'Vznikne 40 služeb, poslední zkrácená na 3 dny. '
        '2 se překrývají a přeskočí se.',
      );
    });

    test('Czech number agreement', () {
      expect(dutyPlanPreview(plan(1)), 'Vznikne 1 služba.');
      expect(dutyPlanPreview(plan(3)), 'Vzniknou 3 služby.');
      expect(
        dutyPlanPreview(plan(5, clipped: 1)),
        'Vznikne 5 služeb, poslední zkrácená na 1 den.',
      );
      expect(
        dutyPlanPreview(plan(1, clipped: 5)),
        'Vznikne 1 služba, zkrácená na 5 dní.',
      );
      expect(
        dutyPlanPreview(plan(0, skipped: 1)),
        'Nevznikne žádná služba. 1 se překrývá a přeskočí se.',
      );
      expect(
        dutyPlanPreview(plan(2, skipped: 6)),
        'Vzniknou 2 služby. 6 se překrývá a přeskočí se.',
      );
    });
  });

  testWidgets('a player gets the refusal, not the plan', (tester) async {
    await tester.pumpWidget(app(me: jan));
    await tester.pumpAndSettle();
    expect(find.text('Jen pro správce.'), findsOneWidget);
    expect(find.text('Přidat službu'), findsNothing);
  });

  testWidgets('Správa lists Služby right after Docházka', (tester) async {
    await tester.pumpWidget(app(home: const AdminScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Služby'), findsOneWidget);
    expect(find.byIcon(Icons.local_cafe_outlined), findsOneWidget);
    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(top('Docházka'), lessThan(top('Služby')));
    expect(top('Služby'), lessThan(top('Rozvrh')));
    // Exactly one row after Docházka.
    expect(top('Služby') - top('Docházka'), top('Rozvrh') - top('Služby'));

    await tester.tap(find.text('Služby'));
    await tester.pumpAndSettle();
    expect(find.byType(DutiesAdminScreen), findsOneWidget);
  });

  testWidgets('the header names the season, the plan runs chronologically '
      'with the running duty tinted and the past collapsed', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Sezóna 2026/27 · od 1. 9. 2026'), findsOneWidget);

    // The running duty: the note appended, the chip, the tint, Czech-sorted
    // names.
    final now = tileOf('po 5. 10. – ne 11. 10. · mimo so');
    expect(now, findsOneWidget);
    expect(
      find.descendant(of: now, matching: find.text('Teď slouží')),
      findsOneWidget,
    );
    expect(tester.widget<ListTile>(now).tileColor, isNotNull);
    expect(
      find.descendant(of: now, matching: find.text('Jan Novák, Jana Nováková')),
      findsOneWidget,
    );

    // An empty one says so in the error colour; the others are plain.
    final empty = tileOf('po 12. 10. – ne 18. 10.');
    final neobsazeno = find.descendant(
      of: empty,
      matching: find.text('Neobsazeno'),
    );
    expect(neobsazeno, findsOneWidget);
    final context = tester.element(empty);
    expect(
      tester.widget<Text>(neobsazeno).style?.color,
      Theme.of(context).colorScheme.error,
    );
    expect(tester.widget<ListTile>(empty).tileColor, isNull);
    expect(find.text('Teď slouží'), findsOneWidget);

    // Chronological, the past below behind its count; the implicit
    // season's duty (24. 8.) is Historie's, not listed here.
    double top(Finder f) => tester.getTopLeft(f).dy;
    expect(top(now), lessThan(top(empty)));
    expect(top(empty), lessThan(top(tileOf('po 19. 10. – ne 25. 10.'))));
    expect(
      top(tileOf('po 19. 10. – ne 25. 10.')),
      lessThan(top(find.text('Minulé služby (2)'))),
    );
    expect(find.text('po 21. 9. – ne 27. 9.'), findsNothing);
    expect(find.text('po 24. 8. – ne 30. 8.'), findsNothing);

    await tester.tap(find.text('Minulé služby (2)'));
    await tester.pumpAndSettle();
    expect(
      top(find.text('po 21. 9. – ne 27. 9.')),
      lessThan(top(find.text('po 28. 9. – ne 4. 10.'))),
    );
    // A placeholder is marked in the names.
    expect(
      find.text('Bohumil Kroupa · bez účtu, Jana Nováková'),
      findsOneWidget,
    );
    expect(find.text('po 24. 8. – ne 30. 8.'), findsNothing);
  });

  testWidgets('Přehled sezóny: every approved player, placeholders and zeros '
      'included, Czech-sorted', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Přehled sezóny'), findsOneWidget);
    const rows = [
      'Bohumil Kroupa — 1 služba · 7 dní (1 odsloužena)',
      'Cyril Hudec — —',
      'Čeněk Dvořák — —',
      'Jan Novák — 1 služba · 7 dní',
      'Jana Nováková — 2 služby · 14 dní (1 odsloužena)',
      'Petr Svoboda — 2 služby · 14 dní (1 odsloužena)',
      'Správce — —',
      'Zdeněk Šimek — —',
    ];
    for (final row in rows) {
      expect(find.text(row), findsOneWidget, reason: row);
    }
    for (var i = 1; i < rows.length; i++) {
      expect(
        tester.getTopLeft(find.text(rows[i - 1])).dy,
        lessThan(tester.getTopLeft(find.text(rows[i])).dy),
        reason: '${rows[i - 1]} before ${rows[i]}',
      );
    }
    expect(find.textContaining('Tablet'), findsNothing);
    expect(find.textContaining('Nový Hráč'), findsNothing);
  });

  testWidgets('with no season yet the header says První sezóna and the empty '
      'plan says so', (tester) async {
    await tester.pumpWidget(
      app(
        dutyPeriods: const [],
        dutyAssignments: const [],
        dutySeasons: const [],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('První sezóna'), findsOneWidget);
    expect(find.text('Služby zatím nejsou naplánované.'), findsOneWidget);
    expect(find.textContaining('Minulé služby'), findsNothing);
  });

  group('reminder', () {
    testWidgets('off: no lead picker; switching on keeps the lead', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.text('Připomínka služby'), findsOneWidget);
      expect(
        find.text(
          'Odesílá se v 18:00. Push, jinak e-mail. Hráči bez účtu '
          'ji nedostanou.',
        ),
        findsOneWidget,
      );
      expect(find.text('Předstih'), findsNothing);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(log, ['reminder true 2 t1']);
    });

    testWidgets('on: the lead picker saves, switching off keeps the lead', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          scheduleSettings: const ScheduleSettings(
            laneCount: 4,
            trainingWeekdays: {1, 2, 4},
            bookingHorizonDays: 14,
            maxActiveReservations: 3,
            tenantId: 't1',
            dutyReminderEnabled: true,
            dutyReminderDays: 2,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Předstih'), findsOneWidget);
      expect(find.text('2 dny'), findsOneWidget);
      await tester.tap(find.text('2 dny'));
      await tester.pumpAndSettle();
      for (final option in ['1 den', '3 dny', 'týden']) {
        expect(find.text(option), findsWidgets, reason: option);
      }
      await tester.tap(find.text('týden').last);
      await tester.pumpAndSettle();
      expect(log, ['reminder true 7 t1']);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(log.last, 'reminder false 2 t1');
    });
  });

  group('generator', () {
    Future<void> openGenerator(WidgetTester tester) async {
      await tester.tap(find.text('Vygenerovat…'));
      await tester.pumpAndSettle();
    }

    testWidgets('defaults continue the plan weekly to 30. 6. and preview '
        'what duty_generate would do', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await openGenerator(tester);

      expect(find.text('Vygenerovat služby'), findsOneWidget);
      expect(find.text('Každý týden'), findsOneWidget);
      expect(find.text('Po N dnech'), findsOneWidget);
      expect(inDialog(find.text('po 26. 10. 2026')), findsOneWidget);
      expect(inDialog(find.text('st 30. 6. 2027')), findsOneWidget);
      expect(
        find.text('Vznikne 36 služeb, poslední zkrácená na 3 dny.'),
        findsOneWidget,
      );
      expect(find.text('První služba: po 26. 10. – ne 1. 11.'), findsOneWidget);

      // The change day moves the first duty to the next such weekday.
      await tester.tap(find.widgetWithText(ChoiceChip, 'st'));
      await tester.pumpAndSettle();
      expect(
        find.text('Vznikne 36 služeb, poslední zkrácená na 1 den.'),
        findsOneWidget,
      );
      expect(find.text('První služba: st 28. 10. – út 3. 11.'), findsOneWidget);

      await tester.tap(find.text('Vygenerovat'));
      await tester.pumpAndSettle();
      expect(log, ['generate 2026-10-28 7 2027-06-30']);
      expect(find.text('Vygenerovat služby'), findsNothing);
      expect(find.text('Vytvořeno služeb: 36.'), findsOneWidget);
    });

    testWidgets('Po N dnech counts its days', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await openGenerator(tester);

      await tester.tap(find.text('Po N dnech'));
      await tester.pumpAndSettle();
      expect(find.text('Počet dní'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'st'), findsNothing);
      for (var i = 0; i < 3; i++) {
        await tester.tap(inDialog(find.byIcon(Icons.add)));
        await tester.pump();
      }
      expect(inDialog(find.text('10')), findsOneWidget);
      expect(
        find.text('Vznikne 25 služeb, poslední zkrácená na 8 dní.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Vygenerovat'));
      await tester.pumpAndSettle();
      expect(log, ['generate 2026-10-26 10 2027-06-30']);
    });

    testWidgets('an earlier Od skips the periods that already exist', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await openGenerator(tester);

      await tester.tap(inDialog(find.text('Od')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('12'));
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(inDialog(find.text('po 12. 10. 2026')), findsOneWidget);
      expect(
        find.text(
          'Vznikne 36 služeb, poslední zkrácená na 3 dny. '
          '2 se překrývají a přeskočí se.',
        ),
        findsOneWidget,
      );
    });
  });

  group('assign sheet', () {
    /// The sheet's list top to bottom: each player's name, „—“ for a
    /// divider between the count groups.
    List<String> rows() {
      final found = inSheet(
        find.byWidgetPredicate((w) => w is CheckboxListTile || w is Divider),
      );
      final rows = [
        for (final e in found.evaluate())
          (
            // By the element: a const Divider is one widget many times.
            dy: (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy,
            label: switch (e.widget) {
              CheckboxListTile(:final Text title) => title.data!,
              _ => '—',
            },
          ),
      ]..sort((a, b) => a.dy.compareTo(b.dy));
      return [for (final r in rows) r.label];
    }

    testWidgets('fewest duties first, then Czech-sorted, a divider between '
        'the counts; the chosen ids are saved', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(find.text('po 12. 10. – ne 18. 10.'));
      await tester.pumpAndSettle();

      expect(inSheet(find.text('po 12. 10. – ne 18. 10.')), findsOneWidget);
      expect(rows(), [
        'Cyril Hudec',
        'Čeněk Dvořák',
        'Správce',
        'Zdeněk Šimek',
        '—',
        'Bohumil Kroupa',
        'Jan Novák',
        '—',
        'Jana Nováková',
        'Petr Svoboda',
      ]);
      expect(inSheet(find.text('Tablet')), findsNothing);
      expect(inSheet(find.text('Nový Hráč')), findsNothing);

      String countOf(String name) => tester
          .widget<Text>(
            find.descendant(
              of: find.widgetWithText(CheckboxListTile, name),
              matching: find.textContaining('×'),
            ),
          )
          .data!;
      expect(countOf('Bohumil Kroupa'), '1×');
      expect(countOf('Cyril Hudec'), '0×');
      expect(countOf('Jana Nováková'), '2×');
      expect(countOf('Petr Svoboda'), '2×');

      await tester.tap(inSheet(find.text('Zdeněk Šimek')));
      await tester.tap(inSheet(find.text('Cyril Hudec')));
      await tester.pump();
      // The count follows the tick, so the admin balances while picking.
      expect(countOf('Cyril Hudec'), '1×');
      // The order does not: no row moves under the finger.
      expect(rows(), [
        'Cyril Hudec',
        'Čeněk Dvořák',
        'Správce',
        'Zdeněk Šimek',
        '—',
        'Bohumil Kroupa',
        'Jan Novák',
        '—',
        'Jana Nováková',
        'Petr Svoboda',
      ]);

      await tester.tap(inSheet(find.text('Uložit')));
      await tester.pumpAndSettle();
      expect(log, ['assign p4 cyril,zdenek']);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Uloženo.'), findsOneWidget);
    });

    testWidgets('the search ignores diacritics and matches the nick, and '
        'keeps the ticks it hides', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(find.text('po 12. 10. – ne 18. 10.'));
      await tester.pumpAndSettle();

      expect(find.text('jméno nebo přezdívka'), findsOneWidget);
      await tester.tap(inSheet(find.text('Cyril Hudec')));
      await tester.enterText(inSheet(find.byType(TextField)), 'simek');
      await tester.pump();
      expect(inSheet(find.text('Zdeněk Šimek')), findsOneWidget);
      expect(inSheet(find.text('Cyril Hudec')), findsNothing);

      await tester.enterText(inSheet(find.byType(TextField)), 'peta');
      await tester.pump();
      expect(inSheet(find.text('Petr Svoboda')), findsOneWidget);
      await tester.tap(inSheet(find.text('Petr Svoboda')));
      await tester.pump();

      await tester.tap(inSheet(find.text('Uložit')));
      await tester.pumpAndSettle();
      expect(log, ['assign p4 cyril,petr']);
    });

    testWidgets('the club chips narrow the list; ticks in other clubs stay', (
      tester,
    ) async {
      tall(tester);
      Profile inClub(Profile p, String clubId) => Profile(
        id: p.id,
        displayName: p.displayName,
        email: p.email,
        role: p.role,
        status: p.status,
        nick: p.nick,
        clubId: clubId,
      );
      await tester.pumpWidget(
        app(
          everyone: [
            for (final p in profiles)
              if (p.id == 'jan' || p.id == 'jana')
                inClub(p, 'c1')
              else if (p.id == 'petr')
                inClub(p, 'c2')
              else
                p,
          ],
          clubs: const [
            Club(id: 'c2', name: 'Veverky'),
            Club(id: 'c1', name: 'Sokol'),
            Club(id: 'c3', name: 'Prázdný'),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('po 12. 10. – ne 18. 10.'));
      await tester.pumpAndSettle();

      // Only clubs with a player, Czech-sorted, after „Všichni“.
      expect(inSheet(find.byType(ChoiceChip)), findsNWidgets(4));
      expect(inSheet(find.text('Prázdný')), findsNothing);
      expect(
        tester.getTopLeft(inSheet(find.text('Sokol'))).dx,
        lessThan(tester.getTopLeft(inSheet(find.text('Veverky'))).dx),
      );

      await tester.tap(inSheet(find.text('Sokol')));
      await tester.pump();
      expect(inSheet(find.text('Jan Novák')), findsOneWidget);
      expect(inSheet(find.text('Jana Nováková')), findsOneWidget);
      expect(inSheet(find.text('Petr Svoboda')), findsNothing);
      expect(inSheet(find.text('Cyril Hudec')), findsNothing);
      await tester.tap(inSheet(find.text('Jan Novák')));

      await tester.tap(inSheet(find.text('Bez oddílu')));
      await tester.pump();
      expect(inSheet(find.text('Jan Novák')), findsNothing);
      expect(inSheet(find.text('Cyril Hudec')), findsOneWidget);

      await tester.tap(inSheet(find.text('Veverky')));
      await tester.pump();
      await tester.tap(inSheet(find.text('Petr Svoboda')));
      await tester.tap(inSheet(find.text('Uložit')));
      await tester.pumpAndSettle();
      expect(log, ['assign p4 jan,petr']);
    });

    testWidgets('the chosen club is remembered for the next opening',
        (tester) async {
      tall(tester);
      await tester.pumpWidget(
        app(
          everyone: [
            for (final p in profiles)
              if (p.id == 'jan')
                Profile(
                  id: p.id,
                  displayName: p.displayName,
                  email: p.email,
                  role: p.role,
                  status: p.status,
                  clubId: 'c1',
                )
              else if (p.id == 'petr')
                Profile(
                  id: p.id,
                  displayName: p.displayName,
                  email: p.email,
                  role: p.role,
                  status: p.status,
                  clubId: 'c2',
                )
              else
                p,
          ],
          clubs: const [
            Club(id: 'c1', name: 'Sokol'),
            Club(id: 'c2', name: 'Veverky'),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('po 12. 10. – ne 18. 10.'));
      await tester.pumpAndSettle();
      await tester.tap(inSheet(find.text('Veverky')));
      await tester.pump();
      expect(inSheet(find.text('Jan Novák')), findsNothing);
      await tester.tap(inSheet(find.text('Uložit')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('po 19. 10. – ne 25. 10.'));
      await tester.pumpAndSettle();
      expect(inSheet(find.text('Petr Svoboda')), findsOneWidget);
      expect(inSheet(find.text('Jan Novák')), findsNothing);
      expect(
        tester
            .widget<ChoiceChip>(
              find.ancestor(
                of: inSheet(find.text('Veverky')),
                matching: find.byType(ChoiceChip),
              ),
            )
            .selected,
        isTrue,
      );
    });

    testWidgets('without clubs the sheet shows no chips', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(find.text('po 12. 10. – ne 18. 10.'));
      await tester.pumpAndSettle();
      expect(inSheet(find.byType(ChoiceChip)), findsNothing);
    });

    testWidgets('Uložit a další saves and moves to the next duty', (
      tester,
    ) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(find.text('po 5. 10. – ne 11. 10. · mimo so'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, 'Jan Novák'),
            )
            .value,
        isTrue,
      );
      await tester.tap(inSheet(find.text('Jan Novák')));
      await tester.tap(inSheet(find.text('Uložit a další')));
      await tester.pumpAndSettle();

      expect(log, ['assign p3 jana']);
      expect(inSheet(find.text('po 12. 10. – ne 18. 10.')), findsOneWidget);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, 'Jana Nováková'),
            )
            .value,
        isFalse,
      );
      // Jan's duty went, so his count did too.
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.widgetWithText(CheckboxListTile, 'Jan Novák'),
                matching: find.textContaining('×'),
              ),
            )
            .data,
        '0×',
      );

      await tester.tap(inSheet(find.text('Petr Svoboda')));
      await tester.tap(inSheet(find.text('Uložit')));
      await tester.pumpAndSettle();
      expect(log, ['assign p3 jana', 'assign p4 petr']);
    });

    testWidgets('the search keeps the order and the groups', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(find.text('po 12. 10. – ne 18. 10.'));
      await tester.pumpAndSettle();

      await tester.enterText(inSheet(find.byType(TextField)), 'nov');
      await tester.pump();
      expect(rows(), ['Jan Novák', '—', 'Jana Nováková']);

      await tester.enterText(inSheet(find.byType(TextField)), 'ek');
      await tester.pump();
      expect(rows(), ['Čeněk Dvořák', 'Zdeněk Šimek']);
    });

    testWidgets('Uložit a další sorts the next duty by its own counts', (
      tester,
    ) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(find.text('po 5. 10. – ne 11. 10. · mimo so'));
      await tester.pumpAndSettle();

      String countOf(String name) => tester
          .widget<Text>(
            find.descendant(
              of: find.widgetWithText(CheckboxListTile, name),
              matching: find.textContaining('×'),
            ),
          )
          .data!;

      // Sorted by the counts shown, this duty's saved ticks in: Jan's only
      // duty is this one, so he sorts with the ones, Jana with the twos.
      final before = [
        'Cyril Hudec',
        'Čeněk Dvořák',
        'Správce',
        'Zdeněk Šimek',
        '—',
        'Bohumil Kroupa',
        'Jan Novák',
        '—',
        'Jana Nováková',
        'Petr Svoboda',
      ];
      expect(rows(), before);
      expect(
        [for (final name in before) name == '—' ? name : countOf(name)],
        ['0×', '0×', '0×', '0×', '—', '1×', '1×', '—', '2×', '2×'],
      );

      // Ticks move the counts, never the rows.
      await tester.tap(inSheet(find.text('Cyril Hudec')));
      await tester.tap(inSheet(find.text('Jan Novák')));
      await tester.pump();
      expect(countOf('Cyril Hudec'), '1×');
      expect(countOf('Jan Novák'), '0×');
      expect(rows(), before);
      await tester.tap(inSheet(find.text('Jan Novák')));
      await tester.pump();

      await tester.tap(inSheet(find.text('Uložit a další')));
      await tester.pumpAndSettle();
      expect(log, ['assign p3 cyril,jan,jana']);
      expect(inSheet(find.text('po 12. 10. – ne 18. 10.')), findsOneWidget);
      expect(rows(), [
        'Čeněk Dvořák',
        'Správce',
        'Zdeněk Šimek',
        '—',
        'Bohumil Kroupa',
        'Cyril Hudec',
        'Jan Novák',
        '—',
        'Jana Nováková',
        'Petr Svoboda',
      ]);
    });

    testWidgets('Uložit without a change sends nothing and says nothing', (
      tester,
    ) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(find.text('po 5. 10. – ne 11. 10. · mimo so'));
      await tester.pumpAndSettle();

      await tester.tap(inSheet(find.text('Uložit')));
      await tester.pumpAndSettle();
      expect(log, isEmpty);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Uloženo.'), findsNothing);
    });

    testWidgets('the last duty offers no Uložit a další', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(find.text('po 19. 10. – ne 25. 10.'));
      await tester.pumpAndSettle();
      expect(inSheet(find.text('Uložit')), findsOneWidget);
      expect(inSheet(find.text('Uložit a další')), findsNothing);
    });
  });

  group('period menu', () {
    testWidgets('Přiřadit hráče… comes first and opens the sheet like a '
        'tap', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(menuOf('po 12. 10. – ne 18. 10.'));
      await tester.pumpAndSettle();
      final items = ['Přiřadit hráče…', 'Upravit termín…', 'Smazat'];
      for (var i = 1; i < items.length; i++) {
        expect(
          tester.getTopLeft(find.text(items[i - 1])).dy,
          lessThan(tester.getTopLeft(find.text(items[i])).dy),
          reason: '${items[i - 1]} before ${items[i]}',
        );
      }
      await tester.tap(find.text('Přiřadit hráče…'));
      await tester.pumpAndSettle();

      expect(inSheet(find.text('po 12. 10. – ne 18. 10.')), findsOneWidget);
      expect(inSheet(find.text('Uložit a další')), findsOneWidget);
      await tester.tap(inSheet(find.text('Cyril Hudec')));
      await tester.tap(inSheet(find.text('Uložit')));
      await tester.pumpAndSettle();
      expect(log, ['assign p4 cyril']);
      expect(find.text('Uloženo.'), findsOneWidget);
    });

    testWidgets('Smazat asks first, then deletes', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(menuOf('po 5. 10. – ne 11. 10. · mimo so'));
      await tester.pumpAndSettle();
      expect(find.text('Upravit termín…'), findsOneWidget);
      await tester.tap(find.text('Smazat'));
      await tester.pumpAndSettle();
      expect(find.text('Smazat službu?'), findsOneWidget);
      expect(find.text('Přiřazení hráči o ni přijdou.'), findsOneWidget);

      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();
      expect(log, isEmpty);

      await tester.tap(menuOf('po 5. 10. – ne 11. 10. · mimo so'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Smazat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ano'));
      await tester.pumpAndSettle();
      expect(log, ['delete p3']);
    });

    testWidgets('Upravit termín… saves the period with its note', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(menuOf('po 12. 10. – ne 18. 10.'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Upravit termín…'));
      await tester.pumpAndSettle();

      expect(find.text('Upravit termín'), findsOneWidget);
      expect(inDialog(find.text('po 12. 10. 2026')), findsOneWidget);
      expect(inDialog(find.text('ne 18. 10. 2026')), findsOneWidget);
      await tester.enterText(inDialog(find.byType(TextField)), 'bez pátku');
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();
      expect(log, ['save p4 2026-10-12 2026-10-18 bez pátku']);
      expect(find.text('Upravit termín'), findsNothing);
    });

    testWidgets('Přidat službu continues after the last duty with its '
        'length', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Přidat službu'));
      await tester.pumpAndSettle();
      expect(inDialog(find.text('Přidat službu')), findsOneWidget);
      expect(inDialog(find.text('po 26. 10. 2026')), findsOneWidget);
      expect(inDialog(find.text('ne 1. 11. 2026')), findsOneWidget);
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();
      expect(log, ['save null 2026-10-26 2026-11-01 ']);
    });

    testWidgets('Smazat neobsazené budoucí… counts them from tomorrow', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Další akce'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Smazat neobsazené budoucí…'));
      await tester.pumpAndSettle();
      expect(find.text('Smazat neobsazené budoucí služby?'), findsOneWidget);
      expect(
        find.text(
          'Smaže se 1 služba bez hráčů, od čt 8. 10. dál. '
          'Obsazené zůstanou.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Ano'));
      await tester.pumpAndSettle();
      expect(log, ['deleteUnassigned 2026-10-08']);
      expect(find.text('Smazáno služeb: 1.'), findsOneWidget);
    });
  });

  group('seasons', () {
    testWidgets('Nová sezóna… names it after the year and warns about the '
        'running duty', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Sezóny'));
      await tester.pumpAndSettle();
      expect(find.text('Historie'), findsOneWidget);
      expect(find.text('Vrátit poslední sezónu'), findsOneWidget);
      await tester.tap(find.text('Nová sezóna…'));
      await tester.pumpAndSettle();

      expect(find.text('Nová sezóna'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(inDialog(find.byType(TextField)))
            .controller!
            .text,
        '2026/27',
      );
      expect(inDialog(find.text('Název')), findsOneWidget);
      expect(inDialog(find.text('st 7. 10. 2026')), findsOneWidget);
      expect(
        find.text(
          'Počty služeb začnou od nuly. Naplánované služby zůstanou a '
          'pokračují stejně. Historie se dá zobrazit.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'Služba po 5. 10. – ne 11. 10. začala dřív, a tak se '
          'počítá ještě do předchozí sezóny.',
        ),
        findsOneWidget,
      );

      await tester.enterText(inDialog(find.byType(TextField)), 'Podzim');
      await tester.tap(find.text('Začít sezónu'));
      await tester.pumpAndSettle();
      expect(log, ['season 2026-10-07 Podzim']);
      expect(find.text('Nová sezóna'), findsNothing);
    });

    testWidgets('Vrátit poslední sezónu asks, then deletes the newest '
        'boundary', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Sezóny'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vrátit poslední sezónu'));
      await tester.pumpAndSettle();
      expect(find.text('Vrátit poslední sezónu?'), findsOneWidget);
      await tester.tap(find.text('Vrátit'));
      await tester.pumpAndSettle();
      expect(log, ['undo 2026-09-01']);
    });

    testWidgets('with no season there is nothing to undo', (tester) async {
      await tester.pumpWidget(app(dutySeasons: const []));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Sezóny'));
      await tester.pumpAndSettle();
      final undo = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(PopupMenuItem<String>, 'Vrátit poslední sezónu'),
      );
      expect(undo.enabled, isFalse);
    });

    testWidgets('Historie opens the history screen', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Sezóny'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Historie'));
      await tester.pumpAndSettle();
      expect(find.byType(DutiesHistoryScreen), findsOneWidget);
      expect(find.text('Historie služeb'), findsOneWidget);
    });
  });

  group('history', () {
    testWidgets('opens on the season before this one, read-only; a chip '
        'switches the season', (tester) async {
      tall(tester);
      await tester.pumpWidget(app(home: const DutiesHistoryScreen()));
      await tester.pumpAndSettle();

      final first = find.widgetWithText(ChoiceChip, 'První sezóna');
      final current = find.widgetWithText(ChoiceChip, '2026/27');
      expect(
        tester.getTopLeft(first).dx,
        lessThan(tester.getTopLeft(current).dx),
      );
      expect(tester.widget<ChoiceChip>(first).selected, isTrue);

      expect(find.text('po 24. 8. – ne 30. 8.'), findsOneWidget);
      expect(
        find.text('Jana Nováková — 1 služba · 7 dní (1 odsloužena)'),
        findsOneWidget,
      );
      expect(find.text('Petr Svoboda — —'), findsOneWidget);
      expect(find.text('po 5. 10. – ne 11. 10. · mimo so'), findsNothing);
      // Read-only: no menus, and a tap opens nothing.
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      await tester.tap(find.text('po 24. 8. – ne 30. 8.'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Přidat službu'), findsNothing);

      await tester.tap(current);
      await tester.pumpAndSettle();
      expect(find.text('po 24. 8. – ne 30. 8.'), findsNothing);
      expect(find.text('po 5. 10. – ne 11. 10. · mimo so'), findsOneWidget);
      expect(find.text('Neobsazeno'), findsOneWidget);
      expect(
        find.text('Jana Nováková — 2 služby · 14 dní (1 odsloužena)'),
        findsOneWidget,
      );
    });
  });

  group('360 dp', () {
    testWidgets('the screen, the generator and the sheet fit a phone', (
      tester,
    ) async {
      phone(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // ensureVisible, not scrollUntilVisible: the latter stops once the
      // row is built, which can still be under the docked button bar.
      await tester.ensureVisible(find.text('Minulé služby (2)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Minulé služby (2)'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('po 21. 9. – ne 27. 9.'), findsOneWidget);

      await tester.tap(find.text('Vygenerovat…'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Po N dnech'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('po 12. 10. – ne 18. 10.'),
        -200,
      );
      await tester.ensureVisible(find.text('po 12. 10. – ne 18. 10.'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('po 12. 10. – ne 18. 10.'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(inSheet(find.text('Uložit a další')), findsOneWidget);
    });

    testWidgets('the history fits a phone', (tester) async {
      phone(tester);
      await tester.pumpWidget(app(home: const DutiesHistoryScreen()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
