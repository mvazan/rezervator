/// Správa → Služby → Historie (0050): the seasons as chips in chronological
/// order, and for the chosen one its duties and overview, read-only. A new
/// season moves nothing, so every earlier one is still here whole.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/duties.dart';
import '../../domain/models.dart';
import 'widgets/admin_scaffold.dart';
import 'widgets/duty_parts.dart';

class DutiesHistoryScreen extends ConsumerStatefulWidget {
  const DutiesHistoryScreen({super.key});

  @override
  ConsumerState<DutiesHistoryScreen> createState() =>
      _DutiesHistoryScreenState();
}

class _DutiesHistoryScreenState extends ConsumerState<DutiesHistoryScreen> {
  /// Whether the admin tapped a chip yet; until then the default season
  /// shows.
  bool _picked = false;

  /// The tapped season by its first day (null for the implicit first one).
  Day? _pickedFrom;

  @override
  Widget build(BuildContext context) {
    final today = watchDutyToday(ref);
    final value = watchDutyData(ref);
    return AdminScaffold(
      title: 'Historie služeb',
      body: AsyncBody(
        value: value,
        onRetry: () => refreshDutyData(ref),
        builder: (data) {
          final all = seasonRanges(data.seasons);
          final current = currentSeason(all, today);
          // The implicit first season only when it is the current one or
          // something happened in it — otherwise a chip for nothing.
          final ranges = [
            for (final r in all)
              if (!r.isImplicit ||
                  identical(r, current) ||
                  data.periods.any(r.containsPeriod))
                r,
          ];
          // By default the season before this one — what Historie is
          // opened for — or this one when there is no earlier.
          final at = ranges.indexOf(current);
          final byDefault = at > 0 ? ranges[at - 1] : current;
          final chosen = _picked
              ? ranges.firstWhere(
                  (r) => r.from == _pickedFrom,
                  orElse: () => byDefault,
                )
              : byDefault;
          final periods = [
            for (final p in data.periods)
              if (chosen.containsPeriod(p)) p,
          ];
          final byId = {for (final p in data.profiles) p.id: p};
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    for (final (i, r) in ranges.indexed) ...[
                      if (i > 0) const SizedBox(width: 8),
                      ChoiceChip(
                        label: Text(seasonLabel(r)),
                        selected: identical(r, chosen),
                        onSelected: (_) => setState(() {
                          _picked = true;
                          _pickedFrom = r.from;
                        }),
                      ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  _rangeText(chosen, periods),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (periods.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('V téhle sezóně nebyly žádné služby.'),
                ),
              for (final period in periods)
                DutyPeriodTile(
                  period: period,
                  assignees: dutyAssigneesLabel(
                    assigneeIds(data.assignments, period.id),
                    byId,
                  ),
                  current: period.covers(today),
                ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: DutySeasonOverview(
                  season: chosen,
                  data: data,
                  today: today,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// „Sezóna 2025/26 · od 1. 9. 2025 do 31. 8. 2026“ — the main screen's
  /// title, closed by the next boundary when there is one.
  static String _rangeText(SeasonRange season, List<DutyPeriod> periods) {
    final title = seasonTitle(season, periods);
    final until = season.until;
    if (until == null) return title;
    return title.contains(' · od ')
        ? '$title do ${dutyDate(until)}'
        : '$title · do ${dutyDate(until)}';
  }
}
