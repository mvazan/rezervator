import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/widgets/team_totals_card.dart';

import '../../../support/rudna_vrsovice.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: child,
      ),
    ),
  ),
);

/// A finished `match_results` row with only the given team values.
MatchResult _result({
  int? homeTotal,
  int? awayTotal,
  int? homeFulls,
  int? awayFulls,
  int? homeSpares,
  int? awaySpares,
  int? homeErrors,
  int? awayErrors,
  num? homeSetPoints,
  num? awaySetPoints,
}) => MatchResult.fromJson({
  'match_id': 'x',
  'status': 'finished',
  'home_total': homeTotal,
  'away_total': awayTotal,
  'home_fulls': homeFulls,
  'away_fulls': awayFulls,
  'home_spares': homeSpares,
  'away_spares': awaySpares,
  'home_errors': homeErrors,
  'away_errors': awayErrors,
  'home_set_points': homeSetPoints,
  'away_set_points': awaySetPoints,
  'fetched_at': '2026-09-17T08:00:00+00:00',
});

Text _text(WidgetTester tester, String data) =>
    tester.widget<Text>(find.text(data));

FontWeight? _weight(WidgetTester tester, String data) =>
    _text(tester, data).style?.fontWeight;

void main() {
  group('the finished Rudná A 7 : 1 Vršovice A', () {
    Future<void> pump(WidgetTester tester) =>
        tester.pumpWidget(_host(TeamTotalsCard(result: rudnaResult)));

    testWidgets('the title, every row, its values and its lead', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('Družstva'), findsOneWidget);
      for (final text in [
        '2555',
        '2321',
        'Kuželky ← 234',
        '1809',
        '1653',
        'Plné ← 156',
        '746',
        '668',
        'Dorážka ← 78',
        '44',
        '74',
        'Chyby (méně = lépe)',
        '8,5',
        'SB',
        '3,5',
      ]) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
    });

    testWidgets("the leader's value is w800, the other w500", (tester) async {
      await pump(tester);
      for (final (leader, other) in [
        ('2555', '2321'),
        ('1809', '1653'),
        ('746', '668'),
        ('8,5', '3,5'),
      ]) {
        expect(_weight(tester, leader), FontWeight.w800, reason: leader);
        expect(_weight(tester, other), FontWeight.w500, reason: other);
      }
    });

    testWidgets('fewer errors lead, and the errors row prints no arrow', (
      tester,
    ) async {
      await pump(tester);
      expect(_weight(tester, '44'), FontWeight.w800);
      expect(_weight(tester, '74'), FontWeight.w500);
      expect(find.textContaining('30'), findsNothing);
    });

    testWidgets('home on the left, away on the right, the label between', (
      tester,
    ) async {
      await pump(tester);
      for (final (home, label, away) in [
        ('2555', 'Kuželky ← 234', '2321'),
        ('44', 'Chyby (méně = lépe)', '74'),
        ('8,5', 'SB', '3,5'),
      ]) {
        final h = tester.getRect(find.text(home));
        final l = tester.getRect(find.text(label));
        final a = tester.getRect(find.text(away));
        expect(h.right, lessThan(l.left), reason: label);
        expect(l.right, lessThan(a.left), reason: label);
        // Mirrored: the label sits in the middle of the row.
        final card = tester.getRect(find.byType(TeamTotalsCard));
        expect(l.center.dx, closeTo(card.center.dx, 1), reason: label);
      }
    });

    testWidgets('five rows, each at least 44dp tall', (tester) async {
      await pump(tester);
      for (final row in ['kuzelky', 'plne', 'dorazka', 'chyby', 'sb']) {
        final size = tester.getSize(find.byKey(Key('team-totals-$row')));
        expect(size.height, greaterThanOrEqualTo(44), reason: row);
      }
      expect(
        tester.getSize(find.byKey(const Key('team-totals-kuzelky'))).height,
        44,
      );
    });

    testWidgets('the label is 13dp in onSurfaceVariant, values 18dp', (
      tester,
    ) async {
      await pump(tester);
      final scheme = Theme.of(tester.element(find.text('SB'))).colorScheme;
      for (final label in ['Kuželky ← 234', 'Chyby (méně = lépe)', 'SB']) {
        final style = _text(tester, label).style;
        expect(style?.fontSize, 13, reason: label);
        expect(style?.color, scheme.onSurfaceVariant, reason: label);
      }
      for (final value in ['2555', '2321', '44', '74']) {
        final style = _text(tester, value).style;
        expect(style?.fontSize, 18, reason: value);
        expect(style?.color, scheme.onSurface, reason: value);
      }
    });

    testWidgets('numbers use tabular figures', (tester) async {
      await pump(tester);
      for (final number in [
        '2555',
        '2321',
        '44',
        '74',
        '8,5',
        '3,5',
        'Kuželky ← 234',
      ]) {
        expect(
          _text(tester, number).style?.fontFeatures,
          contains(const FontFeature.tabularFigures()),
          reason: number,
        );
      }
    });

    testWidgets('one semantics label per row, without the arrow', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      expect(
        tester.getSemantics(find.byKey(const Key('team-totals-kuzelky'))),
        containsSemantics(label: 'Kuželky 2555 : 2321'),
      );
      expect(
        tester.getSemantics(find.byKey(const Key('team-totals-chyby'))),
        containsSemantics(label: 'Chyby (méně = lépe) 44 : 74'),
      );
      expect(
        tester.getSemantics(find.byKey(const Key('team-totals-sb'))),
        containsSemantics(label: 'SB 8,5 : 3,5'),
      );
      expect(find.bySemanticsLabel('Kuželky 2555 : 2321'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('←')), findsNothing);
      handle.dispose();
    });
  });

  testWidgets('an away lead points right; a tie is „=“ with no leader', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        TeamTotalsCard(
          result: _result(
            homeTotal: 2300,
            awayTotal: 2400,
            homeFulls: 1600,
            awayFulls: 1600,
            homeSpares: 700,
            awaySpares: 800,
            homeErrors: 20,
            awayErrors: 12,
            homeSetPoints: 6,
            awaySetPoints: 6,
          ),
        ),
      ),
    );
    expect(find.text('Kuželky 100 →'), findsOneWidget);
    expect(_weight(tester, '2400'), FontWeight.w800);
    expect(_weight(tester, '2300'), FontWeight.w500);
    // Equal fulls and equal set points: nobody leads, both w500.
    expect(find.text('Plné ='), findsOneWidget);
    expect(find.text('1600'), findsNWidgets(2));
    for (final element in find.text('1600').evaluate()) {
      expect((element.widget as Text).style?.fontWeight, FontWeight.w500);
    }
    for (final element in find.text('6').evaluate()) {
      expect((element.widget as Text).style?.fontWeight, FontWeight.w500);
    }
    // Fewer errors away: the away value leads.
    expect(_weight(tester, '12'), FontWeight.w800);
    expect(_weight(tester, '20'), FontWeight.w500);
  });

  testWidgets('a row both sides lack is left out; one missing side is „–“', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        TeamTotalsCard(
          result: _result(
            homeTotal: 2555,
            awayTotal: 2321,
            homeFulls: 1809,
            homeSetPoints: 8.5,
            awaySetPoints: 3.5,
          ),
        ),
      ),
    );
    // No spares and no errors on either side: no rows for them.
    expect(find.textContaining('Dorážka'), findsNothing);
    expect(find.textContaining('Chyby'), findsNothing);
    expect(find.byKey(const Key('team-totals-dorazka')), findsNothing);
    // Away fulls unknown: „–“, no lead and no leader.
    expect(find.text('Plné'), findsOneWidget);
    expect(find.text('–'), findsOneWidget);
    expect(_weight(tester, '1809'), FontWeight.w500);
  });

  testWidgets('a result with a null total renders nothing', (tester) async {
    await tester.pumpWidget(
      _host(TeamTotalsCard(result: _result(homeTotal: 2555))),
    );
    expect(find.text('Družstva'), findsNothing);
    expect(find.byType(Card), findsNothing);

    await tester.pumpWidget(
      _host(TeamTotalsCard(result: _result(awayTotal: 2321))),
    );
    expect(find.text('Družstva'), findsNothing);
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('no overflow on a 360dp phone at text scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(360, 800),
              textScaler: TextScaler.linear(scale),
            ),
            child: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: TeamTotalsCard(result: rudnaResult),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byType(TeamTotalsCard)).right,
        lessThanOrEqualTo(360),
      );
      expect(find.text('Chyby (méně = lépe)'), findsOneWidget);
    });
  }
}
