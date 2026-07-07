import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';

/// Admin: manage the list of daily time blocks (start/end, ordering,
/// active/inactive).
class BlocksScreen extends ConsumerWidget {
  const BlocksScreen({super.key});

  Future<void> _delete(BuildContext context, TimeBlock block) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Smazat blok?',
      message: 'Opravdu smazat blok ${block.label}?',
    );
    if (!confirmed) return;
    if (!context.mounted) return;

    try {
      await Api.deleteTimeBlock(block.id);
      if (context.mounted) snack(context, 'Blok smazán.');
      return;
    } on PostgrestException catch (e) {
      if (e.code != '23503') {
        if (context.mounted) snack(context, friendlyDbError(e));
        return;
      }
      // FK restrict: block already has reservations — deactivate instead.
    }

    if (!context.mounted) return;
    await tryAction(
      context,
      () => Api.updateTimeBlock(block.id, active: false),
      success: 'Blok už má rezervace — místo smazání deaktivován.',
      errorText: friendlyDbError,
    );
  }

  Future<void> _openDialog(BuildContext context, List<TimeBlock> blocks,
      {TimeBlock? existing}) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _BlockDialog(existing: existing, blocks: blocks),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    if (profile?.isAdmin != true) {
      return Scaffold(
        appBar: AppBar(title: const Text('Tréninkové bloky')),
        body: const Center(child: Text('Jen pro správce.')),
      );
    }

    final blocks = ref.watch(timeBlocksProvider).value ?? const <TimeBlock>[];

    return Scaffold(
      appBar: AppBar(title: const Text('Tréninkové bloky')),
      body: ListView(
        children: [
          for (final block in blocks)
            ListTile(
              title: Text(block.label),
              subtitle: Text('Pozice ${block.position}'),
              leading: Switch(
                value: block.active,
                onChanged: (active) => tryAction(
                  context,
                  () => Api.updateTimeBlock(block.id, active: active),
                  errorText: friendlyDbError,
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () =>
                        _openDialog(context, blocks, existing: block),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(context, block),
                  ),
                ],
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openDialog(context, blocks),
        icon: const Icon(Icons.add),
        label: const Text('Přidat blok'),
      ),
    );
  }
}

/// Add/edit dialog: two time pickers for start/end.
class _BlockDialog extends StatefulWidget {
  const _BlockDialog({required this.existing, required this.blocks});

  final TimeBlock? existing;
  final List<TimeBlock> blocks;

  @override
  State<_BlockDialog> createState() => _BlockDialogState();
}

class _BlockDialogState extends State<_BlockDialog> {
  HourMinute? _start;
  HourMinute? _end;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _start = widget.existing?.startsAt;
    _end = widget.existing?.endsAt;
  }

  Future<void> _pickStart() async {
    final picked = await pickTime(context, initial: _start);
    if (picked != null) setState(() => _start = picked);
  }

  Future<void> _pickEnd() async {
    final picked = await pickTime(context, initial: _end);
    if (picked != null) setState(() => _end = picked);
  }

  Future<void> _save() async {
    final start = _start;
    final end = _end;
    if (start == null || end == null) {
      snack(context, 'Vyber začátek i konec.');
      return;
    }
    if (end.compareTo(start) <= 0) {
      snack(context, 'Konec musí být po začátku.');
      return;
    }

    setState(() => _saving = true);
    final existing = widget.existing;
    final ok = await tryAction(
      context,
      () => existing == null
          ? Api.addTimeBlock(
              start,
              end,
              widget.blocks.isEmpty
                  ? 0
                  : widget.blocks
                          .map((b) => b.position)
                          .reduce((a, b) => a > b ? a : b) +
                      1,
            )
          : Api.updateTimeBlock(existing.id, startsAt: start, endsAt: end),
      success: 'Uloženo.',
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
      title: Text(widget.existing == null ? 'Nový blok' : 'Upravit blok'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: const Text('Začátek'),
            trailing: Text(_start?.display() ?? '--:--'),
            onTap: _pickStart,
          ),
          ListTile(
            title: const Text('Konec'),
            trailing: Text(_end?.display() ?? '--:--'),
            onTap: _pickEnd,
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
