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
import 'package:rezervator/features/kiosk/kiosk_guide.dart';
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

  group('in the panels', () {
    Message notice() => Message(
      id: 'n1',
      kind: MessageKind.notice,
      audience: MessageAudience.all,
      authorId: 'a',
      authorRole: MessageAuthorRole.admin,
      onDate: null,
      blockId: null,
      title: 'Brigáda',
      body: 'Sejdeme se v devět.',
      expiresAt: null,
      notify: true,
      showOnKiosk: true,
      createdAt: DateTime(2026, 9, 1),
      updatedAt: DateTime(2026, 9, 1),
    );

    testWidgets('KioskPanelView: the guide takes its share and opens on a '
        'tap', (tester) async {
      fullHd(tester);
      var opened = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(
              (ref) => Stream.value(
                const ScheduleSettings(
                  laneCount: 2,
                  trainingWeekdays: {1, 2, 3, 4, 5, 6, 7},
                  bookingHorizonDays: 14,
                  maxActiveReservations: 3,
                ),
              ),
            ),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.dark),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  height: panelHeight,
                  child: KioskPanelView(
                    side: PanelSide.left,
                    width: 2 * column,
                    open: true,
                    content: KioskPanelContent(
                      side: PanelSide.left,
                      entries: const [
                        KioskPanelEntry(KioskModule.guide, 45),
                        KioskPanelEntry(KioskModule.notices, 55),
                      ],
                      notices: [notice()],
                    ),
                    onOpenNotice: (_) {},
                    onOpenMatch: (_) {},
                    onOpenGuide: () => opened++,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final card = find.byType(KioskGuideCard);
      final want = cardSize(days: 2, share: 45);
      expect(tester.getSize(card).width, closeTo(want.width, 1e-6));
      expect(tester.getSize(card).height, closeTo(want.height, 1e-6));
      expect(qr, findsOneWidget);
      await tester.tap(card);
      expect(opened, 1);
      // The notices' turn timer goes with the tree.
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the shell: the guide in the left panel beside a notice, a '
        'tap opens it in the kiosk\'s theme, the idle reset closes it', (
      tester,
    ) async {
      fullHd(tester);
      const panels = KioskPanels(
        left: KioskPanel(days: 2, open: true),
        right: KioskPanel(days: 2, open: false),
        modules: [
          KioskModulePlacement(id: 'duty', side: PanelSide.off, share: 30),
          KioskModulePlacement(id: 'guide', side: PanelSide.left, share: 45),
          KioskModulePlacement(id: 'notices', side: PanelSide.left, share: 55),
          KioskModulePlacement(id: 'matches', side: PanelSide.off, share: 60),
          KioskModulePlacement(id: 'week', side: PanelSide.off, share: 55),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(
              (ref) => Stream.value(
                const ScheduleSettings(
                  laneCount: 2,
                  trainingWeekdays: {1, 2, 3, 4, 5, 6, 7},
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
            messagesProvider.overrideWith((ref) => Stream.value([notice()])),
            kioskSocketOpenProvider.overrideWithValue(() => true),
            matchResultsProvider.overrideWith((ref) => Stream.value(const {})),
            matchPlayerResultsProvider.overrideWith(
              (ref, id) => Stream.value(const []),
            ),
            dutyPeriodsProvider.overrideWith((ref) => Stream.value(const [])),
            dutyAssignmentsProvider.overrideWith(
              (ref) => Stream.value(const []),
            ),
          ],
          // The app's light theme around the kiosk's dark one: the dialog
          // is dark only through the shell's wrap.
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: const KioskShell(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final panel = tester.getSize(find.byType(KioskPanelView));
      expect(panel.width, 2 * column);
      final card = find.byType(KioskGuideCard);
      expect(
        tester.getSize(card).height,
        closeTo((panel.height - 3 * pad) * 0.45, 1e-6),
      );
      expect(qr, findsOneWidget);

      await tester.tap(card);
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget);
      expect(Theme.of(tester.element(dialog)).brightness, Brightness.dark);

      // A minute without a touch: the kiosk starts over, the guide shut.
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
