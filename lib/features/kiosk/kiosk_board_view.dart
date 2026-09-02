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
import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../data/week_schedule.dart';
import '../../domain/calendar_layout.dart';
import '../../domain/models.dart';
import '../../domain/schedule.dart';
import '../schedule/widgets/calendar_board.dart';
import '../schedule/widgets/schedule_day_column.dart';
import '../schedule/widgets/slot_tile.dart';

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

double _minPxPerMinute(Iterable<TimeBlock> blocks, int laneCount) {
  int? shortest;
  for (final b in blocks) {
    final d = b.durationMinutes;
    if (d > 0 && (shortest == null || d < shortest)) shortest = d;
  }
  if (shortest == null) return 0.9;
  final floor =
      (_minLaneRowHeight * laneCount + blockCardHeaderHeight) / shortest;
  return floor < 0.9 ? 0.9 : floor;
}

class KioskBoardView extends ConsumerStatefulWidget {
  const KioskBoardView({super.key, required this.selected});

  /// The currently selected player, or null when the board is display-only.
  final PlayerName? selected;

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

  /// Same as [resetToNow], reading the current time itself — the shell's
  /// idle-reset entry point.
  void resetToToday() {
    final now = DateTime.now();
    resetToNow(HourMinute(now.hour, now.minute));
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
  }

  @override
  Widget build(BuildContext context) {
    final nowDt = ref.watch(nowProvider).value ?? DateTime.now();
    final todayDay = Day.fromDateTime(nowDt);
    final now = HourMinute(nowDt.hour, nowDt.minute);
    final thisMonday = todayDay.addDays(1 - todayDay.weekday);

    final settings =
        ref.watch(settingsProvider).value ?? ScheduleSettings.defaults;

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
    final viewByMonday = {
      for (final monday in mondays)
        monday: ref.watch(weekScheduleProvider(monday)),
    };

    if (viewByMonday.values.any((v) => v.isLoading)) {
      return const Center(child: CircularProgressIndicator());
    }

    if (viewByMonday.values.any((v) => v.hasError)) {
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

    final views = [for (final v in viewByMonday.values) v.value!];
    // Every covered week must be bookable (real blocks, its reservation
    // stream loaded — see WeekView.interactive) before any cell reacts.
    final interactive = views.every((v) => v.interactive);

    // The selected player's live reservations across every watched week —
    // the count create_reservation checks against max_active_reservations,
    // so ＋ is only offered where the RPC would accept it (no limit_reached
    // bounce). Weeks are disjoint Monday..Sunday spans: nothing double-counts.
    final selected = widget.selected;
    final selectedCount = selected == null
        ? 0
        : activeReservationCount(
            [for (final v in views) ...v.reservations],
            selected.id,
            todayDay,
          );

    // Keyed by date (not position) so slicing today..horizon can't
    // misalign even if a Monday's week ever produced anything but exactly 7
    // entries.
    final dayByDate = <Day, DaySchedule>{};
    for (final v in views) {
      for (final day in v.week.days) {
        dayByDate[day.date] = day;
      }
    }
    final days = <DaySchedule>[
      for (var offset = 0; offset <= settings.bookingHorizonDays; offset++)
        dayByDate[todayDay.addDays(offset)]!,
    ];

    final nameById = views.first.nameById;
    final clubColorById = views.first.clubColorById;

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
        final comfortableScale = settings.laneCount * laneRowRefHeight / 60;
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
                              // The kiosk column is read-only: no admin
                              // hooks, rows resolved by _laneRow.
                              child: Container(
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 2),
                                clipBehavior: Clip.antiAlias,
                                decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(10)),
                                child: ScheduleDayColumn(
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
                                  laneRow: (context, day, block, lane) =>
                                      _laneRow(
                                    day,
                                    block,
                                    lane,
                                    settings: settings,
                                    nameById: nameById,
                                    clubColorById: clubColorById,
                                    interactive: interactive,
                                    selectedCount: selectedCount,
                                  ),
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

  /// The kiosk's slot policy resolved into a row tile: exactly one action
  /// (book a free slot for the selected player, under the same
  /// create_reservation mirror the app uses), never cancel. "Mine" is the
  /// selected player.
  Widget _laneRow(
    OpenDay day,
    TimeBlock block,
    int lane, {
    required ScheduleSettings settings,
    required Map<String, String> nameById,
    required Map<String, int> clubColorById,
    required bool interactive,
    required int selectedCount,
  }) {
    final selected = widget.selected;
    final state = day.slot(block.id, lane);
    switch (state) {
      case RentedSlot():
      case PrioritySlotState():
        return SlotTile(state: state, size: SlotTileSize.row, laneDigit: lane);
      case ReservedSlot(:final reservation):
        return SlotTile(
          state: state,
          size: SlotTileSize.row,
          laneDigit: lane,
          playerName: nameById[reservation.playerId] ?? '?',
          isMine: selected != null && reservation.playerId == selected.id,
          clubColorIndex: clubColorById[reservation.playerId] ?? -1,
        );
      case FreeSlot():
        final bookable = interactive &&
            selected != null &&
            canBook(
              state: state,
              myActiveCount: selectedCount,
              settings: settings,
            );
        return SlotTile(
          state: state,
          size: SlotTileSize.row,
          laneDigit: lane,
          onTap: bookable
              ? () => _book(context, ref, day.date, block, lane, selected)
              : null,
        );
    }
  }
}
