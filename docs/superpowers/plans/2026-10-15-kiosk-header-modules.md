# Kiosk: moduly v záhlaví — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The kiosk's header becomes a row of uniform modules (title over value): clock, weather, name day, a new duty module and notices, each off/left/right in an admin-chosen order; today's matches untitled in the centre, home over away; one admin section „Záhlaví“.

**Architecture:** A new jsonb column `schedule_settings.kiosk_header` (0081) with a never-raising validator, mirroring `kiosk_panels` (0077); a pure-Dart `KioskHeader` model beside `KioskPanels`; a presentational `KioskHeaderModuleFrame` the status bar fills; the admin table mirrors „Panely“.

**Tech Stack:** Flutter 3.38 + Riverpod 3, Supabase (Postgres 15, PostgREST), `flutter_test`.

Spec: `docs/superpowers/specs/2026-10-15-kiosk-header-modules-design.md`. Branch `kiosk-header-modules`, worktree `/Users/mvazan/Home/rezervator-kiosk-header`.

## Global Constraints

- Czech UI strings exactly as in the spec, in „…“ quotes where the spec has them; code comments in English, in the surrounding files' voice (short doc comments that say why).
- Work only inside `/Users/mvazan/Home/rezervator-kiosk-header`. Never touch `/Users/mvazan/Home/rezervator` (another session works there).
- One commit per logical change, conventional `type(scope): subject` (Czech or English), ending with the line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Commit ONLY your own paths: `git add <paths> && git commit -m "…" -- <paths>` (other agents may have staged files). Never push, tag or deploy.
- Never run `dart format` (files mix styles). Keep 80 columns where the file does.
- Tests: `TZ=Europe/Prague flutter test <file>`; `flutter analyze` must say „No issues found!“.
- A command that may run longer than 2 minutes (the whole `test/features/kiosk_test.dart`, the whole suite, `snap_repo.sh`) runs with Bash `run_in_background: true`, output to a log in the scratchpad, and is followed with `Monitor` (`tail -f <log> | grep --line-buffered -E "All tests passed|Some tests failed|EXIT|tenancy|FAILED"`) or polled — a foreground tool call over 180 s kills the agent. Iterate with `--plain-name '<test name>'`.
- Migrations re-runnable, explicit grants/revokes; never `supabase db reset`, never `db push`, never apply migrations to the dev DB on :54322.
- No new packages.
- `PanelSide` (`lib/domain/kiosk_layout.dart`) is reused for the header's side; the header's modules are a separate enum, never added to `KioskModule`.

---

### Task 1: Migration 0081, tenancy suite, schema snapshot, SCHEMA.md

**Files:**
- Create: `supabase/migrations/0081_kiosk_header.sql`
- Modify: `supabase/tests/tenancy_rls.sql` (new block before the final `rollback;` at the end; `\ir` re-runs after older blocks, see Step 3)
- Modify: `supabase/schema.sql` (regenerated, never hand-edited)
- Modify: `docs/SCHEMA.md` (the `schedule_settings` row near line 69 and the validator paragraph near lines 209–213)

**Interfaces:**
- Produces: column `kiosk_header jsonb not null` (default below), column `kiosk_weather_title text` (null or 1–40 chars after `btrim`), function `kiosk_header_valid(jsonb) returns boolean`, named checks `schedule_settings_kiosk_header_check`, `schedule_settings_kiosk_weather_title_check`. Columns `kiosk_weather`, `kiosk_nameday`, `kiosk_duty_header`, `kiosk_notices_header` dropped.

- [ ] **Step 1: Write the migration**

```sql
-- 0081 — the kiosk's header modules (Správa → Kiosk → Záhlaví): every
-- module of the status bar but the clock and today's matches is off, left
-- (after the clock) or right (before „Rezervace tréninku“), in an order.
-- One jsonb column holds it:
--
--   {"modules": [{"id": "weather", "side": "left"}, …]}
--
-- The modules are weather (0067), nameday (0067), duty (the canteen duty,
-- 0073) and notices (Nástěnka); the array's order is their order on a
-- side. kiosk_header_valid checks the shape, not the ids: the app keeps an
-- id it does not know and writes it back unchanged, so a later module
-- needs no migration. kiosk_weather_title is the weather's title on the
-- kiosk („Dnes v Brně“ — Czech declines the place, so the admin types it);
-- null shows „Počasí“.
--
-- The four switches the column replaces (kiosk_weather and kiosk_nameday
-- from 0067, kiosk_duty_header from 0073, kiosk_notices_header from 0077)
-- are converted and dropped. No function, trigger, view or edge function
-- reads them; public_week is an allow-list since 0066, so nothing changes
-- there. kiosk_todays_matches (0071) stays: today's matches have no side,
-- they are always in the centre.
--
-- Re-runnable on purpose, like 0077: the conversion runs only while all
-- four old columns exist. The tenancy suite re-runs 0067, 0073 and 0077,
-- which bring them back, and then this file.

-- Whether a value is a header layout. It never raises: every value is
-- looked at with jsonb_typeof before it is read, so a bad layout is a
-- check violation and nothing else. The CHECK runs as the admin who saves:
-- authenticated executes it, anon does not.
create or replace function kiosk_header_valid(p jsonb) returns boolean
    language plpgsql immutable set search_path = public as $$
declare
  v_module jsonb;
  v_ids text[] := '{}';
begin
  if jsonb_typeof(p) is distinct from 'object'
     or jsonb_typeof(p -> 'modules') is distinct from 'array' then
    return false;
  end if;
  for v_module in select value from jsonb_array_elements(p -> 'modules') loop
    if jsonb_typeof(v_module) is distinct from 'object'
       or jsonb_typeof(v_module -> 'id') is distinct from 'string'
       or jsonb_typeof(v_module -> 'side') is distinct from 'string' then
      return false;
    end if;
    if v_module ->> 'id' = '' or v_module ->> 'id' = any (v_ids)
       or v_module ->> 'side' not in ('off', 'left', 'right') then
      return false;
    end if;
    v_ids := v_ids || (v_module ->> 'id');
  end loop;
  return true;
end;
$$;
revoke all on function kiosk_header_valid(jsonb) from public, anon;
grant execute on function kiosk_header_valid(jsonb) to authenticated, service_role;
comment on function kiosk_header_valid(jsonb) is
  'Whether a value is a kiosk header layout (0081), for the check on schedule_settings.kiosk_header; never raises. authenticated executes it: the check runs as the admin who saves.';

-- A new alley: the notices on the right, the rest off — what the old
-- switches' defaults convert to.
alter table schedule_settings
  add column if not exists kiosk_header jsonb not null default
    '{"modules": [{"id": "weather", "side": "off"},
                  {"id": "nameday", "side": "off"},
                  {"id": "duty", "side": "off"},
                  {"id": "notices", "side": "right"}]}'::jsonb
    constraint schedule_settings_kiosk_header_check
    check (kiosk_header_valid(kiosk_header)),
  add column if not exists kiosk_weather_title text
    constraint schedule_settings_kiosk_weather_title_check
    check (kiosk_weather_title is null
           or char_length(btrim(kiosk_weather_title)) between 1 and 40);
comment on column schedule_settings.kiosk_header is
  'The kiosk''s header modules (0081): modules [{id, side off|left|right}] in their order — left after the clock, right before „Rezervace tréninku“. kiosk_header_valid checks the shape only; the app keeps an id it does not know.';
comment on column schedule_settings.kiosk_weather_title is
  'The weather module''s title on the kiosk (0081), typed by the admin („Dnes v Brně“); null shows „Počasí“.';

-- The old switches, converted: one on goes left — the weather, the name
-- day and the duty stood beside or under the clock — and the notices
-- right, where their line was. plpgsql plans the update, which names the
-- old columns, only when it runs, so the block also runs once they are
-- gone.
do $$
begin
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'schedule_settings'
         and column_name in ('kiosk_weather', 'kiosk_nameday',
                             'kiosk_duty_header',
                             'kiosk_notices_header')) < 4 then
    return;
  end if;
  update schedule_settings
     set kiosk_header = jsonb_build_object('modules', jsonb_build_array(
           jsonb_build_object('id', 'weather', 'side',
             case when kiosk_weather then 'left' else 'off' end),
           jsonb_build_object('id', 'nameday', 'side',
             case when kiosk_nameday then 'left' else 'off' end),
           jsonb_build_object('id', 'duty', 'side',
             case when kiosk_duty_header then 'left' else 'off' end),
           jsonb_build_object('id', 'notices', 'side',
             case when kiosk_notices_header then 'right' else 'off' end)));
end $$;

alter table schedule_settings
  drop column if exists kiosk_weather,
  drop column if exists kiosk_nameday,
  drop column if exists kiosk_duty_header,
  drop column if exists kiosk_notices_header;
```

- [ ] **Step 2: Tenancy block for 0081** — before the final `rollback;` of `supabase/tests/tenancy_rls.sql`, after the 0079 block, modelled on the 0077 section (search `0077` around lines 12222–12610 for its case table, double run, snapshot and assertions). It must:
  1. re-run `\ir ../migrations/0067_kiosk_weather_nameday.sql`, `0073_kiosk_duty.sql`, `0077_kiosk_panels.sql` (use the exact file names in `supabase/migrations/`) so the four old columns exist again;
  2. insert case tenants and set the four booleans per case (all off; all on; only weather; only notices off; nameday+duty) through a temp case table;
  3. `\ir ../migrations/0081_kiosk_header.sql` twice with a snapshot temp table after the first run, asserting the second run changes nothing;
  4. assert per case the exact `kiosk_header` (e.g. all on → weather left, nameday left, duty left, notices right, in that order);
  5. assert the four old columns are absent from `information_schema.columns`; both named checks exist in `pg_constraint`; a new alley (insert a tenant) gets the default `{"modules":[weather off, nameday off, duty off, notices right]}`;
  6. assert `check_violation` for: a non-object, `{"modules": 3}`, a module without id, an empty id, a duplicate id, side `"middle"`; and that `kiosk_header_valid` returns `false` (not null, no error) for `'3'`, `'[]'`, `'{"modules":[1]}'`; that `kiosk_header_valid('{"modules":[{"id":"later","side":"left"}]}')` is true (unknown ids pass);
  7. assert `kiosk_weather_title` rejects `''`, `'   '` and 41 characters, accepts 40 characters and null;
  8. `has_function_privilege('authenticated', 'kiosk_header_valid(jsonb)', 'execute')` true, `'anon'` false;
  9. as an authenticated admin (`set local role authenticated` + jwt claims, copy the 0077 block's way) PATCH-equivalent `update schedule_settings set kiosk_header = …` succeeds for the admin's own tenant;
  10. the `public_week` settings keys stay the six (`booking_horizon_days`, `kiosk_dark`, `kiosk_fit_day`, `lane_count`, `max_active_reservations`, `training_weekdays`).
  Use the suite's existing assertion idiom (`do $$ … raise exception 'FAIL: …' … $$`).

- [ ] **Step 3: Keep „the schema as it is“ for blocks after older re-runs** — the suite re-runs 0067 (≈line 10578), 0073 (≈10744) and 0077 (≈10749, 12378, 12381). After the 0073 block that reads `kiosk_duty_header` (ends ≈10804) and after the 0077 section's last statement, add `\ir ../migrations/0081_kiosk_header.sql` so later blocks see the post-0081 schema. Do not change what those older blocks assert.

- [ ] **Step 4: Run the snapshot + tenancy suite on a throwaway stack (background, ~5–8 min)**

Run (Bash, `run_in_background: true`):
`/private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/snap_repo.sh /Users/mvazan/Home/rezervator-kiosk-header > <scratchpad>/snap0081.log 2>&1; echo EXIT=$? >> <scratchpad>/snap0081.log`
Expected: the log ends with `tenancy OK` and a `supabase/schema.sql` diff stat. On `tenancy FAILED`, read `/private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/supa-throwaway/tenancy.log`, fix, re-run. Check `git diff supabase/schema.sql`: four column lines gone, `kiosk_header` and `kiosk_weather_title` added with comments and checks, `kiosk_header_valid` function and its grants, the `kiosk_notices_header` COMMENT gone — nothing else.

- [ ] **Step 5: docs/SCHEMA.md** — in the `schedule_settings` row replace the four dropped columns with `kiosk_header` (0081: header modules off/left/right in order, `kiosk_header_valid`) and `kiosk_weather_title` (0081); add `kiosk_header_valid` beside `kiosk_panels_valid` in the validators paragraph.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/0081_kiosk_header.sql supabase/tests/tenancy_rls.sql supabase/schema.sql docs/SCHEMA.md
git commit -m "feat(db): moduly záhlaví kiosku — kiosk_header a nadpis počasí (0081)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- supabase/migrations/0081_kiosk_header.sql supabase/tests/tenancy_rls.sql supabase/schema.sql docs/SCHEMA.md
```

---

### Task 2: `KioskHeader` model and the new settings fields

**Files:**
- Create: `lib/domain/kiosk_header.dart`
- Modify: `lib/domain/models.dart` (import; `ScheduleSettings` constructor ≈787–803, fields ≈860–912, `fromJson` ≈1031–1056) — ADD `kioskHeader` and `kioskWeatherTitle`; KEEP the four old fields for now (Task 5 removes them)
- Test: `test/domain/kiosk_header_test.dart` (new), `test/domain/models_test.dart`

**Interfaces:**
- Produces: `enum KioskHeaderModule { weather, nameday, duty, notices }`; `class KioskHeaderPlacement {String id; PanelSide side; Map<String, Object?>? raw; KioskHeaderModule? get module; Map<String, Object?> toJson()}`; `class KioskHeader {List<KioskHeaderPlacement> modules; static const defaults; factory fromJson(Object?); toJson(); List<KioskHeaderPlacement> modulesOn(PanelSide); PanelSide sideOf(KioskHeaderModule); bool isOn(KioskHeaderModule); KioskHeader withSide(KioskHeaderModule, PanelSide); KioskHeader moved(KioskHeaderModule, int by)}`; `KioskHeader kioskHeaderFromLegacy({required bool weather, required bool nameday, required bool dutyHeader, required bool noticesHeader})`; `ScheduleSettings.kioskHeader` (default `KioskHeader.defaults`) and `ScheduleSettings.kioskWeatherTitle` (`String?`, trimmed, blank → null); `const kioskWeatherDefaultTitle = 'Počasí'` in `kiosk_header.dart`.

- [ ] **Step 1: Write the failing tests** `test/domain/kiosk_header_test.dart`, in the style of `test/domain/kiosk_layout_test.dart` (helper `placed(h)` printing `id:side` in list order):
  - the ids: `KioskHeaderModule.values.map((m) => m.name)` == `['weather', 'nameday', 'duty', 'notices']`.
  - `KioskHeader.defaults.toJson()` == `{'modules': [{'id': 'weather', 'side': 'off'}, {'id': 'nameday', 'side': 'off'}, {'id': 'duty', 'side': 'off'}, {'id': 'notices', 'side': 'right'}]}`.
  - the default is 0081's column default: read `supabase/migrations/0081_kiosk_header.sql`, regex `r"kiosk_header\s+jsonb[^;']*?default\s+'(\{[^']*\})'"`, `jsonDecode` the match, compare to `KioskHeader.defaults.toJson()` (copy `models_test.dart`'s 0077 test ≈350–366).
  - fromJson: round trip through `jsonDecode(jsonEncode(...))`; `null`, `'x'`, `3`, `{}`, `{'modules': 3}` read as defaults; missing known modules appended off in enum order; an unknown id is kept and written back exactly (`{'id': 'later', 'side': 'left', 'x': 1}`); duplicate, id-less, empty-id and non-object entries skipped; an unknown side reads as off.
  - `modulesOn(PanelSide.left)` lists only known modules on the left, in order; `sideOf`/`isOn`.
  - `withSide` keeps the slot; `moved(m, -1/+1)` moves among known modules on the same side only and stops at the ends; a module off does not move; an unknown entry keeps its slot.
  - `kioskHeaderFromLegacy`: all off → weather/nameday/duty off, notices off; all on → left, left, left, right; only notices → defaults; the result's `toJson` passes the shape rules (ids unique, sides in off/left/right).
  - `==`/`hashCode` equal for equal layouts, unequal after `withSide`.
  - In `test/domain/models_test.dart` add: `kiosk_header` parsed (`ScheduleSettings.fromJson({...base, 'kiosk_header': {...}}).kioskHeader.sideOf(KioskHeaderModule.weather) == PanelSide.left`); missing → `KioskHeader.defaults`; `kiosk_weather_title` `'  Dnes v Brně  '` → `'Dnes v Brně'`, `'   '` → null, missing → null; a cached row from before 0081 (with `kiosk_weather: true` but no `kiosk_header`) reads `kioskHeader == KioskHeader.defaults` (no conversion in Dart, like the 0077 test ≈200–218).

- [ ] **Step 2: Run them — FAIL** (`TZ=Europe/Prague flutter test test/domain/kiosk_header_test.dart test/domain/models_test.dart` → compile errors).

- [ ] **Step 3: Implement `lib/domain/kiosk_header.dart`**

```dart
/// The kiosk's header modules, the pure half (0081, `schedule_settings.
/// kiosk_header`): which module stands left of the centre (after the
/// clock), which right (before „Rezervace tréninku“), which is off, and
/// their order. Správa → Kiosk → Záhlaví edits it, the status bar lays it
/// out. The clock (always first) and today's matches (always in the
/// centre) are not listed. Pure Dart, unit-tested.
library;

import 'dart:convert' show jsonEncode;

import 'kiosk_layout.dart' show PanelSide;

/// A module of the kiosk's header. The name is its id in `kiosk_header`
/// — do not rename one.
enum KioskHeaderModule { weather, nameday, duty, notices }

/// The weather module's title while the admin has typed none (0081's
/// `kiosk_weather_title` null).
const kioskWeatherDefaultTitle = 'Počasí';

final _headerModulesById = {
  for (final m in KioskHeaderModule.values) m.name: m,
};

/// One module's entry: its side.
class KioskHeaderPlacement {
  const KioskHeaderPlacement({required this.id, required this.side, this.raw});

  /// The JSON id — a [KioskHeaderModule]'s name, or a module a newer app
  /// knows.
  final String id;
  final PanelSide side;

  /// The entry as read, for an id this build does not know: written back
  /// unchanged, so an older admin app never drops a newer module.
  final Map<String, Object?>? raw;

  /// Null for an id this build does not know.
  KioskHeaderModule? get module => _headerModulesById[id];

  Map<String, Object?> toJson() => raw ?? {'id': id, 'side': side.name};

  @override
  bool operator ==(Object other) =>
      other is KioskHeaderPlacement &&
      other.id == id &&
      other.side == side &&
      jsonEncode(other.raw) == jsonEncode(raw);

  @override
  int get hashCode => Object.hash(id, side);

  @override
  String toString() => '$id:${side.name}';
}

/// The header's layout. Immutable; the admin's edits return a new one,
/// which is PATCHed whole.
class KioskHeader {
  const KioskHeader({required this.modules});

  /// In order: a side lays its modules out left to right as listed here.
  final List<KioskHeaderPlacement> modules;

  /// 0081's column default, letter for letter (a test compares the two):
  /// the notices on the right, the rest off — what the old switches'
  /// defaults convert to.
  static const defaults = KioskHeader(
    modules: [
      KioskHeaderPlacement(id: 'weather', side: PanelSide.off),
      KioskHeaderPlacement(id: 'nameday', side: PanelSide.off),
      KioskHeaderPlacement(id: 'duty', side: PanelSide.off),
      KioskHeaderPlacement(id: 'notices', side: PanelSide.right),
    ],
  );

  /// Reads `kiosk_header`. Without a `modules` list (a row from before
  /// 0081) it is the defaults. Entries that are no object or have no id,
  /// and an id's second entry, are skipped; a bad side is off; an id this
  /// build does not know is kept as it was read; a module the list lacks
  /// is added at its end, off.
  factory KioskHeader.fromJson(Object? json) {
    final list = json is Map<String, Object?> ? json['modules'] : null;
    if (list is! List) return defaults;
    final seen = <String>{};
    final modules = <KioskHeaderPlacement>[];
    for (final entry in list) {
      if (entry is! Map<String, Object?>) continue;
      final id = entry['id'];
      if (id is! String || id.isEmpty || !seen.add(id)) continue;
      final side = PanelSide.values
          .where((s) => s.name == entry['side'])
          .firstOrNull;
      modules.add(
        KioskHeaderPlacement(
          id: id,
          side: side ?? PanelSide.off,
          raw: _headerModulesById[id] == null
              ? Map<String, Object?>.unmodifiable(entry)
              : null,
        ),
      );
    }
    for (final m in KioskHeaderModule.values) {
      if (!seen.contains(m.name)) {
        modules.add(KioskHeaderPlacement(id: m.name, side: PanelSide.off));
      }
    }
    return KioskHeader(modules: List.unmodifiable(modules));
  }

  Map<String, Object?> toJson() => {
    'modules': [for (final m in modules) m.toJson()],
  };

  /// The known modules on [side], in order.
  List<KioskHeaderPlacement> modulesOn(PanelSide side) => [
    for (final m in modules)
      if (m.module != null && m.side == side) m,
  ];

  PanelSide sideOf(KioskHeaderModule m) =>
      modules.where((p) => p.id == m.name).firstOrNull?.side ?? PanelSide.off;

  /// Whether [m] is in the header at all.
  bool isOn(KioskHeaderModule m) => sideOf(m) != PanelSide.off;

  /// [m] to [side] (or off). It keeps its place in the order, so it lands
  /// among that side's modules where it stood before.
  KioskHeader withSide(KioskHeaderModule m, PanelSide side) {
    final i = modules.indexWhere((p) => p.id == m.name);
    final next = [...modules];
    final placed = KioskHeaderPlacement(id: m.name, side: side);
    if (i < 0) {
      next.add(placed);
    } else {
      next[i] = placed;
    }
    return KioskHeader(modules: List.unmodifiable(next));
  }

  /// [m] [by] places left (negative) or right among the modules of its own
  /// side, stopping at the first and the last; the modules elsewhere — on
  /// the other side, off, unknown — keep their places. A module off does
  /// not move.
  KioskHeader moved(KioskHeaderModule m, int by) {
    final side = sideOf(m);
    if (side == PanelSide.off || by == 0) return this;
    final slots = [
      for (var i = 0; i < modules.length; i++)
        if (modules[i].module != null && modules[i].side == side) i,
    ];
    final from = slots.indexWhere((i) => modules[i].id == m.name);
    if (from < 0) return this;
    final to = (from + by).clamp(0, slots.length - 1);
    if (to == from) return this;
    final peers = [for (final i in slots) modules[i]];
    peers.insert(to, peers.removeAt(from));
    final next = [...modules];
    for (var k = 0; k < slots.length; k++) {
      next[slots[k]] = peers[k];
    }
    return KioskHeader(modules: List.unmodifiable(next));
  }

  @override
  bool operator ==(Object other) {
    if (other is! KioskHeader || other.modules.length != modules.length) {
      return false;
    }
    for (var i = 0; i < modules.length; i++) {
      if (other.modules[i] != modules[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(modules);

  @override
  String toString() => 'KioskHeader($modules)';
}

/// 0081's conversion of the four old switches, in Dart (tested against the
/// same cases as the tenancy suite): an old switch on puts the weather,
/// the name day and the duty left — they stood beside or under the clock —
/// and the notices right, where their line was.
KioskHeader kioskHeaderFromLegacy({
  required bool weather,
  required bool nameday,
  required bool dutyHeader,
  required bool noticesHeader,
}) {
  PanelSide on(bool v, PanelSide side) => v ? side : PanelSide.off;
  return KioskHeader(
    modules: [
      KioskHeaderPlacement(id: 'weather', side: on(weather, PanelSide.left)),
      KioskHeaderPlacement(id: 'nameday', side: on(nameday, PanelSide.left)),
      KioskHeaderPlacement(id: 'duty', side: on(dutyHeader, PanelSide.left)),
      KioskHeaderPlacement(
        id: 'notices',
        side: on(noticesHeader, PanelSide.right),
      ),
    ],
  );
}
```

- [ ] **Step 4: `ScheduleSettings`** — import `kiosk_header.dart` in `models.dart` (beside `kiosk_layout.dart`), add constructor params `this.kioskHeader = KioskHeader.defaults, this.kioskWeatherTitle`, fields with doc comments (`/// The header's modules (0081): …`, `/// The weather module's title (0081); null shows [kioskWeatherDefaultTitle].`), and in `fromJson`: `kioskHeader: KioskHeader.fromJson(json['kiosk_header'])`, `kioskWeatherTitle:` parsed exactly like `kioskWarning` (trimmed, blank → null). Leave `kioskWeather`, `kioskNameday`, `kioskDutyHeader`, `kioskNoticesHeader` untouched in this task.

- [ ] **Step 5: Run — PASS**: `TZ=Europe/Prague flutter test test/domain/kiosk_header_test.dart test/domain/models_test.dart test/domain/kiosk_layout_test.dart` and `flutter analyze`.

- [ ] **Step 6: Commit** — `feat(kiosk): model modulů záhlaví (KioskHeader) a nadpis počasí` with the files above, path-limited.

---

### Task 3: The kiosk header — modules, duty module, centre lines

**Files:**
- Create: `lib/features/kiosk/kiosk_header_module.dart` (the frame)
- Modify: `lib/features/kiosk/kiosk_shell.dart` (`_StatusBar` ≈572–861)
- Modify: `lib/features/kiosk/kiosk_day_info.dart` (keep `kioskWeatherProvider`, `weatherIcon`; replace `KioskDayInfo` with `KioskWeatherModule` and `KioskNameDayModule`; library doc → „Správa → Kiosk → Záhlaví“)
- Modify: `lib/features/kiosk/kiosk_duty.dart` (replace `KioskDutyLine` with `KioskDutyModule`; library doc)
- Modify: `lib/features/kiosk/kiosk_headline.dart` (add `alignment` and `padding` parameters, defaults = today's `Alignment.center` / `EdgeInsets.symmetric(horizontal: 8, vertical: 4)`)
- Modify: `lib/domain/namedays.dart` (`nameDayLine` → `nameDayHeader`)
- Test: `test/features/kiosk_day_info_test.dart` (rewrite for the modules), `test/domain/namedays_test.dart`, `test/features/kiosk_headline_test.dart` (one test for `alignment: centerLeft`), `test/features/kiosk_test.dart` (harness ≈1815–1925 and every header test listed below)

**Interfaces:**
- Consumes (Task 2): `ScheduleSettings.kioskHeader` (`KioskHeader`, `modulesOn`, `sideOf`, `isOn`), `ScheduleSettings.kioskWeatherTitle`, `kioskWeatherDefaultTitle`, `KioskHeaderModule`, `PanelSide`.
- Produces: `KioskHeaderModuleFrame({required String title, required Widget child, VoidCallback? onTap, double? maxWidth})`; constants `kioskHeaderValueHeight = 34.0`, `kioskHeaderGap = 32.0`, `kioskHeaderModuleShare = 0.2`; `TextStyle kioskHeaderTitleStyle(ColorScheme)`, `TextStyle kioskHeaderNameStyle(ColorScheme)`; `KioskWeatherModule({required KioskWeather weather, required String title})`, `KioskNameDayModule({required ({String title, String text}) day})`, `KioskDutyModule({required KioskDutyEntry entry, required VoidCallback onTap})`; `({String title, String text})? nameDayHeader(NameDay)`.
- The shell stops reading `kioskWeather`, `kioskNameday`, `kioskDutyHeader`, `kioskNoticesHeader` (it reads `kioskHeader` instead); `kioskWeatherProvider` gates on `kioskHeader.isOn(KioskHeaderModule.weather)`.

- [ ] **Step 1: Name day pair (TDD)** — in `test/domain/namedays_test.dart` replace the `nameDayLine` expectations: 3 Jan → `(title: 'Dnes má svátek', text: 'Radmila')`; several names → `(title: 'Dnes mají svátek', text: 'Kašpar, Melichar a Baltazar')`; 1 Jan → `(title: 'Státní svátek', text: 'Nový rok')`; 5 Jul → names win (`'Dnes mají svátek'`, `'Cyril a Metoděj'`); 29 Feb → `'Horymír'`; every day of a leap year non-null. Run → FAIL. Implement in `namedays.dart`:

```dart
/// What the kiosk's name-day module says for [day] (0081): „Dnes má
/// svátek“ over „Radmila“, „Dnes mají svátek“ over „Adam a Eva“ (several
/// names joined the Czech way); a public holiday without a name:
/// „Státní svátek“ over the holiday; null when there is neither.
({String title, String text})? nameDayHeader(NameDay day) {
  final names = day.names;
  if (names.isEmpty) {
    final holiday = day.holiday;
    return holiday == null ? null : (title: 'Státní svátek', text: holiday);
  }
  final list = names.length == 1
      ? names.single
      : '${names.sublist(0, names.length - 1).join(', ')} a ${names.last}';
  return (
    title: names.length == 1 ? 'Dnes má svátek' : 'Dnes mají svátek',
    text: list,
  );
}
```
Remove `nameDayLine` (its only caller is `KioskDayInfo`). Run → PASS.

- [ ] **Step 2: The frame** `lib/features/kiosk/kiosk_header_module.dart`:

```dart
/// One module of the kiosk's header (0081): a small title over its value.
/// Every module has the same height — a title line, then a value box
/// [kioskHeaderValueHeight] tall (scaled with the text) — so the bar,
/// which centres its children, lines all titles up and all values up.
library;

import 'package:flutter/material.dart';

/// The value box's height at text scale 1: room for the clock's 28 px.
const kioskHeaderValueHeight = 34.0;

/// The space between two modules.
const kioskHeaderGap = 32.0;

/// The share of the screen's width a module with a short value (weather,
/// name day, duty) may take: the centre, the notices and „Rezervace
/// tréninku“ keep their room on a narrow kiosk with large text.
const kioskHeaderModuleShare = 0.2;

/// A module's title: small, quiet, one line.
TextStyle kioskHeaderTitleStyle(ColorScheme scheme) => TextStyle(
  fontSize: 13,
  height: 1.3,
  fontWeight: FontWeight.w600,
  color: scheme.onSurfaceVariant,
);

/// A name as a module's value (name day, duty).
TextStyle kioskHeaderNameStyle(ColorScheme scheme) => TextStyle(
  fontSize: 22,
  fontWeight: FontWeight.w700,
  color: scheme.onSurface,
);

class KioskHeaderModuleFrame extends StatelessWidget {
  const KioskHeaderModuleFrame({
    super.key,
    required this.title,
    required this.child,
    this.onTap,
    this.maxWidth,
  });

  final String title;

  /// The value, laid left in its box.
  final Widget child;

  /// A tap anywhere on the module.
  final VoidCallback? onTap;

  /// Null: as wide as the value (or, under an Expanded, the room given).
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget module = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: kioskHeaderTitleStyle(scheme),
        ),
        SizedBox(
          height: MediaQuery.textScalerOf(context)
              .scale(kioskHeaderValueHeight),
          // widthFactor 1: as wide as the value, not the room it may take.
          child: Align(
            alignment: Alignment.centerLeft,
            widthFactor: 1,
            child: child,
          ),
        ),
      ],
    );
    if (onTap != null) {
      module = InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: module,
      );
    }
    final cap = maxWidth;
    return cap == null
        ? module
        : ConstrainedBox(
            constraints: BoxConstraints(maxWidth: cap),
            child: module,
          );
  }
}
```

- [ ] **Step 3: Modules** — in `kiosk_day_info.dart`:
  - `KioskWeatherModule` (ConsumerStatefulWidget not needed — a `StatefulWidget` taking `weather` and `title`): keeps `sourceFor = Duration(seconds: 8)` and the `_source` timer; builds `KioskHeaderModuleFrame(title: _source != null ? weatherSource : widget.title, maxWidth: MediaQuery.sizeOf(context).width * kioskHeaderModuleShare, onTap: _showSource, child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: _Weather(...)))`. `_Weather` unchanged (icon, 22 px temperature, max/min, umbrella, semantics).
  - `KioskNameDayModule({required day})`: `KioskHeaderModuleFrame(title: day.title, maxWidth: width * kioskHeaderModuleShare, child: Text(day.text, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: kioskHeaderNameStyle(scheme)))`.
  - `kioskWeatherProvider`: `!v.kioskHeader.isOn(KioskHeaderModule.weather)` instead of `!v.kioskWeather`.
  - Delete `KioskDayInfo` and `kioskDayInfoShare`.
  In `kiosk_duty.dart`: `KioskDutyModule({required entry, required onTap})` → `KioskHeaderModuleFrame(title: entry.names.length == 1 ? 'Dnes má službu' : 'Dnes mají službu', onTap: onTap, maxWidth: width * kioskHeaderModuleShare, child: Text(entry.who, …kioskHeaderNameStyle…))`; delete `KioskDutyLine`; update the library doc („the header's module „Dnes má službu“ (Správa → Kiosk → Záhlaví)“).
  In `kiosk_headline.dart`: `alignment` replaces the fixed `Alignment.center` in the `AnimatedSwitcher`'s `layoutBuilder` Stack, `padding` replaces the fixed padding; defaults keep every existing test green.

- [ ] **Step 4: The status bar** — rewrite `_StatusBar.build` (`kiosk_shell.dart`):

```dart
final settings = ref.watch(settingsProvider).value;
final header = settings?.kioskHeader ?? KioskHeader.defaults;
// … warning, warningFontSize, todays, info, now, todayDay as today …
final notices = warning == null && header.isOn(KioskHeaderModule.notices)
    ? kioskNotices(ref.watch(messagesProvider).value ?? const [], now)
    : const <Message>[];
final duty = warning == null && header.isOn(KioskHeaderModule.duty)
    ? ref.watch(kioskDutyPlanProvider.select((plan) => plan.now))
    : null;
final weather = warning == null && header.isOn(KioskHeaderModule.weather)
    ? freshWeather(ref.watch(kioskWeatherProvider).value, now)
    : null;
final nameDay = warning == null && header.isOn(KioskHeaderModule.nameday)
    ? nameDayHeader(czechNameDay(todayDay))
    : null;

/// A module as the bar lays it out — null when it has nothing to say
/// today, so the others close up.
Widget? module(KioskHeaderModule m) => switch (m) {
  KioskHeaderModule.weather => weather == null ? null : KioskWeatherModule(
      weather: weather,
      title: settings?.kioskWeatherTitle ?? kioskWeatherDefaultTitle,
    ),
  KioskHeaderModule.nameday =>
      nameDay == null ? null : KioskNameDayModule(day: nameDay),
  KioskHeaderModule.duty =>
      duty == null ? null : KioskDutyModule(entry: duty, onTap: onOpenDuty),
  KioskHeaderModule.notices => notices.isEmpty ? null : Expanded(
      flex: 3,
      child: KioskHeaderModuleFrame(
        title: 'Nástěnka',
        child: KioskHeadline(
          notices: notices,
          turn: Duration(seconds: settings?.kioskNoticesRotationSeconds ?? 12),
          onOpen: onOpenNotice,
          alignment: Alignment.centerLeft,
          padding: EdgeInsets.zero,
        ),
      ),
    ),
};
List<Widget> side(PanelSide s) => [
  for (final p in header.modulesOn(s))
    if (module(p.module!) case final w?) w,
];
final left = side(PanelSide.left);
final right = side(PanelSide.right);
```
  (`KioskHeadline` keeps its `SizedBox(width: double.infinity)`, so under the frame's `Align(widthFactor: 1)` it fills the Expanded.) The centre widget: the warning (as today, `Expanded(flex: …)` around `KioskWarning`), else the matches column, else the info text. The matches column — home lines first:

```dart
final home = [for (final m in todays) if (!m.isAway) m];
final away = [for (final m in todays) if (m.isAway) m];
Widget line(List<PrioritySlot> matches) => Wrap(
  alignment: WrapAlignment.center,
  crossAxisAlignment: WrapCrossAlignment.center,
  children: [
    for (var i = 0; i < matches.length; i++) ...[
      if (i > 0) Text('  ·  ', style: infoStyle),
      InkWell( /* exactly today's InkWell → onOpenMatch(matches[i]) */ ),
    ],
  ],
);
final centre = todays.isNotEmpty
    ? Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (home.isNotEmpty) line(home),
          if (home.isNotEmpty && away.isNotEmpty) const SizedBox(height: 4),
          if (away.isNotEmpty) line(away),
        ],
      )
    : (info.isNotEmpty ? EmojiText(info, /* today's style */) : null);
```
  The row: `[clockModule, for (w in left) ...[SizedBox(width: kioskHeaderGap), w], SizedBox(width: 24), if (centre/warning) Expanded(flex: 2, child: centre) else if (no Expanded among left/right) const Spacer(), for (w in right) ...[SizedBox(width: kioskHeaderGap), w] (no gap before the first right module when there is a centre — use 24 there), SizedBox(width: 16), reserve]`. With a warning: left/right are empty, the warning is the centre (`Expanded(flex: 1)`). `crossAxisAlignment: CrossAxisAlignment.center` stays. The clock module: `KioskHeaderModuleFrame(title: <dayFull(todayDay) with its first letter upper-cased>, child: Text(clock, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)))` — no tap. Delete `KioskDayInfo` and the duty line from the bar.

- [ ] **Step 5: Tests** — update `test/features/kiosk_test.dart`:
  - harness (`app()` ≈1815–1925): replace the `headerNotices`, `nameday`, `dutyHeader` booleans with a `KioskHeader header` parameter (default `KioskHeader.defaults`) or keep the booleans and build `kioskHeader: kioskHeaderFromLegacy(...)` — the latter keeps call sites unchanged; also a `weatherTitle` if needed.
  - :3063 name day → finds `'Dnes má svátek'` and `'Věra'` (8 Oct); title above the value (`getRect` bottom ≤ value top), both right of the clock module and left of the reserve button.
  - :3145 warning hides the modules (`KioskNameDayModule`, `KioskWeatherModule`, `KioskDutyModule` find nothing).
  - :3162 / :5661 today's matches: scope finders to the bar's `Wrap`s (`find.byType(Wrap)` may now find two — use `.first`/`descendant` accordingly).
  - :5606 headline: now under „Nástěnka“; the headline starts at the title's left (±1); still left of the reserve button; tap opens the notice.
  - canteen duty group (≈6150–6340): finder `find.text('AA Hráč a PP Hráč')` + title `find.text('Dnes mají službu')`; „under the date“ test becomes „a module beside the clock“ (left of the duty module ≥ clock module's right); one name → „Dnes má službu“; long names stay one line at most `1920 * kioskHeaderModuleShare` wide; taps on the module open the plan; `KioskDutyLine` references become `KioskDutyModule`.
  - NEW tests: (a) every module on (weather via `kioskWeatherProvider` override, name day, duty, notices) at `fullHd`: the titles share one top (±0.5) and the values share one top (±0.5); order by side — left modules between clock and centre in list order, right modules between centre and the reserve button; `moved` order respected. (b) the clock module: title „Čtvrtek 8. 10.“ over „12:00“. (c) home and away today: the home label's line is above the away label's line, both centred in the bar's middle (±1 of each other's centre x). (d) a module with nothing to say (duty with nobody serving) leaves no gap: the next module starts `kioskHeaderGap` after the previous one. (e) a narrow kiosk (1024×600) with `textScaler 2`: no overflow (`tester.takeException()` null), names ellipsized.
  - `test/features/kiosk_day_info_test.dart`: rewrite for `KioskWeatherModule` / `KioskNameDayModule` (title + value, umbrella from 30 %, stale weather → the bar shows no weather module, source tap swaps the TITLE for `weatherSource` for `sourceFor` and back, moon at night, provider asks only when the weather is on — `kioskHeader` with weather left, place set).
  - `test/features/kiosk_headline_test.dart`: add one test — with `alignment: Alignment.centerLeft, padding: EdgeInsets.zero` the icon's left equals the headline's left.
  Run each file (kiosk_test.dart in the background, see Global Constraints) → PASS; `flutter analyze` clean.

- [ ] **Step 6: Commit** — `feat(kiosk): záhlaví z modulů — nadpis a údaj, služba jako modul, domácí a venkovní zápasy pod sebou` (path-limited to the files of this task).

---

### Task 4: Admin — one section „Záhlaví“

**Files:**
- Modify: `lib/features/admin/kiosk_screen.dart` (section „Stavový řádek“ ≈950–1009 → „Záhlaví“; „Nástěnka“ ≈1011–1043; „Služby na kantýně“ ≈1044–1099; `_weather` ≈567–578; labels ≈104–116)
- Test: `test/features/kiosk_screen_test.dart`

**Interfaces:**
- Consumes (Task 2): `ScheduleSettings.kioskHeader`, `kioskWeatherTitle`, `KioskHeader.withSide/moved/modulesOn/sideOf/isOn/toJson`, `KioskHeaderModule`, `kioskWeatherDefaultTitle`; existing `_panel`, `_placeColumns`, `_alleyPlace`, `_pickPlace`, `showKioskTextDialog` (`lib/features/admin/widgets/kiosk_text_dialog.dart`).
- Produces: PATCH bodies `{'kiosk_header': <whole layout>}` (plus the three place columns when the weather is placed for the first time with no place and a known alley), `{'kiosk_weather_title': <trimmed or null>}`, `{'kiosk_todays_matches': bool}`. Keys `section:Záhlaví`, `kiosk-header-modules-header`, `kiosk-header-module:<clock|weather|nameday|duty|notices|matches>`. The screen stops reading `kioskWeather`, `kioskNameday`, `kioskDutyHeader`, `kioskNoticesHeader`.

- [ ] **Step 1: Failing tests** in `kiosk_screen_test.dart` (rewrite the affected tests listed in the spec's research; keep the harness):
  - section order (≈1858–1889): Obrazovka kiosku, **Záhlaví**, Panely, Nástěnka, Služby na kantýně, …; ≈1551–1571 `top(section('Záhlaví'))`.
  - the Záhlaví table: head „Modul“ / „Poloha“ / „Pořadí“ on a wide screen; rows in this order: „Hodiny a datum“ (text „Vlevo, vždy první“, no dropdown), then the layout's known modules in its order („Počasí“, „Svátek“, „Služba na kantýně“, „Nástěnka“), then „Dnešní zápasy“; defaults show Vypnuto, Vypnuto, Vypnuto, Vpravo and „Uprostřed“.
  - picking „Vlevo“ for „Svátek“ PATCHes `{'kiosk_header': KioskHeader.defaults.withSide(KioskHeaderModule.nameday, PanelSide.left).toJson()}`.
  - weather: placing it with no place and a known alley PATCHes the layout AND the alley's place columns in one body (old test ≈325–340 values); with a place already picked only the layout (≈342–363); without a known venue only the layout (≈365–373).
  - „Místo pro počasí“ and „Nadpis počasí“ show only while the weather is placed; the place dialog tests (≈376–536) use a fixture with the weather placed.
  - „Nadpis počasí“: subtitle shows the title or „Počasí (výchozí)“; „Upravit…“ opens the text dialog; saving „  Dnes v Brně “ PATCHes `{'kiosk_weather_title': 'Dnes v Brně'}`; saving empty or exactly „Počasí“ PATCHes `{'kiosk_weather_title': null}`.
  - arrows: with weather and name day left, „Posunout níž“ on weather PATCHes `moved(weather, 1)`; the first's ↑ and the last's ↓ disabled; an off module has no arrows.
  - „Dnešní zápasy“ dropdown → „Vypnuto“ PATCHes `{'kiosk_todays_matches': false}`.
  - „Nástěnka“ has no „V záhlaví“ any more; its about text is the spec's; „Střídání oznamů“ shows with the notices in the header OR in a panel, hidden when neither (≈654–687, ≈1920–1944 rewritten with `kioskHeader`).
  - „Služby na kantýně“: only „V kalendáři“ (+ „Kde je pás“); about text the spec's (≈1384–1425, ≈2033–2036).
  - the unscoped `find.byType(DropdownButtonFormField<PanelSide>)` count (≈1145) is scoped to `section('Panely')`.
  - phone width: a header row is two lines (name over the dropdown + arrows), no overflow.

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement** — `_headerSection(context, ref, settings, alley)` replaces „Stavový řádek“ in `build`:
  - `_section(context, 'Záhlaví', 'Pruh nahoře na kiosku. Každý modul má nadpis a pod ním údaj. Moduly vlevo jsou hned za hodinami, vpravo před tlačítkem „Rezervace tréninku“; dnešní zápasy jsou uprostřed — domácí nahoře, venkovní pod nimi.', [...])`.
  - `LayoutBuilder` with `wide = maxWidth >= _moduleRowWidth` like `_panelsSection`; a head row („Modul“ Expanded, „Poloha“ width `_headerSideWidth = 170.0`, gap 12, „Pořadí“ `_arrowsWidth`, centred) keyed `kiosk-header-modules-header`.
  - `_headerRow(...)` per known module of `header.modules` (skip unknown ids): name (`_headerLabel`: weather „Počasí“, nameday „Svátek“, duty „Služba na kantýně“, notices „Nástěnka“), `DropdownButtonFormField<PanelSide>` (`labelText: 'Poloha'`, items `_sideLabel`), arrows like `_moduleRow` (tooltips „Posunout výš“ / „Posunout níž“, `Icons.arrow_upward` / `arrow_downward`; enabled by position among `header.modulesOn(side)`), an off module keeps the columns in line with a `SizedBox(width: _arrowsWidth)`.
  - The clock row: name „Hodiny a datum“, in the „Poloha“ column `Text('Vlevo, vždy první')`.
  - The matches row: „Dnešní zápasy“, `DropdownButtonFormField<bool>` items `false` → „Vypnuto“, `true` → „Uprostřed“ → `_panel(..., {'kiosk_todays_matches': v})`.
  - Side writes: `_header(context, settings, next, {Map<String, Object?> extra = const {}})` → `_panel(context, settings, {'kiosk_header': next.toJson(), ...extra})`; the weather moving from off to a side with `settings.kioskWeatherLat == null && alley != null` adds `_placeColumns(alley)` (replaces `_weather`).
  - While the weather is placed: the existing „Místo pro počasí“ `ListTile`, then a `ListTile` „Nadpis počasí“ (leading `Icons.title`, subtitle `settings.kioskWeatherTitle ?? 'Počasí (výchozí)'`, trailing `TextButton('Upravit…')` → `showKioskTextDialog(context, title: 'Nadpis počasí', label: 'Nadpis', initial: settings.kioskWeatherTitle ?? kioskWeatherDefaultTitle, defaultText: kioskWeatherDefaultTitle, maxLength: 40)`; save `text.trim()`, null when empty or equal to `kioskWeatherDefaultTitle`).
  - Under the table a `bodySmall` note: „Počasí: ČHMÚ (model ALADIN) přes Open-Meteo.com (CC BY 4.0), obnovuje se každou půlhodinu; zdroj kiosk ukáže po ťuknutí na počasí. Svátek podle českého kalendáře; ve státní svátek bez jména jeho název. Služba podle plánu ve Správě → Služby; ťuk ukáže plán.“
  - „Nástěnka“: drop the „V záhlaví“ switch; about „Oznamy z nástěnky klubu. Který oznam se na kiosku ukáže, volíš přímo na nástěnce (⋮ u oznamu). Do záhlaví ji dáš v Záhlaví, do panelu vlevo nebo vpravo v Panelech (výš).“; rotation condition `header.isOn(KioskHeaderModule.notices) || _placed(settings, KioskModule.notices)`.
  - „Služby na kantýně“: drop „V záhlaví“; about „Kdo právě slouží na kantýně a kdo přijde na řadu — podle plánu ve Správě → Služby. Do záhlaví dáš službu v Záhlaví, kartu do panelu v Panelech (výš).“
  - The warning tile's empty text („…dokud visí, ostatní údaje v záhlaví ustoupí…“) stays.

- [ ] **Step 4: Run — PASS** (`TZ=Europe/Prague flutter test test/features/kiosk_screen_test.dart`, `flutter analyze`).

- [ ] **Step 5: Commit** — `feat(admin): jedna sekce Záhlaví — poloha a pořadí modulů, nadpis počasí` (path-limited).

---

### Task 5: Drop the old fields, contrast, changelog, final verification

**Files:**
- Modify: `lib/domain/models.dart` (remove `kioskWeather`, `kioskNameday`, `kioskDutyHeader`, `kioskNoticesHeader`: constructor, fields, `fromJson`)
- Modify: every remaining reference (`grep -rn "kioskWeather\b\|kioskNameday\|kioskDutyHeader\|kioskNoticesHeader" lib test`) — `test/domain/models_test.dart` ≈68–77, 188–196, 217, 334–347 and any harness left
- Modify: `test/features/name_picker_contrast_test.dart` (or the kiosk contrast test it holds) — add: the module title colour `onSurfaceVariant` on `surfaceContainerHighest` in the kiosk's light and dark themes (`buildTheme(Brightness.light/dark)` from `lib/core/theme.dart`) ≥ 4.5:1; if it fails, change `kioskHeaderTitleStyle` to a colour that passes and say so in the commit body
- Modify: `lib/features/profile/changelog_data.dart` — today's `Release(null, '15. 10. 2026', …)`: a new FIRST bullet „Kiosk, záhlaví: každý údaj má nahoře nadpis a pod ním hodnotu, všechny v jedné řadě — hodiny s datem, počasí (nadpis napíše správce, třeba „Dnes v Brně“), svátek, nově služba na kantýně („Dnes má službu“ místo řádku pod hodinami) a nástěnka. Ve Správě → Kiosk → Záhlaví každému zvolíš, jestli je vlevo, nebo vpravo, a pořadí; dnešní zápasy jsou uprostřed, domácí nad venkovními.“ and a store bullet „Kiosk: přehlednější záhlaví“ first in its `store:` list (the store summary has ≈53 characters left; `test/features/store_notes_test.dart` must pass)

- [ ] **Step 1:** remove the fields, fix references, run `flutter analyze` → clean.
- [ ] **Step 2:** contrast test → run → PASS (fix the colour if needed).
- [ ] **Step 3:** changelog → `TZ=Europe/Prague flutter test test/changelog_test.dart test/features/store_notes_test.dart` → PASS.
- [ ] **Step 4:** whole suite in the background: `TZ=Europe/Prague flutter test > <scratchpad>/suite.log 2>&1; echo EXIT=$? >> <scratchpad>/suite.log` → `All tests passed!`.
- [ ] **Step 5:** commits — `refactor(kiosk): pryč staré přepínače záhlaví` (models + tests), `test(kiosk): kontrast nadpisů modulů záhlaví`, `docs(changelog): kiosk — moduly v záhlaví` (each path-limited).
