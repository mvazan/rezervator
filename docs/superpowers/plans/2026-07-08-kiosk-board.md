# Rezervátor — Kiosková tabuľa + prep + vlastné časy + domácí/hosté (plan)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox steps.

**Goal:** Implement spec `docs/superpowers/specs/2026-07-08-kiosk-board-design.md`: landscape board kiosk view (days-as-columns from today, stacked full names/nicks), `matches.prep_minutes` blocking window with 🛠 cells, per-day custom block times editor, home/away teams, `profiles.nick`.

**Branch:** `kiosk-board` (from merged main ab1fe92). Czech UI. Spec wins over this plan on conflict.

## Global Constraints
- Domain pure Dart + TDD. Reservations/overrides mutate only via RPCs (`set_day_override` for overrides; special blocks via `Api.addSpecialTimeBlock` direct insert — admin RLS covers time_blocks).
- Migration is append-only `supabase/migrations/0002_board.sql`; 0001 stays untouched. Function bodies copied from 0001 must differ ONLY in the specified predicates/columns.
- Existing test TEXTS preserved except: `Vyplň soupeře.` → `Vyplň hosty.` and any test constructing `Match(opponent: …)` adapts to the new model (assert-equivalent, not weakened). All tests green + analyze clean each task.
- Commits end `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Migration 0002 + domain (TDD)

**Files:** create `supabase/migrations/0002_board.sql`; modify `lib/domain/models.dart`, `lib/domain/schedule.dart`, tests.

**Migration content (verbatim except copied bodies):**
```sql
-- 0002 — board: nick, match prep + home/away, players view, set_nick.

alter table profiles add column nick text not null default ''
  check (char_length(nick) <= 14);

alter table matches rename column opponent to away_team;
alter table matches add column home_team text not null default '';
alter table matches add column prep_minutes smallint not null default 0
  check (prep_minutes between 0 and 240);

drop view players;
create view players as
  select id, display_name, club, nick
  from profiles
  where status = 'approved' and role <> 'kiosk';
revoke all on players from anon;
grant select on players to authenticated;

create or replace function set_nick(p_user_id uuid, p_nick text default '')
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if auth.uid() <> p_user_id and not is_admin() then
    raise exception 'not_allowed';
  end if;
  if char_length(trim(coalesce(p_nick, ''))) > 14 then
    raise exception 'nick_too_long';
  end if;
  update profiles set nick = trim(coalesce(p_nick, '')) where id = p_user_id;
end;
$$;
```
Plus: copy `create_reservation` FULL body from 0001 as `create or replace`, changing ONLY the match-overlap predicate to the prep-aware clamped window:
```sql
  if exists (
    select 1 from matches m
    where m.date = p_date
      and (case when extract(epoch from m.starts_at) / 60 >= m.prep_minutes
                then m.starts_at - make_interval(mins => m.prep_minutes)
                else time '00:00' end) < v_block.ends_at
      and m.ends_at > v_block.starts_at
  ) then
    raise exception 'blocked_by_match';
  end if;
```
And copy `cancel_res_for_match` FULL body as `create or replace`, changing ONLY its overlap predicate the same way (`b.starts_at`/`b.ends_at` side unchanged; `new.starts_at`→ clamped `new.starts_at - prep`, i.e. `(case when extract(epoch from new.starts_at)/60 >= new.prep_minutes then new.starts_at - make_interval(mins => new.prep_minutes) else time '00:00' end) < b.ends_at and new.ends_at > b.starts_at`), and note `cancel_note = 'zápas: ' || new.away_team` (column rename!).

**Domain:**
- `Match`: `opponent` → `homeTeam` + `awayTeam` (+ `prepMinutes int`), `fromJson` reads `home_team`/`away_team`/`prep_minutes`; getter `String get title => homeTeam.isEmpty ? awayTeam : '$homeTeam – $awayTeam';` and `HourMinute get blockingStart` (startsAt minus prep, clamped to 00:00).
- `PlayerName`: + `nick` (from view; default '').
- `schedule.dart`: match-overlap uses `blockingStart`; `MatchSlot` gains `final bool isPrep` = block does NOT overlap the real `[startsAt, endsAt)` window (only the prep extension).
- New pure helper (in `lib/domain/blocks.dart`): `({List<String> reuseIds, List<(HourMinute, HourMinute)> toCreate}) matchSpecialBlocks({required List<TimeBlock> existingInactive, required List<(HourMinute, HourMinute)> requested})` — exact start+end match → reuse, else create.
- TDD: tests for prep window (block ending exactly at blockingStart is free; midnight clamp: match 00:15 prep 30 → blockingStart 00:00), isPrep true only for prep-only cells, Match.title both variants, matchSpecialBlocks (reuse/create/empty), fromJson round-trip. Update existing match fixtures (`opponent:` → `awayTeam:`; add `homeTeam: ''`, `prepMinutes: 0`) WITHOUT weakening asserts.

**Verify:** analyze + all tests green. Commit `feat: board migration and domain (prep, home/away, nick, special blocks)`.

---

### Task 2: Admin UI — match form, custom-times override editor, nick menu

**Files:** modify `lib/features/admin/matches_screen.dart`, `overrides_screen.dart`, `players_screen.dart`, `lib/data/providers.dart`, `lib/core/ui.dart` (friendlyDbError: `nick_too_long` → `Zkratka je moc dlouhá (max 14 znaků).`).

**Spec:**
1. Api additions: `setNick(String userId, String nick)` → rpc set_nick; `addSpecialTimeBlock(HourMinute start, HourMinute end)` → insert time_blocks `{starts_at, ends_at, position: start.minutesFromMidnight, active: false}` returning id (`.select('id').single()`); `saveMatch` gains `homeTeam`/`prepMinutes` params (renames `opponent`→`awayTeam`), writes `home_team`, `away_team`, `prep_minutes`.
2. Match dialog: fields `Domácí` (optional) above `Hosté` (required, validation `Vyplň hosty.`), and `Příprava drah` — SegmentedButton presets `0 / 30 / 60 min` + `Jiná…` (promptText number, 0–240, `Zadej 0–240 minut.`). List tile shows `Match.title`.
3. Overrides editor: two modes (`Zavřeno` with Důvod | `Otevřeno — vlastní časy`). Custom-times mode: rows `od–do` via `pickTime`, prefilled from the day's effective blocks (override blocks if set, else default active), add row ＋ / remove ✕; validations per spec (end>start `Konec musí být po začátku.`, pairwise overlap `Časy se nesmí překrývat.`, ≥1 row). Save: `matchSpecialBlocks(existingInactive: <from timeBlocksProvider where !active>, requested: rows)` → for toCreate call `Api.addSpecialTimeBlock` collecting ids → `Api.setDayOverride(blockIds: reuse+created)`. Existing-override rows prefill from its blocks' times. List subtitle for custom overrides shows the times (`15:30–16:30 · 16:30–17:30 · …`).
4. PlayersScreen: player menu gains `Zkratka na tabuli…` → promptText(initial: current nick, hint `Tom P.`) → `Api.setNick` (empty clears), success `Uloženo.`. Show current nick in the subtitle when set (`club · „nick“`). (Profiles stream already delivers nick for admins; Profile model: add `nick` field read from json — minor model touch, include here with fromJson default ''.)

**Verify:** analyze + tests green (`Vyplň soupeře.`→`Vyplň hosty.` test-copy update allowed per constraints). Commit `feat: match home/away and prep, custom day times editor, nick management`.

---

### Task 3: Kiosk board view + app prep tiles

**Files:** create `lib/features/kiosk/kiosk_board_view.dart`; modify `lib/features/kiosk/kiosk_shell.dart` (use board view; idle also resets horizontal scroll to today), `lib/features/schedule/widgets/slot_tile.dart` (+ prep variant), `lib/features/schedule/widgets/day_header.dart` (match strip uses `Match.title`), any `m.opponent` usages (kiosk info line etc.) → `m.title`.

**Spec (board):** per spec §1 — days-as-columns from `today` to `today + bookingHorizonDays`; column width `clamp(160, (w-rail)/7, 220)`; horizontal `ListView`/`PageView` with column snapping; left time rail from the UNION of visible days' blocks sorted by startsAt (row group height = laneCount × row height, uniform); cells: stacked lane rows (digit + name/nick/＋/🔒 renter, ellipsis; my reservation indigo; free bookable only with selected player + interactive gate as today); match cell `🏆 {title}\n{start}–{end}` spanning the block; prep-only cell `🛠 Příprava drah`; missing-block cell = dim empty; closed day = dim column with vertical `✕ zavřeno[ — reason]` + match cells still shown; DNES header gradient. Data: compute via two `buildWeekSchedule` calls (this week's and next week's Monday; slice days in range) — reuse existing providers (`weekReservationsProvider` for BOTH mondays). Status bar/booking flow/idle untouched otherwise. Name rendering: `nick.isNotEmpty ? nick : displayName` — needs players list (already fetched) mapped by id alongside display names.
**App tiles:** `SlotTile` MatchSlot rendering: when `state.isPrep` show `🛠` + text `Příprava` (compact) / `Příprava drah` (large) in muted rose — same tile semantics otherwise (inert).

**Verify:** analyze + tests green (kiosk widget tests adapt to board structure — same Czech action texts; day-count/dark assertions updated to board equivalents WITHOUT weakening: still assert 7 visible day headers from today + dark theme + booking flow + no cancel affordance). Commit `feat: kiosk board view with stacked names and prep cells`.

---

### Task 4: Tests polish + verification

- New widget tests (if not covered in T3): nick fallback + ellipsis on board; prep cell rendered for a prep-only block; custom-times editor validation (overlap rejected).
- `flutter analyze`; full `flutter test`; `flutter build web --release --base-href /rezervator/`; `flutter build apk --debug`.
- Controller: phase review → fixes → apply migration 0002 to live DB (psql) → push branch → PR.
