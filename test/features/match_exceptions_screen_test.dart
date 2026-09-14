import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/profile/match_exceptions_screen.dart';

/// Výjimky: the one-match answers. The screen lists the WHOLE upcoming
/// schedule, ticked where the match is already the player's, so a tick adds
/// one their teams do not give and unticking hides one they do. Agreeing
/// with the teams stores nothing — the exception is dropped instead, which
/// is what the ✕ in the list up top does too.
void main() {
  final now = DateTime(2026, 9, 9, 10, 0); // středa
  final today = Day.fromDateTime(now);

  const me = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
    followedTeams: ['SKK Veverky Brno A'],
  );

  PrioritySlot match(
    String id,
    Day date,
    HourMinute start, {
    String home = 'KK Vyškov A',
    String away = 'KK Vyškov B',
    bool isAway = false,
    String description = '',
  }) =>
      PrioritySlot(
        id: id,
        date: date,
        startsAt: start,
        endsAt: HourMinute(start.hour + 3, start.minute),
        type: PrioritySlot.fallbackMatchType,
        homeTeam: home,
        awayTeam: away,
        isAway: isAway,
        description: description,
      );

  Widget app({
    List<PrioritySlot> slots = const [],
    Map<String, bool> exceptions = const {},
    Profile profile = me,
    List<CalendarTeam> routed = const [],
    CalendarLink link = CalendarLink.none,
    bool calendarAvailable = false,
    bool slotsLoading = false,
    bool slotsFailed = false,
    Future<void> Function(String matchId, bool? shown)? save,
  }) =>
      ProviderScope(
        overrides: [
          myProfileProvider.overrideWith((ref) => Stream.value(profile)),
          prioritySlotsProvider.overrideWithValue(slots),
          prioritySlotsLoadingProvider.overrideWithValue(slotsLoading),
          prioritySlotsFailedProvider.overrideWithValue(slotsFailed),
          myMatchExceptionsProvider.overrideWith((ref) => Stream.value(exceptions)),
          myCalendarTeamsProvider.overrideWith((ref) => Stream.value(routed)),
          myCalendarLinkProvider.overrideWith((ref) => Stream.value(link)),
          calendarAvailableProvider.overrideWithValue(calendarAvailable),
          nowProvider.overrideWith((ref) => Stream.value(now)),
        ],
        child: MaterialApp(
          home: MatchExceptionsScreen(
            setMatchException:
                save ?? (_, _) async => throw StateError('unexpected'),
          ),
        ),
      );

  Finder rowOf(String id) => find.byKey(ValueKey(id));
  bool ticked(WidgetTester tester, String id) =>
      tester.widget<CheckboxListTile>(rowOf(id)).value == true;

  testWidgets('lists the whole schedule by day, ticked where the match is '
      'already yours', (tester) async {
    await tester.pumpWidget(app(slots: [
      match('m1', today.addDays(1), const HourMinute(18, 0)),
      match('m2', today.addDays(1), const HourMinute(9, 0),
          home: 'KK Blansko', away: 'TJ Sokol Husovice'),
      match('m3', today.addDays(2), const HourMinute(10, 0),
          home: 'SKK Veverky Brno A', away: 'KK MS Brno D'),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('Výjimky'), findsOneWidget);
    // Everything is listed — including the match a followed team gives,
    // which is the only way to hide it.
    expect(rowOf('m1'), findsOneWidget);
    expect(rowOf('m2'), findsOneWidget);
    expect(rowOf('m3'), findsOneWidget);
    expect(ticked(tester, 'm3'), isTrue, reason: 'SKK Veverky is followed');
    expect(ticked(tester, 'm1'), isFalse);

    // Zítra, and within it the earlier match first.
    expect(find.text('Zítra'), findsOneWidget);
    expect(tester.getTopLeft(rowOf('m2')).dy,
        lessThan(tester.getTopLeft(rowOf('m1')).dy));
    expect(find.text('9:00–12:00 · doma'), findsOneWidget);
  });

  testWidgets('ticking a match no team gives adds it', (tester) async {
    final saved = <(String, bool?)>[];
    await tester.pumpWidget(app(
      slots: [match('m1', today.addDays(1), const HourMinute(18, 0))],
      save: (id, shown) async => saved.add((id, shown)),
    ));
    await tester.pumpAndSettle();

    await tester.tap(rowOf('m1'));
    await tester.pumpAndSettle();
    expect(saved, [('m1', true)]);
  });

  testWidgets('unticking a match a team gives hides it', (tester) async {
    final saved = <(String, bool?)>[];
    await tester.pumpWidget(app(
      slots: [
        match('m1', today.addDays(1), const HourMinute(18, 0),
            home: 'SKK Veverky Brno A', away: 'KK MS Brno D'),
      ],
      save: (id, shown) async => saved.add((id, shown)),
    ));
    await tester.pumpAndSettle();

    expect(ticked(tester, 'm1'), isTrue);
    await tester.tap(rowOf('m1'));
    await tester.pumpAndSettle();
    expect(saved, [('m1', false)]);
  });

  // Agreeing with the teams is not a decision worth storing: it drops the
  // exception instead, so the list up top cannot fill with rows that say
  // what the teams already say.
  testWidgets('ticking back to what the teams say drops the exception',
      (tester) async {
    final saved = <(String, bool?)>[];
    await tester.pumpWidget(app(
      slots: [
        // Hidden though its team gives it: ticking means "team, you were
        // right".
        match('m1', today.addDays(1), const HourMinute(18, 0),
            home: 'SKK Veverky Brno A', away: 'KK MS Brno D'),
        // Added though no team gives it: unticking means the same.
        match('m2', today.addDays(1), const HourMinute(20, 0)),
      ],
      exceptions: const {'m1': false, 'm2': true},
      save: (id, shown) async => saved.add((id, shown)),
    ));
    await tester.pumpAndSettle();

    expect(ticked(tester, 'm1'), isFalse);
    expect(ticked(tester, 'm2'), isTrue);

    await tester.tap(rowOf('m1'));
    await tester.pumpAndSettle();
    await tester.tap(rowOf('m2'));
    await tester.pumpAndSettle();
    expect(saved, [('m1', null), ('m2', null)]);
  });

  group('Tvoje výjimky', () {
    testWidgets('names what was overruled, which way, and takes it back',
        (tester) async {
      final saved = <(String, bool?)>[];
      await tester.pumpWidget(app(
        slots: [
          match('m1', today.addDays(1), const HourMinute(18, 0)),
          match('m2', today.addDays(2), const HourMinute(10, 0),
              home: 'SKK Veverky Brno A', away: 'KK MS Brno D'),
        ],
        exceptions: const {'m1': true, 'm2': false},
        save: (id, shown) async => saved.add((id, shown)),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Tvoje výjimky'), findsOneWidget);
      expect(find.text('čt 10.9. · přidáno'), findsOneWidget);
      expect(find.text('pá 11.9. · skryto'), findsOneWidget);

      // ✕ hands the match back to the teams — the same "no opinion" a tick
      // back would have stored.
      await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('exception:m1')),
        matching: find.byTooltip('Zrušit výjimku'),
      ));
      await tester.pumpAndSettle();
      expect(saved, [('m1', null)]);
    });

    testWidgets('is not there when nothing is overruled', (tester) async {
      await tester.pumpWidget(app(
        slots: [match('m1', today.addDays(1), const HourMinute(18, 0))],
      ));
      await tester.pumpAndSettle();
      expect(find.text('Tvoje výjimky'), findsNothing);
    });
  });

  testWidgets('the search narrows the schedule and leaves the exceptions '
      'alone', (tester) async {
    await tester.pumpWidget(app(
      slots: [
        match('m1', today.addDays(1), const HourMinute(18, 0),
            home: 'KK Vyškov A', away: 'KK Vyškov B'),
        match('m2', today.addDays(1), const HourMinute(9, 0),
            home: 'TJ Sokol Husovice', away: 'KK Blansko'),
      ],
      exceptions: const {'m1': true},
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'husovice');
    await tester.pumpAndSettle();
    expect(rowOf('m2'), findsOneWidget);
    expect(rowOf('m1'), findsNothing, reason: 'filtered out of the schedule');
    // …but the exception is still there to be taken back, which is what one
    // comes back to this screen for.
    expect(find.byKey(const ValueKey('exception:m1')), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'nikdo');
    await tester.pumpAndSettle();
    expect(find.text('Nikdo neodpovídá hledání'), findsOneWidget);
  });

  testWidgets('the promise names the main calendar only when there are two',
      (tester) async {
    await tester.pumpWidget(app(
      slots: [match('m1', today.addDays(1), const HourMinute(18, 0))],
      calendarAvailable: true,
      link: const CalendarLink(status: CalendarLinkStatus.linked),
    ));
    await tester.pumpAndSettle();
    expect(
      find.text('Přidaný zápas uvidíš v Můj přehled a přijde ti do Google '
          'kalendáře.'),
      findsOneWidget,
    );
  });

  testWidgets('with a second calendar it says which one', (tester) async {
    await tester.pumpWidget(app(
      slots: [match('m1', today.addDays(1), const HourMinute(18, 0))],
      calendarAvailable: true,
      link: const CalendarLink(
          status: CalendarLinkStatus.linked, secondaryEnabled: true),
    ));
    await tester.pumpAndSettle();
    expect(
      find.text('Přidaný zápas uvidíš v Můj přehled a přijde ti do hlavního '
          'Google kalendáře.'),
      findsOneWidget,
    );
  });

  testWidgets('without a calendar it promises only the overview',
      (tester) async {
    await tester.pumpWidget(app(
      slots: [match('m1', today.addDays(1), const HourMinute(18, 0))],
    ));
    await tester.pumpAndSettle();
    expect(find.text('Přidaný zápas uvidíš v Můj přehled.'), findsOneWidget);
  });

  testWidgets('an empty schedule says so', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('V rozpisu nejsou žádné další zápasy'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNothing);
  });

  testWidgets('a failed save says so in Czech, not as an exception',
      (tester) async {
    await tester.pumpWidget(app(
      slots: [match('m1', today.addDays(1), const HourMinute(18, 0))],
      save: (_, _) async => throw Exception('match_past'),
    ));
    await tester.pumpAndSettle();

    await tester.tap(rowOf('m1'));
    await tester.pumpAndSettle();
    expect(find.text('Tenhle zápas už byl.'), findsOneWidget);
  });

  testWidgets('a slow schedule is a spinner, a failed one a retry',
      (tester) async {
    await tester.pumpWidget(app(slotsLoading: true));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpWidget(app(slotsFailed: true));
    await tester.pumpAndSettle();
    expect(find.text('Zápasy se nepodařilo načíst.'), findsOneWidget);
    expect(find.text('Zkusit znovu'), findsOneWidget);
  });
}
