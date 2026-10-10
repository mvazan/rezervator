import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/kiosk/kiosk_stream_window.dart';

void main() {
  const matchType = PrioritySlotType(
    id: 'tm',
    name: 'Zápas',
    isMatch: true,
    builtin: true,
  );
  PrioritySlot match(String id, String video, {String home = 'Domácí'}) =>
      PrioritySlot(
        id: id,
        date: Day(2026, 10, 8),
        startsAt: const HourMinute(14, 0),
        endsAt: const HourMinute(17, 0),
        type: matchType,
        homeTeam: home,
        awayTeam: 'Hosté',
        importKey: 'cka:$id',
        videoUrl: 'https://www.youtube.com/watch?v=$video',
      );
  const v1 = 'wOq9EODb8w8';
  const v2 = 'abcdefghijk';
  final one = [match('m1', v1)];
  final two = [match('m1', v1), match('m2', v2, home: 'Druzí')];

  /// The latest player's „the video has ended“.
  VoidCallback? ended;

  /// The player stand-in: the video and whether it takes touches.
  Widget player(
    String videoId, {
    required bool interactive,
    VoidCallback? onEnded,
  }) {
    ended = onEnded;
    return Text(
      'player $videoId ${interactive ? 'on' : 'off'}',
      key: const ValueKey('player'),
    );
  }

  final playerFinder = find.byKey(const ValueKey('player'));

  /// The streams closed (the ×, an end), in order.
  late List<String> closed;
  late List<bool> maximized;
  setUp(() {
    closed = [];
    maximized = [];
    ended = null;
  });

  /// The window on a 1200 × 700 area.
  Widget app(
    List<PrioritySlot> matches, {
    KioskCorner corner = KioskCorner.bl,
    int width = 35,
    bool interactive = true,
    KioskStreamReveal? reveal,
    bool hidden = false,
  }) => MaterialApp(
    home: Scaffold(
      body: KioskStreamWindow(
        matches: matches,
        content: player,
        corner: corner,
        widthPercent: width,
        interactive: interactive,
        reveal: reveal,
        hidden: hidden,
        onClose: closed.add,
        onMaximized: maximized.add,
      ),
    ),
  );

  void area(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  // 35 % of 1200 = 420 wide; the player 420 × 236.25 under a 40 px bar,
  // a 20 px bar below; the frame 296.25 tall.
  const w = 420.0;
  const playerH = w * 9 / 16;
  const frameH = 40 + 20 + playerH;

  testWidgets('opens at the admin\'s corner and width, the player under the '
      'title bar', (tester) async {
    area(tester);
    await tester.pumpWidget(app(one));
    await tester.pumpAndSettle();

    expect(find.text('player $v1 on'), findsOneWidget);
    expect(find.text('Domácí – Hosté'), findsOneWidget);
    expect(
      tester.getRect(playerFinder),
      Rect.fromLTWH(8, 700 - 8 - frameH + 40, w, playerH),
    );

    // A fresh window (the old one keeps its place through rebuilds).
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(app(one, corner: KioskCorner.tr, width: 50));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(playerFinder),
      Rect.fromLTWH(1200 - 8 - 600, 8 + 40, 600, 600 * 9 / 16),
    );
  });

  testWidgets('the title bar drags the window, and it stays inside the area',
      (tester) async {
    area(tester);
    await tester.pumpWidget(app(one));
    await tester.pumpAndSettle();
    final before = tester.getRect(playerFinder);

    await tester.drag(find.text('Domácí – Hosté'), const Offset(100, -50));
    await tester.pumpAndSettle();
    expect(tester.getRect(playerFinder), before.shift(const Offset(100, -50)));

    await tester.drag(find.text('Domácí – Hosté'), const Offset(-2000, 2000));
    await tester.pumpAndSettle();
    final rect = tester.getRect(playerFinder);
    expect(rect.left, 0);
    expect(rect.bottom + 20, 700);
  });

  testWidgets('the grip resizes the window, 16:9 kept, down to the minimum '
      'width', (tester) async {
    area(tester);
    await tester.pumpWidget(app(one));
    await tester.pumpAndSettle();
    final before = tester.getRect(playerFinder);

    await tester.drag(find.byTooltip('Změnit velikost'), const Offset(200, 0));
    await tester.pumpAndSettle();
    var rect = tester.getRect(playerFinder);
    expect(rect.width, before.width + 200);
    expect(rect.height, closeTo(rect.width * 9 / 16, 0.01));
    expect(rect.left, before.left);

    await tester.drag(find.byTooltip('Změnit velikost'), const Offset(-2000, 0));
    await tester.pumpAndSettle();
    rect = tester.getRect(playerFinder);
    expect(rect.width, KioskStreamWindow.minWidth);
    expect(rect.height, closeTo(KioskStreamWindow.minWidth * 9 / 16, 0.01));
  });

  testWidgets('maximize fills the area under the title bar; back brings the '
      'window where it was', (tester) async {
    area(tester);
    await tester.pumpWidget(app(one));
    await tester.pumpAndSettle();
    final before = tester.getRect(playerFinder);

    await tester.tap(find.byTooltip('Na celou obrazovku'));
    await tester.pumpAndSettle();
    expect(tester.getRect(playerFinder), const Rect.fromLTWH(0, 40, 1200, 660));
    expect(find.byTooltip('Změnit velikost'), findsNothing);

    await tester.tap(find.byTooltip('Zmenšit'));
    await tester.pumpAndSettle();
    expect(tester.getRect(playerFinder), before);
    // The layer heard both.
    expect(maximized, [true, false]);
  });

  testWidgets('the × closes the stream shown; with more, the window turns on '
      'to the next one', (tester) async {
    area(tester);
    await tester.pumpWidget(app(two));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Zavřít stream'));
    await tester.pump();
    expect(closed, ['m1']);
    // Before the list even shrinks, the next stream is on.
    expect(find.text('player $v2 on'), findsOneWidget);

    await tester.pumpWidget(app([two[1]]));
    await tester.pumpAndSettle();
    expect(find.text('player $v2 on'), findsOneWidget);
    await tester.tap(find.byTooltip('Zavřít stream'));
    await tester.pump();
    expect(closed, ['m1', 'm2']);
  });

  testWidgets('the collapsed pill has its × too', (tester) async {
    area(tester);
    await tester.pumpWidget(app(one));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Sbalit'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Zavřít stream'));
    await tester.pump();
    expect(closed, ['m1']);
  });

  testWidgets('the end of the video closes it, and turns on to the next',
      (tester) async {
    area(tester);
    await tester.pumpWidget(app(two));
    await tester.pumpAndSettle();
    expect(find.text('player $v1 on'), findsOneWidget);

    ended!();
    await tester.pump();
    expect(closed, ['m1']);
    expect(find.text('player $v2 on'), findsOneWidget);
  });

  testWidgets('a ▶ at one of its streams turns the window to it and expands '
      'it', (tester) async {
    area(tester);
    await tester.pumpWidget(app(two));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Sbalit'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(app(two, reveal: (id: 'm2', seq: 1)));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Rozbalit stream'), findsNothing);
    expect(find.text('player $v2 on'), findsOneWidget);
    expect(find.text('2/2'), findsOneWidget);
  });

  testWidgets('a window born with a ▶ opens on its match', (tester) async {
    area(tester);
    await tester.pumpWidget(app(two, reveal: (id: 'm2', seq: 3)));
    await tester.pumpAndSettle();
    expect(find.text('player $v2 on'), findsOneWidget);
  });

  testWidgets('a ▶ at another window\'s stream takes this one off the whole '
      'area', (tester) async {
    area(tester);
    await tester.pumpWidget(app(one));
    await tester.pumpAndSettle();
    final before = tester.getRect(playerFinder);
    await tester.tap(find.byTooltip('Na celou obrazovku'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(app(one, reveal: (id: 'elsewhere', seq: 1)));
    await tester.pumpAndSettle();
    expect(tester.getRect(playerFinder), before);
  });

  testWidgets('hidden behind a maximized window: only the player, in a '
      'pixel, taking no touches — the same element', (tester) async {
    area(tester);
    await tester.pumpWidget(app(one));
    await tester.pumpAndSettle();
    final element = tester.element(playerFinder);

    await tester.pumpWidget(app(one, hidden: true));
    await tester.pumpAndSettle();
    expect(find.text('Domácí – Hosté'), findsNothing);
    expect(find.byTooltip('Zavřít stream'), findsNothing);
    expect(tester.getRect(playerFinder).size, const Size(1, 1));
    expect(find.text('player $v1 off'), findsOneWidget);
    expect(identical(tester.element(playerFinder), element), isTrue);

    await tester.pumpWidget(app(one));
    await tester.pumpAndSettle();
    expect(find.text('player $v1 on'), findsOneWidget);
    expect(identical(tester.element(playerFinder), element), isTrue);
  });

  testWidgets('collapse leaves a pill and keeps the very same player alive; '
      'a tap brings the window back', (tester) async {
    area(tester);
    await tester.pumpWidget(app(one));
    await tester.pumpAndSettle();
    final before = tester.getRect(playerFinder);
    final element = tester.element(playerFinder);

    await tester.tap(find.byTooltip('Sbalit'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Rozbalit stream'), findsOneWidget);
    expect(find.text('Domácí – Hosté'), findsOneWidget);
    expect(tester.getRect(playerFinder).size, const Size(1, 1));
    expect(identical(tester.element(playerFinder), element), isTrue);

    await tester.tap(find.byTooltip('Rozbalit stream'));
    await tester.pumpAndSettle();
    expect(tester.getRect(playerFinder), before);
    expect(identical(tester.element(playerFinder), element), isTrue);
  });

  testWidgets('two matches: ‹ › turn between them, the window stays put; the '
      'shown one survives a change of the list', (tester) async {
    area(tester);
    await tester.pumpWidget(app(two));
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);
    expect(find.text('player $v1 on'), findsOneWidget);
    await tester.drag(find.text('Domácí – Hosté'), const Offset(100, -100));
    await tester.pumpAndSettle();
    final moved = tester.getRect(playerFinder);

    await tester.tap(find.byTooltip('Další zápas'));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
    expect(find.text('player $v2 on'), findsOneWidget);
    expect(find.text('Druzí – Hosté'), findsOneWidget);
    expect(tester.getRect(playerFinder), moved);

    // The first match ends: the list shrinks, the shown one stays shown.
    await tester.pumpWidget(app([two[1]]));
    await tester.pumpAndSettle();
    expect(find.text('player $v2 on'), findsOneWidget);
    expect(find.text('2/2'), findsNothing);
    expect(tester.getRect(playerFinder), moved);

    // A match joins again: still the same window, same place.
    await tester.pumpWidget(app(two));
    await tester.pumpAndSettle();
    expect(find.text('player $v2 on'), findsOneWidget);
    expect(tester.getRect(playerFinder), moved);
  });

  testWidgets('a maximize or a collapse mid-drag ends the gesture: the player '
      'takes touches again', (tester) async {
    area(tester);
    await tester.pumpWidget(app(one));
    await tester.pumpAndSettle();
    final drag = await tester.startGesture(
      tester.getCenter(find.text('Domácí – Hosté')),
    );
    await drag.moveBy(const Offset(30, 30));
    await tester.pump();
    expect(find.text('player $v1 off'), findsOneWidget);

    // A second finger: the bar loses its pan mid-gesture.
    await tester.tap(find.byTooltip('Na celou obrazovku'));
    await tester.pumpAndSettle();
    expect(find.text('player $v1 on'), findsOneWidget);
    await drag.up();
    await tester.pumpAndSettle();
    expect(find.text('player $v1 on'), findsOneWidget);
  });

  testWidgets('a finger that rests on the grip and then drags still resizes '
      '— no long-press tooltip takes the gesture', (tester) async {
    area(tester);
    await tester.pumpWidget(app(one));
    await tester.pumpAndSettle();
    final before = tester.getRect(playerFinder);

    final grip = await tester.startGesture(
      tester.getCenter(find.byTooltip('Změnit velikost')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await grip.moveBy(const Offset(100, 0));
    await tester.pump();
    await grip.up();
    await tester.pumpAndSettle();
    expect(tester.getRect(playerFinder).width, before.width + 100);
  });

  testWidgets('the grip cannot make the window taller than the area: the '
      'bottom bar and the grip stay within reach', (tester) async {
    area(tester);
    await tester.pumpWidget(app(one));
    await tester.pumpAndSettle();

    await tester.drag(find.byTooltip('Změnit velikost'), const Offset(2000, 0));
    await tester.pumpAndSettle();
    final rect = tester.getRect(playerFinder);
    expect(rect.width, closeTo((700 - 60) * 16 / 9, 0.01));
    expect(rect.bottom + KioskStreamWindow.bottomHeight, lessThanOrEqualTo(700));
    expect(
      tester.getRect(find.byTooltip('Změnit velikost')).bottom,
      lessThanOrEqualTo(700),
    );
  });

  testWidgets('the player takes no touches during a drag or a resize, nor '
      'while a route sits above the kiosk', (tester) async {
    area(tester);
    await tester.pumpWidget(app(one));
    await tester.pumpAndSettle();
    expect(find.text('player $v1 on'), findsOneWidget);

    final drag = await tester.startGesture(
      tester.getCenter(find.text('Domácí – Hosté')),
    );
    await drag.moveBy(const Offset(30, 30));
    await tester.pump();
    expect(find.text('player $v1 off'), findsOneWidget);
    await drag.up();
    await tester.pumpAndSettle();
    expect(find.text('player $v1 on'), findsOneWidget);

    final resize = await tester.startGesture(
      tester.getCenter(find.byTooltip('Změnit velikost')),
    );
    await resize.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(find.text('player $v1 off'), findsOneWidget);
    await resize.up();
    await tester.pumpAndSettle();
    expect(find.text('player $v1 on'), findsOneWidget);

    await tester.pumpWidget(app(one, interactive: false));
    await tester.pumpAndSettle();
    expect(find.text('player $v1 off'), findsOneWidget);
  });
}
