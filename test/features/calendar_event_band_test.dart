import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/widgets/emoji_text.dart';
import 'package:rezervator/domain/labels.dart' show BandLine;
import 'package:rezervator/features/schedule/widgets/calendar_board.dart';

import '../support/emoji_finders.dart';

void main() {
  const home = 'SKK Veverky Brno C';
  const away = 'KK Orel Ivančice B';
  const time = '18:51–21:51';
  const oneLine = '🏆 SKK Veverky Brno C – KK Orel Ivančice B\n$time';
  const lines = <BandLine>[
    (text: '🏆', wraps: false),
    (text: home, wraps: true),
    (text: '–', wraps: false),
    (text: away, wraps: true),
  ];

  /// The band in a box [width] × [height], as the board positions it.
  Widget band({
    required double width,
    required double height,
    double fontSize = 10,
  }) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          height: height,
          child: CalendarEventBand(
            background: Colors.red,
            foreground: Colors.white,
            text: oneLine,
            lines: lines,
            time: time,
            bold: true,
            fontSize: fontSize,
          ),
        ),
      ),
    ),
  );

  int? maxLinesOf(WidgetTester tester, String text) => tester
      .widgetList<EmojiText>(find.byType(EmojiText))
      .firstWhere((t) => t.text == text)
      .maxLines;

  testWidgets('a tall band: the cup, home, dash, away and the time each on '
      'a line of its own, in that order', (tester) async {
    await tester.pumpWidget(band(width: 160, height: 300));
    final rows = [
      findEmojiText('🏆'),
      find.text(home),
      find.text('–'),
      find.text(away),
      find.text(time),
    ];
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

  testWidgets('the lines to spare go to the names: a long name may take '
      'several; the cup, the dash and the time keep to one', (tester) async {
    // 300 px of 14 px lines: 21; five rows leave 16, eight more a name.
    await tester.pumpWidget(band(width: 60, height: 300));
    expect(maxLinesOf(tester, home), 9);
    expect(maxLinesOf(tester, away), 9);
    expect(maxLinesOf(tester, '🏆'), 1);
    expect(maxLinesOf(tester, time), 1);
    // The narrow column wraps the name instead of cutting it.
    expect(tester.getSize(find.text(home)).height, greaterThan(20));

    // Five lines and a little: the stack, one line a row.
    await tester.pumpWidget(band(width: 60, height: 75));
    expect(maxLinesOf(tester, home), 1);
  });

  testWidgets('a band too short for the stack keeps the two-line label', (
    tester,
  ) async {
    await tester.pumpWidget(band(width: 160, height: 60));
    expect(findEmojiText(oneLine), findsOneWidget);
    expect(find.text('–'), findsNothing);
  });

  testWidgets('a larger font: bigger text, and a taller band before it '
      'stacks', (tester) async {
    await tester.pumpWidget(band(width: 300, height: 300, fontSize: 18));
    expect(tester.widget<Text>(find.text(away)).style?.fontSize, 18);

    // 18 px lines are about 25 px: 100 px holds four, not five.
    await tester.pumpWidget(band(width: 300, height: 100, fontSize: 18));
    expect(findEmojiText(oneLine), findsOneWidget);
  });

  testWidgets('larger text needs a taller band before it stacks', (
    tester,
  ) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: band(width: 160, height: 100),
      ),
    );
    expect(findEmojiText(oneLine), findsOneWidget);
  });
}
