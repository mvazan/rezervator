import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/palette.dart';
import 'widgets/admin_body.dart';
import 'widgets/color_picker.dart';

/// Admin: manage clubs (oddíly) — list + add/edit/delete, each backed by
/// [Api.upsertClub]/[Api.deleteClub].
class ClubsScreen extends ConsumerWidget {
  const ClubsScreen({super.key});

  Future<void> _addOrEdit(BuildContext context, {Club? existing}) async {
    final result = await showDialog<(String, int)>(
      context: context,
      builder: (_) => _ClubDialog(existing: existing),
    );
    if (result == null || !context.mounted) return;
    final (name, colorIndex) = result;
    await tryAction(
      context,
      () =>
          Api.upsertClub(id: existing?.id, name: name, colorIndex: colorIndex),
      success: 'Uloženo.',
      errorText: friendlyDbError,
    );
  }

  Future<void> _delete(BuildContext context, Club club) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Smazat oddíl?',
      message:
          'Opravdu smazat oddíl „${club.name}"? Hráči zůstanou bez oddílu.',
    );
    if (!confirmed || !context.mounted) return;
    await tryAction(
      context,
      () => Api.deleteClub(club.id),
      success: 'Smazáno.',
      errorText: friendlyDbError,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    if (profile?.isAdmin != true) {
      return Scaffold(
        appBar: AppBar(title: const Text('Oddíly')),
        body: const Center(child: Text('Jen pro správce.')),
      );
    }

    final clubs = ref.watch(clubsProvider).value ?? const <Club>[];

    return Scaffold(
      appBar: AppBar(title: const Text('Oddíly')),
      body: AdminBody(
        child: clubs.isEmpty
            ? const Center(child: Text('Zatím žádné oddíly.'))
            : ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  for (final club in clubs)
                    ListTile(
                      leading: _ClubSwatch(colorIndex: club.colorIndex),
                      title: Text(club.name),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () =>
                                _addOrEdit(context, existing: club),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(context, club),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addOrEdit(context),
        icon: const Icon(Icons.add),
        label: const Text('Přidat oddíl'),
      ),
    );
  }
}

/// Small circular color swatch shown next to a club's name in the list.
class _ClubSwatch extends StatelessWidget {
  const _ClubSwatch({required this.colorIndex});

  final int colorIndex;

  @override
  Widget build(BuildContext context) {
    final color =
        ClubColors.of(colorIndex, Brightness.dark)?.$1 ??
        Theme.of(context).colorScheme.surfaceContainerHighest;
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// Add/edit dialog for a club: name field + [ColorPickerGrid].
class _ClubDialog extends StatefulWidget {
  const _ClubDialog({this.existing});

  final Club? existing;

  @override
  State<_ClubDialog> createState() => _ClubDialogState();
}

class _ClubDialogState extends State<_ClubDialog> {
  final _name = TextEditingController();
  late int _colorIndex;

  @override
  void initState() {
    super.initState();
    _name.text = widget.existing?.name ?? '';
    _colorIndex = widget.existing?.colorIndex ?? -1;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      snack(context, 'Vyplň název oddílu.');
      return;
    }
    Navigator.of(context).pop((name, _colorIndex));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Přidat oddíl' : 'Upravit oddíl'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Název'),
            ),
            const SizedBox(height: 16),
            ColorPickerGrid(
              selected: _colorIndex,
              noneValue: -1,
              noneLabel: 'Žádná',
              onChanged: (index) => setState(() => _colorIndex = index),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Zrušit'),
        ),
        FilledButton(onPressed: _save, child: const Text('Uložit')),
      ],
    );
  }
}
