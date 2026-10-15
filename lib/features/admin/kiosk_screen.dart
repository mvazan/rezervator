import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/kiosk_url.dart';
import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/weather.dart' show WeatherPlace;
import '../auth/update_screen.dart' show UpdateScreen;
import 'widgets/admin_scaffold.dart';
import 'widgets/copyable_address.dart';
import 'widgets/kiosk_text_dialog.dart';
import 'widgets/number_setting_field.dart';
import 'widgets/weather_place_dialog.dart';

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

  static String _pickerLabel(KioskPickerMode m) => switch (m) {
    KioskPickerMode.letters => 'Podle písmen',
    KioskPickerMode.clubs => 'Podle oddílu',
    KioskPickerMode.both => 'Podle oddílu i písmen',
  };

  static String _bandLabel(KioskDutyBandPosition p) => switch (p) {
    KioskDutyBandPosition.top => 'Nad datem',
    KioskDutyBandPosition.middle => 'Mezi datem a zápasy',
    KioskDutyBandPosition.bottom => 'Dole pod zápasy',
  };

  /// The note under the two ranges: they are only where the list opens;
  /// [button] is the kiosk's own button for that direction.
  static String _rangeNote(String button) =>
      'Jen výchozí rozsah — na kiosku jde posouvat celou sezónu '
      '(„$button“).';

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
    Map<String, Object?> changes,
  ) => tryAction(
    context,
    () => Api.setKioskPanel(changes, tenantId: settings.tenantId),
    errorText: friendlyDbError,
  );

  /// The warning's text, typed in a dialog (0068); saved trimmed.
  Future<void> _editWarning(
    BuildContext context,
    ScheduleSettings settings,
  ) async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => _WarningDialog(initial: settings.kioskWarning ?? ''),
    );
    if (text == null || !context.mounted) return;
    await _panel(context, settings, {'kiosk_warning': text});
  }

  /// [place] as the three columns that keep it.
  static Map<String, Object> _placeColumns(WeatherPlace place) => {
    'kiosk_weather_place': place.label,
    'kiosk_weather_lat': place.lat,
    'kiosk_weather_lon': place.lon,
  };

  /// The alley's own venue as a weather place — the admin reads the
  /// federation settings (the kiosk cannot), null when unknown.
  static WeatherPlace? _alleyPlace(WidgetRef ref) {
    final slug = ref.watch(federationSyncProvider).value?.venueSlug ?? '';
    if (slug.isEmpty) return null;
    return venueWeatherPlace(
      (ref.watch(venuesProvider).value ?? const <Venue>[])
          .where((v) => v.slug == slug)
          .firstOrNull,
    );
  }

  /// „Počasí“: on with the place it needs — the alley's venue when none was
  /// picked yet and the venue is known; off keeps the place for next time.
  Future<void> _weather(
    BuildContext context,
    ScheduleSettings settings,
    bool on,
    WeatherPlace? alley,
  ) => _panel(context, settings, {
    'kiosk_weather': on,
    if (on && settings.kioskWeatherLat == null && alley != null)
      ..._placeColumns(alley),
  });

  Future<void> _pickPlace(
    BuildContext context,
    ScheduleSettings settings,
    WeatherPlace? alley,
  ) async {
    final place = await showWeatherPlaceDialog(context, alley: alley);
    if (place == null || !context.mounted) return;
    await _panel(context, settings, _placeColumns(place));
  }

  /// Where the app is running (the web build knows; an alley hosting its
  /// own copy under a sub-path included) — or, on Android, where the public
  /// web app lives, because a phone has no address to offer a tablet.
  String _kioskUrl() =>
      kioskUrlFrom(kIsWeb ? Uri.base : Uri.parse(UpdateScreen.webUrl));

  /// The note on the name picker's first page (0070: under its first
  /// letters, or its names on a small alley — or its club tiles, 0076),
  /// typed in a dialog — a new
  /// one starts from the default text; saved trimmed.
  Future<void> _editPickerNote(
    BuildContext context,
    ScheduleSettings settings,
  ) async {
    final text = await showKioskTextDialog(
      context,
      title: 'Upozornění při rezervaci',
      label: 'Text upozornění',
      initial: settings.kioskPickerNote ?? ScheduleSettings.defaultPickerNote,
      defaultText: ScheduleSettings.defaultPickerNote,
      maxLength: ScheduleSettings.pickerNoteMaxLength,
    );
    if (text == null || !context.mounted) return;
    await _panel(context, settings, {'kiosk_picker_note': text});
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kiosks = [
      for (final p in ref.watch(profilesProvider).value ?? const <Profile>[])
        if (p.role == Role.kiosk) p,
    ];
    final alley = _alleyPlace(ref);
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
                // The warning first: it is what an admin comes here for
                // in a hurry („Dráha 3 je mimo provoz“).
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.warning_amber_rounded,
                    color: settings?.kioskWarning == null
                        ? null
                        : Theme.of(context).colorScheme.error,
                  ),
                  title: const Text('Upozornění'),
                  subtitle: Text(
                    settings?.kioskWarning ??
                        'Žádné. Varování s ikonou výstrahy v záhlaví kiosku; '
                            'dokud visí, ostatní údaje v záhlaví ustoupí. '
                            'Platí, dokud ho neodstraníš.',
                    // The whole text is one tap away, under „Upravit…“.
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: settings == null
                            ? null
                            : () => _editWarning(context, settings),
                        child: Text(
                          settings?.kioskWarning == null
                              ? 'Přidat…'
                              : 'Upravit…',
                        ),
                      ),
                      if (settings?.kioskWarning != null)
                        IconButton(
                          tooltip: 'Odstranit upozornění',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _panel(context, settings!, {
                            'kiosk_warning': null,
                          }),
                        ),
                    ],
                  ),
                ),
                // Then the booking's: on the name picker's first page,
                // under its letters or names (0070).
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.warning_amber_rounded,
                    color: settings?.kioskPickerNote == null
                        ? null
                        : Theme.of(context).colorScheme.error,
                  ),
                  title: const Text('Upozornění při rezervaci'),
                  subtitle: Text(
                    settings?.kioskPickerNote ??
                        'Žádné. Upozornění na první stránce výběru hráče na '
                            'kiosku.',
                    // The whole text is one tap away, under „Upravit…“.
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: settings == null
                            ? null
                            : () => _editPickerNote(context, settings),
                        child: Text(
                          settings?.kioskPickerNote == null
                              ? 'Přidat…'
                              : 'Upravit…',
                        ),
                      ),
                      if (settings?.kioskPickerNote != null)
                        IconButton(
                          tooltip: 'Odstranit upozornění při rezervaci',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _panel(context, settings!, {
                            'kiosk_picker_note': null,
                          }),
                        ),
                    ],
                  ),
                ),
                // How the name picker starts (0076): letters, the clubs,
                // or both — beside the note that stands under them.
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 12),
                  child: DropdownButtonFormField<KioskPickerMode>(
                    initialValue:
                        settings?.kioskPickerMode ?? KioskPickerMode.letters,
                    decoration: const InputDecoration(
                      labelText: 'Výběr hráče',
                      helperText:
                          'Podle oddílu: dlaždice oddílů v jejich barvě, ťuk '
                          'ukáže hráče oddílu; hráči bez oddílu jsou pod '
                          '„Ostatní“. Jen když je z čeho vybírat — aspoň dva '
                          'oddíly s hráči, nebo oddíl a hráči bez oddílu; '
                          'jinak kiosk ukáže písmena.',
                      helperMaxLines: 4,
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final m in KioskPickerMode.values)
                        DropdownMenuItem(
                          value: m,
                          child: Text(_pickerLabel(m)),
                        ),
                    ],
                    onChanged: settings == null
                        ? null
                        : (m) => m == null
                              ? null
                              : _panel(context, settings, {
                                  'kiosk_picker_mode': m.name,
                                }),
                  ),
                ),
                _number(
                  context,
                  settings,
                  'Písmo upozornění',
                  settings?.kioskWarningFontSize ?? 22,
                  'kiosk_warning_font_size',
                  unit: 'px',
                  min: 14,
                  max: 40,
                  helper:
                      'Obě upozornění, v záhlaví i při rezervaci. 22 je '
                      'stejně velké jako nápověda „Vyber první písmeno…“.',
                ),
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
                _number(
                  context,
                  settings,
                  'Doba nečinnosti',
                  settings?.kioskIdleSeconds ?? 60,
                  'kiosk_idle_seconds',
                  unit: 's',
                  min: 15,
                  max: 600,
                  helper:
                      'Po tolika sekundách bez dotyku kiosk zapomene '
                      'vybraného hráče, zavře okna i zápis, vrátí tabuli na '
                      'dnešek a panel do výchozího stavu.',
                ),
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
                if (!(settings?.kioskFitDay ?? true))
                  _number(
                    context,
                    settings,
                    'Velikost písma na tabuli',
                    settings?.kioskFontSize ?? 11,
                    'kiosk_font_size',
                    unit: 'px',
                    min: 9,
                    max: 24,
                    helper:
                        'Jména v řádcích drah; řádky se písmu přizpůsobí. '
                        'Appka má 11. Při celém dni na obrazovce se písmo '
                        'řídí výškou řádků samo.',
                  ),
                _number(
                  context,
                  settings,
                  'Písmo zápasů a pronájmů',
                  settings?.kioskBandFontSize ?? 10,
                  'kiosk_band_font_size',
                  unit: 'px',
                  min: 8,
                  max: 24,
                  helper:
                      'Pásy zápasů, blokací a pronájmů na tabuli; appka má '
                      '10. Kde se pás vejde, má zápas pohár, domácí, '
                      'pomlčku a hosty pod sebou a dlouhý název se zalomí.',
                ),
                _number(
                  context,
                  settings,
                  'Šířka přehledu zápasů dne',
                  settings?.kioskDayMatchesWidth ?? 560,
                  'kiosk_day_matches_width',
                  unit: 'px',
                  min: 340,
                  max: 1200,
                  helper:
                      'Okno se zápasy dne po klepnutí na záhlaví dne. Appka '
                      'má 340; širší než obrazovka okno nikdy nebude.',
                ),
                _number(
                  context,
                  settings,
                  'Dní na obrazovce',
                  settings?.kioskVisibleDays ?? 7,
                  'kiosk_visible_days',
                  unit: 'dní',
                  min: 2,
                  max: 14,
                  helper:
                      'Kolik dní (sloupců) je na celé obrazovce najednou; '
                      'další jsou o kus vedle. Rozbalený panel z nich zakryje '
                      'tolik, kolik je jeho šířka.',
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
                    max: 60,
                  ),
              ],
            ),
            _section(
              context,
              'Stavový řádek',
              'Co kiosk ukáže vedle hodin: dnešní zápasy, počasí a kdo má '
                  'svátek.',
              [
                _switch(
                  context,
                  settings,
                  'Dnešní zápasy v záhlaví',
                  settings?.kioskTodaysMatches ?? true,
                  'kiosk_todays_matches',
                  subtitle: 'Vypnuto = záhlaví kiosku dnešní zápasy neukazuje.',
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Počasí'),
                  subtitle: const Text(
                    'Teplota a dnešní předpověď pro vybrané místo, '
                    'obnovuje se každou půlhodinu. Data: ČHMÚ (model '
                    'ALADIN) přes Open-Meteo.com (CC BY 4.0); zdroj kiosk '
                    'ukáže po ťuknutí na počasí.',
                  ),
                  value: settings?.kioskWeather ?? false,
                  onChanged: settings == null
                      ? null
                      : (on) => _weather(context, settings, on, alley),
                ),
                if (settings?.kioskWeather ?? false)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.place_outlined),
                    title: const Text('Místo pro počasí'),
                    subtitle: Text(
                      settings?.kioskWeatherPlace ??
                          'Není vybrané — kiosk počasí neukáže.',
                    ),
                    trailing: TextButton(
                      onPressed: settings == null
                          ? null
                          : () => _pickPlace(context, settings, alley),
                      child: Text(
                        settings?.kioskWeatherPlace == null
                            ? 'Vybrat…'
                            : 'Změnit…',
                      ),
                    ),
                  ),
                _switch(
                  context,
                  settings,
                  'Svátek',
                  settings?.kioskNameday ?? false,
                  'kiosk_nameday',
                  subtitle:
                      'Kdo má dnes svátek, podle českého kalendáře; ve '
                      'státní svátek bez jména jeho název.',
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
                    max: 120,
                    helper:
                        'Po kolika sekundách se ukáže další oznam '
                        '(v záhlaví i v panelu).',
                  ),
              ],
            ),
            _section(
              context,
              'Služby na kantýně',
              'Kdo právě slouží na kantýně a kdo přijde na řadu — podle plánu '
                  've Správě → Služby. Každé místo se zapíná zvlášť.',
              [
                _switch(
                  context,
                  settings,
                  'V záhlaví',
                  settings?.kioskDutyHeader ?? false,
                  'kiosk_duty_header',
                  subtitle:
                      'Pod hodinami „Služba: …“ s dnešní službou; ťuk ukáže '
                      'plán.',
                ),
                _switch(
                  context,
                  settings,
                  'V kalendáři',
                  settings?.kioskDutyBoard ?? false,
                  'kiosk_duty_board',
                  subtitle:
                      'Pás se jmény přes dny služby v hlavičkách dnů tabule.',
                ),
                // Where in the day headers the band runs — only with one.
                if (settings?.kioskDutyBoard ?? false)
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 12),
                    child: DropdownButtonFormField<KioskDutyBandPosition>(
                      initialValue:
                          settings?.kioskDutyBandPosition ??
                          KioskDutyBandPosition.middle,
                      decoration: const InputDecoration(
                        labelText: 'Kde je pás',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final p in KioskDutyBandPosition.values)
                          DropdownMenuItem(
                            value: p,
                            child: Text(_bandLabel(p)),
                          ),
                      ],
                      onChanged: settings == null
                          ? null
                          : (p) => p == null
                                ? null
                                : _panel(context, settings, {
                                    'kiosk_duty_band_position': p.name,
                                  }),
                    ),
                  ),
                // The card lives in the drawer: with the drawer off there is
                // nowhere to put it (like the live match's section).
                if (settings?.kioskPanelEnabled ?? true)
                  _switch(
                    context,
                    settings,
                    'V panelu',
                    settings?.kioskDutyDrawer ?? false,
                    'kiosk_duty_drawer',
                    subtitle: 'Karta se službou a plánem v postranním panelu.',
                  ),
                if ((settings?.kioskPanelEnabled ?? true) &&
                    (settings?.kioskDutyDrawer ?? false))
                  _number(
                    context,
                    settings,
                    'Podíl karty v panelu',
                    settings?.kioskDutyShare ?? 30,
                    'kiosk_duty_share',
                    unit: '%',
                    min: 10,
                    max: 90,
                    helper:
                        'Kolik výšky panelu karta zabere; zbytek si dělí '
                        'nástěnka a zápasy.',
                  ),
              ],
            ),
            _section(
              context,
              'Postranní panel',
              'Panel vpravo vedle tabule s nástěnkou a zápasy (a službou na '
                  'kantýně, je-li zapnutá). Návštěvník '
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
                    settings?.kioskDrawerColumns ?? 2,
                    'kiosk_drawer_columns',
                    unit: 'dní',
                    min: 1,
                    max: 13,
                    helper:
                        'Kolik sloupců dní rozbalený panel zakryje; nejvýš o '
                        'jeden méně, než je dní na obrazovce. Zavřený i '
                        'otevřený panel tak nechá na tabuli jen celé dny.',
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
                          'zápasy. Karta služby si bere svůj podíl napřed.',
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
                          '${_rangeNote('Zobrazit předchozí')}',
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
                            '${_rangeNote('Zobrazit další')}',
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
                      min: 30,
                      max: 600,
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
                      max: 120,
                      helper:
                          'Hraje-li se víc zápasů najednou, po kolika '
                          'sekundách se ukáže další.',
                    ),
                  ],
                ],
              ),
            _section(
              context,
              'Stream zápasu',
              'Zápas, který má na webu ČKA video (YouTube), si kdokoli pustí '
                  'na kiosku tlačítkem ▶ u zápasu — živě i ze záznamu — v '
                  'plovoucím okně vedle tabule, potichu; zvuk si pustí v '
                  'přehrávači. Okno jde posouvat, zvětšit na celou obrazovku, '
                  'sbalit nebo křížkem zavřít; po konci videa se zavře samo. '
                  'Doba nečinnosti okna nechá, kde je návštěvník nechal.',
              [
                _switch(
                  context,
                  settings,
                  'Stream na kiosku',
                  settings?.kioskStreamEnabled ?? true,
                  'kiosk_stream_enabled',
                  subtitle:
                      'Vypnuto = u zápasů žádné ▶ a žádné okno se streamem.',
                ),
                if (settings?.kioskStreamEnabled ?? true) ...[
                  _switch(
                    context,
                    settings,
                    'Živý přenos se otevře sám',
                    settings?.kioskStream ?? false,
                    'kiosk_stream',
                    subtitle:
                        'Hraný zápas s videem se otevře bez dotyku: od hodiny '
                        'před začátkem do půl hodiny po zapsání výsledku. '
                        'Zavřený se sám znovu neotevře. Vypnuto = jen '
                        'tlačítkem ▶.',
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 12),
                    child: DropdownButtonFormField<KioskCorner>(
                      initialValue:
                          settings?.kioskStreamCorner ?? KioskCorner.bl,
                      decoration: const InputDecoration(
                        labelText: 'Kde se okno objeví',
                        helperText:
                            'Panel je vpravo; vlevo dole mu okno nepřekáží. '
                            'Další okna do dalších rohů — nejdřív na stejné '
                            'straně.',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: KioskCorner.tl,
                          child: Text('Vlevo nahoře'),
                        ),
                        DropdownMenuItem(
                          value: KioskCorner.tr,
                          child: Text('Vpravo nahoře'),
                        ),
                        DropdownMenuItem(
                          value: KioskCorner.bl,
                          child: Text('Vlevo dole'),
                        ),
                        DropdownMenuItem(
                          value: KioskCorner.br,
                          child: Text('Vpravo dole'),
                        ),
                      ],
                      onChanged: settings == null
                          ? null
                          : (c) => c == null
                                ? null
                                : _panel(context, settings, {
                                    'kiosk_stream_corner': c.name,
                                  }),
                    ),
                  ),
                  _number(
                    context,
                    settings,
                    'Šířka okna',
                    settings?.kioskStreamWidth ?? 35,
                    'kiosk_stream_width',
                    unit: '%',
                    min: 20,
                    max: 60,
                    helper:
                        'Procenta šířky obrazovky; výška podle videa 16:9. '
                        'Návštěvník si okno přesune nebo zvětší sám.',
                  ),
                  _number(
                    context,
                    settings,
                    'Oken najednou',
                    settings?.kioskStreamMax ?? 1,
                    'kiosk_stream_max',
                    unit: '',
                    min: 1,
                    max: 4,
                    helper:
                        'Při 1 se mezi puštěnými streamy listuje šipkami v '
                        'okně. Víc = každý stream ve svém okně; když jsou '
                        'plná, další ▶ zavře nejstarší puštěný (živý přenos '
                        'jen uvolní místo a pak se vrátí). Každé okno je '
                        'další přehrávač — na slabším displeji raději 1.',
                  ),
                ],
              ],
            ),
            _section(
              context,
              'Optimalizace výkonu',
              'Pro slabší displej, na kterém se kiosk zadrhává (třeba Android '
                  's kioskem v prohlížeči). Každá volba ubere kreslení za '
                  'drobnost ve vzhledu.',
              [
                _switch(
                  context,
                  settings,
                  'Opakující se animace',
                  settings?.kioskAnimations ?? true,
                  'kiosk_animations',
                  subtitle:
                      'Tlačítko panelu se každé čtyři sekundy rozzáří a ikona '
                      'živého přenosu pulzuje; při tom se překresluje celá '
                      'obrazovka, i když se kiosku nikdo nedotýká. Vypnuto = '
                      'obojí je v klidu.',
                ),
                _switch(
                  context,
                  settings,
                  'Nižší rozlišení (jen web)',
                  settings?.kioskLowRes ?? false,
                  'kiosk_low_res',
                  subtitle:
                      'Kiosk v prohlížeči se vykreslí v menším rozlišení a '
                      'displej ho roztáhne — až 2× méně pixelů, trochu měkčí '
                      'písmo. Pomůže, když displej hlásí devicePixelRatio nad '
                      '1; při 1 nic nezmění. Nainstalované aplikace se '
                      'netýká. Kiosk se po změně sám obnoví.',
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

/// The kiosk warning's text: one or a few lines, at most
/// [ScheduleSettings.warningMaxLength] characters (the column's check, 0068,
/// 0074). Pops the trimmed text, null when cancelled.
class _WarningDialog extends StatefulWidget {
  const _WarningDialog({required this.initial});

  final String initial;

  @override
  State<_WarningDialog> createState() => _WarningDialogState();
}

class _WarningDialogState extends State<_WarningDialog> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _text.text.trim();
    return AlertDialog(
      title: const Text('Upozornění na kiosku'),
      content: SizedBox(
        width: 480,
        child: TextField(
          controller: _text,
          autofocus: true,
          maxLength: ScheduleSettings.warningMaxLength,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Text upozornění',
            hintText: 'Třeba: Dráha 3 je mimo provoz.',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: text.isEmpty ? null : () => Navigator.pop(context, text),
          child: const Text('Uložit'),
        ),
      ],
    );
  }
}
