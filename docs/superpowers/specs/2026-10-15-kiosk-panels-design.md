# Kiosk: dva panely, „Jak začít“, „Hráči týdne“

Requested by the user on 2026-10-15. The app speaks Czech; the user writes Slovak. Branch `kiosk-panels` from `main` (b17828f, migrations up to 0076); migrations `0077_kiosk_panels.sql` and `0078_week_players.sql`. PR #200 (`kiosk-live-refresh`) is open and touches `kiosk_info_panel.dart` — whichever merges second resolves.

Three parts, built in this order on one branch: the panels (everything else is placed in them), then the guide module, then the players of the week.

## Decided with the user

- **A left panel** like the right one, and **one place in the admin** where the modules go into the panels: per panel its width and whether it starts open; one table of modules, each with its panel (off / left / right), its share in % and its order (↑↓).
- **No backward compatibility.** The old panel columns are converted and **dropped**. The kiosk display is reloaded at once when it runs the web build; when it runs the APK, `apk.yml` is built from the release and pushed through the CMS the same day — until then the old APK falls back to its `fromJson` defaults (a right drawer with notices and matches, no duty card, notices in the header). Older phone apps do not crash on missing columns, but an admin cannot save panel settings from them — the user releases a new app version the same day.
- **„Jak začít“**: a card like Nástěnka, one page (no turning, no dots), a fixed short text in the app, a QR code to Google Play, generated once outside the project; no new package.
- **„Hráči týdne“**: the previous Monday–Sunday, **our players only**, best results (pins) in categories 100/120 throws × men/women, with home/away, per competition and per club in a full-screen detail. **Gender from the ČKA register** (evidence.kuzelky.cz shows ♂/♀ per member — the source of the registration numbers already).
- **Computed on demand**, not stored: one RPC per kiosk per hour (late fetches, corrections for 14 days and the gender look-ups keep changing a past week).
- Rankings are ordered **by result, best first** — the one deliberate exception to the rule that lists go alphabetically or chronologically; a ranking is what the module is.

---

## Part 1 — Panels

### Data (0077)

`schedule_settings`:

- `kiosk_panels jsonb not null default <default layout>`, named check `schedule_settings_kiosk_panels_check` = `kiosk_panels_valid(kiosk_panels)`. Default:

  ```json
  {
    "left":  {"days": 2, "open": false},
    "right": {"days": 2, "open": false},
    "modules": [
      {"id": "duty",    "side": "off",   "share": 30},
      {"id": "notices", "side": "right", "share": 40},
      {"id": "matches", "side": "right", "share": 60},
      {"id": "guide",   "side": "off",   "share": 45},
      {"id": "week",    "side": "off",   "share": 55}
    ]
  }
  ```

- `kiosk_panels_valid(jsonb) returns boolean` — immutable, `set search_path = public`, **never raises**: plpgsql that checks `jsonb_typeof` before reading any value and returns false for any other shape, so every bad value is a check violation (23514). Valid: an object; `left` and `right` objects with `days` an integral JSON number 1–13 (`v::numeric = trunc(v::numeric)`) and `open` a JSON boolean; `modules` an array of objects, `id` a non-empty string, each id at most once, `side` one of `off | left | right`, `share` an integral JSON number 5–95. The ids are **not** listed in SQL: the app skips ids it does not know and keeps them (see Model), so a later module needs no migration. Privileges: `revoke all … from public, anon; grant execute … to authenticated, service_role` — the CHECK runs as the admin who saves.
- `kiosk_notices_header boolean not null default true` — Nástěnka's line in the status bar, which `kiosk_notices_mode` used to mix with the panel.
- **Conversion** — a plpgsql `DO` block (plpgsql parses the statement naming the old columns only when it runs), guarded: it runs only while all eight old columns exist in `public.schedule_settings`, so the migration re-runs. Per row:
  - `right = {days: kiosk_drawer_columns, open: kiosk_drawer_open}`, `left = {days: 2, open: false}`; modules in today's fixed order duty, notices, matches, then guide and week off.
  - Placed `right` when `kiosk_panel_enabled` and — duty: `kiosk_duty_drawer`; notices: `kiosk_notices_mode in ('drawer','both')`; matches: `kiosk_show_matches or kiosk_live_mode` (today the match being played takes the drawer even with the list off; after the conversion it needs `matches` placed, so such an alley gets the list too) — else `off`.
  - Shares among the placed ones, from today's nested weights (duty `d` % of the drawer, notices `n` % of the rest), computed in `numeric` and cast with `round(…)::int` (half away from zero, as Dart's `round()`): duty, notices and matches → `d`, `round((100 − d) · n / 100.0)`, and the rest to 100; duty with one of the others → `d` and `100 − d`; no duty → notices `n`, matches `100 − n`; one module alone → its old share does not matter (it fills the panel). Every converted share is clamped to 5–95. A module placed off keeps its default share.
  - `kiosk_notices_header = kiosk_notices_mode in ('header','both')`.
- **Dropped:** `kiosk_panel_enabled`, `kiosk_drawer_open`, `kiosk_drawer_columns`, `kiosk_notices_mode`, `kiosk_notices_share`, `kiosk_show_matches`, `kiosk_duty_drawer`, `kiosk_duty_share`; their checks `schedule_settings_kiosk_drawer_columns_check`, `…_kiosk_notices_mode_check`, `…_kiosk_share_check` and `…_kiosk_duty_share_check` go with the columns. The plan greps every SQL function, trigger, view and edge function for the eight names first.
- Kept: `kiosk_live_mode` and the live options, `kiosk_notices_rotation_seconds`, `kiosk_show_upcoming`, `kiosk_weeks_back/ahead`, `kiosk_follow_board`, `kiosk_visible_days`.
- `public_week` is an allow-list — nothing to do.
- **Tenancy suite:** the suite re-runs 0064/0065 (around l. 10575) and 0073 (l. 10744), which bring the eight old columns back with their defaults. So: the 0073 block is rewritten without `kiosk_duty_drawer`/`kiosk_duty_share`; 0077 is re-run right after the 0073 re-run; the new 0077 block at the end of the file inserts alleys, sets old-column combinations through re-added columns (`\ir` of 0064/0073 where needed), runs `\ir 0077` twice (the first converts and drops, the second proves the guard skips), then asserts the conversions — including (d, n) = (30, 40), (90, 10), (90, 90), (60, 10), (55, 10), duty with only matches, list off with live mode on — the columns and the four check names gone from `pg_constraint`, the new-alley default, the check refusing bad layouts (duplicate id, unknown side, share 4/96, days 0/14, days 2.5, share as a string, missing `left`, `modules` an object), `has_function_privilege` (authenticated yes, anon no), and `public_week`'s six keys.
- `supabase/schema.sql` from a fresh throwaway stack, `docs/SCHEMA.md`.

### Model

`lib/domain/kiosk_layout.dart` (pure Dart, unit-tested):

- `enum KioskModule { duty, notices, matches, guide, week }` — the names are the JSON ids; Czech labels in the admin.
- `enum PanelSide { off, left, right }`.
- `class KioskPanel { int days; bool open; }`, `class KioskModulePlacement { KioskModule module; PanelSide side; int share; }`.
- `class KioskPanels { KioskPanel left, right; List<KioskModulePlacement> modules; }` with `fromJson` (bad values fall back per field, a missing module is appended off with its default share, an **unknown id is kept as an opaque entry** and written back by `toJson` — an older admin app never drops a newer module), `toJson`, `KioskPanels.defaults`, `modulesOn(PanelSide)`, `sideOf(KioskModule)`, and the edits the admin makes (`withSide`, `withShare`, `moved(module, by)`, `withPanel(side, days:, open:)`).
- `ScheduleSettings.kioskPanels` and `kioskNoticesHeader` replace the dropped fields; `KioskNoticesMode`, `kioskShowNotices`, `kioskNoticesInHeader`, `kioskPanelEnabled`, `kioskDrawerOpen`, `kioskDrawerColumns`, `kioskNoticesShare`, `kioskShowMatches`, `kioskDutyDrawer`, `kioskDutyShare` go.
- `kioskPanelWidths(screenWidth, {visibleDays, int? left, int? right}) → ({double left, double right})` — `left`/`right` the asked days, null for a side without content (it takes nothing). A present panel gets 1..`visibleDays − 1` whole day columns of `(screenWidth − calendarRulerWidth) / visibleDays`; with both present their sum is capped at `visibleDays − 1`, the left giving way first; when even 1 + 1 does not fit (`visibleDays` 2) both get 1 and opening one closes the other. Replaces `kioskDrawerWidthFor`; the shell computes it once and hands each panel its width (the drawer no longer recomputes its own).

### Kiosk

- **Content** per side: `kioskPanelContentProvider` becomes a family over `PanelSide` → `KioskPanelContent?` listing the side's modules that have something to show, in order, each with its share: `notices` when there is a notice, `matches` when the window has matches **or a match is being played**, `duty` when the plan has a duty, `guide` always, `week` when the week has lines. Null when none — no panel and no button on that side.
- **Layout** (`kiosk_shell.dart`): `Row[left panel, Expanded(board), right panel]`, each panel in its own `RepaintBoundary`; the board's columns stay sized on the whole screen (`columnBasisWidth: screenWidth`), so either panel takes whole days. The left panel mirrors the right: it grows from the left edge, its content laid out at full width from its right edge while it slides (`OverflowBox` aligned `centerRight`).
- **One panel widget** (`KioskPanelView`, from today's `KioskDrawer`) takes the side, width, open, hidden, `resetToken` and the content, and stacks the modules with `Expanded(flex: share)` and 12 px gaps — one module alone fills the panel; notices alone keep today's `Flexible`. Cards with their own scroll or paging state (matches, duty, week) are keyed by `resetToken`, so the idle reset starts them over. Cards: `_DutyCard`, `_NoticesCard`, `_MatchesCard` unchanged, plus `KioskGuideCard` (part 2) and `KioskWeekCard` (part 3).
- **The match being played** takes over the panel that holds `matches` (as today) and keeps that panel open; `kiosk_live_mode` off = never. `kioskLiveProvider` is gated on `matches` being placed (and live mode), not on a panel switch.
- **Buttons:** one `KioskDrawerButton` per panel with content, floating over the board at that panel's inner edge: the right one as today; the left one **centred on the hour ruler** (`left: leftWidth + (calendarRulerWidth − size) / 2`), never over today's column. Arrows point the way the panel moves; labels per side („Zobrazit levý panel“ / „Skrýt levý panel“, „… pravý panel“); both breathe with `kiosk_animations`.
- **State:** one `_drawerOverride` per side; the idle reset puts both back and bumps `resetToken`; picking a player hides both (`hidden`, content kept alive as now); `_liveHidden`, `onShowLive` and `boardDays` (follow-board) go to the panel holding `matches`.
- **Stream windows** float over the board and both panels as today; the default corner stays bottom left; `KioskCorner.fromHere`'s comment and the admin's helper say a window covers the panel on its side („Okno překryje panel na své straně; vyber roh na straně bez panelu.“).
- Header notices read `kioskNoticesHeader`.

### Admin (Správa → Kiosk)

Section order: **Obrazovka kiosku, Stavový řádek, Panely, Nástěnka, Služby na kantýně, Zápasy, Hraný zápas, Stream zápasu, Optimalizace výkonu** (then the address and the accounts, as now). „Postranní panel“ goes.

```
PANELY
Panely vlevo a vpravo vedle tabule. Návštěvník je rozbalí a sbalí tlačítkem
na okraji obrazovky; po době nečinnosti se vrátí do výchozího stavu.

Levý panel    Šířka [2] dní    Výchozně rozbalený [ ]
Pravý panel   Šířka [2] dní    Výchozně rozbalený [x]

Modul               Panel         Podíl    Pořadí
Služba na kantýně   [Vypnuto ▾]
Nástěnka            [Vpravo  ▾]   [40] %   ↑ ↓
Zápasy              [Vpravo  ▾]   [60] %   ↑ ↓
Jak začít           [Vlevo   ▾]   [45] %   ↑ ↓
Hráči týdne         [Vlevo   ▾]   [55] %   ↑ ↓
                    Vlevo 100 % · Vpravo 100 %
```

- Width 1–13 days per panel (helper: both together at most one day fewer than the days on the screen); a panel's row is shown only when a module is on its side.
- Share 5–95 % and the arrows only for a placed module; the arrows move it among the placed modules of its panel. The sum per panel is shown; it need not be 100 (helper: „Podíly se přepočítají na celou výšku panelu.“).
- Every change PATCHes the whole `kiosk_panels` (optimistic, as the other settings).
- Module options stay in their sections: **Nástěnka** („V záhlaví“ = `kiosk_notices_header`, rotation — shown when notices are in the header or a panel), **Služby na kantýně** (header, board, band position; the drawer switch and share go to the table), **Zápasy** (new section with the list options from „Postranní panel“: upcoming, follow the board, weeks back/ahead — shown when matches are placed), **Hraný zápas** (shown when matches are placed).
- Reworded for two panels: the stream corner helper (above), the notices helper, the visible-days helper, the duty subtitle, the animations subtitle („tlačítka panelů“) and the idle helper („panely do výchozího stavu“).
- Tests find section titles and repeated labels („Nástěnka“, „Zápasy“, „V záhlaví“) within their section; the section-order test gets the new order.

---

## Part 2 — „Jak začít“ (module `guide`)

A card like Nástěnka (`_Card`, made public as `KioskCard`): title **„JAK ZAČÍT“** with `Icons.lightbulb_outline`, one page, no turning. Headings 18 px w800, body 16 px / 1.3 (Nástěnka's body). Fixed text:

> **Rezervace na kiosku**
> 1. Ťukni na „Rezervace tréninku“ a najdi své jméno.
> 2. Ťukni na volnou dráhu v tabuli a potvrď.
> 3. Máš-li v Rezervátoru účet, přijde ti potvrzení — v aplikaci, a když ji nepoužíváš, e-mailem s odkazem na zrušení.
>
> **Rezervátor i v mobilu**
> Rezervace, zrušení a upozornění odkudkoli: aplikace pro Android (QR) nebo web **rezervator.online**.

Step 3 promises nothing it cannot keep: a player without an account (no e-mail) gets no confirmation; a player whose app has notifications blocked gets the push and no e-mail (the token is saved regardless of the permission — out of scope here).

**QR** (`lib/features/kiosk/kiosk_qr.dart`): `const kioskPlayQr = <String>[…]` — the module matrix of `https://play.google.com/store/apps/details?id=cz.kuzelky.rezervator` (byte mode, level L, version 4, 33 × 33), generated once in the scratchpad with the `qr` 3.0.2 package from the pub cache (`dart pub get --offline`), the generator's version, URL and level in the file's header like `namedays.dart`. `KioskQr(rows:, size:)` paints black modules on a white tile with a 4-module quiet zone in either kiosk theme, in **device pixels**: `m = floor(size · dpr / 41)`, tile `m · 41 / dpr` logical px, one `Path`, `isAntiAlias = false`; `Semantics` label „QR kód: Rezervátor na Google Play“.

**Fit:** the QR sits beside the second paragraph — size = min(220, the height left, the content width − 12 − 200 for the text column); shown only when `m ≥ 3` and the tile is at least 120 logical px, else under the paragraph when the height allows, else left out, and then the paragraph reads „aplikace pro Android — ťukni pro QR kód“. When even the text does not fit, it is clipped with „Více“ (as Nástěnka). A tap on the card opens a dialog (`_touchable`, kiosk theme) with the whole text and a 300 px QR. The default share (45 %) gives the card ~430 px on a 1080 px screen — a 220 px QR beside the text in a 2-day panel.

**Checks:** a unit test of the matrix (square, 33 rows, the three 7 × 7 finder patterns, the timing row and column); widget tests of the fit (1920 × 1080, 2 of 8 days, 45 % → QR shown; smaller → under/left out with the tap hint); the user scans the code from the kiosk before release.

---

## Part 3 — „Hráči týdne“ (module `week`)

### Gender (0078 + `regnum-lookup`)

- `site_player_regnums.gender text check (gender in ('m','f'))` (null = unknown) and `gender_checked_at timestamptz` (null = never asked). Service role only, as the table; its comment (re-set in 0078) names gender as kept.
- `_shared/regnum.ts`:
  - `parseRows` also reads the register's gender field. The codes are read once from the raw register JSON (`GET https://evidence.kuzelky.cz/frontend-api/members?fulltext=Pavlů` — Tomáš is a man, Jana a woman, SKK Veverky Brno, in the user's screenshot) and pinned in the fixture; only those two values map to `m`/`f`, anything else is null. The existing parseRows test and its title gain gender.
  - `Resolved` gains `gender`: on `found` the found rows' gender; on `ambiguous` the common gender of that exit's candidates (the age-filtered named rows, or all named rows when the page has no age), null when they differ; `none` has none. Both ambiguous exits unit-tested.
  - `needsGender(row, now)`: `gender is null and (gender_checked_at is null or older than RETRY_AFTER)`, whatever the status. A `found` row gets its gender from the register alone (search by name, the row whose number equals the stored one) — number and status untouched; rows without a cache row, or `none`/`ambiguous` past `RETRY_AFTER`, go through the normal resolve, which now writes gender. Every attempt stamps `gender_checked_at`. Pure and tested in `regnum_test.ts`.
  - Header comments of `regnum.ts` and `regnum-lookup/index.ts` name gender as read and kept.
- `regnum-lookup` gains `{ mode: "week", monday }`: reads the week's lines by calling `kiosk_week_players(monday)` **as the caller** (so „ours“ is defined once, in SQL), takes those with a `player_slug` that need gender, and resolves them within `BUDGET`; answers `{ more }`. The kiosk may call it (a signed-in member of the alley).

### Data (0078)

`kiosk_week_players(p_monday date default null) returns table(...)` — `security definer`, `stable`, `set search_path = public`; raises `not_allowed` unless `is_approved_or_kiosk()`; only `current_tenant_id()`'s rows; `revoke all … from public, anon; grant execute … to authenticated` (as `refresh_match`, 0062). `p_monday` is normalised with `date_trunc('week', p_monday)::date`; null = the previous week's Monday in Europe/Prague (`date_trunc('week', now() at time zone 'Europe/Prague')::date − 7`). The client always passes it. One row per **line of ours** in a match of that week:

- matches: `priority_slots` with `import_key like 'cka:%'`, `parent_id is null`, `date` in Monday..Sunday, their `match_results.status in ('finished','forfeit')`;
- our side: the side's team slug (`home_team_slug` / `away_team_slug`) is a `teams.site_slug` of the tenant — the rule the server uses (0045); no name fallback;
- lines: `match_player_results` of that side without a substitute (`sub_name is null`) and with a `total`;
- columns: `match_id`, `date`, `player_name`, `player_slug`, `total`, `errors`, `throws` (`120` for `T120`, `100` for `T100`, else by `jsonb_array_length(lanes)`: 4 → 120, 2 → 100, else null), `is_away` (= `priority_slots.is_away`, the alley's home/away as on the board — not the line's side), `competition`, `team_name`, `opponent`, `club_id`, `club_name`, `club_color` (`teams.club_id` → `clubs`), `gender` (from `site_player_regnums` by slug).

### Client

- `weekPlayersProvider` (StreamProvider of `WeekLines` — the Monday it read and the lines): the RPC for the previous week's Prague Monday (from `nowProvider`); re-read hourly, on the week's turn and on resume. The first read is shown at once; while lines with a slug lack gender, it then calls `regnum-lookup` `{mode: week, monday}` (20 s timeout) in rounds while `more`, up to 4 (as `matchRegnumsProvider`), and yields a second read; the hourly re-read asks again while lines still lack it. The card's and the detail's titles name the Monday that was read, not the clock's.
- `lib/domain/week_players.dart` (pure, unit-tested): `WeekLine`; `weekCategories(lines)` → Muži 120, Ženy 120, Muži 100, Ženy 100 (empty ones left out); `byCompetition(lines)` and `byClub(lines)` (groups Czech-alphabetical); `where(lines, away:)`; `ranked(lines)`: **one entry per player** (by `player_slug`, else the name) with the best line, total descending, then fewer errors, then the name (`compareCzech`). Unknown gender or throws: only in competitions and clubs.
- **Card** `KioskWeekCard`: title **„HRÁČI TÝDNE · 5.–11. 10.“** (`Icons.emoji_events_outlined`); as many categories as fit, each with its best three: „1. Jan Novák 598“ and, smaller, „Termínátor A · doma“; „Více“ when categories were left out. A tap anywhere opens the detail.
- **Detail** (full screen like the Zápis, `_touchable`): „Hráči týdne 5.–11. 10.“; chips **Vše / Doma / Venku**; segments **Kategorie / Soutěže / Oddíly**; one column per group (horizontal scroll when they do not fit), each a full ranking: order, name, result, and smaller the team, the opponent, home/away. A tap on a line opens that match's Zápis (the slot from `prioritySlotsProvider` by `match_id`).
- No lines in the week → no content → the module takes no room.

---

## Testing

- **Unit:** `KioskPanels` parsing (unknown ids kept, duplicates, missing ids, bad values), edits and JSON round trip; `kioskPanelWidths` (absent side, clamps, left gives way first, `visibleDays` 2); the conversion arithmetic mirrored in Dart with the suite's (d, n) cases; week categories, groups, filters, one entry per player and ranking ties; QR matrix structure.
- **Widget:** both panels with their buttons (found by label), mirrored slide, the left button over the ruler with today's first lane still bookable, the live match taking over the matches' panel on either side, picking hides both, the idle reset restores both and restarts the cards; admin table (placement, share, ↑↓, sums, PATCH of the whole JSON, panel rows only for a used side) and the new section order; guide card fit and dialog; week card fit and „Více“, detail filters/segments and the tap to the Zápis.
- **SQL (tenancy suite):** 0077 as above; 0078: the RPC's week bounds in Prague and normalisation, our side by slug only, substitutes and unfinished matches out, another alley's matches invisible, anon without EXECUTE, gender joined.
- **Deno:** register gender parsing (fixture with the pinned codes), both ambiguous exits, `needsGender`, a found row's gender filled without touching its number.
- **Browser** on the local stack at 1920 × 1080: seed first by a script that is not a migration (teams with `site_slug` and clubs, the previous week's `cka:` slots' team slugs, `match_results.discipline`, `player_slug` on the lines, `site_player_regnums` rows with m/f/null, T100 and T120); then both panels, each module, the detail, the QR scanned by the user from the kiosk.
