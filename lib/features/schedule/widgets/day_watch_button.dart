/// The „Hlídat uvolněná místa“ bell next to a day's free-spot count (0058):
/// on, the server pushes a notice when somebody cancels a training that day
/// and the player could book it. A tap opens a sheet to watch the whole day
/// or just the blocks the player picks. The state is `slot_watches` (own rows), so
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

/// The blocks of [date] still worth watching: for today those that have not
/// started ([now]); nothing can be booked in a block that has.
List<TimeBlock> watchableBlocks(
  List<TimeBlock> blocks, {
  required Day date,
  required Day today,
  required HourMinute now,
}) => [
  for (final b in blocks)
    if (date != today || b.startsAt.compareTo(now) > 0) b,
];

class DayWatchButton extends ConsumerWidget {
  const DayWatchButton({
    super.key,
    required this.date,
    required this.blocks,
    this.size = 22,
    this.dense = false,
    this.color,
    this.watch = _watchDay,
    this.unwatch = Api.unwatchDay,
  });

  final Day date;

  /// The blocks to pick from ([watchableBlocks]); none = no bell.
  final List<TimeBlock> blocks;

  /// Icon size: the narrow board header uses a smaller one.
  final double size;

  /// A plain tappable icon with no 40dp button around it, for the board
  /// header's one quiet line.
  final bool dense;

  /// The icon's colour when off; null = the theme's.
  final Color? color;

  /// Injectable for widget tests (the Api ones need a live Supabase client).
  final Future<void> Function(Day day, Set<String> blocks) watch;
  final Future<void> Function(Day day) unwatch;

  static Future<void> _watchDay(Day day, Set<String> blocks) =>
      Api.watchDay(day, blocks: blocks);

  Future<void> _open(BuildContext context, Set<String>? watching) async {
    final choice = await showModalBottomSheet<DayWatchChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          DayWatchSheet(date: date, blocks: blocks, watching: watching),
    );
    if (choice == null || !context.mounted) return;
    if (!choice.on) {
      await tryAction(context, () => unwatch(date), errorText: friendlyDbError);
    } else {
      await tryAction(
        context,
        () => watch(date, choice.blocks),
        success: dayWatchOnMessage,
        errorText: friendlyDbError,
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (blocks.isEmpty) return const SizedBox.shrink();
    final watching = ref.watch(myDayWatchesProvider).value?[date];
    final on = watching != null;
    final scheme = Theme.of(context).colorScheme;
    final tooltip = on ? 'Hlídáš uvolněná místa' : 'Hlídat uvolněná místa';
    final icon = Icon(
      on ? Icons.notifications_active : Icons.notifications_none,
      size: size,
      color: on ? scheme.primary : color,
    );
    // Room around the bell, so a tap meant for the chip or the ⋮ beside it
    // does not land on it.
    if (dense) {
      return Tooltip(
        message: tooltip,
        child: InkResponse(
          radius: size,
          onTap: () => _open(context, watching),
          child: Padding(padding: const EdgeInsets.all(5), child: icon),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: IconButton(
        icon: icon,
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: BoxConstraints.tightFor(
          width: size + 14,
          height: size + 14,
        ),
        onPressed: () => _open(context, watching),
      ),
    );
  }
}

/// What the sheet answered: watch ([blocks] empty = the whole day) or stop.
class DayWatchChoice {
  const DayWatchChoice.watch(this.blocks) : on = true;
  const DayWatchChoice.stop() : on = false, blocks = const {};

  final bool on;
  final Set<String> blocks;
}

/// The bell's sheet: „Celý den“, or the blocks of the day to pick from. With
/// nothing picked it is the whole day, so the player who wants no more than
/// the bell taps „Hlídat“ at once. [watching]: the blocks of the current
/// watch (empty = the whole day), null when there is none.
class DayWatchSheet extends StatefulWidget {
  const DayWatchSheet({
    super.key,
    required this.date,
    required this.blocks,
    required this.watching,
  });

  final Day date;
  final List<TimeBlock> blocks;
  final Set<String>? watching;

  @override
  State<DayWatchSheet> createState() => _DayWatchSheetState();
}

class _DayWatchSheetState extends State<DayWatchSheet> {
  late final Set<String> _picked = {
    for (final b in widget.blocks)
      if (widget.watching?.contains(b.id) ?? false) b.id,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final watching = widget.watching != null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Hlídat uvolněná místa', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '${dayFull(widget.date)}. Dáme ti vědět, když se někdo odhlásí '
              'a ty by sis mohl místo zarezervovat.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilterChip(
                  label: const Text('Celý den'),
                  selected: _picked.isEmpty,
                  onSelected: (_) => setState(_picked.clear),
                ),
                for (final b in widget.blocks)
                  FilterChip(
                    label: Text(b.label),
                    selected: _picked.contains(b.id),
                    onSelected: (on) => setState(() {
                      if (on) {
                        _picked.add(b.id);
                      } else {
                        _picked.remove(b.id);
                      }
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 12,
              runSpacing: 12,
              children: [
                if (watching)
                  TextButton(
                    onPressed: () =>
                        Navigator.of(context).pop(const DayWatchChoice.stop()),
                    child: const Text('Přestat hlídat'),
                  ),
                FilledButton(
                  onPressed: () =>
                      Navigator.of(context).pop(DayWatchChoice.watch({..._picked})),
                  child: Text(watching ? 'Uložit' : 'Hlídat'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
