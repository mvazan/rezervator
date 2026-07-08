import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';

/// Self-service profile screen: every signed-in user can see their display
/// name/club (set at registration by an admin) and edit their own board
/// nick. Structured so future editable fields slot in as more list tiles.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  Future<void> _editNick(BuildContext context, String currentNick) async {
    final input = await promptText(
      context,
      title: 'Přezdívka na tabuli',
      hint: 'Tom P.',
      initial: currentNick,
      confirmLabel: 'Uložit',
    );
    if (input == null || !context.mounted) return;
    await tryAction(
      context,
      () => Api.setNick(currentUserId!, input),
      success: 'Uloženo.',
      errorText: friendlyDbError,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;

    return Scaffold(
      appBar: AppBar(title: const Text('Můj profil')),
      body: profile == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        title: const Text('Jméno'),
                        subtitle: Text(profile.displayName),
                      ),
                      ListTile(
                        title: const Text('Oddíl'),
                        subtitle: Text(
                          profile.club.isEmpty ? '—' : profile.club,
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Jméno a oddíl nastavuje správce.',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: ListTile(
                    title: const Text('Přezdívka na tabuli'),
                    subtitle: Text(
                      profile.nick.isEmpty ? 'nenastavena' : profile.nick,
                    ),
                    trailing: TextButton(
                      onPressed: () => _editNick(context, profile.nick),
                      child: const Text('Upravit'),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
