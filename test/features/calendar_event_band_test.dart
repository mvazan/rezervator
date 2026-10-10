import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/widgets/emoji_text.dart';
import 'package:rezervator/features/schedule/widgets/calendar_board.dart';

import '../support/emoji_finders.dart';

void main() {
  const home = '🏆 SKK Veverky Brno C';
  const away = 'KK Orel Ivančice B';
  const time = '18:51–21:51';
  const oneLine = '🏆 SKK Veverky Brno C – KK Orel Ivančice B\n$time';

  /// The band in a box [width] × [height], as the board positions it.
  Widget band({required double width, required double height}) =>
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              height: height,
              child: const CalendarEventBand(
                background: Colors.red,
                foreground: Colors.white,
                text: oneLine,
                lines: [home, '–', away],
                time: time,
                bold: true,
              ),
            ),
          ),
        ),
      );

  testWidgets('a tall band: home, dash, away and the time each on a line of '
      'its own, in that order', (tester) async {
    await tester.pumpWidget(band(width: 160, height: 300));
    final rows = [findEmojiText(home), find.text('–'), find.text(away),
      find.text(time)];
    for (final row in rows) {
      expect(row, findsOneWidget);
    }
    for (var i = 1; i < rows.length; i++) {
      expect(
        tester.getTopLeft(rows[i]).dy,
        greaterThan(tester.getTopLeft(rows[i - 1]).dy),
      );
    }
    expect(findEmojiText(oneLine), findsNothing);
  });

  testWidgets('room to spare: a long name may wrap within its own line; '
      'just enough room: one line each, ellipsized', (tester) async {
    int? maxLinesOf(String text) => tester
        .widgetList<EmojiText>(find.byType(EmojiText))
        .firstWhere((t) => t.text == text)
        .maxLines;

    await tester.pumpWidget(band(width: 80, height: 300));
    expect(maxLinesOf(away), 2);
    expect(maxLinesOf(time), 1);

    // Four lines of 14 px and a little: the stack, one line a row.
    await tester.pumpWidget(band(width: 80, height: 60));
    expect(maxLinesOf(away), 1);
  });

  testWidgets('a band too short for the stack keeps the two-line label', (
    tester,
  ) async {
    await tester.pumpWidget(band(width: 160, height: 40));
    expect(findEmojiText(oneLine), findsOneWidget);
    expect(find.text('–'), findsNothing);
  });

  testWidgets('larger text needs a taller band before it stacks', (
    tester,
  ) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: band(width: 160, height: 60),
      ),
    );
    expect(findEmojiText(oneLine), findsOneWidget);
  });
}
