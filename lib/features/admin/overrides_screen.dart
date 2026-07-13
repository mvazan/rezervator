import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import 'widgets/admin_body.dart';

/// Admin: manage per-day closures that take precedence over the weekly
/// training-day rule. An override closes a day with a reason (e.g. "Malování
/// drah"); the schedule then shows it as closed and cancels colliding
/// reservations.
class OverridesScreen extends ConsumerWidget {
  const OverridesScreen({super.key});

  Future<void> _delete(BuildContext context, DayOverride override) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Smazat výjimku?',
      message: 'Den se vrátí k týdennímu pravidlu.',
    );
    if (!confirmed) return;
    if (!context.mounted) return;

    await tryAction(
      context,
      () => Api.deleteDayOverride(override.date),
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
    // Only closures are managed here; ignore any legacy open/custom-times rows.
    final closures = [
      for (final o in overrides)
        if (o.closed) o,
    ];
    final now = today();
    // Upcoming first (ascending); past collapsed at the bottom (most recent
    // first), so the default view is only what still matters.
    final upcoming = closures.where((o) => !o.date.isBefore(now)).toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    final past = closures.where((o) => o.date.isBefore(now)).toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    Widget tile(DayOverride override) => ListTile(
          title: Text(dayFull(override.date)),
          subtitle: Text('Zavřeno — ${override.reason}'),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(context, override),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Výjimky dnů')),
      body: AdminBody(
        child: closures.isEmpty
            ? const Center(child: Text('Zatím žádné výjimky.'))
            : ListView(
                children: [
                  if (upcoming.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Žádné nadcházející výjimky.'),
                    )
                  else
                    for (final override in upcoming) tile(override),
                  if (past.isNotEmpty)
                    ExpansionTile(
                      title: Text('Minulé (${past.length})'),
                      children: [for (final override in past) tile(override)],
                    ),
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
      _reason.text = existing?.reason ?? '';
    });
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

    setState(() => _saving = true);
    final ok = await tryAction(
      context,
      () => Api.setDayOverride(
        date: date,
        closed: true,
        reason: _reason.text.trim(),
        blockIds: null,
      ),
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
