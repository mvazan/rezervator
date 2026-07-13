import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import 'slot_types_screen.dart';
import 'widgets/blockage_dialog.dart';
import 'widgets/admin_body.dart';

/// Admin: manage per-day closures that take precedence over the weekly
/// training-day rule. An override closes a day with a reason (e.g. "Malování
/// drah"); the schedule then shows it as closed and cancels colliding
/// reservations.
class OverridesScreen extends ConsumerWidget {
  const OverridesScreen({super.key});

  Future<void> _deleteRun(
      BuildContext context, List<DayOverride> run) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Smazat výjimku?',
      message: run.length == 1
          ? 'Den se vrátí k týdennímu pravidlu.'
          : '${run.length} dní se vrátí k týdennímu pravidlu.',
    );
    if (!confirmed) return;
    if (!context.mounted) return;

    await tryAction(
      context,
      () async {
        for (final o in run) {
          await Api.deleteDayOverride(o.date);
        }
      },
      errorText: friendlyDbError,
    );
  }

  Future<void> _deleteBlockage(BuildContext context, PrioritySlot slot) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Smazat blokaci?',
      message: 'Opravdu smazat „${slot.title}" (${dayLabel(slot.date)})?',
    );
    if (!confirmed || !context.mounted) return;
    await tryAction(
      context,
      () => Api.deletePrioritySlot(slot.id),
      errorText: friendlyDbError,
    );
  }

  /// Returns a schedule-fork day to the weekly rules. A training day goes
  /// back to the template blocks; a NON-training day closes again (every
  /// reservation that date cancels, closed write FIRST so a failure between
  /// the two calls can't leave the day wide open).
  Future<void> _restore(BuildContext context, DayOverride override,
      List<TimeBlock> blocks, ScheduleSettings settings) async {
    final isTraining =
        settings.trainingWeekdays.contains(override.date.weekday);
    final templateIds = [
      for (final b in blocks)
        if (b.active && b.position >= 0) b.id,
    ];
    final reservations = await Api.futureLiveReservations(today());
    if (!context.mounted) return;
    final losing = reservations
        .where((r) =>
            r.date == override.date &&
            (!isTraining || !templateIds.contains(r.blockId)))
        .length;
    final confirmed = await confirmDialog(
      context,
      title: 'Vrátit den k týdennímu rozvrhu?',
      message: losing == 0
          ? (isTraining
              ? 'Jednodenní změna rozvrhu se zruší.'
              : 'Jednodenní změna se zruší a den bude zase zavřený.')
          : (isTraining
              ? 'Jednodenní změna se zruší a $losing rezervací mimo týdenní '
                  'bloky bude zrušeno („změna rozvrhu").'
              : 'Den bude zase zavřený a všech $losing rezervací bude '
                  'zrušeno („změna rozvrhu").'),
      confirmLabel: 'Vrátit',
    );
    if (!confirmed || !context.mounted) return;
    await tryAction(
      context,
      () async {
        if (isTraining) {
          await Api.setDayOverride(
              date: override.date,
              closed: false,
              reason: '',
              blockIds: templateIds);
        } else {
          await Api.setDayOverride(
              date: override.date, closed: true, reason: '');
        }
        await Api.deleteDayOverride(override.date);
      },
      success: 'Den vrácen k týdennímu rozvrhu.',
      errorText: friendlyDbError,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    if (profile?.isAdmin != true) {
      return Scaffold(
        appBar: AppBar(title: const Text('Výjimky dnů')),
        body: const Center(child: Text('Jen pro správce.')),
      );
    }

    final overrides =
        ref.watch(dayOverridesProvider).value ?? const <DayOverride>[];
    final settings =
        ref.watch(settingsProvider).value ?? ScheduleSettings.defaults;
    final blocks = ref.watch(timeBlocksProvider).value ?? const <TimeBlock>[];
    final blockById = {for (final b in blocks) b.id: b};
    final closures = [
      for (final o in overrides)
        if (o.closed) o,
    ];
    final slots = ref.watch(prioritySlotsProvider);
    final types = ref.watch(slotTypesProvider).value ?? const [];
    // Blokace: every non-match priority slot the admin manages by hand —
    // úklid children (parentId set) live and die with their match.
    final blockages = [
      for (final s in slots)
        if (!s.type.isMatch && s.parentId == null) s,
    ];
    // Day-scoped schedule changes made from the calendar (open overrides
    // with a block selection) — listed so the admin has one tidy place to
    // see and undo every one-day fork.
    final forks = [
      for (final o in overrides)
        if (!o.closed && o.blockIds != null) o,
    ];
    final now = today();
    // Upcoming first (ascending); past collapsed at the bottom (most recent
    // first), so the default view is only what still matters.
    final upcoming = closures.where((o) => !o.date.isBefore(now)).toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    final past = closures.where((o) => o.date.isBefore(now)).toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    // Consecutive same-reason closures (e.g. a week of dovolená) fold into
    // one range tile; deleting it removes every day of the run.
    List<List<DayOverride>> runsOf(List<DayOverride> list) {
      final sorted = [...list]..sort((a, b) => a.date.compareTo(b.date));
      final runs = <List<DayOverride>>[];
      for (final o in sorted) {
        if (runs.isNotEmpty &&
            runs.last.last.date.addDays(1) == o.date &&
            runs.last.last.reason == o.reason) {
          runs.last.add(o);
        } else {
          runs.add([o]);
        }
      }
      return runs;
    }

    Widget tile(List<DayOverride> run) => ListTile(
          title: Text(run.length == 1
              ? dayFull(run.first.date)
              : '${dayFull(run.first.date)} – ${dayFull(run.last.date)}'),
          subtitle: Text('Zavřeno — ${run.first.reason}'
              '${run.length > 1 ? ' (${run.length} dní)' : ''}'),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _deleteRun(context, run),
          ),
        );

    Widget forkTile(DayOverride override) {
      final parts = [
        for (final id in override.blockIds!)
          if (blockById[id] != null)
            blockById[id]!.position < 0
                ? '${blockById[id]!.label} (jen tento den)'
                : blockById[id]!.label,
      ];
      return ListTile(
        title: Text(dayFull(override.date)),
        subtitle: Text(
          parts.isEmpty ? 'Žádné bloky (den zavřen)' : parts.join(' · '),
        ),
        trailing: override.date.isBefore(now)
            ? null
            : IconButton(
                icon: const Icon(Icons.undo),
                tooltip: 'Vrátit den k týdennímu rozvrhu',
                onPressed: () => _restore(
                    context, override, blocks, settings),
              ),
      );
    }

    final upcomingForks = forks.where((o) => !o.date.isBefore(now)).toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    final pastForks = forks.where((o) => o.date.isBefore(now)).toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    Widget blockageTile(PrioritySlot slot) => ListTile(
          title: Text(
            '${dayLabel(slot.date)} · '
            '${slot.startsAt.display()}–${slot.endsAt.display()} · '
            '${slot.title}',
          ),
          subtitle: switch ([
            if (slot.type.lanes != null)
              'dráhy ${slot.type.lanes!.join(', ')}',
            if (slot.description.isNotEmpty) slot.description,
          ].join(' · ')) {
            '' => null,
            final sub => Text(sub),
          },
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) =>
                      BlockageDialog(existing: slot, types: types),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _deleteBlockage(context, slot),
              ),
            ],
          ),
        );

    final upcomingBlockages =
        blockages.where((s) => !s.date.isBefore(now)).toList()
          ..sort((a, b) => a.date.compareTo(b.date));
    final pastBlockages = blockages.where((s) => s.date.isBefore(now)).toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    return Scaffold(
      appBar: AppBar(title: const Text('Výjimky dnů')),
      body: AdminBody(
        child: closures.isEmpty && forks.isEmpty && blockages.isEmpty
            ? const Center(child: Text('Zatím žádné výjimky.'))
            : ListView(
                children: [
                  if (upcoming.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Žádné nadcházející výjimky.'),
                    )
                  else
                    for (final run in runsOf(upcoming)) tile(run),
                  if (past.isNotEmpty)
                    ExpansionTile(
                      title: Text('Minulé (${past.length})'),
                      children: [for (final run in runsOf(past)) tile(run)],
                    ),
                  if (forks.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 20, 16, 4),
                      child: Text(
                        'Jednodenní změny rozvrhu',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    for (final override in upcomingForks) forkTile(override),
                    if (pastForks.isNotEmpty)
                      ExpansionTile(
                        title: Text('Minulé změny (${pastForks.length})'),
                        children: [
                          for (final override in pastForks) forkTile(override),
                        ],
                      ),
                  ],
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 4, 0),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Blokace',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.tune),
                          tooltip: 'Typy blokací',
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const SlotTypesScreen()),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add),
                          tooltip: 'Přidat blokaci',
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) => BlockageDialog(types: types),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (blockages.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Zatím žádné blokace.'),
                    )
                  else ...[
                    for (final slot in upcomingBlockages) blockageTile(slot),
                    if (pastBlockages.isNotEmpty)
                      ExpansionTile(
                        title: Text('Minulé blokace (${pastBlockages.length})'),
                        children: [
                          for (final slot in pastBlockages) blockageTile(slot),
                        ],
                      ),
                  ],
                ],
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => const _OverrideDialog(),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Přidat výjimku'),
      ),
    );
  }
}

/// Add/edit-closure dialog: date + reason. Picking a date that already has a
/// closure edits it in place ([Api.setDayOverride] upserts by date).
class _OverrideDialog extends ConsumerStatefulWidget {
  const _OverrideDialog();

  @override
  ConsumerState<_OverrideDialog> createState() => _OverrideDialogState();
}

class _OverrideDialogState extends ConsumerState<_OverrideDialog> {
  Day? _date;
  Day? _dateTo;
  final _reason = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = today();
    final initial = _date ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(
        now.year,
        now.month,
        now.day,
      ).add(const Duration(days: 365)),
      locale: const Locale('cs'),
    );
    if (picked == null) return;
    final date = Day.fromDateTime(picked);
    final overrides =
        ref.read(dayOverridesProvider).value ?? const <DayOverride>[];
    final existing = overrides
        .where((o) => o.date == date && o.closed)
        .firstOrNull;
    setState(() {
      _date = date;
      if (_dateTo != null && _dateTo!.isBefore(date)) _dateTo = null;
      _reason.text = existing?.reason ?? '';
    });
  }

  Future<void> _pickDateTo() async {
    final from = _date ?? today();
    final initial = _dateTo ?? from;
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(from.year, from.month, from.day),
      lastDate: DateTime(from.year, from.month, from.day)
          .add(const Duration(days: 365)),
      locale: const Locale('cs'),
    );
    if (picked != null) setState(() => _dateTo = Day.fromDateTime(picked));
  }

  Future<void> _save() async {
    final date = _date;
    if (date == null) {
      snack(context, 'Vyber datum.');
      return;
    }
    if (_reason.text.trim().isEmpty) {
      snack(context, 'Vyplň důvod.');
      return;
    }
    final to = _dateTo ?? date;
    final span = to.differenceInDays(date);
    if (span < 0) {
      snack(context, '„Do" musí být po datu začátku.');
      return;
    }
    if (span > 92) {
      snack(context, 'Nejvýše 3 měsíce najednou.');
      return;
    }

    setState(() => _saving = true);
    final ok = await tryAction(
      context,
      () async {
        // One override row per day — the list groups consecutive runs back
        // into a single range tile.
        for (var i = 0; i <= span; i++) {
          await Api.setDayOverride(
            date: date.addDays(i),
            closed: true,
            reason: _reason.text.trim(),
            blockIds: null,
          );
        }
      },
      success: 'Výjimka uložena. Kolidující rezervace byly zrušeny.',
      errorText: friendlyDbError,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Přidat výjimku'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Datum'),
            trailing: Text(_date == null ? 'Vybrat' : dayFull(_date!)),
            onTap: _pickDate,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Do (volitelně)'),
            subtitle: _dateTo == null
                ? const Text('Nevyplněno = jen jeden den',
                    style: TextStyle(fontSize: 12))
                : null,
            trailing: _dateTo == null
                ? const Text('Vybrat')
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(dayFull(_dateTo!)),
                      IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => setState(() => _dateTo = null),
                      ),
                    ],
                  ),
            onTap: _pickDateTo,
          ),
          TextField(
            controller: _reason,
            decoration: const InputDecoration(
              labelText: 'Důvod (zavřeno)',
              hintText: 'Malování drah',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Ukládám…' : 'Uložit'),
        ),
      ],
    );
  }
}
