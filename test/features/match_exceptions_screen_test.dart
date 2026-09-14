import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/profile/match_exceptions_screen.dart';

/// Výjimky: the one screen where a player says "I am playing this one" for
/// a match neither of whose teams is theirs. It offers only what they do
/// not already have, and every tick saves at once (there is nothing to
/// batch — the Google side rides the job queue either way).
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
    Set<String> exceptions = const {},
    Profile profile = me,
    List<CalendarTeam> routed = const [],
    CalendarLink link = CalendarLink.none,
    bool calendarAvailable = false,
    bool slotsLoading = false,
    bool slotsFailed = false,
    Future<void> Function(String matchId, bool on)? save,
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

  testWidgets('lists the matches that are not already yours, by day',
      (tester) async {
    await tester.pumpWidget(app(slots: [
      match('m1', today.addDays(1), const HourMinute(18, 0)),
      match('m2', today.addDays(1), const HourMinute(9, 0),
          home: 'KK Blansko', away: 'TJ Sokol Husovice'),
      // Ours already: followed, and no calendar to route it to.
      match('m3', today.addDays(2), const HourMinute(10, 0),
          home: 'SKK Veverky Brno A', away: 'KK MS Brno D'),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('Výjimky'), findsOneWidget);
    expect(rowOf('m1'), findsOneWidget);
    expect(rowOf('m2'), findsOneWidget);
    expect(rowOf('m3'), findsNothing, reason: 'that one is already yours');

    // Zítra, and within it the earlier match first.
    expect(find.text('Zítra'), findsOneWidget);
    expect(tester.getTopLeft(rowOf('m2')).dy,
        lessThan(tester.getTopLeft(rowOf('m1')).dy));
    expect(find.text('9:00–12:00 · doma'), findsOneWidget);
  });

  testWidgets('a tick saves at once, and the row shows the server\'s answer '
      'rather than the tap', (tester) async {
    final saved = <(String, bool)>[];
    await tester.pumpWidget(app(
      slots: [match('m1', today.addDays(1), const HourMinute(18, 0))],
      save: (id, on) async => saved.add((id, on)),
    ));
    await tester.pumpAndSettle();

    expect(ticked(tester, 'm1'), isFalse);
    await tester.tap(rowOf('m1'));
    await tester.pumpAndSettle();
    expect(saved, [('m1', true)]);

    // The tick comes back through the stream, not from the tap: with the
    // stream pinned to "no exceptions" the row stays unticked, so tapping
    // again asks for the same thing rather than toggling to false against a
    // state the server never confirmed.
    expect(ticked(tester, 'm1'), isFalse);
    await tester.tap(rowOf('m1'));
    await tester.pumpAndSettle();
    expect(saved, [('m1', true), ('m1', true)]);
  });

  testWidgets('an already-excepted match reads ticked and switches off',
      (tester) async {
    final saved = <(String, bool)>[];
    await tester.pumpWidget(app(
      slots: [match('m1', today.addDays(1), const HourMinute(18, 0))],
      exceptions: const {'m1'},
      save: (id, on) async => saved.add((id, on)),
    ));
    await tester.pumpAndSettle();

    expect(ticked(tester, 'm1'), isTrue);
    await tester.tap(rowOf('m1'));
    await tester.pumpAndSettle();
    expect(saved, [('m1', false)]);
  });

  // A team whose matches go to the SECOND calendar is still on offer: this
  // screen is how one of them comes over to the main one.
  testWidgets('a team in the second calendar is still worth an exception',
      (tester) async {
    await tester.pumpWidget(app(
      slots: [
        match('m1', today.addDays(1), const HourMinute(18, 0),
            home: 'SKK Veverky Brno A', away: 'KK MS Brno D'),
      ],
      calendarAvailable: true,
      link: const CalendarLink(
          status: CalendarLinkStatus.linked, secondaryEnabled: true),
      routed: const [
        CalendarTeam(
            team: 'SKK Veverky Brno A', calendar: CalendarSlot.secondary),
      ],
    ));
    await tester.pumpAndSettle();

    expect(rowOf('m1'), findsOneWidget);
    expect(
      find.text('Zaškrtnutý zápas uvidíš v Můj přehled a přijde ti do '
          'hlavního Google kalendáře.'),
      findsOneWidget,
    );
  });

  testWidgets('without a calendar the screen promises only the overview',
      (tester) async {
    await tester.pumpWidget(app(
      slots: [match('m1', today.addDays(1), const HourMinute(18, 0))],
    ));
    await tester.pumpAndSettle();

    expect(find.text('Zaškrtnutý zápas uvidíš v Můj přehled.'), findsOneWidget);
  });

  testWidgets('nothing to add says so', (tester) async {
    await tester.pumpWidget(app(slots: [
      match('m1', today.addDays(1), const HourMinute(18, 0),
          home: 'SKK Veverky Brno A', away: 'KK MS Brno D'),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('Není co přidat'), findsOneWidget);
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
