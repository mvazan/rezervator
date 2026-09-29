/// Klubovna → Služby (0050): who works the canteen when. My duty on top,
/// who serves now, the plan ahead in date order and the past collapsed,
/// my own periods highlighted. Read-only for everyone — the admin plans in
/// Správa → Služby, which „Spravovat“ opens.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/collation.dart';
import '../../domain/duties.dart';
import '../../domain/models.dart';
import '../admin/duties_admin_screen.dart';
import 'widgets/duty_cards.dart';

Widget _adminPage(BuildContext _) => const DutiesAdminScreen();

class DutiesScreen extends ConsumerWidget {
  const DutiesScreen({super.key, this.adminPage = _adminPage});

  /// What „Spravovat“ opens — Správa → Služby; a test swaps in a stand-in.
  final WidgetBuilder adminPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAdmin =
        ref.watch(myProfileProvider.select((p) => p.value?.isAdmin)) ?? false;
    final value = _watchData(ref);

    Widget body;
    if (value.hasError) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(friendlyDbError(value.error!), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => _refresh(ref),
                child: const Text('Zkusit znovu'),
              ),
            ],
          ),
        ),
      );
    } else if (!value.hasValue) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = _DutyList(data: value.value!);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Služby'),
        actions: [
          if (isAdmin)
            TextButton(
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: adminPage)),
              child: const Text('Spravovat'),
            ),
        ],
      ),
      body: body,
    );
  }
}

/// What the list renders from: the periods and assignees (streams) and the
/// roster's names, placeholders included.
typedef _Data = ({
  List<DutyPeriod> periods,
  List<DutyAssignment> assignments,
  Map<String, String> names,
});

/// [_Data] as one [AsyncValue]: the first error, else loading until all
/// three have a value — so the list never draws half a plan.
AsyncValue<_Data> _watchData(WidgetRef ref) {
  final periods = ref.watch(dutyPeriodsProvider);
  final assignments = ref.watch(dutyAssignmentsProvider);
  final players = ref.watch(playersProvider);
  for (final v in <AsyncValue<Object?>>[periods, assignments, players]) {
    if (v.hasError && !v.hasValue) {
      return AsyncValue.error(v.error!, v.stackTrace ?? StackTrace.current);
    }
  }
  if (!periods.hasValue || !assignments.hasValue || !players.hasValue) {
    return const AsyncValue.loading();
  }
  return AsyncValue.data((
    periods: periods.value!,
    assignments: assignments.value!,
    names: {for (final p in players.value!) p.id: p.displayName},
  ));
}

void _refresh(WidgetRef ref) {
  ref.invalidate(dutyPeriodsProvider);
  ref.invalidate(dutyAssignmentsProvider);
  ref.invalidate(playersProvider);
}

class _DutyList extends ConsumerWidget {
  const _DutyList({required this.data});

  final _Data data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final meId = ref.watch(myProfileProvider.select((p) => p.value?.id));
    final today = ref.watch(
      nowProvider.select(
        (now) => Day.fromDateTime(now.value ?? DateTime.now()),
      ),
    );
    final mine = ref.watch(myDutyProvider);
    final settings =
        ref.watch(settingsProvider).value ?? ScheduleSettings.defaults;
    final split = splitDuties(data.periods, today);

    // Known names only, Czech-sorted; an id the roster lacks is left out.
    List<String> namesOf(Iterable<String> ids) =>
        [for (final id in ids) ?data.names[id]]..sort(compareCzech);
    List<String> ids(DutyPeriod p) => assigneeIds(data.assignments, p.id);
    Widget tile(DutyPeriod p) => DutyRosterTile(
      period: p,
      mine: ids(p).contains(meId),
      others: namesOf(ids(p).where((id) => id != meId)),
    );

    final current = split.current;
    final nowIds = current == null ? const <String>[] : ids(current);
    // My card already says it when I serve alone.
    final showNow =
        namesOf(nowIds).isNotEmpty &&
        !(nowIds.length == 1 && nowIds.single == meId);

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (mine.current != null || mine.next != null)
          MyDutyCard(
            duty: mine,
            coNames: namesOf(mine.coAssignees),
            reminderDays: settings.dutyReminderEnabled
                ? settings.dutyReminderDays
                : null,
          ),
        if (showNow)
          NowServingCard(
            period: current!,
            names: [
              if (nowIds.contains(meId)) 'ty',
              ...namesOf(nowIds.where((id) => id != meId)),
            ],
          ),
        const SizedBox(height: 8),
        // A running period no card shows (nobody the roster knows serves
        // it) heads the plan as a plain tile, „Neobsazeno“ when unassigned.
        if (current case final p? when !showNow && !nowIds.contains(meId))
          tile(p),
        for (final p in split.upcoming) tile(p),
        if (current == null && split.upcoming.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Služby zatím nejsou naplánované.',
              textAlign: TextAlign.center,
            ),
          ),
        if (split.past.isNotEmpty)
          ExpansionTile(
            title: const Text('Minulé služby'),
            children: [for (final p in split.past) tile(p)],
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Během služby můžeš rezervovat a rušit tréninky ostatním '
                  'a upravovat bloky v jednotlivých dnech.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
