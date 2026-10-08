import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/kiosk_url.dart';
import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../auth/update_screen.dart' show UpdateScreen;
import 'widgets/admin_scaffold.dart';
import 'widgets/copyable_address.dart';
import 'widgets/number_setting_field.dart';

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
    KioskNoticesMode.drawer => 'Jen v panelu',
    KioskNoticesMode.header => 'Jen v záhlaví',
    KioskNoticesMode.both => 'V záhlaví i v panelu',
  };

  /// The note under the two ranges: they are only where the list opens.
  static const _rangeNote =
      'Jen výchozí rozsah — na kiosku jde posouvat celou sezónu '
      '(„Zobrazit další“).';

  /// A section: its title, a line on what it is about, and its options.
  Widget _section(
    BuildContext context,
    String title,
    String about,
    List<Widget> children,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(about, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 8),
        ...children,
      ],
    ),
  );

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

  /// A number the admin types, between [min] and [max], written to
  /// [column] on Enter or when the field loses focus.
  Widget _number(
    BuildContext context,
    ScheduleSettings? settings,
    String label,
    int value,
    String column, {
    required String unit,
    required int min,
    required int max,
    String? helper,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: NumberSettingField(
      key: ValueKey(column),
      label: label,
      value: value,
      unit: unit,
      min: min,
      max: max,
      helper: helper,
      onChanged: settings == null
          ? null
          : (n) => _panel(context, settings, {column: n}),
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
            _section(
              context,
              'Obrazovka kiosku',
              'Tablet na zdi kuželny: jak vypadá tabule a co se stane, když '
                  'se ho nikdo nedotýká.',
              [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Tmavý režim'),
                  subtitle: const Text('Vypnuto = světlá obrazovka.'),
                  value: settings?.kioskDark ?? true,
                  onChanged: settings == null
                      ? null
                      : (value) => tryAction(
                          context,
                          () => Api.setKioskDark(
                            value,
                            tenantId: settings.tenantId,
                          ),
                          errorText: friendlyDbError,
                        ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Celý den na obrazovku'),
                  subtitle: const Text(
                    'Zapnuto = rozvrh celého dne se vejde na obrazovku bez '
                    'posouvání. Vypnuto = sloty mají pohodlnou velikost a '
                    'tabule se posouvá; po době nečinnosti se vrátí na '
                    'aktuální čas.',
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
                _number(
                  context,
                  settings,
                  'Doba nečinnosti',
                  settings?.kioskIdleSeconds ?? 60,
                  'kiosk_idle_seconds',
                  unit: 's',
                  min: 10,
                  max: 3600,
                  helper:
                      'Po tolika sekundách bez dotyku kiosk zapomene '
                      'vybraného hráče, zavře okna i zápis, vrátí tabuli na '
                      'dnešek a panel do výchozího stavu.',
                ),
                _switch(
                  context,
                  settings,
                  'Posun tabule do minulosti',
                  (settings?.kioskPastDays ?? 0) > 0,
                  'kiosk_past_days',
                  subtitle:
                      'Návštěvník může tabuli posunout o pár dní zpět a '
                      'podívat se, kdo trénoval.',
                  toValue: (on) => on ? 7 : 0,
                ),
                if ((settings?.kioskPastDays ?? 0) > 0)
                  _number(
                    context,
                    settings,
                    'Kolik dní zpět',
                    settings?.kioskPastDays ?? 7,
                    'kiosk_past_days',
                    unit: 'dní',
                    min: 1,
                    max: 365,
                  ),
              ],
            ),
            _section(
              context,
              'Nástěnka',
              'Oznamy z nástěnky klubu. Který oznam se na kiosku ukáže, '
                  'volíš přímo na nástěnce (⋮ u oznamu).',
              [
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 12),
                  child: DropdownButtonFormField<KioskNoticesMode>(
                    initialValue:
                        settings?.kioskNoticesMode ?? KioskNoticesMode.both,
                    decoration: const InputDecoration(
                      labelText: 'Kde se oznamy zobrazí',
                      helperText:
                          'Záhlaví = stavový řádek nahoře, nadpis jednoho '
                          'oznamu. Panel = postranní panel vpravo (níž).',
                      helperMaxLines: 3,
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final m in KioskNoticesMode.values)
                        DropdownMenuItem(
                          value: m,
                          child: Text(_noticesLabel(m)),
                        ),
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
                  _number(
                    context,
                    settings,
                    'Střídání oznamů',
                    settings?.kioskNoticesRotationSeconds ?? 12,
                    'kiosk_notices_rotation_seconds',
                    unit: 's',
                    min: 3,
                    max: 600,
                    helper:
                        'Po kolika sekundách se ukáže další oznam '
                        '(v záhlaví i v panelu).',
                  ),
              ],
            ),
            _section(
              context,
              'Postranní panel',
              'Panel vpravo vedle tabule s nástěnkou a zápasy. Návštěvník '
                  'ho rozbalí a sbalí tlačítkem na okraji obrazovky; po době '
                  'nečinnosti se vrátí do výchozího stavu.',
              [
                _switch(
                  context,
                  settings,
                  'Panel zapnutý',
                  settings?.kioskPanelEnabled ?? true,
                  'kiosk_panel_enabled',
                  subtitle: 'Vypnuto = kiosk ukazuje jen tabuli.',
                ),
                if (settings?.kioskPanelEnabled ?? true) ...[
                  _switch(
                    context,
                    settings,
                    'Výchozně rozbalený',
                    settings?.kioskDrawerOpen ?? false,
                    'kiosk_drawer_open',
                    subtitle:
                        'Vypnuto = po době nečinnosti je panel skrytý a '
                        'čeká na tlačítko.',
                  ),
                  _number(
                    context,
                    settings,
                    'Šířka panelu',
                    settings?.kioskDrawerWidth ?? 440,
                    'kiosk_drawer_width',
                    unit: 'px',
                    min: 240,
                    max: 1200,
                    helper: 'Na užší obrazovce zabere nejvýš 60 % šířky.',
                  ),
                  if ((settings?.kioskShowNotices ?? true) &&
                      (settings?.kioskShowMatches ?? true))
                    _number(
                      context,
                      settings,
                      'Podíl nástěnky na výšce panelu',
                      settings?.kioskNoticesShare ?? 40,
                      'kiosk_notices_share',
                      unit: '%',
                      min: 10,
                      max: 90,
                      helper:
                          'Kolik výšky panelu dostanou oznamy; zbytek mají '
                          'zápasy.',
                    ),
                  _switch(
                    context,
                    settings,
                    'Zápasy v panelu',
                    settings?.kioskShowMatches ?? true,
                    'kiosk_show_matches',
                    subtitle:
                        'Seznam zápasů kuželny. Klepnutím na odehraný '
                        'zápas se otevře jeho zápis.',
                  ),
                  if (settings?.kioskShowMatches ?? true) ...[
                    _switch(
                      context,
                      settings,
                      'I budoucí zápasy',
                      settings?.kioskShowUpcoming ?? true,
                      'kiosk_show_upcoming',
                      subtitle: 'Vypnuto = jen odehrané a dnešní zápasy.',
                    ),
                    _switch(
                      context,
                      settings,
                      'Seznam sleduje tabuli',
                      settings?.kioskFollowBoard ?? true,
                      'kiosk_follow_board',
                      subtitle:
                          'Když návštěvník posune tabuli na jiné dny, '
                          'seznam zápasů naskočí na zápasy těch dnů.',
                    ),
                    _number(
                      context,
                      settings,
                      'Odehrané zápasy: týdnů zpět',
                      settings?.kioskWeeksBack ?? 2,
                      'kiosk_weeks_back',
                      unit: 'týdnů',
                      min: 0,
                      max: 52,
                      helper:
                          'Kolik týdnů před tím aktuálním seznam otevře. '
                          '${KioskSettingsScreen._rangeNote}',
                    ),
                    if (settings?.kioskShowUpcoming ?? true)
                      _number(
                        context,
                        settings,
                        'Budoucí zápasy: týdnů dopředu',
                        settings?.kioskWeeksAhead ?? 1,
                        'kiosk_weeks_ahead',
                        unit: 'týdnů',
                        min: 0,
                        max: 52,
                        helper:
                            'Kolik týdnů po tom aktuálním seznam otevře. '
                            '${KioskSettingsScreen._rangeNote}',
                      ),
                  ],
                ],
              ],
            ),
            if (settings?.kioskPanelEnabled ?? true)
              _section(
                context,
                'Hraný zápas',
                'Zápas, který se právě hraje a má na webu ČKA průběžné '
                    'výsledky.',
                [
                  _switch(
                    context,
                    settings,
                    'Hraný zápas přes celý panel',
                    settings?.kioskLiveMode ?? true,
                    'kiosk_live_mode',
                    subtitle:
                        'Souboje hraného zápasu zaberou celý panel a panel '
                        'zůstane rozbalený — i když ho návštěvník zavře, po '
                        'době nečinnosti se rozbalí znovu. Vypnuto = hraný '
                        'zápas je jen řádek v seznamu.',
                  ),
                  if (settings?.kioskLiveMode ?? true) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 12),
                      child: DropdownButtonFormField<MatchLayout>(
                        initialValue:
                            settings?.kioskLiveLayout ?? MatchLayout.full,
                        decoration: const InputDecoration(
                          labelText: 'Zobrazení hraného zápasu',
                          helperText:
                              'Kompaktní a tabulkové zobrazení vejdou celý '
                              'zápas do panelu; klepnutí na souboj ho '
                              'rozbalí.',
                          helperMaxLines: 3,
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: MatchLayout.full,
                            child: Text('Podrobné — karty soubojů'),
                          ),
                          DropdownMenuItem(
                            value: MatchLayout.compact,
                            child: Text('Kompaktní — bez posouvání'),
                          ),
                          DropdownMenuItem(
                            value: MatchLayout.table,
                            child: Text('Tabulka — souboj na řádek'),
                          ),
                        ],
                        onChanged: settings == null
                            ? null
                            : (m) => m == null
                                  ? null
                                  : _panel(context, settings, {
                                      'kiosk_live_layout': m.name,
                                    }),
                      ),
                    ),
                    _number(
                      context,
                      settings,
                      'Kontrola výsledků',
                      settings?.kioskLiveRefreshSeconds ?? 60,
                      'kiosk_live_refresh_seconds',
                      unit: 's',
                      min: 15,
                      max: 3600,
                      helper:
                          'Po kolika sekundách se kiosk zeptá webu ČKA na '
                          'nové skóre hraného zápasu.',
                    ),
                    _number(
                      context,
                      settings,
                      'Střídání hraných zápasů',
                      settings?.kioskLiveRotationSeconds ?? 12,
                      'kiosk_live_rotation_seconds',
                      unit: 's',
                      min: 3,
                      max: 600,
                      helper:
                          'Hraje-li se víc zápasů najednou, po kolika '
                          'sekundách se ukáže další.',
                    ),
                  ],
                  _number(
                    context,
                    settings,
                    'Velikost zápisu',
                    settings?.kioskZapisPercent ?? 80,
                    'kiosk_zapis_percent',
                    unit: '%',
                    min: 50,
                    max: 100,
                    helper:
                        'Kolik obrazovky zabere zápis otevřený klepnutím na '
                        'zápas; 100 = celá obrazovka s křížkem.',
                  ),
                ],
              ),
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
