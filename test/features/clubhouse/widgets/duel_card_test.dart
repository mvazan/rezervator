import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/duels.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/palette.dart';
import 'package:rezervator/features/clubhouse/widgets/duel_card.dart';

import '../../../support/rudna_vrsovice.dart';

/// One `match_player_results` row with only what the card reads.
MatchPlayerResult _player(
  String side,
  int pos,
  List<Map<String, Object?>> lanes, {
  int? total,
  num? sb,
  num? tb,
}) => MatchPlayerResult.fromJson({
  'id': '$side$pos',
  'match_id': 'x',
  'side': side,
  'position': pos,
  'player_name': '$side $pos',
  'total': total,
  'set_points': sb,
  'team_points': tb,
  'lanes': lanes,
});

/// One lane of the `lanes` jsonb; a null [total] is a lane not thrown yet.
Map<String, Object?> _lane(int n, int? total, [num? sp]) => {
  'lane': n,
  'fulls': null,
  'spares': null,
  'errors': null,
  'total': total,
  'setPoints': sp,
};

/// The six duels of the finished Rudná A 7 : 1 Vršovice A.
final _rudna = duelsOf(rudnaPlayers);

/// Their shared bar scale: duel 5's +99.
final _scale = diffScale(_rudna);

/// Live: both threw lane 1 (213 : 216), only home threw lane 2 (150).
final _playing = duelsOf([
  _player('home', 1, [_lane(1, 213), _lane(2, 150)], total: 363),
  _player('away', 1, [_lane(1, 216), _lane(2, null)], total: 216),
]).single;

/// Live: neither player has thrown a lane yet.
final _waiting = duelsOf([
  _player('home', 1, [_lane(1, null), _lane(2, null)]),
  _player('away', 1, [_lane(1, null), _lane(2, null)]),
]).single;

/// T120, done: 4 × 150 against 4 × 140.
final _t120 = duelsOf([
  _player(
    'home',
    1,
    [for (var i = 1; i <= 4; i++) _lane(i, 150, 1)],
    total: 600,
    sb: 4,
    tb: 1,
  ),
  _player(
    'away',
    1,
    [for (var i = 1; i <= 4; i++) _lane(i, 140, 0)],
    total: 560,
    sb: 0,
    tb: 0,
  ),
]).single;

/// Done, a split point: 200 : 200, half a set point and half a point each.
final _split = duelsOf([
  _player('home', 1, [_lane(1, 200, 0.5)], total: 200, sb: 0.5, tb: 0.5),
  _player('away', 1, [_lane(1, 200, 0.5)], total: 200, sb: 0.5, tb: 0.5),
]).single;

Widget _card(
  Duel duel, {
  bool expanded = false,
  VoidCallback? onTap,
  int? scale,
  bool showSetPoints = false,
}) => DuelCard(
  duel: duel,
  scale: scale ?? _scale,
  expanded: expanded,
  onTap: onTap ?? () {},
  homeColor: Colors.teal,
  awayColor: Colors.purple,
  showSetPoints: showSetPoints,
);

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

Text _text(WidgetTester tester, String data) =>
    tester.widget<Text>(find.text(data));

Rect _rect(WidgetTester tester, String key) =>
    tester.getRect(find.byKey(Key(key)));

/// The style of the span that prints [number] inside the lane text [lane].
/// The [number] Text inside lane [lane]'s row of duel [position].
Text _inLane(WidgetTester tester, int position, int lane, String number) =>
    tester.widget<Text>(
      find.descendant(
        of: find.byKey(Key('duel-$position-lane-$lane-score')),
        matching: find.text(number),
      ),
    );

/// The three texts of one lane row: home, the separator, away.
List<String> _laneRow(WidgetTester tester, int position, int lane) => [
  for (final t in tester.widgetList<Text>(
    find.descendant(
      of: find.byKey(Key('duel-$position-lane-$lane-score')),
      matching: find.byType(Text),
    ),
  ))
    t.data!,
];

void main() {
  group('duel 1, collapsed: Mičanová 407 : 385 Pelánek, pins decided', () {
    Future<void> pump(WidgetTester tester) =>
        tester.pumpWidget(_host(_card(_rudna[0])));

    testWidgets("the winner's total is w800, the loser's w500", (tester) async {
      await pump(tester);
      expect(_text(tester, '407').style?.fontWeight, FontWeight.w800);
      expect(_text(tester, '385').style?.fontWeight, FontWeight.w500);
    });

    testWidgets('the lead and the lanes; no pill, no position', (tester) async {
      await pump(tester);
      expect(find.text('bod'), findsNothing);
      expect(find.text('½'), findsNothing);
      expect(find.text('+22'), findsOneWidget);
      // Lanes are „1.“ and „2.“, not „Dr. 1“.
      expect(find.text('1.'), findsOneWidget);
      expect(find.text('2.'), findsOneWidget);
      expect(find.textContaining('Dr.'), findsNothing);
      // The position circle is gone: the only lone „1“ would be it.
      expect(find.text('1'), findsNothing);
      // Each lane is one row „213 : 216“ (home right-aligned, away left).
      expect(_laneRow(tester, 1, 1), ['213', ' : ', '216']);
      expect(_laneRow(tester, 1, 2), ['194', ' : ', '169']);
    });

    testWidgets('the lead sits between the totals, bigger than before', (
      tester,
    ) async {
      await pump(tester);
      final lead = tester.getCenter(find.text('+22'));
      expect(lead.dx, greaterThan(tester.getCenter(find.text('407')).dx));
      expect(lead.dx, lessThan(tester.getCenter(find.text('385')).dx));
      expect(_text(tester, '+22').style?.fontSize, 20);
    });

    testWidgets('a closed chevron, no set points, no table', (tester) async {
      await pump(tester);
      // 100 throws: set points do not play a role, they are not shown.
      expect(find.textContaining('SB'), findsNothing);
      expect(find.textContaining('rozhodly'), findsNothing);
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
      expect(find.byIcon(Icons.expand_less), findsNothing);
      // The Plné of lane 1 is only in the expanded table.
      expect(find.text('156'), findsNothing);
      expect(find.text('Plné'), findsNothing);
    });

    testWidgets('each lane winner is w800, with a dot on its outer side', (
      tester,
    ) async {
      await pump(tester);
      // Lane 1 went away (216), lane 2 home (194).
      expect(_inLane(tester, 1, 1, '216').style?.fontWeight, FontWeight.w800);
      expect(_inLane(tester, 1, 1, '213').style?.fontWeight, FontWeight.w500);
      expect(_inLane(tester, 1, 2, '194').style?.fontWeight, FontWeight.w800);
      expect(_inLane(tester, 1, 2, '169').style?.fontWeight, FontWeight.w500);
      final dot1 = _rect(tester, 'duel-1-lane-1-dot');
      final dot2 = _rect(tester, 'duel-1-lane-2-dot');
      expect(dot1.left, greaterThan(_rect(tester, 'duel-1-lane-1-score').right));
      expect(dot2.right, lessThan(_rect(tester, 'duel-1-lane-2-score').left));
      expect(dot1.size, const Size(6, 6));
    });

    testWidgets('the bar grows from the centre towards home, on the shared '
        'scale', (tester) async {
      await pump(tester);
      final track = _rect(tester, 'duel-1-bar');
      final fill = _rect(tester, 'duel-1-bar-fill');
      expect(track.height, 6);
      expect(fill.right, closeTo(track.center.dx, 0.01));
      expect(fill.width, closeTo(22 / 99 * track.width / 2, 0.01));
    });

    testWidgets('a 4dp stripe on the home edge', (tester) async {
      await pump(tester);
      final card = tester.getRect(find.byType(DuelCard));
      final stripe = _rect(tester, 'duel-1-stripe');
      expect(stripe.width, 4);
      expect(stripe.left, closeTo(card.left, 0.01));
    });

    testWidgets('numbers use tabular figures', (tester) async {
      await pump(tester);
      for (final number in ['407', '385', '+22']) {
        expect(
          _text(tester, number).style?.fontFeatures,
          contains(const FontFeature.tabularFigures()),
          reason: number,
        );
      }
    });
  });

  group('duel 1, expanded', () {
    Future<void> pump(WidgetTester tester) =>
        tester.pumpWidget(_host(_card(_rudna[0], expanded: true)));

    testWidgets('the lane table and the Celkem row', (tester) async {
      await pump(tester);
      // Lane 1 home: 156 plné, 57 dorážka; the whole match: 297 plné.
      expect(find.text('156'), findsOneWidget);
      expect(find.text('57'), findsOneWidget);
      expect(find.text('297'), findsOneWidget);
      // Away's Celkem row: 263 plné, 122 dorážka, 14 chyb.
      expect(find.text('263'), findsOneWidget);
      expect(find.text('122'), findsOneWidget);
      expect(find.text('14'), findsOneWidget);
      expect(find.text('Plné'), findsNWidgets(2));
      expect(find.text('Dor.'), findsNWidgets(2));
      expect(find.text('Ch.'), findsNWidgets(2));
      expect(find.byIcon(Icons.expand_less), findsNothing);
      expect(find.byIcon(Icons.expand_more), findsNothing);
    });

    testWidgets('expanded: no lane summary, +/- per lane, no verdict', (
      tester,
    ) async {
      await pump(tester);
      // The collapsed lane summary is hidden once the table is open.
      expect(find.text('213 : 216'), findsNothing);
      expect(find.text('194 : 169'), findsNothing);
      expect(find.text('1.'), findsNothing);
      // Lane 1 went away by 3, lane 2 home by 25: in the middle column.
      expect(find.text('-3'), findsOneWidget);
      expect(find.text('+25'), findsOneWidget);
      // Nothing of the old sentence.
      expect(find.textContaining('rozhodly'), findsNothing);
      expect(find.textContaining('→'), findsNothing);
      // No chevron row either: a tap on the card closes it again.
      expect(find.byIcon(Icons.expand_less), findsNothing);
      expect(find.byIcon(Icons.expand_more), findsNothing);
    });

    testWidgets('the table is mirrored: home Plné far left, away Plné far '
        'right', (tester) async {
      await pump(tester);
      final homeFulls = tester.getCenter(find.text('297'));
      final awayFulls = tester.getCenter(find.text('263'));
      final homeTotal = tester.getCenter(find.text('407').last);
      final awayTotal = tester.getCenter(find.text('385').last);
      expect(homeFulls.dx, lessThan(homeTotal.dx));
      expect(homeTotal.dx, lessThan(awayTotal.dx));
      expect(awayTotal.dx, lessThan(awayFulls.dx));
    });
  });

  group('duel 6: Spěváček 431 : 434 Vilímovský, away took it', () {
    testWidgets('the lead points right, the away total is w800, a tied lane', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_card(_rudna[5])));
      expect(find.text('-3'), findsOneWidget);
      expect(_text(tester, '434').style?.fontWeight, FontWeight.w800);
      expect(_text(tester, '431').style?.fontWeight, FontWeight.w500);
      expect(_laneRow(tester, 6, 1), ['215', ' = ', '215']);
      // A tie has no dot and no winner weight.
      expect(find.byKey(const Key('duel-6-lane-1-dot')), findsNothing);
      for (final t in tester.widgetList<Text>(find.descendant(
        of: find.byKey(const Key('duel-6-lane-1-score')),
        matching: find.text('215'),
      ))) {
        expect(t.style?.fontWeight, FontWeight.w500);
      }
      expect(find.textContaining('SB'), findsNothing);
    });

    testWidgets('the bar and the stripe sit on the away side', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_card(_rudna[5])));

      final track = _rect(tester, 'duel-6-bar');
      final fill = _rect(tester, 'duel-6-bar-fill');
      expect(fill.left, closeTo(track.center.dx, 0.01));
      expect(fill.width, closeTo(3 / 99 * track.width / 2, 0.01));

      final card = tester.getRect(find.byType(DuelCard));
      expect(_rect(tester, 'duel-6-stripe').right, closeTo(card.right, 0.01));
    });

    testWidgets('expanded: the lane leads are signed, a tie is „=“', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_card(_rudna[5], expanded: true)));
      expect(find.text('='), findsOneWidget);
      expect(find.text('-3'), findsNWidgets(2), reason: 'the lead and lane 2');
      expect(find.textContaining('bod '), findsNothing);
    });

    testWidgets('duel 5 (+99) fills its half of the bar', (tester) async {
      await tester.pumpWidget(_host(_card(_rudna[4])));
      final track = _rect(tester, 'duel-5-bar');
      final fill = _rect(tester, 'duel-5-bar-fill');
      expect(fill.left, closeTo(track.left, 0.01));
      expect(fill.right, closeTo(track.center.dx, 0.01));
    });
  });

  group('side-colour marks: a legible shade of the side colour', () {
    for (final brightness in Brightness.values) {
      Future<void> pump(WidgetTester tester, Duel duel) => tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(body: SingleChildScrollView(child: _card(duel))),
        ),
      );
      Color? fillIn(WidgetTester tester, String key) {
        final box = tester.widget<DecoratedBox>(
          find.descendant(
            of: find.byKey(Key(key)),
            matching: find.byType(DecoratedBox),
          ),
        );
        return (box.decoration as BoxDecoration).color;
      }

      final home = legibleSideShade(Colors.teal, brightness, home: true);
      final away = legibleSideShade(Colors.purple, brightness, home: false);

      testWidgets('${brightness.name}: the stripe, the lane dots and the bar', (
        tester,
      ) async {
        await pump(tester, _rudna[0]);
        expect(
          tester
              .widget<ColoredBox>(find.byKey(const Key('duel-1-stripe')))
              .color,
          home,
        );
        // Lane 1 went away, lane 2 home.
        expect(fillIn(tester, 'duel-1-lane-1-dot'), away);
        expect(fillIn(tester, 'duel-1-lane-2-dot'), home);
        expect(fillIn(tester, 'duel-1-bar-fill'), home);
      });

      testWidgets('${brightness.name}: a live bar is half strength inside a '
          'full-strength 1dp edge', (tester) async {
        await pump(tester, _playing);
        final box = tester.widget<DecoratedBox>(
          find.descendant(
            of: find.byKey(const Key('duel-1-bar-fill')),
            matching: find.byType(DecoratedBox),
          ),
        );
        final decoration = box.decoration as BoxDecoration;
        expect(decoration.color, away.withValues(alpha: 0.5));
        expect(decoration.border, Border.all(color: away));
      });
    }
  });

  testWidgets('a substitution shows under the starter, nowhere else', (
    tester,
  ) async {
    final duel = duelsOf([
      MatchPlayerResult.fromJson({
        'id': 'a',
        'match_id': 'x',
        'side': 'away',
        'position': 1,
        'player_name': 'Pavel Medek',
        'sub_name': 'Miloš Vážan',
        'sub_from_throw': 41,
        'lanes': [_lane(1, 200), _lane(2, 210)],
        'total': 410,
      }),
      _player('home', 1, [_lane(1, 190), _lane(2, 200)], total: 390),
    ]).single;
    await tester.pumpWidget(_host(_card(duel)));
    expect(find.text('Pavel Medek'), findsOneWidget);
    expect(find.text('od 41. hodu Miloš Vážan'), findsOneWidget);
    await tester.pumpWidget(_host(_card(_rudna[0])));
    expect(find.textContaining('od '), findsNothing);
  });

  testWidgets('the lead is printed in its side colour: + home, - guests', (
    tester,
  ) async {
    Color? colorOf(String label) => tester.widget<Text>(find.text(label)).style?.color;
    Color shade(Color c) => legibleSideText(c, Brightness.light, highContrast: false);
    // Duel 1 went to home (+22), duel 6 to the guests (-3); the card's
    // sides are teal and purple.
    await tester.pumpWidget(_host(_card(_rudna[0])));
    expect(colorOf('+22'), shade(Colors.teal));
    await tester.pumpWidget(_host(_card(_rudna[5])));
    expect(colorOf('-3'), shade(Colors.purple));
  });

  testWidgets('tapping the card calls onTap once', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(_card(_rudna[0], onTap: () => taps++)));
    await tester.tap(find.byType(DuelCard));
    expect(taps, 1);
  });

  testWidgets('one semantics label for the whole card', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_host(_card(_rudna[0])));
    // Read off the node itself: `containsSemantics` is deprecated on the
    // newest Flutter and its successor `isSemantics` is not on the oldest
    // one this repo builds with.
    final node = tester.getSemantics(find.byType(DuelCard)).getSemanticsData();
    expect(node.label, duelSemantics(_rudna[0]));
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.hasAction(SemanticsAction.tap), isTrue);
    expect(find.bySemanticsLabel(duelSemantics(_rudna[0])), findsOneWidget);
    semantics.dispose();
  });

  group('live, playing: lane 1 thrown by both, lane 2 only by home', () {
    testWidgets('after 1 of 2 lanes; no winner styling yet', (tester) async {
      await tester.pumpWidget(_host(_card(_playing)));
      expect(find.text('po 1 ze 2 drah'), findsOneWidget);
      expect(_laneRow(tester, 1, 2), ['–', ' : ', '–']);
      expect(find.text('bod'), findsNothing);
      expect(find.text('½'), findsNothing);
      // The totals count only the lane both threw, as the lead does.
      // The 32dp totals carry no winner weight while the duel is played; a
      // thrown lane still has its own winner (216 in lane 1).
      for (final total in ['213', '216']) {
        final big = tester
            .widgetList<Text>(find.text(total))
            .where((t) => t.style?.fontSize == 32);
        expect(big.single.style?.fontWeight, FontWeight.w500, reason: total);
      }
      expect(_inLane(tester, 1, 1, '216').style?.fontWeight, FontWeight.w800);
      expect(find.text('363'), findsNothing);
      expect(find.text('-3'), findsOneWidget);
      expect(find.textContaining('SB'), findsNothing);
      expect(find.byKey(const Key('duel-1-stripe')), findsNothing);
    });

    testWidgets('TalkBack reads the totals the card prints, and the leader', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_host(_card(_playing)));
      expect(
        find.bySemanticsLabel(
          '1. souboj: home 1 213, away 1 216, hraje se, vede 1 o 3',
        ),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('the bar is at half strength', (tester) async {
      await tester.pumpWidget(_host(_card(_playing)));
      final fill = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byKey(const Key('duel-1-bar-fill')),
          matching: find.byType(DecoratedBox),
        ),
      );
      final color = (fill.decoration as BoxDecoration).color!;
      expect(color.a, closeTo(0.5, 0.01));
    });

    testWidgets('expanded: the table, but no sentence yet', (tester) async {
      await tester.pumpWidget(_host(_card(_playing, expanded: true)));
      expect(find.text('Plné'), findsNWidgets(2));
      // Neither the verdict line nor the sentence („SB 1 : 1 → …“).
      expect(find.textContaining('SB'), findsNothing);
    });
  });

  group('live, waiting', () {
    testWidgets('a slim card with the names and „čeká“', (tester) async {
      await tester.pumpWidget(_host(_card(_waiting)));
      expect(find.text('čeká'), findsOneWidget);
      expect(find.text('home 1'), findsOneWidget);
      expect(find.text('away 1'), findsOneWidget);
      expect(tester.getSize(find.byType(DuelCard)).height, lessThan(80));
      expect(
        tester.getSize(find.byType(DuelCard)).height,
        greaterThanOrEqualTo(56),
      );
      expect(find.text('1.'), findsNothing);
    });

    testWidgets('it never expands, but a tap still reaches onTap', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(_card(_waiting, expanded: true, onTap: () => taps++)),
      );
      expect(find.text('Plné'), findsNothing);
      expect(find.byIcon(Icons.expand_less), findsNothing);
      await tester.tap(find.byType(DuelCard));
      expect(taps, 1);
    });
  });

  testWidgets('T120: the four lanes in a 2×2 grid', (tester) async {
    await tester.pumpWidget(_host(_card(_t120)));
    for (var n = 1; n <= 4; n++) {
      expect(find.text('$n.'), findsOneWidget);
    }
    final dr1 = tester.getTopLeft(find.text('1.'));
    final dr2 = tester.getTopLeft(find.text('2.'));
    final dr3 = tester.getTopLeft(find.text('3.'));
    final dr4 = tester.getTopLeft(find.text('4.'));
    expect(dr3.dy, greaterThan(dr1.dy));
    expect(dr3.dx, closeTo(dr1.dx, 0.01));
    expect(dr2.dy, closeTo(dr1.dy, 0.01));
    expect(dr2.dx, greaterThan(dr1.dx));
    expect(dr4.dy, closeTo(dr3.dy, 0.01));
    expect(dr4.dx, closeTo(dr2.dx, 0.01));
  });

  testWidgets('T120: the set points in the result, the pins in brackets', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_card(_t120, showSetPoints: true)));
    // „4 (600)  +40  (560) 0“: SB big, the pins beside them in brackets.
    expect(find.text('4 (600)'), findsOneWidget);
    expect(find.text('(560) 0'), findsOneWidget);
    // Nothing of the old verdict line.
    expect(find.text('SB 4 : 0'), findsNothing);
    // Without set points (100 throws) the plain pins.
    await tester.pumpWidget(_host(_card(_t120)));
    expect(find.text('4 (600)'), findsNothing);
    expect(find.text('600'), findsOneWidget);
  });

  testWidgets('T120: 1. and 3. (2. and 4.) start in one column, thrown or not', (
    tester,
  ) async {
    final duel = duelsOf([
      _player('home', 1, [
        _lane(1, 150, 1),
        _lane(2, 150, 1),
        _lane(3, null),
        _lane(4, null),
      ]),
      _player('away', 1, [
        _lane(1, 140, 0),
        _lane(2, 140, 0),
        _lane(3, null),
        _lane(4, null),
      ]),
    ]).single;
    await tester.pumpWidget(_host(_card(duel)));
    expect(
      tester.getTopLeft(find.text('1.')).dx,
      closeTo(tester.getTopLeft(find.text('3.')).dx, 0.01),
    );
    expect(
      tester.getTopLeft(find.text('2.')).dx,
      closeTo(tester.getTopLeft(find.text('4.')).dx, 0.01),
    );
    // The colons stand under each other as well, thrown lane or not.
    double colon(int lane) => tester
        .getCenter(
          find.descendant(
            of: find.byKey(Key('duel-1-lane-$lane-score')),
            matching: find.text(lane <= 2 ? ' : ' : ' : '),
          ),
        )
        .dx;
    expect(colon(1), closeTo(colon(3), 0.01));
    expect(colon(2), closeTo(colon(4), 0.01));
  });

  testWidgets('a split point: no stripe, no bar, the lead „=“', (tester) async {
    await tester.pumpWidget(_host(_card(_split, expanded: true)));
    // A split has no pill and no winner weight: just the lead „=“.
    expect(find.text('½'), findsNothing);
    expect(find.text('bod'), findsNothing);
    // The lead and the tied lane in the open table.
    expect(find.text('='), findsNWidgets(2));
    expect(find.byKey(const Key('duel-1-stripe')), findsNothing);
    expect(find.byKey(const Key('duel-1-bar-fill')), findsNothing);
    expect(find.textContaining('body'), findsNothing);
  });

  final states = {
    'duel 1': (duel: _rudna[0], expanded: false),
    'duel 1 expanded': (duel: _rudna[0], expanded: true),
    'duel 6 expanded': (duel: _rudna[5], expanded: true),
    'playing expanded': (duel: _playing, expanded: true),
    'waiting': (duel: _waiting, expanded: false),
    'T120 expanded': (duel: _t120, expanded: true),
    'split expanded': (duel: _split, expanded: true),
  };
  for (final MapEntry(key: name, value: state) in states.entries) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('$name: no overflow on a 360dp phone at text scale $scale', (
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
                    child: _card(state.duel, expanded: state.expanded),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(
          tester.getRect(find.byType(DuelCard)).right,
          lessThanOrEqualTo(360),
        );
      });
    }
  }

  group('a walkover (nobody opposite)', () {
    // The fourth home player throws 217 + 223 with nobody opposite.
    final lone = duelsOf([
      _player('home', 1, [_lane(1, 190), _lane(2, 190)], total: 380, sb: 0, tb: 0),
      _player('away', 1, [_lane(1, 200), _lane(2, 200)], total: 400, sb: 2, tb: 1),
      _player('home', 2, [_lane(1, 217), _lane(2, 223)], total: 440),
    ]).last;

    testWidgets('says „bez soupeře“, shows the lone total, no lead, and marks '
        'every lane for the present player', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DuelCard(
              duel: lone,
              scale: 50,
              expanded: false,
              onTap: () {},
              homeColor: Colors.green,
              awayColor: Colors.red,
            ),
          ),
        ),
      );
      expect(find.text('bez soupeře'), findsOneWidget);
      expect(find.text('440'), findsOneWidget);
      expect(find.textContaining('po 0 ze'), findsNothing);
      expect(find.byKey(const Key('duel-2-lane-1-dot')), findsOneWidget);
      expect(find.byKey(const Key('duel-2-lane-2-dot')), findsOneWidget);
      expect(find.text('217'), findsOneWidget);
      expect(find.text('223'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
