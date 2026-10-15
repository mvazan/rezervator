# Kiosk: moduly v záhlaví

Requested by the user on 2026-10-15. The app speaks Czech; the user writes
Slovak. Branch `kiosk-header-modules` from `main` (9f25a31, migrations up to
0079); migration `0082_kiosk_header.sql`. Two unmerged local branches already
hold an 0080 (`club-nickname`, `notices-newest`); `notices-newest` also changes
the header's notices (`kiosk_shell.dart` `_StatusBar`, `kiosk_headline.dart`) —
whichever merges second resolves the conflict and, if needed, renumbers.

## Why

The kiosk's header (status bar) grew piece by piece: the clock with the date
under it and the canteen duty as a chip under that, the weather with the name
day stacked under it, today's matches and the notices in the middle. Every
piece is centred on its own and stacked differently, so each starts and ends
at another height. The admin switches are spread over three sections
(„Stavový řádek“, „Nástěnka“, „Služby na kantýně“).

## Decided with the user

- **One shape for every module:** a small title on top, the value under it.
  All titles share one line, all values the next one.
- **Titles, simplified** (the user, after the first review): the clock says
  the day — „Dnes je čtvrtek 15. 10.“ — so no other title repeats „Dnes“;
  the others end with a colon: „Brno:“, „Svátek slaví:“, „Službu má:“,
  „Nástěnka:“.
- **Clock:** a module too — title „Dnes je čtvrtek 15. 10.“, value the time.
  Always first on the left; it cannot be moved or switched off.
- **Weather:** title the place the admin types („Brno“ — the place label is
  „TJ Sokol Brno IV, Štolcova…“ for the alley's venue, so it cannot be
  derived), shown with a colon; default „Počasí:“.
- **Name day:** „Svátek slaví:“ / „Hedvika“ (or „Adam a Eva“ — „slaví“ fits
  one and more); a public holiday without a name: „Státní svátek:“ / „Nový
  rok“.
- **Duty (new module):** „Službu má:“ / „Jan Novák“; „Službu mají:“ for two
  or more people. Replaces the „Služba: …“ chip under the clock. The
  side-panel card and the board band stay.
- **Notices:** a module with the title „Nástěnka“ and the rotating headline as
  its value; it takes the width that is left.
- **Position:** every module except the clock is off, left or right; left ones
  follow the clock, right ones stand before „Rezervace tréninku“; the admin
  orders them.
- **Today's matches:** no title, in the centre — home matches (and the alley's
  blockages ⛔) on one line, away matches on the line under it; otherwise as
  they are.
- **Admin:** one section „Záhlaví“ with a table like „Panely“.

## Data (0082)

`schedule_settings.kiosk_header jsonb not null`, default

```json
{"modules":[{"id":"weather","side":"off"},{"id":"nameday","side":"off"},
            {"id":"duty","side":"off"},{"id":"notices","side":"right"}]}
```

— what today's column defaults convert to (weather, name day and duty off,
notices on). The modules' order in the list is their order on each side.

- Validator `kiosk_header_valid(jsonb) returns boolean` (plpgsql, `immutable`,
  `set search_path = public`, never raises, like `kiosk_panels_valid`): an
  object whose `modules` is an array of objects, each with a non-empty string
  `id` (no duplicates) and `side` in `off|left|right`. Ids are not checked —
  a later module needs no migration; the app keeps an unknown entry and writes
  it back. `revoke all … from public, anon; grant execute … to authenticated,
  service_role`. Named check `schedule_settings_kiosk_header_check`.
- `kiosk_weather_title text` (null = „Počasí“), named check
  `schedule_settings_kiosk_weather_title_check`: null or 1–40 characters after
  `btrim`.
- **Conversion**, guarded like 0077 (only while all four old columns exist):
  `kiosk_weather` → weather `left`, `kiosk_nameday` → name day `left`,
  `kiosk_duty_header` → duty `left`, `kiosk_notices_header` → notices `right`;
  off stays off. Order weather, name day, duty, notices. Weather that was on
  without a place converts to `left` too (the kiosk shows nothing without a
  place, as today).
- **Drop** `kiosk_weather`, `kiosk_nameday`, `kiosk_duty_header`,
  `kiosk_notices_header` (`drop column if exists`). `kiosk_todays_matches`
  stays a boolean; the weather place columns stay.
- `public_week` is an allow-list since 0066: nothing to change.
- Comments on the function and both columns cite (0082). Re-runnable: the
  tenancy suite re-runs 0067, 0071, 0073 and 0077, which bring the old columns
  back.
- No backward compatibility, as with 0077: an older kiosk falls back to its
  `fromJson` defaults (notices on, the rest off) and an older admin cannot
  save the dropped switches until the release.

## Model

`lib/domain/kiosk_header.dart` (pure Dart, beside `kiosk_layout.dart`):

- `enum KioskHeaderModule { weather, nameday, duty, notices }` — the names are
  the JSON ids, never rename.
- `KioskHeaderPlacement {id, side (PanelSide), raw}` — `module` getter (null
  for an id this build does not know), `toJson() => raw ?? {id, side}`, `==`.
- `KioskHeader {modules}` mirroring `KioskPanels` without shares and panels:
  `defaults`, `fromJson(Object?)` (non-map / no list → defaults; skips non-
  objects, empty and duplicate ids; unknown side → off; keeps unknown ids raw;
  appends missing known modules off), `toJson`, `sideOf`, `modulesOn(side)`
  (known only, in order), `withSide` (keeps the module's slot), `moved(m, by)`
  (among the known modules on the same side), `==`/`hashCode`.
- `kioskHeaderFromLegacy({weather, nameday, dutyHeader, noticesHeader})` —
  the SQL conversion in Dart, tested on the same cases as the tenancy suite.
- `ScheduleSettings`: `kioskWeather`, `kioskNameday`, `kioskDutyHeader` and
  `kioskNoticesHeader` go; `kioskHeader` (`KioskHeader.fromJson(
  json['kiosk_header'])`) and `kioskWeatherTitle` (trimmed, blank → null)
  come. A cached row from before 0082 reads as the defaults.

`lib/domain/namedays.dart`: `nameDayLine` gives way to a title/value pair
(`({String title, String text})?`) — „Svátek slaví:“ /
„Státní svátek:“, names joined the Czech way.

## The kiosk

```
┌───────────────────────────────────────────────────────────────────────────────────────────┐
│ Dnes je čtvrtek 15. 10.  Brno:   Svátek slaví:   🏠 A – Tatran · 17:00–21:00  Nástěnka            ╭──────────────────╮ │
│ 14:32            ☀ 14°  16°/7°    Hedvika            B – Slavia · 10:00–14:00  📢 Brigáda v sobotu │ Rezervace tréninku│ │
│                                                                                                ╰──────────────────╯ │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

- **Frame** (`lib/features/kiosk/kiosk_header_module.dart`): title 13 px w600
  `onSurfaceVariant`, one line, ellipsis; under it a value box of
  `textScaler.scale(34)` px with the value centred-left in it. Every module has
  the same height, so the bar (whose children are centred) lines all titles up
  and all values up. Modules are 32 px apart. An optional tap on the whole
  module.
- **Value styles:** clock 28 px w800; the weather's temperature 22 px w800 with
  the rest of its row as today; names (name day, duty) 22 px w700, one line,
  ellipsis; the headline as today (22 px w700 with its icon and counter).
- **Widths:** the clock takes what it needs; weather, name day and duty at most
  a fifth of the screen each (weather scales down, names ellipsize); notices
  and the centre are `Expanded` (notices flex 3, centre flex 2); with neither
  present a spacer keeps the right modules on the right.
- **Order:** clock, left modules, centre, right modules, reserve button.
- **Hidden module:** weather without a (fresh) forecast, duty with nobody
  serving today, notices without a notice — left out, the rest close up.
- **Weather tap:** the title shows „Zdroj: ČHMÚ (model ALADIN) přes
  Open-Meteo.com“ for `sourceFor` (8 s), then the admin's title again.
- **Duty tap:** the plan („Služby na kantýně“ dialog), as the chip did.
- **Notices:** `KioskHeadline` gains `alignment` and `padding` parameters
  (defaults as today); the module passes `centerLeft` and no padding so the
  headline starts under its title.
- **Centre:** the info line („Zavřeno…“, „Další trénink…“) unchanged when
  there is no match; with matches, a column of two centred `Wrap`s — home and
  blockages first, away under them — each item tappable as today.
- **Warning (0068):** while it hangs, every module but the clock steps aside
  and the warning takes the centre, as today.

## Admin (Správa → Kiosk)

Section „Záhlaví“ replaces „Stavový řádek“ (same place: after „Obrazovka
kiosku“, before „Panely“).

```
Záhlaví
Pruh nahoře na kiosku. Každý modul má nadpis a pod ním údaj. Moduly vlevo
jsou hned za hodinami, vpravo před tlačítkem „Rezervace tréninku“; dnešní
zápasy jsou uprostřed — domácí nahoře, venkovní pod nimi.

Modul                 Poloha                 Pořadí
Hodiny a datum        Vlevo, vždy první
Počasí                [Vlevo        ▾]       ↑ ↓
Svátek                [Vlevo        ▾]       ↑ ↓
Služba na kantýně     [Vypnuto      ▾]
Nástěnka              [Vpravo       ▾]       ↑ ↓
Dnešní zápasy         [Uprostřed    ▾]

📍 Místo pro počasí      TJ Sokol Brno IV, …           Změnit…
   Nadpis počasí         Brno                          Upravit…
Počasí: ČHMÚ (model ALADIN) přes Open-Meteo.com (CC BY 4.0), obnovuje se
každou půlhodinu; zdroj kiosk ukáže po ťuknutí na počasí. Svátek podle
českého kalendáře; ve státní svátek bez jména jeho název. Služba podle plánu
ve Správě → Služby; ťuk ukáže plán.
```

- Rows keyed `kiosk-header-module:<id>` (`clock`, `weather`, `nameday`, `duty`,
  `notices`, `matches`), head `kiosk-header-modules-header`; one line from
  520 px, two lines on a phone — like „Panely“.
- „Poloha“ is a `DropdownButtonFormField<PanelSide>` (Vypnuto / Vlevo /
  Vpravo); the arrows (tooltips „Posunout výš“ / „Posunout níž“) move a module
  among the placed ones on its side and are left out for a module that is off.
  Every edit PATCHes the whole `kiosk_header`.
- „Dnešní zápasy“: Vypnuto / Uprostřed → `kiosk_todays_matches`.
- Weather moving from off to a side with no place picked takes the alley's
  venue as its place in the same PATCH (today's rule of the switch).
- „Místo pro počasí“ and „Nadpis počasí“ only while the weather is placed.
  The title is typed in the kiosk text dialog (at most 40 characters,
  default „Počasí“, saved trimmed; empty = default → null).
- „Nástěnka“ loses „V záhlaví“; about: „Oznamy z nástěnky klubu. Který oznam se
  na kiosku ukáže, volíš přímo na nástěnce (⋮ u oznamu). Do záhlaví ji dáš
  v Záhlaví, do panelu vlevo nebo vpravo v Panelech (výš).“ „Střídání oznamů“
  shows while the notices are in the header or in a panel.
- „Služby na kantýně“ loses „V záhlaví“; about: „Kdo právě slouží na kantýně
  a kdo přijde na řadu — podle plánu ve Správě → Služby. Do záhlaví dáš službu
  v Záhlaví, kartu do panelu v Panelech (výš).“ „V kalendáři“ and „Kde je pás“
  stay.

## Changelog

One bullet first in today's unreleased entry (15. 10. 2026) and a short store
bullet (the store summary has about 50 characters left).

## Testing

- **Unit:** `kiosk_header_test.dart` (ids, defaults, fromJson, edits, legacy
  conversion, default equals the migration's column default), `models_test`
  (fields, cached pre-0082 row), `namedays_test` (title/value pairs).
- **Widget:** header modules (titles and values on one line each, order by
  side, hidden modules, warning, weather source tap, duty tap → plan, narrow
  kiosk with large text, home/away lines); admin section (table, PATCHes,
  weather place on first placing, title dialog, section order, Nástěnka and
  Služby without „V záhlaví“).
- **Contrast:** module titles (`onSurfaceVariant` on `surfaceContainerHighest`)
  in the kiosk's light and dark themes, WCAG AA.
- **SQL tenancy suite:** an 0082 block (conversion per case, re-run is a no-op,
  old columns gone, checks raise, validator false not error, grants), `\ir
  0082` after the blocks that re-run older migrations.
- **Schema snapshot** regenerated on a throwaway stack.
- **Browser** at 1920×1080 against a local stack: both themes, every module
  on, a warning, matches home + away.

## Out of scope

Editable titles for other modules; a locative helper; moving the clock;
changes to the side panels or the duty band.
