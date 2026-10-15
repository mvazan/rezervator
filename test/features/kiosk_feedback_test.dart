import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/theme.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/kiosk_layout.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/kiosk/kiosk_connection.dart';
import 'package:rezervator/features/kiosk/kiosk_feedback.dart';
import 'package:rezervator/features/kiosk/kiosk_info_panel.dart';
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

/// „Napište nám“ (module `feedback`): the card's fit on a Full HD kiosk —
/// the QR code of the web's form beside the text, under it, or left out
/// with the text sending a visitor to the tap — the dialog with the large
/// code, and the card in the shell's panel.
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
  // Version 3 and its quiet zone: 29 + 2 · 4 modules across the tile.
  const span = 37;

  /// The card as the panel lays it out: [days] columns wide, its [share]
  /// of the panel shared with one module more (100 = alone).
  Size cardSize({required int days, required int share}) => Size(
    days * column - 2 * pad,
    share == 100
        ? panelHeight - 2 * pad
        : (panelHeight - 2 * pad - pad) * share / 100,
  );

  void fullHd(WidgetTester tester) {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
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
              child: KioskFeedbackCard(onOpen: onOpen ?? () {}),
            ),
          ),
        ),
      ),
    );
  }

  final qr = find.byType(KioskQr);
  final withQr = find.text(kioskFeedbackText);
  final tapHint = find.text(kioskFeedbackTextTap);

  group('KioskFeedbackCard', () {
    testWidgets('2 of 8 days at its default 35 %: the form\'s code beside the '
        'text', (tester) async {
      fullHd(tester);
      await pumpCard(
        tester,
        cardSize(days: 2, share: kioskModuleDefaultShare(KioskModule.feedback)),
      );
      expect(find.text('NAPIŠTE NÁM'), findsOneWidget);
      expect(find.text(kioskFeedbackTitle), findsOneWidget);
      expect(qr, findsOneWidget);
      expect(tester.widget<KioskQr>(qr).rows, kioskFeedbackQr);
      expect(withQr, findsOneWidget);
      expect(tapHint, findsNothing);
      final code = tester.getRect(qr);
      final text = tester.getRect(withQr);
      expect(code.width, greaterThanOrEqualTo(120));
      expect(code.left, greaterThan(text.right));
      // Whole device pixels a module, the quiet zone included.
      expect(code.width % span, 0);
    });

    testWidgets('15 %: no room for the code — the text sends a visitor to '
        'the tap, cut rather than overflowing', (tester) async {
      fullHd(tester);
      await pumpCard(tester, cardSize(days: 2, share: 15));
      expect(qr, findsNothing);
      expect(withQr, findsNothing);
      expect(tapHint, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('one narrow day alone: the code under the text', (
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

    testWidgets('a tap anywhere on the card opens the code', (tester) async {
      fullHd(tester);
      var opened = 0;
      await pumpCard(
        tester,
        cardSize(days: 2, share: 35),
        onOpen: () => opened++,
      );
      await tester.tap(find.text('NAPIŠTE NÁM'));
      await tester.tap(qr);
      expect(opened, 2);
    });
  });

  group('showKioskFeedback', () {
    testWidgets('the text and the code at 300 px, in the theme [wrap] gives '
        'it; „Zavřít“ closes it', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showKioskFeedback(
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
      expect(find.text('Napište nám'), findsOneWidget);
      expect(find.text(kioskFeedbackTitle), findsOneWidget);
      expect(withQr, findsOneWidget);
      // 300 px of room: 8 px a module.
      expect(tester.getSize(qr), const Size(8.0 * span, 8.0 * span));
      expect(Theme.of(tester.element(dialog)).brightness, Brightness.dark);

      await tester.tap(find.text('Zavřít'));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
    });
  });

  testWidgets('the shell: Napište nám alone in the left panel, a tap opens '
      'its code in the kiosk\'s theme, the idle reset closes it', (
    tester,
  ) async {
    fullHd(tester);
    final panels = KioskPanels.defaults
        .withSide(KioskModule.notices, PanelSide.off)
        .withSide(KioskModule.matches, PanelSide.off)
        .withSide(KioskModule.feedback, PanelSide.left)
        .withPanel(PanelSide.left, open: true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(
            (ref) => Stream.value(
              ScheduleSettings(
                laneCount: 2,
                trainingWeekdays: const {1, 2, 3, 4, 5, 6, 7},
                bookingHorizonDays: 14,
                maxActiveReservations: 3,
                kioskVisibleDays: 8,
                kioskPanels: panels,
              ),
            ),
          ),
          nowProvider.overrideWith(
            (ref) => Stream.value(DateTime(2026, 10, 8, 12)),
          ),
          timeBlocksProvider.overrideWith((ref) => Stream.value(const [])),
          dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
          prioritySlotsProvider.overrideWithValue(const []),
          rentalsProvider.overrideWith((ref) => Stream.value(const [])),
          weekReservationsProvider.overrideWith(
            (ref, monday) => Stream.value(const []),
          ),
          playersProvider.overrideWith((ref) async => const []),
          messagesProvider.overrideWith((ref) => Stream.value(const [])),
          kioskSocketOpenProvider.overrideWithValue(() => true),
          matchResultsProvider.overrideWith((ref) => Stream.value(const {})),
          matchPlayerResultsProvider.overrideWith(
            (ref, id) => Stream.value(const []),
          ),
          dutyPeriodsProvider.overrideWith((ref) => Stream.value(const [])),
          dutyAssignmentsProvider.overrideWith((ref) => Stream.value(const [])),
        ],
        // The app's light theme around the kiosk's dark one: the dialog is
        // dark only through the shell's wrap.
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const KioskShell(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(KioskPanelView)).width, 2 * column);
    final card = find.byType(KioskFeedbackCard);
    expect(card, findsOneWidget);
    expect(qr, findsOneWidget);

    await tester.tap(card);
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(find.byType(KioskFeedbackDialog), findsOneWidget);
    expect(Theme.of(tester.element(dialog)).brightness, Brightness.dark);

    // A minute without a touch: the kiosk starts over, the dialog shut.
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
