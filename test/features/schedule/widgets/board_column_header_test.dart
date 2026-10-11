import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/widgets/emoji_text.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/schedule/widgets/calendar_board.dart';

/// The band across the board's day headers (the kiosk's canteen duty,
/// 0073): one segment per day, a strip above the day label, under it or
/// along the header's bottom edge, rounded only where the band starts or
/// ends. The app's week board has no band and keeps its header as it was.
void main() {
  final date = Day(2026, 10, 8);
  final header = find.byType(BoardColumnHeader);
  final band = find.byType(BoardBand);
  final strip = find.descendant(of: band, matching: find.byType(Material));
  const who = 'AA Hráč a PP Hráč';

  // Two of the day's matches: two lines under the day label.
  PrioritySlot match(String id, int hour) => PrioritySlot(
    id: id,
    date: date,
    startsAt: HourMinute(hour, 0),
    endsAt: HourMinute(hour + 3, 0),
    type: PrioritySlot.fallbackMatchType,
    homeTeam: 'Domácí $id',
    awayTeam: 'Hosté',
  );
  final matches = [match('a', 10), match('b', 15)];
  final lines = find.descendant(of: header, matching: find.byType(EmojiText));

  Future<void> pump(
    WidgetTester tester, {
    BoardBandSegment? segment,
    bool collapsed = false,
    double gap = 0,
    // Null: the app's week board, no band at all.
    KioskDutyBandPosition? position = KioskDutyBandPosition.middle,
    List<PrioritySlot> priority = const [],
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
                  priority: priority,
                  height:
                      boardHeaderHeight(0) +
                      (position == null ? 0 : boardBandHeight),
                  collapsed: collapsed,
                  gap: gap,
                  band: segment,
                  bandPosition: position,
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
    await pump(tester, position: null, priority: matches);
    expect(band, findsNothing);
    final label = find.text('čt 8.10.');
    expect(label, findsOneWidget);
    // The app's week board: the label on the header's top padding, the
    // lines right under it.
    expect(tester.getRect(label).top, tester.getRect(header).top + 4);
    expect(tester.getRect(lines.first).top, tester.getRect(label).bottom);
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

  group('where the band runs', () {
    const piece = BoardBandSegment(starts: true, ends: true, label: who);
    final label = find.text('čt 8.10.');

    testWidgets('middle: between the day label and the match lines', (
      tester,
    ) async {
      await pump(tester, segment: piece, priority: matches);
      expect(lines, findsNWidgets(2));
      expect(
        tester.getRect(strip).top,
        greaterThanOrEqualTo(tester.getRect(label).bottom),
      );
      expect(
        tester.getRect(strip).bottom,
        lessThanOrEqualTo(tester.getRect(lines.first).top),
      );
      expect(tester.getRect(label).top, tester.getRect(header).top + 4);
    });

    testWidgets('top: above the day label, flush with the header\'s top', (
      tester,
    ) async {
      await pump(
        tester,
        segment: piece,
        priority: matches,
        position: KioskDutyBandPosition.top,
      );
      expect(tester.getRect(strip).top, tester.getRect(header).top);
      expect(
        tester.getRect(strip).bottom,
        lessThanOrEqualTo(tester.getRect(label).top),
      );
      // The label and the lines below it keep their order.
      expect(
        tester.getRect(label).bottom,
        lessThanOrEqualTo(tester.getRect(lines.first).top),
      );
    });

    testWidgets('bottom: under the last match line, flush with the header\'s '
        'bottom however many lines the day has', (tester) async {
      await pump(
        tester,
        segment: piece,
        priority: matches,
        position: KioskDutyBandPosition.bottom,
      );
      expect(tester.getRect(strip).bottom, tester.getRect(header).bottom);
      expect(
        tester.getRect(strip).top,
        greaterThanOrEqualTo(tester.getRect(lines.last).bottom),
      );
      expect(
        tester.getRect(label).bottom,
        lessThanOrEqualTo(tester.getRect(lines.first).top),
      );
      final withLines = tester.getRect(strip);

      for (final priority in [<PrioritySlot>[], [matches.first]]) {
        await pump(
          tester,
          segment: piece,
          priority: priority,
          position: KioskDutyBandPosition.bottom,
        );
        expect(tester.getRect(strip), withLines, reason: '$priority');
      }
    });

    testWidgets('a day without a piece keeps its label on the banded days\' '
        'line wherever the band runs', (tester) async {
      for (final position in KioskDutyBandPosition.values) {
        await pump(
          tester,
          segment: piece,
          priority: matches,
          position: position,
        );
        final banded = tester.getRect(label);
        await pump(tester, priority: matches, position: position);
        expect(band, findsNothing, reason: '$position');
        expect(tester.getRect(label), banded, reason: '$position');
      }
    });

    testWidgets('the header is as tall wherever the band runs; through the gap '
        'to the column\'s edge in each place; the strip one height', (
      tester,
    ) async {
      final height = boardHeaderHeight(0) + boardBandHeight;
      double? stripHeight;
      for (final position in KioskDutyBandPosition.values) {
        await pump(
          tester,
          gap: 2,
          segment: const BoardBandSegment(starts: false, ends: false),
          priority: matches,
          position: position,
        );
        expect(tester.getSize(header).height, height, reason: '$position');
        expect(
          tester.getRect(strip).left,
          tester.getRect(header).left,
          reason: '$position',
        );
        expect(
          tester.getRect(strip).right,
          tester.getRect(header).right,
          reason: '$position',
        );
        stripHeight ??= tester.getRect(strip).height;
        expect(tester.getRect(strip).height, stripHeight, reason: '$position');
      }
    });

    testWidgets('the collapsed header hides it wherever it runs', (
      tester,
    ) async {
      for (final position in KioskDutyBandPosition.values) {
        await pump(
          tester,
          collapsed: true,
          segment: piece,
          position: position,
        );
        expect(
          tester.getSize(header).height,
          collapsedHeaderHeight,
          reason: '$position',
        );
        expect(band, findsNothing, reason: '$position');
        expect(label, findsOneWidget, reason: '$position');
        expect(
          tester.getRect(label).bottom,
          lessThanOrEqualTo(tester.getRect(header).bottom),
          reason: '$position',
        );
      }
    });
  });
}
