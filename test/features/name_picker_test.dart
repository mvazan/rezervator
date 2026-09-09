import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/palette.dart';
import 'package:rezervator/features/kiosk/name_picker.dart';

/// The kiosk picker's LAYOUT and COLOUR, measured. Both used to be wrong in
/// a way no test noticed: every tile was one full-width row (a `Center`
/// inside a `Wrap` child expands to the loose constraints it gets), so a
/// 1920px kiosk showed one letter per line, and every name wore the same
/// brand gradient regardless of club.
void main() {
  // A tile's painted box: SizedBox → Ink (the decoration) → InkWell.
  Finder tileOf(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(Ink));

  BoxDecoration decorationOf(WidgetTester tester, String label) =>
      tester.widget<Ink>(tileOf(label)).decoration! as BoxDecoration;

  Widget picker(
    List<PlayerName> players, {
    Brightness brightness = Brightness.dark,
  }) =>
      ProviderScope(
        overrides: [playersProvider.overrideWith((ref) async => players)],
        child: MaterialApp(home: NamePicker(brightness: brightness)),
      );

  void surface(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// 26 players, distinct first letters — more than the picker's capacity,
  /// so the root always renders letter tiles.
  final manyPlayers = [
    for (var i = 0; i < 26; i++)
      PlayerName(
        id: 'p$i',
        displayName:
            '${String.fromCharCode(65 + i)}${String.fromCharCode(65 + i)} Hráč',
      ),
  ];

  testWidgets('letters are squares in a grid, not one row each',
      (tester) async {
    surface(tester, const Size(1280, 800));
    await tester.pumpWidget(picker(manyPlayers));
    await tester.pumpAndSettle();

    final a = tester.getRect(tileOf('A'));
    final b = tester.getRect(tileOf('B'));
    expect(a.width, lessThan(200),
        reason: 'a letter tile is a square, not a full-width row');
    expect(a.width, a.height);
    expect(b.top, a.top, reason: 'B sits beside A, not under it');
    expect(b.left, greaterThan(a.right));

    // The whole alphabet fits on a 1280px screen in a handful of rows.
    final rows = {for (final l in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('')) tester.getRect(tileOf(l)).top};
    expect(rows.length, lessThanOrEqualTo(4));
  });

  testWidgets('names fill the width in columns, one column on a narrow screen',
      (tester) async {
    final players = [
      for (var i = 0; i < 6; i++)
        PlayerName(id: 'p$i', displayName: 'Hráč Číslo $i'),
    ];

    surface(tester, const Size(1280, 800));
    await tester.pumpWidget(picker(players));
    await tester.pumpAndSettle();

    final first = tester.getRect(tileOf('Hráč Číslo 0'));
    final second = tester.getRect(tileOf('Hráč Číslo 1'));
    expect(second.top, first.top, reason: 'two names share a row at 1280px');
    expect(first.height, 88);

    // A phone-sized kiosk (or a portrait tablet) drops to one column rather
    // than squeezing two unreadable ones.
    surface(tester, const Size(420, 900));
    await tester.pumpWidget(picker(players));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(tileOf('Hráč Číslo 1')).top,
      greaterThan(tester.getRect(tileOf('Hráč Číslo 0')).top),
    );
  });

  testWidgets('a name tile wears its club colour, outlined in its own text '
      'colour; a clubless player gets the neutral surface', (tester) async {
    const clubIndex = 3; // Fialová
    final players = [
      const PlayerName(id: 'p1', displayName: 'Klubový Hráč', clubColor: clubIndex),
      const PlayerName(id: 'p2', displayName: 'Bez Klubu'),
    ];
    surface(tester, const Size(1280, 800));
    await tester.pumpWidget(picker(players));
    await tester.pumpAndSettle();

    final (bg, fg) = ClubColors.of(clubIndex, Brightness.dark)!;
    final clubTile = decorationOf(tester, 'Klubový Hráč');
    expect(clubTile.color, bg);
    expect((clubTile.border as Border).top.color, fg,
        reason: 'the outline is what separates the tile from the page');
    expect(tester.widget<Text>(find.text('Klubový Hráč')).style?.color, fg);

    final scheme = Theme.of(tester.element(find.text('Bez Klubu'))).colorScheme;
    final plainTile = decorationOf(tester, 'Bez Klubu');
    expect(plainTile.color, scheme.surfaceContainerHigh);
    expect((plainTile.border as Border).top.color, scheme.outline);
  });

  testWidgets('a hand-picked club colour is shaded, never painted raw',
      (tester) async {
    final packed = packCustomColor(const Color(0xFFFF9800));
    final players = [
      PlayerName(id: 'p1', displayName: 'Vlastní Barva', clubColor: packed),
    ];
    surface(tester, const Size(1280, 800));
    await tester.pumpWidget(picker(players));
    await tester.pumpAndSettle();

    final (bg, fg) = customTint(packed, Brightness.dark);
    expect(decorationOf(tester, 'Vlastní Barva').color, bg);
    expect(tester.widget<Text>(find.text('Vlastní Barva')).style?.color, fg);
  });

  testWidgets('drilling in and back: Zpět is its own control above the grid',
      (tester) async {
    surface(tester, const Size(1280, 800));
    await tester.pumpWidget(picker(manyPlayers));
    await tester.pumpAndSettle();
    expect(find.text('Zpět'), findsNothing, reason: 'nothing to go back to');

    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    expect(find.text('AA Hráč'), findsOneWidget);
    expect(find.text('A…'), findsOneWidget, reason: 'where you are');

    // Above the tiles, not among them.
    expect(
      tester.getRect(find.text('Zpět')).bottom,
      lessThan(tester.getRect(tileOf('AA Hráč')).top),
    );

    await tester.tap(find.text('Zpět'));
    await tester.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);
  });

  testWidgets('picking a name pops it', (tester) async {
    surface(tester, const Size(1280, 800));
    PlayerName? picked;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playersProvider.overrideWith((ref) async => manyPlayers),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async =>
                      picked = await showNamePicker(context),
                  child: const Text('Otevřít'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Otevřít'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AA Hráč'));
    await tester.pumpAndSettle();

    expect(picked?.id, 'p0');
  });

  testWidgets('the light kiosk theme gets the light palette shades',
      (tester) async {
    const clubIndex = 2; // Červená
    surface(tester, const Size(1280, 800));
    await tester.pumpWidget(picker(
      [
        const PlayerName(
            id: 'p1', displayName: 'Světlý Hráč', clubColor: clubIndex),
      ],
      brightness: Brightness.light,
    ));
    await tester.pumpAndSettle();

    final (bg, fg) = ClubColors.of(clubIndex, Brightness.light)!;
    expect(decorationOf(tester, 'Světlý Hráč').color, bg);
    expect(tester.widget<Text>(find.text('Světlý Hráč')).style?.color, fg);
  });
}
