import 'package:flutter/material.dart';

import '../../../domain/models.dart';
import '../../../domain/palette.dart';
import '../../../domain/schedule.dart';

/// One vertical item of a day's grid: a block row, an off-block event banner,
/// or an empty internal gap between blocks. The renderers walk this list in
/// order, so the calendar shows time gaps honestly instead of stacking
/// blocks flush.
sealed class DayGridItem {
  const DayGridItem();
}

class BlockItem extends DayGridItem {
  const BlockItem(this.block);

  final TimeBlock block;
}

class EventItem extends DayGridItem {
  const EventItem(this.event);

  final OffBlockEvent event;
}

/// An event-free hole between two consecutive blocks — renders as a thin
/// seam, or (admin) an add-block affordance prefilled with the hole's range.
class EmptyGapItem extends DayGridItem {
  const EmptyGapItem(this.start, this.end);

  final HourMinute start;
  final HourMinute end;
}

/// Interleaves a day's blocks with its off-block events (at their true
/// position in time order) and marks event-free holes between consecutive
/// blocks. Leading/trailing holes never appear on their own — only events
/// extend the day beyond its blocks.
List<DayGridItem> dayGridItems(DaySchedule day) {
  final blocks = switch (day) {
    OpenDay(:final blocks) => blocks,
    ClosedDay() => const <TimeBlock>[],
  };
  final events = offBlockEvents(
    priority: day.priority,
    rentals: day.rentals,
    blocks: blocks,
  );

  final items = <DayGridItem>[];
  var e = 0;
  // Emits every event starting before [minutes]; returns whether any did.
  bool emitEventsBefore(int minutes) {
    var any = false;
    while (e < events.length &&
        events[e].start.minutesFromMidnight < minutes) {
      items.add(EventItem(events[e++]));
      any = true;
    }
    return any;
  }

  int? runningEnd;
  for (final b in blocks) {
    final s = b.startsAt.minutesFromMidnight;
    final hadEvents = emitEventsBefore(s);
    if (runningEnd != null && s > runningEnd && !hadEvents) {
      items.add(EmptyGapItem(
        HourMinute(runningEnd ~/ 60, runningEnd % 60),
        b.startsAt,
      ));
    }
    items.add(BlockItem(b));
    final end = b.endsAt.minutesFromMidnight;
    if (runningEnd == null || end > runningEnd) runningEnd = end;
  }
  emitEventsBefore(24 * 60);
  return items;
}

/// Full-width banner for an off-block match/rental, showing its real times.
class GapEventBanner extends StatelessWidget {
  const GapEventBanner({super.key, required this.event, this.compact = true});

  final OffBlockEvent event;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground, text) = switch (event) {
      OffBlockPriority(:final slot) => (
          ClubColors.of(slot.type.colorIndex, scheme.brightness)?.$1 ??
              scheme.errorContainer.withValues(alpha: 0.6),
          ClubColors.of(slot.type.colorIndex, scheme.brightness)?.$2 ??
              scheme.onErrorContainer,
          '${slot.type.isMatch ? '🏆' : '⛔'} ${slot.title} · '
              '${slot.startsAt.display()}–${slot.endsAt.display()}',
        ),
      OffBlockRental(:final rental) => (
          ClubColors.of(rental.color, scheme.brightness)?.$1 ??
              scheme.tertiaryContainer.withValues(alpha: 0.5),
          ClubColors.of(rental.color, scheme.brightness)?.$2 ??
              scheme.onTertiaryContainer,
          '🔒 ${rental.renterName} · '
              '${rental.startsAt.display()}–${rental.endsAt.display()}',
        ),
    };
    return Container(
      constraints: const BoxConstraints(minHeight: 36),
      // Bottom matches the lane rows' own 10px bottom padding, so a banner
      // and the block row under it don't visually fuse.
      margin: EdgeInsets.only(top: 3, bottom: compact ? 3 : 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Text(
        text,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: compact ? 12 : 13,
          fontWeight: FontWeight.w600,
          color: foreground,
        ),
      ),
    );
  }
}

/// An event-free hole between blocks. Non-admin: a 10px faint seam keeping
/// the calendar time-honest. Admin ([onAdd] non-null): a 20px tappable strip
/// with a faint ＋ that opens the add-block flow prefilled with the range.
class EmptyGapRow extends StatelessWidget {
  const EmptyGapRow({super.key, required this.item, this.onAdd});

  final EmptyGapItem item;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (onAdd == null) {
      return Container(
        height: 10,
        margin: const EdgeInsets.symmetric(vertical: 1),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(4),
        ),
      );
    }
    return Semantics(
      button: true,
      label: 'Přidat blok',
      child: InkWell(
        onTap: onAdd,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          height: 20,
          margin: const EdgeInsets.symmetric(vertical: 1),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
          child: Text(
            '＋ ${item.start.display()}–${item.end.display()}',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
        ),
      ),
    );
  }
}
