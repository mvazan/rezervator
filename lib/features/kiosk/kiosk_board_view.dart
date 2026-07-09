/// Kiosk "board": landscape days-as-columns view replacing the old vertical
/// week list. Columns run from `today` (first, highlighted DNES) forward
/// through `booking_horizon_days`, all equally wide.
///
/// Absolute 30-min axis (spec 2026-07-09): the left rail is a regular grid of
/// 30-minute slots covering `min(all block starts)..max(all block ends)` across
/// EVERY visible day (default blocks + shifted override blocks), floored/ceiled
/// to :00/:30 boundaries. Every block — standard or shifted — is placed at its
/// TRUE time: a block starting at T has the same slot offset (hence the same
/// y-coordinate) in every column and against the rail, so shifted days line up
/// vertically with the times on the rail. A shifted day still gets a ⚡ header
/// marker and per-cell time labels (a small aid since its times differ from the
/// clean default columns); standard days read their time from the rail.
///
/// Display-only until a player is selected — then free lane rows book for
/// THAT player. No cancel affordance anywhere (kiosk performs exactly one
/// action type).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/palette.dart';
import '../../domain/schedule.dart';
import 'board_layout.dart';

/// True when [date] resolves as an [OpenDay] under exactly the resolution the
/// board renders with (buildWeekSchedule): closed overrides and non-training
/// weekdays are closed, and an override's blockIds are filtered against the
/// real block set — an override whose ids no longer resolve to any existing
/// block is a ClosedDay, not open. Matches/rentals/reservations never affect
/// open-vs-closed status (only which slots within an open day are free), so
/// they're passed empty.
///
/// This is the ONLY day-type probe outside the grid itself — the status bar
/// and [nextTrainingDay] both go through it, so they can never disagree with
/// what the board shows.
bool isDayOpen({
  required Day date,
  required Day today,
  required ScheduleSettings settings,
  required List<TimeBlock> blocks,
  required List<DayOverride> overrides,
}) {
  final week = buildWeekSchedule(
    monday: date.addDays(1 - date.weekday),
    today: today,
    now: const HourMinute(0, 0),
    settings: settings,
    blocks: blocks,
    overrides: overrides,
    matches: const [],
    rentals: const [],
    reservations: const [],
  );
  // WeekSchedule.days is contractually Monday..Sunday, so [weekday - 1] is
  // exactly [date]'s entry.
  return week.days[date.weekday - 1] is OpenDay;
}

/// Scans forward from [today] (exclusive) up to [horizonDays] and returns the
/// first date that resolves open per [isDayOpen] — the "Další trénink" the
/// kiosk status bar shows on days without training.
Day? nextTrainingDay({
  required Day today,
  required ScheduleSettings settings,
  required List<TimeBlock> blocks,
  required List<DayOverride> overrides,
  required int horizonDays,
}) {
  for (var offset = 1; offset <= horizonDays; offset++) {
    final date = today.addDays(offset);
    if (isDayOpen(
      date: date,
      today: today,
      settings: settings,
      blocks: blocks,
      overrides: overrides,
    )) {
      return date;
    }
  }
  return null;
}

/// Equal column width per spec §1: `clamp(160, (width−rail)/7, 220)` so a
/// typical tablet shows exactly 7 days without horizontal scroll.
double boardColumnWidth(double availableWidth) =>
    ((availableWidth - _railWidth) / 7).clamp(160.0, 220.0);

const _railWidth = 64.0;
const _headerHeight = 56.0;

/// Sort blocks by start time, breaking ties by [TimeBlock.position] — mirrors
/// `schedule.dart`'s private `_byStartThenPosition` so the board's row rail
/// orders identically to how each day's own blocks are ordered.
int _byStartThenPosition(TimeBlock a, TimeBlock b) {
  final byStart =
      a.startsAt.minutesFromMidnight.compareTo(b.startsAt.minutesFromMidnight);
  return byStart != 0 ? byStart : a.position.compareTo(b.position);
}

/// True when [day]'s resolved block set differs from the default active
/// (swimline) set — i.e. the day carries an override that shifted or replaced
/// its times, so it must render as its own continuous own-times column rather
/// than into the shared swimline grid (spec §2). Compares block-id SETS, not
/// order: a standard day (override absent, or an override whose block_ids
/// resolve back to exactly the default set) has the same set → false. A
/// [ClosedDay] is never "shifted" (it renders the ✕ column regardless).
bool isShiftedDay(OpenDay day, List<TimeBlock> defaultActive) {
  final dayIds = {for (final b in day.blocks) b.id};
  final defaultIds = {for (final b in defaultActive) b.id};
  return dayIds.length != defaultIds.length ||
      !dayIds.containsAll(defaultIds);
}

/// Faint horizontal divider between time-slot row-groups, shared by [_Rail]
/// and [_DayColumn] so the lines land on the same y-offset in both (spec:
/// subtle time-slot gridlines, no vertical/lane dividers). `null` after the
/// last block — nothing to separate it from below.
Border? _gridlineBorder(ColorScheme scheme, {required bool isLast}) {
  if (isLast) return null;
  return Border(
    bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.25)),
  );
}

/// Column-snap scroll physics for the board's horizontal `ListView` (spec
/// §1: "horizontálnym scrollom (snap po stĺpcoch)"). A plain [PageView]
/// can't be used instead because its `viewportFraction` — the mechanism
/// that would let multiple [columnWidth]-wide columns share one viewport —
/// is fixed at [PageController] construction time, before the
/// [LayoutBuilder] that computes [columnWidth] from the available width
/// ever runs. This mirrors [PageScrollPhysics]'s own
/// `createBallisticSimulation` (see `package:flutter/src/widgets/page_view
/// .dart`), substituting `pixels / columnWidth` for its `pixels /
/// viewportDimension` "page" unit so a fling settles on the nearest column
/// boundary instead of the nearest full viewport.
class _ColumnSnapPhysics extends ScrollPhysics {
  const _ColumnSnapPhysics({required this.columnWidth, super.parent});

  final double columnWidth;

  @override
  _ColumnSnapPhysics applyTo(ScrollPhysics? ancestor) =>
      _ColumnSnapPhysics(columnWidth: columnWidth, parent: buildParent(ancestor));

  double _targetPixels(ScrollMetrics position, Tolerance tolerance, double velocity) {
    var column = position.pixels / columnWidth;
    if (velocity < -tolerance.velocity) {
      column -= 0.5;
    } else if (velocity > tolerance.velocity) {
      column += 0.5;
    }
    return column.roundToDouble() * columnWidth;
  }

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    if ((velocity <= 0.0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0.0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final tolerance = toleranceFor(position);
    final target = _targetPixels(position, tolerance, velocity)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target != position.pixels) {
      return ScrollSpringSimulation(spring, position.pixels, target, velocity,
          tolerance: tolerance);
    }
    return null;
  }

  @override
  bool get allowImplicitScrolling => false;
}

class KioskBoardView extends ConsumerStatefulWidget {
  const KioskBoardView({
    super.key,
    required this.selected,
    required this.onBooked,
  });

  /// The currently selected player, or null when the board is display-only.
  final PlayerName? selected;

  /// Called after a booking attempt completes (success or failure) so the
  /// shell can decide whether to keep the selection (it always does — kiosk
  /// supports multi-booking per player before the ✕ or idle timeout clears
  /// the selection).
  final VoidCallback onBooked;

  @override
  ConsumerState<KioskBoardView> createState() => KioskBoardViewState();
}

class KioskBoardViewState extends ConsumerState<KioskBoardView> {
  final _hScroll = ScrollController();
  final _vScroll = ScrollController();

  // Snapshot of the most recent build's absolute axis, kept so resetToToday
  // can locate "now"'s slot without threading a HourMinute through the shell's
  // imperative reset call — the shell only holds a GlobalKey to this state, no
  // board-shaped data of its own to pass.
  HourMinute _axisStart = const HourMinute(0, 0);
  double _unit = 0;
  int _slotCount = 0;

  @override
  void dispose() {
    _hScroll.dispose();
    _vScroll.dispose();
    super.dispose();
  }

  static const _scrollDuration = Duration(milliseconds: 300);
  static const _scrollCurve = Curves.easeInOut;

  /// Scrolls the board back to today (leftmost column) and to the row-group
  /// covering the current time — called by the shell on idle reset (spec
  /// §1: "Idle reset resetuje aj horizontálny scroll na DNES") and extended
  /// here to also settle the vertical scroll on "now" so a kiosk that's sat
  /// idle re-centers on the relevant time slot instead of the day's first
  /// block.
  void resetToNow(HourMinute now) {
    if (_hScroll.hasClients) {
      _hScroll.animateTo(0, duration: _scrollDuration, curve: _scrollCurve);
    }
    if (_vScroll.hasClients && _slotCount > 0) {
      final target = _headerHeight + _nowSlot(now) * _unit;
      final clamped = target.clamp(0.0, _vScroll.position.maxScrollExtent);
      _vScroll.animateTo(clamped, duration: _scrollDuration, curve: _scrollCurve);
    }
  }

  /// Same as [resetToNow], reading the current time itself — kept as the
  /// name the shell already calls (`_boardKey.currentState?.resetToToday()`)
  /// so no shell change is needed beyond this widget growing a vertical
  /// scroll too.
  void resetToToday() => resetToNow(HourMinute(DateTime.now().hour, DateTime.now().minute));

  /// [now]'s position on the absolute axis, in 30-min slots from [_axisStart],
  /// clamped to `[0, _slotCount]` — so a time before the axis lands at the top
  /// and a time past the last block lands at the bottom, and the scroll target
  /// (`_headerHeight + slot * _unit`) always sits inside the grid.
  double _nowSlot(HourMinute now) {
    final slots =
        (now.minutesFromMidnight - _axisStart.minutesFromMidnight) / 30;
    return slots.clamp(0, _slotCount).toDouble();
  }

  Future<void> _book(
    BuildContext context,
    WidgetRef ref,
    Day date,
    TimeBlock block,
    int lane,
    PlayerName player,
  ) async {
    final message =
        '${player.displayName} · ${dayFull(date)} · ${block.label} · Dráha $lane';
    final confirmed = await confirmDialog(
      context,
      title: 'Rezervovat termín?',
      message: message,
      confirmLabel: 'Rezervovat',
    );
    if (!confirmed || !context.mounted) return;
    await tryAction(
      context,
      () => Api.createReservation(
        playerId: player.id,
        date: date,
        blockId: block.id,
        lane: lane,
      ),
      success: 'Zarezervováno.',
      errorText: friendlyDbError,
    );
    widget.onBooked();
  }

  @override
  Widget build(BuildContext context) {
    final nowDt = DateTime.now();
    final todayDay = Day.fromDateTime(nowDt);
    final now = HourMinute(nowDt.hour, nowDt.minute);
    final thisMonday = todayDay.addDays(1 - todayDay.weekday);

    final settings =
        ref.watch(settingsProvider).value ?? ScheduleSettings.defaults;
    final timeBlocks = ref.watch(timeBlocksProvider);
    final overrides = ref.watch(dayOverridesProvider).value ?? const [];
    final matches = ref.watch(matchesProvider).value ?? const [];
    final rentals = ref.watch(rentalsProvider).value ?? const [];
    final players = ref.watch(playersProvider).value ?? const [];

    // The board shows today..today+horizonDays inclusive (horizonDays+1
    // days total — matches buildWeekSchedule's own beyondHorizon predicate:
    // `differenceInDays(today) > horizonDays`, so exactly horizonDays itself
    // is still in range). That span can straddle more than two ISO weeks
    // whenever today isn't Monday (e.g. today = Sunday + horizonDays = 14
    // reaches 20 days ahead), so the number of Mondays to query is derived
    // from the actual span rather than hardcoded to "this + next" as a
    // starting approximation would assume.
    final lastDay = todayDay.addDays(settings.bookingHorizonDays);
    final lastMonday = lastDay.addDays(1 - lastDay.weekday);
    final mondayCount = lastMonday.differenceInDays(thisMonday) ~/ 7 + 1;
    final mondays = [
      for (var w = 0; w < mondayCount; w++) thisMonday.addDays(7 * w),
    ];
    final weekReservationsByMonday = {
      for (final monday in mondays)
        monday: ref.watch(weekReservationsProvider(monday)),
    };

    if (timeBlocks.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (timeBlocks.hasError) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Rozvrh se nepodařilo načíst.'),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => ref.invalidate(timeBlocksProvider),
              child: const Text('Zkusit znovu'),
            ),
          ],
        ),
      );
    }

    final dbBlocks = timeBlocks.value ?? const [];
    final blocksFromDb = dbBlocks.isNotEmpty;
    final blocks = blocksFromDb ? dbBlocks : defaultTimeBlocks();
    // Same reasoning as the old week view: cells stay inert while the
    // placeholder grid is shown or any covered week's reservation stream
    // hasn't loaded yet — a booking attempt against either would either hit
    // unmapped placeholder ids or race the RPC's own authoritative
    // slot-taken check.
    final interactive = blocksFromDb &&
        weekReservationsByMonday.values.every((r) => r.hasValue);

    // Keyed by date (not position) so slicing today..horizon can't
    // misalign even if a Monday's week ever produced anything but exactly 7
    // entries.
    final dayByDate = <Day, DaySchedule>{};
    for (final monday in mondays) {
      final week = buildWeekSchedule(
        monday: monday,
        today: todayDay,
        now: now,
        settings: settings,
        blocks: blocks,
        overrides: overrides,
        matches: matches,
        rentals: rentals,
        reservations: weekReservationsByMonday[monday]!.value ?? const [],
      );
      for (final day in week.days) {
        dayByDate[day.date] = day;
      }
    }
    final days = <DaySchedule>[
      for (var offset = 0; offset <= settings.bookingHorizonDays; offset++)
        dayByDate[todayDay.addDays(offset)]!,
    ];

    final nameById = {
      for (final p in players)
        p.id: p.nick.isNotEmpty ? p.nick : p.displayName,
    };
    final clubColorById = {for (final p in players) p.id: p.clubColor};

    // Default active (swimline) block set — still needed to classify a day as
    // shifted (its own block set differs → ⚡ header + per-cell time labels).
    // No longer drives geometry: the absolute axis below does.
    final railBlocks = blocks.where((b) => b.active).toList()
      ..sort(_byStartThenPosition);

    // Absolute 30-min axis over ALL blocks in view — the default active set
    // (so standard days always contribute their times even if a given visible
    // day is closed) unioned with every open day's own blocks (so a shifted
    // day's own-time blocks widen the axis to cover them). axisRange floors the
    // earliest start / ceils the latest end to :00/:30 and counts 30-min slots.
    final allBlocks = <TimeBlock>[
      ...railBlocks,
      for (final d in days)
        if (d is OpenDay) ...d.blocks,
    ];
    final axis = axisRange(allBlocks);
    final axisStart = axis.start;
    final slotCount = axis.slots;
    final unit = axisUnit(settings.laneCount);
    final gridHeight = slotCount * unit;
    final totalHeight = _headerHeight + gridHeight;
    // Snapshot for resetToNow's imperative scroll-target math (see field docs
    // above) — assignment only, no setState, so it can't trigger a rebuild loop.
    _axisStart = axisStart;
    _unit = unit;
    _slotCount = slotCount;

    return LayoutBuilder(
      builder: (context, constraints) {
        final columnWidth = boardColumnWidth(constraints.maxWidth);
        return SingleChildScrollView(
          controller: _vScroll,
          child: SizedBox(
            height: totalHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Rail(axisStart: axisStart, slotCount: slotCount, unit: unit),
                Expanded(
                  child: SizedBox(
                    height: totalHeight,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      controller: _hScroll,
                      physics: _ColumnSnapPhysics(columnWidth: columnWidth),
                      itemCount: days.length,
                      itemBuilder: (context, index) => SizedBox(
                        width: columnWidth,
                        child: _DayColumn(
                          day: days[index],
                          isToday: index == 0,
                          railBlocks: railBlocks,
                          axisStart: axisStart,
                          slotCount: slotCount,
                          unit: unit,
                          laneCount: settings.laneCount,
                          nameById: nameById,
                          clubColorById: clubColorById,
                          interactive: interactive,
                          selected: widget.selected,
                          onBook: (date, block, lane) => _book(
                            context,
                            ref,
                            date,
                            block,
                            lane,
                            widget.selected!,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The "HH:MM" label for the start of slot [i] on the absolute axis — i.e.
/// [axisStart] plus `i` half-hours. Formatted from raw minutes-from-midnight
/// (never via a [HourMinute], which asserts `hour < 24`) so a slot start at
/// 23:30 is fine and even a would-be 24:00 boundary never crashes; slot starts
/// are always strictly below the axis end, so this stays within a day anyway.
String _axisSlotLabel(HourMinute axisStart, int i) {
  final total = axisStart.minutesFromMidnight + i * 30;
  final h = total ~/ 60;
  final m = total % 60;
  return '$h:${m.toString().padLeft(2, '0')}';
}

/// Fixed left rail: one label per 30-min axis slot (0..[slotCount]-1), each
/// exactly [unit] tall so labels line up with the cells every [_DayColumn]
/// places on the same absolute axis. Whole-hour slot starts are drawn slightly
/// bolder; a faint gridline sits on each slot boundary.
class _Rail extends StatelessWidget {
  const _Rail({
    required this.axisStart,
    required this.slotCount,
    required this.unit,
  });

  final HourMinute axisStart;
  final int slotCount;
  final double unit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: _railWidth,
      child: Column(
        children: [
          const SizedBox(height: _headerHeight),
          for (var i = 0; i < slotCount; i++)
            Container(
              height: unit,
              decoration: BoxDecoration(
                border: _gridlineBorder(scheme, isLast: i == slotCount - 1),
              ),
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    _axisSlotLabel(axisStart, i),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 9,
                      // Whole-hour lines read as the primary grid; the :30
                      // marks are lighter so the eye anchors on the hours.
                      fontWeight:
                          (axisStart.minutesFromMidnight + i * 30) % 60 == 0
                              ? FontWeight.w700
                              : FontWeight.w500,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One board column's header: the day label (today gets the "DNES · …"
/// gradient treatment, spec §1) plus a match strip. Public and typed on
/// [date] so widget tests can enumerate visible board days the same way
/// they used to enumerate [DayHeader]s in the old week view.
class BoardColumnHeader extends StatelessWidget {
  const BoardColumnHeader({
    super.key,
    required this.date,
    required this.isToday,
    required this.matches,
    this.shifted = false,
  });

  final Day date;
  final bool isToday;
  final List<Match> matches;

  /// A shifted (own-times) day gets a tiny ⚡ before the date so it reads as
  /// custom (spec §2). Never combined with the DNES prefix on the same column.
  final bool shifted;

  static const _gradientColors = [Color(0xFF6366F1), Color(0xFF22D3EE)];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: _headerHeight,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        gradient:
            isToday ? const LinearGradient(colors: _gradientColors) : null,
        color: isToday ? null : scheme.surfaceContainerHigh,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            isToday
                ? 'DNES · ${dayLabel(date)}'
                : (shifted ? '⚡ ${dayLabel(date)}' : dayLabel(date)),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: isToday ? Colors.white : scheme.onSurface,
            ),
          ),
          if (matches.isNotEmpty)
            Text(
              matches.map((m) => '🏆 ${m.title}').join(' · '),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                color: isToday
                    ? Colors.white.withValues(alpha: 0.9)
                    : scheme.primary,
              ),
            ),
        ],
      ),
    );
  }
}

/// One board column, placed on the shared absolute 30-min axis: DNES-gradient
/// (today) or plain header, then the day's blocks each positioned at their TRUE
/// time — a block starting at T occupies the same slot (same y) in every
/// column and against the rail. Standard days read their time from the rail;
/// shifted days keep a ⚡ header + per-cell time labels since their times don't
/// match the clean default columns. A closed day dims the whole column and
/// shows a vertical "✕ zavřeno[ — reason]" — matches still render at their slot
/// (spectators want to see who plays even on a closed day, spec §1).
class _DayColumn extends StatelessWidget {
  const _DayColumn({
    required this.day,
    required this.isToday,
    required this.railBlocks,
    required this.axisStart,
    required this.slotCount,
    required this.unit,
    required this.laneCount,
    required this.nameById,
    required this.clubColorById,
    required this.interactive,
    required this.selected,
    required this.onBook,
  });

  final DaySchedule day;
  final bool isToday;
  final List<TimeBlock> railBlocks;
  final HourMinute axisStart;
  final int slotCount;
  final double unit;
  final int laneCount;
  final Map<String, String> nameById;
  final Map<String, int> clubColorById;
  final bool interactive;
  final PlayerName? selected;
  final void Function(Day date, TimeBlock block, int lane) onBook;

  double get _gridHeight => slotCount * unit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final day = this.day;
    // A shifted (own-times) day carries times that don't line up with the
    // clean default columns, so mark the header (⚡) and label its cells.
    final shifted = day is OpenDay && isShiftedDay(day, railBlocks);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
      ),
      // No border: an inset border would eat into the fixed-height column
      // below (header + gridHeight body summing to exactly the available
      // height already) and overflow by the border width — column separation
      // comes from the horizontal margin alone.
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BoardColumnHeader(
            date: day.date,
            isToday: isToday,
            matches: day.matches,
            shifted: shifted,
          ),
          SizedBox(
            height: _gridHeight,
            child: day is ClosedDay
                ? _closedBody(context, scheme, day)
                : _openBody(context, scheme, day as OpenDay, shifted),
          ),
        ],
      ),
    );
  }

  /// Places [day]'s own blocks on the absolute axis: for each block (sorted by
  /// start) an empty dim gap fills any slots before its `startSlot`, then the
  /// block cell occupies `spanSlots * unit`; a trailing gap fills to
  /// [slotCount]. Because slot math is integer (÷30) and heights are exactly
  /// `slots * unit`, a block at a given time has an identical top y in every
  /// column and on the rail.
  Widget _openBody(
      BuildContext context, ColorScheme scheme, OpenDay day, bool shifted) {
    final sorted = [...day.blocks]..sort(_byStartThenPosition);
    return _placed(
      context,
      scheme,
      sorted,
      (block) => _openCell(context, block, showTime: shifted),
    );
  }

  /// Closed column: the default active (swimline) blocks placed on the axis so
  /// any match still shows at its true slot (spectators), the rest rendering
  /// the dimmed "✕ zavřeno" filler; gaps between/around them are the same dim
  /// empty slots.
  Widget _closedBody(
      BuildContext context, ColorScheme scheme, ClosedDay day) {
    final sorted = [...railBlocks]..sort(_byStartThenPosition);
    return _placed(
      context,
      scheme,
      sorted,
      (block) => _closedCell(context, scheme, block),
    );
  }

  /// Builds the vertical Column of gaps + block cells for [blocks] (already
  /// sorted by start) on the absolute axis, using [cellFor] to render each
  /// block's body. A faint gridline sits under every emitted piece except the
  /// last so slot boundaries read across columns and against the rail.
  Widget _placed(
    BuildContext context,
    ColorScheme scheme,
    List<TimeBlock> blocks,
    Widget Function(TimeBlock block) cellFor,
  ) {
    final pieces = <({double height, Widget? cell})>[];
    var cursor = 0;
    for (final block in blocks) {
      final off = slotOffset(block, axisStart);
      if (off.startSlot > cursor) {
        pieces.add((height: (off.startSlot - cursor) * unit, cell: null));
      }
      // Blocks are non-overlapping by design, but the schema doesn't enforce
      // it — if a misconfigured pair overlaps (startSlot < cursor) place the
      // block right after the previous one instead of overflowing the fixed
      // gridHeight Column.
      final start = off.startSlot < cursor ? cursor : off.startSlot;
      pieces.add((height: off.spanSlots * unit, cell: cellFor(block)));
      cursor = start + off.spanSlots;
    }
    if (cursor < slotCount) {
      pieces.add((height: (slotCount - cursor) * unit, cell: null));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < pieces.length; i++)
          Container(
            height: pieces[i].height,
            decoration: BoxDecoration(
              border: _gridlineBorder(scheme, isLast: i == pieces.length - 1),
            ),
            child: pieces[i].cell ??
                ColoredBox(
                  color: scheme.surfaceContainerLowest.withValues(alpha: 0.3),
                ),
          ),
      ],
    );
  }

  /// A closed day still shows any match spanning [block] (spectators), on
  /// top of the dimmed "✕ zavřeno" column filler.
  Widget _closedCell(BuildContext context, ColorScheme scheme, TimeBlock block) {
    final closedDay = day as ClosedDay;
    final (blockMatch, isPrep) = matchStateForBlock(block, closedDay.matches);
    if (blockMatch != null) {
      return _matchCell(context, blockMatch, isPrep: isPrep);
    }
    return Container(
      color: scheme.surfaceContainerLowest.withValues(alpha: 0.6),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: RotatedBox(
        quarterTurns: 3,
        child: Text(
          closedDay.reason.isEmpty
              ? '✕ zavřeno'
              : '✕ zavřeno — ${closedDay.reason}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }

  /// Renders one of [day]'s own block cells. [showTime] (shifted day, spec §3)
  /// overlays a small `HH:MM–HH:MM` label at the top-right of the cell — over
  /// the free ＋, occupied, prep AND match content alike — so a player reads
  /// the time even though a shifted day's times don't line up with the rail.
  /// Standard-day cells pass `showTime: false` (time comes from the rail).
  Widget _openCell(BuildContext context, TimeBlock block,
      {bool showTime = false}) {
    final openDay = day as OpenDay;
    final scheme = Theme.of(context).colorScheme;

    final firstState = openDay.slot(block.id, 1);
    final Widget body;
    if (firstState is MatchSlot) {
      body = _matchCell(context, firstState.match, isPrep: firstState.isPrep);
    } else {
      body = Column(
        children: [
          for (var lane = 1; lane <= laneCount; lane++)
            Expanded(child: _laneRow(context, openDay, block, lane)),
        ],
      );
    }
    if (!showTime) return body;
    // Overlay the time label at the top-right without stealing height from the
    // body — a Column header here would shrink the lanes and break the exact
    // slots*unit height the absolute axis relies on. A Stack keeps the body
    // full-height under the label.
    return Stack(
      children: [
        Positioned.fill(child: body),
        // Top-right corner: the lane rows put their digit at the left and the
        // name centered, so the right corner is the least crowded. A faint
        // surface backdrop keeps the label readable over any club colour.
        Positioned(
          top: 1,
          right: 3,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '${block.startsAt.display()}–${block.endsAt.display()}',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Match/prep cell spans the whole block (all lanes) per spec §1:
  /// `🏆 {title}\n{start}–{end}` in rose, or the muted prep banner.
  Widget _matchCell(BuildContext context, Match match, {required bool isPrep}) {
    final scheme = Theme.of(context).colorScheme;
    if (isPrep) {
      return Container(
        color: scheme.errorContainer.withValues(alpha: 0.25),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          '🛠 Příprava drah',
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Container(
      color: scheme.errorContainer.withValues(alpha: 0.6),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        '🏆 ${match.title}\n${match.startsAt.display()}–${match.endsAt.display()}',
        textAlign: TextAlign.center,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: scheme.onErrorContainer,
        ),
      ),
    );
  }

  /// One lane row within an open block cell: digit + name/nick (mine =
  /// indigo), free = dashed cyan ＋, rental = 🔒 + renter name (amber).
  Widget _laneRow(BuildContext context, OpenDay day, TimeBlock block, int lane) {
    final scheme = Theme.of(context).colorScheme;
    final state = day.slot(block.id, lane);

    switch (state) {
      case RentedSlot(:final rental):
        // Rental colour (spec §3): a 0–11 index paints the row with that
        // palette colour; the default (-2, ClubColors.of → null) keeps the
        // amber tertiary tint.
        final rentalClub = ClubColors.of(rental.color, scheme.brightness);
        return _rowShell(
          context,
          background:
              rentalClub?.$1 ?? scheme.tertiaryContainer.withValues(alpha: 0.5),
          lane: lane,
          child: Text(
            '🔒 ${rental.renterName}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: rentalClub?.$2 ?? scheme.onTertiaryContainer,
            ),
          ),
        );
      case ReservedSlot(:final reservation):
        final isMine = selected != null && reservation.playerId == selected!.id;
        final name = nameById[reservation.playerId] ?? '?';
        // Foreign reservations carry the player's club colour (spec §5) so
        // spectators tell clubs apart at a glance; "mine" is never club-tinted
        // — it keeps the indigo primaryContainer highlight so the selected
        // player's own bookings stay unmistakable over any club background.
        final club = isMine
            ? null
            : ClubColors.of(clubColorById[reservation.playerId] ?? -1,
                scheme.brightness);
        return _rowShell(
          context,
          background: isMine
              ? scheme.primaryContainer
              : club?.$1 ??
                  scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          lane: lane,
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: isMine ? FontWeight.w700 : FontWeight.w500,
              color: isMine
                  ? scheme.onPrimaryContainer
                  : club?.$2 ?? scheme.onSurfaceVariant,
            ),
          ),
        );
      case FreeSlot(:final inPast, :final beyondHorizon):
        final bookable =
            interactive && selected != null && !inPast && !beyondHorizon;
        return _rowShell(
          context,
          lane: lane,
          onTap: bookable ? () => onBook(day.date, block, lane) : null,
          // Spec §1: bookable free rows get a cyan outline around the ＋
          // (kept plain/solid rather than a literal dash pattern — Flutter
          // has no built-in dashed Border, and SlotTile's own free-slot
          // rendering elsewhere in the app already uses the same plain-
          // border interpretation).
          border: bookable
              ? Border.all(color: scheme.secondary.withValues(alpha: 0.5))
              : null,
          child: bookable
              ? Text(
                  '＋',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: scheme.secondary,
                  ),
                )
              : null,
        );
      case MatchSlot():
        // Every lane of a matched block resolves to the same MatchSlot —
        // _openCell already renders the whole-block match/prep banner before
        // ever reaching per-lane rows, so this case is unreachable in
        // practice; kept only so the switch stays exhaustive.
        return const SizedBox.shrink();
    }
  }

  Widget _rowShell(
    BuildContext context, {
    required int lane,
    Color? background,
    BoxBorder? border,
    VoidCallback? onTap,
    Widget? child,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final body = Container(
      decoration: BoxDecoration(color: background, border: border),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            child: Text(
              '$lane',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ),
          const SizedBox(width: 4),
          if (child != null) Expanded(child: child),
        ],
      ),
    );
    if (onTap == null) return body;
    return InkWell(onTap: onTap, child: body);
  }
}
