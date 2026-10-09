/// A request to show one spot of the calendar — what a „uvolnilo se místo“
/// push asks for: the week and the day of the spot, and its cell outlined
/// while it is still free. A push about a reservation made for the player
/// (kiosk, group mate, duty) asks the same for that reservation: its cell
/// outlined while it is still booked. A plain provider, because the tap arrives in
/// [HomeShell] and the week it moves belongs to [WeekScreen].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';

class CalendarFocus {
  const CalendarFocus({
    required this.date,
    this.blockId,
    this.lane,
    this.reservationId,
    this.handled = false,
    this.highlight = false,
  });

  final Day date;

  /// The spot; null for an older push that named only the day.
  final String? blockId;
  final int? lane;

  /// A booking made for the player: the reservation the spot should hold. Null for a freed
  /// spot, which should be free instead.
  final String? reservationId;

  /// The screen has moved to [date] and said what it found.
  final bool handled;

  /// The spot is as the push said (free, or holding [reservationId]): its
  /// cell is outlined until the focus is cleared.
  final bool highlight;

  CalendarFocus copyWith({bool? handled, bool? highlight}) => CalendarFocus(
    date: date,
    blockId: blockId,
    lane: lane,
    reservationId: reservationId,
    handled: handled ?? this.handled,
    highlight: highlight ?? this.highlight,
  );
}

class CalendarFocusNotifier extends Notifier<CalendarFocus?> {
  @override
  CalendarFocus? build() => null;

  void request(CalendarFocus focus) => state = focus;

  void markHandled({required bool highlight}) {
    final f = state;
    if (f != null) state = f.copyWith(handled: true, highlight: highlight);
  }

  void clear() => state = null;
}

final calendarFocusProvider =
    NotifierProvider<CalendarFocusNotifier, CalendarFocus?>(
      CalendarFocusNotifier.new,
    );

/// Outlines [child] while the focus points at this very cell.
class CellHighlight extends ConsumerWidget {
  const CellHighlight({
    super.key,
    required this.date,
    required this.blockId,
    required this.lane,
    required this.child,
  });

  final Day date;
  final String blockId;
  final int lane;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(
      calendarFocusProvider.select(
        (f) =>
            f != null &&
            f.highlight &&
            f.date == date &&
            f.blockId == blockId &&
            f.lane == lane,
      ),
    );
    if (!on) return child;
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary,
          width: 3,
        ),
      ),
      child: child,
    );
  }
}
