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
  const KioskSettingsScreen({
    super.key,
    this.resetPassword = Api.resetKioskPassword,
  });

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
      message:
          'Kiosku „${p.displayName}“ se nastaví nové heslo a to '
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

  static String _noticesLabel(KioskNoticesMode m) => switch (m) {
    KioskNoticesMode.off => 'Nezobrazovat',
    KioskNoticesMode.drawer => 'V panelu',
    KioskNoticesMode.header => 'V záhlaví',
    KioskNoticesMode.both => 'V záhlaví i v panelu',
  };

  static const _weekChoices = [0, 1, 2, 3, 4];

  static String _weeksLabel(int n, String direction) => n == 0
      ? 'Jen aktuální týden'
      : '${czechCount(n, 'týden', 'týdny', 'týdnů')} $direction';

  /// The note under the two ranges: they are only where the list opens.
  static const _rangeNote =
      'Jen výchozí rozsah — na kiosku jde posouvat celou sezónu '
      '(„Zobrazit další“).';

  /// A switch writing [column]: the bool itself, or — for a number column —
  /// what [toValue] makes of it.
  Widget _switch(
    BuildContext context,
    ScheduleSettings? settings,
    String title,
    bool value,
    String column, {
    String? subtitle,
    Object Function(bool on)? toValue,
  }) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    value: value,
    onChanged: settings == null
        ? null
        : (v) => _panel(context, settings, {
            column: toValue == null ? v : toValue(v),
          }),
  );

  Widget _choice(
    BuildContext context,
    ScheduleSettings? settings,
    String label,
    int value,
    String column,
    List<int> choices,
    String Function(int) text, {
    String? helper,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: DropdownButtonFormField<int>(
      // A value the list does not offer (set by hand) still shows.
      initialValue: value,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 2,
        border: const OutlineInputBorder(),
      ),
      items: [
        for (final n in {...choices, value}.toList()..sort())
          DropdownMenuItem(value: n, child: Text(text(n))),
      ],
      onChanged: settings == null
          ? null
          : (n) => n == null ? null : _panel(context, settings, {column: n}),
    ),
  );

  Future<void> _panel(
    BuildContext context,
    ScheduleSettings settings,
    Map<String, Object> changes,
  ) => tryAction(
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
                      () => Api.setKioskFitDay(
                        value,
                        tenantId: settings.tenantId,
                      ),
                      errorText: friendlyDbError,
                    ),
            ),
            _choice(
              context,
              settings,
              'Doba nečinnosti',
              settings?.kioskIdleSeconds ?? 60,
              'kiosk_idle_seconds',
              const [30, 60, 120, 300],
              (n) => n < 60 ? '$n s' : '${n ~/ 60} min',
              helper:
                  'Po ní kiosk zapomene vybraného hráče, zavře okna a '
                  'zápis, vrátí tabuli na dnešek a panel do výchozího stavu.',
            ),
            _switch(
              context,
              settings,
              'Kiosk: posun do minulosti',
              (settings?.kioskPastDays ?? 0) > 0,
              'kiosk_past_days',
              subtitle:
                  'Návštěvník může tabuli posunout o pár dní zpět '
                  'a podívat se, kdo trénoval. Po době nečinnosti se '
                  'tabule vrátí na dnešek.',
              toValue: (on) => on ? 7 : 0,
            ),
            if ((settings?.kioskPastDays ?? 0) > 0)
              _choice(
                context,
                settings,
                'Jak daleko zpět',
                settings?.kioskPastDays ?? 7,
                'kiosk_past_days',
                const [1, 2, 3, 7, 14, 30],
                (n) => czechCount(n, 'den', 'dny', 'dní'),
              ),
            const SizedBox(height: 8),
            _choice(
              context,
              settings,
              'Velikost zápisu',
              settings?.kioskZapisPercent ?? 80,
              'kiosk_zapis_percent',
              const [60, 70, 80, 90, 100],
              (n) => n == 100 ? 'Celá obrazovka (s křížkem)' : '$n % obrazovky',
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: DropdownButtonFormField<KioskNoticesMode>(
                initialValue:
                    settings?.kioskNoticesMode ?? KioskNoticesMode.both,
                decoration: const InputDecoration(
                  labelText: 'Nástěnka na kiosku',
                  helperText:
                      'Záhlaví = nadpis jednoho oznamu nahoře mezi '
                      'časem a Rezervovat, oznamy se střídají.',
                  helperMaxLines: 2,
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final m in KioskNoticesMode.values)
                    DropdownMenuItem(value: m, child: Text(_noticesLabel(m))),
                ],
                onChanged: settings == null
                    ? null
                    : (m) => m == null
                          ? null
                          : _panel(context, settings, {
                              'kiosk_notices_mode': m.name,
                            }),
              ),
            ),
            if ((settings?.kioskNoticesMode ?? KioskNoticesMode.both) !=
                KioskNoticesMode.off)
              _choice(
                context,
                settings,
                'Střídání oznamů',
                settings?.kioskNoticesRotationSeconds ?? 12,
                'kiosk_notices_rotation_seconds',
                const [6, 8, 12, 20, 30, 60],
                (n) => 'po $n s',
              ),
            const SizedBox(height: 24),
            Text(
              'Panel vpravo',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text(
              'Postranní panel kiosku ukazuje nástěnku a zápasy. Návštěvník '
              'ho rozbalí a sbalí, po době nečinnosti se vrátí do výchozího '
              'stavu. Které oznamy se na kiosku ukážou, volíš přímo na '
              'nástěnce (⋮ u oznamu).',
            ),
            _switch(
              context,
              settings,
              'Panel vpravo',
              settings?.kioskPanelEnabled ?? true,
              'kiosk_panel_enabled',
            ),
            if (settings?.kioskPanelEnabled ?? true) ...[
              _choice(
                context,
                settings,
                'Šířka panelu',
                settings?.kioskDrawerWidth ?? 440,
                'kiosk_drawer_width',
                const [360, 440, 520, 600, 720],
                (n) => '$n px',
              ),
              _switch(
                context,
                settings,
                'Panel je výchozně rozbalený',
                settings?.kioskDrawerOpen ?? false,
                'kiosk_drawer_open',
                subtitle:
                    'Vypnuto = panel je skrytý a rozbalí se '
                    'tlačítkem na okraji obrazovky.',
              ),
              _switch(
                context,
                settings,
                'Zápasy v panelu',
                settings?.kioskShowMatches ?? true,
                'kiosk_show_matches',
                subtitle:
                    'Klepnutím na odehraný zápas se otevře jeho '
                    'zápis.',
              ),
              if (settings?.kioskShowMatches ?? true) ...[
                _switch(
                  context,
                  settings,
                  'Následující zápasy',
                  settings?.kioskShowUpcoming ?? true,
                  'kiosk_show_upcoming',
                ),
                _switch(
                  context,
                  settings,
                  'Zápasy sledují tabuli',
                  settings?.kioskFollowBoard ?? true,
                  'kiosk_follow_board',
                  subtitle: 'Když návštěvník posune tabuli na jiné dny, '
                      'seznam zápasů naskočí na zápasy těch dnů.',
                ),
                _choice(
                  context,
                  settings,
                  'Odehrané zápasy',
                  settings?.kioskWeeksBack ?? 2,
                  'kiosk_weeks_back',
                  _weekChoices,
                  (n) => _weeksLabel(n, 'zpět'),
                  helper: _rangeNote,
                ),
                if (settings?.kioskShowUpcoming ?? true)
                  _choice(
                    context,
                    settings,
                    'Budoucí zápasy',
                    settings?.kioskWeeksAhead ?? 1,
                    'kiosk_weeks_ahead',
                    _weekChoices,
                    (n) => _weeksLabel(n, 'dopředu'),
                    helper: _rangeNote,
                  ),
              ],
              _switch(
                context,
                settings,
                'Aktuální zápas přes celý panel',
                settings?.kioskLiveMode ?? true,
                'kiosk_live_mode',
                subtitle:
                    'Zápas, který se hraje a má data, zabere celý '
                    'panel (souboje) a panel zůstane rozbalený — i když '
                    'ho návštěvník zavře, po době nečinnosti se rozbalí '
                    'znovu.',
              ),
              if (settings?.kioskLiveMode ?? true)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: DropdownButtonFormField<KioskLiveLayout>(
                    initialValue:
                        settings?.kioskLiveLayout ?? KioskLiveLayout.full,
                    decoration: const InputDecoration(
                      labelText: 'Zobrazení aktuálního zápasu',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: KioskLiveLayout.full,
                        child: Text('Podrobné — karty soubojů'),
                      ),
                      DropdownMenuItem(
                        value: KioskLiveLayout.compact,
                        child: Text('Kompaktní — bez posouvání'),
                      ),
                      DropdownMenuItem(
                        value: KioskLiveLayout.table,
                        child: Text('Tabulka — souboj na řádek'),
                      ),
                    ],
                    onChanged: settings == null
                        ? null
                        : (m) => m == null
                            ? null
                            : _panel(
                                context,
                                settings,
                                {'kiosk_live_layout': m.name},
                              ),
                  ),
                ),
              if (settings?.kioskLiveMode ?? true)
                _choice(
                  context,
                  settings,
                  'Střídání aktuálních zápasů',
                  settings?.kioskLiveRotationSeconds ?? 12,
                  'kiosk_live_rotation_seconds',
                  const [6, 8, 12, 20, 30, 60],
                  (n) => 'po $n s',
                ),
              if ((settings?.kioskShowNotices ?? true) &&
                  (settings?.kioskShowMatches ?? true))
                _choice(
                  context,
                  settings,
                  'Podíl nástěnky na výšce panelu',
                  settings?.kioskNoticesShare ?? 40,
                  'kiosk_notices_share',
                  const [20, 30, 40, 50, 60, 70],
                  (n) => '$n %',
                ),
            ],
            const SizedBox(height: 24),
            Text(
              'Adresa pro tablet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text(
              'Otevři ji v prohlížeči tabletu a přihlas se kioskovým účtem '
              'níž. Tablet pak ukazuje tabuli a rezervuje se z něj bez '
              'přihlašování hráčů.',
            ),
            const SizedBox(height: 8),
            CopyableAddress(url: _kioskUrl()),
            const SizedBox(height: 24),
            Text(
              'Kioskové účty',
              style: Theme.of(context).textTheme.titleMedium,
            ),
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
