import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/duels.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/widgets/duel_card.dart';
import 'package:rezervator/features/clubhouse/widgets/duels_compact.dart';

void main() {
  final slot = PrioritySlot(
    id: 'm',
    date: Day(2026, 10, 8),
    startsAt: HourMinute(14, 0),
    endsAt: HourMinute(17, 0),
    type: PrioritySlot.fallbackMatchType,
    homeTeam: 'Domácí',
    awayTeam: 'Hosté',
    importKey: 'cka:m',
  );

  /// A player's line: [lanes] lanes on the sheet, the first [thrown] of
  /// them with a total.
  MatchPlayerResult player(
    String side,
    int pos, {
    int? total,
    int lanes = 0,
    int? thrown,
  }) => MatchPlayerResult(
    id: '$side-$pos',
    matchId: 'm',
    side: side,
    position: pos,
    playerName: '${side == 'home' ? 'Dom' : 'Hos'} Hráč$pos',
    total: total,
    lanes: [
      for (var l = 1; l <= lanes; l++)
        PlayerLane(
          lane: l,
          total: l <= (thrown ?? lanes) ? (side == 'home' ? 100 + l : 98 + l) : null,
        ),
    ],
  );

  // Duel 1 done (home wins), duel 2 being played (two of four lanes in),
  // duel 3 not started.
  final duels = duelsOf([
    player('home', 1, total: 420, lanes: 4),
    player('away', 1, total: 400, lanes: 4),
    player('home', 2, lanes: 4, thrown: 2),
    player('away', 2, lanes: 4, thrown: 2),
    player('home', 3),
    player('away', 3),
  ]);

  MatchResult result(int home, int away, {int? pinsHome, int? pinsAway}) =>
      MatchResult.fromJson({
        'match_id': 'm',
        'status': 'in_progress',
        'home_points': home,
        'away_points': away,
        'home_total': ?pinsHome,
        'away_total': ?pinsAway,
        'fetched_at': '2026-10-08T13:00:00+00:00',
      });

  Widget host(Widget child, {double height = 800}) => MaterialApp(
    home: Scaffold(body: SizedBox(height: height, child: child)),
  );

  group('MatchScoreLine', () {
    testWidgets('the teams around the points, the live pins with their lead',
        (tester) async {
      await tester.pumpWidget(
        host(MatchScoreLine(slot: slot, result: result(2, 0), duels: duels)),
      );
      expect(find.text('Domácí'), findsOneWidget);
      expect(find.text('Hosté'), findsOneWidget);
      expect(find.text('2 : 0'), findsOneWidget);
      // Live: the done duel's totals plus the lanes bowled so far —
      // 420 + (101+102) : 400 + (99+100).
      expect(find.textContaining('623'), findsOneWidget);
      expect(find.textContaining('599'), findsOneWidget);
      expect(find.textContaining('+24'), findsOneWidget);
    });

    testWidgets('no lanes yet: the site\'s totals, and none without them',
        (tester) async {
      final waiting = duelsOf([player('home', 1), player('away', 1)]);
      await tester.pumpWidget(
        host(
          MatchScoreLine(
            slot: slot,
            result: result(0, 0, pinsHome: 1500, pinsAway: 1500),
            duels: waiting,
          ),
        ),
      );
      expect(find.text('0 : 0'), findsOneWidget);
      expect(find.textContaining('1500'), findsOneWidget);

      await tester.pumpWidget(
        host(MatchScoreLine(slot: slot, result: null, duels: waiting)),
      );
      expect(find.text('0 : 0'), findsOneWidget);
      expect(find.textContaining('1500'), findsNothing);
    });
  });

  group('DuelsCompact', () {
    testWidgets('a block per duel: names, totals, lead; „čeká“ for one not '
        'started; a tap opens a played one as the full card, a tap on the '
        'card folds it', (tester) async {
      await tester.pumpWidget(
        host(DuelsCompact(duels: duels, result: result(2, 0))),
      );
      // The folded cards are in the tree (the cross-fade), hidden: only
      // what can be hit counts.
      Finder shown(String text) => find.text(text).hitTestable();
      expect(shown('Dom Hráč1'), findsOneWidget);
      expect(shown('Hos Hráč3'), findsOneWidget);
      expect(shown('420'), findsOneWidget);
      expect(shown('+20'), findsOneWidget);
      expect(shown('čeká'), findsOneWidget);
      expect(find.byType(DuelCard).hitTestable(), findsNothing);
      expect(find.byType(RefreshIndicator), findsNothing);

      // The waiting duel has nothing to open.
      await tester.tap(shown('Dom Hráč3'));
      await tester.pumpAndSettle();
      expect(find.byType(DuelCard).hitTestable(), findsNothing);

      await tester.tap(shown('Dom Hráč1'));
      await tester.pumpAndSettle();
      final card = find.byType(DuelCard).hitTestable();
      expect(card, findsOneWidget);
      expect(tester.widget<DuelCard>(card).duel.position, 1);
      expect(find.text('Plné'), findsWidgets);

      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.byType(DuelCard).hitTestable(), findsNothing);
    });

    testWidgets('a header is pinned above the duels; with a refresh the list '
        'pulls', (tester) async {
      var pulled = 0;
      await tester.pumpWidget(
        host(
          DuelsCompact(
            duels: duels,
            result: result(2, 0),
            header: const Text('HLAVIČKA'),
            onRefresh: () async => pulled++,
          ),
        ),
      );
      expect(find.text('HLAVIČKA'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('HLAVIČKA')).dy,
        lessThan(tester.getTopLeft(find.text('Dom Hráč1').hitTestable()).dy),
      );
      await tester.fling(
        find.text('Dom Hráč2').hitTestable(),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();
      expect(pulled, 1);
      // The header stayed where it was: not part of the list.
      expect(tester.getTopLeft(find.text('HLAVIČKA')).dy, lessThan(20));
    });
  });

  testWidgets('one open card taller than the list: it stays open and the '
      'list scrolls, so no row is out of reach', (tester) async {
    await tester.pumpWidget(
      host(DuelsCompact(duels: duels, result: result(2, 0)), height: 260),
    );
    await tester.tap(find.text('Dom Hráč1').hitTestable());
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 320));
      await tester.pumpAndSettle();
    }
    expect(find.byType(DuelCard).hitTestable(), findsOneWidget);
    final scroll = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    expect(scroll.maxScrollExtent, greaterThan(0));
    await tester.drag(find.byType(DuelCard).hitTestable(), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('Hos Hráč3').hitTestable(), findsOneWidget);
  });

  for (final table in [false, true]) {
    testWidgets('${table ? 'table' : 'compact'} with singleOpen: opening '
        'another duel folds the first in the same moment', (tester) async {
      final view = table
          ? DuelsTable(duels: duels, result: result(2, 0), singleOpen: true)
          : DuelsCompact(duels: duels, result: result(2, 0), singleOpen: true);
      await tester.pumpWidget(host(view));
      String name(int pos) => table ? 'Hráč$pos' : 'Dom Hráč$pos';
      await tester.tap(find.text(name(1)).hitTestable().first);
      await tester.pumpAndSettle();
      expect(find.byType(DuelCard).hitTestable(), findsOneWidget);

      await tester.tap(find.text(name(2)).hitTestable().first);
      // One frame: no waiting for the first to settle — it is already
      // folding while the second opens.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final states = [
        for (final f in tester.widgetList<AnimatedCrossFade>(
          find.byType(AnimatedCrossFade),
        ))
          f.crossFadeState,
      ];
      expect(
        states.where((s) => s == CrossFadeState.showSecond),
        hasLength(1),
        reason: 'one duel open, the other already folding',
      );
      await tester.pumpAndSettle();
      final card = find.byType(DuelCard).hitTestable();
      expect(card, findsOneWidget);
      expect(tester.widget<DuelCard>(card).duel.position, 2);

      // A tap on the open card folds it, leaving none.
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.byType(DuelCard).hitTestable(), findsNothing);
    });
  }

  group('DuelsTable', () {
    testWidgets('a row per duel with surnames, a dot on the one being played, '
        'and alternate rows shaded', (tester) async {
      await tester.pumpWidget(
        host(DuelsTable(duels: duels, result: result(2, 0))),
      );
      expect(find.text('Hráč1').hitTestable(), findsNWidgets(2));
      expect(find.text('Dom Hráč1').hitTestable(), findsNothing);
      expect(find.byIcon(Icons.circle).hitTestable(), findsOneWidget);
      // The waiting duel: dashes for its totals and lead.
      expect(find.text('–').hitTestable(), findsNWidgets(3));
      final rows = tester
          .widgetList<Material>(
            find.ancestor(of: find.byType(InkWell), matching: find.byType(Material)),
          )
          .where((m) => m.child is InkWell)
          .toList();
      expect(rows, hasLength(3));
      expect(rows[0].color, Colors.transparent);
      expect(rows[1].color, isNot(Colors.transparent));
      expect(rows[2].color, Colors.transparent);

      await tester.tap(find.text('Hráč2').hitTestable().first);
      await tester.pumpAndSettle();
      final card = find.byType(DuelCard).hitTestable();
      expect(card, findsOneWidget);
      expect(tester.widget<DuelCard>(card).duel.position, 2);
    });
  });
}
