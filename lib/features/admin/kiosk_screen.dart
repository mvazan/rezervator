import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/kiosk_url.dart';
import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/kiosk_header.dart';
import '../../domain/kiosk_layout.dart';
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

  static String _sideLabel(PanelSide side) => switch (side) {
    PanelSide.off => 'Vypnuto',
    PanelSide.left => 'Vlevo',
    PanelSide.right => 'Vpravo',
  };

  static String _moduleLabel(KioskModule module) => switch (module) {
    KioskModule.duty => 'Služba na kantýně',
    KioskModule.notices => 'Nástěnka',
    KioskModule.matches => 'Zápasy',
    KioskModule.guide => 'Jak začít',
    KioskModule.week => 'Hráči týdne',
    KioskModule.feedback => 'Napište nám',
  };

  static String _headerLabel(KioskHeaderModule module) => switch (module) {
    KioskHeaderModule.weather => 'Počasí',
    KioskHeaderModule.nameday => 'Svátek',
    KioskHeaderModule.duty => 'Služba na kantýně',
    KioskHeaderModule.notices => 'Nástěnka',
  };

  static String _zapisNavLabel(KioskZapisNav m) => switch (m) {
    KioskZapisNav.off => 'Vypnuto',
    KioskZapisNav.bar => 'Lišta nad zápisem',
    KioskZapisNav.sides => 'Šipky po stranách',
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

  static String _freshLabel(KioskNoticesFresh f) => switch (f) {
    KioskNoticesFresh.off => 'Nezvýrazňovat',
    KioskNoticesFresh.highlight => 'Zvýraznit',
    KioskNoticesFresh.longer => 'Zobrazit déle',
    KioskNoticesFresh.both => 'Zvýraznit i zobrazit déle',
  };

  /// The note under „Čerstvé oznamy“ for the admin's [days] — one day in
  /// its own form („před 1 dnem“, „před 3 dny“).
  static String _freshNote(int days) =>
      'Oznam vyvěšený před méně než '
      '${days == 1 ? '1 dnem' : '$days dny'} dostane štítek NOVÉ, nebo '
      'zůstane na obrazovce dvakrát déle.';

  /// The note under the two ranges: they are only where the list opens;
  /// [button] is the kiosk's own button for that direction.
  static String _rangeNote(String button) =>
      'Jen výchozí rozsah — na kiosku jde posouvat celou sezónu '
      '(„$button“).';

  /// A section: its title, a line on what it is about, and its options.
  /// Keyed by its title: „Nástěnka“ is a row of the Záhlaví and the Panely
  /// tables too, „Zápasy“ of Panely.
  Widget _section(
    BuildContext context,
    String title,
    String about,
    List<Widget> children,
  ) => Padding(
    key: ValueKey('section:$title'),
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

  /// Writes the panels' layout (0077) — always the whole of it: the
  /// column's check validates it as one value and the kiosk reads it as
  /// one, so moving or resizing one module is a new layout.
  Future<void> _layout(
    BuildContext context,
    ScheduleSettings settings,
    KioskPanels panels,
  ) => _panel(context, settings, {'kiosk_panels': panels.toJson()});

  /// The panels' layout — the default one until the settings row exists.
  static KioskPanels _panels(ScheduleSettings? settings) =>
      settings?.kioskPanels ?? KioskPanels.defaults;

  /// Whether [module] sits in a panel.
  static bool _placed(ScheduleSettings? settings, KioskModule module) =>
      _panels(settings).sideOf(module) != PanelSide.off;

  /// „Panely“: the width and the start of each panel that holds a module
  /// (an empty one is not on the kiosk at all), then the table that puts
  /// the modules into the panels, then the shares' sum per panel.
  Widget _panelsSection(BuildContext context, ScheduleSettings? settings) {
    final panels = _panels(settings);
    final used = [
      for (final side in const [PanelSide.left, PanelSide.right])
        if (panels.modulesOn(side).isNotEmpty) side,
    ];
    return _section(
      context,
      'Panely',
      'Panely vlevo a vpravo vedle tabule. Návštěvník je rozbalí a sbalí '
          'tlačítkem na okraji obrazovky; po době nečinnosti se vrátí do '
          'výchozího stavu.',
      [
        for (final side in used) _panelRow(context, settings, panels, side),
        if (used.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              'Šířka = kolik sloupců dní rozbalený panel zakryje; oba panely '
              'dohromady nejvýš o jeden méně, než je dní na obrazovce, takže '
              'tabule ukáže vždy celé dny. Panel, který není výchozně '
              'rozbalený, je po době nečinnosti skrytý a čeká na tlačítko.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= _moduleRowWidth;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The table's head over the one-line rows; on a phone each
                // control carries its own label instead.
                if (wide) _moduleHeader(context),
                for (final placement in panels.modules)
                  // A module of a newer app is not listed; the layout keeps
                  // it and every write hands it back unchanged.
                  if (placement.module case final module?)
                    _moduleRow(context, settings, panels, module, wide: wide),
              ],
            );
          },
        ),
        if (used.isNotEmpty) ...[
          Text(
            [
              for (final side in used)
                '${_sideLabel(side)} ${_sum(panels, side)} %',
            ].join(' · '),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Podíly se přepočítají na celou výšku panelu.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  /// The shares' sum of the modules on [side] — it need not be 100, the
  /// kiosk takes the shares as weights of the panel's height.
  static int _sum(KioskPanels panels, PanelSide side) =>
      panels.modulesOn(side).fold(0, (sum, p) => sum + p.share);

  /// The width and the start of the panel on [side].
  Widget _panelRow(
    BuildContext context,
    ScheduleSettings? settings,
    KioskPanels panels,
    PanelSide side,
  ) {
    final panel = panels.panel(side);
    return Padding(
      key: ValueKey('kiosk-panel:${side.name}'),
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            side == PanelSide.left ? 'Levý panel' : 'Pravý panel',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: NumberSettingField(
                  key: ValueKey('kiosk_panels.${side.name}.days'),
                  label: 'Šířka',
                  value: panel.days,
                  unit: 'dní',
                  min: 1,
                  max: 13,
                  onChanged: settings == null
                      ? null
                      : (n) => _layout(
                          context,
                          settings,
                          panels.withPanel(side, days: n),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Výchozně rozbalený'),
                  value: panel.open,
                  onChanged: settings == null
                      ? null
                      : (on) => _layout(
                          context,
                          settings,
                          panels.withPanel(side, open: on),
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// From this width on a module's row is one line of the table; below it
  /// (a phone) a placed module's share and arrows go under its name.
  static const _moduleRowWidth = 520.0;

  /// The columns of a one-line row after the module's name: its panel's
  /// list, its share, its two arrows. The arrows get a fixed 2 x 48 column:
  /// an [IconButton] is only 48 wide where the platform pads tap targets
  /// (phones) and 40 on desktop, where the row would end short.
  static const _panelWidth = 150.0;
  static const _shareWidth = 120.0;
  static const _arrowsWidth = 2 * 48.0;

  /// What a placed module adds to its row: the share and the two arrows.
  static const _placedWidth = _shareWidth + 4 + _arrowsWidth;

  /// The table's head over the one-line rows, as in the spec's sketch:
  /// „Modul“, „Panel“, „Podíl“, „Pořadí“, each over its column.
  Widget _moduleHeader(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Padding(
      key: const ValueKey('kiosk-modules-header'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text('Modul', style: style)),
          SizedBox(
            width: _panelWidth,
            child: Text('Panel', style: style),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: _shareWidth,
            child: Text('Podíl', style: style),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: _arrowsWidth,
            child: Text('Pořadí', style: style, textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }

  /// The table's row of [module]: its panel and — once placed — its share
  /// and the arrows that move it among the placed modules of its panel.
  Widget _moduleRow(
    BuildContext context,
    ScheduleSettings? settings,
    KioskPanels panels,
    KioskModule module, {
    required bool wide,
  }) {
    final side = panels.sideOf(module);
    final onSide = side == PanelSide.off
        ? const <KioskModulePlacement>[]
        : panels.modulesOn(side);
    final at = onSide.indexWhere((p) => p.module == module);
    void write(KioskPanels next) {
      if (settings != null) _layout(context, settings, next);
    }

    final name = Text(
      _moduleLabel(module),
      style: Theme.of(context).textTheme.bodyLarge,
    );
    final panel = SizedBox(
      width: _panelWidth,
      child: DropdownButtonFormField<PanelSide>(
        initialValue: side,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Panel',
          border: OutlineInputBorder(),
        ),
        items: [
          for (final s in PanelSide.values)
            DropdownMenuItem(value: s, child: Text(_sideLabel(s))),
        ],
        onChanged: settings == null
            ? null
            : (s) {
                if (s != null && s != side) {
                  write(panels.withSide(module, s));
                }
              },
      ),
    );
    final placed = <Widget>[
      SizedBox(
        width: _shareWidth,
        child: NumberSettingField(
          key: ValueKey('kiosk_panels.${module.name}.share'),
          label: 'Podíl',
          value: panels.shareOf(module),
          unit: '%',
          min: 5,
          max: 95,
          onChanged: settings == null
              ? null
              : (n) => write(panels.withShare(module, n)),
        ),
      ),
      const SizedBox(width: 4),
      SizedBox(
        width: _arrowsWidth,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: 'Posunout výš',
              icon: const Icon(Icons.arrow_upward),
              onPressed: settings == null || at <= 0
                  ? null
                  : () => write(panels.moved(module, -1)),
            ),
            IconButton(
              tooltip: 'Posunout níž',
              icon: const Icon(Icons.arrow_downward),
              onPressed: settings == null || at >= onSide.length - 1
                  ? null
                  : () => write(panels.moved(module, 1)),
            ),
          ],
        ),
      ),
    ];
    return Padding(
      key: ValueKey('kiosk-module:${module.name}'),
      padding: const EdgeInsets.only(bottom: 12),
      child: wide
          ? Row(
              children: [
                Expanded(child: name),
                panel,
                const SizedBox(width: 12),
                // An unplaced module keeps the columns in line.
                if (side == PanelSide.off)
                  const SizedBox(width: _placedWidth)
                else
                  ...placed,
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [Expanded(child: name), panel]),
                if (side != PanelSide.off)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: placed,
                    ),
                  ),
              ],
            ),
    );
  }

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

  /// The header's layout (0082) — the default one until the settings row
  /// exists.
  static KioskHeader _headerOf(ScheduleSettings? settings) =>
      settings?.kioskHeader ?? KioskHeader.defaults;

  /// Writes the header's layout (0082) — the whole of it, as the panels':
  /// the column's check validates it as one value — with [extra] columns
  /// in the same PATCH.
  Future<void> _header(
    BuildContext context,
    ScheduleSettings settings,
    KioskHeader next, {
    Map<String, Object?> extra = const {},
  }) => _panel(context, settings, {'kiosk_header': next.toJson(), ...extra});

  /// [module] to [side]. The weather coming into the header with no place
  /// picked yet takes the alley's venue, when known, in the same PATCH —
  /// the kiosk shows no weather without one; off keeps the place for next
  /// time.
  Future<void> _headerSide(
    BuildContext context,
    ScheduleSettings settings,
    KioskHeader header,
    KioskHeaderModule module,
    PanelSide side,
    WeatherPlace? alley,
  ) => _header(
    context,
    settings,
    header.withSide(module, side),
    extra: {
      if (module == KioskHeaderModule.weather &&
          !header.isOn(module) &&
          side != PanelSide.off &&
          settings.kioskWeatherLat == null &&
          alley != null)
        ..._placeColumns(alley),
    },
  );

  /// At most this many characters: 0082's check on `kiosk_weather_title`.
  static const _weatherTitleMaxLength = 40;

  /// The weather module's title (0082), typed in a dialog starting from
  /// the one shown; saved trimmed, the default as none — the kiosk shows
  /// [kioskWeatherDefaultTitle] then.
  Future<void> _editWeatherTitle(
    BuildContext context,
    ScheduleSettings settings,
  ) async {
    final text = await showKioskTextDialog(
      context,
      title: 'Nadpis počasí',
      label: 'Nadpis',
      initial: settings.kioskWeatherTitle ?? kioskWeatherDefaultTitle,
      defaultText: kioskWeatherDefaultTitle,
      maxLength: _weatherTitleMaxLength,
    );
    if (text == null || !context.mounted) return;
    // One line on the kiosk: a line break typed in the dialog (it takes a
    // few lines for the other kiosk texts) becomes a space.
    final title = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    await _panel(context, settings, {
      'kiosk_weather_title':
          title.isEmpty || title == kioskWeatherDefaultTitle ? null : title,
    });
  }

  /// The „Poloha“ column of the Záhlaví table: room for „Uprostřed“ in a
  /// list and for „Vlevo, vždy první“.
  static const _headerSideWidth = 170.0;

  /// „Záhlaví“ (0082): the table that puts the header's modules left or
  /// right of the centre and orders them — the clock and today's matches
  /// with their fixed places as its first and last rows — then the
  /// weather's place and title while the weather is in the header.
  Widget _headerSection(
    BuildContext context,
    ScheduleSettings? settings,
    WeatherPlace? alley,
  ) {
    final header = _headerOf(settings);
    return _section(
      context,
      'Záhlaví',
      'Pruh nahoře na kiosku. Každý modul má nadpis a pod ním údaj. Moduly '
          'vlevo jsou hned za hodinami, vpravo před tlačítkem „Rezervace '
          'tréninku“; dnešní zápasy jsou uprostřed — domácí nahoře, '
          'venkovní pod nimi.',
      [
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= _moduleRowWidth;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The table's head over the one-line rows; on a phone each
                // list carries its own label instead.
                if (wide) _headerHead(context),
                _headerRow(
                  context,
                  'clock',
                  'Hodiny a datum',
                  const Text('Vlevo, vždy první'),
                  wide: wide,
                ),
                for (final placement in header.modules)
                  // A module of a newer app is not listed; the layout keeps
                  // it and every write hands it back unchanged.
                  if (placement.module case final module?)
                    _headerModuleRow(
                      context,
                      settings,
                      header,
                      module,
                      alley,
                      wide: wide,
                    ),
                _headerRow(
                  context,
                  'matches',
                  'Dnešní zápasy',
                  DropdownButtonFormField<bool>(
                    initialValue: settings?.kioskTodaysMatches ?? true,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Poloha',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: false, child: Text('Vypnuto')),
                      DropdownMenuItem(value: true, child: Text('Uprostřed')),
                    ],
                    onChanged: settings == null
                        ? null
                        : (on) {
                            if (on != null) {
                              _panel(context, settings, {
                                'kiosk_todays_matches': on,
                              });
                            }
                          },
                  ),
                  wide: wide,
                ),
              ],
            );
          },
        ),
        if (header.isOn(KioskHeaderModule.weather)) ...[
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
                settings?.kioskWeatherPlace == null ? 'Vybrat…' : 'Změnit…',
              ),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.title),
            title: const Text('Nadpis počasí'),
            subtitle: Text(
              settings?.kioskWeatherTitle ??
                  '$kioskWeatherDefaultTitle (výchozí)',
            ),
            trailing: TextButton(
              onPressed: settings == null
                  ? null
                  : () => _editWeatherTitle(context, settings),
              child: const Text('Upravit…'),
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Počasí: ČHMÚ (model ALADIN) přes Open-Meteo.com (CC BY 4.0), '
            'obnovuje se každou půlhodinu; zdroj kiosk ukáže po ťuknutí na '
            'počasí. Svátek podle českého kalendáře; ve státní svátek bez '
            'jména jeho název. Služba podle plánu ve Správě → Služby; ťuk '
            'ukáže plán.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  /// The Záhlaví table's head over the one-line rows: „Modul“, „Poloha“,
  /// „Pořadí“, each over its column.
  Widget _headerHead(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Padding(
      key: const ValueKey('kiosk-header-modules-header'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text('Modul', style: style)),
          SizedBox(
            width: _headerSideWidth,
            child: Text('Poloha', style: style),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: _arrowsWidth,
            child: Text('Pořadí', style: style, textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }

  /// A row of the Záhlaví table, keyed by [id]: [name], then [place] in
  /// the „Poloha“ column and [arrows] (none: an empty column) in the
  /// „Pořadí“ one; on a phone the place and the arrows go under the name.
  Widget _headerRow(
    BuildContext context,
    String id,
    String name,
    Widget place, {
    Widget? arrows,
    required bool wide,
  }) {
    final label = Text(name, style: Theme.of(context).textTheme.bodyLarge);
    return Padding(
      key: ValueKey('kiosk-header-module:$id'),
      padding: const EdgeInsets.only(bottom: 12),
      child: wide
          ? Row(
              children: [
                Expanded(child: label),
                SizedBox(width: _headerSideWidth, child: place),
                const SizedBox(width: 12),
                // A row without arrows keeps the columns in line.
                SizedBox(width: _arrowsWidth, child: arrows),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                label,
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: place),
                    if (arrows != null) ...[
                      const SizedBox(width: 12),
                      SizedBox(width: _arrowsWidth, child: arrows),
                    ],
                  ],
                ),
              ],
            ),
    );
  }

  /// The row of [module]: its side and — once placed — the arrows that
  /// move it among the placed modules of that side.
  Widget _headerModuleRow(
    BuildContext context,
    ScheduleSettings? settings,
    KioskHeader header,
    KioskHeaderModule module,
    WeatherPlace? alley, {
    required bool wide,
  }) {
    final side = header.sideOf(module);
    final onSide = side == PanelSide.off
        ? const <KioskHeaderPlacement>[]
        : header.modulesOn(side);
    final at = onSide.indexWhere((p) => p.module == module);
    void move(int by) {
      if (settings != null) {
        _header(context, settings, header.moved(module, by));
      }
    }

    return _headerRow(
      context,
      module.name,
      _headerLabel(module),
      DropdownButtonFormField<PanelSide>(
        initialValue: side,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Poloha',
          border: OutlineInputBorder(),
        ),
        items: [
          for (final s in PanelSide.values)
            DropdownMenuItem(value: s, child: Text(_sideLabel(s))),
        ],
        onChanged: settings == null
            ? null
            : (s) {
                if (s != null && s != side) {
                  _headerSide(context, settings, header, module, s, alley);
                }
              },
      ),
      arrows: side == PanelSide.off
          ? null
          : Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'Posunout výš',
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: settings == null || at <= 0
                      ? null
                      : () => move(-1),
                ),
                IconButton(
                  tooltip: 'Posunout níž',
                  icon: const Icon(Icons.arrow_downward),
                  onPressed: settings == null || at >= onSide.length - 1
                      ? null
                      : () => move(1),
                ),
              ],
            ),
      wide: wide,
    );
  }

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
                      'dnešek a panely do výchozího stavu.',
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
                // How the Zápis pages through the matches (0079).
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 12),
                  child: DropdownButtonFormField<KioskZapisNav>(
                    initialValue: settings?.kioskZapisNav ?? KioskZapisNav.bar,
                    decoration: const InputDecoration(
                      labelText: 'Listování v zápisu',
                      helperText:
                          'Šipky k předchozímu a dalšímu odehranému zápasu, '
                          'ťuk na družstvo ukáže jeho zápasy; listuje i '
                          'přejetí prstem. Po stranách: šipky vedle zápisu, '
                          'na celé obrazovce přes něj — ťuk je schová.',
                      helperMaxLines: 4,
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final m in KioskZapisNav.values)
                        DropdownMenuItem(
                          value: m,
                          child: Text(_zapisNavLabel(m)),
                        ),
                    ],
                    onChanged: settings == null
                        ? null
                        : (m) => m == null
                              ? null
                              : _panel(context, settings, {
                                  'kiosk_zapis_nav': m.name,
                                }),
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
                        'Jména v řádcích drah; řádek je jméno a pár pixelů '
                        'kolem, takže větší písmo vyplní víc řádku. Appka má '
                        '11. Při celém dni na obrazovce se písmo řídí výškou '
                        'řádků samo.',
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
                      '10. Kde se pás vejde, má zápas nahoře pohár s časem '
                      'a pod mezerou domácí, „x“ a hosty pod sebou; '
                      'dlouhý název se zalomí.',
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
                      'další jsou o kus vedle. Rozbalené panely z nich '
                      'zakryjí tolik, kolik je jejich šířka.',
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
            _headerSection(context, settings, alley),
            _panelsSection(context, settings),
            _section(
              context,
              'Nástěnka',
              'Oznamy z nástěnky klubu. Který oznam se na kiosku ukáže, '
                  'volíš přímo na nástěnce (⋮ u oznamu). Do záhlaví ji dáš '
                  'v Záhlaví, do panelu vlevo nebo vpravo v Panelech (výš).',
              [
                if (_headerOf(settings).isOn(KioskHeaderModule.notices) ||
                    _placed(settings, KioskModule.notices)) ...[
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
                  // What a notice up for less than a few days gets on the
                  // kiosk (0081) — and those days, unless it gets nothing.
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 12),
                    child: DropdownButtonFormField<KioskNoticesFresh>(
                      initialValue:
                          settings?.kioskNoticesFresh ??
                          KioskNoticesFresh.highlight,
                      decoration: InputDecoration(
                        labelText: 'Čerstvé oznamy',
                        helperText: _freshNote(
                          settings?.kioskNoticesFreshDays ?? 3,
                        ),
                        helperMaxLines: 3,
                        border: const OutlineInputBorder(),
                      ),
                      items: [
                        for (final f in KioskNoticesFresh.values)
                          DropdownMenuItem(
                            value: f,
                            child: Text(_freshLabel(f)),
                          ),
                      ],
                      onChanged: settings == null
                          ? null
                          : (f) => f == null
                                ? null
                                : _panel(context, settings, {
                                    'kiosk_notices_fresh_mode': f.name,
                                  }),
                    ),
                  ),
                  if ((settings?.kioskNoticesFresh ??
                          KioskNoticesFresh.highlight) !=
                      KioskNoticesFresh.off)
                    _number(
                      context,
                      settings,
                      'Čerstvý je do',
                      settings?.kioskNoticesFreshDays ?? 3,
                      'kiosk_notices_fresh_days',
                      // „do 1 dne“, „do 2 dní“: the stored days, so the
                      // unit follows the echo of what was written.
                      unit: (settings?.kioskNoticesFreshDays ?? 3) == 1
                          ? 'dne'
                          : 'dní',
                      min: 1,
                      max: 14,
                    ),
                ],
              ],
            ),
            _section(
              context,
              'Služby na kantýně',
              'Kdo právě slouží na kantýně a kdo přijde na řadu — podle plánu '
                  've Správě → Služby. Do záhlaví dáš službu v Záhlaví, kartu '
                  'do panelu v Panelech (výš).',
              [
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
              ],
            ),
            // The match list's options — only with the list in a panel.
            if (_placed(settings, KioskModule.matches))
              _section(
                context,
                'Zápasy',
                'Seznam zápasů kuželny v panelu. Klepnutím na odehraný zápas '
                    'se otevře jeho zápis.',
                [
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
                        'Když návštěvník posune tabuli, seznam se posune '
                        'jen o zápasy dnů, které přibyly.',
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
              ),
            // The match being played takes over the panel with the list.
            if (_placed(settings, KioskModule.matches))
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
                        'Souboje hraného zápasu zaberou celý panel se zápasy '
                        'a ten zůstane rozbalený — i když ho návštěvník '
                        'zavře, po době nečinnosti se rozbalí znovu. Vypnuto '
                        '= hraný zápas je jen řádek v seznamu.',
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
                            'Okno překryje panel na své straně; vyber roh na '
                            'straně bez panelu. Další okna do dalších rohů — '
                            'nejdřív na stejné straně.',
                        helperMaxLines: 3,
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
                      'Tlačítka panelů se každé čtyři sekundy rozzáří a ikona '
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
