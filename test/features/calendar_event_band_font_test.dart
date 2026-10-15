import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/text_size.dart';
import 'package:rezervator/core/theme.dart';
import 'package:rezervator/domain/labels.dart' show BandLine, bandGap;
import 'package:rezervator/features/schedule/widgets/calendar_board.dart';

/// The app's own font: the test font's lines are not Manrope's, and a line
/// of the band is what decides how many fit.
Future<void> _loadManrope() async {
  final loader = FontLoader(appFontFamily);
  for (final weight in ['Regular', 'Medium', 'Bold', 'ExtraBold']) {
    final bytes = File('assets/fonts/Manrope-$weight.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

/// A match band stacks its lines only when every one of them fits: with the
/// app's font and theme, at any text size and any of the kiosk's band fonts
/// (0069), in any height, the stack never runs past the band — the away
/// team at its bottom is not cut off.
void main() {
  setUpAll(_loadManrope);

  const home = 'SKK Veverky Brno C';
  const away = 'KK Orel Ivančice B';
  const time = '18:51–21:51';
  const lines = <BandLine>[
    (text: '🏆 $time', wraps: true),
    bandGap,
    (text: home, wraps: true),
    (text: 'x', wraps: false),
    (text: away, wraps: true),
  ];

  for (final (fontSize, choice, width, where) in [
    (10.0, TextSizeChoice.largest, 40.0, 'the phone\'s week, „Největší“'),
    (10.0, TextSizeChoice.large, 40.0, 'the phone\'s week, „Velký“'),
    (10.0, TextSizeChoice.normal, 40.0, 'the phone\'s week'),
    (12.0, TextSizeChoice.normal, 60.0, 'the kiosk, 12 px'),
    (14.0, TextSizeChoice.normal, 60.0, 'the kiosk, 14 px'),
    (14.0, TextSizeChoice.normal, 200.0, 'the kiosk, 14 px, wide'),
    (20.0, TextSizeChoice.normal, 120.0, 'the kiosk, 20 px'),
  ]) {
    testWidgets('$where: no band height overflows its stack', (tester) async {
      final overflows = <double>[];
      for (var height = 40.0; height <= 400; height++) {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.light),
            // As main.dart applies the Settings text size.
            builder: (context, child) {
              final mq = MediaQuery.of(context);
              return MediaQuery(
                data: mq.copyWith(
                  textScaler: AppTextScaler(mq.textScaler, choice),
                ),
                child: child!,
              );
            },
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  // A fresh band each height: a RenderFlex reports its
                  // overflow only once.
                  key: ValueKey(height),
                  width: width,
                  height: height,
                  child: CalendarEventBand(
                    background: Colors.red,
                    foreground: Colors.white,
                    text: '🏆 $home – $away\n$time',
                    lines: lines,
                    bold: true,
                    fontSize: fontSize,
                  ),
                ),
              ),
            ),
          ),
        );
        if (tester.takeException() != null) overflows.add(height);
      }
      expect(overflows, isEmpty);
    });
  }
}
