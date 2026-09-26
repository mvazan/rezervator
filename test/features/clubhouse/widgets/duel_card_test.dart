import 'package:flutter/material.dart';
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
}) => DuelCard(
  duel: duel,
  scale: scale ?? _scale,
  expanded: expanded,
  onTap: onTap ?? () {},
  homeColor: Colors.teal,
  awayColor: Colors.purple,
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
TextStyle? _spanStyle(WidgetTester tester, String lane, String number) {
  final span = _text(tester, lane).textSpan!;
  TextStyle? found;
  span.visitChildren((child) {
    if (child is TextSpan && child.text == number) {
      found = child.style;
      return false;
    }
    return true;
  });
  return found;
}

void main() {
  group('duel 1, collapsed: Mičanová 407 : 385 Pelánek, pins decided', () {
    Future<void> pump(WidgetTester tester) =>
        tester.pumpWidget(_host(_card(_rudna[0])));

    testWidgets("the winner's total is w800, the loser's w500", (tester) async {
      await pump(tester);
      expect(_text(tester, '407').style?.fontWeight, FontWeight.w800);
      expect(_text(tester, '385').style?.fontWeight, FontWeight.w500);
    });

    testWidgets('one „bod“ pill, the lead and the lanes', (tester) async {
      await pump(tester);
      expect(find.text('bod'), findsOneWidget);
      expect(find.text('½'), findsNothing);
      expect(find.text('◂ 22'), findsOneWidget);
      expect(find.text('Dr. 1'), findsOneWidget);
      expect(find.text('Dr. 2'), findsOneWidget);
      expect(find.text('213 : 216'), findsOneWidget);
      expect(find.text('194 : 169'), findsOneWidget);
    });

    testWidgets('the „bod“ pill sits next to the home total', (tester) async {
      await pump(tester);
      final pill = tester.getCenter(find.text('bod'));
      expect(pill.dx, greaterThan(tester.getCenter(find.text('407')).dx));
      expect(pill.dx, lessThan(tester.getCenter(find.text('◂ 22')).dx));
    });

    testWidgets('the verdict line and a closed chevron; no table', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('SB 1 : 1 · rozhodly kuželky'), findsOneWidget);
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
      expect(
        _spanStyle(tester, '213 : 216', '216')?.fontWeight,
        FontWeight.w800,
      );
      expect(
        _spanStyle(tester, '213 : 216', '213')?.fontWeight,
        FontWeight.w500,
      );
      expect(
        _spanStyle(tester, '194 : 169', '194')?.fontWeight,
        FontWeight.w800,
      );
      expect(
        _spanStyle(tester, '194 : 169', '169')?.fontWeight,
        FontWeight.w500,
      );
      final dot1 = _rect(tester, 'duel-1-lane-1-dot');
      final dot2 = _rect(tester, 'duel-1-lane-2-dot');
      expect(
        dot1.left,
        greaterThan(tester.getRect(find.text('213 : 216')).right),
      );
      expect(dot2.right, lessThan(tester.getRect(find.text('194 : 169')).left));
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
      for (final number in ['407', '385', '◂ 22', '213 : 216']) {
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
      expect(find.byIcon(Icons.expand_less), findsOneWidget);
    });

    testWidgets('the sentence tells how the point was won', (tester) async {
      await pump(tester);
      expect(
        find.text('SB 1 : 1 → rozhodly kuželky 407 : 385 → bod Mičanová'),
        findsOneWidget,
      );
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
      expect(find.text('3 ▸'), findsOneWidget);
      expect(_text(tester, '434').style?.fontWeight, FontWeight.w800);
      expect(_text(tester, '431').style?.fontWeight, FontWeight.w500);
      expect(find.text('215 = 215'), findsOneWidget);
      // A tie has no dot and no winner weight.
      expect(find.byKey(const Key('duel-6-lane-1-dot')), findsNothing);
      expect(
        _spanStyle(tester, '215 = 215', '215')?.fontWeight,
        FontWeight.w500,
      );
      expect(find.text('SB 0,5 : 1,5'), findsOneWidget);
    });

    testWidgets('the pill, the bar and the stripe sit on the away side', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_card(_rudna[5])));
      final pill = tester.getCenter(find.text('bod'));
      expect(pill.dx, greaterThan(tester.getCenter(find.text('3 ▸')).dx));
      expect(pill.dx, lessThan(tester.getCenter(find.text('434')).dx));

      final track = _rect(tester, 'duel-6-bar');
      final fill = _rect(tester, 'duel-6-bar-fill');
      expect(fill.left, closeTo(track.center.dx, 0.01));
      expect(fill.width, closeTo(3 / 99 * track.width / 2, 0.01));

      final card = tester.getRect(find.byType(DuelCard));
      expect(_rect(tester, 'duel-6-stripe').right, closeTo(card.right, 0.01));
    });

    testWidgets('the sentence names the away winner by surname', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_card(_rudna[5], expanded: true)));
      expect(find.text('SB 0,5 : 1,5 → bod Vilímovský'), findsOneWidget);
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

      final home = legibleShadeOf(Colors.teal, brightness);
      final away = legibleShadeOf(Colors.purple, brightness);

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
        // The „bod“ pill keeps the side colour itself, at 16 %.
        final pill = tester.widget<DecoratedBox>(
          find
              .ancestor(
                of: find.text('bod'),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        expect(
          (pill.decoration as ShapeDecoration).color,
          Colors.teal.withValues(alpha: 0.16),
        );
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

  testWidgets('tapping the card calls onTap once', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(_card(_rudna[0], onTap: () => taps++)));
    await tester.tap(find.byType(DuelCard));
    expect(taps, 1);
  });

  testWidgets('one semantics label for the whole card', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_host(_card(_rudna[0])));
    expect(
      tester.getSemantics(find.byType(DuelCard)),
      containsSemantics(
        label: duelSemantics(_rudna[0]),
        isButton: true,
        hasTapAction: true,
      ),
    );
    expect(find.bySemanticsLabel(duelSemantics(_rudna[0])), findsOneWidget);
    semantics.dispose();
  });

  group('live, playing: lane 1 thrown by both, lane 2 only by home', () {
    testWidgets('after 1 of 2 lanes; no winner styling yet', (tester) async {
      await tester.pumpWidget(_host(_card(_playing)));
      expect(find.text('po 1 ze 2 drah'), findsOneWidget);
      expect(find.text('– : –'), findsOneWidget);
      expect(find.text('bod'), findsNothing);
      expect(find.text('½'), findsNothing);
      // The totals count only the lane both threw, as the lead does.
      expect(_text(tester, '213').style?.fontWeight, FontWeight.w500);
      expect(_text(tester, '216').style?.fontWeight, FontWeight.w500);
      expect(find.text('363'), findsNothing);
      expect(find.text('3 ▸'), findsOneWidget);
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
      expect(find.textContaining('→'), findsNothing);
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
      expect(find.text('Dr. 1'), findsNothing);
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
      expect(find.text('Dr. $n'), findsOneWidget);
    }
    final dr1 = tester.getTopLeft(find.text('Dr. 1'));
    final dr2 = tester.getTopLeft(find.text('Dr. 2'));
    final dr3 = tester.getTopLeft(find.text('Dr. 3'));
    final dr4 = tester.getTopLeft(find.text('Dr. 4'));
    expect(dr3.dy, greaterThan(dr1.dy));
    expect(dr3.dx, closeTo(dr1.dx, 0.01));
    expect(dr2.dy, closeTo(dr1.dy, 0.01));
    expect(dr2.dx, greaterThan(dr1.dx));
    expect(dr4.dy, closeTo(dr3.dy, 0.01));
    expect(dr4.dx, closeTo(dr2.dx, 0.01));
    expect(find.text('SB 4 : 0'), findsOneWidget);
  });

  testWidgets('a split point: „½“ on both sides, no stripe', (tester) async {
    await tester.pumpWidget(_host(_card(_split, expanded: true)));
    expect(find.text('½'), findsNWidgets(2));
    expect(find.text('bod'), findsNothing);
    expect(find.text('='), findsOneWidget);
    expect(find.byKey(const Key('duel-1-stripe')), findsNothing);
    expect(find.byKey(const Key('duel-1-bar-fill')), findsNothing);
    expect(find.text('SB 0,5 : 0,5 → body napůl'), findsOneWidget);
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
}
