/// The pieces Správa → Služby and Historie služeb share (0050): the loading
/// of the four inputs, the season's title, the roster, a period's tile and
/// the season overview card. The counting itself is `duties.dart`'s.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/clock.dart';
import '../../../data/providers.dart';
import '../../../domain/collation.dart';
import '../../../domain/duties.dart';
import '../../../domain/models.dart';

/// What the implicit first season — the duties before the first boundary —
/// is called, having no name of its own.
const firstSeasonName = 'První sezóna';

/// „1. 9. 2026“.
String dutyDate(Day day) => '${day.day}. ${day.month}. ${day.year}';

/// „st 30. 6. 2027“ — a date field's value in the duty dialogs, the year
/// included because a plan runs into the next one.
String dutyPickerDate(Day day) => '${dutyDayLabel(day)} ${day.year}';

/// The season's name: its boundary's, or [firstSeasonName].
String seasonLabel(SeasonRange season) => season.name ?? firstSeasonName;

/// „Sezóna 2026/27 · od 1. 9. 2026“. The implicit first season starts with
/// its first duty („První sezóna · od 24. 8. 2026“), or has no date while
/// it has none.
String seasonTitle(SeasonRange season, Iterable<DutyPeriod> periods) {
  final name = season.name;
  if (name != null) return 'Sezóna $name · od ${dutyDate(season.from!)}';
  final starts = [
    for (final p in periods)
      if (season.containsPeriod(p)) p.startsOn,
  ]..sort();
  return starts.isEmpty
      ? firstSeasonName
      : '$firstSeasonName · od ${dutyDate(starts.first)}';
}

/// Where a new duty goes by default („Přidat službu“, the generator): the
/// day after the last one, as long as it lasted (clamped to the
/// generator's 1–31), or a week from today with no duty yet. A plan that
/// ended in the past picks up from today.
({Day start, int days}) nextDutyDefaults(
  Iterable<DutyPeriod> periods,
  Day today,
) {
  DutyPeriod? last;
  for (final p in periods) {
    if (last == null || p.endsOn.isAfter(last.endsOn)) last = p;
  }
  final after = last?.endsOn.addDays(1);
  return (
    start: after == null || after.isBefore(today) ? today : after,
    days: (last?.days ?? 7).clamp(1, 31),
  );
}

/// The players a duty can go to, Czech-sorted: approved, not a kiosk, not a
/// visiting superadmin — placeholders included. The same set
/// `duty_set_assignees` accepts.
List<Profile> dutyRoster(Iterable<Profile> profiles) => [
  for (final p in profiles)
    if (p.isApproved && p.role != Role.kiosk && !p.isVisiting) p,
]..sort((a, b) => compareCzech(a.displayName, b.displayName));

/// The period's players for its tile: Czech-sorted names, a placeholder
/// marked „· bez účtu“, joined by commas; null when nobody is assigned.
String? dutyAssigneesLabel(
  Iterable<String> userIds,
  Map<String, Profile> profiles,
) {
  final people = [for (final id in userIds) profiles[id]];
  if (people.isEmpty) return null;
  final names = [
    for (final p in people)
      if (p == null)
        'Neznámý hráč'
      else if (p.hasAccount)
        p.displayName
      else
        '${p.displayName} · bez účtu',
  ]..sort(compareCzech);
  return names.join(', ');
}

/// Everything the two duty screens render from, loaded together so neither
/// draws half a plan: the periods and assignees (streams), the season
/// boundaries (a future) and the profiles (names).
typedef DutyData = ({
  List<DutyPeriod> periods,
  List<DutyAssignment> assignments,
  List<DutySeason> seasons,
  List<Profile> profiles,
});

/// [DutyData] as one [AsyncValue]: the first error, else loading until all
/// four have a value.
AsyncValue<DutyData> watchDutyData(WidgetRef ref) {
  final periods = ref.watch(dutyPeriodsProvider);
  final assignments = ref.watch(dutyAssignmentsProvider);
  final seasons = ref.watch(dutySeasonsProvider);
  final profiles = ref.watch(profilesProvider);
  for (final value in <AsyncValue<Object?>>[
    periods,
    assignments,
    seasons,
    profiles,
  ]) {
    if (value.hasError && !value.hasValue) {
      return AsyncValue.error(
        value.error!,
        value.stackTrace ?? StackTrace.current,
      );
    }
  }
  if (!periods.hasValue ||
      !assignments.hasValue ||
      !seasons.hasValue ||
      !profiles.hasValue) {
    return const AsyncValue.loading();
  }
  return AsyncValue.data((
    periods: periods.value!,
    assignments: assignments.value!,
    seasons: seasons.value!,
    profiles: profiles.value!,
  ));
}

/// Re-reads the four inputs of [watchDutyData] (AsyncBody's retry).
void refreshDutyData(WidgetRef ref) {
  ref.invalidate(dutyPeriodsProvider);
  ref.invalidate(dutyAssignmentsProvider);
  ref.invalidate(dutySeasonsProvider);
  ref.invalidate(profilesProvider);
}

/// Today by the app clock, which a test can pin; changes once a day.
Day watchDutyToday(WidgetRef ref) => ref.watch(
  nowProvider.select((now) => Day.fromDateTime(now.value ?? DateTime.now())),
);

/// One duty: „po 5. 10. – ne 11. 10.“ with its note, its players (or
/// „Neobsazeno“ in the error colour), tinted with „Teď slouží“ while it
/// runs. [onTap] and [menu] are null in the read-only history.
class DutyPeriodTile extends StatelessWidget {
  const DutyPeriodTile({
    super.key,
    required this.period,
    required this.assignees,
    required this.current,
    this.onTap,
    this.menu,
  });

  final DutyPeriod period;

  /// [dutyAssigneesLabel]; null for nobody.
  final String? assignees;

  /// The period covers today.
  final bool current;
  final VoidCallback? onTap;
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = period.note.isEmpty
        ? dutyRangeLabel(period)
        : '${dutyRangeLabel(period)} · ${period.note}';
    return ListTile(
      tileColor: current ? scheme.secondaryContainer : null,
      title: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(title),
          if (current)
            Chip(
              label: const Text('Teď slouží'),
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
      subtitle: assignees == null
          ? Text('Neobsazeno', style: TextStyle(color: scheme.error))
          : Text(assignees!),
      trailing: menu,
      onTap: onTap,
    );
  }
}

/// „Přehled sezóny“: every player of [roster] — plus anyone else who served
/// in [season] — with their count, Czech-sorted, never by the count. A
/// player without a duty reads „—“.
class DutySeasonOverview extends StatelessWidget {
  const DutySeasonOverview({
    super.key,
    required this.season,
    required this.data,
    required this.today,
  });

  final SeasonRange season;
  final DutyData data;
  final Day today;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final counts = dutyCounts(
      data.periods,
      data.assignments,
      season,
      today: today,
    );
    final byId = {for (final p in data.profiles) p.id: p};
    final people =
        {
            for (final p in dutyRoster(data.profiles)) p.id: p,
            // Someone who served and has since left the roster (pending, kiosk)
            // still belongs in the season's numbers.
            for (final id in counts.keys)
              if (byId[id] != null) id: byId[id]!,
          }.values.toList()
          ..sort((a, b) => compareCzech(a.displayName, b.displayName));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Přehled sezóny', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final p in people)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text.rich(
                  TextSpan(
                    text: p.displayName,
                    children: [
                      TextSpan(
                        text:
                            ' — '
                            '${dutyCountLabel(counts[p.id] ?? DutyCount.zero)}',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
