/// The pieces of Klubovna → Služby (0050): my duty card, who serves now and
/// one period of the plan, mine highlighted.
library;

import 'package:flutter/material.dart';

import '../../../domain/duties.dart';
import '../../../domain/models.dart';

/// My current or next duty, tinted `secondaryContainer`: „Právě sloužíš —
/// do ne 11. 10.“ with „spolu s: …“, or „Tvoje příští služba: …“; plus
/// the reminder's lead when the admin switched it on and a next duty is
/// ahead to be reminded of.
class MyDutyCard extends StatelessWidget {
  const MyDutyCard({
    super.key,
    required this.duty,
    this.coNames = const [],
    this.reminderDays,
  });

  /// Has a [MyDuty.current] or a [MyDuty.next].
  final MyDuty duty;

  /// The others on my current duty, Czech-sorted.
  final List<String> coNames;

  /// The reminder's lead in days; null while the reminder is off.
  final int? reminderDays;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = duty.current;
    final title = current != null
        ? 'Právě sloužíš — do ${dutyDayLabel(current.endsOn)}'
        : 'Tvoje příští služba: ${dutyRangeLabel(duty.next!)}';
    final lines = [
      if (current != null && coNames.isNotEmpty)
        'spolu s: ${joinNames(coNames)}',
      // Only a duty that has not started is reminded of.
      if (reminderDays case final days? when duty.next != null)
        'Připomínku dostaneš ${dutyLeadLabel(days)} předem.',
    ];
    return Card(
      color: scheme.secondaryContainer,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.local_cafe_outlined, color: scheme.onSecondaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                  for (final line in lines) ...[
                    const SizedBox(height: 4),
                    Text(
                      line,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// „Teď slouží: Jana Nováková a Petr Svoboda“ with „do ne 11. 10.“.
class NowServingCard extends StatelessWidget {
  const NowServingCard({super.key, required this.period, required this.names});

  final DutyPeriod period;

  /// Who serves, in display order („ty“ first, then Czech-sorted).
  final List<String> names;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
    child: ListTile(
      leading: const Icon(Icons.groups_outlined),
      title: Text('Teď slouží: ${joinNames(names)}'),
      subtitle: Text('do ${dutyDayLabel(period.endsOn)}'),
    ),
  );
}

/// One period of the plan: „po 12. 10. – ne 18. 10. · posvícení“ and its
/// players, Czech-sorted. Mine gets a 4dp `primary` stripe on the leading
/// edge, „ty“ in w700 first and the chip „Tvoje služba“; everyone else's
/// stays plain (a transparent stripe keeps the rows aligned).
class DutyRosterTile extends StatelessWidget {
  const DutyRosterTile({
    super.key,
    required this.period,
    required this.mine,
    this.others = const [],
  });

  final DutyPeriod period;

  /// I am assigned to it.
  final bool mine;

  /// The other players' names, Czech-sorted, me left out.
  final List<String> others;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = period.note.isEmpty
        ? dutyRangeLabel(period)
        : '${dutyRangeLabel(period)} · ${period.note}';
    final Widget subtitle = !mine && others.isEmpty
        ? Text('Neobsazeno', style: TextStyle(color: scheme.onSurfaceVariant))
        : Text.rich(
            TextSpan(
              children: [
                if (mine)
                  const TextSpan(
                    text: 'ty',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                if (mine && others.isNotEmpty) const TextSpan(text: ', '),
                if (others.isNotEmpty) TextSpan(text: others.join(', ')),
              ],
            ),
          );
    return Container(
      key: mine ? ValueKey('duty-mine-${period.id}') : null,
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: mine ? scheme.primary : Colors.transparent,
            width: 4,
          ),
        ),
      ),
      child: ListTile(
        title: Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(title),
            if (mine)
              Chip(
                label: const Text('Tvoje služba'),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                labelStyle: TextStyle(
                  fontSize: 11,
                  color: scheme.onPrimaryContainer,
                ),
                backgroundColor: scheme.primaryContainer,
                side: BorderSide.none,
              ),
          ],
        ),
        subtitle: subtitle,
      ),
    );
  }
}
