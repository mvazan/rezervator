import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart' show dayFull;
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/palette.dart';
import 'package:rezervator/features/clubhouse/match_detail_screen.dart';
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
    Stream<Profile>? profileStream,
    Stream<Map<String, bool>>? exceptionsStream,
    Future<void> Function(String id)? cancel,
    VoidCallback? onOpenCalendar,
    bool slotsLoading = false,
    bool slotsFailed = false,
    int? trainingColorId,
    DateTime? nowOverride,
    Map<String, bool> exceptions = const {},
    Map<String, MatchResult> results = const {},
  }) {
    return ProviderScope(
      overrides: [
        myProfileProvider.overrideWith(
          (ref) => profileStream ?? Stream.value(profile),
        ),
        myActiveReservationsProvider.overrideWith(
          (ref) => reservationsStream ?? Stream.value(reservations),
        ),
        timeBlocksProvider.overrideWith((ref) => Stream.value(const [b1])),
        prioritySlotsProvider.overrideWithValue(slots),
        // _prioritySlotRowsProvider is private to providers.dart, so a test
        // that wants to simulate it still being pending overrides this
        // public signal directly instead.
        prioritySlotsLoadingProvider.overrideWithValue(slotsLoading),
        prioritySlotsFailedProvider.overrideWithValue(slotsFailed),
        nowProvider.overrideWith((ref) => Stream.value(nowOverride ?? now)),
        myTeamColorsProvider.overrideWith((ref) => Stream.value(teamColors)),
        myMatchExceptionsProvider.overrideWith(
          (ref) => exceptionsStream ?? Stream.value(exceptions),
        ),
        matchResultsProvider.overrideWith((ref) => Stream.value(results)),
        // MatchDetailScreen (pushed on a played match's tap) watches these
        // two as well.
        matchPlayerResultsProvider.overrideWith(
          (ref, id) => Stream.value(const []),
        ),
        venuesProvider.overrideWith((ref) => Stream.value(const [])),
        myCalendarLinkProvider.overrideWith(
          (ref) => Stream.value(
            trainingColorId == null
                ? CalendarLink.none
                : CalendarLink(
                    status: CalendarLinkStatus.linked,
                    trainingColorId: trainingColorId,
                  ),
          ),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: MyTrainingsScreen(
            onOpenCalendar: onOpenCalendar ?? () {},
            cancelReservation:
                cancel ?? (_) async => throw StateError('unexpected'),
          ),
        ),
      ),
    );
  }

  testWidgets('lists trainings and followed matches by day, today and '
      'tomorrow by name', (tester) async {
    await tester.pumpWidget(
      app(
        reservations: [res('r1', today), res('r2', today.addDays(1))],
        slots: [match],
      ),
    );
    await tester.pumpAndSettle();

    // The shared home strip: the app's name, not the view's — which view
    // this is, the shell's tabs say.
    expect(find.text('Rezervátor'), findsOneWidget);
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
      lessThan(
        tester.getTopLeft(find.text('SKK Veverky Brno A – KK MS Brno D')).dy,
      ),
    );
    expect(find.textContaining('Moje týmy'), findsNothing);
  });

  testWidgets('a past match of a followed team is listed, above today\'s '
      'entries', (tester) async {
    final pastMatch = PrioritySlot(
      id: 'past',
      date: today.addDays(-3),
      startsAt: const HourMinute(18, 30),
      endsAt: const HourMinute(21, 30),
      type: PrioritySlot.fallbackMatchType,
      homeTeam: 'SKK Veverky Brno A',
      awayTeam: 'KK MS Brno D',
      description: 'KP1 Sever',
      importKey: 'cka:past',
    );
    await tester.pumpWidget(
      app(reservations: [res('r1', today)], slots: [pastMatch, match]),
    );
    await tester.pumpAndSettle();

    expect(find.text(dayFull(today.addDays(-3))), findsOneWidget);
    expect(
      tester.getTopLeft(find.text(dayFull(today.addDays(-3)))).dy,
      lessThan(tester.getTopLeft(find.text('Dnes')).dy),
    );
  });

  testWidgets('opens scrolled to the first day at/after today, past days '
      'scrolled above', (tester) async {
    final pastMatches = [
      for (var i = 3; i >= 1; i--)
        PrioritySlot(
          id: 'past$i',
          date: today.addDays(-i),
          startsAt: const HourMinute(18, 30),
          endsAt: const HourMinute(21, 30),
          type: PrioritySlot.fallbackMatchType,
          homeTeam: 'SKK Veverky Brno A',
          awayTeam: 'KK MS Brno D',
          importKey: 'cka:past$i',
        ),
    ];
    final futureMatches = [
      for (var i = 1; i <= 10; i++)
        PrioritySlot(
          id: 'future$i',
          date: today.addDays(i),
          startsAt: const HourMinute(18, 30),
          endsAt: const HourMinute(21, 30),
          type: PrioritySlot.fallbackMatchType,
          homeTeam: 'SKK Veverky Brno A',
          awayTeam: 'KK MS Brno D',
          importKey: 'cka:future$i',
        ),
    ];
    await tester.pumpWidget(
      app(
        reservations: [res('r1', today)],
        slots: [...pastMatches, ...futureMatches],
      ),
    );
    await tester.pumpAndSettle();

    final earliestHeader = tester.getTopLeft(
      find.text(dayFull(today.addDays(-3))),
    );
    final todayHeader = tester.getTopLeft(find.text('Dnes'));
    expect(earliestHeader.dy, lessThan(0));
    expect(todayHeader.dy, inInclusiveRange(0, 200));
  });

  testWidgets('the scroll waits for the profile stream too, not just slots — a '
      'reservations-only partial list must not lock in the scroll target', (
    tester,
  ) async {
    // Matches need `teams` (from myProfileProvider) to be on the list at
    // all — while the profile stream is still pending, `days` only has the
    // reservation (today+5), a single day whose own "scroll" is a no-op
    // (nothing to scroll past). If that no-op latches `_scrolledToUpcoming`
    // regardless, the PAST matches below (today-10..-1, needing `teams`
    // too — plenty of them, so an un-rescrolled offset leaves "Zítra" well
    // outside the top of the viewport, not just a few px off) later arrive
    // ABOVE it with no re-scroll to push them out of view — so "Zítra"
    // (today+1, the real first upcoming day) ends up hidden below the fold
    // instead of at the top.
    final pastMatches = [
      for (var i = 10; i >= 1; i--)
        PrioritySlot(
          id: 'past$i',
          date: today.addDays(-i),
          startsAt: const HourMinute(18, 30),
          endsAt: const HourMinute(21, 30),
          type: PrioritySlot.fallbackMatchType,
          homeTeam: 'SKK Veverky Brno A',
          awayTeam: 'KK MS Brno D',
          importKey: 'cka:past$i',
        ),
    ];
    final upcomingMatches = [
      for (var i = 1; i <= 3; i++)
        PrioritySlot(
          id: 'upcoming$i',
          date: today.addDays(i),
          startsAt: const HourMinute(18, 30),
          endsAt: const HourMinute(21, 30),
          type: PrioritySlot.fallbackMatchType,
          homeTeam: 'SKK Veverky Brno A',
          awayTeam: 'KK MS Brno D',
          importKey: 'cka:upcoming$i',
        ),
    ];
    final profileCtrl = StreamController<Profile>();
    addTearDown(profileCtrl.close);
    await tester.pumpWidget(
      app(
        reservations: [res('r1', today.addDays(5))],
        slots: [...pastMatches, ...upcomingMatches],
        profileStream: profileCtrl.stream,
      ),
    );
    await tester.pump();

    // Profile still pending: only the reservation's day is on the list.
    expect(find.text(dayFull(today.addDays(5))), findsOneWidget);

    profileCtrl.add(me); // delivers teams: ['SKK Veverky Brno A']
    await tester.pumpAndSettle();

    // Now the real, earlier upcoming day (today+1, labelled "Zítra") is the
    // correct scroll target — proving the scroll waited for the profile
    // stream instead of latching onto the reservation-only list (which
    // would have left the ten PAST days' headers pinned at the top and
    // "Zítra" scrolled far below the fold instead).
    final earliestPastHeader = tester.getTopLeft(
      find.text(dayFull(today.addDays(-10))),
    );
    final firstUpcomingHeader = tester.getTopLeft(find.text('Zítra'));
    expect(firstUpcomingHeader.dy, inInclusiveRange(0, 200));
    expect(earliestPastHeader.dy, lessThan(firstUpcomingHeader.dy));
  });

  group('scrolled to what is upcoming after the list changes', () {
    PrioritySlot teamMatch(String id, int dayOffset, {String? home}) =>
        PrioritySlot(
          id: id,
          date: today.addDays(dayOffset),
          startsAt: const HourMinute(18, 30),
          endsAt: const HourMinute(21, 30),
          type: PrioritySlot.fallbackMatchType,
          homeTeam: home ?? 'SKK Veverky Brno A',
          awayTeam: 'KK MS Brno D',
          importKey: 'cka:$id',
        );
    final season = [
      for (var i = 12; i >= 1; i--) teamMatch('past$i', -i),
      for (var i = 1; i <= 10; i++) teamMatch('future$i', i),
    ];

    double scrollPixels(WidgetTester tester) =>
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;

    testWidgets('following a team later re-scrolls past its played matches', (
      tester,
    ) async {
      final profileCtrl = StreamController<Profile>();
      addTearDown(profileCtrl.close);
      await tester.pumpWidget(
        app(
          reservations: [res('r1', today)],
          slots: season,
          profileStream: profileCtrl.stream,
        ),
      );
      profileCtrl.add(nobody);
      await tester.pumpAndSettle();
      // Only today's training: nothing to scroll past yet.
      expect(find.text('Dnes'), findsOneWidget);
      expect(find.text(dayFull(today.addDays(-12))), findsNothing);

      profileCtrl.add(me); // the player picks their team in Moje týmy
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.text(dayFull(today.addDays(-12)))).dy,
        lessThan(0),
      );
      expect(tester.getTopLeft(find.text('Dnes')).dy, inInclusiveRange(0, 200));
    });

    testWidgets(
      'a list rebuilt after a spinner (tenant switch) scrolls again',
      (tester) async {
        await tester.pumpWidget(
          app(reservations: [res('r1', today)], slots: season),
        );
        await tester.pumpAndSettle();
        expect(scrollPixels(tester), greaterThan(0));

        // The kuželna's streams restart: the spinner replaces the list.
        await tester.pumpWidget(
          app(
            reservations: [res('r1', today)],
            slots: season,
            slotsLoading: true,
          ),
        );
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        // Same shape of list for the new kuželna — a brand-new scroll view.
        await tester.pumpWidget(
          app(reservations: [res('r1', today)], slots: season),
        );
        await tester.pumpAndSettle();

        expect(
          tester.getTopLeft(find.text(dayFull(today.addDays(-12)))).dy,
          lessThan(0),
        );
        expect(
          tester.getTopLeft(find.text('Dnes')).dy,
          inInclusiveRange(0, 200),
        );
      },
    );

    testWidgets('once the player scrolls by hand, a later change leaves '
        'the list where they put it', (tester) async {
      final profileCtrl = StreamController<Profile>();
      addTearDown(profileCtrl.close);
      await tester.pumpWidget(
        app(
          reservations: [res('r1', today)],
          slots: [
            ...season,
            for (var i = 12; i >= 1; i--)
              teamMatch('otherPast$i', -12 - i, home: 'SKK Veverky Brno B'),
          ],
          profileStream: profileCtrl.stream,
        ),
      );
      profileCtrl.add(me);
      await tester.pumpAndSettle();

      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      final byHand = scrollPixels(tester);

      // A second followed team brings its own played matches above today.
      profileCtrl.add(
        const Profile(
          id: 'me',
          displayName: 'Já Hráč',
          email: 'me@example.com',
          role: Role.player,
          status: ProfileStatus.approved,
          followedTeams: ['SKK Veverky Brno A', 'SKK Veverky Brno B'],
        ),
      );
      await tester.pumpAndSettle();

      expect(scrollPixels(tester), byHand);
    });
  });

  testWidgets('a past finished federation match shows its score', (
    tester,
  ) async {
    final pastMatch = PrioritySlot(
      id: 'past',
      date: today.addDays(-3),
      startsAt: const HourMinute(18, 30),
      endsAt: const HourMinute(21, 30),
      type: PrioritySlot.fallbackMatchType,
      homeTeam: 'SKK Veverky Brno A',
      awayTeam: 'KK MS Brno D',
      importKey: 'cka:past',
    );
    final result = MatchResult.fromJson(const {
      'match_id': 'past',
      'status': 'finished',
      'home_points': 5,
      'away_points': 3,
      'fetched_at': '2026-09-06T21:00:00+00:00',
    });
    await tester.pumpWidget(app(slots: [pastMatch], results: {'past': result}));
    await tester.pumpAndSettle();

    expect(find.text('5 : 3'), findsOneWidget);
  });

  testWidgets(
    'a decided federation match\'s winning team NAME is weighted, matching '
    'Výsledky and the day dialog',
    (tester) async {
      final pastMatch = PrioritySlot(
        id: 'past',
        date: today.addDays(-3),
        startsAt: const HourMinute(18, 30),
        endsAt: const HourMinute(21, 30),
        type: PrioritySlot.fallbackMatchType,
        homeTeam: 'SKK Veverky Brno A',
        awayTeam: 'KK MS Brno D',
        importKey: 'cka:past',
      );
      final result = MatchResult.fromJson(const {
        'match_id': 'past',
        'status': 'finished',
        'home_points': 5,
        'away_points': 3,
        'fetched_at': '2026-09-06T21:00:00+00:00',
      });
      await tester.pumpWidget(
        app(slots: [pastMatch], results: {'past': result}),
      );
      await tester.pumpAndSettle();

      final titleText = tester.widget<Text>(
        find.text('SKK Veverky Brno A – KK MS Brno D'),
      );
      final spans = (titleText.textSpan! as TextSpan).children!
          .cast<TextSpan>();
      expect(spans[0].style?.fontWeight, FontWeight.w800, reason: 'home won');
      // Explicitly w400 (not just "not w800") — a plain ambient/null style
      // would also satisfy `isNot(w800)` without proving the loser was
      // actually lightened (Fix round 1).
      expect(spans[1].style?.fontWeight, FontWeight.w400, reason: 'separator');
      expect(spans[2].style?.fontWeight, FontWeight.w400, reason: 'away lost');
    },
  );

  testWidgets(
    'a federation match with a scheduled/null-points result row shows no '
    'trailing score (no bare dash before kickoff)',
    (tester) async {
      final upcoming = PrioritySlot(
        id: 'upcoming',
        date: today.addDays(2),
        startsAt: const HourMinute(18, 30),
        endsAt: const HourMinute(21, 30),
        type: PrioritySlot.fallbackMatchType,
        homeTeam: 'SKK Veverky Brno A',
        awayTeam: 'KK MS Brno D',
        importKey: 'cka:upcoming',
      );
      final result = MatchResult.fromJson(const {
        'match_id': 'upcoming',
        'status': 'scheduled',
        'fetched_at': '2026-09-08T21:00:00+00:00',
      });
      await tester.pumpWidget(
        app(slots: [upcoming], results: {'upcoming': result}),
      );
      await tester.pumpAndSettle();

      expect(find.text('SKK Veverky Brno A – KK MS Brno D'), findsOneWidget);
      expect(find.text('–'), findsNothing);
      final tile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'SKK Veverky Brno A – KK MS Brno D'),
      );
      expect(tile.trailing, isNull);

      // No winner yet (scheduled, no points on the board) — the title
      // stays a plain, unstyled Text, not forced to w400 either (Fix
      // round 1).
      final titleText = tester.widget<Text>(
        find.text('SKK Veverky Brno A – KK MS Brno D'),
      );
      expect(titleText.textSpan, isNull);
      expect(titleText.style, isNull);
    },
  );

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
      'shows the error text with a retry, never the empty state', (
    tester,
  ) async {
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
    await tester.pumpWidget(
      app(
        reservations: [res('r1', today.addDays(1))],
        cancel: (id) async => cancelled.add(id),
      ),
    );
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
    await tester.pumpWidget(
      app(
        reservations: [res('r1', today)],
        // b1 is 18:00–19:00; the calendar refuses cancel once startsAt has
        // passed (domain/schedule.dart's canCancel) — Můj přehled must
        // agree instead of offering a cancel the RPC would reject.
        nowOverride: DateTime(2026, 9, 9, 18, 30),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('18:00–19:00 · Dráha 2'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);

    await tester.tap(find.text('18:00–19:00 · Dráha 2'));
    await tester.pumpAndSettle();
    expect(find.text('Zrušit rezervaci?'), findsNothing);
  });

  testWidgets('empty: says so and the button opens the calendar', (
    tester,
  ) async {
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

  testWidgets('without followed teams the list ends with the hint', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(profile: nobody, reservations: [res('r1', today)], slots: [match]),
    );
    await tester.pumpAndSettle();

    expect(find.text('SKK Veverky Brno A – KK MS Brno D'), findsNothing);
    expect(find.textContaining('Moje týmy'), findsOneWidget);
  });

  // ---------------------------------------------------------------------
  // Match trophy colour (0036): the SAME registry the profile's team
  // pickers edit (myTeamColorsProvider).
  // ---------------------------------------------------------------------

  group('match trophy colour (0036)', () {
    // The pick is unchanged (matchColorOf); what changed is how it is shown —
    // a filled dot in the team's raw Google colour instead of an outlined
    // glyph tinted a legible shade, so a colour change is not missed.
    Color rawNamed(String name) =>
        googleEventColors.firstWhere((c) => c.$2 == name).$3;
    int? trophyColorId(WidgetTester t) =>
        t.widget<MatchTrophy>(find.byType(MatchTrophy)).colorId;
    Color? dotFill(WidgetTester t) {
      final c = t.widget<Container>(
        find.descendant(
          of: find.byType(MatchTrophy),
          matching: find.byType(Container),
        ),
      );
      return (c.decoration as BoxDecoration).color;
    }

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

    testWidgets('neither team coloured keeps today\'s plain outlined trophy', (
      tester,
    ) async {
      await tester.pumpWidget(app(slots: [match]));
      await tester.pumpAndSettle();

      expect(trophyColorId(tester), isNull);
      expect(find.byIcon(Icons.emoji_events_outlined), findsOneWidget);
    });

    testWidgets('the followed HOME team\'s colour fills the dot', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(slots: [match], teamColors: const {'SKK Veverky Brno A': 3}),
      );
      await tester.pumpAndSettle();

      expect(trophyColorId(tester), 3);
      expect(dotFill(tester), rawNamed('Švestková'));
      // The dot carries the filled trophy glyph, not the outlined one.
      expect(find.byIcon(Icons.emoji_events), findsOneWidget);
      expect(find.byIcon(Icons.emoji_events_outlined), findsNothing);
    });

    testWidgets('the followed AWAY team\'s colour fills the dot too', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(slots: [awayMatch], teamColors: const {'SKK Veverky Brno A': 6}),
      );
      await tester.pumpAndSettle();

      expect(trophyColorId(tester), 6);
      expect(dotFill(tester), rawNamed('Mandarinková'));
    });

    testWidgets('a derby — both teams coloured — fills with the HOME '
        'team\'s colour, same tie-break as the Google event', (tester) async {
      const bothFollower = Profile(
        id: 'me',
        displayName: 'Já Hráč',
        email: 'me@example.com',
        role: Role.player,
        status: ProfileStatus.approved,
        followedTeams: ['SKK Veverky Brno A', 'KK MS Brno D'],
      );
      await tester.pumpWidget(
        app(
          profile: bothFollower,
          slots: [match], // home 'SKK Veverky Brno A', away 'KK MS Brno D'
          teamColors: const {'SKK Veverky Brno A': 4, 'KK MS Brno D': 9},
        ),
      );
      await tester.pumpAndSettle();

      expect(trophyColorId(tester), 4);
      expect(dotFill(tester), rawNamed('Lososová'));
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
      await tester.pumpWidget(
        app(
          profile: devitkaFollower,
          slots: [derby],
          // Veverky was once coloured, but the player follows only Devítka.
          teamColors: const {'SKK Veverky Brno A': 11},
        ),
      );
      await tester.pumpAndSettle();

      // The match is listed at all (Devítka is followed) …
      expect(
        find.text('SKK Veverky Brno A – KS Devítka Brno B'),
        findsOneWidget,
      );
      // … but its trophy stays plain, not Veverky's red.
      expect(trophyColorId(tester), isNull);
      expect(find.byIcon(Icons.emoji_events_outlined), findsOneWidget);
    });
  });

  group('training colour', () {
    Color colorNamed(String name) => legibleShadeOf(
      googleEventColors.firstWhere((c) => c.$2 == name).$3,
      Brightness.light,
    );
    Color rawNamed(String name) =>
        googleEventColors.firstWhere((c) => c.$2 == name).$3;
    Color? dotFill(WidgetTester t) {
      final c = t.widget<Container>(
        find.descendant(
          of: find.byType(MatchTrophy),
          matching: find.byType(Container),
        ),
      );
      return (c.decoration as BoxDecoration).color;
    }

    testWidgets('without a training colour the T stays plain', (tester) async {
      await tester.pumpWidget(app(reservations: [res('r1', today)]));
      await tester.pumpAndSettle();

      expect(tester.widget<Icon>(find.byIcon(Icons.title)).color, isNull);
    });

    testWidgets('the training colour tints the T, in the same derived shade '
        'the trophy uses', (tester) async {
      await tester.pumpWidget(
        app(reservations: [res('r1', today)], trainingColorId: 5),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<Icon>(find.byIcon(Icons.title)).color,
        colorNamed('Banánová'),
      );
    });

    testWidgets('a training and a match each take their own colour', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          reservations: [res('r1', today)],
          slots: [match],
          teamColors: const {'SKK Veverky Brno A': 3},
          trainingColorId: 5,
        ),
      );
      await tester.pumpAndSettle();

      // The training T keeps its tinted-letter look (the player's own
      // colour); the match now shows as a filled dot in the team's colour.
      expect(
        tester.widget<Icon>(find.byIcon(Icons.title)).color,
        colorNamed('Banánová'),
      );
      expect(dotFill(tester), rawNamed('Švestková'));
    });
  });

  // A match played for somebody else's team (0039) is on the list like any
  // other — nothing marks it out, it simply is the player's.
  group('an exception', () {
    final guest = PrioritySlot(
      id: 'guest',
      date: today.addDays(2),
      startsAt: const HourMinute(10, 0),
      endsAt: const HourMinute(13, 0),
      type: PrioritySlot.fallbackMatchType,
      homeTeam: 'KK Vyškov A',
      awayTeam: 'KK Vyškov B',
    );

    // One ProviderScope per test: a second pumpWidget does not swap them.
    testWidgets('without one, a match of nobody\'s team is not on the list', (
      tester,
    ) async {
      await tester.pumpWidget(app(slots: [guest]));
      await tester.pumpAndSettle();
      expect(find.text('KK Vyškov A – KK Vyškov B'), findsNothing);
    });

    testWidgets('puts a match of nobody\'s team on the list', (tester) async {
      await tester.pumpWidget(
        app(slots: [guest], exceptions: const {'guest': true}),
      );
      await tester.pumpAndSettle();
      expect(find.text('KK Vyškov A – KK Vyškov B'), findsOneWidget);
      // No badge, no note: it reads exactly like a followed team's match.
      expect(find.text('10:00–13:00 · doma'), findsOneWidget);
    });

    testWidgets('wears our team\'s colour on the trophy', (tester) async {
      await tester.pumpWidget(
        app(
          slots: [guest],
          exceptions: const {'guest': true},
          teamColors: const {'KK Vyškov A': 11},
        ),
      );
      await tester.pumpAndSettle();

      final dot = tester.widget<Container>(
        find.descendant(
          of: find.byType(MatchTrophy),
          matching: find.byType(Container),
        ),
      );
      expect(
        (dot.decoration as BoxDecoration).color,
        googleEventColors.firstWhere((c) => c.$1 == 11).$3,
      );
    });

    testWidgets('a team with no colour leaves the trophy plain', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(slots: [guest], exceptions: const {'guest': true}),
      );
      await tester.pumpAndSettle();

      final icon = tester.widget<Icon>(
        find.byIcon(Icons.emoji_events_outlined),
      );
      expect(icon.color, isNull);
    });
  });

  group('tap-through to the match detail', () {
    final playedMatch = PrioritySlot(
      id: 'played',
      date: today.addDays(-2),
      startsAt: const HourMinute(18, 0),
      endsAt: const HourMinute(20, 0),
      type: PrioritySlot.fallbackMatchType,
      homeTeam: 'SKK Veverky Brno A',
      awayTeam: 'KK MS Brno D',
      importKey: 'cka:1',
    );
    final finishedResult = MatchResult(
      matchId: 'played',
      status: MatchStatus.finished,
      homePoints: 5,
      awayPoints: 3,
      fetchedAt: DateTime.utc(2026, 1, 1),
    );

    testWidgets('a played match opens its detail screen', (tester) async {
      await tester.pumpWidget(
        app(slots: [playedMatch], results: {'played': finishedResult}),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('SKK Veverky Brno A – KK MS Brno D'));
      await tester.pumpAndSettle();

      expect(find.byType(MatchDetailScreen), findsOneWidget);
    });

    testWidgets(
      'a non-federation upcoming match (no result yet) stays unclickable',
      (tester) async {
        // `match` (top-level fixture): two days out, no `importKey` at all
        // — `fromFederation` alone already blocks the tap here, so this
        // case doesn't by itself prove the `hasScoreData` gate does
        // anything (see the federation case below for that).
        await tester.pumpWidget(app(slots: [match]));
        await tester.pumpAndSettle();

        await tester.tap(find.text('SKK Veverky Brno A – KK MS Brno D'));
        await tester.pumpAndSettle();

        expect(find.byType(MatchDetailScreen), findsNothing);
      },
    );

    testWidgets('a federation upcoming match with no score data yet stays '
        'unclickable too (isolates the hasScoreData gate)', (tester) async {
      final upcomingFederation = PrioritySlot(
        id: 'upcoming-fed',
        date: today.addDays(2),
        startsAt: const HourMinute(18, 30),
        endsAt: const HourMinute(21, 30),
        type: PrioritySlot.fallbackMatchType,
        homeTeam: 'SKK Veverky Brno A',
        awayTeam: 'KK MS Brno D',
        importKey: 'cka:upcoming-fed',
      );
      // No entry in `results` at all — `hasScoreData(null)` is false,
      // same as a `scheduled` row would be.
      await tester.pumpWidget(app(slots: [upcomingFederation]));
      await tester.pumpAndSettle();

      await tester.tap(find.text('SKK Veverky Brno A – KK MS Brno D'));
      await tester.pumpAndSettle();

      expect(find.byType(MatchDetailScreen), findsNothing);
    });
  });
}
