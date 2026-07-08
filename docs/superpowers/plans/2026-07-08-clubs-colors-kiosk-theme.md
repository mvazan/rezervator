# Rezervátor — Oddíly s barvami, barevné pronájmy, téma kiosku (plan)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox steps.

**Goal:** Implement spec `docs/superpowers/specs/2026-07-08-clubs-colors-kiosk-theme-design.md`: clubs as a colored entity (replacing free-text club), per-rental color, admin-toggled kiosk light/dark theme, club colors on kiosk board + app grid.

**Branch:** `clubs-colors` (from main 6d616e2). Czech UI. Spec wins on conflict. Migration is `0003_clubs.sql`, atomic (begin/commit), applied to live DB by controller at the end.

## Global Constraints
- Domain pure Dart + TDD. Reservations/overrides via RPCs only. No user-facing text changes to existing strings (tests depend on them).
- `flutter analyze` "No issues found!" + full test suite green each task. Commits end `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Palette values are LOCKED (spec §2) — copy verbatim.

---

### Task 1: Migration 0003 + domain palette + models (TDD)

**Files:** create `supabase/migrations/0003_clubs.sql`, `lib/domain/palette.dart`; modify `lib/domain/models.dart`; tests `test/domain/palette_test.dart` (+ model additions).

**Migration (atomic):**
```sql
begin;
create table clubs (
  id uuid primary key default gen_random_uuid(),
  name text unique not null,
  color smallint not null default -1 check (color between -1 and 11),
  created_at timestamptz not null default now()
);
alter table profiles add column club_id uuid references clubs (id) on delete set null;
alter table rentals add column color smallint not null default -2
  check (color between -2 and 11);
alter table schedule_settings add column kiosk_dark boolean not null default true;

-- Data-migrate distinct non-empty profiles.club → clubs (round-robin palette),
-- link players by name match.
insert into clubs (name, color)
  select c.club, (row_number() over (order by c.club) - 1)::int % 12
  from (select distinct club from profiles where trim(club) <> '') c;
update profiles p set club_id = c.id from clubs c where c.name = p.club;

drop view players;
create view players as
  select p.id, p.display_name, p.club, p.nick_placeholder_removed_if_any,
         p.club_id, coalesce(c.color, -1) as club_color
  from profiles p left join clubs c on c.id = p.club_id
  where p.status = 'approved' and p.role <> 'kiosk';
-- NOTE: rezervator main has NO nick column yet (that's on an unmerged branch).
-- The players view here must match the ACTUAL current columns: id,
-- display_name, club, club_id, club_color. Implementer: read the live
-- 0001 players view / current schema and reproduce its columns + add club_id,
-- club_color. Do NOT reference a nick column unless it exists on this branch.
revoke all on players from anon;
grant select on players to authenticated;

create or replace function set_player_club(p_user_id uuid, p_club_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  update profiles set club_id = p_club_id where id = p_user_id;
end; $$;

create or replace function upsert_club(p_id uuid, p_name text, p_color smallint)
returns clubs language plpgsql security definer set search_path = public as $$
declare v clubs;
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  if trim(coalesce(p_name,'')) = '' then raise exception 'empty_name'; end if;
  if p_id is null then
    insert into clubs (name, color) values (trim(p_name), p_color) returning * into v;
  else
    update clubs set name = trim(p_name), color = p_color where id = p_id returning * into v;
  end if;
  return v;
end; $$;

create or replace function delete_club(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  delete from clubs where id = p_id;  -- profiles.club_id set null via FK
end; $$;

alter table clubs enable row level security;
create policy clubs_select on clubs for select using (is_approved_or_kiosk());
create policy clubs_write on clubs for all using (is_admin()) with check (is_admin());
-- (clubs writes normally go via RPCs; policy covers direct admin reads/writes.)

alter publication supabase_realtime add table clubs;
commit;
```
IMPORTANT for implementer: read the CURRENT `supabase/migrations/0001_schema.sql` (this branch = main, pre-nick) to reproduce the `players` view's real column list before adding club_id/club_color. Adjust the view SELECT accordingly. `on conflict`/name-collision in the club insert: distinct guarantees unique names.

**Domain `palette.dart`:**
```dart
import 'package:flutter/material.dart';

/// Club color palette (spec §2). Index 0–11 = a club color; anything else
/// (e.g. -1 "no club", -2 rental default) → the neutral fallback.
class ClubColors {
  const ClubColors._();
  // Each entry: [darkBg, darkFg, lightBg, lightFg] as 0xFF ints.
  static const _p = <List<int>>[
    [0xFF1E3A8A,0xFFBFDBFE,0xFFDBEAFE,0xFF1E3A8A], // Modrá
    [0xFF14532D,0xFFBBF7D0,0xFFDCFCE7,0xFF166534], // Zelená
    [0xFF7F1D1D,0xFFFECACA,0xFFFEE2E2,0xFF991B1B], // Červená
    [0xFF7C2D12,0xFFFED7AA,0xFFFFEDD5,0xFF9A3412], // Oranžová
    [0xFF4C1D95,0xFFDDD6FE,0xFFEDE9FE,0xFF5B21B6], // Fialová
    [0xFF134E4A,0xFF99F6E4,0xFFCCFBF1,0xFF115E59], // Tyrkys
    [0xFF831843,0xFFFBCFE8,0xFFFCE7F3,0xFF9D174D], // Růžová
    [0xFF713F12,0xFFFDE68A,0xFFFEF9C3,0xFF854D0E], // Žlutá
    [0xFF365314,0xFFD9F99D,0xFFECFCCB,0xFF3F6212], // Limetka
    [0xFF312E81,0xFFC7D2FE,0xFFE0E7FF,0xFF3730A3], // Indigo
    [0xFF44403C,0xFFE7E5E4,0xFFE7E5E4,0xFF44403C], // Hnědá
    [0xFF334155,0xFFCBD5E1,0xFFE2E8F0,0xFF334155], // Šedá
  ];
  static const names = ['Modrá','Zelená','Červená','Oranžová','Fialová',
      'Tyrkys','Růžová','Žlutá','Limetka','Indigo','Hnědá','Šedá'];
  static int get count => _p.length;

  /// Background+foreground for [index] at [brightness]; null when [index] is
  /// out of 0–11 (caller uses its own neutral tint).
  static (Color bg, Color fg)? of(int index, Brightness b) {
    if (index < 0 || index >= _p.length) return null;
    final e = _p[index];
    return b == Brightness.dark
        ? (Color(e[0]), Color(e[1]))
        : (Color(e[2]), Color(e[3]));
  }
}
```
Tests: `of(0, dark)` == (0xFF1E3A8A, 0xFFBFDBFE); `of(-1, ...)` and `of(12, ...)` == null; `count == 12`; names length 12.

**Models:** `Profile` + `clubId` (String?); `PlayerName` + `clubId` (String?), `clubColor` (int, default -1); `Rental` + `color` (int, default -2); `ScheduleSettings` + `kioskDark` (bool, default true). Update fromJson (club_id, club_color, color, kiosk_dark) with defaults for pre-migration rows. New `Club { id, name, colorIndex; fromJson }`. Adapt existing model fixtures/tests without weakening.

**Verify:** analyze + tests green. Commit `feat: clubs migration, color palette, model fields`.

---

### Task 2: Data layer — clubs provider + Api

**Files:** modify `lib/data/providers.dart`.

- `clubsProvider` (StreamProvider<List<Club>>, gated on `_authUidProvider` like the others — READ the file, main may or may not have the auth-gate yet; if not present, just a plain stream matching the existing pattern), sorted by name.
- Api: `setPlayerClub(userId, clubId?)`, `upsertClub(id?, name, colorIndex)`, `deleteClub(id)` → RPCs. `saveRental` gains `color` param. `PlayerName`/players fetch already carries club_color via view.

**Verify:** analyze + tests green. Commit `feat: clubs provider and api`.

---

### Task 3: Admin — clubs management, player club dropdown, rental color, kiosk theme toggle

**Files:** modify `lib/features/admin/settings_screen.dart` (or wherever kuželna settings live — add „Oddíly" section + kiosk theme switch), `lib/features/admin/players_screen.dart` (club dropdown), `lib/features/admin/rentals_screen.dart` (color picker), `lib/data/providers.dart` (Api.setKioskDark or fold into existing settings update).

- Settings: kiosk theme `SwitchListTile` „Kiosk: tmavý režim" → writes `schedule_settings.kiosk_dark` (Api update). „Oddíly" subsection: list clubs with a color swatch, add/edit (name + palette picker dialog: grid of the 12 swatches, read ClubColors), delete (confirm).
- Players: each player row gets a club dropdown (list from clubsProvider + „bez oddílu") → Api.setPlayerClub. Show current club name.
- Rentals form: color picker (palette + „výchozí"/-2) → saveRental color.
- Palette picker widget: reusable `lib/features/admin/widgets/color_picker.dart` (grid of ClubColors swatches showing dark bg, selected ring).

**Verify:** analyze + tests green (add widget test: club color picker selects an index; kiosk theme switch writes). Commit `feat: admin clubs, player club assignment, rental color, kiosk theme toggle`.

---

### Task 4: Render club colors — kiosk board + app SlotTile + kiosk theme

**Files:** modify `lib/features/kiosk/kiosk_shell.dart` + `kiosk_board_view.dart` (theme from settings.kioskDark; club color on lane rows), `lib/features/schedule/widgets/slot_tile.dart` (+ clubColorIndex tint), `lib/features/schedule/week_screen.dart` + `day_pager_view.dart` (pass club color per reservation).

- Kiosk theme: KioskShell reads `settingsProvider` kioskDark → `buildTheme(kioskDark ? dark : light)` instead of hardcoded dark. All kiosk widgets inherit; gridline alpha + status bar already theme-driven; verify readability both modes.
- Kiosk board lane row: for an occupied lane, look up the player's `club_color` (from players view → nameById-style map keyed by playerId → colorIndex) and tint the row via `ClubColors.of(index, brightness)` (bg+fg); fallback neutral when -1/none. Keep the „mine" highlight distinguishable (e.g. left accent bar in primary over the club bg).
- App SlotTile: add optional `clubColorIndex`; when set and state is a foreign reservation, tint bg/fg via ClubColors at `Theme.of(context).brightness`. „Mine" stays primaryContainer. Rentals: use `rental.color` (ClubColors index, or amber default when -2).
- week_screen/day_pager: build a `clubColorById` map from players and thread the index into slotTileFor / board cells (mirror the existing nameById plumbing).

**Verify:** analyze + full tests green; `flutter build web --release --base-href /rezervator/` + `flutter build apk --debug`. Add widget tests: board lane tinted by club color in dark AND light kiosk; app foreign reservation tinted; rental uses its color. Commit `feat: club colors on kiosk board and app grid, admin kiosk theme`.

---

### Task 5: Verify + apply + review + PR
- Full analyze/tests + web/apk builds; controller whole-branch review; fixes; apply 0003 to live DB (psql, user-approved); push; PR (note: stacks on main; if PR #6 nick/logout still open, mention ordering).
