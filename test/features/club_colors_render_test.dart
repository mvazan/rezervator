import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/theme.dart';
import 'package:rezervator/core/ui.dart' show today;
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/palette.dart';
import 'package:rezervator/features/kiosk/kiosk_board_view.dart';
import 'package:rezervator/features/kiosk/kiosk_shell.dart';
import 'package:rezervator/features/schedule/week_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Task 4 — club colours render on the kiosk board and the app grid, and the
/// kiosk theme follows the admin `kiosk_dark` setting (spec §4, §5).
void main() {
  const b1 = TimeBlock(
    id: 'b1',
    startsAt: HourMinute(22, 58),
    endsAt: HourMinute(23, 59),
    position: 0,
    active: true,
  );

  ScheduleSettings settings({bool kioskDark = true}) => ScheduleSettings(
    laneCount: 2,
    trainingWeekdays: const {1, 2, 3, 4, 5, 6, 7},
    bookingHorizonDays: 14,
    maxActiveReservations: 3,
    kioskDark: kioskDark,
  );

  final t = today();

  Reservation res(String id, String playerId, {int lane = 1}) => Reservation(
    id: id,
    playerId: playerId,
    date: t,
    blockId: 'b1',
    lane: lane,
    createdVia: 'app',
    createdAt: DateTime.utc(2026, 1, 1),
  );

  /// Nearest Container ancestor of [text] that paints a solid background — the
  /// row/cell shell whose colour the club tint sets.
  Color? bgOf(WidgetTester tester, Finder text) {
    final container = tester
        .widgetList<Container>(find.ancestor(of: text, matching: find.byType(Container)))
        .firstWhere((c) {
          final d = c.decoration;
          return d is BoxDecoration && d.color != null;
        });
    return (container.decoration as BoxDecoration).color;
  }

  group('kiosk board', () {
    Widget kioskApp({
      required List<PlayerName> roster,
      required List<Reservation> reservations,
      List<Rental> rentals = const [],
      bool kioskDark = true,
    }) {
      return ProviderScope(
        overrides: [
          settingsProvider.overrideWith(
            (ref) => Stream.value(settings(kioskDark: kioskDark)),
          ),
          timeBlocksProvider.overrideWith((ref) => Stream.value(const [b1])),
          dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
          prioritySlotsProvider.overrideWithValue(const []),
          rentalsProvider.overrideWith((ref) => Stream.value(rentals)),
          weekReservationsProvider.overrideWith(
            (ref, monday) => Stream.value(reservations),
          ),
          playersProvider.overrideWith((ref) async => roster),
        ],
        // Pin the ambient app theme to light so a dark kiosk can only be
        // credited to KioskShell's own theme, not the harness default.
        child: MaterialApp(theme: buildTheme(Brightness.light), home: const KioskShell()),
      );
    }

    // KioskShell's idle/clock timers must be torn down before the test ends.
    Future<void> finish(WidgetTester tester) =>
        tester.pumpWidget(const SizedBox.shrink());

    testWidgets('a foreign reservation is tinted with its club colour (dark)', (
      tester,
    ) async {
      const other = PlayerName(
        id: 'other',
        displayName: 'Petr Novák',
        club: 'Modří',
        clubColor: 0, // Modrá
      );
      await tester.pumpWidget(
        kioskApp(roster: [other], reservations: [res('r1', other.id)]),
      );
      await tester.pumpAndSettle();

      expect(
        Theme.of(tester.element(find.byType(KioskBoardView))).brightness,
        Brightness.dark,
      );
      expect(
        bgOf(tester, find.text('Petr Novák')),
        ClubColors.of(0, Brightness.dark)!.$1,
      );

      await finish(tester);
    });

    testWidgets('a foreign reservation is tinted with its club colour (light)', (
      tester,
    ) async {
      const other = PlayerName(
        id: 'other',
        displayName: 'Petr Novák',
        club: 'Zelení',
        clubColor: 1, // Zelená
      );
      await tester.pumpWidget(
        kioskApp(
          roster: [other],
          reservations: [res('r1', other.id)],
          kioskDark: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        Theme.of(tester.element(find.byType(KioskBoardView))).brightness,
        Brightness.light,
      );
      expect(
        bgOf(tester, find.text('Petr Novák')),
        ClubColors.of(1, Brightness.light)!.$1,
      );

      await finish(tester);
    });

    testWidgets('a club-less foreign reservation keeps the neutral tint', (
      tester,
    ) async {
      const other = PlayerName(
        id: 'other',
        displayName: 'Petr Novák',
        club: '',
      ); // clubColor defaults to -1
      await tester.pumpWidget(
        kioskApp(roster: [other], reservations: [res('r1', other.id)]),
      );
      await tester.pumpAndSettle();

      final scheme =
          Theme.of(tester.element(find.byType(KioskBoardView))).colorScheme;
      // -1 → ClubColors.of returns null → the pre-existing neutral surface.
      expect(
        bgOf(tester, find.text('Petr Novák')),
        scheme.surfaceContainerHighest.withValues(alpha: 0.6),
      );

      await finish(tester);
    });

    testWidgets('the kiosk theme follows the kiosk_dark setting', (
      tester,
    ) async {
      await tester.pumpWidget(
        kioskApp(roster: const [], reservations: const [], kioskDark: false),
      );
      await tester.pumpAndSettle();

      expect(
        Theme.of(tester.element(find.byType(KioskBoardView))).brightness,
        Brightness.light,
      );

      await finish(tester);
    });
  });

  group('app grid', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    const me = Profile(
      id: 'me',
      displayName: 'Já Hráč',
      club: '',
      email: 'me@example.com',
      role: Role.player,
      status: ProfileStatus.approved,
    );

    Widget app({
      required List<PlayerName> roster,
      List<Reservation> reservations = const [],
      List<Rental> rentals = const [],
    }) {
      return ProviderScope(
        overrides: [
          settingsProvider.overrideWith((ref) => Stream.value(settings())),
          timeBlocksProvider.overrideWith((ref) => Stream.value(const [b1])),
          dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
          prioritySlotsProvider.overrideWithValue(const []),
          rentalsProvider.overrideWith((ref) => Stream.value(rentals)),
          weekReservationsProvider.overrideWith(
            (ref, monday) => Stream.value(reservations),
          ),
          myActiveReservationsProvider.overrideWith(
            (ref) => Stream.value(reservations),
          ),
          myProfileProvider.overrideWith((ref) => Stream.value(me)),
          playersProvider.overrideWith((ref) async => roster),
        ],
        // Pin light so the expected ClubColors brightness is deterministic.
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const Scaffold(body: WeekScreen()),
        ),
      );
    }

    testWidgets('a foreign reservation cell is tinted by the club colour', (
      tester,
    ) async {
      const other = PlayerName(
        id: 'p2',
        displayName: 'Petr Novák',
        club: 'Červení',
        clubColor: 2, // Červená
      );
      await tester.pumpWidget(
        app(roster: [other], reservations: [res('r2', 'p2')]),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Petr Novák').first);
      await tester.pumpAndSettle();

      expect(
        bgOf(tester, find.text('Petr Novák').first),
        ClubColors.of(2, Brightness.light)!.$1,
      );
    });

    testWidgets('a rental cell uses its own palette colour', (tester) async {
      final rental = Rental(
        id: 'rent1',
        renterName: 'Firma s.r.o.',
        lanes: const [1, 2],
        date: t,
        weekday: null,
        startsAt: const HourMinute(22, 58),
        endsAt: const HourMinute(23, 59),
        validFrom: null,
        validUntil: null,
        note: '',
        color: 3, // Oranžová
      );
      await tester.pumpWidget(app(roster: const [], rentals: [rental]));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Firma s.r.o.').first);
      await tester.pumpAndSettle();

      expect(
        bgOf(tester, find.text('Firma s.r.o.').first),
        ClubColors.of(3, Brightness.light)!.$1,
      );
    });
  });
}
