/// A list of lead times — "2 h předem", "1 den předem" — with add and
/// remove, and the little number+unit dialog behind the add.
///
/// Two places want exactly this list. The Google calendar card has had it
/// since 0032: what GOOGLE should remind about, one list per calendar. Můj
/// profil now has its own (0040): what the APP should remind about, for a
/// player who has no Google calendar at all — or who wants both, which is
/// nobody's business but theirs.
///
/// Every change saves at once, as it always did here: the list is the
/// state, and a reminder added and then abandoned unsaved would be a lie the
/// row is telling. The sheet re-reads its list from [minutesOf] on every
/// build, so it redraws itself when the save lands.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../domain/models.dart';

/// Opens the list. [minutesOf] is re-read on every build (the stream behind
/// it decides what the rows say); [onChanged] is handed the whole new list.
Future<void> showRemindersSheet(
  BuildContext context, {
  required String title,
  required String emptyCopy,
  required List<int> Function(WidgetRef ref) minutesOf,
  required Future<void> Function(List<int> minutes) onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => Consumer(
      builder: (context, ref, _) {
        final minutes = minutesOf(ref);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (minutes.isEmpty)
                ListTile(
                  leading: const Icon(Icons.notifications_off_outlined),
                  title: const Text('Žádné připomínky'),
                  subtitle: Text(emptyCopy),
                ),
              for (final m in minutes)
                ListTile(
                  leading: const Icon(Icons.notifications_none_outlined),
                  title: Text(reminderOffsetLabel(m)),
                  trailing: IconButton(
                    tooltip: 'Odebrat',
                    icon: const Icon(Icons.close),
                    onPressed: () => tryAction(
                      context,
                      () => onChanged([
                        for (final x in minutes)
                          if (x != m) x,
                      ]),
                    ),
                  ),
                ),
              if (minutes.length < maxCalendarReminders)
                ListTile(
                  leading: const Icon(Icons.add),
                  title: const Text('Přidat připomínku'),
                  onTap: () => _addReminder(context, minutes, onChanged),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    ),
  );
}

/// "Number + unit" dialog; converts to minutes and saves.
Future<void> _addReminder(
  BuildContext context,
  List<int> current,
  Future<void> Function(List<int> minutes) onChanged,
) async {
  final minutes = await showDialog<int>(
    context: context,
    builder: (_) => const _ReminderDialog(),
  );
  if (minutes == null || !context.mounted) return;
  if (minutes > maxReminderMinutes) {
    snack(context, 'Nejdál to jde 4 týdny (28 dní) předem.');
    return;
  }
  await tryAction(context, () => onChanged([...current, minutes]));
}

/// "Kolik" + hodiny/dny; pops with the offset in minutes (never with zero
/// or garbage — the button just waits for a real number). Owns its text
/// controller, so the exit animation can still rebuild the field safely.
class _ReminderDialog extends StatefulWidget {
  const _ReminderDialog();

  @override
  State<_ReminderDialog> createState() => _ReminderDialogState();
}

class _ReminderDialogState extends State<_ReminderDialog> {
  final _amount = TextEditingController();
  var _unit = _ReminderUnit.hours;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _submit() {
    final n = int.tryParse(_amount.text.trim());
    if (n == null || n <= 0) return;
    Navigator.pop(context, n * _unit.inMinutes);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Připomínka předem'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Kolik'),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          SegmentedButton<_ReminderUnit>(
            segments: [
              for (final u in _ReminderUnit.values)
                ButtonSegment(value: u, label: Text(u.label)),
            ],
            selected: {_unit},
            onSelectionChanged: (s) => setState(() => _unit = s.first),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Přidat')),
      ],
    );
  }
}

enum _ReminderUnit {
  hours('hodiny', 60),
  days('dny', 1440);

  const _ReminderUnit(this.label, this.inMinutes);

  final String label;
  final int inMinutes;
}
