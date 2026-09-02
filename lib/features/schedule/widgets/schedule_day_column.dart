/// One day column of a calendar board — shared by the app's week calendar
/// and the kiosk board. The day's blocks render as cards at their true time
/// with one lane row each (the row itself comes from the board through
/// [ScheduleDayColumn.laneRow] — the app resolves its booking/cancel policy
/// into compact [SlotTile]s, the kiosk into row tiles); off-block
/// matches/rentals render as bands at their true time; a closed day dims
/// the whole column behind a vertical "✕ zavřeno[ — reason]" (matches still
/// render on top — spectators want to see who plays).
///
/// Admin gestures are optional hooks: tap empty space to add (prefilled
/// with the free gap), click a card header or a band to edit, HOLD a card
/// or band and drag it onto empty space of the same day to move it (snap
/// 5 min, live od–do preview on the ghost). With no hooks the column is
/// read-only — that is the kiosk.
library;

import 'package:flutter/material.dart';

import '../../../domain/calendar_layout.dart';
import '../../../domain/labels.dart';
import '../../../domain/models.dart';
import '../../../domain/palette.dart';
import '../../../domain/schedule.dart';
import '../schedule_callbacks.dart';
import 'calendar_board.dart';

/// A 60-minute block gets this much height per lane at the comfortable
/// scale (the app's week view; the kiosk's "comfortable scroll" mode).
const double laneRowRefHeight = 40.0;

/// Height of a block card's od–do header row.
const double blockCardHeaderHeight = 14.0;

/// Drag&drop payloads: what a held card/band carries to the drop target.
/// [hoverMinute] is the live-preview channel: the hovered column publishes
/// the snapped would-be start minute, the drag ghost renders it as od–do.
class BlockDragData {
  BlockDragData(this.date, this.block);
  final Day date;
  final TimeBlock block;
  final ValueNotifier<int?> hoverMinute = ValueNotifier(null);
}

class SlotDragData {
  SlotDragData(this.slot);
  final PrioritySlot slot;
  final ValueNotifier<int?> hoverMinute = ValueNotifier(null);
}

/// D&D snap grid: 5 minutes.
int _snapMinute(int minute) => ((minute + 2) ~/ 5) * 5;

/// Renders one lane row inside a block card; the board decides what a
/// slot state looks like and what a tap does.
typedef LaneRowBuilder = Widget Function(
    BuildContext context, OpenDay day, TimeBlock block, int lane);

class ScheduleDayColumn extends StatelessWidget {
  const ScheduleDayColumn({
    super.key,
    required this.day,
    required this.window,
    required this.pxPerMinute,
    required this.halfHourMarks,
    required this.nowMinute,
    required this.laneRow,
    this.admin = CalendarAdminHooks.none,
  });

  final DaySchedule day;
  final CalendarWindow window;
  final double pxPerMinute;
  final bool halfHourMarks;

  /// Minutes from midnight to draw the "now" line at (today's column only),
  /// already known to lie inside the window.
  final int? nowMinute;
  final LaneRowBuilder laneRow;

  /// Admin gestures ([CalendarAdminHooks.none] = read-only column; the
  /// header-level onAddForDay is the board's business, not the column's).
  final CalendarAdminHooks admin;

  void Function(Day date, TimeBlock block)? get onEditBlock =>
      admin.onEditBlock;
  void Function(Day date, HourMinute start, HourMinute end)?
      get onAddBlockInGap => admin.onAddBlockInGap;
  void Function(Day date, PrioritySlot slot)? get onEditPrioritySlot =>
      admin.onEditPrioritySlot;
  void Function(Day date, Rental rental)? get onEditRental =>
      admin.onEditRental;
  void Function(Day date, TimeBlock block, HourMinute newStart)?
      get onMoveBlock => admin.onMoveBlock;
  void Function(Day date, PrioritySlot slot, HourMinute newStart)?
      get onMovePrioritySlot => admin.onMovePrioritySlot;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final openDay = day is OpenDay ? day as OpenDay : null;

    // Everything this day already shows — blocks AND event bands. Taps on
    // free space prefill the add-block dialog with the surrounding gap, so
    // "occupied" must include event bands or the prefill would overlap a
    // visible rental/match.
    final occupied = mergeIntervals([
      if (openDay != null)
        for (final b in openDay.blocks)
          (b.startsAt.minutesFromMidnight, b.endsAt.minutesFromMidnight),
      for (final m in day.priority)
        (m.startsAt.minutesFromMidnight, m.endsAt.minutesFromMidnight),
      if (openDay != null)
        for (final r in openDay.rentals)
          (r.startsAt.minutesFromMidnight, r.endsAt.minutesFromMidnight),
    ]);

    final onTapFree = onAddBlockInGap == null
        ? null
        : (int minute) {
            final gap = freeGapAt(minute, occupied, window);
            if (gap == null) return;
            onAddBlockInGap!(
                day.date, hourMinuteAt(gap.$1), hourMinuteAt(gap.$2));
          };

    // Drag&drop landing: snap the ghost's top edge to 5 minutes and only
    // accept when the whole slot (a match brings its úklid child along)
    // fits into free space of THIS day — the landing rule is [dropFits].
    void handleDrop(Object data, int minute) {
      final snapped = _snapMinute(minute);
      (int, int)? candidate;
      void Function()? commit;
      List<(int, int)> self = const [];
      if (data is BlockDragData && data.date == day.date) {
        final dur = data.block.durationMinutes;
        candidate = (snapped, snapped + dur);
        self = [
          (
            data.block.startsAt.minutesFromMidnight,
            data.block.endsAt.minutesFromMidnight
          )
        ];
        commit = () =>
            onMoveBlock?.call(day.date, data.block, hourMinuteAt(snapped));
      } else if (data is SlotDragData && data.slot.date == day.date) {
        final s = data.slot;
        final dur = s.endsAt.minutesFromMidnight - s.startsAt.minutesFromMidnight;
        final child = day.priority
            .where((m) => m.parentId == s.id)
            .firstOrNull;
        final childDur = child == null
            ? 0
            : child.endsAt.minutesFromMidnight -
                child.startsAt.minutesFromMidnight;
        candidate = (snapped - childDur, snapped + dur);
        self = [
          (s.startsAt.minutesFromMidnight, s.endsAt.minutesFromMidnight),
          if (child != null)
            (
              child.startsAt.minutesFromMidnight,
              child.endsAt.minutesFromMidnight
            ),
        ];
        commit = () =>
            onMovePrioritySlot?.call(day.date, s, hourMinuteAt(snapped));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Přesun jde jen v rámci stejného dne.')));
        return;
      }
      final fits = dropFits(
        candidate: candidate,
        self: self,
        occupied: occupied,
        window: window,
      );
      if (!fits) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Tady není volné místo.')));
        return;
      }
      commit();
    }

    final canMove = onMoveBlock != null || onMovePrioritySlot != null;

    // Live drop-time preview: publish the snapped minute to the payload's
    // notifier while its ghost hovers over THIS day's column (a foreign
    // day would refuse the drop, so it previews nothing).
    ValueNotifier<int?>? hoverOf(Object data) => switch (data) {
          BlockDragData d when d.date == day.date => d.hoverMinute,
          SlotDragData d when d.slot.date == day.date => d.hoverMinute,
          _ => null,
        };
    void handleDragAt(Object data, int minute) =>
        hoverOf(data)?.value = _snapMinute(minute);
    void handleDragExit(Object data) => hoverOf(data)?.value = null;

    return CalendarColumn(
      window: window,
      pxPerMinute: pxPerMinute,
      halfHourMarks: halfHourMarks,
      entries: _entries(context, openDay),
      background: openDay == null ? _closedBackground(context, scheme) : null,
      nowMinute: nowMinute,
      onTapFreeAt: onTapFree,
      onDropAt: canMove ? handleDrop : null,
      onDragAt: canMove ? handleDragAt : null,
      onDragExit: canMove ? handleDragExit : null,
    );
  }

  List<CalendarEntry> _entries(BuildContext context, OpenDay? openDay) {
    final entries = <CalendarEntry>[];
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
    final scheme = Theme.of(context).colorScheme;
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

    for (final m in day.priority) {
      final (bg, fg) = clubTint(m.type.colorIndex, scheme.brightness,
          fallbackBg: scheme.errorContainer.withValues(alpha: 0.6),
          fallbackFg: scheme.onErrorContainer);
      Widget band() {
        Widget w = CalendarEventBand(
          background: bg,
          foreground: fg,
          text: '${slotEventLabel(m)}\n'
              '${m.startsAt.display()}–${m.endsAt.display()}',
          bold: true,
        );
        // Click = edit (a click has nothing else to do on a blocking band);
        // an úklid child edits its parent match.
        if (onEditPrioritySlot != null) {
          w = InkWell(
            onTap: () => onEditPrioritySlot!(day.date, m),
            child: w,
          );
        }
        // HOLD = move. Úklid children follow their match, they don't move
        // on their own.
        if (onMovePrioritySlot != null && m.parentId == null) {
          final data = SlotDragData(m);
          w = _draggable(
            context,
            data: data,
            hoverMinute: data.hoverMinute,
            label: m.title,
            heightMinutes: m.endsAt.minutesFromMidnight -
                m.startsAt.minutesFromMidnight,
            child: w,
          );
        }
        return w;
      }

      addBands(m.startsAt, m.endsAt, band);
    }
    if (openDay != null) {
      // Copied to a local: a getter never promotes on the null check.
      final edit = onEditRental;
      for (final r in openDay.rentals) {
        final (bg, fg) = clubTint(r.color, scheme.brightness,
            fallbackBg: scheme.tertiaryContainer.withValues(alpha: 0.5),
            fallbackFg: scheme.onTertiaryContainer);
        Widget band() {
          Widget w = CalendarEventBand(
            background: bg,
            foreground: fg,
            text: '${rentalLabel(r)}\n'
                '${r.startsAt.display()}–${r.endsAt.display()}',
          );
          // Click = edit that day's occurrence (a weekly rental's "jen
          // tento den" exception, a one-time rental's plain dialog).
          if (edit != null) {
            w = InkWell(onTap: () => edit(day.date, r), child: w);
          }
          return w;
        }

        addBands(r.startsAt, r.endsAt, band);
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

  /// One block's calendar card: a thin time header ('17:30–18:30' — for
  /// admins a click-to-edit target) over one lane row per lane. Whole-alley
  /// priority slots never reach a rendered block (they cancel overlapping
  /// blocks in buildWeekSchedule and render as true-time bands); lane-scoped
  /// slots resolve per lane row. Admins HOLD the card to drag it onto empty
  /// space (same-day move).
  Widget _blockCard(BuildContext context, OpenDay openDay, TimeBlock block) {
    final scheme = Theme.of(context).colorScheme;

    // Same ground as the card — the header is typography, not a bar: quiet
    // spaced small-caps-like digits that read as a label, not a stripe.
    final headerText = Text(
      block.label,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 9,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.8,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
      ),
    );
    final header = Container(
      height: blockCardHeaderHeight,
      alignment: Alignment.center,
      child: onEditBlock == null
          ? headerText
          : InkWell(
              onTap: () => onEditBlock!(openDay.date, block),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  headerText,
                  const SizedBox(width: 3),
                  Icon(
                    Icons.edit_outlined,
                    size: 9,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
                  ),
                ],
              ),
            ),
    );

    final card = Container(
      // Stable per-block key (unique among one column's entries) so tests
      // can measure card geometry and target gestures.
      key: ValueKey('cal-block-${block.id}'),
      // The 1.5px vertical inset matches CalendarEventBand's, so a band and
      // a touching block card keep a visible seam between them.
      margin: const EdgeInsets.symmetric(horizontal: 1, vertical: 1.5),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          header,
          Expanded(
            child: Column(
              children: [
                for (var lane = 1; lane <= openDay.laneCount; lane++)
                  Expanded(child: laneRow(context, openDay, block, lane)),
              ],
            ),
          ),
        ],
      ),
    );
    if (onMoveBlock == null) return card;
    final data = BlockDragData(openDay.date, block);
    return _draggable(
      context,
      data: data,
      hoverMinute: data.hoverMinute,
      label: block.label,
      heightMinutes: block.durationMinutes,
      child: card,
    );
  }

  /// HOLD-to-drag wrapper shared by cards and bands: the ghost is a simple
  /// tinted box of the slot's true size so the admin can align its top
  /// edge with the target time — which it live-previews as 'od–do' from
  /// [hoverMinute] (published by the hovered column, see handleDragAt).
  Widget _draggable(
    BuildContext context, {
    required Object data,
    required ValueNotifier<int?> hoverMinute,
    required String label,
    required int heightMinutes,
    required Widget child,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => LongPressDraggable<Object>(
        data: data,
        delay: const Duration(milliseconds: 200),
        feedback: Material(
          color: Colors.transparent,
          child: Container(
            width: constraints.maxWidth,
            height: heightMinutes * pxPerMinute,
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.75),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.primary),
            ),
            alignment: Alignment.center,
            child: ValueListenableBuilder<int?>(
              valueListenable: hoverMinute,
              builder: (context, minute, _) => Text(
                minute == null
                    ? label
                    : '${hourMinuteAt(minute).display()}–'
                        '${hourMinuteAt(minute + heightMinutes).display()}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.35, child: child),
        child: child,
      ),
    );
  }
}
