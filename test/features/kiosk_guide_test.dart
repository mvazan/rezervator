import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/theme.dart';
import 'package:rezervator/features/kiosk/kiosk_guide.dart';
import 'package:rezervator/features/kiosk/kiosk_qr.dart';
import 'package:rezervator/features/kiosk/kiosk_shell.dart';
import 'package:rezervator/features/schedule/widgets/calendar_board.dart'
    show calendarRulerWidth;

/// The app's own font: the test font's glyphs are wider than Manrope's, so
/// a fit measured against it would not be the kiosk's.
Future<void> _loadManrope() async {
  final loader = FontLoader(appFontFamily);
  for (final weight in ['Regular', 'Medium', 'Bold', 'ExtraBold']) {
    final bytes = File('assets/fonts/Manrope-$weight.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

/// „Jak začít“ (module `guide`, 0077): the card's fit on a Full HD kiosk —
/// the QR code beside the second paragraph, under it, or left out with the
/// text sending a visitor to the tap — the dialog with the whole text and
/// the large code, and the card in a panel and in the shell.
void main() {
  setUpAll(_loadManrope);

  // One day column of a Full HD kiosk with 8 days on the screen; a panel
  // is whole columns of it (kioskPanelWidths).
  const column = (1920 - calendarRulerWidth) / 8;
  // The shell's panel at 1080: the status bar (96) and the idle bar (3)
  // take the rest.
  const panelHeight = 981.0;
  // A panel's padding (12 around) and the gap between two modules.
  const pad = 12.0;

  /// The guide's card as the panel lays it out: [days] columns wide, its
  /// [share] of the panel shared with one module more (100 = alone).
  Size cardSize({required int days, required int share}) => Size(
    days * column - 2 * pad,
    share == 100
        ? panelHeight - 2 * pad
        : (panelHeight - 2 * pad - pad) * share / 100,
  );

  void fullHd(WidgetTester tester, {double dpr = 1}) {
    tester.view.physicalSize = const Size(1920, 1080) * dpr;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpCard(
    WidgetTester tester,
    Size size, {
    VoidCallback? onOpen,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox.fromSize(
              size: size,
              child: KioskGuideCard(onOpen: onOpen ?? () {}),
            ),
          ),
        ),
      ),
    );
  }

  final qr = find.byType(KioskQr);
  final withQr = find.text(kioskGuideMobile);
  final tapHint = find.text(kioskGuideMobileTap);
  final more = find.text('Více');

  group('KioskGuideCard', () {
    test('the first step names the kiosk\'s button as it reads', () {
      expect(kioskGuideSteps.first, contains('„$kioskReserveLabel“'));
    });

    testWidgets('2 of 8 days at 45 %: the QR code beside the second '
        'paragraph, the text whole', (tester) async {
      fullHd(tester);
      await pumpCard(tester, cardSize(days: 2, share: 45));
      expect(qr, findsOneWidget);
      expect(withQr, findsOneWidget);
      expect(tapHint, findsNothing);
      expect(more, findsNothing);
      final code = tester.getRect(qr);
      final text = tester.getRect(withQr);
      expect(code.width, greaterThanOrEqualTo(120));
      // Beside: right of the text, the text column at least 200 wide.
      expect(code.left, greaterThan(text.right));
      expect(text.width, greaterThanOrEqualTo(200));
      // Whole device pixels a module: 41 of them, quiet zone included.
      expect(code.width % 41, 0);
    });

    testWidgets('at 1.5 device pixels to one the tile is still whole device '
        'pixels a module', (tester) async {
      fullHd(tester, dpr: 1.5);
      await pumpCard(tester, cardSize(days: 2, share: 45));
      final device = tester.getSize(qr).width * 1.5;
      expect(device, closeTo(device.roundToDouble(), 1e-6));
      expect(device.round() % 41, 0);
    });

    testWidgets('35 %: no room for the code — the text sends a visitor to '
        'the tap, whole', (tester) async {
      fullHd(tester);
      await pumpCard(tester, cardSize(days: 2, share: 35));
      expect(qr, findsNothing);
      expect(withQr, findsNothing);
      expect(tapHint, findsOneWidget);
      expect(more, findsNothing);
    });

    testWidgets('30 %: the text itself is cut, faded, with „Více“', (
      tester,
    ) async {
      fullHd(tester);
      await pumpCard(tester, cardSize(days: 2, share: 30));
      expect(qr, findsNothing);
      expect(tapHint, findsOneWidget);
      expect(more, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('one narrow day alone: the code under the paragraph', (
      tester,
    ) async {
      fullHd(tester);
      await pumpCard(tester, cardSize(days: 1, share: 100));
      expect(qr, findsOneWidget);
      expect(withQr, findsOneWidget);
      expect(
        tester.getRect(qr).top,
        greaterThan(tester.getRect(withQr).bottom),
      );
      expect(tester.getSize(qr).width, greaterThanOrEqualTo(120));
    });

    testWidgets('a tap anywhere on the card opens the guide', (tester) async {
      fullHd(tester);
      var opened = 0;
      await pumpCard(
        tester,
        cardSize(days: 2, share: 30),
        onOpen: () => opened++,
      );
      await tester.tap(find.text('JAK ZAČÍT'));
      await tester.tap(more);
      expect(opened, 2);
    });
  });

  group('showKioskGuide', () {
    testWidgets('the whole text, the code at 300 px, in the theme [wrap] '
        'gives it; „Zavřít“ closes it', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showKioskGuide(
                  context,
                  wrap: (child) =>
                      Theme(data: buildTheme(Brightness.dark), child: child),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final dialog = find.byType(AlertDialog);
      expect(find.text('Jak začít'), findsOneWidget);
      expect(find.text(kioskGuideStepsTitle), findsOneWidget);
      for (final (i, step) in kioskGuideSteps.indexed) {
        expect(find.text('${i + 1}. $step'), findsOneWidget);
      }
      expect(find.text(kioskGuideMobileTitle), findsOneWidget);
      expect(withQr, findsOneWidget);
      // 300 px of room: 7 px a module.
      expect(tester.getSize(qr), const Size(287, 287));
      expect(
        Theme.of(tester.element(dialog)).brightness,
        Brightness.dark,
      );

      await tester.tap(find.text('Zavřít'));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
    });
  });
}
