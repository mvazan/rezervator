import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart' show dayFull;
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/palette.dart';
import 'package:rezervator/features/schedule/my_trainings_screen.dart';

void main() {
  final now = DateTime(2026, 9, 9, 10, 0); // středa
  final today = Day.fromDateTime(now);
  const b1 = TimeBlock(
    id: 'b1',
    startsAt: HourMinute(18, 0),
    endsAt: HourMinute(19, 0),
    position: 0,
    active: true,
  );
  const me = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
    followedTeams: ['SKK Veverky Brno A'],
  );
  const nobody = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
  );
  Reservation res(String id, Day date) => Reservation(
        id: id,
        playerId: 'me',
        date: date,
        blockId: 'b1',
        lane: 2,
        createdVia: 'app',
        createdAt: DateTime.utc(2026, 1, 1),
      );
  final match = PrioritySlot(
    id: 'm1',
    date: today.addDays(2),
    startsAt: const HourMinute(18, 30),
    endsAt: const HourMinute(21, 30),
    type: PrioritySlot.fallbackMatchType,
    homeTeam: 'SKK Veverky Brno A',
    awayTeam: 'KK MS Brno D',
    description: 'KP1 Sever',
  );

  Widget app({
    Profile profile = me,
    List<Reservation> reservations = const [],
    List<PrioritySlot> slots = const [],
    Map<String, int> teamColors = const <String, int>{},
    Stream<List<Reservation>>? reservationsStream,
    Future<void> Function(String id)? cancel,
    VoidCallback? onOpenCalendar,
    bool slotsLoading = false,
    bool slotsFailed = false,
    int? trainingColorId,
    DateTime? nowOverride,
  }) {
    return ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(profile)),
        myActiveReservationsProvider.overrideWith(
            (ref) => reservationsStream ?? Stream.value(reservations)),
        timeBlocksProvider.overrideWith((ref) => Stream.value(const [b1])),
        prioritySlotsProvider.overrideWithValue(slots),
        // _prioritySlotRowsProvider is private to providers.dart, so a test
        // that wants to simulate it still being pending overrides this
        // public signal directly instead.
        prioritySlotsLoadingProvider.overrideWithValue(slotsLoading),
        prioritySlotsFailedProvider.overrideWithValue(slotsFailed),
        nowProvider.overrideWith((ref) => Stream.value(nowOverride ?? now)),
        myTeamColorsProvider.overrideWith((ref) => Stream.value(teamColors)),
        myCalendarLinkProvider.overrideWith((ref) => Stream.value(
              trainingColorId == null
                  ? CalendarLink.none
                  : CalendarLink(
                      status: CalendarLinkStatus.linked,
                      trainingColorId: trainingColorId,
                    ),
            )),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: MyTrainingsScreen(
            onOpenCalendar: onOpenCalendar ?? () {},
            cancelReservation: cancel ?? (_) async => throw StateError('unexpected'),
          ),
        ),
      ),
    );
  }

  testWidgets('lists trainings and followed matches by day, today and '
      'tomorrow by name', (tester) async {
    await tester.pumpWidget(app(
      reservations: [res('r1', today), res('r2', today.addDays(1))],
      slots: [match],
    ));
    await tester.pumpAndSettle();

    expect(find.text('Můj přehled'), findsOneWidget);
    expect(find.text('Dnes'), findsOneWidget);
    expect(find.text('Zítra'), findsOneWidget);
    // A day beyond tomorrow (the match, two days out) is labelled with the
    // full weekday name, not a relative one.
    expect(find.text(dayFull(today.addDays(2))), findsOneWidget);
    expect(find.text('18:00–19:00 · Dráha 2'), findsNWidgets(2));
    expect(find.text('SKK Veverky Brno A – KK MS Brno D'), findsOneWidget);
    expect(find.text('18:30–21:30 · doma · KP1 Sever'), findsOneWidget);
    // Chronological: today's training above the match two days out.
    expect(
      tester.getTopLeft(find.text('Dnes')).dy,
      lessThan(tester.getTopLeft(find.text('SKK Veverky Brno A – KK MS Brno D')).dy),
    );
    expect(find.textContaining('Moje týmy'), findsNothing);
  });

  testWidgets('while reservations have not loaded yet shows a progress '
      'indicator, never the empty state', (tester) async {
    final ctrl = StreamController<List<Reservation>>();
    addTearDown(ctrl.close);
    // No pumpAndSettle: the indicator's animation never settles on its own,
    // and a single pumpWidget frame already flushes every OTHER overridden
    // stream (blocks, profile, now) via their microtask, leaving only the
    // reservations stream genuinely stuck loading.
    await tester.pumpWidget(app(reservationsStream: ctrl.stream));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Zatím nic.'), findsNothing);
  });

  testWidgets('while priority slots have not delivered their first snapshot '
      'yet shows a progress indicator, never the empty state', (tester) async {
    // reservations/blocks resolve normally on the first frame; only the
    // slots stream is still pending (see prioritySlotsLoadingProvider) — a
    // player who follows teams but has no reservation must not see "Zatím
    // nic." while the match slots are still on their way in.
    await tester.pumpWidget(app(slotsLoading: true));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Zatím nic.'), findsNothing);
  });

  testWidgets('when the reservations stream errors, shows the error text '
      'and a retry button', (tester) async {
    await tester.pumpWidget(
      app(reservationsStream: Stream.error(StateError('boom'))),
    );
    await tester.pumpAndSettle();

    expect(find.text('Přehled se nepodařilo načíst.'), findsOneWidget);
    expect(find.text('Zkusit znovu'), findsOneWidget);
    expect(find.text('Zatím nic.'), findsNothing);
  });

  testWidgets('when the priority slots failed before their first snapshot, '
      'shows the error text with a retry, never the empty state',
      (tester) async {
    // The cache rethrows only a first-ever error, so a cache-less player
    // whose priority_slots fetch fails would otherwise see a quiet list
    // without their teams' matches — indistinguishable from "nothing
    // scheduled" (see prioritySlotsFailedProvider).
    await tester.pumpWidget(app(slotsFailed: true));
    await tester.pumpAndSettle();

    expect(find.text('Přehled se nepodařilo načíst.'), findsOneWidget);
    expect(find.text('Zkusit znovu'), findsOneWidget);
    expect(find.text('Zatím nic.'), findsNothing);
  });

  testWidgets('tapping a training asks, then cancels it', (tester) async {
    final cancelled = <String>[];
    await tester.pumpWidget(app(
      reservations: [res('r1', today.addDays(1))],
      cancel: (id) async => cancelled.add(id),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('18:00–19:00 · Dráha 2'));
    await tester.pumpAndSettle();
    expect(find.text('Zrušit rezervaci?'), findsOneWidget);
    await tester.tap(find.text('Zrušit rezervaci'));
    await tester.pumpAndSettle();

    expect(cancelled, ['r1']);
    expect(find.text('Rezervace zrušena.'), findsOneWidget);
  });

  testWidgets('a training whose block already started today offers no '
      'cancel, but stays listed', (tester) async {
    await tester.pumpWidget(app(
      reservations: [res('r1', today)],
      // b1 is 18:00–19:00; the calendar refuses cancel once startsAt has
      // passed (domain/schedule.dart's canCancel) — Můj přehled must
      // agree instead of offering a cancel the RPC would reject.
      nowOverride: DateTime(2026, 9, 9, 18, 30),
    ));
    await tester.pumpAndSettle();

    expect(find.text('18:00–19:00 · Dráha 2'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);

    await tester.tap(find.text('18:00–19:00 · Dráha 2'));
    await tester.pumpAndSettle();
    expect(find.text('Zrušit rezervaci?'), findsNothing);
  });

  testWidgets('empty: says so and the button opens the calendar', (tester) async {
    var opened = 0;
    await tester.pumpWidget(app(onOpenCalendar: () => opened++));
    await tester.pumpAndSettle();

    expect(find.text('Zatím nic.'), findsOneWidget);
    // `me` follows a team, just has no upcoming match for it right now —
    // the hint is for "you follow nobody", so it must stay hidden here.
    expect(find.textContaining('Moje týmy'), findsNothing);
    await tester.tap(find.text('Do kalendáře'));
    expect(opened, 1);
  });

  testWidgets('empty and following no teams: the hint shows below "Do '
      'kalendáře" too', (tester) async {
    await tester.pumpWidget(app(profile: nobody));
    await tester.pumpAndSettle();

    expect(find.text('Zatím nic.'), findsOneWidget);
    expect(find.textContaining('Moje týmy'), findsOneWidget);
  });

  testWidgets('without followed teams the list ends with the hint', (tester) async {
    await tester.pumpWidget(app(
      profile: nobody,
      reservations: [res('r1', today)],
      slots: [match],
    ));
    await tester.pumpAndSettle();

    expect(find.text('SKK Veverky Brno A – KK MS Brno D'), findsNothing);
    expect(find.textContaining('Moje týmy'), findsOneWidget);
  });

  // ---------------------------------------------------------------------
  // Match trophy colour (0036): the SAME registry the profile's team
  // pickers edit (myTeamColorsProvider).
  // ---------------------------------------------------------------------

  group('match trophy colour (0036)', () {
    // The trophy paints a derived shade, legible on the surface (light
    // theme here, MaterialApp's default) — never Google's raw event RGB;
    // see legibleShadeOf and _trophyColorOf's own doc comment.
    Color colorNamed(String name) => legibleShadeOf(
        googleEventColors.firstWhere((c) => c.$2 == name).$3, Brightness.light);

    // match's default teams: home 'SKK Veverky Brno A', away 'KK MS Brno D'.
    final awayMatch = PrioritySlot(
      id: 'm2',
      date: today.addDays(3),
      startsAt: const HourMinute(18, 0),
      endsAt: const HourMinute(21, 0),
      type: PrioritySlot.fallbackMatchType,
      homeTeam: 'KK Blansko B',
      awayTeam: 'SKK Veverky Brno A',
      isAway: true,
    );

    testWidgets('neither team coloured keeps today\'s plain trophy', (
      tester,
    ) async {
      await tester.pumpWidget(app(slots: [match]));
      await tester.pumpAndSettle();

      final icon =
          tester.widget<Icon>(find.byIcon(Icons.emoji_events_outlined));
      expect(icon.color, isNull);
    });

    testWidgets('the followed HOME team\'s colour tints the trophy', (
      tester,
    ) async {
      await tester.pumpWidget(app(
        slots: [match],
        teamColors: const {'SKK Veverky Brno A': 3},
      ));
      await tester.pumpAndSettle();

      final icon =
          tester.widget<Icon>(find.byIcon(Icons.emoji_events_outlined));
      expect(icon.color, colorNamed('Švestková'));
    });

    testWidgets('the followed AWAY team\'s colour tints the trophy too', (
      tester,
    ) async {
      await tester.pumpWidget(app(
        slots: [awayMatch],
        teamColors: const {'SKK Veverky Brno A': 6},
      ));
      await tester.pumpAndSettle();

      final icon =
          tester.widget<Icon>(find.byIcon(Icons.emoji_events_outlined));
      expect(icon.color, colorNamed('Mandarinková'));
    });

    testWidgets('a derby — both teams coloured — tints with the HOME '
        'team\'s colour, same tie-break as the Google event', (tester) async {
      const bothFollower = Profile(
        id: 'me',
        displayName: 'Já Hráč',
        email: 'me@example.com',
        role: Role.player,
        status: ProfileStatus.approved,
        followedTeams: ['SKK Veverky Brno A', 'KK MS Brno D'],
      );
      await tester.pumpWidget(app(
        profile: bothFollower,
        slots: [match], // home 'SKK Veverky Brno A', away 'KK MS Brno D'
        teamColors: const {'SKK Veverky Brno A': 4, 'KK MS Brno D': 9},
      ));
      await tester.pumpAndSettle();

      final icon =
          tester.widget<Icon>(find.byIcon(Icons.emoji_events_outlined));
      expect(icon.color, colorNamed('Lososová'));
    });

    testWidgets('a colour on a team the player does NOT follow never '
        'paints a match that only shows because the OTHER team is '
        'followed', (tester) async {
      const devitkaFollower = Profile(
        id: 'me',
        displayName: 'Já Hráč',
        email: 'me@example.com',
        role: Role.player,
        status: ProfileStatus.approved,
        followedTeams: ['KS Devítka Brno B'],
      );
      final derby = PrioritySlot(
        id: 'm3',
        date: today.addDays(2),
        startsAt: const HourMinute(18, 0),
        endsAt: const HourMinute(20, 0),
        type: PrioritySlot.fallbackMatchType,
        homeTeam: 'SKK Veverky Brno A',
        awayTeam: 'KS Devítka Brno B',
      );
      await tester.pumpWidget(app(
        profile: devitkaFollower,
        slots: [derby],
        // Veverky was once coloured, but the player follows only Devítka.
        teamColors: const {'SKK Veverky Brno A': 11},
      ));
      await tester.pumpAndSettle();

      // The match is listed at all (Devítka is followed) …
      expect(find.text('SKK Veverky Brno A – KS Devítka Brno B'), findsOneWidget);
      // … but its trophy must stay plain, not Veverky's red.
      final icon =
          tester.widget<Icon>(find.byIcon(Icons.emoji_events_outlined));
      expect(icon.color, isNull);
    });
  });

  group('training colour', () {
    Color colorNamed(String name) => legibleShadeOf(
        googleEventColors.firstWhere((c) => c.$2 == name).$3, Brightness.light);

    testWidgets('without a training colour the T stays plain', (tester) async {
      await tester.pumpWidget(app(reservations: [res('r1', today)]));
      await tester.pumpAndSettle();

      expect(tester.widget<Icon>(find.byIcon(Icons.title)).color, isNull);
    });

    testWidgets('the training colour tints the T, in the same derived shade '
        'the trophy uses', (tester) async {
      await tester.pumpWidget(app(
        reservations: [res('r1', today)],
        trainingColorId: 5,
      ));
      await tester.pumpAndSettle();

      expect(
        tester.widget<Icon>(find.byIcon(Icons.title)).color,
        colorNamed('Banánová'),
      );
    });

    testWidgets('a training and a match each take their own colour', (
      tester,
    ) async {
      await tester.pumpWidget(app(
        reservations: [res('r1', today)],
        slots: [match],
        teamColors: const {'SKK Veverky Brno A': 3},
        trainingColorId: 5,
      ));
      await tester.pumpAndSettle();

      expect(
        tester.widget<Icon>(find.byIcon(Icons.title)).color,
        colorNamed('Banánová'),
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.emoji_events_outlined)).color,
        colorNamed('Švestková'),
      );
    });
  });
}
