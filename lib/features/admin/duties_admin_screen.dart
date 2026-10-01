/// Správa → Služby (0050): the admin plans the canteen duties, assigns the
/// players, sees how often each served this season, sets the reminder
/// before a duty and starts a new season. Every write goes through the
/// admin-only duty_* RPCs; the list follows the two duty streams.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/duties.dart';
import '../../domain/labels.dart' show czechCount;
import '../../domain/models.dart';
import 'duties_history_screen.dart';
import 'widgets/admin_scaffold.dart';
import 'widgets/duty_admin_api.dart';
import 'widgets/duty_assign_sheet.dart';
import 'widgets/duty_generator_dialog.dart';
import 'widgets/duty_parts.dart';
import 'widgets/duty_period_dialog.dart';
import 'widgets/duty_season_dialog.dart';
import '../../core/push_screen.dart';

class DutiesAdminScreen extends ConsumerWidget {
  const DutiesAdminScreen({super.key, this.api = const DutyAdminApi()});

  /// Injectable so widget tests can drive every dialog without the backend.
  final DutyAdminApi api;

  /// „Předstih“: the leads offered, in days.
  static const _leads = [1, 2, 3, 7];

  Future<void> _generate(
    BuildContext context,
    List<DutyPeriod> periods,
    Day today,
  ) async {
    final created = await showDialog<int>(
      context: context,
      builder: (_) => DutyGeneratorDialog(
        existing: periods,
        today: today,
        generate: api.generate,
      ),
    );
    if (created != null && context.mounted) {
      snack(context, 'Vytvořeno služeb: $created.');
    }
  }

  /// „Přidat službu“ continues after the last duty with its length, like
  /// the generator; „Upravit termín…“ ([existing]) starts from the period.
  Future<void> _editPeriod(
    BuildContext context,
    List<DutyPeriod> periods,
    Day today, {
    DutyPeriod? existing,
  }) async {
    final next = nextDutyDefaults(periods, today);
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => DutyPeriodDialog(
        existing: existing,
        startsOn: existing?.startsOn ?? next.start,
        endsOn: existing?.endsOn ?? next.start.addDays(next.days - 1),
        today: today,
        save: api.savePeriod,
      ),
    );
    if (saved == true && context.mounted) snack(context, 'Uloženo.');
  }

  Future<void> _delete(
    BuildContext context,
    DutyPeriod period, {
    required bool assigned,
  }) => confirmDelete(
    context,
    title: 'Smazat službu?',
    message: assigned
        ? 'Přiřazení hráči o ni přijdou.'
        : 'Služba ${dutyRangeLabel(period)} se smaže.',
    action: () => api.deletePeriod(period.id),
    success: 'Smazáno.',
  );

  /// „Smazat neobsazené budoucí…“: the empty duties from tomorrow on — a
  /// running one is not future. Cheap to redo a plan in another rhythm.
  Future<void> _deleteUnassigned(
    BuildContext context,
    DutyData data,
    Day today,
  ) async {
    final from = today.addDays(1);
    final assigned = {for (final a in data.assignments) a.periodId};
    final n = data.periods
        .where((p) => !p.startsOn.isBefore(from) && !assigned.contains(p.id))
        .length;
    if (n == 0) {
      snack(context, 'Žádné neobsazené budoucí služby.');
      return;
    }
    final verb = n >= 2 && n <= 4 ? 'Smažou se' : 'Smaže se';
    final confirmed = await confirmDialog(
      context,
      title: 'Smazat neobsazené budoucí služby?',
      message:
          '$verb ${czechCount(n, 'služba', 'služby', 'služeb')} bez '
          'hráčů, od ${dutyDayLabel(from)} dál. Obsazené zůstanou.',
    );
    if (!confirmed || !context.mounted) return;
    var deleted = 0;
    final ok = await tryAction(
      context,
      () async => deleted = await api.deleteUnassigned(from),
      errorText: friendlyDbError,
    );
    if (ok && context.mounted) snack(context, 'Smazáno služeb: $deleted.');
  }

  Future<void> _assign(
    BuildContext context,
    DutyData data,
    DutyPeriod period,
    Day today,
    List<Club> clubs,
  ) async {
    final saved = await showDutyAssignSheet(
      context,
      periods: data.periods,
      index: data.periods.indexOf(period),
      assignments: data.assignments,
      seasons: data.seasons,
      roster: dutyRoster(data.profiles),
      clubs: clubs,
      today: today,
      save: api.setAssignees,
    );
    if (saved == true && context.mounted) snack(context, 'Uloženo.');
  }

  Future<void> _newSeason(
    BuildContext context,
    WidgetRef ref,
    DutyData data,
    Day today,
  ) async {
    final started = await showDialog<bool>(
      context: context,
      builder: (_) => DutySeasonDialog(
        periods: data.periods,
        seasons: data.seasons,
        today: today,
        start: api.startSeason,
      ),
    );
    if (started != true) return;
    ref.invalidate(dutySeasonsProvider);
    if (context.mounted) snack(context, 'Nová sezóna začala.');
  }

  Future<void> _undoSeason(
    BuildContext context,
    WidgetRef ref,
    List<DutySeason> seasons,
  ) async {
    final newest = seasons.reduce(
      (a, b) => a.startedOn.isAfter(b.startedOn) ? a : b,
    );
    final confirmed = await confirmDialog(
      context,
      title: 'Vrátit poslední sezónu?',
      message:
          'Sezóna „${newest.name}“ od ${dutyDate(newest.startedOn)} se '
          'zruší a její služby se započítají do předchozí sezóny.',
      confirmLabel: 'Vrátit',
    );
    if (!confirmed || !context.mounted) return;
    final ok = await tryAction(
      context,
      () => api.deleteSeason(newest.startedOn),
      success: 'Sezóna vrácena.',
      errorText: friendlyDbError,
    );
    if (ok) ref.invalidate(dutySeasonsProvider);
  }

  Widget _seasonMenu(
    BuildContext context,
    WidgetRef ref,
    DutyData? data,
    Day today,
  ) => PopupMenuButton<String>(
    tooltip: 'Sezóny',
    enabled: data != null,
    onSelected: (action) {
      switch (action) {
        case 'new':
          _newSeason(context, ref, data!, today);
        case 'history':
          pushScreen(context, (_) => const DutiesHistoryScreen());
        case 'undo':
          _undoSeason(context, ref, data!.seasons);
      }
    },
    itemBuilder: (_) => [
      const PopupMenuItem(value: 'new', child: Text('Nová sezóna…')),
      const PopupMenuItem(value: 'history', child: Text('Historie')),
      PopupMenuItem(
        value: 'undo',
        enabled: data?.seasons.isNotEmpty ?? false,
        child: const Text('Vrátit poslední sezónu'),
      ),
    ],
  );

  Widget _reminderCard(BuildContext context, ScheduleSettings? settings) {
    final enabled = settings?.dutyReminderEnabled ?? false;
    final days = settings?.dutyReminderDays ?? 1;
    Future<void> save(bool on, int lead) => tryAction(
      context,
      () => api.setReminder(on, lead, tenantId: settings!.tenantId),
      errorText: friendlyDbError,
    );
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            title: const Text('Připomínka služby'),
            subtitle: const Text(
              'Odesílá se v 18:00. Push, jinak e-mail. Hráči bez účtu ji '
              'nedostanou.',
            ),
            value: enabled,
            // The settings row is null until the backend is seeded.
            onChanged: settings == null ? null : (on) => save(on, days),
          ),
          if (enabled)
            ListTile(
              title: const Text('Předstih'),
              trailing: DropdownButton<int>(
                value: days,
                underline: const SizedBox.shrink(),
                items: [
                  // A lead set elsewhere (1–14) stays selectable as it is.
                  for (final lead in {..._leads, days}.toList()..sort())
                    DropdownMenuItem(
                      value: lead,
                      child: Text(dutyLeadLabel(lead)),
                    ),
                ],
                onChanged: (lead) {
                  if (lead != null && lead != days) save(true, lead);
                },
              ),
            ),
        ],
      ),
    );
  }

  /// The tile's ⋮: „Přiřadit hráče…“ does what a tap on the tile does.
  Widget _periodMenu(
    BuildContext context,
    DutyData data,
    DutyPeriod period,
    Day today,
    List<Club> clubs, {
    required bool assigned,
  }) => PopupMenuButton<String>(
    onSelected: (action) {
      switch (action) {
        case 'assign':
          _assign(context, data, period, today, clubs);
        case 'edit':
          _editPeriod(context, data.periods, today, existing: period);
        case 'delete':
          _delete(context, period, assigned: assigned);
      }
    },
    itemBuilder: (_) => const [
      PopupMenuItem(value: 'assign', child: Text('Přiřadit hráče…')),
      PopupMenuItem(value: 'edit', child: Text('Upravit termín…')),
      PopupMenuItem(value: 'delete', child: Text('Smazat')),
    ],
  );

  Widget _body(
    BuildContext context,
    DutyData data,
    ScheduleSettings? settings,
    Day today,
    List<Club> clubs,
  ) {
    final theme = Theme.of(context);
    final season = currentSeason(seasonRanges(data.seasons), today);
    final byId = {for (final p in data.profiles) p.id: p};
    // Running and ahead, whatever their season; the season's past below.
    final ahead = [
      for (final p in data.periods)
        if (!p.endsOn.isBefore(today)) p,
    ];
    final past = [
      for (final p in data.periods)
        if (p.endsOn.isBefore(today) && season.containsPeriod(p)) p,
    ];

    Widget tile(DutyPeriod period) {
      final ids = assigneeIds(data.assignments, period.id);
      return DutyPeriodTile(
        period: period,
        assignees: dutyAssigneesLabel(ids, byId),
        current: period.covers(today),
        onTap: () => _assign(context, data, period, today, clubs),
        menu: _periodMenu(
          context,
          data,
          period,
          today,
          clubs,
          assigned: ids.isNotEmpty,
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            seasonTitle(season, data.periods),
            style: theme.textTheme.titleMedium,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: _reminderCard(context, settings),
        ),
        const SizedBox(height: 8),
        if (ahead.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Služby zatím nejsou naplánované.'),
          ),
        for (final period in ahead) tile(period),
        if (past.isNotEmpty)
          ExpansionTile(
            title: Text('Minulé služby (${past.length})'),
            children: [for (final period in past) tile(period)],
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: DutySeasonOverview(season: season, data: data, today: today),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = watchDutyToday(ref);
    final value = watchDutyData(ref);
    final data = value.value;
    final settings = ref.watch(settingsProvider).value;
    // Only names the filter chips of the assign sheet: not yet streamed
    // just means no club chips.
    final clubs = ref.watch(clubsProvider).value ?? const <Club>[];
    return AdminScaffold(
      title: 'Služby',
      actions: [_seasonMenu(context, ref, data, today)],
      body: AsyncBody(
        value: value,
        onRetry: () => refreshDutyData(ref),
        builder: (data) => _body(context, data, settings, today, clubs),
      ),
      // Not a FAB: the bar docks under the list (ListActionBar).
      floatingActionButton: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton(
            onPressed: data == null
                ? null
                : () => _generate(context, data.periods, today),
            child: const Text('Vygenerovat…'),
          ),
          FilledButton(
            onPressed: data == null
                ? null
                : () => _editPeriod(context, data.periods, today),
            child: const Text('Přidat službu'),
          ),
          PopupMenuButton<String>(
            tooltip: 'Další akce',
            enabled: data != null,
            onSelected: (_) => _deleteUnassigned(context, data!, today),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'delete_unassigned',
                child: Text('Smazat neobsazené budoucí…'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
