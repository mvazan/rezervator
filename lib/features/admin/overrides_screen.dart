import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';

/// Admin: manage per-day overrides (closures and custom block sets) that
/// take precedence over the weekly training-day rule.
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

  String _subtitle(DayOverride override) {
    if (override.closed) {
      return 'Zavřeno — ${override.reason}';
    }
    final blockIds = override.blockIds;
    if (blockIds == null) {
      return 'Otevřeno (výchozí bloky)';
    }
    return 'Vlastní bloky (${blockIds.length})';
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
    final sorted = [...overrides]..sort((a, b) => a.date.compareTo(b.date));

    return Scaffold(
      appBar: AppBar(title: const Text('Výjimky dnů')),
      body: sorted.isEmpty
          ? const Center(child: Text('Zatím žádné výjimky.'))
          : ListView(
              children: [
                for (final override in sorted)
                  ListTile(
                    title: Text(dayFull(override.date)),
                    subtitle: Text(_subtitle(override)),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _delete(context, override),
                    ),
                  ),
              ],
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

/// Add-override dialog: date picker, closed/open mode radio, and — when
/// open — an optional custom block selection.
class _OverrideDialog extends ConsumerStatefulWidget {
  const _OverrideDialog();

  @override
  ConsumerState<_OverrideDialog> createState() => _OverrideDialogState();
}

class _OverrideDialogState extends ConsumerState<_OverrideDialog> {
  Day? _date;
  bool _closed = true;
  final _reason = TextEditingController();
  final Set<String> _selectedBlockIds = {};
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
    if (picked != null) setState(() => _date = Day.fromDateTime(picked));
  }

  Future<void> _save() async {
    final date = _date;
    if (date == null) {
      snack(context, 'Vyber datum.');
      return;
    }
    if (_closed && _reason.text.trim().isEmpty) {
      snack(context, 'Vyplň důvod.');
      return;
    }

    setState(() => _saving = true);
    final ok = await tryAction(
      context,
      () => Api.setDayOverride(
        date: date,
        closed: _closed,
        reason: _closed ? _reason.text.trim() : '',
        blockIds: _closed || _selectedBlockIds.isEmpty
            ? null
            : _selectedBlockIds.toList(),
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
    final blocks = ref.watch(timeBlocksProvider).value ?? const <TimeBlock>[];

    return AlertDialog(
      title: const Text('Přidat výjimku'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Datum'),
              trailing: Text(_date == null ? 'Vybrat' : dayFull(_date!)),
              onTap: _pickDate,
            ),
            RadioGroup<bool>(
              groupValue: _closed,
              onChanged: (v) => setState(() => _closed = v!),
              child: const Column(
                children: [
                  RadioListTile<bool>(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Zavřeno'),
                    value: true,
                  ),
                  RadioListTile<bool>(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Otevřeno'),
                    value: false,
                  ),
                ],
              ),
            ),
            if (_closed)
              Padding(
                padding: const EdgeInsets.only(left: 16, bottom: 8),
                child: TextField(
                  controller: _reason,
                  decoration: const InputDecoration(
                    labelText: 'Důvod',
                    hintText: 'Malování drah',
                  ),
                ),
              ),
            if (!_closed)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final block in blocks)
                      FilterChip(
                        label: Text(
                          block.active
                              ? block.label
                              : '${block.label} (neaktivní)',
                        ),
                        selected: _selectedBlockIds.contains(block.id),
                        onSelected: (selected) => setState(() {
                          if (selected) {
                            _selectedBlockIds.add(block.id);
                          } else {
                            _selectedBlockIds.remove(block.id);
                          }
                        }),
                      ),
                  ],
                ),
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
