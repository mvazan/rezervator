import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';

/// Admin: manage matches (block reservations for spectators to see).
class MatchesScreen extends ConsumerWidget {
  const MatchesScreen({super.key});

  Future<void> _delete(BuildContext context, Match match) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Smazat zápas?',
      message: 'Opravdu smazat zápas se soupeřem ${match.awayTeam}?',
    );
    if (!confirmed) return;
    if (!context.mounted) return;

    await tryAction(
      context,
      () => Api.deleteMatch(match.id),
      errorText: friendlyDbError,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    if (profile?.isAdmin != true) {
      return Scaffold(
        appBar: AppBar(title: const Text('Zápasy')),
        body: const Center(child: Text('Jen pro správce.')),
      );
    }

    final matches = ref.watch(matchesProvider).value ?? const <Match>[];
    final sorted = [...matches]..sort((a, b) => b.date.compareTo(a.date));

    return Scaffold(
      appBar: AppBar(title: const Text('Zápasy')),
      body: sorted.isEmpty
          ? const Center(child: Text('Zatím žádné zápasy.'))
          : ListView(
              children: [
                for (final match in sorted)
                  ListTile(
                    title: Text(
                      '${dayLabel(match.date)} · '
                      '${match.startsAt.display()}–${match.endsAt.display()} · '
                      '${match.awayTeam}',
                    ),
                    subtitle: match.description.isEmpty
                        ? null
                        : Text(match.description),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) => _MatchDialog(existing: match),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _delete(context, match),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => const _MatchDialog(),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Přidat zápas'),
      ),
    );
  }
}

/// Add/edit dialog: date + two time pickers (end defaults to start + 3h),
/// opponent (required) and description (optional).
class _MatchDialog extends StatefulWidget {
  const _MatchDialog({this.existing});

  final Match? existing;

  @override
  State<_MatchDialog> createState() => _MatchDialogState();
}

class _MatchDialogState extends State<_MatchDialog> {
  Day? _date;
  HourMinute? _start;
  HourMinute? _end;
  final _awayTeam = TextEditingController();
  final _description = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _date = existing?.date;
    _start = existing?.startsAt;
    _end = existing?.endsAt;
    _awayTeam.text = existing?.awayTeam ?? '';
    _description.text = existing?.description ?? '';
  }

  @override
  void dispose() {
    _awayTeam.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = today();
    final initial = _date ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(const Duration(days: 365)),
      lastDate: DateTime(
        now.year,
        now.month,
        now.day,
      ).add(const Duration(days: 365)),
      locale: const Locale('cs'),
    );
    if (picked != null) setState(() => _date = Day.fromDateTime(picked));
  }

  Future<void> _pickStart() async {
    final picked = await pickTime(context, initial: _start);
    if (picked == null) return;
    setState(() {
      _start = picked;
      // Default a 3h span the first time a start is picked.
      if (_end == null) {
        final endMinutes = picked.minutesFromMidnight + 180;
        _end = HourMinute((endMinutes ~/ 60) % 24, endMinutes % 60);
      }
    });
  }

  Future<void> _pickEnd() async {
    final picked = await pickTime(context, initial: _end);
    if (picked != null) setState(() => _end = picked);
  }

  Future<void> _save() async {
    final date = _date;
    final start = _start;
    final end = _end;
    if (date == null || start == null || end == null) {
      snack(context, 'Vyber datum a čas.');
      return;
    }
    if (end.compareTo(start) <= 0) {
      snack(context, 'Konec musí být po začátku.');
      return;
    }
    final awayTeam = _awayTeam.text.trim();
    if (awayTeam.isEmpty) {
      snack(context, 'Vyplň soupeře.');
      return;
    }

    setState(() => _saving = true);
    final ok = await tryAction(
      context,
      () => Api.saveMatch(
        id: widget.existing?.id,
        date: date,
        startsAt: start,
        endsAt: end,
        awayTeam: awayTeam,
        description: _description.text.trim(),
      ),
      success: 'Zápas uložen. Kolidující rezervace byly zrušeny.',
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
      title: Text(widget.existing == null ? 'Přidat zápas' : 'Upravit zápas'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Datum'),
              trailing: Text(_date == null ? 'Vybrat' : dayFull(_date!)),
              onTap: _pickDate,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Začátek'),
              trailing: Text(_start?.display() ?? '--:--'),
              onTap: _pickStart,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Konec'),
              trailing: Text(_end?.display() ?? '--:--'),
              onTap: _pickEnd,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _awayTeam,
              decoration: const InputDecoration(labelText: 'Soupeř'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _description,
              decoration: const InputDecoration(labelText: 'Popis'),
            ),
          ],
        ),
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
