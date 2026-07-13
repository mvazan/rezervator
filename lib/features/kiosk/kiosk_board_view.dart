/// Kiosk "board": landscape days-as-columns CALENDAR view. An hour ruler
/// runs down the left; each column positions its day's blocks (and off-block
/// matches/rentals) at their true time, sized to their true duration, on a
/// shared [CalendarWindow] + px/minute scale — so all columns and the ruler
/// are geometrically aligned by construction. The window is stretched to the
/// available height (whole day visible without scrolling) unless that would
/// squash rows below legibility, in which case a vertical scroll kicks in.
/// Display-only until a player is selected — then free lane rows book for
/// THAT player. No cancel affordance anywhere (kiosk performs exactly one
/// action type).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/calendar_layout.dart';
import '../../domain/models.dart';
import '../../domain/palette.dart';
import '../../domain/schedule.dart';
import '../schedule/widgets/calendar_board.dart';

export '../schedule/widgets/calendar_board.dart'
    show
        BoardColumnHeader,
        ColumnSnapPhysics,
        boardColumnWidth,
        boardHeaderHeight,
        calendarHeaderHeight;

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

/// Slack under the columns so the bottom hour label (centered on its line)
/// isn't half-clipped by the viewport in fit-height mode.
const double _bottomLabelPad = 8.0;

/// Scale floor keeping every lane row tappable: the shortest visible block,
/// divided across [laneCount] rows (plus its od–do time header), must stay
/// at least [_minLaneRowHeight] tall per row (the deleted segment board
/// guaranteed the same 22px). Below the resulting scale the board grows past
/// the viewport and scrolls vertically instead of squashing further (rare —
/// only when an early-morning event stretches the window way beyond the
/// usual training hours).
const double _minLaneRowHeight = 22.0;

/// Height of the block card's od–do time header row.
const double _blockHeaderHeight = 14.0;

double _minPxPerMinute(Iterable<TimeBlock> blocks, int laneCount) {
  int? shortest;
  for (final b in blocks) {
    final d = b.durationMinutes;
    if (d > 0 && (shortest == null || d < shortest)) shortest = d;
  }
  if (shortest == null) return 0.9;
  final floor =
      (_minLaneRowHeight * laneCount + _blockHeaderHeight) / shortest;
  return floor < 0.9 ? 0.9 : floor;
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

  /// The sticky header strip's horizontal position — driven by [_hScroll]
  /// (never scrolled directly), so headers stay glued over their columns.
  final _hHeader = ScrollController();

  @override
  void initState() {
    super.initState();
    _hScroll.addListener(_syncHeader);
  }

  void _syncHeader() {
    if (_hHeader.hasClients &&
        _hScroll.hasClients &&
        _hHeader.offset != _hScroll.offset) {
      _hHeader.jumpTo(_hScroll.offset);
    }
  }

  // Snapshot of the most recent build's geometry, kept so resetToNow can
  // locate "now" without threading a HourMinute through the shell's
  // imperative reset call — the shell only holds a GlobalKey to this state,
  // no board-shaped data of its own to pass.
  CalendarWindow? _window;
  double _pxPerMinute = 0;

  /// Today's block spans in minutes-from-midnight — the idle reset anchors
  /// on the START of the block containing "now" (the board doesn't creep
  /// down mid-block; it advances when the block ends).
  List<(int, int)> _todayBlockSpans = const [];

  @override
  void dispose() {
    _hScroll.dispose();
    _vScroll.dispose();
    _hHeader.dispose();
    super.dispose();
  }

  static const _scrollDuration = Duration(milliseconds: 300);
  static const _scrollCurve = Curves.easeInOut;

  /// Scrolls the board back to today (leftmost column) and vertically toward
  /// "now" — called by the shell on idle reset. With the usual fit-height
  /// scale the vertical extent is zero and only the horizontal reset moves.
  /// While a block is running, the anchor is that block's START (the whole
  /// block stays in view until it ends — no mid-block creep).
  void resetToNow(HourMinute now) {
    if (_hScroll.hasClients) {
      _hScroll.animateTo(0, duration: _scrollDuration, curve: _scrollCurve);
    }
    final window = _window;
    if (_vScroll.hasClients && window != null) {
      final nowMin = now.minutesFromMidnight;
      var anchorMin = nowMin;
      for (final (start, end) in _todayBlockSpans) {
        if (start <= nowMin && nowMin < end) {
          anchorMin = start;
          break;
        }
      }
      // The header strip is sticky (outside the scroll), so the target is
      // pure body geometry.
      final target = window.topFor(hourMinuteAt(anchorMin), _pxPerMinute) -
          40; // a little context above the line
      _vScroll.animateTo(
        target.clamp(0.0, _vScroll.position.maxScrollExtent),
        duration: _scrollDuration,
        curve: _scrollCurve,
      );
    }
  }

  /// Same as [resetToNow], reading the current time itself — kept as the
  /// name the shell already calls (`_boardKey.currentState?.resetToToday()`).
  void resetToToday() =>
      resetToNow(HourMinute(DateTime.now().hour, DateTime.now().minute));

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
    // Same reasoning as the app's week view: cells stay inert while the
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

    // The shared time window: every visible day's blocks plus every
    // off-block match/rental window (matches count on closed days too —
    // spectators; rentals only exist on open days). One window for all
    // columns AND the ruler.
    final windowBlocks = <TimeBlock>[
      for (final day in days)
        if (day is OpenDay) ...day.blocks,
    ];
    final eventWindows = <(HourMinute, HourMinute)>[
      for (final day in days) ...[
        for (final m in day.priority) (m.startsAt, m.endsAt),
        if (day is OpenDay)
          for (final r in day.rentals) (r.startsAt, r.endsAt),
      ],
    ];
    final window =
        calendarWindowFor(blocks: windowBlocks, eventWindows: eventWindows);
    if (window == null) {
      return const Center(child: Text('Rozvrh je prázdný.'));
    }
    // Half-hour ruler labels/gridlines only when the alley actually uses
    // half-hour block boundaries.
    final halfHourMarks = windowBlocks
        .any((b) => b.startsAt.minute == 30 || b.endsAt.minute == 30);

    // Shared header height: the busiest visible day dictates it for every
    // column AND the ruler offset, so all event lines fit without clipping.
    var maxHeaderEvents = 0;
    for (final day in days) {
      final count = headerEvents(day).length;
      if (count > maxHeaderEvents) maxHeaderEvents = count;
    }
    final headerHeight = boardHeaderHeight(maxHeaderEvents);

    return LayoutBuilder(
      builder: (context, constraints) {
        final columnWidth = boardColumnWidth(constraints.maxWidth);
        // Two admin-selectable modes (settings.kioskFitDay):
        // - fit-height: the whole window stretches to the viewport, floored
        //   at the legibility scale (then the board scrolls anyway);
        // - comfortable scroll: the same fixed scale as the app's week view
        //   (a 60-min block = laneCount × 40 px), scrolling vertically; the
        //   idle reset brings the board back to "now".
        final fitScale =
            (constraints.maxHeight - headerHeight - _bottomLabelPad) /
                window.minutes;
        final minScale = _minPxPerMinute(windowBlocks, settings.laneCount);
        final comfortableScale = settings.laneCount * 40.0 / 60;
        final pxPerMinute = settings.kioskFitDay
            ? (fitScale < minScale ? minScale : fitScale)
            // The tappability floor applies here too: a very short block
            // must not squash its lane rows below reach in scroll mode
            // either.
            : (comfortableScale < minScale ? minScale : comfortableScale);
        final bodyHeight = window.minutes * pxPerMinute + _bottomLabelPad;
        // Snapshot for resetToNow's imperative scroll-target math (see field
        // docs above) — assignment only, no setState, so it can't trigger a
        // rebuild loop.
        _window = window;
        _pxPerMinute = pxPerMinute;
        _todayBlockSpans = [
          if (days.first case OpenDay(:final blocks))
            for (final b in blocks)
              (b.startsAt.minutesFromMidnight, b.endsAt.minutesFromMidnight),
        ];

        // Sticky header strip: pinned above the vertically scrolling body,
        // horizontally driven by the body's own scroll (see _syncHeader).
        return Column(
          children: [
            SizedBox(
              height: headerHeight,
              child: Row(
                children: [
                  const SizedBox(width: calendarRulerWidth),
                  Expanded(
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      controller: _hHeader,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: days.length,
                      itemBuilder: (context, index) => SizedBox(
                        width: columnWidth,
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          child: BoardColumnHeader(
                            date: days[index].date,
                            isToday: index == 0,
                            priority: headerEvents(days[index]),
                            height: headerHeight,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                controller: _vScroll,
                child: SizedBox(
                  height: bodyHeight,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      HourRuler(
                        window: window,
                        pxPerMinute: pxPerMinute,
                        halfHourMarks: halfHourMarks,
                      ),
                      Expanded(
                        child: SizedBox(
                          height: bodyHeight,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            controller: _hScroll,
                            physics:
                                ColumnSnapPhysics(columnWidth: columnWidth),
                            itemCount: days.length,
                            itemBuilder: (context, index) => SizedBox(
                              width: columnWidth,
                              child: _DayColumn(
                                day: days[index],
                                window: window,
                                pxPerMinute: pxPerMinute,
                                halfHourMarks: halfHourMarks,
                                nowMinute: index == 0 &&
                                        now.minutesFromMidnight >=
                                            window.startMinute &&
                                        now.minutesFromMidnight <
                                            window.endMinute
                                    ? now.minutesFromMidnight
                                    : null,
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
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One board column's calendar area — blocks and off-block events positioned
/// at their true time (the day header lives in the sticky strip above). A
/// closed day dims the whole column behind a vertical "✕ zavřeno[ — reason]";
/// matches still render on top (spectators want to see who plays even on a
/// closed day).
class _DayColumn extends StatelessWidget {
  const _DayColumn({
    required this.day,
    required this.window,
    required this.pxPerMinute,
    required this.halfHourMarks,
    required this.nowMinute,
    required this.laneCount,
    required this.nameById,
    required this.clubColorById,
    required this.interactive,
    required this.selected,
    required this.onBook,
  });

  final DaySchedule day;
  final CalendarWindow window;
  final double pxPerMinute;
  final bool halfHourMarks;
  final int? nowMinute;
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
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10)),
      child: CalendarColumn(
        window: window,
        pxPerMinute: pxPerMinute,
        halfHourMarks: halfHourMarks,
        entries: _entries(context),
        background: closed ? _closedBackground(context, scheme) : null,
        nowMinute: nowMinute,
      ),
    );
  }

  List<CalendarEntry> _entries(BuildContext context) {
    final entries = <CalendarEntry>[];

    final openDay = day is OpenDay ? day as OpenDay : null;
    final blockUnion = mergeIntervals([
      if (openDay != null)
        for (final b in openDay.blocks)
          (b.startsAt.minutesFromMidnight, b.endsAt.minutesFromMidnight),
    ]);

    if (openDay != null) {
      for (final block in openDay.blocks) {
        entries.add(CalendarEntry(
          start: block.startsAt,
          end: block.endsAt,
          child: _blockCard(context, openDay, block),
        ));
      }
    }

    // Off-block pieces of matches/rentals: the part of an event window not
    // covered by this day's own blocks — nor by an earlier band — renders as
    // a positioned band (the in-block part renders via slot states inside
    // the block card). Matches band on closed days too; rentals only exist
    // on open days. `covered` grows with every emitted band, so overlaps
    // resolve first-wins in emission order: priority slots (start-sorted)
    // before rentals — a renter band can never paint over a match.
    final covered = <(int, int)>[...blockUnion];
    void addBands(
        HourMinute start, HourMinute end, Widget Function() bandBuilder) {
      for (final (s, e) in subtractInterval(
          (start.minutesFromMidnight, end.minutesFromMidnight),
          mergeIntervals(covered))) {
        entries.add(CalendarEntry(
            start: hourMinuteAt(s), end: hourMinuteAt(e), child: bandBuilder()));
        covered.add((s, e));
      }
    }

    final scheme = Theme.of(context).colorScheme;
    for (final m in day.priority) {
      final club = ClubColors.of(m.type.colorIndex, scheme.brightness);
      addBands(
        m.startsAt,
        m.endsAt,
        () => CalendarEventBand(
          background: club?.$1 ?? scheme.errorContainer.withValues(alpha: 0.6),
          foreground: club?.$2 ?? scheme.onErrorContainer,
          text: '${m.type.isMatch ? '🏆' : '⛔'} ${m.title}\n'
              '${m.startsAt.display()}–${m.endsAt.display()}',
          bold: true,
        ),
      );
    }
    if (openDay != null) {
      for (final r in openDay.rentals) {
        final club = ClubColors.of(r.color, scheme.brightness);
        addBands(
          r.startsAt,
          r.endsAt,
          () => CalendarEventBand(
            background:
                club?.$1 ?? scheme.tertiaryContainer.withValues(alpha: 0.5),
            foreground: club?.$2 ?? scheme.onTertiaryContainer,
            text: '🔒 ${r.renterName}\n'
                '${r.startsAt.display()}–${r.endsAt.display()}',
          ),
        );
      }
    }

    return entries;
  }

  Widget _closedBackground(BuildContext context, ColorScheme scheme) {
    final closedDay = day as ClosedDay;
    return Container(
      color: scheme.surfaceContainerLowest.withValues(alpha: 0.5),
      alignment: Alignment.center,
      child: RotatedBox(
        quarterTurns: 3,
        child: Text(
          closedDay.reason.isEmpty
              ? '✕ zavřeno'
              : '✕ zavřeno — ${closedDay.reason}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }

  /// One block's calendar card: one row per lane. Whole-alley priority
  /// slots never reach a rendered block (they cancel overlapping blocks in
  /// buildWeekSchedule and render as true-time bands instead); lane-scoped
  /// slots resolve per lane row.
  Widget _blockCard(BuildContext context, OpenDay openDay, TimeBlock block) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      // Stable per-block key (unique among one column's entries; other
      // columns have their own parents) so tests can measure card geometry.
      key: ValueKey('cal-block-${block.id}'),
      // The 1.5px vertical inset matches CalendarEventBand's, so a band and
      // a touching block card keep a visible seam between them.
      margin: const EdgeInsets.symmetric(horizontal: 1, vertical: 1.5),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        children: [
          // Quiet od–do label, same treatment as the app's week view.
          SizedBox(
            height: _blockHeaderHeight,
            child: Center(
              child: Text(
                block.label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
                ),
              ),
            ),
          ),
          for (var lane = 1; lane <= laneCount; lane++)
            Expanded(child: _laneRow(context, openDay, block, lane)),
        ],
      ),
    );
  }

  /// One lane row within an open block card: digit + name/nick (mine =
  /// indigo), free = cyan-outlined ＋, rental = 🔒 + renter name (amber).
  Widget _laneRow(
      BuildContext context, OpenDay day, TimeBlock block, int lane) {
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
            : ClubColors.of(
                clubColorById[reservation.playerId] ?? -1, scheme.brightness);
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
      case PrioritySlotState(:final slot):
        // A LANE-SCOPED priority slot blocking just this row — or, briefly,
        // an unresolved-type slot (renders like a match but doesn't cancel
        // blocks until its type row streams in).
        final club = ClubColors.of(slot.type.colorIndex, scheme.brightness);
        return _rowShell(
          context,
          background: club?.$1 ?? scheme.errorContainer.withValues(alpha: 0.6),
          lane: lane,
          child: Text(
            '${slot.type.isMatch ? '🏆' : '⛔'} ${slot.title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: club?.$2 ?? scheme.onErrorContainer,
            ),
          ),
        );
    }
  }

  /// Every lane slot renders as its own bounded rounded cell (margin +
  /// radius) inside the block card; a free non-bookable slot stays a quiet
  /// outline-less fill so the card reads as one unit at a distance.
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
