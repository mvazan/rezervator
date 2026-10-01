/// The „Hlídat uvolněná místa“ bell next to a day's free-spot count (0058):
/// on, the server pushes a notice when somebody cancels a training that day
/// and the player could book it. The state is `slot_watches` (own rows), so
/// the bell shows the same on every device and flips back by itself when a
/// booking that day ends the watch.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/models.dart';

/// What a first tap promises, as a quiet snack.
const dayWatchOnMessage =
    'Dám ti vědět, až se ten den uvolní místo. Rezervace dne hlídání ukončí.';

/// Only the signed-in player's calendar gets the bell, for the days that can
/// still free a bookable spot: [date] from [today] on, and — except for an
/// admin, who books beyond it — inside the booking horizon. Not on the
/// kiosk, nor on the public overview ([interactive] false there).
bool canWatchDay({
  required Day date,
  required Day today,
  required ScheduleSettings settings,
  required Profile? me,
  required bool interactive,
}) =>
    interactive &&
    me != null &&
    me.role != Role.kiosk &&
    !date.isBefore(today) &&
    (me.isAdmin || !date.isAfter(today.addDays(settings.bookingHorizonDays)));

class DayWatchButton extends ConsumerWidget {
  const DayWatchButton({
    super.key,
    required this.date,
    this.size = 22,
    this.dense = false,
    this.color,
    this.watch = Api.watchDay,
    this.unwatch = Api.unwatchDay,
  });

  final Day date;

  /// Icon size: the narrow board header uses a smaller one.
  final double size;

  /// A plain tappable icon with no 40dp button around it, for the board
  /// header's one quiet line.
  final bool dense;

  /// The icon's colour when off; null = the theme's.
  final Color? color;

  /// Injectable for widget tests (the Api ones need a live Supabase client).
  final Future<void> Function(Day day) watch;
  final Future<void> Function(Day day) unwatch;

  Future<void> _toggle(BuildContext context, bool watching) async {
    if (watching) {
      await tryAction(
        context,
        () => unwatch(date),
        errorText: friendlyDbError,
      );
    } else {
      await tryAction(
        context,
        () => watch(date),
        success: dayWatchOnMessage,
        errorText: friendlyDbError,
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final watching = ref.watch(myDayWatchesProvider).value?.contains(date) ??
        false;
    final scheme = Theme.of(context).colorScheme;
    final tooltip = watching
        ? 'Hlídáš uvolněná místa — vypnout'
        : 'Hlídat uvolněná místa';
    final icon = Icon(
      watching ? Icons.notifications_active : Icons.notifications_none,
      size: size,
      color: watching ? scheme.primary : color,
    );
    // The board header's quiet line has no room for a 40dp button: a plain
    // tappable icon there.
    if (dense) {
      return Tooltip(
        message: tooltip,
        child: InkResponse(
          radius: size,
          onTap: () => _toggle(context, watching),
          child: Padding(padding: const EdgeInsets.all(3), child: icon),
        ),
      );
    }
    return IconButton(
      icon: icon,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(width: size + 14, height: size + 14),
      onPressed: () => _toggle(context, watching),
    );
  }
}
