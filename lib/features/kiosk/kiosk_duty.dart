/// The canteen duty on the kiosk (0073): who serves now and who comes next,
/// read from the plan of Správa → Služby. The admin switches each place on
/// separately (Správa → Kiosk → Služby v kantýně): the status bar's line
/// under the date ([KioskDutyLine]), a band across the board's day headers
/// and a card in the side drawer. A tap on any of them opens the plan
/// ([showKioskDutyDialog]). Display only — duties are edited in the app.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/duties.dart';
import '../../domain/models.dart';

/// The roster's display names by user id, placeholders included — what
/// [kioskDutyPlan] and [kioskDutyOn] look the assignees up in.
final kioskDutyNamesProvider = Provider<Map<String, String>>((ref) {
  final players = ref.watch(playersProvider).value ?? const [];
  return {for (final p in players) p.id: p.displayName};
});

/// The kiosk's duty plan over the app clock's today (see [kioskDutyPlan]):
/// who serves now and the next five. Follows midnight with no row
/// changing; the minute tick does not reach it.
final kioskDutyPlanProvider =
    Provider<({KioskDutyEntry? now, List<KioskDutyEntry> next})>((ref) {
      final today = ref.watch(
        nowProvider.select(
          (now) => Day.fromDateTime(now.value ?? DateTime.now()),
        ),
      );
      return kioskDutyPlan(
        ref.watch(dutyPeriodsProvider).value ?? const [],
        ref.watch(dutyAssignmentsProvider).value ?? const [],
        ref.watch(kioskDutyNamesProvider),
        today,
      );
    });

/// The status bar's duty line („V záhlaví“): „Služba: Jan Novák a Petr
/// Svoboda“ with a cup, tinted `secondaryContainer`, one line of at most
/// [maxWidth] — a long list of names is cut, the clock column stays
/// narrow. A tap opens the plan ([onTap]).
class KioskDutyLine extends StatelessWidget {
  const KioskDutyLine({super.key, required this.entry, required this.onTap});

  static const maxWidth = 420.0;

  /// Today's duty.
  final KioskDutyEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: maxWidth),
      child: Material(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.local_cafe_outlined,
                  size: 16,
                  color: scheme.onSecondaryContainer,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    'Služba: ${entry.who}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens „Služby v kantýně“ over the kiosk. [wrap] is the shell's: it gives
/// the dialog the kiosk's theme and counts a touch on it for the idle timer
/// — whose reset closes it, with every other dialog.
Future<void> showKioskDutyDialog(
  BuildContext context, {
  required Widget Function(Widget child) wrap,
}) => showDialog<void>(
  context: context,
  builder: (context) => wrap(const KioskDutyDialog()),
);

/// The plan: who serves now as a tinted block — left out while nobody
/// does — then the next ones, date order, each its range on the left and
/// its names on the right. Watches [kioskDutyPlanProvider], so a dialog
/// left open flips at midnight with the rest of the kiosk.
class KioskDutyDialog extends ConsumerWidget {
  const KioskDutyDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final plan = ref.watch(kioskDutyPlanProvider);
    final now = plan.now;
    return AlertDialog(
      title: const Text('Služby v kantýně'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (now != null) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.local_cafe_outlined,
                        color: scheme.onSecondaryContainer,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Teď slouží: ${now.who}',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: scheme.onSecondaryContainer,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              now.range,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSecondaryContainer,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
              if (plan.next.isEmpty)
                Text(
                  'Další služby zatím nejsou naplánované.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                )
              else ...[
                Text('Další', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                for (final (i, entry) in plan.next.indexed) ...[
                  if (i > 0) const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(entry.range),
                        const SizedBox(width: 16),
                        // A long list of names wraps under itself; the
                        // range keeps its line.
                        Expanded(
                          child: Text(
                            entry.who,
                            textAlign: TextAlign.end,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Zavřít'),
        ),
      ],
    );
  }
}
