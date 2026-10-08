import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/kiosk_url.dart';
import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/labels.dart' show czechCount;
import '../../domain/models.dart';
import '../auth/update_screen.dart' show UpdateScreen;
import 'widgets/admin_scaffold.dart';
import 'widgets/copyable_address.dart';

/// Admin: kiosk-specific settings (the board theme) and the kiosk accounts
/// themselves. The accounts live here, not among Hráči: a kiosk is the
/// alley's tablet, not a person, and this is the only place one can be
/// turned back into a player.
class KioskSettingsScreen extends ConsumerWidget {
  const KioskSettingsScreen({super.key, this.resetPassword = Api.resetKioskPassword});

  /// Injectable so a widget test can drive the dialogs without the edge
  /// function (functions.invoke encodes its body on an isolate, which a
  /// pumped test never lets finish).
  final Future<String> Function(String userId) resetPassword;

  Future<void> _returnToPlayer(BuildContext context, Profile p) => tryAction(
        context,
        () => Api.setRole(p.id, Role.player),
        success: 'Účet vrácen mezi hráče.',
        errorText: friendlyDbError,
      );

  /// Sets a new password and shows it — the current one cannot be read
  /// back (Supabase keeps only a hash), so this is the way to credentials
  /// for a tablet. Shown once: leaving the dialog means setting another.
  Future<void> _newPassword(BuildContext context, Profile p) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Nastavit nové heslo?',
      message: 'Kiosku „${p.displayName}“ se nastaví nové heslo a to '
          'dosavadní přestane platit. Už přihlášený tablet běží dál, nové '
          'heslo bude potřebovat až při dalším přihlášení.',
      confirmLabel: 'Nastavit',
    );
    if (!confirmed || !context.mounted) return;

    String? password;
    final ok = await tryAction(
      context,
      () async => password = await resetPassword(p.id),
      errorText: friendlyDbError,
    );
    if (!ok || password == null || !context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Nové heslo kiosku'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Přihlašovací jméno: ${p.email}'),
            const SizedBox(height: 12),
            SelectableText(
              password!,
              style: Theme.of(dialogContext).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            const Text(
              'Zapiš si ho teď — znovu ho appka nezobrazí, jen nastaví '
              'další nové.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: password!));
              if (dialogContext.mounted) {
                snack(dialogContext, 'Heslo zkopírováno.');
              }
            },
            child: const Text('Kopírovat'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Hotovo'),
          ),
        ],
      ),
    );
  }

  /// How far back the panel lists finished matches, in days (0 = only the
  /// next match), as the dropdown offers it.
  static const _historyChoices = [0, 7, 14, 21, 28, 56, 84];

  static String _historyLabel(int days) => days == 0
      ? 'Jen příští zápas'
      : czechCount(days ~/ 7, 'týden', 'týdny', 'týdnů');

  Future<void> _panel(BuildContext context, ScheduleSettings settings,
          Map<String, Object> changes) =>
      tryAction(
        context,
        () => Api.setKioskPanel(changes, tenantId: settings.tenantId),
        errorText: friendlyDbError,
      );

  /// Where the app is running (the web build knows; an alley hosting its
  /// own copy under a sub-path included) — or, on Android, where the public
  /// web app lives, because a phone has no address to offer a tablet.
  String _kioskUrl() =>
      kioskUrlFrom(kIsWeb ? Uri.base : Uri.parse(UpdateScreen.webUrl));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kiosks = [
      for (final p in ref.watch(profilesProvider).value ?? const <Profile>[])
        if (p.role == Role.kiosk) p,
    ];
    return AdminScaffold(
      title: 'Kiosk',
      body: AsyncBody(
        value: ref.watch(settingsProvider),
        onRetry: () => ref.invalidate(settingsProvider),
        // The settings row is null until the backend is seeded — the
        // switches then show the defaults, disabled.
        builder: (settings) => ListView(
          padding: padWithSystemInset(context, const EdgeInsets.all(16)),
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Kiosk: tmavý režim'),
              subtitle: const Text('Vypnuto = kiosková obrazovka světlá.'),
              value: settings?.kioskDark ?? true,
              onChanged: settings == null
                  ? null
                  : (value) => tryAction(
                      context,
                      () =>
                          Api.setKioskDark(value, tenantId: settings.tenantId),
                      errorText: friendlyDbError,
                    ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Kiosk: celý den na obrazovku'),
              subtitle: const Text(
                'Zapnuto = celý rozvrh dne se vejde na obrazovku bez '
                'posouvání. Vypnuto = sloty mají pohodlnou velikost a tabule '
                'se posouvá (po nečinnosti se sama vrátí na aktuální čas).',
              ),
              value: settings?.kioskFitDay ?? true,
              onChanged: settings == null
                  ? null
                  : (value) => tryAction(
                      context,
                      () => Api.setKioskFitDay(value,
                          tenantId: settings.tenantId),
                      errorText: friendlyDbError,
                    ),
            ),
            const SizedBox(height: 24),
            Text('Panel vpravo',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text(
              'Postranní panel kiosku ukazuje nástěnku a zápasy. Návštěvník '
              'ho rozbalí a sbalí, po minutě bez dotyku se vrátí do výchozího '
              'stavu. Které oznamy se na kiosku ukážou, volíš přímo na '
              'nástěnce (⋮ u oznamu).',
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Nástěnka v panelu'),
              value: settings?.kioskShowNotices ?? true,
              onChanged: settings == null
                  ? null
                  : (value) =>
                      _panel(context, settings, {'kiosk_show_notices': value}),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Zápasy v panelu'),
              subtitle: const Text(
                'Příští zápas a odehrané zápasy; klepnutím na odehraný se '
                'otevře jeho zápis.',
              ),
              value: settings?.kioskShowMatches ?? true,
              onChanged: settings == null
                  ? null
                  : (value) =>
                      _panel(context, settings, {'kiosk_show_matches': value}),
            ),
            if (settings?.kioskShowMatches ?? true)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: DropdownButtonFormField<int>(
                  initialValue: _historyChoices
                          .contains(settings?.kioskMatchesHistoryDays ?? 21)
                      ? settings?.kioskMatchesHistoryDays ?? 21
                      : 21,
                  decoration: const InputDecoration(
                    labelText: 'Odehrané zápasy z posledních',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final days in _historyChoices)
                      DropdownMenuItem(
                        value: days,
                        child: Text(_historyLabel(days)),
                      ),
                  ],
                  onChanged: settings == null
                      ? null
                      : (days) => days == null
                          ? null
                          : _panel(context, settings,
                              {'kiosk_matches_history_days': days}),
                ),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Panel je výchozně rozbalený'),
              subtitle: const Text(
                'Vypnuto = na kiosku je jen úzký pruh, panel se rozbalí '
                'klepnutím.',
              ),
              value: settings?.kioskDrawerOpen ?? false,
              onChanged: settings == null
                  ? null
                  : (value) =>
                      _panel(context, settings, {'kiosk_drawer_open': value}),
            ),
            const SizedBox(height: 24),
            Text('Adresa pro tablet',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text(
              'Otevři ji v prohlížeči tabletu a přihlas se kioskovým účtem '
              'níž. Tablet pak ukazuje tabuli a rezervuje se z něj bez '
              'přihlašování hráčů.',
            ),
            const SizedBox(height: 8),
            CopyableAddress(url: _kioskUrl()),
            const SizedBox(height: 24),
            Text('Kioskové účty',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            if (kiosks.isEmpty)
              const Text(
                'Zatím žádný. Účet se kioskem stane v Hráčích přes '
                '„Nastavit jako kiosk“; pak zmizí ze seznamu hráčů a objeví '
                'se tady.',
              ),
            for (final p in kiosks)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.tablet_outlined),
                title: Text(p.displayName),
                subtitle: Text(p.email),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) => value == 'password'
                      ? _newPassword(context, p)
                      : _returnToPlayer(context, p),
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: 'password',
                      child: Text('Nastavit nové heslo…'),
                    ),
                    PopupMenuItem(
                      value: 'player',
                      child: Text('Vrátit mezi hráče'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
