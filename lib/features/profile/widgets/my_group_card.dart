/// Můj profil → Moje skupina (0044). Always shown — that is how a player
/// learns groups exist at all: without one it explains itself in a line and
/// offers the invite; with an invite waiting, it asks; in a group, it lists
/// who is in, who is invited, and lets the player leave.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/collation.dart';
import '../../../domain/groups.dart';
import '../../../domain/models.dart';

class MyGroupCard extends ConsumerWidget {
  const MyGroupCard({
    super.key,
    required this.meId,
    this.invite = Api.groupInvite,
    this.accept = Api.groupAccept,
    this.decline = Api.groupDecline,
    this.leave = Api.groupLeave,
    this.cancelInvite = Api.groupCancelInvite,
  });

  final String meId;

  /// Injectable for widget tests (the Api ones need a live Supabase client).
  final Future<void> Function(String userId) invite;
  final Future<void> Function(String groupId) accept;
  final Future<void> Function(String groupId) decline;
  final Future<void> Function() leave;
  final Future<void> Function(String groupId, String userId) cancelInvite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final group = ref.watch(myGroupProvider);
    // Names only when there is someone to name — a player outside any
    // group never waits on the roster.
    final roster = group.isEmpty
        ? const <PlayerName>[]
        : ref.watch(playersProvider).value ?? const <PlayerName>[];
    String nameOf(String? id) =>
        roster.where((p) => p.id == id).firstOrNull?.displayName ?? '?';
    final theme = Theme.of(context);

    Future<void> run(Future<void> Function() action, {String? success}) =>
        tryAction(context, action, success: success, errorText: friendlyDbError);

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(Icons.group_outlined),
            title: const Text('Moje skupina'),
            subtitle: group.groupId == null
                ? const Text('Rezervujte a rušte tréninky za sebe navzájem '
                    '— třeba rodina nebo dvojice.')
                : null,
          ),
          for (final inv in group.invitesForMe)
            ListTile(
              key: ValueKey('invite-for-me:${inv.groupId}'),
              title: Text('${nameOf(inv.invitedBy)} tě zve do skupiny'),
              subtitle: Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: () => run(() => accept(inv.groupId),
                        success: 'Jsi ve skupině.'),
                    child: const Text('Přijmout'),
                  ),
                  OutlinedButton(
                    onPressed: () => run(() => decline(inv.groupId)),
                    child: const Text('Odmítnout'),
                  ),
                ],
              ),
            ),
          if (group.groupId != null) ...[
            for (final id in group.memberIds)
              if (id != meId)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.person_outline),
                  title: Text(nameOf(id)),
                ),
            for (final id in group.invitedIds)
              ListTile(
                dense: true,
                leading: const Icon(Icons.hourglass_empty),
                title: Text(nameOf(id)),
                subtitle: const Text('pozván(a)'),
                trailing: IconButton(
                  tooltip: 'Stáhnout pozvánku',
                  icon: const Icon(Icons.close),
                  onPressed: () =>
                      run(() => cancelInvite(group.groupId!, id)),
                ),
              ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: () => _pickAndInvite(context, ref, group, run),
                  child: const Text('Pozvat do skupiny…'),
                ),
                if (group.groupId != null)
                  TextButton(
                    style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error),
                    onPressed: () async {
                      final ok = await confirmDialog(
                        context,
                        title: 'Opustit skupinu?',
                        message: 'Ostatní za tebe přestanou moct '
                            'rezervovat a rušit — a ty za ně.',
                        confirmLabel: 'Opustit',
                      );
                      if (ok && context.mounted) await run(leave);
                    },
                    child: const Text('Opustit skupinu'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndInvite(
    BuildContext context,
    WidgetRef ref,
    MyGroup group,
    Future<void> Function(Future<void> Function(), {String? success}) run,
  ) async {
    // The card watches the roster only when it has names to show, so it may
    // not be loaded yet — wait for it.
    final roster = await ref.read(playersProvider.future);
    if (!context.mounted) return;
    final taken = {meId, ...group.memberIds, ...group.invitedIds};
    final candidates = [
      for (final p in roster)
        if (p.hasAccount && !taken.contains(p.id)) p,
    ]..sort((a, b) => compareCzech(a.displayName, b.displayName));
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => _InvitePicker(candidates: candidates),
    );
    if (picked == null || !context.mounted) return;
    await run(() => invite(picked), success: 'Pozvánka odeslána.');
  }
}

class _InvitePicker extends StatefulWidget {
  const _InvitePicker({required this.candidates});
  final List<PlayerName> candidates;

  @override
  State<_InvitePicker> createState() => _InvitePickerState();
}

class _InvitePickerState extends State<_InvitePicker> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  static String _fold(String s) => foldDiacritics(s).toLowerCase();

  @override
  Widget build(BuildContext context) {
    final q = _fold(_query.text.trim());
    final shown = [
      for (final p in widget.candidates)
        if (q.isEmpty || _fold(p.displayName).contains(q) || _fold(p.nick).contains(q))
          p,
    ];
    return AlertDialog(
      title: const Text('Pozvat do skupiny'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Hledat hráče',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final p in shown)
                    ListTile(
                      title: Text(p.displayName),
                      subtitle: p.nick.isEmpty ? null : Text(p.nick),
                      onTap: () => Navigator.pop(context, p.id),
                    ),
                  if (shown.isEmpty)
                    const ListTile(title: Text('Nikdo neodpovídá hledání')),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
      ],
    );
  }
}
