import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/schedule/widgets/calendar_board.dart';

/// The band across the board's day headers (the kiosk's canteen duty,
/// 0073): one segment per day, a strip under the day label, rounded only
/// where the band starts or ends. The app's week board passes none and
/// keeps its header as it was.
void main() {
  final date = Day(2026, 10, 8);
  final header = find.byType(BoardColumnHeader);
  final band = find.byType(BoardBand);
  final strip = find.descendant(of: band, matching: find.byType(Material));
  const who = 'AA Hráč a PP Hráč';

  Future<void> pump(
    WidgetTester tester, {
    BoardBandSegment? segment,
    bool collapsed = false,
    double gap = 0,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 200,
              // Material's 1.43 line makes the 12 px day label 17 px, a
              // pixel more than the thin strip holds — the header's own
              // overflow, band or no band; a tighter line keeps these
              // tests about the band.
              child: DefaultTextStyle.merge(
                style: const TextStyle(height: 1.2),
                child: BoardColumnHeader(
                  date: date,
                  isToday: false,
                  priority: const [],
                  height: boardHeaderHeight(0) + boardBandHeight,
                  collapsed: collapsed,
                  gap: gap,
                  band: segment,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  BorderRadiusGeometry? radius(WidgetTester tester) =>
      tester.widget<Material>(strip).borderRadius;

  testWidgets('no band: nothing between the day label and the events', (
    tester,
  ) async {
    await pump(tester);
    expect(band, findsNothing);
    expect(find.text('čt 8.10.'), findsOneWidget);
  });

  testWidgets('a band is a strip under the day label, its label one '
      'ellipsised line', (tester) async {
    await pump(
      tester,
      segment: const BoardBandSegment(starts: true, ends: true, label: who),
    );
    expect(band, findsOneWidget);
    expect(
      tester.getRect(strip).top,
      greaterThanOrEqualTo(tester.getRect(find.text('čt 8.10.')).bottom),
    );
    final label = find.descendant(of: band, matching: find.text(who));
    expect(label, findsOneWidget);
    expect(tester.widget<Text>(label).maxLines, 1);
    expect(tester.widget<Text>(label).overflow, TextOverflow.ellipsis);
    expect(
      tester.widget<Material>(strip).color,
      Theme.of(tester.element(band)).colorScheme.secondaryContainer,
    );
  });

  testWidgets('rounded only where the band starts or ends; flush with the '
      'column where it runs on', (tester) async {
    await pump(
      tester,
      segment: const BoardBandSegment(starts: true, ends: true, label: who),
    );
    expect(
      radius(tester),
      const BorderRadius.horizontal(
        left: BoardBand.radius,
        right: BoardBand.radius,
      ),
    );
    expect(
      tester.getRect(strip).left,
      greaterThan(tester.getRect(header).left),
    );
    expect(
      tester.getRect(strip).right,
      lessThan(tester.getRect(header).right),
    );

    await pump(
      tester,
      segment: const BoardBandSegment(starts: true, ends: false, label: who),
    );
    expect(
      radius(tester),
      const BorderRadius.horizontal(left: BoardBand.radius),
    );
    expect(tester.getRect(strip).right, tester.getRect(header).right);

    await pump(
      tester,
      segment: const BoardBandSegment(starts: false, ends: true),
    );
    expect(
      radius(tester),
      const BorderRadius.horizontal(right: BoardBand.radius),
    );
    expect(tester.getRect(strip).left, tester.getRect(header).left);

    await pump(
      tester,
      segment: const BoardBandSegment(starts: false, ends: false),
    );
    expect(radius(tester), BorderRadius.zero);
    expect(tester.getRect(strip).left, tester.getRect(header).left);
    expect(tester.getRect(strip).right, tester.getRect(header).right);
  });

  testWidgets('with a gap the background stands in from the sides; the band '
      'runs on through it to the column\'s edge', (tester) async {
    // The header's background: the first box it decorates.
    final background = find
        .descendant(of: header, matching: find.byType(DecoratedBox))
        .first;
    await pump(
      tester,
      gap: 2,
      segment: const BoardBandSegment(starts: false, ends: false),
    );
    expect(
      tester.getRect(background).left,
      tester.getRect(header).left + 2,
    );
    expect(
      tester.getRect(background).right,
      tester.getRect(header).right - 2,
    );
    expect(tester.getRect(strip).left, tester.getRect(header).left);
    expect(tester.getRect(strip).right, tester.getRect(header).right);

    // Where it starts and ends, a little in from the background's sides.
    await pump(
      tester,
      gap: 2,
      segment: const BoardBandSegment(starts: true, ends: true, label: who),
    );
    expect(
      tester.getRect(strip).left,
      tester.getRect(background).left + 4,
    );
    expect(
      tester.getRect(strip).right,
      tester.getRect(background).right - 4,
    );
  });

  testWidgets('without a label the strip runs on blank', (tester) async {
    await pump(
      tester,
      segment: const BoardBandSegment(starts: false, ends: false),
    );
    expect(band, findsOneWidget);
    expect(
      find.descendant(of: band, matching: find.byType(Text)),
      findsNothing,
    );
  });

  testWidgets('a tap on the strip is its own', (tester) async {
    var taps = 0;
    await pump(
      tester,
      segment: BoardBandSegment(
        starts: true,
        ends: false,
        label: who,
        onTap: () => taps++,
      ),
    );
    await tester.tap(band);
    expect(taps, 1);
  });

  testWidgets('the collapsed header hides it', (tester) async {
    await pump(
      tester,
      collapsed: true,
      segment: const BoardBandSegment(starts: true, ends: true, label: who),
    );
    expect(tester.getSize(header).height, collapsedHeaderHeight);
    expect(band, findsNothing);
    expect(find.text(who), findsNothing);
    expect(find.text('čt 8.10.'), findsOneWidget);
  });
}
