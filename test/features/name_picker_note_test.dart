import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/theme.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/kiosk/kiosk_warning.dart';
import 'package:rezervator/features/kiosk/name_picker.dart';

/// The app's own font: the test font's glyphs are wider than Manrope's, so
/// line counts measured against it would not be the kiosk's.
Future<void> _loadManrope() async {
  final loader = FontLoader(appFontFamily);
  for (final weight in ['Regular', 'Medium', 'Bold', 'ExtraBold']) {
    final bytes = File('assets/fonts/Manrope-$weight.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

/// The admin's booking note above the first letters (0070) is read to its
/// end — the end says where to cancel — on the kiosk and on narrower
/// screens alike, never cut by an ellipsis.
void main() {
  setUpAll(_loadManrope);

  final players = [
    for (var i = 0; i < 26; i++)
      PlayerName(
        id: 'p$i',
        displayName:
            '${String.fromCharCode(65 + i)}${String.fromCharCode(65 + i)} Hráč',
      ),
  ];

  Future<void> pump(WidgetTester tester, Size size, String note) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(
            (ref) => Stream.value(
              ScheduleSettings(
                laneCount: 4,
                trainingWeekdays: const {1, 2, 4},
                bookingHorizonDays: 14,
                maxActiveReservations: 3,
                kioskPickerNote: note,
              ),
            ),
          ),
          playersProvider.overrideWith((ref) async => players),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: const NamePicker(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool cut(WidgetTester tester, String note) => tester
      .renderObject<RenderParagraph>(
        find.descendant(of: find.text(note), matching: find.byType(RichText)),
      )
      .didExceedMaxLines;

  final longest = 'Na kiosku se z tréninku odhlásit nedá. ' * 6;
  final note200 = longest.substring(0, 200).trim();

  for (final (size, note, what) in [
    (const Size(1920, 1080), ScheduleSettings.defaultPickerNote, 'default'),
    (const Size(1920, 1080), note200, '200 characters'),
    (const Size(800, 1280), note200, '200 characters'),
    (const Size(375, 812), ScheduleSettings.defaultPickerNote, 'default'),
  ]) {
    testWidgets('the $what note is whole at ${size.width.toInt()} × '
        '${size.height.toInt()}', (tester) async {
      await pump(tester, size, note);
      expect(find.byType(KioskWarning), findsOneWidget);
      expect(cut(tester, note), isFalse);
      expect(tester.takeException(), isNull);
    });
  }
}
