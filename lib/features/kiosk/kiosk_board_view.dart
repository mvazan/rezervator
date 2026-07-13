/// Kiosk "board": landscape days-as-columns view replacing the old vertical
/// week list. Columns run from `today` (first, highlighted DNES) forward
/// through `booking_horizon_days`, all equally wide; rows are the union of
/// every visible day's time blocks (sorted by start time), so a lane cell
/// lines up across columns regardless of which specific day it belongs to.
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
    priority: const [],
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

  // Snapshot of the most recent build's timeline segments, kept so
  // resetToToday can locate "now"'s segment without threading a HourMinute
  // through the shell's imperative reset call — the shell only holds a
  // GlobalKey to this state, no board-shaped data of its own to pass.
  List<BoardSegment> _segments = const [];

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
    if (_vScroll.hasClients && _segments.isNotEmpty) {
      final index = segmentIndexForTime(_segments, now);
      final target = _headerHeight +
          _segments.take(index).fold(0.0, (a, s) => a + s.height);
      final clamped =
          target.clamp(0.0, _vScroll.position.maxScrollExtent);
      _vScroll.animateTo(clamped, duration: _scrollDuration, curve: _scrollCurve);
    }
  }

  /// Same as [resetToNow], reading the current time itself — kept as the
  /// name the shell already calls (`_boardKey.currentState?.resetToToday()`)
  /// so no shell change is needed beyond this widget growing a vertical
  /// scroll too.
  void resetToToday() => resetToNow(HourMinute(DateTime.now().hour, DateTime.now().minute));

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
    final priority = ref.watch(prioritySlotsProvider);
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
        priority: priority,
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

    // Row rail = union of every day on the board (not just whichever column
    // happens to be scrolled into view — the rail is a single fixed
    // structure shared by all columns, so it must be stable regardless of
    // horizontal scroll position), sorted by start time.
    final blockById = <String, TimeBlock>{};
    for (final day in days) {
      if (day is OpenDay) {
        for (final b in day.blocks) {
          blockById[b.id] = b;
        }
      }
    }
    final railBlocks = blockById.values.toList()..sort(_byStartThenPosition);
    // Off-block match/rental windows across EVERY visible day: they carve
    // occupied gap segments into the shared timeline so out-of-block events
    // render at their true time. Matches count on closed days too
    // (spectators); rentals only exist on open days.
    final eventWindows = <(HourMinute, HourMinute)>[
      for (final day in days) ...[
        for (final m in day.priority) (m.startsAt, m.endsAt),
        if (day is OpenDay)
          for (final r in day.rentals) (r.startsAt, r.endsAt),
      ],
    ];
    // The shared timeline: blocks at proportional heights (as before) plus
    // gap segments — every column and the rail consume this same list, so
    // all share one vertical grid.
    final segments = buildBoardSegments(
      railBlocks: railBlocks,
      eventWindows: eventWindows,
      laneCount: settings.laneCount,
    );
    final gridHeight = segments.fold(0.0, (a, s) => a + s.height);
    final totalHeight = _headerHeight + gridHeight;
    // Snapshot for resetToNow's imperative scroll-target math (see field
    // docs above) — assignment only, no setState, so it can't trigger a
    // rebuild loop.
    _segments = segments;

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
                _Rail(segments: segments),
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
                          segments: segments,
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

/// Fixed left rail: one label per timeline segment, each exactly
/// `segments[i].height` tall — the same heights every [_DayColumn] gives its
/// own cells — so labels line up with cells across columns. Block segments
/// carry the block label; occupied gaps a quieter time range; empty-gap
/// slivers stay unlabeled.
class _Rail extends StatelessWidget {
  const _Rail({required this.segments});

  final List<BoardSegment> segments;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: _railWidth,
      child: Column(
        children: [
          const SizedBox(height: _headerHeight),
          for (var i = 0; i < segments.length; i++)
            Container(
              height: segments[i].height,
              decoration: BoxDecoration(
                border:
                    _gridlineBorder(scheme, isLast: i == segments.length - 1),
              ),
              child: switch (segments[i]) {
                BlockSegment(:final block) => Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        block.label,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                OccupiedGapSegment(:final start, :final end) => Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '${start.display()}–${end.display()}',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                          color:
                              scheme.onSurfaceVariant.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                  ),
                EmptyGapSegment() => const SizedBox.shrink(),
              },
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
    required this.priority,
  });

  final Day date;
  final bool isToday;
  final List<PrioritySlot> priority;

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
            isToday ? 'DNES · ${dayLabel(date)}' : dayLabel(date),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: isToday ? Colors.white : scheme.onSurface,
            ),
          ),
          if (priority.isNotEmpty)
            Text(
              priority.map((m) => '${m.type.isMatch ? '🏆' : '⛔'} ${m.title}').join(' · '),
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

/// One board column: DNES-gradient (today) or plain header, then one
/// row-group per rail block. A closed day dims the whole column and shows a
/// vertical "✕ zavřeno[ — reason]" — matches still render on top (spectators
/// want to see who plays even on a closed day, spec §1).
class _DayColumn extends StatelessWidget {
  const _DayColumn({
    required this.day,
    required this.isToday,
    required this.segments,
    required this.laneCount,
    required this.nameById,
    required this.clubColorById,
    required this.interactive,
    required this.selected,
    required this.onBook,
  });

  final DaySchedule day;
  final bool isToday;
  final List<BoardSegment> segments;
  final int laneCount;
  final Map<String, String> nameById;
  final Map<String, int> clubColorById;
  final bool interactive;
  final PlayerName? selected;
  final void Function(Day date, TimeBlock block, int lane) onBook;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final closed = day is ClosedDay;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
      ),
      // No border: an inset border would eat into the fixed-height Column
      // below (header + one SizedBox per segment summing to exactly the
      // available height already) and overflow by the border width —
      // column separation comes from the horizontal margin alone.
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BoardColumnHeader(
            date: day.date,
            isToday: isToday,
            priority: day.priority,
          ),
          for (var i = 0; i < segments.length; i++)
            Container(
              height: segments[i].height,
              decoration: BoxDecoration(
                border:
                    _gridlineBorder(scheme, isLast: i == segments.length - 1),
              ),
              child: switch (segments[i]) {
                BlockSegment(:final block) => closed
                    ? _closedCell(context, scheme, block)
                    : _openCell(context, block),
                final OccupiedGapSegment gap => _gapCell(context, gap),
                EmptyGapSegment() => _dimFiller(scheme),
              },
            ),
        ],
      ),
    );
  }

  Widget _dimFiller(ColorScheme scheme) =>
      Container(color: scheme.surfaceContainerLowest.withValues(alpha: 0.3));

  /// An occupied gap: this day's own off-block matches (open AND closed days
  /// — spectator parity) and rentals (open days only) render as bands at
  /// their true sub-position inside the segment; a day with nothing here
  /// shows the dim filler.
  Widget _gapCell(BuildContext context, OccupiedGapSegment gap) {
    final scheme = Theme.of(context).colorScheme;
    final segStart = gap.start.minutesFromMidnight;
    final segLen = gap.end.minutesFromMidnight - segStart;

    final bands = <Widget>[];
    void addBand(HourMinute start, HourMinute end, Widget child) {
      final s = start.minutesFromMidnight.clamp(segStart, segStart + segLen);
      final e = end.minutesFromMidnight.clamp(segStart, segStart + segLen);
      if (e <= s || segLen <= 0) return;
      bands.add(Positioned(
        left: 0,
        right: 0,
        top: (s - segStart) / segLen * gap.height,
        height: (e - s) / segLen * gap.height,
        child: child,
      ));
    }

    for (final m in day.priority) {
      if (!timesOverlap(m.startsAt, m.endsAt, gap.start, gap.end)) continue;
      final club = ClubColors.of(m.type.colorIndex, scheme.brightness);
      addBand(
        m.startsAt,
        m.endsAt,
        _eventBand(
          scheme,
          background: club?.$1 ?? scheme.errorContainer.withValues(alpha: 0.6),
          foreground: club?.$2 ?? scheme.onErrorContainer,
          text: '${m.type.isMatch ? '🏆' : '⛔'} ${m.title}\n'
              '${m.startsAt.display()}–${m.endsAt.display()}',
          bold: true,
        ),
      );
    }
    if (day case final OpenDay openDay) {
      for (final r in openDay.rentals) {
        if (!timesOverlap(r.startsAt, r.endsAt, gap.start, gap.end)) continue;
        final club = ClubColors.of(r.color, scheme.brightness);
        addBand(
          r.startsAt,
          r.endsAt,
          _eventBand(
            scheme,
            background:
                club?.$1 ?? scheme.tertiaryContainer.withValues(alpha: 0.5),
            foreground: club?.$2 ?? scheme.onTertiaryContainer,
            text: '🔒 ${r.renterName}\n'
                '${r.startsAt.display()}–${r.endsAt.display()}',
          ),
        );
      }
    }

    if (bands.isEmpty) return _dimFiller(scheme);
    return Stack(
      children: [Positioned.fill(child: _dimFiller(scheme)), ...bands],
    );
  }

  Widget _eventBand(
    ColorScheme scheme, {
    required Color background,
    required Color foreground,
    required String text,
    bool bold = false,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 1.5),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        text,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
          color: foreground,
        ),
      ),
    );
  }

  /// A closed day still shows any whole-alley priority slot spanning [block]
  /// (spectators), on top of the dimmed "✕ zavřeno" column filler.
  Widget _closedCell(BuildContext context, ColorScheme scheme, TimeBlock block) {
    final closedDay = day as ClosedDay;
    final (blockSlot, isPrep) =
        wholeAlleyPriorityFor(block, closedDay.priority);
    if (blockSlot != null) {
      return _priorityCell(context, blockSlot, isPrep: isPrep);
    }
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 1.5),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
      ),
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

  Widget _openCell(BuildContext context, TimeBlock railBlock) {
    final openDay = day as OpenDay;
    final scheme = Theme.of(context).colorScheme;
    // The rail's block set is the UNION across every day on the board — an
    // open day that doesn't itself have this specific block (e.g. a custom
    // day-override subset) renders a dim empty filler instead.
    final hasBlock = openDay.blocks.any((b) => b.id == railBlock.id);
    if (!hasBlock) return _dimFiller(scheme);

    // A WHOLE-ALLEY priority slot claims the entire block cell (banner over
    // all lanes); lane-scoped slots fall through to per-lane rows so the
    // remaining lanes stay bookable.
    final (wholeAlley, wholeIsPrep) =
        wholeAlleyPriorityFor(railBlock, openDay.priority);
    if (wholeAlley != null) {
      return _priorityCell(context, wholeAlley, isPrep: wholeIsPrep);
    }

    return Column(
      children: [
        for (var lane = 1; lane <= laneCount; lane++)
          Expanded(child: _laneRow(context, openDay, railBlock, lane)),
      ],
    );
  }

  /// Whole-alley priority cell spans the whole block (all lanes):
  /// `{emoji} {title}\n{start}–{end}` tinted by the type's color (default
  /// rose), or the muted prep banner.
  Widget _priorityCell(BuildContext context, PrioritySlot slot,
      {required bool isPrep}) {
    final scheme = Theme.of(context).colorScheme;
    if (isPrep) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 1.5),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: scheme.errorContainer.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(6),
        ),
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
    final club = ClubColors.of(slot.type.colorIndex, scheme.brightness);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 1.5),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: club?.$1 ?? scheme.errorContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        '${slot.type.isMatch ? '🏆 ' : ''}${slot.title}\n'
        '${slot.startsAt.display()}–${slot.endsAt.display()}',
        textAlign: TextAlign.center,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: club?.$2 ?? scheme.onErrorContainer,
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
      case PrioritySlotState(:final slot, :final isPrep):
        // Whole-alley slots never reach here (_openCell renders the banner
        // first); this is a LANE-SCOPED priority slot blocking just this row.
        final club = ClubColors.of(slot.type.colorIndex, scheme.brightness);
        return _rowShell(
          context,
          background: isPrep
              ? scheme.errorContainer.withValues(alpha: 0.25)
              : club?.$1 ?? scheme.errorContainer.withValues(alpha: 0.6),
          lane: lane,
          child: Text(
            isPrep ? '🛠 Příprava drah' : '⛔ ${slot.title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: isPrep
                  ? scheme.onSurfaceVariant
                  : club?.$2 ?? scheme.onErrorContainer,
            ),
          ),
        );
    }
  }

  /// Every lane slot renders as its own bounded rounded cell (margin +
  /// radius) instead of a flush swimlane band; a free non-bookable slot gets
  /// a faint fill so the card outline still reads at a distance.
  Widget _rowShell(
    BuildContext context, {
    required int lane,
    Color? background,
    BoxBorder? border,
    VoidCallback? onTap,
    Widget? child,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(6);
    final body = Container(
      margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 1.5),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: background ?? scheme.surfaceContainerLow.withValues(alpha: 0.35),
        border: border,
        borderRadius: radius,
      ),
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
                color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
          const SizedBox(width: 4),
          if (child != null) Expanded(child: child),
        ],
      ),
    );
    if (onTap == null) return body;
    return InkWell(onTap: onTap, borderRadius: radius, child: body);
  }
}
