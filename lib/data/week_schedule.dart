/// The week as every board renders it, assembled once per Monday.
///
/// The app's week screen, the day pager's real pages and the kiosk board all
/// used to watch the same eight providers and call buildWeekSchedule
/// themselves; now they watch [weekScheduleProvider] for the Mondays they
/// show and get the [WeekSchedule] plus the name/colour maps in one value.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models.dart';
import '../domain/schedule.dart';
import 'clock.dart';
import 'providers.dart';

class WeekView {
  const WeekView({
    required this.week,
    required this.blocks,
    required this.blocksFromDb,
    required this.reservationsLoaded,
    required this.reservations,
    required this.nameById,
    required this.clubColorById,
    required this.today,
    required this.now,
  });

  final WeekSchedule week;

  /// The blocks the week was built from: the DB rows, or the hourly
  /// placeholder grid while the backend has none yet.
  final List<TimeBlock> blocks;

  /// False while the placeholder grid is shown — its ids are not UUIDs, so
  /// no cell may ever reach the RPC.
  final bool blocksFromDb;

  /// Whether this week's reservation stream has delivered a value. Booking
  /// against a stale/absent view of who holds a slot would race the RPC's
  /// own authoritative check, so cells stay inert until it has.
  final bool reservationsLoaded;

  /// The week's live reservations (Monday..Sunday).
  final List<Reservation> reservations;

  /// Board name per player id — the nick when set, else the display name.
  final Map<String, String> nameById;

  /// Palette index per player id (−1 = no club).
  final Map<String, int> clubColorById;

  final Day today;
  final HourMinute now;

  /// Cells may react to taps: real blocks and a loaded reservation picture.
  /// Callers add their own conditions (a signed-in profile, a selected
  /// kiosk player).
  bool get interactive => blocksFromDb && reservationsLoaded;
}

/// Loading and error follow [timeBlocksProvider] — the one stream a grid
/// cannot render without; every other input falls back to empty/defaults so
/// a late stream never blanks the board.
final weekScheduleProvider =
    Provider.autoDispose.family<AsyncValue<WeekView>, Day>((ref, monday) {
  final timeBlocks = ref.watch(timeBlocksProvider);
  if (timeBlocks.isLoading) return const AsyncLoading();
  if (timeBlocks.hasError) {
    return AsyncError(timeBlocks.error!, timeBlocks.stackTrace!);
  }

  final nowDt = ref.watch(nowProvider).value ?? DateTime.now();
  final today = Day.fromDateTime(nowDt);
  final now = HourMinute(nowDt.hour, nowDt.minute);
  final settings =
      ref.watch(settingsProvider).value ?? ScheduleSettings.defaults;
  final overrides = ref.watch(dayOverridesProvider).value ?? const [];
  final priority = ref.watch(prioritySlotsProvider);
  final rentals = ref.watch(rentalsProvider).value ?? const [];
  final weekReservations = ref.watch(weekReservationsProvider(monday));
  final players = ref.watch(playersProvider).value ?? const [];

  final dbBlocks = timeBlocks.value ?? const <TimeBlock>[];
  final blocksFromDb = dbBlocks.isNotEmpty;
  final blocks = blocksFromDb ? dbBlocks : defaultTimeBlocks();
  final reservations = weekReservations.value ?? const <Reservation>[];

  return AsyncData(WeekView(
    week: buildWeekSchedule(
      monday: monday,
      today: today,
      now: now,
      settings: settings,
      blocks: blocks,
      overrides: overrides,
      priority: priority,
      rentals: rentals,
      reservations: reservations,
    ),
    blocks: blocks,
    blocksFromDb: blocksFromDb,
    reservationsLoaded: weekReservations.hasValue,
    reservations: reservations,
    nameById: {
      for (final p in players)
        p.id: p.nick.isNotEmpty ? p.nick : p.displayName,
    },
    clubColorById: {for (final p in players) p.id: p.clubColor},
    today: today,
    now: now,
  ));
});
