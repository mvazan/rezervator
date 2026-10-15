# Kiosk: dva panely, „Jak začít“, „Hráči týdne“ — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A left kiosk panel beside the right one with all panel modules placed from one admin table (side, share, order), plus two new modules: the „Jak začít“ guide with a Google Play QR code and „Hráči týdne“ (the previous week's best results of our players by 100/120 throws, gender, home/away, competition and club).

**Architecture:** One `schedule_settings.kiosk_panels` JSON (0077) replaces eight panel columns; a pure Dart model (`kiosk_layout.dart`) parses it and a generic `KioskPanelView` renders either side. The guide is a fixed card with a const QR matrix painted in device pixels. The week module reads `kiosk_week_players` (0078, security definer) and fills players' gender from the ČKA register through `regnum-lookup`'s new week mode.

**Tech Stack:** Flutter 3.38 + Riverpod 3, Supabase (Postgres migrations, plpgsql, RLS, tenancy SQL suite), Deno edge functions.

Spec: `docs/superpowers/specs/2026-10-15-kiosk-panels-design.md`. Branch `kiosk-panels` from `main` b17828f.

## Global Constraints

- Czech UI strings exactly as in the spec; code comments in English prose like the surrounding code.
- Commit each logical change separately; commit messages in Czech, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push, tag or deploy.
- Never run `dart format`.
- Dart tests: `TZ=Europe/Prague flutter test <file>`; `flutter analyze` clean.
- Migrations re-runnable, privileges as code (explicit grants/revokes); never `db reset` the dev DB, never `db push --include-all`.
- Schema snapshot + tenancy suite: `/private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/snap_repo.sh /Users/mvazan/Home/rezervator` must print `tenancy OK`; it rewrites `supabase/schema.sql`.
- Lists Czech-alphabetical (`compareCzech`) or chronological; the week rankings (best result first) are the one approved exception.
- No new packages in `pubspec.yaml`.
- `kiosk_panels` default JSON (exact): left {days 2, open false}, right {days 2, open false}, modules duty off 30, notices right 40, matches right 60, guide off 45, week off 55.
- Register gender codes: `1` → `m`, `2` → `f`, anything else null.

---

### Task 1: Migration 0077 — `kiosk_panels`, the old drawer converted and dropped

**Files:**
- Create: `supabase/migrations/0077_kiosk_panels.sql`
- Modify: `supabase/tests/tenancy_rls.sql` (the 0073 block at l. 10744–10816 is rewritten and 0077 re-run right after the 0073 re-run; a new 0077 block goes before the final `rollback;`)
- Modify: `supabase/schema.sql` (regenerated, never edited by hand)
- Modify: `docs/SCHEMA.md` (the `schedule_settings` row at l. 69 and the internal-helpers paragraph at l. 209–210)
- Test: `supabase/tests/tenancy_rls.sql` (run through `/private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/snap_repo.sh`)

**Interfaces:**
- Consumes: the eight old columns of `schedule_settings`: `kiosk_panel_enabled`, `kiosk_drawer_open`, `kiosk_drawer_columns`, `kiosk_notices_mode`, `kiosk_notices_share`, `kiosk_show_matches` (0064), `kiosk_duty_drawer`, `kiosk_duty_share` (0073). `kiosk_live_mode` is read and kept.
- Produces:
  - `kiosk_panels_valid(p jsonb) returns boolean`: plpgsql, `immutable`, `set search_path = public`, never raises. `revoke all … from public, anon; grant execute … to authenticated, service_role`.
  - `schedule_settings.kiosk_panels jsonb not null default '{"left": {"days": 2, "open": false}, "right": {"days": 2, "open": false}, "modules": [{"id": "duty", "side": "off", "share": 30}, {"id": "notices", "side": "right", "share": 40}, {"id": "matches", "side": "right", "share": 60}, {"id": "guide", "side": "off", "share": 45}, {"id": "week", "side": "off", "share": 55}]}'::jsonb`, with the check `schedule_settings_kiosk_panels_check` = `kiosk_panels_valid(kiosk_panels)`.
  - `schedule_settings.kiosk_notices_header boolean not null default true`.
  - The eight old columns are dropped. Their checks go with them: `schedule_settings_kiosk_drawer_columns_check`, `schedule_settings_kiosk_notices_mode_check`, `schedule_settings_kiosk_share_check` and `schedule_settings_kiosk_duty_share_check`.
  - **The conversion rule.** Task 2's `kioskPanelsFromLegacy` mirrors this exactly, and its unit test reuses the cases below.
    - `left = {days: 2, open: false}`; `right = {days: kiosk_drawer_columns, open: kiosk_drawer_open}`.
    - The modules are always listed in the order duty, notices, matches, guide, week. Guide (45) and week (55) are always `off`.
    - Each of the first three is placed `right` only when `kiosk_panel_enabled` is on:
      - duty when `kiosk_duty_drawer`;
      - notices when `kiosk_notices_mode in ('drawer','both')`;
      - matches when `kiosk_show_matches or kiosk_live_mode`.
    - Shares are computed in numeric, with d = `kiosk_duty_share` and n = `kiosk_notices_share`:
      - duty is d;
      - notices is n when duty is not placed; `round((100 − d)·n/100)` when duty and matches are both placed; otherwise 100 − d;
      - matches is 100 − n when duty is not placed; `100 − d − round((100 − d)·n/100)` when duty and notices are both placed; otherwise 100 − d.
    - A module that is alone on the panel therefore gets d (duty), n (notices) or 100 − n (matches).
    - `round` rounds half away from zero, like Dart's `round()`. Each placed share is then clamped to 5–95. A module that is `off` keeps its default share (30, 40, 60).
    - `kiosk_notices_header = kiosk_notices_mode in ('header','both')`.

  | case | enabled | open | columns | mode | n | show_matches | live | duty | d | header | right | duty | notices | matches |
  |---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
  | old defaults (alley A) | t | f | 2 | both | 40 | t | t | f | 30 | t | 2, closed | off 30 | right 40 | right 60 |
  | (30, 40) | t | t | 3 | both | 40 | t | t | t | 30 | t | 3, open | right 30 | right 28 | right 42 |
  | (90, 10) | t | f | 13 | drawer | 10 | t | t | t | 90 | f | 13, closed | right 90 | right 5 (1) | right 9 |
  | (90, 90) | t | f | 2 | both | 90 | t | t | t | 90 | t | 2, closed | right 90 | right 9 | right 5 (1) |
  | (60, 10) | t | f | 2 | both | 10 | t | t | t | 60 | t | 2, closed | right 60 | right 5 (4) | right 36 |
  | (55, 10) | t | f | 2 | both | 10 | t | t | t | 55 | t | 2, closed | right 55 | right 5 (4.5 → 5) | right 40 |
  | duty + matches | t | f | 2 | header | 40 | t | t | t | 70 | t | 2, closed | right 70 | off 40 | right 30 |
  | duty + notices | t | f | 2 | drawer | 40 | f | f | t | 25 | f | 2, closed | right 25 | right 75 | off 60 |
  | no duty | t | f | 2 | both | 75 | t | t | f | 30 | t | 2, closed | off 30 | right 75 | right 25 |
  | list off, live on | t | f | 2 | off | 35 | f | t | f | 30 | f | 2, closed | off 30 | off 40 | right 65 |
  | drawer off | f | t | 5 | both | 40 | t | t | t | 30 | t | 5, open | off 30 | off 40 | off 60 |
  | duty alone | t | f | 2 | header | 40 | f | f | t | 80 | t | 2, closed | right 80 | off 40 | off 60 |
  | notices alone | t | f | 2 | both | 30 | f | f | f | 30 | t | 2, closed | off 30 | right 30 | off 60 |

  Nothing else changes in the database. `public_week` is an allow-list since 0066 and needs nothing. The Dart app stays untouched in this task: it still reads the dropped fields, and `ScheduleSettings.fromJson` falls back to its defaults for them until Task 2/5.

- [ ] **Step 1: Check that no function, trigger, view or edge function reads the eight columns**

Run:
```bash
cd /Users/mvazan/Home/rezervator && grep -rnE 'kiosk_(panel_enabled|drawer_open|drawer_columns|notices_mode|notices_share|show_matches|duty_drawer|duty_share)' supabase/migrations supabase/functions supabase/snippets supabase/schema.sql supabase/tests
```
Expected hits, all harmless to the drop (checked on `kiosk-panels` at 719a8ad):
- `supabase/migrations/0064_kiosk_panel.sql`
  - l. 122–145: the `add column if not exists` lines and their checks.
  - l. 182: a comment.
  - l. 208–213: key removals in 0064's mask-style `public_week`. 0066 replaced that with the allow-list, and removing a key that is absent does nothing.
- `supabase/migrations/0065_kiosk_performance.sql` l. 33–38: the same mask, also replaced by 0066.
- `supabase/migrations/0073_kiosk_duty.sql` l. 9–10 (comment) and l. 20–23 (`add column`).
- `supabase/schema.sql`
  - l. 5672–5678 and 5710–5711: the columns.
  - l. 5722, 5724, 5730 and 5735: their four checks.
  - No function body names them.
- `supabase/tests/tenancy_rls.sql` l. 10763–10812: the 0073 block, rewritten in Step 2.
- `supabase/functions` and `supabase/snippets`: no hit. No edge function reads `schedule_settings` at all.

Other objects that touch the table:
- Three functions hold a `schedule_settings` row variable: `claim_freed_spot_watchers`, `create_reservation` and `watch_day`. They read only `lane_count`, `booking_horizon_days` and `max_active_reservations`.
- The only view is `players`, which does not read `schedule_settings`.
- The only trigger is `settings_shrink`, `AFTER UPDATE OF lane_count, training_weekdays`, so the conversion's UPDATE does not fire it.
- The table is published to realtime without a column list.

Nothing blocks the drop. If the grep shows any other hit, stop and fix that reader first.

- [ ] **Step 2: Write the failing tenancy test**

In `supabase/tests/tenancy_rls.sql`, replace the 0073 re-run and its block (l. 10744–10816). The old text is:

```sql
\ir ../migrations/0073_kiosk_duty.sql

-- 0073: the canteen duty on the kiosk — all three places off for a new
-- alley (its settings row comes from seed_tenant_defaults), the band
-- between the date and the matches, the card's share of the drawer 10–90,
-- the band at the top, in the middle or at the bottom and nowhere else,
-- and with all of it on the public overview still hands out its six
-- settings, nothing more. The file just ran a second time: the migration
-- is re-runnable.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_new constant uuid := '00000000-0000-0000-0000-000000000073';
  v_keys text[];
begin
  insert into tenants (id, name) values (v_new, 'Kuželna (0073)');
  if not exists (select 1 from schedule_settings
                  where tenant_id = v_new
                    and not kiosk_duty_header and not kiosk_duty_board
                    and not kiosk_duty_drawer and kiosk_duty_share = 30
                    and kiosk_duty_band_position = 'middle') then
    raise exception 'FAIL: a new alley''s kiosk does not start with the duty off, a 30 percent card and the band in the middle (0073)';
  end if;
  if not exists (select 1 from pg_constraint
                  where conrelid = 'schedule_settings'::regclass
                    and conname = 'schedule_settings_kiosk_duty_share_check') then
    raise exception 'FAIL: the duty card''s share has no named check (0073)';
  end if;
  if not exists (select 1 from pg_constraint
                  where conrelid = 'schedule_settings'::regclass
                    and conname =
                      'schedule_settings_kiosk_duty_band_position_check') then
    raise exception 'FAIL: the duty band''s position has no named check (0073)';
  end if;
  begin
    update schedule_settings set kiosk_duty_band_position = 'left'
     where tenant_id = v_a;
    raise exception 'FAIL: a duty band position other than top, middle or bottom was accepted (0073)';
  exception when check_violation then null;
  end;
  begin
    update schedule_settings set kiosk_duty_share = 9 where tenant_id = v_a;
    raise exception 'FAIL: a duty card under 10 percent of the drawer was accepted (0073)';
  exception when check_violation then null;
  end;
  begin
    update schedule_settings set kiosk_duty_share = 91 where tenant_id = v_a;
    raise exception 'FAIL: a duty card over 90 percent of the drawer was accepted (0073)';
  exception when check_violation then null;
  end;
  update schedule_settings
     set kiosk_duty_header = true, kiosk_duty_board = true,
         kiosk_duty_drawer = true, kiosk_duty_share = 10,
         kiosk_duty_band_position = 'top'
   where tenant_id = v_a;
  update schedule_settings
     set kiosk_duty_share = 90, kiosk_duty_band_position = 'bottom'
   where tenant_id = v_a;
  v_keys := array(select jsonb_object_keys(
                           public_week('kuzelna-a', current_date)->'settings')
                  order by 1);
  if v_keys <> array['booking_horizon_days', 'kiosk_dark', 'kiosk_fit_day',
                      'lane_count', 'max_active_reservations',
                      'training_weekdays'] then
    raise exception 'FAIL: public_week''s settings keys changed — the kiosk''s duty options may be reaching anon (0073): %', v_keys;
  end if;
  update schedule_settings
     set kiosk_duty_header = false, kiosk_duty_board = false,
         kiosk_duty_drawer = false, kiosk_duty_share = 30,
         kiosk_duty_band_position = 'middle'
   where tenant_id = v_a;
  raise notice 'OK: the kiosk''s duty is off for a new alley, its card 10–90 percent, its band top, middle or bottom, and stays off the public overview (0073)';
end $$;
```

The new text is:

```sql
\ir ../migrations/0073_kiosk_duty.sql
-- 0073 brought back the duty card's two columns, and 0064 (above) the old
-- drawer's six: 0077 sees all eight again, converts them into kiosk_panels
-- and drops them, so everything below sees the schema as it is (0077's own
-- checks are at the end of the file).
\ir ../migrations/0077_kiosk_panels.sql

-- 0073: the canteen duty on the kiosk — the header, the board and the
-- duty card off for a new alley (its settings row comes from
-- seed_tenant_defaults), the band between the date and the matches, the
-- band at the top, in the middle or at the bottom and nowhere else, and
-- with all of it on the public overview still hands out its six settings,
-- nothing more. The card's place and share are the duty module's in
-- kiosk_panels since 0077. The file just ran a second time: the migration
-- is re-runnable.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_new constant uuid := '00000000-0000-0000-0000-000000000073';
  v_keys text[];
begin
  insert into tenants (id, name) values (v_new, 'Kuželna (0073)');
  if not exists (select 1 from schedule_settings
                  where tenant_id = v_new
                    and not kiosk_duty_header and not kiosk_duty_board
                    and kiosk_panels @> '{"modules": [{"id": "duty", "side": "off"}]}'
                    and kiosk_duty_band_position = 'middle') then
    raise exception 'FAIL: a new alley''s kiosk does not start with the duty off and the band in the middle (0073)';
  end if;
  if not exists (select 1 from pg_constraint
                  where conrelid = 'schedule_settings'::regclass
                    and conname =
                      'schedule_settings_kiosk_duty_band_position_check') then
    raise exception 'FAIL: the duty band''s position has no named check (0073)';
  end if;
  begin
    update schedule_settings set kiosk_duty_band_position = 'left'
     where tenant_id = v_a;
    raise exception 'FAIL: a duty band position other than top, middle or bottom was accepted (0073)';
  exception when check_violation then null;
  end;
  update schedule_settings
     set kiosk_duty_header = true, kiosk_duty_board = true,
         kiosk_duty_band_position = 'top'
   where tenant_id = v_a;
  update schedule_settings
     set kiosk_duty_band_position = 'bottom'
   where tenant_id = v_a;
  v_keys := array(select jsonb_object_keys(
                           public_week('kuzelna-a', current_date)->'settings')
                  order by 1);
  if v_keys <> array['booking_horizon_days', 'kiosk_dark', 'kiosk_fit_day',
                      'lane_count', 'max_active_reservations',
                      'training_weekdays'] then
    raise exception 'FAIL: public_week''s settings keys changed — the kiosk''s duty options may be reaching anon (0073): %', v_keys;
  end if;
  update schedule_settings
     set kiosk_duty_header = false, kiosk_duty_board = false,
         kiosk_duty_band_position = 'middle'
   where tenant_id = v_a;
  raise notice 'OK: the kiosk''s duty is off for a new alley, its band top, middle or bottom, and stays off the public overview (0073)';
end $$;
```

Then add the 0077 block at the end of the file. Replace:

```sql
  raise notice 'OK: the name picker starts with letters, takes one of three modes, off the public overview (0076)';
end $$;

rollback;
```

with:

```sql
  raise notice 'OK: the name picker starts with letters, takes one of three modes, off the public overview (0076)';
end $$;

-- 0077: the kiosk's two panels. Alleys with the old drawer's settings in
-- every combination that matters, set through the old columns — 0064 and
-- 0073 bring them back — and then 0077 twice: the first run converts them
-- into kiosk_panels and drops the eight columns, the second finds them gone
-- and skips the conversion (it would fail on a missing column otherwise)
-- and changes nothing.
insert into tenants (id, name) values
  ('00000000-0000-0000-0000-000000077001', 'Kuželna (0077) 30/40'),
  ('00000000-0000-0000-0000-000000077002', 'Kuželna (0077) 90/10'),
  ('00000000-0000-0000-0000-000000077003', 'Kuželna (0077) 90/90'),
  ('00000000-0000-0000-0000-000000077004', 'Kuželna (0077) 60/10'),
  ('00000000-0000-0000-0000-000000077005', 'Kuželna (0077) 55/10'),
  ('00000000-0000-0000-0000-000000077006', 'Kuželna (0077) služba a zápasy'),
  ('00000000-0000-0000-0000-000000077007', 'Kuželna (0077) služba a nástěnka'),
  ('00000000-0000-0000-0000-000000077008', 'Kuželna (0077) bez služby'),
  ('00000000-0000-0000-0000-000000077009', 'Kuželna (0077) jen hraný zápas'),
  ('00000000-0000-0000-0000-000000077010', 'Kuželna (0077) panel vypnutý'),
  ('00000000-0000-0000-0000-000000077011', 'Kuželna (0077) jen služba'),
  ('00000000-0000-0000-0000-000000077012', 'Kuželna (0077) jen nástěnka');
\ir ../migrations/0064_kiosk_panel.sql
\ir ../migrations/0073_kiosk_duty.sql
-- Each alley's old settings and what 0077 must make of them. d = the duty
-- card's share of the drawer, n = the notices' share of the rest.
create temp table kiosk_0077_case (
  tenant_id uuid primary key,
  enabled boolean, open boolean, columns smallint, mode text, n smallint,
  matches boolean, live boolean, duty boolean, d smallint,
  header boolean, panels jsonb);
insert into kiosk_0077_case values
  -- The suite's alley A at the old defaults: the new default.
  ('00000000-0000-0000-0000-00000000000a',
   true, false, 2, 'both', 40, true, true, false, 30, true,
   '{"left": {"days": 2, "open": false}, "right": {"days": 2, "open": false},
     "modules": [{"id": "duty", "side": "off", "share": 30},
                 {"id": "notices", "side": "right", "share": 40},
                 {"id": "matches", "side": "right", "share": 60},
                 {"id": "guide", "side": "off", "share": 45},
                 {"id": "week", "side": "off", "share": 55}]}'),
  -- All three, (d, n) = (30, 40): 30, round(70 · 0.4) = 28, the rest 42.
  ('00000000-0000-0000-0000-000000077001',
   true, true, 3, 'both', 40, true, true, true, 30, true,
   '{"left": {"days": 2, "open": false}, "right": {"days": 3, "open": true},
     "modules": [{"id": "duty", "side": "right", "share": 30},
                 {"id": "notices", "side": "right", "share": 28},
                 {"id": "matches", "side": "right", "share": 42},
                 {"id": "guide", "side": "off", "share": 45},
                 {"id": "week", "side": "off", "share": 55}]}'),
  -- (90, 10): the notices' 1 is clamped to 5, the matches keep 100 − 90 − 1.
  ('00000000-0000-0000-0000-000000077002',
   true, false, 13, 'drawer', 10, true, true, true, 90, false,
   '{"left": {"days": 2, "open": false}, "right": {"days": 13, "open": false},
     "modules": [{"id": "duty", "side": "right", "share": 90},
                 {"id": "notices", "side": "right", "share": 5},
                 {"id": "matches", "side": "right", "share": 9},
                 {"id": "guide", "side": "off", "share": 45},
                 {"id": "week", "side": "off", "share": 55}]}'),
  -- (90, 90): the notices 9, the matches' 1 clamped to 5.
  ('00000000-0000-0000-0000-000000077003',
   true, false, 2, 'both', 90, true, true, true, 90, true,
   '{"left": {"days": 2, "open": false}, "right": {"days": 2, "open": false},
     "modules": [{"id": "duty", "side": "right", "share": 90},
                 {"id": "notices", "side": "right", "share": 9},
                 {"id": "matches", "side": "right", "share": 5},
                 {"id": "guide", "side": "off", "share": 45},
                 {"id": "week", "side": "off", "share": 55}]}'),
  -- (60, 10): the notices' 4 clamped to 5, the matches 100 − 60 − 4.
  ('00000000-0000-0000-0000-000000077004',
   true, false, 2, 'both', 10, true, true, true, 60, true,
   '{"left": {"days": 2, "open": false}, "right": {"days": 2, "open": false},
     "modules": [{"id": "duty", "side": "right", "share": 60},
                 {"id": "notices", "side": "right", "share": 5},
                 {"id": "matches", "side": "right", "share": 36},
                 {"id": "guide", "side": "off", "share": 45},
                 {"id": "week", "side": "off", "share": 55}]}'),
  -- (55, 10): 45 · 0.1 = 4.5 rounds half away from zero to 5, so the
  -- matches get 40 (integer division or round-half-even would give 41).
  ('00000000-0000-0000-0000-000000077005',
   true, false, 2, 'both', 10, true, true, true, 55, true,
   '{"left": {"days": 2, "open": false}, "right": {"days": 2, "open": false},
     "modules": [{"id": "duty", "side": "right", "share": 55},
                 {"id": "notices", "side": "right", "share": 5},
                 {"id": "matches", "side": "right", "share": 40},
                 {"id": "guide", "side": "off", "share": 45},
                 {"id": "week", "side": "off", "share": 55}]}'),
  -- The duty and the matches only (notices in the header): d and 100 − d.
  ('00000000-0000-0000-0000-000000077006',
   true, false, 2, 'header', 40, true, true, true, 70, true,
   '{"left": {"days": 2, "open": false}, "right": {"days": 2, "open": false},
     "modules": [{"id": "duty", "side": "right", "share": 70},
                 {"id": "notices", "side": "off", "share": 40},
                 {"id": "matches", "side": "right", "share": 30},
                 {"id": "guide", "side": "off", "share": 45},
                 {"id": "week", "side": "off", "share": 55}]}'),
  -- The duty and the notices only (the list and the live match off).
  ('00000000-0000-0000-0000-000000077007',
   true, false, 2, 'drawer', 40, false, false, true, 25, false,
   '{"left": {"days": 2, "open": false}, "right": {"days": 2, "open": false},
     "modules": [{"id": "duty", "side": "right", "share": 25},
                 {"id": "notices", "side": "right", "share": 75},
                 {"id": "matches", "side": "off", "share": 60},
                 {"id": "guide", "side": "off", "share": 45},
                 {"id": "week", "side": "off", "share": 55}]}'),
  -- No duty: the notices n, the matches 100 − n.
  ('00000000-0000-0000-0000-000000077008',
   true, false, 2, 'both', 75, true, true, false, 30, true,
   '{"left": {"days": 2, "open": false}, "right": {"days": 2, "open": false},
     "modules": [{"id": "duty", "side": "off", "share": 30},
                 {"id": "notices", "side": "right", "share": 75},
                 {"id": "matches", "side": "right", "share": 25},
                 {"id": "guide", "side": "off", "share": 45},
                 {"id": "week", "side": "off", "share": 55}]}'),
  -- The list off, the live match on: the matches are placed all the same.
  ('00000000-0000-0000-0000-000000077009',
   true, false, 2, 'off', 35, false, true, false, 30, false,
   '{"left": {"days": 2, "open": false}, "right": {"days": 2, "open": false},
     "modules": [{"id": "duty", "side": "off", "share": 30},
                 {"id": "notices", "side": "off", "share": 40},
                 {"id": "matches", "side": "right", "share": 65},
                 {"id": "guide", "side": "off", "share": 45},
                 {"id": "week", "side": "off", "share": 55}]}'),
  -- The drawer off: every module off with its default share; the right
  -- panel keeps the drawer's width and rest, the notices their header.
  ('00000000-0000-0000-0000-000000077010',
   false, true, 5, 'both', 40, true, true, true, 30, true,
   '{"left": {"days": 2, "open": false}, "right": {"days": 5, "open": true},
     "modules": [{"id": "duty", "side": "off", "share": 30},
                 {"id": "notices", "side": "off", "share": 40},
                 {"id": "matches", "side": "off", "share": 60},
                 {"id": "guide", "side": "off", "share": 45},
                 {"id": "week", "side": "off", "share": 55}]}'),
  -- The duty alone.
  ('00000000-0000-0000-0000-000000077011',
   true, false, 2, 'header', 40, false, false, true, 80, true,
   '{"left": {"days": 2, "open": false}, "right": {"days": 2, "open": false},
     "modules": [{"id": "duty", "side": "right", "share": 80},
                 {"id": "notices", "side": "off", "share": 40},
                 {"id": "matches", "side": "off", "share": 60},
                 {"id": "guide", "side": "off", "share": 45},
                 {"id": "week", "side": "off", "share": 55}]}'),
  -- The notices alone.
  ('00000000-0000-0000-0000-000000077012',
   true, false, 2, 'both', 30, false, false, false, 30, true,
   '{"left": {"days": 2, "open": false}, "right": {"days": 2, "open": false},
     "modules": [{"id": "duty", "side": "off", "share": 30},
                 {"id": "notices", "side": "right", "share": 30},
                 {"id": "matches", "side": "off", "share": 60},
                 {"id": "guide", "side": "off", "share": 45},
                 {"id": "week", "side": "off", "share": 55}]}');
update schedule_settings s
   set kiosk_panel_enabled = c.enabled, kiosk_drawer_open = c.open,
       kiosk_drawer_columns = c.columns, kiosk_notices_mode = c.mode,
       kiosk_notices_share = c.n, kiosk_show_matches = c.matches,
       kiosk_live_mode = c.live, kiosk_duty_drawer = c.duty,
       kiosk_duty_share = c.d
  from kiosk_0077_case c
 where c.tenant_id = s.tenant_id;
\ir ../migrations/0077_kiosk_panels.sql
create temp table kiosk_0077_first as
  select tenant_id, kiosk_panels, kiosk_notices_header from schedule_settings;
\ir ../migrations/0077_kiosk_panels.sql

-- An admin of a new alley, who saves the layout as authenticated below.
insert into tenants (id, name) values
  ('00000000-0000-0000-0000-000000077000', 'Kuželna (0077)');
insert into auth.users (id, email) values
  ('77000000-0000-0000-0000-000000000001', 'panely-0077@example.com')
on conflict do nothing;
insert into profiles (id, tenant_id, display_name, email, role, status)
values ('77000000-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-000000077000', 'Správce 0077',
        'panely-0077@example.com', 'admin', 'approved');

do $$
declare
  v_new constant uuid := '00000000-0000-0000-0000-000000077000';
  v_default constant jsonb :=
    '{"left": {"days": 2, "open": false}, "right": {"days": 2, "open": false},
      "modules": [{"id": "duty", "side": "off", "share": 30},
                  {"id": "notices", "side": "right", "share": 40},
                  {"id": "matches", "side": "right", "share": 60},
                  {"id": "guide", "side": "off", "share": 45},
                  {"id": "week", "side": "off", "share": 55}]}';
  v_case record;
  v_label text;
  v_layout jsonb;
  v_keys text[];
begin
  -- Each alley converted as its old drawer showed it.
  for v_case in
    select c.tenant_id, c.header, c.panels,
           s.kiosk_panels as got, s.kiosk_notices_header as got_header
      from kiosk_0077_case c
      join schedule_settings s on s.tenant_id = c.tenant_id
  loop
    if v_case.got is distinct from v_case.panels then
      raise exception 'FAIL: alley % converted to %, expected % (0077)',
        v_case.tenant_id, v_case.got, v_case.panels;
    end if;
    if v_case.got_header is distinct from v_case.header then
      raise exception 'FAIL: alley % has kiosk_notices_header %, expected % (0077)',
        v_case.tenant_id, v_case.got_header, v_case.header;
    end if;
  end loop;
  if (select count(*) from kiosk_0077_case) <> 13 then
    raise exception 'FAIL: the conversion cases are not all there (0077)';
  end if;

  -- The second run skipped the conversion and changed nothing.
  if exists (select 1 from kiosk_0077_first f
               join schedule_settings s using (tenant_id)
              where s.kiosk_panels is distinct from f.kiosk_panels
                 or s.kiosk_notices_header is distinct from f.kiosk_notices_header) then
    raise exception 'FAIL: running 0077 again changed a converted layout (0077)';
  end if;

  -- The old columns and their checks are gone, the new check is there.
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'schedule_settings'
                and column_name in ('kiosk_panel_enabled', 'kiosk_drawer_open',
                                    'kiosk_drawer_columns', 'kiosk_notices_mode',
                                    'kiosk_notices_share', 'kiosk_show_matches',
                                    'kiosk_duty_drawer', 'kiosk_duty_share')) then
    raise exception 'FAIL: an old drawer column survived 0077';
  end if;
  if exists (select 1 from pg_constraint
              where conrelid = 'schedule_settings'::regclass
                and conname in ('schedule_settings_kiosk_drawer_columns_check',
                                'schedule_settings_kiosk_notices_mode_check',
                                'schedule_settings_kiosk_share_check',
                                'schedule_settings_kiosk_duty_share_check')) then
    raise exception 'FAIL: an old drawer column''s check survived 0077';
  end if;
  if not exists (select 1 from pg_constraint
                  where conrelid = 'schedule_settings'::regclass
                    and conname = 'schedule_settings_kiosk_panels_check') then
    raise exception 'FAIL: kiosk_panels has no named check (0077)';
  end if;

  -- A new alley starts with the default layout and the notices' line.
  if not exists (select 1 from schedule_settings
                  where tenant_id = v_new and kiosk_panels = v_default
                    and kiosk_notices_header) then
    raise exception 'FAIL: a new alley does not start with the default panels and the notices in the header (0077)';
  end if;

  -- Bad layouts are a check violation, nothing else.
  for v_label, v_layout in
    select * from (values
      ('a duplicate id',
       '{"left": {"days": 2, "open": false}, "right": {"days": 2, "open": false},
         "modules": [{"id": "duty", "side": "off", "share": 30},
                     {"id": "duty", "side": "right", "share": 30}]}'::jsonb),
      ('an unknown side',
       '{"left": {"days": 2, "open": false}, "right": {"days": 2, "open": false},
         "modules": [{"id": "duty", "side": "top", "share": 30}]}'),
      ('a share of 4',
       '{"left": {"days": 2, "open": false}, "right": {"days": 2, "open": false},
         "modules": [{"id": "duty", "side": "right", "share": 4}]}'),
      ('a share of 96',
       '{"left": {"days": 2, "open": false}, "right": {"days": 2, "open": false},
         "modules": [{"id": "duty", "side": "right", "share": 96}]}'),
      ('a share of 50.5',
       '{"left": {"days": 2, "open": false}, "right": {"days": 2, "open": false},
         "modules": [{"id": "duty", "side": "right", "share": 50.5}]}'),
      ('a share as a string',
       '{"left": {"days": 2, "open": false}, "right": {"days": 2, "open": false},
         "modules": [{"id": "duty", "side": "right", "share": "50"}]}'),
      ('a panel 0 days wide',
       '{"left": {"days": 0, "open": false}, "right": {"days": 2, "open": false},
         "modules": []}'),
      ('a panel 14 days wide',
       '{"left": {"days": 2, "open": false}, "right": {"days": 14, "open": false},
         "modules": []}'),
      ('a panel 2.5 days wide',
       '{"left": {"days": 2.5, "open": false}, "right": {"days": 2, "open": false},
         "modules": []}'),
      ('open as a string',
       '{"left": {"days": 2, "open": "true"}, "right": {"days": 2, "open": false},
         "modules": []}'),
      ('no left panel',
       '{"right": {"days": 2, "open": false}, "modules": []}'),
      ('a null right panel',
       '{"left": {"days": 2, "open": false}, "right": null, "modules": []}'),
      ('the modules an object',
       '{"left": {"days": 2, "open": false}, "right": {"days": 2, "open": false},
         "modules": {"id": "duty", "side": "off", "share": 30}}'),
      ('a module that is not an object',
       '{"left": {"days": 2, "open": false}, "right": {"days": 2, "open": false},
         "modules": ["duty"]}'),
      ('an empty id',
       '{"left": {"days": 2, "open": false}, "right": {"days": 2, "open": false},
         "modules": [{"id": "", "side": "off", "share": 30}]}'),
      ('a numeric id',
       '{"left": {"days": 2, "open": false}, "right": {"days": 2, "open": false},
         "modules": [{"id": 1, "side": "off", "share": 30}]}'),
      ('an array', '[]'),
      ('a JSON null', 'null')) v
  loop
    begin
      update schedule_settings set kiosk_panels = v_layout where tenant_id = v_new;
      raise exception 'FAIL: kiosk_panels took a layout with % (0077): %', v_label, v_layout;
    exception when check_violation then null;
    end;
  end loop;
  -- Called directly it answers false — not null, not an error — for
  -- anything that is not a layout.
  if kiosk_panels_valid(null) is distinct from false
     or kiosk_panels_valid('"panels"') is distinct from false
     or kiosk_panels_valid('7') is distinct from false
     or kiosk_panels_valid('{"left": [], "right": 1, "modules": "x"}') is distinct from false then
    raise exception 'FAIL: kiosk_panels_valid does not answer false for a non-layout (0077)';
  end if;

  -- The bounds pass, and so does a module this database has never heard
  -- of, with options of its own: the app keeps it and writes it back.
  update schedule_settings
     set kiosk_panels =
       '{"left": {"days": 1, "open": true}, "right": {"days": 13, "open": false},
         "modules": [{"id": "duty", "side": "left", "share": 5},
                     {"id": "notices", "side": "right", "share": 95},
                     {"id": "future", "side": "left", "share": 50, "size": "big"}]}'
   where tenant_id = v_new;
  update schedule_settings
     set kiosk_panels = '{"left": {"days": 2, "open": false},
                          "right": {"days": 2, "open": false}, "modules": []}'
   where tenant_id = v_new;
  update schedule_settings set kiosk_panels = v_default where tenant_id = v_new;

  -- The check calls the validator as the admin who saves: authenticated
  -- may execute it, anon may not.
  if not has_function_privilege('authenticated', 'public.kiosk_panels_valid(jsonb)', 'execute') then
    raise exception 'FAIL: authenticated cannot execute kiosk_panels_valid — no admin could save the panels (0077)';
  end if;
  if has_function_privilege('anon', 'public.kiosk_panels_valid(jsonb)', 'execute') then
    raise exception 'FAIL: anon may execute kiosk_panels_valid (0077)';
  end if;

  -- None of it reaches the public overview: its six settings, nothing more.
  v_keys := array(select jsonb_object_keys(
                           public_week('kuzelna-a', current_date)->'settings')
                  order by 1);
  if v_keys <> array['booking_horizon_days', 'kiosk_dark', 'kiosk_fit_day',
                      'lane_count', 'max_active_reservations',
                      'training_weekdays'] then
    raise exception 'FAIL: public_week''s settings keys changed — the kiosk''s panels may be reaching anon (0077): %', v_keys;
  end if;
  raise notice 'OK: the old drawer converts into kiosk_panels and its columns are gone, a new alley gets the default, bad layouts are check violations, the panels stay off the public overview (0077)';
end $$;

-- The admin saves the layout through the API's role: the check runs as
-- authenticated, and a bad layout is still refused.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"77000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_new constant uuid := '00000000-0000-0000-0000-000000077000';
begin
  update schedule_settings
     set kiosk_panels = jsonb_set(kiosk_panels, '{left,days}', '3'),
         kiosk_notices_header = false
   where tenant_id = v_new;
  if not found then
    raise exception 'FAIL: the admin could not save the kiosk panels (0077)';
  end if;
  begin
    update schedule_settings
       set kiosk_panels = jsonb_set(kiosk_panels, '{right,days}', '0')
     where tenant_id = v_new;
    raise exception 'FAIL: the admin saved a panel 0 days wide (0077)';
  exception when check_violation then null;
  end;
end $$;
reset role;
do $$
begin
  if not exists (select 1 from schedule_settings
                  where tenant_id = '00000000-0000-0000-0000-000000077000'
                    and (kiosk_panels #>> '{left,days}') = '3'
                    and not kiosk_notices_header) then
    raise exception 'FAIL: the admin''s layout was not saved (0077)';
  end if;
  raise notice 'OK: an admin saves the kiosk panels through the check as authenticated (0077)';
end $$;

rollback;
```

- [ ] **Step 3: Run the suite and see it fail**

Run:
```bash
/private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/snap_repo.sh /Users/mvazan/Home/rezervator
grep -n "error:" /private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/supa-throwaway/tenancy.log
```
Expected:
- The script prints `tenancy FAILED`.
- The grep shows `tenancy_rls.sql:10749: error: …/supabase/tests/../migrations/0077_kiosk_panels.sql: No such file or directory`.
- No `schema.sql` diff is printed, because no migration changed.

- [ ] **Step 4: Write the migration**

Create `supabase/migrations/0077_kiosk_panels.sql`:

```sql
-- 0077 — the kiosk's two panels (Správa → Kiosk → Panely): one on each
-- side of the board, each so many day columns wide and open or closed at
-- rest, and the modules placed in them — off, left or right, a share of
-- the panel's height, an order. One jsonb column holds it all:
--
--   {"left":  {"days": 2, "open": false},
--    "right": {"days": 2, "open": false},
--    "modules": [{"id": "duty", "side": "off", "share": 30}, …]}
--
-- The modules are duty (the canteen duty, 0073), notices (Nástěnka),
-- matches (the list and the match being played), guide (Jak začít) and
-- week (Hráči týdne); the array's order is their order in a panel, and a
-- share is a weight — a panel need not sum to 100. kiosk_panels_valid
-- checks the shape, not the ids: the app skips an id it does not know and
-- writes it back unchanged, so a later module needs no migration.
-- kiosk_notices_header is the half of kiosk_notices_mode that was not about
-- the panel: Nástěnka's line in the status bar.
--
-- The eight columns of the old single drawer (0064, 0073) are converted
-- and dropped. No function, trigger, view or edge function reads them;
-- public_week is an allow-list since 0066.
--
-- Re-runnable on purpose, like 0064 and 0065: the conversion runs only
-- while all eight old columns exist. The tenancy suite re-runs 0064 and
-- 0073, which bring them back, and then this file.

-- Whether a value is a panel layout. It never raises: every value is
-- looked at with jsonb_typeof before it is read, so a bad layout is a
-- check violation and nothing else. The CHECK runs as the admin who saves:
-- authenticated executes it, anon does not.
create or replace function kiosk_panels_valid(p jsonb) returns boolean
    language plpgsql immutable set search_path = public as $$
declare
  v_side text;
  v_panel jsonb;
  v_module jsonb;
  v_ids text[] := '{}';
begin
  if jsonb_typeof(p) is distinct from 'object' then
    return false;
  end if;
  foreach v_side in array array['left', 'right'] loop
    v_panel := p -> v_side;
    if jsonb_typeof(v_panel) is distinct from 'object'
       or jsonb_typeof(v_panel -> 'days') is distinct from 'number'
       or jsonb_typeof(v_panel -> 'open') is distinct from 'boolean' then
      return false;
    end if;
    -- A JSON number: its text always casts to numeric.
    if (v_panel ->> 'days')::numeric <> trunc((v_panel ->> 'days')::numeric)
       or (v_panel ->> 'days')::numeric not between 1 and 13 then
      return false;
    end if;
  end loop;
  if jsonb_typeof(p -> 'modules') is distinct from 'array' then
    return false;
  end if;
  for v_module in select value from jsonb_array_elements(p -> 'modules') loop
    if jsonb_typeof(v_module) is distinct from 'object'
       or jsonb_typeof(v_module -> 'id') is distinct from 'string'
       or jsonb_typeof(v_module -> 'side') is distinct from 'string'
       or jsonb_typeof(v_module -> 'share') is distinct from 'number' then
      return false;
    end if;
    if v_module ->> 'id' = '' or v_module ->> 'id' = any (v_ids)
       or v_module ->> 'side' not in ('off', 'left', 'right')
       or (v_module ->> 'share')::numeric
            <> trunc((v_module ->> 'share')::numeric)
       or (v_module ->> 'share')::numeric not between 5 and 95 then
      return false;
    end if;
    v_ids := v_ids || (v_module ->> 'id');
  end loop;
  return true;
end;
$$;
revoke all on function kiosk_panels_valid(jsonb) from public, anon;
grant execute on function kiosk_panels_valid(jsonb) to authenticated, service_role;
comment on function kiosk_panels_valid(jsonb) is
  'Whether a value is a kiosk panel layout (0077), for the check on schedule_settings.kiosk_panels; never raises. authenticated executes it: the check runs as the admin who saves.';

-- A new alley: the right panel with the notices and the matches, closed —
-- what the old drawer's defaults convert to.
alter table schedule_settings
  add column if not exists kiosk_panels jsonb not null default
    '{"left": {"days": 2, "open": false},
      "right": {"days": 2, "open": false},
      "modules": [{"id": "duty", "side": "off", "share": 30},
                  {"id": "notices", "side": "right", "share": 40},
                  {"id": "matches", "side": "right", "share": 60},
                  {"id": "guide", "side": "off", "share": 45},
                  {"id": "week", "side": "off", "share": 55}]}'::jsonb
    constraint schedule_settings_kiosk_panels_check
    check (kiosk_panels_valid(kiosk_panels)),
  add column if not exists kiosk_notices_header boolean not null default true;
comment on column schedule_settings.kiosk_panels is
  'The kiosk''s two panels and the modules in them (0077): left/right {days 1–13, open}, modules [{id, side off|left|right, share 5–95}] in their order. kiosk_panels_valid checks the shape only; the app keeps an id it does not know.';
comment on column schedule_settings.kiosk_notices_header is
  'Nástěnka''s line in the kiosk''s status bar, one notice title at a time (0077: the header half of the dropped kiosk_notices_mode). Default on.';

-- The old drawer, converted. plpgsql plans the update, which names the old
-- columns, only when it runs, so the block also runs once they are gone.
-- The right panel is the old drawer; a module goes in it when the drawer
-- was on and showed it — the matches also when only the match being played
-- did (with the list off it took the drawer all the same; now it needs the
-- matches placed, so such an alley gets the list too). The shares flatten
-- the old nested weights (the duty d % of the drawer, the notices n % of
-- the rest), in numeric — round() half away from zero, as Dart's round() —
-- and each is clamped to 5–95. A module left off keeps its default share.
do $$
begin
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'schedule_settings'
         and column_name in ('kiosk_panel_enabled', 'kiosk_drawer_open',
                             'kiosk_drawer_columns', 'kiosk_notices_mode',
                             'kiosk_notices_share', 'kiosk_show_matches',
                             'kiosk_duty_drawer', 'kiosk_duty_share')) < 8 then
    return;
  end if;
  with placed as (
    select tenant_id,
           kiosk_panel_enabled and kiosk_duty_drawer as duty,
           kiosk_panel_enabled
             and kiosk_notices_mode in ('drawer', 'both') as notices,
           kiosk_panel_enabled
             and (kiosk_show_matches or kiosk_live_mode) as matches,
           kiosk_duty_share::numeric as d,
           kiosk_notices_share::numeric as n
      from schedule_settings
  ), shares as (
    -- The duty d; with the notices and the matches both placed, the
    -- notices (100 − d)·n/100 and the matches the rest to 100; with one of
    -- them, that one 100 − d. Without the duty, the notices n and the
    -- matches 100 − n. A module alone fills its panel whatever its share.
    select tenant_id, duty, notices, matches,
           d as duty_share,
           case when not duty then n
                when matches then round((100 - d) * n / 100)
                else 100 - d end as notices_share,
           case when not duty then 100 - n
                when notices then 100 - d - round((100 - d) * n / 100)
                else 100 - d end as matches_share
      from placed
  )
  update schedule_settings s
     set kiosk_panels = jsonb_build_object(
           'left', jsonb_build_object('days', 2, 'open', false),
           'right', jsonb_build_object('days', s.kiosk_drawer_columns,
                                       'open', s.kiosk_drawer_open),
           'modules', jsonb_build_array(
             jsonb_build_object(
               'id', 'duty',
               'side', case when x.duty then 'right' else 'off' end,
               'share', case when x.duty
                             then greatest(5, least(95, x.duty_share))::int
                             else 30 end),
             jsonb_build_object(
               'id', 'notices',
               'side', case when x.notices then 'right' else 'off' end,
               'share', case when x.notices
                             then greatest(5, least(95, x.notices_share))::int
                             else 40 end),
             jsonb_build_object(
               'id', 'matches',
               'side', case when x.matches then 'right' else 'off' end,
               'share', case when x.matches
                             then greatest(5, least(95, x.matches_share))::int
                             else 60 end),
             jsonb_build_object('id', 'guide', 'side', 'off', 'share', 45),
             jsonb_build_object('id', 'week', 'side', 'off', 'share', 55))),
         kiosk_notices_header = s.kiosk_notices_mode in ('header', 'both')
    from shares x
   where x.tenant_id = s.tenant_id;
end $$;

-- Their checks (schedule_settings_kiosk_drawer_columns_check,
-- …_kiosk_notices_mode_check, …_kiosk_share_check and
-- …_kiosk_duty_share_check) go with them.
alter table schedule_settings
  drop column if exists kiosk_panel_enabled,
  drop column if exists kiosk_drawer_open,
  drop column if exists kiosk_drawer_columns,
  drop column if exists kiosk_notices_mode,
  drop column if exists kiosk_notices_share,
  drop column if exists kiosk_show_matches,
  drop column if exists kiosk_duty_drawer,
  drop column if exists kiosk_duty_share;
```

- [ ] **Step 5: Regenerate the snapshot and run the suite, which now passes**

Run:
```bash
/private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/snap_repo.sh /Users/mvazan/Home/rezervator
grep -c "OK: .*(0077)" /private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/supa-throwaway/tenancy.log
grep -o "OK: the kiosk's duty.*(0073)" /private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/supa-throwaway/tenancy.log
git -C /Users/mvazan/Home/rezervator diff supabase/schema.sql
```
Expected:
- The script prints `tenancy OK`, then ` 1 file changed, 74 insertions(+), 12 deletions(-)`.
- The first grep prints `2`.
- The second prints the rewritten 0073 notice.
- The `schema.sql` diff contains only these changes:
  - the new function `kiosk_panels_valid("p" "jsonb")` (LANGUAGE plpgsql IMMUTABLE, `SET "search_path" TO 'public'`), with its `COMMENT ON FUNCTION`;
  - the eight columns removed from `schedule_settings`, and `kiosk_panels` and `kiosk_notices_header` added at the end of the table;
  - the four old checks removed, and `CONSTRAINT "schedule_settings_kiosk_panels_check" CHECK ("public"."kiosk_panels_valid"("kiosk_panels"))` added;
  - two `COMMENT ON COLUMN` lines;
  - `REVOKE ALL … FROM PUBLIC` plus `GRANT ALL … TO "authenticated"` and `… TO "service_role"` for `kiosk_panels_valid` (no `anon` line).

  This exact result was verified on a scratch copy of the repo. A mutation that used integer arithmetic for the shares was caught by the (55, 10) case: matches came out 41 instead of 40.

- [ ] **Step 6: Update docs/SCHEMA.md**

Make four exact replacements. Each `old` occurs once.

Edit 1 (row `schedule_settings`, l. 69). Old:
```text
`kiosk_dark`, `kiosk_fit_day`, the kiosk panel's settings (0064): `kiosk_panel_enabled`, `kiosk_drawer_open`, `kiosk_drawer_columns` (1–13 day columns the open drawer covers, at most `kiosk_visible_days` − 1 in the app), `kiosk_notices_mode` (off \| drawer \| header \| both), `kiosk_notices_rotation_seconds`, `kiosk_notices_share` (10–90 %), `kiosk_show_matches`, `kiosk_show_upcoming`,
```
New:
```text
`kiosk_dark`, `kiosk_fit_day`, the kiosk's panels (0077, Správa → Kiosk → Panely): `kiosk_panels` (jsonb `{"left": {"days", "open"}, "right": {"days", "open"}, "modules": [{"id", "side", "share"}, …]}` — per panel the day columns it covers when open, 1–13 (the app keeps the two together at most `kiosk_visible_days` − 1), and whether it rests open; per module (`duty`, `notices`, `matches`, `guide`, `week`) its panel, off \| left \| right, and its share of the panel's height, 5–95, a weight; the array's order is the order in a panel. `schedule_settings_kiosk_panels_check` = `kiosk_panels_valid(kiosk_panels)`, which checks the shape and never raises; the ids are not listed — the app keeps one it does not know and writes it back. Default: the right panel, 2 days, closed, with the notices 40 and the matches 60, the rest off) and `kiosk_notices_header` (0077: Nástěnka's line in the status bar, default on) — 0077 converted the old single drawer's columns (`kiosk_panel_enabled`, `kiosk_drawer_open`, `kiosk_drawer_columns`, `kiosk_notices_mode`, `kiosk_notices_share`, `kiosk_show_matches` from 0064, `kiosk_duty_drawer`, `kiosk_duty_share` from 0073) into these two and dropped them; the kiosk's other settings (0064): `kiosk_notices_rotation_seconds`, `kiosk_show_upcoming`,
```

Edit 2 (same row). Old:
```text
the drawer button's breathing and, 0072,
```
New:
```text
the panel buttons' breathing and, 0072,
```

Edit 3 (same row). Old:
```text
`kiosk_duty_board` (a band across a duty's days in the board's day headers), `kiosk_duty_band_position` (where in the headers that band runs: top \| middle \| bottom — above the day label, between it and the day's matches, or along the bottom edge under them; default middle, `schedule_settings_kiosk_duty_band_position_check`), `kiosk_duty_drawer` (a card with the duty and the plan in the side drawer) and `kiosk_duty_share` (10–90 % of the drawer's height that card takes, default 30, `schedule_settings_kiosk_duty_share_check`; the notices and the matches share the rest), `duty_reminder_enabled`
```
New:
```text
`kiosk_duty_board` (a band across a duty's days in the board's day headers) and `kiosk_duty_band_position` (where in the headers that band runs: top \| middle \| bottom — above the day label, between it and the day's matches, or along the bottom edge under them; default middle, `schedule_settings_kiosk_duty_band_position_check`); the card with the duty and the plan is the `duty` module of `kiosk_panels` since 0077, `duty_reminder_enabled`
```

Edit 4 (the "Internal, no EXECUTE for app roles" paragraph, l. 209–210). Old:
```text
internal either: `authenticated` executes them, `anon` does not —
§Zprávy a nástěnka.)
```
New:
```text
internal either: `authenticated` executes them, `anon` does not —
§Zprávy a nástěnka. Nor is `kiosk_panels_valid(jsonb)` (0077): the check
on `schedule_settings.kiosk_panels` runs as the admin who saves, so
`authenticated` executes it; `anon` does not.)
```

Check that the old columns are named only in the conversion sentence:
```bash
grep -c "kiosk_drawer_open\|kiosk_duty_share" /Users/mvazan/Home/rezervator/docs/SCHEMA.md
```
Expected: `1`. That one line, l. 69, holds the sentence that says 0077 converted and dropped them.

- [ ] **Step 7: Commit**

```bash
cd /Users/mvazan/Home/rezervator
git add supabase/migrations/0077_kiosk_panels.sql supabase/tests/tenancy_rls.sql supabase/schema.sql docs/SCHEMA.md
git commit -m "$(cat <<'EOF'
feat(db): dva panely kiosku — kiosk_panels, převod starého panelu (0077)

kiosk_panels (jsonb): levý a pravý panel (šířka 1–13 dní, výchozně
rozbalený) a moduly duty/notices/matches/guide/week s panelem a podílem
5–95; kontrola kiosk_panels_valid nikdy nehází a smí ji volat jen
authenticated. kiosk_notices_header = nástěnka v záhlaví. Osm sloupců
starého panelu převedeno (podíly v numeric, sevřené na 5–95; hraný
zápas bez seznamu dostane modul matches) a odstraněno. Tenancy test
(převod, opakovaný běh, výchozí stav, odmítnuté tvary, práva, public_week),
snapshot, SCHEMA.md.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

Do not apply 0077 to the local dev stack (port 54322) in this task. The app there still writes the old columns until Task 4. Task 13 applies it (`supabase migration up --local`) before the browser check.


### Task 2: Model rozložení panelů (`lib/domain/kiosk_layout.dart`) a `ScheduleSettings.kioskPanels` / `kioskNoticesHeader`

The pure model of the two panels: both enums, the layout with its JSON (unknown ids kept), the admin's edits, the panel widths, and a Dart mirror of 0077's conversion that pins the conversion arithmetic in unit tests. `ScheduleSettings` gains the two new fields. **The old fields stay as they are in this task.** Their columns are gone since Task 1, so they parse to their defaults; Tasks 3 and 4 move every reader over, and Task 5 deletes them.

**Files:**
- Create: `lib/domain/kiosk_layout.dart`
- Create: `test/domain/kiosk_layout_test.dart`
- Modify: `lib/domain/models.dart` (an import; `ScheduleSettings` constructor, fields and `fromJson`)
- Modify: `test/domain/models_test.dart` (imports; two tests at the end of group `ScheduleSettings`)

**Interfaces:**
- Consumes:
  - From Task 1: `supabase/migrations/0077_kiosk_panels.sql`, whose column default is one single-quoted JSON literal, `kiosk_panels jsonb not null default '{…}'::jsonb`. A test here reads that literal and compares it with `KioskPanels.defaults`.
  - The conversion that Task 1's SQL does has to match `kioskPanelsFromLegacy`. Placement:
    - duty is right when `kiosk_panel_enabled and kiosk_duty_drawer`;
    - notices are right when `kiosk_panel_enabled and kiosk_notices_mode in ('drawer','both')`;
    - matches are right when `kiosk_panel_enabled and (kiosk_show_matches or kiosk_live_mode)`.
  - Shares, with `d` = `kiosk_duty_share` and `n` = `kiosk_notices_share`. The duty's share is `d` whenever duty is placed. The notices' share follows this CASE:

    ```sql
    case when duty and matches then round((100 - d) * n / 100.0)::int
         when duty then 100 - d
         else n end
    ```

    The matches' share follows this CASE:

    ```sql
    case when duty and notices then 100 - d - round((100 - d) * n / 100.0)::int
         when duty then 100 - d
         else 100 - n end
    ```

    Each placed share is then clamped with `greatest(5, least(95, …))`. The matches' remainder is computed from the notices value before the clamp. Read this way, a module that is alone in the panel gets duty `d`, notices `n` and matches `100 − n`. The spec leaves that case open ("its old share does not matter"), so Task 1's CASEs must be equivalent to these.
- Produces (`lib/domain/kiosk_layout.dart`, pure Dart, no Flutter import):
  - `enum KioskModule { duty, notices, matches, guide, week }` and `enum PanelSide { off, left, right }`. Each `.name` is the JSON id or side.
  - `int kioskModuleDefaultShare(KioskModule m)` returns duty 30, notices 40, matches 60, guide 45, week 55.
  - `const kioskPanelMinDays = 1`, `kioskPanelMaxDays = 13`, `kioskModuleMinShare = 5`, `kioskModuleMaxShare = 95`. These are additions: the admin (Task 4) can use them for its field ranges.
  - `class KioskPanel { const KioskPanel({required this.days, required this.open}); final int days; final bool open; Map<String, Object?> toJson(); }`, with value equality.
  - `class KioskModulePlacement { const KioskModulePlacement({required this.id, required this.side, required this.share, this.raw}); final String id; final PanelSide side; final int share; final Map<String, Object?>? raw; KioskModule? get module; Map<String, Object?> toJson(); }`, with value equality.
  - `class KioskPanels`, with value equality, so `ref.watch(settingsProvider.select((s) => s?.kioskPanels))` rebuilds only on a real change:
    - `const KioskPanels({required this.left, required this.right, required this.modules})` and `static const defaults`
    - `factory KioskPanels.fromJson(Object? json)` and `Map<String, Object?> toJson()`
    - `KioskPanel panel(PanelSide side)` throws `ArgumentError` for off
    - `List<KioskModulePlacement> modulesOn(PanelSide side)`, `PanelSide sideOf(KioskModule m)`, `int shareOf(KioskModule m)`
    - `KioskPanels withSide(KioskModule m, PanelSide side)`, `KioskPanels withShare(KioskModule m, int share)`, `KioskPanels moved(KioskModule m, int by)`, `KioskPanels withPanel(PanelSide side, {int? days, bool? open})`
  - `({double left, double right}) kioskPanelWidths(double screenWidth, {required double rulerWidth, required int visibleDays, int? left, int? right})`.
  - `bool kioskPanelsExclusive({required int visibleDays, required bool hasLeft, required bool hasRight})`.
  - `KioskPanels kioskPanelsFromLegacy({required bool panelEnabled, required bool drawerOpen, required int drawerColumns, required String noticesMode, required int noticesShare, required bool showMatches, required bool liveMode, required bool dutyDrawer, required int dutyShare})`.
  - In `lib/domain/models.dart`:
    - `ScheduleSettings.kioskPanels`: `final KioskPanels kioskPanels`, default `KioskPanels.defaults`, read by `fromJson` as `KioskPanels.fromJson(json['kiosk_panels'])`.
    - `ScheduleSettings.kioskNoticesHeader`: `final bool kioskNoticesHeader`, default `true`, read by `fromJson` as `json['kiosk_notices_header'] as bool? ?? true`.
    - `models.dart` imports `kiosk_layout.dart` but does **not** re-export it. Files that use `KioskModule` or `PanelSide` import `../../domain/kiosk_layout.dart` themselves. An export would make those direct imports `unnecessary_import`, and `flutter analyze` would fail.

- [ ] **Step 1: Write the failing unit test**

Create `test/domain/kiosk_layout_test.dart`:

```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/kiosk_layout.dart';

void main() {
  /// Every module as `id:side:share`, in the enum's order — one readable
  /// line per layout.
  String placed(KioskPanels p) => [
    for (final m in KioskModule.values)
      '${m.name}:${p.sideOf(m).name}:${p.shareOf(m)}',
  ].join(' ');

  /// The modules of [side] as `id:share`, in their order.
  String on(KioskPanels p, PanelSide side) =>
      [for (final m in p.modulesOn(side)) '${m.id}:${m.share}'].join(' ');

  group('the ids', () {
    test('the enum names are the JSON ids and sides', () {
      expect([for (final m in KioskModule.values) m.name], [
        'duty',
        'notices',
        'matches',
        'guide',
        'week',
      ]);
      expect([for (final s in PanelSide.values) s.name], [
        'off',
        'left',
        'right',
      ]);
    });

    test('every module has its default share', () {
      expect(
        [for (final m in KioskModule.values) kioskModuleDefaultShare(m)],
        [30, 40, 60, 45, 55],
      );
    });
  });

  group('KioskPanels.defaults', () {
    test('is the spec\'s default layout', () {
      expect(KioskPanels.defaults.toJson(), {
        'left': {'days': 2, 'open': false},
        'right': {'days': 2, 'open': false},
        'modules': [
          {'id': 'duty', 'side': 'off', 'share': 30},
          {'id': 'notices', 'side': 'right', 'share': 40},
          {'id': 'matches', 'side': 'right', 'share': 60},
          {'id': 'guide', 'side': 'off', 'share': 45},
          {'id': 'week', 'side': 'off', 'share': 55},
        ],
      });
      expect(on(KioskPanels.defaults, PanelSide.right), 'notices:40 matches:60');
      expect(on(KioskPanels.defaults, PanelSide.left), '');
    });
  });

  group('KioskPanels.fromJson', () {
    const full = {
      'left': {'days': 3, 'open': true},
      'right': {'days': 1, 'open': false},
      'modules': [
        {'id': 'guide', 'side': 'left', 'share': 45},
        {'id': 'week', 'side': 'left', 'share': 55},
        {'id': 'duty', 'side': 'right', 'share': 30},
        {'id': 'notices', 'side': 'right', 'share': 25},
        {'id': 'matches', 'side': 'off', 'share': 60},
      ],
    };

    test('reads a whole layout and writes it back the same', () {
      final p = KioskPanels.fromJson(full);
      expect(p.left, const KioskPanel(days: 3, open: true));
      expect(p.right, const KioskPanel(days: 1, open: false));
      expect(on(p, PanelSide.left), 'guide:45 week:55');
      expect(on(p, PanelSide.right), 'duty:30 notices:25');
      expect(p.sideOf(KioskModule.matches), PanelSide.off);
      expect(p.toJson(), full);
      // Through a JSON string and back, as the row travels.
      expect(KioskPanels.fromJson(jsonDecode(jsonEncode(p.toJson()))), p);
    });

    test('nothing usable reads as the defaults', () {
      for (final json in <Object?>[null, 'x', 3, const <String, Object?>{}]) {
        expect(KioskPanels.fromJson(json), KioskPanels.defaults,
            reason: '$json');
      }
      // A row from before 0077: no modules list → the default modules,
      // the panels as far as they are there.
      final p = KioskPanels.fromJson({
        'right': {'days': 4, 'open': true},
        'modules': {'id': 'duty'},
      });
      expect(p.right, const KioskPanel(days: 4, open: true));
      expect(p.left, const KioskPanel(days: 2, open: false));
      expect(p.modules, KioskPanels.defaults.modules);
    });

    test('a module the list lacks is added at its end, off, with its '
        'default share', () {
      final p = KioskPanels.fromJson({
        'left': {'days': 2, 'open': false},
        'right': {'days': 2, 'open': false},
        'modules': [
          {'id': 'matches', 'side': 'right', 'share': 70},
        ],
      });
      expect(p.toJson()['modules'], [
        {'id': 'matches', 'side': 'right', 'share': 70},
        {'id': 'duty', 'side': 'off', 'share': 30},
        {'id': 'notices', 'side': 'off', 'share': 40},
        {'id': 'guide', 'side': 'off', 'share': 45},
        {'id': 'week', 'side': 'off', 'share': 55},
      ]);
      // An empty list: every module off.
      final none = KioskPanels.fromJson({'modules': <Object?>[]});
      expect(on(none, PanelSide.left), '');
      expect(on(none, PanelSide.right), '');
      expect(none.modules, hasLength(5));
    });

    test('an id this build does not know is kept and written back '
        'unchanged — and left out of the panels', () {
      const radar = {
        'id': 'radar',
        'side': 'left',
        'share': 20,
        'colour': 'red',
      };
      final p = KioskPanels.fromJson({
        'left': {'days': 2, 'open': false},
        'right': {'days': 2, 'open': false},
        'modules': [
          {'id': 'guide', 'side': 'left', 'share': 45},
          radar,
          {'id': 'week', 'side': 'left', 'share': 55},
        ],
      });
      final unknown = p.modules[1];
      expect(unknown.id, 'radar');
      expect(unknown.module, isNull);
      expect(unknown.raw, radar);
      expect(on(p, PanelSide.left), 'guide:45 week:55');
      expect((p.toJson()['modules'] as List)[1], radar);
      // The admin's edits keep it where it was, as it was.
      final edited = p
          .withSide(KioskModule.duty, PanelSide.left)
          .withShare(KioskModule.guide, 60)
          .moved(KioskModule.week, -1)
          .withPanel(PanelSide.left, days: 3);
      expect(edited.modules[1].id, 'radar');
      expect((edited.toJson()['modules'] as List)[1], radar);
      expect(on(edited, PanelSide.left), 'week:55 guide:60 duty:30');
    });

    test('an id\'s second entry, an entry without an id and one that is no '
        'object are skipped', () {
      final p = KioskPanels.fromJson({
        'modules': [
          {'id': 'notices', 'side': 'left', 'share': 30},
          {'id': 'notices', 'side': 'right', 'share': 70},
          {'side': 'right', 'share': 50},
          {'id': '', 'side': 'right', 'share': 50},
          {'id': 7, 'side': 'right', 'share': 50},
          'matches',
          null,
        ],
      });
      expect(p.sideOf(KioskModule.notices), PanelSide.left);
      expect(p.shareOf(KioskModule.notices), 30);
      expect(p.modules.where((m) => m.id == 'notices'), hasLength(1));
      expect(p.modules, hasLength(5));
      expect(p.sideOf(KioskModule.matches), PanelSide.off);
    });

    test('a bad value falls back on its own', () {
      Map<String, Object?> layout(Object? days, Object? open, Object? side,
              Object? share) =>
          {
            'left': {'days': days, 'open': open},
            'right': {'days': 5, 'open': true},
            'modules': [
              {'id': 'week', 'side': side, 'share': share},
            ],
          };
      for (final (days, read) in <(Object?, int)>[
        (0, 2),
        (14, 2),
        (2.5, 2),
        ('3', 2),
        (null, 2),
        (1, 1),
        (13, 13),
        // A whole JSON number written as 3.0 is 3 (as the check sees it).
        (3.0, 3),
      ]) {
        expect(
          KioskPanels.fromJson(layout(days, false, 'left', 50)).left.days,
          read,
          reason: 'days $days',
        );
      }
      expect(KioskPanels.fromJson(layout(2, 'true', 'left', 50)).left.open,
          isFalse);
      expect(KioskPanels.fromJson(layout(2, true, 'left', 50)).left.open,
          isTrue);
      expect(
        KioskPanels.fromJson(layout(2, false, 'top', 50))
            .sideOf(KioskModule.week),
        PanelSide.off,
      );
      expect(
        KioskPanels.fromJson(layout(2, false, null, 50))
            .sideOf(KioskModule.week),
        PanelSide.off,
      );
      for (final (share, read) in <(Object?, int)>[
        (4, 55),
        (96, 55),
        ('50', 55),
        (50.5, 55),
        (null, 55),
        (5, 5),
        (95, 95),
      ]) {
        expect(
          KioskPanels.fromJson(layout(2, false, 'left', share))
              .shareOf(KioskModule.week),
          read,
          reason: 'share $share',
        );
      }
      // The right panel is untouched by the left's bad values.
      expect(KioskPanels.fromJson(layout(0, 'x', 'top', 4)).right,
          const KioskPanel(days: 5, open: true));
    });
  });

  group('reading the layout', () {
    test('panel() of off is an error', () {
      expect(KioskPanels.defaults.panel(PanelSide.left),
          const KioskPanel(days: 2, open: false));
      expect(() => KioskPanels.defaults.panel(PanelSide.off),
          throwsArgumentError);
    });

    test('sideOf and shareOf of a module a hand-built layout lacks: off, '
        'its default share', () {
      const bare = KioskPanels(
        left: KioskPanel(days: 2, open: false),
        right: KioskPanel(days: 2, open: false),
        modules: [],
      );
      expect(bare.sideOf(KioskModule.week), PanelSide.off);
      expect(bare.shareOf(KioskModule.week), 55);
      expect(
        on(bare.withSide(KioskModule.week, PanelSide.left), PanelSide.left),
        'week:55',
      );
    });
  });

  group('the admin\'s edits', () {
    test('withSide keeps the module\'s place in the order', () {
      final p = KioskPanels.defaults.withSide(KioskModule.duty, PanelSide.right);
      // Duty stood first, so it comes first in the right panel.
      expect(on(p, PanelSide.right), 'duty:30 notices:40 matches:60');
      final q = p
          .withSide(KioskModule.notices, PanelSide.left)
          .withSide(KioskModule.guide, PanelSide.left);
      expect(on(q, PanelSide.left), 'notices:40 guide:45');
      expect(on(q, PanelSide.right), 'duty:30 matches:60');
      expect(q.withSide(KioskModule.duty, PanelSide.off).sideOf(KioskModule.duty),
          PanelSide.off);
      // The original is untouched.
      expect(KioskPanels.defaults.sideOf(KioskModule.duty), PanelSide.off);
    });

    test('withShare holds the share to 5–95', () {
      final p = KioskPanels.defaults;
      expect(p.withShare(KioskModule.notices, 25).shareOf(KioskModule.notices),
          25);
      expect(p.withShare(KioskModule.notices, 2).shareOf(KioskModule.notices),
          5);
      expect(p.withShare(KioskModule.notices, 120).shareOf(KioskModule.notices),
          95);
    });

    test('moved steps among the modules of its own panel only', () {
      final p = KioskPanels.fromJson({
        'modules': [
          {'id': 'duty', 'side': 'right', 'share': 30},
          {'id': 'guide', 'side': 'left', 'share': 45},
          {'id': 'notices', 'side': 'right', 'share': 40},
          {'id': 'week', 'side': 'off', 'share': 55},
          {'id': 'matches', 'side': 'right', 'share': 60},
        ],
      });
      expect(on(p.moved(KioskModule.matches, -1), PanelSide.right),
          'duty:30 matches:60 notices:40');
      expect(on(p.moved(KioskModule.matches, -2), PanelSide.right),
          'matches:60 duty:30 notices:40');
      expect(on(p.moved(KioskModule.duty, 1), PanelSide.right),
          'notices:40 duty:30 matches:60');
      // Past the ends it stops there.
      expect(p.moved(KioskModule.duty, -1), p);
      expect(on(p.moved(KioskModule.duty, 9), PanelSide.right),
          'notices:40 matches:60 duty:30');
      // The left panel's guide and the week off keep their places.
      final moved = p.moved(KioskModule.matches, -2);
      expect([for (final m in moved.modules) m.id],
          ['matches', 'guide', 'duty', 'week', 'notices']);
      // Alone in its panel, or off: nothing moves.
      expect(p.moved(KioskModule.guide, 1), p);
      expect(p.moved(KioskModule.week, -1), p);
      expect(p.moved(KioskModule.notices, 0), p);
    });

    test('withPanel changes the days (held to 1–13) and the resting state of '
        'one panel', () {
      final p = KioskPanels.defaults
          .withPanel(PanelSide.left, days: 4)
          .withPanel(PanelSide.right, open: true);
      expect(p.left, const KioskPanel(days: 4, open: false));
      expect(p.right, const KioskPanel(days: 2, open: true));
      expect(p.withPanel(PanelSide.left, days: 0).left.days, 1);
      expect(p.withPanel(PanelSide.left, days: 20).left.days, 13);
      expect(p.modules, KioskPanels.defaults.modules);
      expect(() => p.withPanel(PanelSide.off, days: 2), throwsArgumentError);
    });

    test('every edit PATCHes as a whole layout the check accepts', () {
      final p = KioskPanels.defaults
          .withSide(KioskModule.guide, PanelSide.left)
          .withSide(KioskModule.week, PanelSide.left)
          .withShare(KioskModule.week, 70)
          .moved(KioskModule.week, -1)
          .withPanel(PanelSide.left, days: 3, open: true);
      expect(p.toJson(), {
        'left': {'days': 3, 'open': true},
        'right': {'days': 2, 'open': false},
        'modules': [
          {'id': 'duty', 'side': 'off', 'share': 30},
          {'id': 'notices', 'side': 'right', 'share': 40},
          {'id': 'matches', 'side': 'right', 'share': 60},
          {'id': 'week', 'side': 'left', 'share': 70},
          {'id': 'guide', 'side': 'left', 'share': 45},
        ],
      });
      expect(KioskPanels.fromJson(p.toJson()), p);
    });
  });

  group('kioskPanelWidths', () {
    // 1920 px, the 46 px hour ruler, 7 days: a day column is 1874 / 7.
    const col7 = (1920 - 46) / 7;
    ({double left, double right}) widths({
      int visibleDays = 7,
      int? left,
      int? right,
    }) => kioskPanelWidths(
      1920,
      rulerWidth: 46,
      visibleDays: visibleDays,
      left: left,
      right: right,
    );

    test('a side with nothing to show takes nothing', () {
      expect(widths(), (left: 0.0, right: 0.0));
      expect(widths(left: 2), (left: 2 * col7, right: 0.0));
      expect(widths(right: 3), (left: 0.0, right: 3 * col7));
      // A converted drawer of 6 of 7 days keeps its 6 beside an empty left.
      expect(widths(right: 6), (left: 0.0, right: 6 * col7));
    });

    test('one panel gets 1 to visibleDays − 1 columns', () {
      expect(widths(right: 0), (left: 0.0, right: 1 * col7));
      expect(widths(right: 13), (left: 0.0, right: 6 * col7));
      expect(widths(left: -2), (left: 1 * col7, right: 0.0));
    });

    test('both together get at most visibleDays − 1, the left giving way '
        'first', () {
      expect(widths(left: 2, right: 2), (left: 2 * col7, right: 2 * col7));
      expect(widths(left: 4, right: 4), (left: 2 * col7, right: 4 * col7));
      expect(widths(left: 3, right: 6), (left: 1 * col7, right: 5 * col7));
      expect(widths(left: 13, right: 13), (left: 1 * col7, right: 5 * col7));
      const col3 = (1920 - 46) / 3;
      expect(widths(visibleDays: 3, left: 2, right: 2),
          (left: 1 * col3, right: 1 * col3));
    });

    test('two days on the screen: one column each, and only one open', () {
      const col2 = (1920 - 46) / 2;
      expect(widths(visibleDays: 2, left: 3, right: 3),
          (left: 1 * col2, right: 1 * col2));
      expect(widths(visibleDays: 2, right: 3), (left: 0.0, right: 1 * col2));
      // Below the column's check (2–14) it reads as 2.
      expect(widths(visibleDays: 1, left: 1), (left: 1 * col2, right: 0.0));
      expect(
        kioskPanelsExclusive(visibleDays: 2, hasLeft: true, hasRight: true),
        isTrue,
      );
      expect(
        kioskPanelsExclusive(visibleDays: 3, hasLeft: true, hasRight: true),
        isFalse,
      );
      expect(
        kioskPanelsExclusive(visibleDays: 2, hasLeft: false, hasRight: true),
        isFalse,
      );
      expect(
        kioskPanelsExclusive(visibleDays: 1, hasLeft: true, hasRight: true),
        isTrue,
      );
    });
  });

  group('kioskPanelsFromLegacy (0077\'s conversion, mirrored)', () {
    KioskPanels legacy({
      bool panelEnabled = true,
      bool drawerOpen = false,
      int drawerColumns = 2,
      String noticesMode = 'both',
      int noticesShare = 40,
      bool showMatches = true,
      bool liveMode = true,
      bool dutyDrawer = false,
      int dutyShare = 30,
    }) => kioskPanelsFromLegacy(
      panelEnabled: panelEnabled,
      drawerOpen: drawerOpen,
      drawerColumns: drawerColumns,
      noticesMode: noticesMode,
      noticesShare: noticesShare,
      showMatches: showMatches,
      liveMode: liveMode,
      dutyDrawer: dutyDrawer,
      dutyShare: dutyShare,
    );

    test('the old defaults become the new defaults', () {
      expect(legacy(), KioskPanels.defaults);
    });

    test('the drawer becomes the right panel; the left is two closed days',
        () {
      final p = legacy(drawerColumns: 5, drawerOpen: true);
      expect(p.right, const KioskPanel(days: 5, open: true));
      expect(p.left, const KioskPanel(days: 2, open: false));
      // Off, the panel keeps its geometry — and nothing goes into it.
      final off = legacy(
        panelEnabled: false,
        drawerColumns: 3,
        drawerOpen: true,
        dutyDrawer: true,
      );
      expect(off.right, const KioskPanel(days: 3, open: true));
      expect(placed(off),
          'duty:off:30 notices:off:40 matches:off:60 guide:off:45 week:off:55');
    });

    test('duty, notices and matches: d, round((100 − d) · n / 100), the rest '
        '— each held to 5–95', () {
      for (final (d, n, shares) in [
        (30, 40, 'duty:right:30 notices:right:28 matches:right:42'),
        // 1 → 5; the rest is counted from the 1: 100 − 90 − 1.
        (90, 10, 'duty:right:90 notices:right:5 matches:right:9'),
        (90, 90, 'duty:right:90 notices:right:9 matches:right:5'),
        (60, 10, 'duty:right:60 notices:right:5 matches:right:36'),
        // 4.5 rounds half away from zero to 5 (numeric, not float8's 4).
        (55, 10, 'duty:right:55 notices:right:5 matches:right:40'),
      ]) {
        expect(
          placed(legacy(dutyDrawer: true, dutyShare: d, noticesShare: n)),
          '$shares guide:off:45 week:off:55',
          reason: '($d, $n)',
        );
      }
      // In the old fixed order: duty on top.
      expect(
        on(legacy(dutyDrawer: true), PanelSide.right),
        'duty:30 notices:28 matches:42',
      );
    });

    test('duty with one other: d and 100 − d', () {
      // Only the matches: notices in the header alone.
      expect(
        placed(legacy(dutyDrawer: true, noticesMode: 'header')),
        'duty:right:30 notices:off:40 matches:right:70 guide:off:45 '
        'week:off:55',
      );
      // Only the notices: no list and no live mode.
      expect(
        placed(legacy(
          dutyDrawer: true,
          dutyShare: 60,
          showMatches: false,
          liveMode: false,
        )),
        'duty:right:60 notices:right:40 matches:off:60 guide:off:45 '
        'week:off:55',
      );
    });

    test('no duty: notices n, matches 100 − n', () {
      expect(
        placed(legacy(noticesShare: 25)),
        'duty:off:30 notices:right:25 matches:right:75 guide:off:45 '
        'week:off:55',
      );
      expect(
        placed(legacy(noticesMode: 'drawer', noticesShare: 90)),
        'duty:off:30 notices:right:90 matches:right:10 guide:off:45 '
        'week:off:55',
      );
    });

    test('the list off with live mode on keeps the matches (the match being '
        'played took the drawer); with live mode off they go', () {
      expect(
        placed(legacy(showMatches: false, liveMode: true)),
        'duty:off:30 notices:right:40 matches:right:60 guide:off:45 '
        'week:off:55',
      );
      expect(
        legacy(showMatches: false, liveMode: false)
            .sideOf(KioskModule.matches),
        PanelSide.off,
      );
    });

    test('the notices go right only from drawer or both', () {
      for (final (mode, side) in [
        ('off', PanelSide.off),
        ('header', PanelSide.off),
        ('drawer', PanelSide.right),
        ('both', PanelSide.right),
      ]) {
        expect(legacy(noticesMode: mode).sideOf(KioskModule.notices), side,
            reason: mode);
      }
    });

    test('a module alone fills its panel; its share follows the same rules',
        () {
      expect(
        placed(legacy(
          dutyDrawer: true,
          dutyShare: 70,
          noticesMode: 'header',
          showMatches: false,
          liveMode: false,
        )),
        'duty:right:70 notices:off:40 matches:off:60 guide:off:45 '
        'week:off:55',
      );
      expect(
        placed(legacy(noticesMode: 'off', noticesShare: 30)),
        'duty:off:30 notices:off:40 matches:right:70 guide:off:45 '
        'week:off:55',
      );
      expect(
        placed(legacy(showMatches: false, liveMode: false, noticesShare: 30)),
        'duty:off:30 notices:right:30 matches:off:60 guide:off:45 '
        'week:off:55',
      );
    });
  });
}
```

- [ ] **Step 2: Run it, expect FAIL**

Run: `cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/domain/kiosk_layout_test.dart`

Expected: FAIL at compile time, with `Error: Error when reading 'lib/domain/kiosk_layout.dart': No such file or directory` and `'KioskPanels' isn't a type.`

- [ ] **Step 3: Implement the model**

Create `lib/domain/kiosk_layout.dart`:

```dart
/// The kiosk's two panels, the pure half (0077, `schedule_settings.
/// kiosk_panels`): how many day columns each panel covers and whether it
/// rests open, and which module goes into which panel — with its share of
/// the panel's height and its place in the order. Správa → Kiosk edits it,
/// the kiosk lays it out. Pure Dart, unit-tested.
library;

import 'dart:convert' show jsonEncode;

/// A module of the kiosk's panels. The name is its id in `kiosk_panels`
/// — do not rename one.
enum KioskModule { duty, notices, matches, guide, week }

/// Where a module goes: nowhere, the left panel or the right one. The name
/// is its `side` in `kiosk_panels` — do not rename one.
enum PanelSide { off, left, right }

/// The share of its panel's height a module starts with — also what a
/// module gets back when the stored layout does not have it yet (0077's
/// default layout says the same).
int kioskModuleDefaultShare(KioskModule m) => switch (m) {
  KioskModule.duty => 30,
  KioskModule.notices => 40,
  KioskModule.matches => 60,
  KioskModule.guide => 45,
  KioskModule.week => 55,
};

/// The bounds `kiosk_panels_valid` (0077) holds a panel's width and a
/// module's share to.
const kioskPanelMinDays = 1;
const kioskPanelMaxDays = 13;
const kioskModuleMinShare = 5;
const kioskModuleMaxShare = 95;

final _modulesById = {for (final m in KioskModule.values) m.name: m};

int _clampInt(int value, int min, int max) =>
    value < min ? min : (value > max ? max : value);

/// A whole JSON number (`2` or `2.0`), else null — the check's test
/// `v::numeric = trunc(v::numeric)`.
int? _whole(Object? v) =>
    v is num && v.isFinite && v == v.truncate() ? v.toInt() : null;

/// One panel: how many of the board's day columns it covers when open, and
/// whether it is open when nobody has touched the kiosk for a while.
class KioskPanel {
  const KioskPanel({required this.days, required this.open});

  final int days;
  final bool open;

  static const _fallback = KioskPanel(days: 2, open: false);

  /// Each field on its own: a bad or missing one is the default's.
  static KioskPanel _fromJson(Object? json) {
    if (json is! Map<String, Object?>) return _fallback;
    final days = _whole(json['days']);
    final open = json['open'];
    return KioskPanel(
      days: days != null && days >= kioskPanelMinDays &&
              days <= kioskPanelMaxDays
          ? days
          : _fallback.days,
      open: open is bool ? open : _fallback.open,
    );
  }

  Map<String, Object?> toJson() => {'days': days, 'open': open};

  @override
  bool operator ==(Object other) =>
      other is KioskPanel && other.days == days && other.open == open;

  @override
  int get hashCode => Object.hash(days, open);

  @override
  String toString() => 'KioskPanel($days, open: $open)';
}

/// One module's entry in the layout: its panel and its share of that
/// panel's height (a flex weight — the shares of a panel need not add up
/// to 100, they are spread over its whole height).
class KioskModulePlacement {
  const KioskModulePlacement({
    required this.id,
    required this.side,
    required this.share,
    this.raw,
  });

  /// The JSON id — a [KioskModule]'s name, or a module a newer app knows.
  final String id;
  final PanelSide side;

  /// 5–95.
  final int share;

  /// The entry as read, for an id this build does not know: written back
  /// unchanged, so an older admin app never drops a newer module.
  final Map<String, Object?>? raw;

  /// Null for an id this build does not know.
  KioskModule? get module => _modulesById[id];

  KioskModulePlacement _with({PanelSide? side, int? share}) =>
      KioskModulePlacement(
        id: id,
        side: side ?? this.side,
        share: share ?? this.share,
        raw: raw,
      );

  Map<String, Object?> toJson() =>
      raw ?? {'id': id, 'side': side.name, 'share': share};

  @override
  bool operator ==(Object other) =>
      other is KioskModulePlacement &&
      other.id == id &&
      other.side == side &&
      other.share == share &&
      jsonEncode(other.raw) == jsonEncode(raw);

  @override
  int get hashCode => Object.hash(id, side, share);

  @override
  String toString() => '$id:${side.name}:$share';
}

/// The whole layout: both panels and every module's place. Immutable; the
/// admin's edits return a new one, which is PATCHed whole.
class KioskPanels {
  const KioskPanels({
    required this.left,
    required this.right,
    required this.modules,
  });

  final KioskPanel left, right;

  /// In order: a panel stacks its modules top to bottom as listed here.
  final List<KioskModulePlacement> modules;

  /// 0077's column default, letter for letter (a test compares the two):
  /// both panels two days wide and closed, the notices and the matches in
  /// the right one — what the kiosk showed before there were two.
  static const defaults = KioskPanels(
    left: KioskPanel(days: 2, open: false),
    right: KioskPanel(days: 2, open: false),
    modules: [
      KioskModulePlacement(id: 'duty', side: PanelSide.off, share: 30),
      KioskModulePlacement(id: 'notices', side: PanelSide.right, share: 40),
      KioskModulePlacement(id: 'matches', side: PanelSide.right, share: 60),
      KioskModulePlacement(id: 'guide', side: PanelSide.off, share: 45),
      KioskModulePlacement(id: 'week', side: PanelSide.off, share: 55),
    ],
  );

  /// Reads `kiosk_panels`. Bad values fall back field by field: a panel to
  /// two closed days, a side to off, a share to the module's default.
  /// Without a `modules` list at all (a row from before 0077) the modules
  /// are the defaults'. Entries that are no object or have no id, and an
  /// id's second entry, are skipped; an id this build does not know is kept
  /// as it was read; a module the list lacks is added at its end, off, with
  /// its default share.
  factory KioskPanels.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const <String, Object?>{};
    final list = map['modules'];
    if (list is! List) {
      return KioskPanels(
        left: KioskPanel._fromJson(map['left']),
        right: KioskPanel._fromJson(map['right']),
        modules: defaults.modules,
      );
    }
    final seen = <String>{};
    final modules = <KioskModulePlacement>[];
    for (final entry in list) {
      if (entry is! Map<String, Object?>) continue;
      final id = entry['id'];
      if (id is! String || id.isEmpty || !seen.add(id)) continue;
      final module = _modulesById[id];
      final side = PanelSide.values
          .where((s) => s.name == entry['side'])
          .firstOrNull;
      final share = _whole(entry['share']);
      modules.add(
        KioskModulePlacement(
          id: id,
          side: side ?? PanelSide.off,
          share: share != null &&
                  share >= kioskModuleMinShare &&
                  share <= kioskModuleMaxShare
              ? share
              : (module == null ? 50 : kioskModuleDefaultShare(module)),
          raw: module == null ? Map<String, Object?>.unmodifiable(entry) : null,
        ),
      );
    }
    for (final m in KioskModule.values) {
      if (seen.contains(m.name)) continue;
      modules.add(
        KioskModulePlacement(
          id: m.name,
          side: PanelSide.off,
          share: kioskModuleDefaultShare(m),
        ),
      );
    }
    return KioskPanels(
      left: KioskPanel._fromJson(map['left']),
      right: KioskPanel._fromJson(map['right']),
      modules: List.unmodifiable(modules),
    );
  }

  Map<String, Object?> toJson() => {
    'left': left.toJson(),
    'right': right.toJson(),
    'modules': [for (final m in modules) m.toJson()],
  };

  /// The left or the right panel; off is no panel.
  KioskPanel panel(PanelSide side) => switch (side) {
    PanelSide.left => left,
    PanelSide.right => right,
    PanelSide.off => throw ArgumentError.value(side, 'side', 'is no panel'),
  };

  /// The known modules on [side], in order.
  List<KioskModulePlacement> modulesOn(PanelSide side) => [
    for (final m in modules)
      if (m.module != null && m.side == side) m,
  ];

  KioskModulePlacement? _placement(KioskModule m) =>
      modules.where((p) => p.id == m.name).firstOrNull;

  PanelSide sideOf(KioskModule m) => _placement(m)?.side ?? PanelSide.off;

  int shareOf(KioskModule m) =>
      _placement(m)?.share ?? kioskModuleDefaultShare(m);

  KioskPanels _withModules(List<KioskModulePlacement> next) =>
      KioskPanels(left: left, right: right, modules: List.unmodifiable(next));

  KioskPanels _change(
    KioskModule m,
    KioskModulePlacement Function(KioskModulePlacement p) change,
  ) {
    final i = modules.indexWhere((p) => p.id == m.name);
    final next = [...modules];
    if (i < 0) {
      next.add(
        change(
          KioskModulePlacement(
            id: m.name,
            side: PanelSide.off,
            share: kioskModuleDefaultShare(m),
          ),
        ),
      );
    } else {
      next[i] = change(next[i]);
    }
    return _withModules(next);
  }

  /// [m] into the panel [side] (or off). It keeps its place in the order,
  /// so it lands among that panel's modules where it stood before.
  KioskPanels withSide(KioskModule m, PanelSide side) =>
      _change(m, (p) => p._with(side: side));

  /// [m]'s share, held to 5–95.
  KioskPanels withShare(KioskModule m, int share) => _change(
    m,
    (p) => p._with(
      share: _clampInt(share, kioskModuleMinShare, kioskModuleMaxShare),
    ),
  );

  /// [m] [by] places up (negative) or down among the modules of its own
  /// panel, stopping at the first and the last; the modules elsewhere —
  /// in the other panel, off, unknown — keep their places. A module off
  /// does not move.
  KioskPanels moved(KioskModule m, int by) {
    final side = sideOf(m);
    if (side == PanelSide.off || by == 0) return this;
    final slots = [
      for (var i = 0; i < modules.length; i++)
        if (modules[i].module != null && modules[i].side == side) i,
    ];
    final from = slots.indexWhere((i) => modules[i].id == m.name);
    if (from < 0) return this;
    final to = _clampInt(from + by, 0, slots.length - 1);
    if (to == from) return this;
    final peers = [for (final i in slots) modules[i]];
    peers.insert(to, peers.removeAt(from));
    final next = [...modules];
    for (var k = 0; k < slots.length; k++) {
      next[slots[k]] = peers[k];
    }
    return _withModules(next);
  }

  /// The panel [side] with [days] (held to 1–13) and/or [open] changed.
  KioskPanels withPanel(PanelSide side, {int? days, bool? open}) {
    final old = panel(side);
    final next = KioskPanel(
      days: days == null
          ? old.days
          : _clampInt(days, kioskPanelMinDays, kioskPanelMaxDays),
      open: open ?? old.open,
    );
    return side == PanelSide.left
        ? KioskPanels(left: next, right: right, modules: modules)
        : KioskPanels(left: left, right: next, modules: modules);
  }

  @override
  bool operator ==(Object other) {
    if (other is! KioskPanels ||
        other.left != left ||
        other.right != right ||
        other.modules.length != modules.length) {
      return false;
    }
    for (var i = 0; i < modules.length; i++) {
      if (other.modules[i] != modules[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(left, right, Object.hashAll(modules));

  @override
  String toString() => 'KioskPanels(left: $left, right: $right, $modules)';
}

/// How wide each panel is on a screen [screenWidth] wide, in whole day
/// columns of the board — which sizes [visibleDays] columns on the whole
/// screen after the hour ruler ([rulerWidth]), so open or closed the board
/// shows whole days only. [left] and [right] are the days the admin asked
/// for, null for a side with nothing to show: it takes nothing. A present
/// panel gets 1 to `visibleDays − 1` columns; with both present their sum
/// is held to `visibleDays − 1`, the left giving way first. When even one
/// day each does not fit ([kioskPanelsExclusive]) both get one, and only
/// one of them is open at a time.
({double left, double right}) kioskPanelWidths(
  double screenWidth, {
  required double rulerWidth,
  required int visibleDays,
  int? left,
  int? right,
}) {
  final days = visibleDays < 2 ? 2 : visibleDays;
  final column = (screenWidth - rulerWidth) / days;
  final most = days - 1;
  var l = left == null ? null : _clampInt(left, 1, most);
  var r = right == null ? null : _clampInt(right, 1, most);
  if (l != null && r != null && l + r > most) {
    if (most < 2) {
      l = 1;
      r = 1;
    } else {
      l = most - r < 1 ? 1 : most - r;
      if (l + r > most) r = most - l;
    }
  }
  return (left: (l ?? 0) * column, right: (r ?? 0) * column);
}

/// Whether the two panels cannot be open at once: both have something to
/// show and the board has too few days for one column each beside a day of
/// its own (2 days on the screen) — opening one then closes the other.
bool kioskPanelsExclusive({
  required int visibleDays,
  required bool hasLeft,
  required bool hasRight,
}) =>
    hasLeft && hasRight && (visibleDays < 2 ? 2 : visibleDays) - 1 < 2;

/// 0077's conversion of the old single drawer's columns, in Dart: the
/// migration does this in SQL, and this mirror keeps its arithmetic under
/// unit tests with the tenancy suite's cases. The drawer becomes the right
/// panel (its columns and its resting state), the left one two closed
/// days; duty, notices and matches go right in the old fixed order when the
/// drawer was on and each was in it — the matches also with the list off
/// while live mode was on, as the match being played took the drawer then
/// — guide and week stay off. The shares come from the old nested weights
/// (duty [dutyShare] % of the drawer, notices [noticesShare] % of the
/// rest), rounded half away from zero like numeric `round()`: all three →
/// duty d, notices round((100 − d) · n / 100), matches the rest to 100;
/// duty with one other → d and 100 − d; no duty → notices n, matches
/// 100 − n; a module alone fills its panel whatever its share (duty d,
/// notices n, matches 100 − n, by the same rules). Each share is then held
/// to 5–95 — the matches' rest is counted from the notices before that. A
/// module off keeps its default share.
KioskPanels kioskPanelsFromLegacy({
  required bool panelEnabled,
  required bool drawerOpen,
  required int drawerColumns,
  required String noticesMode,
  required int noticesShare,
  required bool showMatches,
  required bool liveMode,
  required bool dutyDrawer,
  required int dutyShare,
}) {
  final duty = panelEnabled && dutyDrawer;
  final notices =
      panelEnabled && (noticesMode == 'drawer' || noticesMode == 'both');
  final matches = panelEnabled && (showMatches || liveMode);
  final d = dutyShare;
  final n = noticesShare;
  // The notices' part of what the duty leaves — 4.5 is 5, as in numeric.
  final noticesOfRest = ((100 - d) * n / 100).round();
  KioskModulePlacement place(KioskModule m, bool placed, int share) =>
      KioskModulePlacement(
        id: m.name,
        side: placed ? PanelSide.right : PanelSide.off,
        share: placed
            ? _clampInt(share, kioskModuleMinShare, kioskModuleMaxShare)
            : kioskModuleDefaultShare(m),
      );
  return KioskPanels(
    left: const KioskPanel(days: 2, open: false),
    right: KioskPanel(days: drawerColumns, open: drawerOpen),
    modules: List.unmodifiable([
      place(KioskModule.duty, duty, d),
      place(
        KioskModule.notices,
        notices,
        duty ? (matches ? noticesOfRest : 100 - d) : n,
      ),
      place(
        KioskModule.matches,
        matches,
        duty ? (notices ? 100 - d - noticesOfRest : 100 - d) : 100 - n,
      ),
      place(KioskModule.guide, false, 0),
      place(KioskModule.week, false, 0),
    ]),
  );
}
```

- [ ] **Step 4: Run the tests and the analyzer, expect PASS**

Run: `cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/domain/kiosk_layout_test.dart`

Expected: `+28: All tests passed!`

Run: `cd /Users/mvazan/Home/rezervator && flutter analyze lib/domain/kiosk_layout.dart test/domain/kiosk_layout_test.dart`

Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
cd /Users/mvazan/Home/rezervator && git add lib/domain/kiosk_layout.dart test/domain/kiosk_layout_test.dart && git commit -m "feat(kiosk): model rozložení dvou panelů — moduly, šířky, převod starého panelu

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 6: Write the failing `ScheduleSettings` tests**

In `test/domain/models_test.dart`, replace the imports.

Old:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
```

New:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/kiosk_layout.dart';
import 'package:rezervator/domain/models.dart';
```

Then append two tests to the end of group `ScheduleSettings`. They go after the test 'fromJson reads the streams master switch (0072); on when absent', where the group closes and `group('canteen duty (0050)'` begins.

Old:

```dart
      expect(ScheduleSettings.defaults.kioskStreamEnabled, isTrue);
    });
  });
```

New:

```dart
      expect(ScheduleSettings.defaults.kioskStreamEnabled, isTrue);
    });

    test('fromJson reads the kiosk panels and the notices\' header line '
        '(0077); the default layout and on when absent', () {
      const base = {
        'lane_count': 4,
        'training_weekdays': [1, 2, 4],
        'booking_horizon_days': 14,
        'max_active_reservations': 3,
      };
      final read = ScheduleSettings.fromJson({
        ...base,
        'kiosk_panels': {
          'left': {'days': 3, 'open': true},
          'right': {'days': 2, 'open': false},
          'modules': [
            {'id': 'guide', 'side': 'left', 'share': 45},
            {'id': 'week', 'side': 'left', 'share': 55},
            {'id': 'notices', 'side': 'right', 'share': 40},
          ],
        },
        'kiosk_notices_header': false,
      });
      expect(read.kioskPanels.left, const KioskPanel(days: 3, open: true));
      expect(
        [for (final m in read.kioskPanels.modulesOn(PanelSide.left)) m.id],
        ['guide', 'week'],
      );
      expect(read.kioskPanels.sideOf(KioskModule.matches), PanelSide.off);
      expect(read.kioskNoticesHeader, isFalse);
      final old = ScheduleSettings.fromJson(base);
      expect(old.kioskPanels, KioskPanels.defaults);
      expect(old.kioskNoticesHeader, isTrue);
      expect(ScheduleSettings.defaults.kioskPanels, KioskPanels.defaults);
      expect(ScheduleSettings.defaults.kioskNoticesHeader, isTrue);
    });

    test('the default panel layout is the column\'s default, value for value',
        () {
      // Every alley without a saved layout gets 0077's default; the app's
      // fallback must be the same layout.
      final sql = File(
        'supabase/migrations/0077_kiosk_panels.sql',
      ).readAsStringSync();
      final column = RegExp(
        r"kiosk_panels\s+jsonb[^;']*?default\s+'(\{[^']*\})'",
      ).firstMatch(sql)!.group(1)!;
      final decoded = jsonDecode(column);
      expect(decoded, KioskPanels.defaults.toJson());
      expect(KioskPanels.fromJson(decoded), KioskPanels.defaults);
    });
  });
```

- [ ] **Step 7: Run it, expect FAIL**

Run: `cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/domain/models_test.dart`

Expected: FAIL at compile time, with `Error: The getter 'kioskPanels' isn't defined for the type 'ScheduleSettings'.`

- [ ] **Step 8: Add the two fields to `ScheduleSettings`**

`lib/domain/models.dart` needs four edits.

(a) The import, right under `library;`.

Old:

```dart
/// Pure Dart — no Flutter imports — so all logic on top is unit-testable.
library;
```

New:

```dart
/// Pure Dart — no Flutter imports — so all logic on top is unit-testable.
library;

import 'kiosk_layout.dart';
```

(b) The constructor.

Old:

```dart
    this.kioskDutyBandPosition = KioskDutyBandPosition.middle,
    this.kioskPickerMode = KioskPickerMode.letters,
```

New:

```dart
    this.kioskDutyBandPosition = KioskDutyBandPosition.middle,
    this.kioskPanels = KioskPanels.defaults,
    this.kioskNoticesHeader = true,
    this.kioskPickerMode = KioskPickerMode.letters,
```

(c) The fields.

Old:

```dart
  /// Where the band of [kioskDutyBoard] runs in the day headers (0073).
  final KioskDutyBandPosition kioskDutyBandPosition;
```

New:

```dart
  /// Where the band of [kioskDutyBoard] runs in the day headers (0073).
  final KioskDutyBandPosition kioskDutyBandPosition;

  /// The kiosk's two panels (0077, `kiosk_panels`): how many day columns
  /// each covers and whether it rests open, and which module goes into
  /// which panel — with its share of the height, in its order.
  final KioskPanels kioskPanels;

  /// Nástěnka's line in the status bar, one notice's title at a time
  /// (0077, `kiosk_notices_header`) — whether the notices are in a panel
  /// too is [kioskPanels]' business.
  final bool kioskNoticesHeader;
```

(d) `fromJson`.

Old:

```dart
        kioskDutyBandPosition: KioskDutyBandPosition.parse(
          json['kiosk_duty_band_position'] as String?,
        ),
```

New:

```dart
        kioskDutyBandPosition: KioskDutyBandPosition.parse(
          json['kiosk_duty_band_position'] as String?,
        ),
        kioskPanels: KioskPanels.fromJson(json['kiosk_panels']),
        kioskNoticesHeader: json['kiosk_notices_header'] as bool? ?? true,
```

- [ ] **Step 9: Run the tests and the analyzer, expect PASS**

Run: `cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/domain/models_test.dart test/domain/kiosk_layout_test.dart`

Expected: `+90: All tests passed!`

Run: `cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/domain`

Expected: `All tests passed!`

Run: `cd /Users/mvazan/Home/rezervator && flutter analyze`

Expected: `No issues found!`. Nothing reads the new fields yet, and the old ones are untouched.

- [ ] **Step 10: Commit**

```bash
cd /Users/mvazan/Home/rezervator && git add lib/domain/models.dart test/domain/models_test.dart && git commit -m "feat(kiosk): ScheduleSettings čte kiosk_panels a kiosk_notices_header (0077)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---


### Task 3: Kiosk runtime — levý a pravý panel

Two panels beside the board, each a stack of the modules the admin placed on its side (`kiosk_panels`, Task 2's model). Four commits: the card frame made public, the button that knows its side, the two panels themselves, and the comments that still spoke of one drawer.

**Files:**
- Modify: `lib/features/kiosk/kiosk_info_panel.dart` (`_Card` → `KioskCard`; `kioskLiveProvider` gating; `kioskPanelContentProvider` becomes a family over `PanelSide`; `KioskPanelContent` + `KioskPanelEntry`; `KioskPanelView` replaces `KioskDrawer`; `KioskDrawerButton.side`)
- Modify: `lib/features/kiosk/kiosk_shell.dart` (two panels, two buttons, per-side overrides, exclusivity at 2 days, idle reset, picking; the status bar's notices read `kioskNoticesHeader`)
- Modify: `lib/features/kiosk/kiosk_board_view.dart` (doc comment of `columnBasisWidth` only)
- Modify: `lib/domain/models.dart` (doc comment of `KioskCorner.fromHere` only)
- Test: `test/features/kiosk_test.dart` (harness `app(...)` of the group „side drawer (notices, matches, live match)“ gains `KioskPanels? panels`; `KioskDrawer` finders → `KioskPanelView`; two existing tests adjusted; a new test of the button's label; a new group „two panels (0077)“)

**Interfaces:**
- Consumes (Task 2, `lib/domain/kiosk_layout.dart`): `enum KioskModule { duty, notices, matches, guide, week }`, `enum PanelSide { off, left, right }`, `KioskPanels` (`defaults`, `left`/`right` → `KioskPanel{days, open}`, `panel(PanelSide)`, `modulesOn(PanelSide)` → `List<KioskModulePlacement>` of known modules in order, `sideOf(KioskModule)`, `withSide(KioskModule, PanelSide)`, `withPanel(PanelSide, {int? days, bool? open})`), `KioskModulePlacement.module` (`KioskModule?`) and `.share`, `({double left, double right}) kioskPanelWidths(double screenWidth, {required double rulerWidth, required int visibleDays, int? left, int? right})`, `bool kioskPanelsExclusive({required int visibleDays, required bool hasLeft, required bool hasRight})`, `KioskPanels kioskPanelsFromLegacy({required bool panelEnabled, required bool drawerOpen, required int drawerColumns, required String noticesMode, required int noticesShare, required bool showMatches, required bool liveMode, required bool dutyDrawer, required int dutyShare})`; `ScheduleSettings.kioskPanels` (constructor param `kioskPanels`, default `KioskPanels.defaults`) and `ScheduleSettings.kioskNoticesHeader` (constructor param `kioskNoticesHeader`, default true). The old `ScheduleSettings` fields and constructor params still exist (removed in Task 5).
- Produces (`lib/features/kiosk/kiosk_info_panel.dart`):
  - `class KioskCard extends StatelessWidget` — `const KioskCard({super.key, required IconData icon, required String title, required Widget child, bool fill = false, Widget? action})`
  - `class KioskPanelEntry { const KioskPanelEntry(this.module, this.share); final KioskModule module; final int share; }`
  - `class KioskPanelContent { const KioskPanelContent({required this.side, required this.entries, this.notices = const [], this.hasMatches = false, this.live = const [], this.duty}); final PanelSide side; final List<KioskPanelEntry> entries; final List<Message> notices; final bool hasMatches; final List<PrioritySlot> live; final ({KioskDutyEntry? now, List<KioskDutyEntry> next})? duty; }`
  - `final kioskPanelContentProvider = Provider.family<KioskPanelContent?, PanelSide>(...)`
  - `final kioskLiveProvider = Provider<List<PrioritySlot>>(...)` — empty unless `kioskPanels.sideOf(KioskModule.matches) != PanelSide.off && kioskLiveMode`
  - `class KioskPanelView extends ConsumerWidget` — `const KioskPanelView({super.key, required PanelSide side, required double width, required KioskPanelContent content, required bool open, bool hidden = false, required void Function(Message) onOpenNotice, required void Function(PrioritySlot) onOpenMatch, void Function(PrioritySlot)? onPlay, int resetToken = 0, ({Day first, Day last})? boardDays, bool showLive = true, void Function(bool live)? onShowLive})`
  - `KioskDrawerButton({super.key, required PanelSide side, required bool open, required VoidCallback onTap, bool breathe = true})` — Semantics label „Zobrazit levý panel“ / „Skrýt levý panel“ / „Zobrazit pravý panel“ / „Skrýt pravý panel“.
- Left for later tasks (do not do them here):
  - **Task 5:** `kioskDrawerWidthFor` stays defined but unused after this task (Task 5 deletes it). The harness still passes the old fields (`kioskDrawerOpen`, `kioskNoticesMode`, `kioskShowMatches`, `kioskDrawerColumns`, `kioskNoticesShare`, `kioskPanelEnabled`, `kioskDutyDrawer`, `kioskDutyShare`) and maps its old params through `kioskPanelsFromLegacy`; Task 5 removes those fields from the harness.
  - **Task 7** replaces exactly this line of the `card` switch in `KioskPanelView.build`: `      KioskModule.guide => const SizedBox.shrink(),` (the provider already shows `guide` always: `KioskModule.guide => true,`). Opening the guide dialog needs a callback from the shell (`_touchable`), which `KioskPanelView` does not have yet — Task 7 adds it.
  - **Task 12** replaces exactly these two lines: in `kioskPanelContentProvider`, `          KioskModule.week => false,` together with the comment line above it (`          // Nothing to show yet: it takes no room.`), with the rule „the week has lines“ (`weekPlayersProvider`); and in `KioskPanelView.build`'s `card` switch, `      KioskModule.week => const SizedBox.shrink(),` with the `KioskWeekCard` keyed by `ValueKey(resetToken)`.

- [ ] **Step 1: Make the card frame public as `KioskCard`**

In `lib/features/kiosk/kiosk_info_panel.dart`, replace:

```dart
/// A rounded card with a title; [fill] makes its body take all the height
/// the card is given (a slot of the drawer), otherwise it is as tall as its
/// content.
class _Card extends StatelessWidget {
  const _Card({
    required this.icon,
```

with:

```dart
/// A rounded card with a title, the frame of every module of a panel
/// (public for the modules that live in files of their own); [fill] makes
/// its body take all the height the card is given (its slot of the
/// panel), otherwise it is as tall as its content.
class KioskCard extends StatelessWidget {
  const KioskCard({
    super.key,
    required this.icon,
```

Then rename its three uses (each `return _Card(` in `_DutyCard`, `_NoticesCardState` and `_MatchesCardState`) and check that no `_Card` is left:

```bash
cd /Users/mvazan/Home/rezervator
perl -pi -e 's/return _Card\(/return KioskCard(/g' lib/features/kiosk/kiosk_info_panel.dart
grep -nw '_Card' lib/features/kiosk/kiosk_info_panel.dart   # expected: no output
grep -c 'KioskCard(' lib/features/kiosk/kiosk_info_panel.dart      # expected: 4
```

A pure rename: no new test.

- [ ] **Step 2: Analyze and run the kiosk tests**

```bash
cd /Users/mvazan/Home/rezervator && flutter analyze
cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/features/kiosk_test.dart
```

Expected: `No issues found!`; `All tests passed!`.

- [ ] **Step 3: Commit**

```bash
cd /Users/mvazan/Home/rezervator
git add lib/features/kiosk/kiosk_info_panel.dart
git commit -m "$(cat <<'EOF'
refactor(kiosk): rám karty modulu veřejný jako KioskCard

Moduly „Jak začít“ a „Hráči týdne“ budou ve vlastních souborech
a potřebují stejný rám jako Nástěnka, Zápasy a Služba na kantýně.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Write the failing test — the button says which panel it opens or closes**

In `test/features/kiosk_test.dart`, group „side drawer (notices, matches, live match)“, insert this test right after the test „closed by default: only the button shows, tap opens it, tap closes it“, i.e. immediately before the line

```dart
    testWidgets('the admin\'s number of days on the screen sets the column '
```

```dart
    testWidgets('the drawer button says which panel it opens or closes, its '
        'arrow pointing the way the panel goes', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(app(notices: [notice('1', 'Brigáda')]));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Zobrazit pravý panel'), findsOneWidget);
      expect(find.bySemanticsLabel('Zobrazit levý panel'), findsNothing);
      expect(openButton, findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Zobrazit pravý panel'));
      await tester.pumpAndSettle();
      expect(drawerText('Brigáda'), findsOneWidget);
      expect(find.bySemanticsLabel('Skrýt pravý panel'), findsOneWidget);
      expect(closeButton, findsOneWidget);
      await finish(tester);
    });
```

- [ ] **Step 5: Run it — expected FAIL**

```bash
cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/features/kiosk_test.dart --plain-name "the drawer button says which panel it opens or closes"
```

Expected: FAIL — `Expected: exactly one matching candidate` / `Found 0 widgets` for `find.bySemanticsLabel('Zobrazit pravý panel')` (the label is still „Zobrazit panel“).

- [ ] **Step 6: Give `KioskDrawerButton` its side**

In `lib/features/kiosk/kiosk_info_panel.dart`, replace (imports):

```dart
import '../../domain/duties.dart' show KioskDutyEntry;
import '../../domain/kiosk_panel.dart';
```

with:

```dart
import '../../domain/duties.dart' show KioskDutyEntry;
import '../../domain/kiosk_layout.dart';
import '../../domain/kiosk_panel.dart';
```

In `lib/features/kiosk/kiosk_info_panel.dart`, replace (the class head):

```dart
/// The button that opens and closes the drawer: a bare double arrow, gray
/// and half see-through, floating over the board at the drawer's left edge
/// (or the screen's, while it is closed). Every few seconds it breathes once
/// — a soft glow and a little more opacity — so a tablet on the wall shows
/// that there is something to open, without ever moving.
class KioskDrawerButton extends StatefulWidget {
  const KioskDrawerButton({
    super.key,
    required this.open,
    required this.onTap,
    this.breathe = true,
  });

  final bool open;
```

with:

```dart
/// The button that opens and closes a panel: a bare double arrow pointing
/// the way the panel moves, gray and half see-through, floating over the
/// board at the panel's inner edge (the right one at the board's right
/// edge, the left one on the hour ruler — never over today's column).
/// Every few seconds it breathes once — a soft glow and a little more
/// opacity — so a tablet on the wall shows that there is something to
/// open, without ever moving.
class KioskDrawerButton extends StatefulWidget {
  const KioskDrawerButton({
    super.key,
    required this.side,
    required this.open,
    required this.onTap,
    this.breathe = true,
  }) : assert(side != PanelSide.off);

  /// The panel it opens and closes: left or right.
  final PanelSide side;
  final bool open;
```

In `lib/features/kiosk/kiosk_info_panel.dart`, replace (start of `_KioskDrawerButtonState.build`):

```dart
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: widget.open ? 'Skrýt panel' : 'Zobrazit panel',
      child: GestureDetector(
```

with:

```dart
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final left = widget.side == PanelSide.left;
    // The way a tap moves the panel: the right one opens to the left and
    // closes to the right, the left one the other way round.
    final towardsRight = left != widget.open;
    return Semantics(
      // A node of its own: two buttons, each known by its label.
      container: true,
      button: true,
      label:
          '${widget.open ? 'Skrýt' : 'Zobrazit'} '
          '${left ? 'levý' : 'pravý'} panel',
      child: GestureDetector(
```

In `lib/features/kiosk/kiosk_info_panel.dart`, replace (the icon in the same `build`):

```dart
            // Its own layer: a breath repaints the icon, not the board and
            // the drawer under it.
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  // 0 → 1 → 0 over one breath; 0 while the button is still.
                  final glow = math.sin(_controller.value * math.pi);
                  return Icon(
                    widget.open
                        ? Icons.keyboard_double_arrow_right
                        : Icons.keyboard_double_arrow_left,
```

with:

```dart
            // Its own layer: a breath repaints the icon, not the board and
            // the panel under it.
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  // 0 → 1 → 0 over one breath; 0 while the button is still.
                  final glow = math.sin(_controller.value * math.pi);
                  return Icon(
                    towardsRight
                        ? Icons.keyboard_double_arrow_right
                        : Icons.keyboard_double_arrow_left,
```

- [ ] **Step 7: The shell names the right side for its one button**

In `lib/features/kiosk/kiosk_shell.dart`, replace (imports):

```dart
import '../../data/providers.dart';
import '../../domain/kiosk_panel.dart'
    show hasKioskVideo, kioskNotices, kioskStreamLabel;
```

with:

```dart
import '../../data/providers.dart';
import '../../domain/kiosk_layout.dart';
import '../../domain/kiosk_panel.dart'
    show hasKioskVideo, kioskNotices, kioskStreamLabel;
```

In `lib/features/kiosk/kiosk_shell.dart`, replace (in `_boardWithPanel`):

```dart
              child: KioskDrawerButton(
                open: open,
```

with:

```dart
              child: KioskDrawerButton(
                side: PanelSide.right,
                open: open,
```

- [ ] **Step 8: Run — expected PASS**

```bash
cd /Users/mvazan/Home/rezervator && flutter analyze
cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/features/kiosk_test.dart
```

Expected: `No issues found!`; `All tests passed!` (the right panel's arrows are as before, so `openButton`/`closeButton` still find it).

- [ ] **Step 9: Commit**

```bash
cd /Users/mvazan/Home/rezervator
git add lib/features/kiosk/kiosk_info_panel.dart lib/features/kiosk/kiosk_shell.dart test/features/kiosk_test.dart
git commit -m "$(cat <<'EOF'
feat(kiosk): tlačítko panelu ví, na které je straně

Popisek pro čtečku i testy („Zobrazit/Skrýt levý/pravý panel“), šipka
ukazuje, kam se panel pohne. Shell zatím předává pravou stranu.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 10: Harness — the panels' layout, else the old settings converted as 0077 converts them**

In `test/features/kiosk_test.dart`, replace (imports):

```dart
import 'package:rezervator/domain/duties.dart'
    show KioskDutyEntry, dutyRangeLabel;
import 'package:rezervator/domain/models.dart';
```

with:

```dart
import 'package:rezervator/domain/duties.dart'
    show KioskDutyEntry, dutyRangeLabel;
import 'package:rezervator/domain/kiosk_layout.dart';
import 'package:rezervator/domain/models.dart';
```

In `test/features/kiosk_test.dart`, replace (the `app({...})` harness of the „side drawer“ group: its last params and the start of `shown`):

```dart
      List<Reservation> reservations = const [],
      int? maxActiveReservations,
    }) => ProviderScope(
      overrides: [
        settingsProvider.overrideWith((ref) {
          ScheduleSettings shown(bool streamOn) => ScheduleSettings(
            laneCount: settings.laneCount,
            trainingWeekdays: trainingWeekdays ?? settings.trainingWeekdays,
            bookingHorizonDays: settings.bookingHorizonDays,
            maxActiveReservations:
                maxActiveReservations ?? settings.maxActiveReservations,
            kioskDrawerOpen: drawerOpen,
            kioskNoticesMode: switch ((showNotices, headerNotices)) {
              (true, true) => KioskNoticesMode.both,
              (true, false) => KioskNoticesMode.drawer,
              (false, true) => KioskNoticesMode.header,
              (false, false) => KioskNoticesMode.off,
            },
            kioskShowMatches: showMatches,
```

with:

```dart
      List<Reservation> reservations = const [],
      int? maxActiveReservations,
      // Both panels as the admin lays them out (0077); null = the layout
      // the drawer settings above convert to, as 0077 converts them.
      KioskPanels? panels,
    }) => ProviderScope(
      overrides: [
        settingsProvider.overrideWith((ref) {
          ScheduleSettings shown(bool streamOn) => ScheduleSettings(
            laneCount: settings.laneCount,
            trainingWeekdays: trainingWeekdays ?? settings.trainingWeekdays,
            bookingHorizonDays: settings.bookingHorizonDays,
            maxActiveReservations:
                maxActiveReservations ?? settings.maxActiveReservations,
            kioskPanels:
                panels ??
                kioskPanelsFromLegacy(
                  panelEnabled: panelEnabled,
                  drawerOpen: drawerOpen,
                  drawerColumns: drawerColumns,
                  noticesMode: showNotices ? 'drawer' : 'off',
                  noticesShare: share,
                  showMatches: showMatches,
                  liveMode: liveMode,
                  dutyDrawer: dutyDrawer,
                  dutyShare: dutyShare,
                ),
            kioskNoticesHeader: headerNotices,
            kioskDrawerOpen: drawerOpen,
            kioskNoticesMode: switch ((showNotices, headerNotices)) {
              (true, true) => KioskNoticesMode.both,
              (true, false) => KioskNoticesMode.drawer,
              (false, true) => KioskNoticesMode.header,
              (false, false) => KioskNoticesMode.off,
            },
            kioskShowMatches: showMatches,
```

Every other line of the harness stays, the inline `kioskNoticesMode: switch …` argument included (Task 5 deletes it with the other old arguments). The old params (`drawerOpen`, `showNotices`, `showMatches`, `drawerColumns`, `share`, `panelEnabled`, `dutyDrawer`, `dutyShare`, `liveMode`) keep compiling and now reach the kiosk through `kioskPanelsFromLegacy`; `headerNotices` reaches it through `kioskNoticesHeader`, which the status bar reads from Step 16 on (the test with `headerNotices: false` depends on it).

- [ ] **Step 11: The drawer finders look for the panel widget**

```bash
cd /Users/mvazan/Home/rezervator
perl -pi -e 's/\bKioskDrawer\b/KioskPanelView/g' test/features/kiosk_test.dart
grep -nw 'KioskDrawer' test/features/kiosk_test.dart   # expected: no output (KioskDrawerButton is untouched)
```

With the default layout only the right panel exists, so each `find.byType(KioskPanelView)` still finds one widget.

- [ ] **Step 12: Adjust the two tests whose expectation the new layout changes**

„the admin switches the notices and the matches off“ — the conversion keeps `matches` placed while live mode is on (spec, Conversion), so the list-off case also turns live mode off:

In `test/features/kiosk_test.dart`, replace (the second `pumpWidget` of that test):

```dart
      await tester.pumpWidget(
        app(
          notices: [notice('1', 'Brigáda')],
          slots: slots,
          drawerOpen: true,
          showMatches: false,
        ),
      );
```

with:

```dart
      // Live mode off too: on, it keeps the matches in the panel (the match
      // being played takes over the panel that holds them, 0077).
      await tester.pumpWidget(
        app(
          notices: [notice('1', 'Brigáda')],
          slots: slots,
          drawerOpen: true,
          showMatches: false,
          liveMode: false,
        ),
      );
```

„the card takes the admin's share of the drawer…“ (group „canteen duty (0073)“) — one flat stack of three shares instead of the duty over a nested split:

In `test/features/kiosk_test.dart`, replace (its title):

```dart
      testWidgets('the card takes the admin\'s share of the drawer; the '
          'notices and the matches split the rest as before', (tester) async {
```

with:

```dart
      testWidgets('the card takes its share of the panel; the notices and '
          'the matches keep their split of the rest', (tester) async {
```

In `test/features/kiosk_test.dart`, replace (its ratio check; the following „The notices keep their 40 % of what is left“ check stays: 28/70 and 16/40 are both 0.4):

```dart
          expect(matches.bottom, closeTo(drawer.bottom - 12, 0.01));
          final rest = matches.bottom - notices.top;
          expect(
            duty.height / rest,
            closeTo(dutyShare / (100 - dutyShare), 0.001),
          );
```

with:

```dart
          expect(matches.bottom, closeTo(drawer.bottom - 12, 0.01));
          // One stack of three shares (0077): the gaps come off first.
          expect(
            duty.height / (duty.height + notices.height + matches.height),
            closeTo(dutyShare / 100, 0.001),
          );
```

- [ ] **Step 13: Write the failing tests of the two panels**

In `test/features/kiosk_test.dart`, inside the group „side drawer (notices, matches, live match)“, insert this group immediately before the line

```dart
    group('canteen duty (0073)', () {
```

```dart
    group('two panels (0077)', () {
      // The notices left, the matches right: a panel on either side.
      final split = KioskPanels.defaults.withSide(
        KioskModule.notices,
        PanelSide.left,
      );
      // One of seven day columns, on the whole screen.
      const column = (1920 - 46) / 7;
      Finder panelOn(PanelSide side) => find.byWidgetPredicate(
        (w) => w is KioskPanelView && w.side == side,
      );
      Finder onPanel(PanelSide side, String text) =>
          find.descendant(of: panelOn(side), matching: find.text(text));
      Finder cardOn(PanelSide side, String title) => find
          .ancestor(of: onPanel(side, title), matching: find.byType(KioskCard))
          .first;
      double width(WidgetTester tester, PanelSide side) =>
          tester.getSize(panelOn(side)).width;
      // The buttons by what a screen reader says: their arrows alone are
      // the same on both sides, pointing opposite ways.
      Finder button(String label) => find.bySemanticsLabel(label);

      testWidgets('a panel on either side, each with its own button; the '
          'left one slides out of the screen\'s left edge, its content laid '
          'out from its inner edge', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            notices: [notice('1', 'Brigáda')],
            slots: [fed('next', day.addDays(1), 'Příští')],
            panels: split,
          ),
        );
        await tester.pumpAndSettle();
        // Both rest closed, as the admin set them: only the two buttons,
        // each arrow pointing the way its panel opens.
        expect(width(tester, PanelSide.left), 0);
        expect(width(tester, PanelSide.right), 0);
        expect(
          find.descendant(
            of: button('Zobrazit levý panel'),
            matching: find.byIcon(Icons.keyboard_double_arrow_right),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: button('Zobrazit pravý panel'),
            matching: find.byIcon(Icons.keyboard_double_arrow_left),
          ),
          findsOneWidget,
        );

        await tester.tap(button('Zobrazit levý panel'));
        // The frame that starts the slide, then 100 ms of its 250.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        // Mid-slide: the panel grows from the left edge, its card laid out
        // at its full width against the panel's right edge.
        final sliding = tester.getRect(panelOn(PanelSide.left));
        expect(sliding.left, 0);
        expect(sliding.width, inExclusiveRange(0, 2 * column));
        final card = tester.getRect(cardOn(PanelSide.left, 'NÁSTĚNKA'));
        expect(card.right, closeTo(sliding.right - 12, 0.5));
        expect(card.width, closeTo(2 * column - 24, 0.5));
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.left), closeTo(2 * column, 0.5));
        expect(onPanel(PanelSide.left, 'Brigáda'), findsOneWidget);
        // The board moved over, its hour ruler first.
        expect(
          tester.getRect(find.byType(HourRuler)).left,
          closeTo(2 * column, 0.5),
        );
        expect(
          find.descendant(
            of: button('Skrýt levý panel'),
            matching: find.byIcon(Icons.keyboard_double_arrow_left),
          ),
          findsOneWidget,
        );

        // Seven days leave room for both.
        await tester.tap(button('Zobrazit pravý panel'));
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.right), closeTo(2 * column, 0.5));
        expect(width(tester, PanelSide.left), closeTo(2 * column, 0.5));
        expect(onPanel(PanelSide.right, 'ZÁPASY'), findsOneWidget);
        expect(
          find.descendant(
            of: button('Skrýt pravý panel'),
            matching: find.byIcon(Icons.keyboard_double_arrow_right),
          ),
          findsOneWidget,
        );

        await tester.tap(button('Skrýt levý panel'));
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.left), 0);
        expect(width(tester, PanelSide.right), closeTo(2 * column, 0.5));
        await finish(tester);
      });

      testWidgets('the left button sits on the hour ruler, not over today\'s '
          'column: a visitor books today\'s first lane as ever', (
        tester,
      ) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(notices: [notice('1', 'Brigáda')], panels: split),
        );
        await tester.pumpAndSettle();
        final ruler = tester.getRect(find.byType(HourRuler));
        expect(
          tester.getCenter(button('Zobrazit levý panel')).dx,
          closeTo(ruler.center.dx, 0.5),
        );
        final arrow = tester.getRect(
          find.descendant(
            of: button('Zobrazit levý panel'),
            matching: find.byType(Icon),
          ),
        );
        expect(arrow.left, greaterThanOrEqualTo(ruler.left));
        expect(arrow.right, lessThanOrEqualTo(ruler.right));

        await tester.tap(find.text(kioskReserveLabel));
        await tester.pumpAndSettle();
        await tester.tap(find.text('A'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(players.first.displayName));
        await tester.pumpAndSettle();
        // Today's first lane: the board's first ＋, right of the ruler.
        final lane = find.byIcon(Icons.add).first;
        await tester.ensureVisible(lane);
        await tester.pumpAndSettle();
        expect(tester.getRect(lane).left, greaterThan(ruler.right));
        await tester.tap(lane);
        await tester.pumpAndSettle();
        expect(find.text('Rezervovat termín?'), findsOneWidget);
        await finish(tester);
      });

      testWidgets('a match being played takes over the panel holding the '
          'matches — on the left too — and keeps it open', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            notices: [notice('1', 'Brigáda')],
            slots: [fed('m', day, 'Hrají')],
            results: {'m': res('m', 'in_progress', 2, 1)},
            lineups: {'m': lineup},
            // The matches left, the notices right.
            panels: KioskPanels.defaults.withSide(
              KioskModule.matches,
              PanelSide.left,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final liveLeft = find.descendant(
          of: panelOn(PanelSide.left),
          matching: find.byType(MatchScoreboard),
        );
        // Open although it rests closed; the right panel is left alone.
        expect(liveLeft, findsOneWidget);
        expect(width(tester, PanelSide.left), closeTo(2 * column, 0.5));
        expect(width(tester, PanelSide.right), 0);
        expect(button('Zobrazit pravý panel'), findsOneWidget);

        // A visitor may close it; after the idle time it is back.
        await tester.tap(button('Skrýt levý panel'));
        await tester.pumpAndSettle();
        expect(liveLeft, findsNothing);
        await tester.pump(const Duration(seconds: 61));
        await tester.pumpAndSettle();
        expect(liveLeft, findsOneWidget);

        // The list of matches is under it, and leads back to it.
        await tester.tap(find.byTooltip('Všechny zápasy'));
        await tester.pumpAndSettle();
        expect(liveLeft, findsNothing);
        expect(onPanel(PanelSide.left, 'ZÁPASY'), findsOneWidget);
        await tester.tap(find.text('Právě se hraje'));
        await tester.pumpAndSettle();
        expect(liveLeft, findsOneWidget);
        await finish(tester);
      });

      testWidgets('a visitor who picked their name gets the board alone: '
          'both panels and both buttons step aside, and are back as they '
          'were once the pick is cleared', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            notices: [notice('1', 'Brigáda')],
            slots: [fed('next', day.addDays(1), 'Příští')],
            panels: split
                .withPanel(PanelSide.left, open: true)
                .withPanel(PanelSide.right, open: true),
          ),
        );
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.left), closeTo(2 * column, 0.5));
        expect(width(tester, PanelSide.right), closeTo(2 * column, 0.5));

        await tester.tap(find.text(kioskReserveLabel));
        await tester.pumpAndSettle();
        await tester.tap(find.text('A'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(players.first.displayName));
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.left), 0);
        expect(width(tester, PanelSide.right), 0);
        expect(find.byType(KioskDrawerButton), findsNothing);

        await tester.tap(find.byTooltip('Zrušit výběr'));
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.left), closeTo(2 * column, 0.5));
        expect(width(tester, PanelSide.right), closeTo(2 * column, 0.5));
        expect(button('Skrýt levý panel'), findsOneWidget);
        expect(button('Skrýt pravý panel'), findsOneWidget);
        await finish(tester);
      });

      testWidgets('the idle reset puts both panels back as the admin set '
          'them and starts their cards over', (tester) async {
        fullHd(tester);
        // The matches left, resting open; the notices right, closed.
        await tester.pumpWidget(
          app(
            notices: [notice('1', 'Brigáda')],
            slots: [
              fed('b1', Day(2026, 10, 1), 'JedenZpět'),
              fed('cur', Day(2026, 10, 9), 'Tento'),
            ],
            weeksBack: 0,
            weeksAhead: 0,
            panels: KioskPanels.defaults
                .withSide(KioskModule.matches, PanelSide.left)
                .withPanel(PanelSide.left, open: true),
          ),
        );
        await tester.pumpAndSettle();
        Finder inLeft(String t) => find.descendant(
          of: panelOn(PanelSide.left),
          matching: find.textContaining(t),
        );
        // A visitor brings an older week into the list and opens the right
        // panel.
        await tester.drag(
          find.descendant(
            of: panelOn(PanelSide.left),
            matching: find.byType(CustomScrollView),
          ),
          const Offset(0, 200),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Zobrazit předchozí'));
        await tester.pumpAndSettle();
        expect(inLeft('JedenZpět'), findsWidgets);
        await tester.tap(button('Zobrazit pravý panel'));
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.right), closeTo(2 * column, 0.5));

        await tester.pump(const Duration(seconds: 61));
        await tester.pumpAndSettle();
        // The right panel rests closed again; the left one, open all along,
        // starts its list over, without the older week.
        expect(width(tester, PanelSide.right), 0);
        expect(width(tester, PanelSide.left), closeTo(2 * column, 0.5));
        expect(inLeft('Tento'), findsWidgets);
        expect(inLeft('JedenZpět'), findsNothing);

        // Closed by a visitor, the left one reopens after the idle time.
        await tester.tap(button('Skrýt levý panel'));
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.left), 0);
        await tester.pump(const Duration(seconds: 61));
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.left), closeTo(2 * column, 0.5));
        await finish(tester);
      });

      testWidgets('two days on the screen leave room for one panel: opening '
          'one closes the other', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            notices: [notice('1', 'Brigáda')],
            slots: [fed('next', day.addDays(1), 'Příští')],
            visibleDays: 2,
            panels: split
                .withPanel(PanelSide.left, open: true)
                .withPanel(PanelSide.right, open: true),
          ),
        );
        await tester.pumpAndSettle();
        // One day each; both rest open, the right one is.
        const oneDay = (1920 - 46) / 2;
        expect(width(tester, PanelSide.right), closeTo(oneDay, 0.5));
        expect(width(tester, PanelSide.left), 0);

        await tester.tap(button('Zobrazit levý panel'));
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.left), closeTo(oneDay, 0.5));
        expect(width(tester, PanelSide.right), 0);

        await tester.tap(button('Zobrazit pravý panel'));
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.right), closeTo(oneDay, 0.5));
        expect(width(tester, PanelSide.left), 0);
        await finish(tester);
      });
    });
```

- [ ] **Step 14: Run — expected FAIL**

```bash
cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/features/kiosk_test.dart
```

Expected: FAIL to load — `Error: Undefined name 'KioskPanelView'.` (and the getter `side` on it).

- [ ] **Step 15: The panel content per side, the live gate and `KioskPanelView`**

In `lib/features/kiosk/kiosk_info_panel.dart`, replace (the library doc):

```dart
/// The kiosk's side drawer: who serves on the canteen and who comes next
/// (0073, on top), the alley's active notices (they take turns when there
/// are several; a tap reads one in full), the matches of the last and next
/// weeks (a tap on a finished one opens its Zápis, ▶ at one with a video
/// its stream) — and, while a match is
/// being played, that match across the whole drawer in the Souboje view
/// (several live matches take turns too). Display only, like the board:
/// nothing here books or writes. Closed it is gone entirely, leaving only a
/// button floating at the screen's edge. The admin picks what it lists and
/// how it looks (Správa → Kiosk); the shell closes or reopens it to its
/// resting state after a minute without a touch.
library;
```

with:

```dart
/// The kiosk's two side panels (0077), left and right of the board, each a
/// stack of the modules the admin placed in it: who serves on the canteen
/// and who comes next (0073), the alley's active notices (they take turns
/// when there are several; a tap reads one in full), the matches of the
/// last and next weeks (a tap on a finished one opens its Zápis, ▶ at one
/// with a video its stream) — and, while a match is being played, that
/// match across the whole panel holding the matches, in the Souboje view
/// (several live matches take turns too). Display only, like the board:
/// nothing here books or writes. Closed a panel is gone entirely, leaving
/// only a button floating over the board. The admin picks what goes where
/// and how it looks (Správa → Kiosk); the shell closes or reopens both
/// panels to their resting state after a minute without a touch.
library;
```

Then replace everything from the line

```dart
/// The matches being played whose players the site has delivered — empty
```

down to, but not including, the line

```dart
/// The button that opens and closes a panel: a bare double arrow pointing
```

(that is `kioskLiveProvider`, `kioskPanelContentProvider`, `KioskPanelContent` and the whole `KioskDrawer` class) with:

```dart
/// The matches being played whose players the site has delivered — empty
/// with live mode off, or while the matches are in no panel (0077): the
/// match being played takes over the panel that holds them. A match marked
/// as playing but without data is not here ([kioskLiveMatches]).
final kioskLiveProvider = Provider<List<PrioritySlot>>((ref) {
  final settings = ref.watch(settingsProvider).value;
  final panels = settings?.kioskPanels ?? KioskPanels.defaults;
  if (panels.sideOf(KioskModule.matches) == PanelSide.off ||
      !(settings?.kioskLiveMode ?? true)) {
    return const [];
  }
  final slots = ref.watch(prioritySlotsProvider);
  final results = ref.watch(matchResultsProvider).value ?? const {};
  final withData = <String>{};
  for (final s in slots) {
    if (results[s.id]?.status != MatchStatus.inProgress) continue;
    if (ref.watch(matchPlayerResultsProvider(s.id)).value?.isNotEmpty ??
        false) {
      withData.add(s.id);
    }
  }
  return kioskLiveMatches(
    slots: slots,
    results: results,
    withData: withData,
    now: ref.watch(nowProvider).value ?? DateTime.now(),
  );
});

/// What the panel on [side] would show now, from the providers and the
/// admin's layout (0077): the modules placed there that have something to
/// show, in the admin's order, each with its share — null when none has
/// (the shell then draws neither that panel nor its button).
final kioskPanelContentProvider =
    Provider.family<KioskPanelContent?, PanelSide>((ref, side) {
      final settings = ref.watch(settingsProvider).value;
      final placed = (settings?.kioskPanels ?? KioskPanels.defaults)
          .modulesOn(side);
      if (placed.isEmpty) return null;
      bool here(KioskModule module) => placed.any((p) => p.module == module);
      final now = ref.watch(nowProvider).value ?? DateTime.now();
      final live = here(KioskModule.matches)
          ? ref.watch(kioskLiveProvider)
          : const <PrioritySlot>[];
      final notices = here(KioskModule.notices)
          ? kioskNotices(ref.watch(messagesProvider).value ?? const [], now)
          : const <Message>[];
      final hasMatches =
          here(KioskModule.matches) &&
          kioskMatchWindow(
            slots: ref.watch(prioritySlotsProvider),
            today: Day.fromDateTime(now),
            weeksBack: settings?.kioskWeeksBack ?? 2,
            weeksAhead: settings?.kioskWeeksAhead ?? 1,
            showUpcoming: settings?.kioskShowUpcoming ?? true,
          ).matches.isNotEmpty;
      // The canteen duty's plan (0073) is read only with its card here. A
      // plan with nobody now and nobody ahead has nothing to say.
      final plan = here(KioskModule.duty)
          ? ref.watch(kioskDutyPlanProvider)
          : null;
      final duty = plan != null && (plan.now != null || plan.next.isNotEmpty)
          ? plan
          : null;
      final entries = <KioskPanelEntry>[];
      for (final placement in placed) {
        final module = placement.module!;
        final shows = switch (module) {
          KioskModule.duty => duty != null,
          KioskModule.notices => notices.isNotEmpty,
          // The list — or the match being played alone, when the list's
          // weeks hold no match (Sunday evening's, still live on Monday).
          KioskModule.matches => hasMatches || live.isNotEmpty,
          // A fixed text: always something to show.
          KioskModule.guide => true,
          // Nothing to show yet: it takes no room.
          KioskModule.week => false,
        };
        if (shows) entries.add(KioskPanelEntry(module, placement.share));
      }
      if (entries.isEmpty) return null;
      return KioskPanelContent(
        side: side,
        entries: entries,
        notices: notices,
        hasMatches: hasMatches,
        live: live,
        duty: duty,
      );
    });

/// What one panel shows (0077): [entries] are its modules with something
/// to show, top to bottom; the rest is what those modules draw.
class KioskPanelContent {
  const KioskPanelContent({
    required this.side,
    required this.entries,
    this.notices = const [],
    this.hasMatches = false,
    this.live = const [],
    this.duty,
  });

  final PanelSide side;
  final List<KioskPanelEntry> entries;
  final List<Message> notices;

  /// The list of matches has a match in its weeks.
  final bool hasMatches;

  /// Matches being played, with data; non-empty = the panel holding the
  /// matches shows only them. Empty in the other panel.
  final List<PrioritySlot> live;

  /// The canteen duty's plan for its card (0073); null with the card in
  /// another panel or nothing planned.
  final ({KioskDutyEntry? now, List<KioskDutyEntry> next})? duty;
}

/// One module of a panel and its share of the panel's height, in percent
/// (5–95). The shares of a panel are weights: they need not add up to 100.
class KioskPanelEntry {
  const KioskPanelEntry(this.module, this.share);

  final KioskModule module;
  final int share;
}

/// One side panel: its modules stacked top to bottom, each its share of
/// the height with 12 px between them — or, while a match is being played,
/// that match alone in the panel holding the matches.
class KioskPanelView extends ConsumerWidget {
  const KioskPanelView({
    super.key,
    required this.side,
    required this.width,
    required this.content,
    required this.open,
    this.hidden = false,
    required this.onOpenNotice,
    required this.onOpenMatch,
    this.onPlay,
    this.resetToken = 0,
    this.boardDays,
    this.showLive = true,
    this.onShowLive,
  });

  /// Left or right of the board: the panel grows from that edge of the
  /// screen.
  final PanelSide side;

  /// Open, it is this wide: whole day columns of the board
  /// ([kioskPanelWidths], worked out once by the shell for both panels).
  final double width;

  /// False after a visitor switched from the match being played to the
  /// list of matches; the idle reset turns it back.
  final bool showLive;

  /// Between the live view and the list: true = the live match. Null in
  /// the panel without the matches.
  final void Function(bool live)? onShowLive;

  /// Bumped by the shell on every idle reset: the cards that scroll or page
  /// start over.
  final int resetToken;

  /// The days a visitor scrolled the board to, when the list follows it.
  final ({Day first, Day last})? boardDays;

  final KioskPanelContent content;
  final bool open;

  /// Out of the way while a visitor books: shut like a closed panel, yet
  /// an [open] one keeps its contents built behind the scenes — the match
  /// being played keeps asking for its score, its pin and its turn, and is
  /// there as it was once the pick is cleared.
  final bool hidden;
  final void Function(Message notice) onOpenNotice;
  final void Function(PrioritySlot match) onOpenMatch;

  /// ▶ at a match with a video: its stream (0072); null while the admin
  /// has the streams off — no ▶ and no live badge.
  final void Function(PrioritySlot match)? onPlay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final settings = ref.watch(settingsProvider).value;
    final noticeTurn = Duration(
      seconds: settings?.kioskNoticesRotationSeconds ?? 12,
    );
    final liveTurn = Duration(
      seconds: settings?.kioskLiveRotationSeconds ?? 12,
    );
    final entries = content.entries;
    // The notices alone keep their natural height: one short notice is not
    // stretched over the whole panel. With other modules each takes its
    // share.
    final noticesAlone =
        entries.length == 1 && entries.single.module == KioskModule.notices;
    Widget card(KioskModule module) => switch (module) {
      // A new key after every idle reset: scrolled down, the plan starts
      // over at the top.
      KioskModule.duty => _DutyCard(
        key: ValueKey(resetToken),
        plan: content.duty!,
      ),
      KioskModule.notices => _NoticesCard(
        notices: content.notices,
        turn: noticeTurn,
        fill: !noticesAlone,
        onOpen: onOpenNotice,
      ),
      // A new key after every idle reset: the list starts over (its weeks
      // and its scroll) like the rest of the kiosk.
      KioskModule.matches => _MatchesCard(
        key: ValueKey(resetToken),
        onOpen: onOpenMatch,
        onPlay: onPlay,
        boardDays: boardDays,
        // Back to the match being played, when one is.
        onShowLive: content.live.isEmpty || onShowLive == null
            ? null
            : () => onShowLive!(true),
      ),
      KioskModule.guide => const SizedBox.shrink(),
      KioskModule.week => const SizedBox.shrink(),
    };
    final showsLive =
        content.live.isNotEmpty && (showLive || !content.hasMatches);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      width: open && !hidden ? width : 0,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(color: scheme.surfaceContainer),
      // Laid out at its full width even while it grows or shrinks, so the
      // text does not reflow during the animation — from its inner edge,
      // the one beside the board: the left panel slides out of the
      // screen's left edge as the right one out of its right edge.
      child: OverflowBox(
        alignment: side == PanelSide.left
            ? Alignment.centerRight
            : Alignment.centerLeft,
        minWidth: width,
        maxWidth: width,
        child: !open
            ? const SizedBox.shrink()
            : Offstage(
                offstage: hidden,
                child: showsLive
                    ? _LiveView(
                        matches: content.live,
                        turn: liveTurn,
                        onOpenMatch: onOpenMatch,
                        onPlay: onPlay,
                        onShowList: !content.hasMatches || onShowLive == null
                            ? null
                            : () => onShowLive!(false),
                      )
                    : Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Keyed by the module: a module coming or
                            // going (a notice expiring) leaves the others
                            // their state.
                            for (final (i, entry) in entries.indexed) ...[
                              if (i > 0) const SizedBox(height: 12),
                              if (noticesAlone)
                                Flexible(
                                  key: ValueKey(entry.module),
                                  child: card(entry.module),
                                )
                              else
                                Expanded(
                                  key: ValueKey(entry.module),
                                  flex: entry.share,
                                  child: card(entry.module),
                                ),
                            ],
                          ],
                        ),
                      ),
              ),
      ),
    );
  }
}
```

`kioskDrawerWidthFor` above it stays untouched (Task 5 removes it).

- [ ] **Step 16: The shell — two panels, two buttons**

In `lib/features/kiosk/kiosk_shell.dart`, replace (imports):

```dart
import 'name_picker.dart';
import '../../core/widgets/emoji_text.dart';
```

with:

```dart
import 'name_picker.dart';
import '../../core/widgets/emoji_text.dart';
import '../schedule/widgets/calendar_board.dart' show calendarRulerWidth;
```

In `lib/features/kiosk/kiosk_shell.dart`, replace (state fields):

```dart
  /// What a visitor did to the drawer (true = open); null = the admin's
  /// resting state. The idle reset puts it back.
  bool? _drawerOverride;

  /// Bumped on every idle reset; the drawer's match list starts over on it.
  int _resets = 0;
```

with:

```dart
  /// What a visitor did to each panel (true = open); a side missing = the
  /// admin's resting state. The idle reset puts both back.
  final _drawerOverride = <PanelSide, bool>{};

  /// Bumped on every idle reset; the panels' cards that scroll or page
  /// (the match list, the duty plan) start over on it.
  int _resets = 0;
```

In `lib/features/kiosk/kiosk_shell.dart`, replace (in `_onIdle`):

```dart
      _selected = null;
      _drawerOverride = null;
```

with:

```dart
      _selected = null;
      _drawerOverride.clear();
```

Then replace the whole method `_boardWithPanel` — everything from the line

```dart
  /// The board with the drawer (notices and matches) on its right — no
```

down to, but not including, the lines

```dart
  @override
  Widget build(BuildContext context) {
    // The admin flips
```

— with:

```dart
  /// The board between the two panels (0077) — a side with nothing to show
  /// has neither a panel nor a button; with nothing on either side the
  /// board is alone.
  Widget _boardWithPanel() {
    final left = ref.watch(kioskPanelContentProvider(PanelSide.left));
    final right = ref.watch(kioskPanelContentProvider(PanelSide.right));
    final settings = ref.watch(settingsProvider).value;
    final panels = settings?.kioskPanels ?? KioskPanels.defaults;
    final visibleDays = settings?.kioskVisibleDays ?? 7;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final play = _play;
    // Worked out once for both: each panel whole day columns, the two
    // together leaving at least one day of the board in view.
    final widths = kioskPanelWidths(
      screenWidth,
      rulerWidth: calendarRulerWidth,
      visibleDays: visibleDays,
      left: left == null ? null : panels.left.days,
      right: right == null ? null : panels.right.days,
    );
    final board = KioskBoardView(
      key: _boardKey,
      selected: _selected,
      onOpenMatch: _openMatchOrStream,
      onPlayVideo: play,
      // The columns are sized on the whole screen, a panel is a whole
      // number of them (kioskPanelWidths): open or closed, either panel
      // leaves the board whole days, and the columns never resize
      // mid-slide.
      columnBasisWidth: screenWidth,
      onVisibleDays: (first, last) =>
          setState(() => _boardDays = (first: first, last: last)),
      onOpenDuty: _openDuty,
    );
    if (left == null && right == null) return board;
    // A match being played keeps the panel holding the matches open: a
    // visitor may close it, and it opens again after the idle time.
    bool resting(PanelSide side, KioskPanelContent content) =>
        panels.panel(side).open || content.live.isNotEmpty;
    var leftOpen =
        left != null &&
        (_drawerOverride[PanelSide.left] ?? resting(PanelSide.left, left));
    var rightOpen =
        right != null &&
        (_drawerOverride[PanelSide.right] ?? resting(PanelSide.right, right));
    // Two days on the screen leave room for one open panel only.
    final exclusive = kioskPanelsExclusive(
      visibleDays: visibleDays,
      hasLeft: left != null,
      hasRight: right != null,
    );
    if (exclusive && leftOpen && rightOpen) {
      // Both rest open (a visitor's tap closes the other one itself, see
      // toggle): the one with the match being played stays, else the right.
      if (left.live.isNotEmpty && right.live.isEmpty) {
        rightOpen = false;
      } else {
        leftOpen = false;
      }
    }
    void toggle(PanelSide side, bool open) => setState(() {
      _drawerOverride[side] = !open;
      // Opened where only one fits: the other one closes.
      final other = side == PanelSide.left ? PanelSide.right : PanelSide.left;
      if (!open && exclusive) _drawerOverride[other] = false;
    });
    // A visitor picked their name: the board is what they came for — both
    // panels and their buttons step aside until the pick is cleared (or the
    // idle reset), then the panels are as they were, live match and all.
    final picking = _selected != null;
    // The match being played, the switch back to it and the board's days
    // belong to the panel holding the matches.
    final matchesSide = panels.sideOf(KioskModule.matches);
    // The board and each panel on their own layer: a panel's turns (a
    // notice, the live match) do not re-record the board, nor the board's
    // scroll a panel. On the web the GPU still redraws every layer each
    // frame — this spares the Dart side (0065). Keyed by side: a panel
    // coming or going on one side leaves the other one its state.
    Widget panel(
      PanelSide side,
      KioskPanelContent content,
      double width,
      bool open,
    ) {
      final holdsMatches = side == matchesSide;
      return RepaintBoundary(
        key: ValueKey(side),
        child: KioskPanelView(
          side: side,
          width: width,
          content: content,
          open: open,
          hidden: picking,
          onOpenNotice: _openNotice,
          onOpenMatch: _openMatch,
          onPlay: play,
          resetToken: _resets,
          showLive: !(holdsMatches && _liveHidden),
          onShowLive: holdsMatches
              ? (live) => setState(() => _liveHidden = !live)
              : null,
          boardDays: holdsMatches && (settings?.kioskFollowBoard ?? true)
              ? _boardDays
              : null,
        ),
      );
    }

    // Each button floats over the board, vertically centred, at its
    // panel's inner edge — or at the board's edge, once the panel is gone:
    // the right one at the right edge, the left one centred on the hour
    // ruler, never over today's column (where visitors book).
    Widget button(PanelSide side, bool open) => KioskDrawerButton(
      side: side,
      open: open,
      onTap: () => toggle(side, open),
      breathe: settings?.kioskAnimations ?? true,
    );
    return Stack(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (left != null)
              panel(PanelSide.left, left, widths.left, leftOpen),
            Expanded(child: RepaintBoundary(child: board)),
            if (right != null)
              panel(PanelSide.right, right, widths.right, rightOpen),
          ],
        ),
        if (!picking && left != null)
          AnimatedPositioned(
            key: const ValueKey(PanelSide.left),
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            top: 0,
            bottom: 0,
            left:
                (leftOpen ? widths.left : 0) +
                (calendarRulerWidth - KioskDrawerButton.size) / 2,
            child: Center(child: button(PanelSide.left, leftOpen)),
          ),
        if (!picking && right != null)
          AnimatedPositioned(
            key: const ValueKey(PanelSide.right),
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            top: 0,
            bottom: 0,
            right: (rightOpen ? widths.right : 0) + KioskDrawerButton.margin,
            child: Center(child: button(PanelSide.right, rightOpen)),
          ),
      ],
    );
  }
```

In `lib/features/kiosk/kiosk_shell.dart`, replace (in `_StatusBar.build`, the header notices — they read `kioskNoticesHeader` now, 0077):

```dart
            (ref.watch(settingsProvider).value?.kioskNoticesInHeader ?? true)
```

with:

```dart
            (ref.watch(settingsProvider).value?.kioskNoticesHeader ?? true)
```

Notes on the shell:
- The board keeps `columnBasisWidth: screenWidth`, so either panel is whole day columns and the columns never resize mid-slide.
- The left button: `left: (leftOpen ? widths.left : 0) + (calendarRulerWidth - KioskDrawerButton.size) / 2` — centred on the 46 px hour ruler, which slides right with the board when the left panel opens.
- `kioskPanelsExclusive` (2 days on the screen, content on both sides): a tap that opens one panel sets the other's override to false; when both rest open, the panel with the match being played stays, else the right one.
- `_liveHidden`, `onShowLive` and `boardDays` go only to the panel on `panels.sideOf(KioskModule.matches)`.
- Each panel's `RepaintBoundary` and each button's `AnimatedPositioned` is keyed by its `PanelSide`, so a panel appearing or vanishing on one side never hands the other side's element (the live refresh, the list's weeks, the breathing) to it.

- [ ] **Step 17: Run — expected PASS**

```bash
cd /Users/mvazan/Home/rezervator && flutter analyze
cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/features/kiosk_test.dart
cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test
```

Expected: `No issues found!`; the kiosk file `All tests passed!` (the six new „two panels (0077)“ tests included); the whole suite `All tests passed!`.

- [ ] **Step 18: Commit**

```bash
cd /Users/mvazan/Home/rezervator
git add lib/features/kiosk/kiosk_info_panel.dart lib/features/kiosk/kiosk_shell.dart test/features/kiosk_test.dart
git commit -m "$(cat <<'EOF'
feat(kiosk): levý a pravý panel podle rozložení kiosk_panels

- obsah panelu po stranách (kioskPanelContentProvider.family): moduly
  s obsahem v pořadí správce, každý svým podílem; žádný = žádný panel
  ani tlačítko na té straně
- KioskPanelView místo KioskDrawer: moduly pod sebou Expanded(flex:
  podíl), samotná Nástěnka Flexible; levý panel vyjíždí zleva, obsah
  rozložený od vnitřního okraje
- hraný zápas zabere panel se Zápasy, ať je vlevo, nebo vpravo
  (kioskLiveProvider hlídá umístění Zápasů a živý režim)
- shell: šířky z kioskPanelWidths jednou pro oba, levé tlačítko na
  pravítku hodin, na dvou dnech jen jeden otevřený, výběr hráče schová
  oba, nečinnost vrátí oba a karty začnou znovu
- oznamy v záhlaví čtou kioskNoticesHeader
- testy: harness bere panels (jinak převod starých nastavení jako
  0077), testy obou panelů

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 19: The comments that still spoke of one drawer**

In `lib/features/kiosk/kiosk_board_view.dart`, replace (doc of `columnBasisWidth`):

```dart
  /// The width the day columns are sized for, instead of the board's own.
  /// The kiosk shell passes the width left beside the OPEN drawer, so the
  /// columns keep one width while the drawer slides in and out — sized to
  /// the board's changing width they were re-laid out on every frame.
```

with:

```dart
  /// The width the day columns are sized for, instead of the board's own.
  /// The kiosk shell passes the whole screen's width: each side panel is a
  /// whole number of these columns, and the columns keep one width while a
  /// panel slides in and out — sized to the board's changing width they
  /// were re-laid out on every frame.
```

In `lib/domain/models.dart`, replace (doc of `KioskCorner.fromHere`; the default corner stays `bl`):

```dart
  /// This corner, then the one above or below it, the one beside it, the
  /// one across: where the kiosk's further stream windows appear (0072) —
  /// the same side first, the drawer's side (the default corner is bottom
  /// left) last.
```

with:

```dart
  /// This corner, then the one above or below it, the one beside it, the
  /// one across: where the kiosk's further stream windows appear (0072) —
  /// the same side first, the other side last. A window covers the side
  /// panel on its side (0077); the admin picks a corner on the side without
  /// a panel (the default is bottom left).
```

- [ ] **Step 20: Analyze**

```bash
cd /Users/mvazan/Home/rezervator && flutter analyze
```

Expected: `No issues found!` (comments only; no test change).

- [ ] **Step 21: Commit**

```bash
cd /Users/mvazan/Home/rezervator
git add lib/features/kiosk/kiosk_board_view.dart lib/domain/models.dart
git commit -m "$(cat <<'EOF'
docs(kiosk): komentáře k panelům po obou stranách

Sloupce tabule se počítají z celé obrazovky kvůli oběma panelům;
okno streamu překryje panel na své straně.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```


### Task 4: Admin „Panely“ — the panels and the module table in Správa → Kiosk

One place in the admin for the panels: per used panel its width and whether it starts open, then one table of modules (panel Vypnuto/Vlevo/Vpravo, share 5–95 %, ↑↓), the sum per panel and its helper. Every change PATCHes the whole `kiosk_panels` through the existing optimistic `Api.setKioskPanel`. „Postranní panel“ goes; its list options become the section „Zápasy“; „Nástěnka“ gets its own „V záhlaví“ switch (`kiosk_notices_header`); „Služby na kantýně“ loses the drawer switch and share; „Hraný zápas“ and „Zápasy“ show while `matches` is placed. New order: Obrazovka kiosku, Stavový řádek, Panely, Nástěnka, Služby na kantýně, Zápasy, Hraný zápas, Stream zápasu, Optimalizace výkonu (then the address and the accounts). A second commit rewords the texts that assumed one right-hand panel.

**Files:**
- Modify: `lib/features/admin/kiosk_screen.dart`
- Modify: `lib/data/providers.dart` (only the doc comment of `Api.setKioskPanel`, which names dropped columns)
- Test: `test/features/kiosk_screen_test.dart`

**Interfaces:**
- Consumes (Task 2, `lib/domain/kiosk_layout.dart`): `enum KioskModule { duty, notices, matches, guide, week }`, `enum PanelSide { off, left, right }`, `class KioskModulePlacement` (`id`, `side`, `share`, `KioskModule? get module`), `class KioskPanels` — `static const defaults`, `factory KioskPanels.fromJson(Object? json)`, `Map<String, Object?> toJson()`, `List<KioskModulePlacement> modules`, `KioskPanel panel(PanelSide side)`, `List<KioskModulePlacement> modulesOn(PanelSide side)`, `PanelSide sideOf(KioskModule m)`, `int shareOf(KioskModule m)`, `KioskPanels withSide(KioskModule m, PanelSide side)`, `KioskPanels withShare(KioskModule m, int share)`, `KioskPanels moved(KioskModule m, int by)`, `KioskPanels withPanel(PanelSide side, {int? days, bool? open})`; `KioskPanel.days` / `.open`. From `lib/domain/models.dart` (Task 2): `ScheduleSettings.kioskPanels` (default `KioskPanels.defaults`) and `ScheduleSettings.kioskNoticesHeader` (default `true`), both constructor params.
- Consumes (existing): `Api.setKioskPanel(Map<String, Object?> changes, {required String tenantId})` (`lib/data/providers.dart`), `NumberSettingField` (`lib/features/admin/widgets/number_setting_field.dart`), `tryAction`, `friendlyDbError`.
- Produces: no public Dart API. String `ValueKey`s the tests find: `section:<title>` on every section, `kiosk-panel:left|right` on a panel's row, `kiosk-module:<KioskModule.name>` on a table row, `kiosk-modules-header` on the table's header row (one-line layout only); `NumberSettingField` keys `kiosk_panels.<side>.days` and `kiosk_panels.<module>.share`. After this task neither `kiosk_screen.dart` nor its test uses `KioskNoticesMode`, `kioskNoticesMode`, `kioskShowNotices`, `kioskNoticesInHeader`, `kioskPanelEnabled`, `kioskDrawerOpen`, `kioskDrawerColumns`, `kioskNoticesShare`, `kioskShowMatches`, `kioskDutyDrawer` or `kioskDutyShare` — Task 5 removes them from the model.

Precondition: Task 2 is committed (the model and the two `ScheduleSettings` fields). Task 3 is independent of this task.

Design notes (why the code looks as it does):
- From 520 px of content width (web, tablet) each module is one line of the table, under a header row „Modul“ / „Panel“ / „Podíl“ / „Pořadí“ as in the spec's sketch (small `Text`s over the same column widths as the rows). On a phone each module takes two lines (name + list, then share + arrows) and the header row is left out; the layout is chosen by a `LayoutBuilder`. Each control keeps its own label either way („Panel“ on the list, „Podíl“ on the share, tooltips „Posunout výš“ / „Posunout níž“ on the arrows), so the two-line layout reads without a header.
- Rows are keyed per module, so ↑↓ moves a row's share field with its module rather than re-using the field in that position.
- The table lists the modules this app knows, in the layout's order (= the order inside each panel); an unknown id (a newer app's module) is not listed and goes back unchanged in every PATCH, because the PATCH is `panels.toJson()` of the parsed layout.
- The panel rows and the sums appear only for a side that holds a module (`modulesOn(side)` non-empty): an empty panel is not on the kiosk at all.
- The sum is shown as it is (it need not be 100): the kiosk takes shares as flex weights.

- [ ] **Step 1: Update the tests first**

All edits are in `test/features/kiosk_screen_test.dart`, applied in this order; each old block occurs exactly once in the file at that point.

**Edit 1 — Import the layout model** (`test/features/kiosk_screen_test.dart`). Replace:

```dart
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
```

with:

```dart
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/kiosk_layout.dart';
import 'package:rezervator/domain/models.dart';
```

**Edit 2 — Section finders next to `inTile`** (`test/features/kiosk_screen_test.dart`). Replace:

```dart
  Finder inTile(String title, String text) => find.descendant(
    of: find.widgetWithText(ListTile, title),
    matching: find.text(text),
  );
```

with:

```dart
  Finder inTile(String title, String text) => find.descendant(
    of: find.widgetWithText(ListTile, title),
    matching: find.text(text),
  );

  /// The admin section titled [title] (keyed by its title) — „Nástěnka“
  /// and „Zápasy“ are rows of the Panely table too, „V záhlaví“ is a
  /// switch in two sections.
  Finder section(String title) => find.byKey(ValueKey('section:$title'));

  /// [finder] within the section titled [title].
  Finder inSection(String title, Finder finder) =>
      find.descendant(of: section(title), matching: finder);
```

**Edit 3 — A taller window: the Panely table makes the page longer** (`test/features/kiosk_screen_test.dart`). Replace:

```dart
  // The page is long (the panel options sit above the address): a tall
  // window keeps every section built.
  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 5600);
```

with:

```dart
  // The page is long (the panel options sit above the address): a tall
  // window keeps every section built.
  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 6400);
```

**Edit 4 — The harness loses `panelEnabled` (the column is gone)** (`test/features/kiosk_screen_test.dart`). Replace:

```dart
    ScheduleSettings? settings,
    bool? panelEnabled,
    Venue? alleyVenue,
    http.Client? openMeteo,
  }) {
    final shown = settings ??
        (panelEnabled == null
            ? defaults0
            : ScheduleSettings(
                laneCount: 4,
                trainingWeekdays: const {1, 2, 4},
                bookingHorizonDays: 14,
                maxActiveReservations: 3,
                kioskPanelEnabled: panelEnabled,
              ));
```

with:

```dart
    ScheduleSettings? settings,
    Venue? alleyVenue,
    http.Client? openMeteo,
  }) {
    final shown = settings ?? defaults0;
```

**Edit 5 — Replace the old „panel options“ test with the notices' header switch and the „Panely“ group** (`test/features/kiosk_screen_test.dart`). Replace:

```dart
  testWidgets('the panel options PATCH their own columns', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;

    await tester.ensureVisible(find.text('Kde se oznamy zobrazí'));
    await tester.tap(find.text('V záhlaví i v panelu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jen v záhlaví').last);
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_notices_mode': 'header'});

    await tester.tap(find.widgetWithText(SwitchListTile, 'Zápasy v panelu'));
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_show_matches': false});

    await tester.tap(
        find.widgetWithText(SwitchListTile, 'Výchozně rozbalený'));
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_drawer_open': true});
  });
```

with:

```dart
  testWidgets('the notices in the header: on by default, their own switch in '
      'the Nástěnka section PATCHes kiosk_notices_header', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    final header = inSection(
      'Nástěnka',
      find.widgetWithText(SwitchListTile, 'V záhlaví'),
    );
    expect(tester.widget<SwitchListTile>(header).value, isTrue);
    // Where in a panel the notices go is the Panely table's now.
    expect(find.text('Kde se oznamy zobrazí'), findsNothing);

    await tester.ensureVisible(header);
    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(
      jsonDecode(requests.lastWhere((r) => r.method == 'PATCH').body),
      {'kiosk_notices_header': false},
    );
  });

  for (final (header, side, why) in [
    (true, PanelSide.off, 'in the header only'),
    (false, PanelSide.left, 'in a panel only'),
  ]) {
    testWidgets('the notices\' rotation shows with the notices $why', (
      tester,
    ) async {
      tall(tester);
      await tester.pumpWidget(
        app(
          settings: ScheduleSettings(
            laneCount: 4,
            trainingWeekdays: const {1},
            bookingHorizonDays: 14,
            maxActiveReservations: 3,
            kioskNoticesHeader: header,
            kioskPanels: KioskPanels.defaults.withSide(
              KioskModule.notices,
              side,
            ),
            tenantId: 't',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        inSection(
          'Nástěnka',
          find.widgetWithText(TextField, 'Střídání oznamů'),
        ),
        findsOneWidget,
      );
    });
  }

  group('panels (0077)', () {
    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;
    int patches() => requests.where((r) => r.method == 'PATCH').length;

    /// [panels] the way a PATCH carries it.
    Object? patched(KioskPanels panels) =>
        jsonDecode(jsonEncode(panels.toJson()));

    /// The modules' entries of the last PATCH.
    List<dynamic> patchedModules() =>
        (lastPatch()['kiosk_panels'] as Map)['modules'] as List;

    /// The settings with [panels], everything else the default.
    ScheduleSettings laid(KioskPanels panels) => ScheduleSettings(
      laneCount: 4,
      trainingWeekdays: const {1, 2, 4},
      bookingHorizonDays: 14,
      maxActiveReservations: 3,
      kioskPanels: panels,
      tenantId: 't',
    );

    Finder moduleRow(KioskModule module) =>
        find.byKey(ValueKey('kiosk-module:${module.name}'));
    Finder panelRow(PanelSide side) =>
        find.byKey(ValueKey('kiosk-panel:${side.name}'));
    Finder inRow(Finder row, Finder finder) =>
        find.descendant(of: row, matching: finder);
    Finder share(KioskModule module) =>
        inRow(moduleRow(module), find.widgetWithText(TextField, 'Podíl'));
    Finder width(PanelSide side) =>
        inRow(panelRow(side), find.widgetWithText(TextField, 'Šířka'));
    IconButton arrow(WidgetTester tester, KioskModule module, IconData icon) =>
        tester.widget<IconButton>(
          inRow(moduleRow(module), find.widgetWithIcon(IconButton, icon)),
        );
    String shown(WidgetTester tester, Finder field) =>
        tester.widget<TextField>(field).controller!.text;

    /// Types [text] into [field] and presses Enter.
    Future<void> type(WidgetTester tester, Finder field, String text) async {
      await tester.ensureVisible(field);
      await tester.enterText(field, text);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
    }

    /// Opens the panel list of [module], now showing [now], and picks [to].
    Future<void> place(
      WidgetTester tester,
      KioskModule module,
      String now,
      String to,
    ) async {
      final current = inRow(moduleRow(module), find.text(now));
      await tester.ensureVisible(current);
      await tester.tap(current);
      await tester.pumpAndSettle();
      await tester.tap(find.text(to).last);
      await tester.pumpAndSettle();
    }

    testWidgets('the default layout: every module in its order with its '
        'panel, the placed ones with their share; only the right panel has '
        'a row; the sum per panel', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(inSection('Panely', find.text('Panely')), findsOneWidget);
      double top(Finder f) => tester.getTopLeft(f).dy;
      final tops = <double>[];
      for (final (module, name, side) in [
        (KioskModule.duty, 'Služba na kantýně', 'Vypnuto'),
        (KioskModule.notices, 'Nástěnka', 'Vpravo'),
        (KioskModule.matches, 'Zápasy', 'Vpravo'),
        (KioskModule.guide, 'Jak začít', 'Vypnuto'),
        (KioskModule.week, 'Hráči týdne', 'Vypnuto'),
      ]) {
        final row = moduleRow(module);
        expect(inSection('Panely', row), findsOneWidget, reason: name);
        expect(inRow(row, find.text(name)), findsOneWidget, reason: name);
        expect(inRow(row, find.text(side)), findsOneWidget, reason: name);
        tops.add(top(row));
      }
      for (var i = 1; i < tops.length; i++) {
        expect(tops[i - 1], lessThan(tops[i]), reason: 'row $i');
      }
      // Wide enough for one-line rows: the table's head above them, each
      // label over its column.
      final head = find.byKey(const ValueKey('kiosk-modules-header'));
      expect(inSection('Panely', head), findsOneWidget);
      for (final label in ['Modul', 'Panel', 'Podíl', 'Pořadí']) {
        expect(inRow(head, find.text(label)), findsOneWidget, reason: label);
      }
      expect(top(head), lessThan(tops.first));
      expect(
        tester.getTopLeft(inRow(head, find.text('Panel'))).dx,
        tester
            .getTopLeft(
              inRow(
                moduleRow(KioskModule.notices),
                find.byType(DropdownButtonFormField<PanelSide>),
              ),
            )
            .dx,
      );
      expect(
        tester.getTopLeft(inRow(head, find.text('Podíl'))).dx,
        tester.getTopLeft(share(KioskModule.notices)).dx,
      );
      expect(shown(tester, share(KioskModule.notices)), '40');
      expect(shown(tester, share(KioskModule.matches)), '60');
      // An unplaced module has no share and no arrows.
      for (final m in [KioskModule.duty, KioskModule.guide, KioskModule.week]) {
        expect(inRow(moduleRow(m), find.byType(TextField)), findsNothing,
            reason: m.name);
        expect(inRow(moduleRow(m), find.byType(IconButton)), findsNothing,
            reason: m.name);
      }

      // Only the right panel holds modules: only its row, above the table.
      expect(panelRow(PanelSide.left), findsNothing);
      expect(inRow(panelRow(PanelSide.right), find.text('Pravý panel')),
          findsOneWidget);
      expect(top(panelRow(PanelSide.right)),
          lessThan(top(moduleRow(KioskModule.duty))));
      expect(shown(tester, width(PanelSide.right)), '2');
      expect(
        tester
            .widget<SwitchListTile>(
              inRow(panelRow(PanelSide.right), find.byType(SwitchListTile)),
            )
            .value,
        isFalse,
      );

      expect(find.text('Vpravo 100 %'), findsOneWidget);
      expect(find.text('Podíly se přepočítají na celou výšku panelu.'),
          findsOneWidget);
      // One place for the panels: the old section is gone.
      expect(find.text('Postranní panel'), findsNothing);
      expect(find.text('Panel zapnutý'), findsNothing);
    });

    testWidgets('a module goes into a panel from its list: the PATCH is the '
        'whole layout', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await place(tester, KioskModule.guide, 'Vypnuto', 'Vlevo');
      expect(lastPatch().keys, ['kiosk_panels']);
      expect(
        lastPatch()['kiosk_panels'],
        patched(
          KioskPanels.defaults.withSide(KioskModule.guide, PanelSide.left),
        ),
      );
      expect((lastPatch()['kiosk_panels'] as Map)['left'],
          {'days': 2, 'open': false});
      expect((lastPatch()['kiosk_panels'] as Map)['right'],
          {'days': 2, 'open': false});
      expect(patchedModules(), hasLength(5));
      expect(
        patchedModules(),
        contains(equals({'id': 'guide', 'side': 'left', 'share': 45})),
      );

      await place(tester, KioskModule.notices, 'Vpravo', 'Vypnuto');
      expect(lastPatch(), {
        'kiosk_panels': patched(
          KioskPanels.defaults.withSide(KioskModule.notices, PanelSide.off),
        ),
      });
      expect(
        patchedModules(),
        contains(equals({'id': 'notices', 'side': 'off', 'share': 40})),
      );
    });

    testWidgets('a placed module\'s share: 5–95 %, the PATCH is the whole '
        'layout', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await type(tester, share(KioskModule.notices), '96');
      expect(find.text('Zadej číslo od 5 do 95.'), findsOneWidget);
      await type(tester, share(KioskModule.notices), '4');
      expect(find.text('Zadej číslo od 5 do 95.'), findsOneWidget);
      expect(patches(), 0);

      await type(tester, share(KioskModule.notices), '30');
      expect(lastPatch(), {
        'kiosk_panels': patched(
          KioskPanels.defaults.withShare(KioskModule.notices, 30),
        ),
      });
      expect(
        patchedModules(),
        contains(equals({'id': 'notices', 'side': 'right', 'share': 30})),
      );
    });

    testWidgets('↑↓ move a module among the placed ones of its panel: the '
        'first cannot go up, the last cannot go down', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(arrow(tester, KioskModule.notices, Icons.arrow_upward).onPressed,
          isNull);
      expect(
          arrow(tester, KioskModule.notices, Icons.arrow_downward).onPressed,
          isNotNull);
      expect(arrow(tester, KioskModule.matches, Icons.arrow_upward).onPressed,
          isNotNull);
      expect(
          arrow(tester, KioskModule.matches, Icons.arrow_downward).onPressed,
          isNull);

      final up =
          inRow(moduleRow(KioskModule.matches), find.byTooltip('Posunout výš'));
      await tester.ensureVisible(up);
      await tester.tap(up);
      await tester.pumpAndSettle();
      expect(lastPatch(), {
        'kiosk_panels': patched(
          KioskPanels.defaults.moved(KioskModule.matches, -1),
        ),
      });
      // The matches now come first on the right.
      expect(
        [
          for (final m in patchedModules().cast<Map>())
            if (m['side'] == 'right') m['id'],
        ],
        ['matches', 'notices'],
      );

      await tester.tap(
        inRow(moduleRow(KioskModule.notices), find.byTooltip('Posunout níž')),
      );
      await tester.pumpAndSettle();
      expect(lastPatch(), {
        'kiosk_panels': patched(
          KioskPanels.defaults.moved(KioskModule.notices, 1),
        ),
      });
    });

    testWidgets('modules on both sides: both panels\' rows, left first; the '
        'width 1–13 and the start PATCH the whole layout; the sum per '
        'panel', (tester) async {
      tall(tester);
      final both = KioskPanels.defaults
          .withSide(KioskModule.guide, PanelSide.left)
          .withSide(KioskModule.week, PanelSide.left);
      await tester.pumpWidget(app(settings: laid(both)));
      await tester.pumpAndSettle();

      double top(Finder f) => tester.getTopLeft(f).dy;
      expect(inRow(panelRow(PanelSide.left), find.text('Levý panel')),
          findsOneWidget);
      expect(inRow(panelRow(PanelSide.right), find.text('Pravý panel')),
          findsOneWidget);
      expect(top(panelRow(PanelSide.left)),
          lessThan(top(panelRow(PanelSide.right))));
      expect(find.text('Vlevo 100 % · Vpravo 100 %'), findsOneWidget);

      await type(tester, width(PanelSide.left), '14');
      expect(find.text('Zadej číslo od 1 do 13.'), findsOneWidget);
      await type(tester, width(PanelSide.left), '0');
      expect(patches(), 0);
      await type(tester, width(PanelSide.left), '3');
      expect(lastPatch(), {
        'kiosk_panels': patched(both.withPanel(PanelSide.left, days: 3)),
      });

      final open =
          inRow(panelRow(PanelSide.left), find.byType(SwitchListTile));
      await tester.ensureVisible(open);
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(lastPatch(), {
        'kiosk_panels': patched(both.withPanel(PanelSide.left, open: true)),
      });
    });

    testWidgets('the match list follows the matches to either panel; a sum '
        'other than 100 shows as it is; alone in its panel a module has '
        'nowhere to move', (tester) async {
      tall(tester);
      await tester.pumpWidget(app(
        settings: laid(
          KioskPanels.defaults.withSide(KioskModule.matches, PanelSide.left),
        ),
      ));
      await tester.pumpAndSettle();

      expect(panelRow(PanelSide.left), findsOneWidget);
      expect(panelRow(PanelSide.right), findsOneWidget);
      expect(find.text('Vlevo 60 % · Vpravo 40 %'), findsOneWidget);
      expect(
        inSection(
          'Zápasy',
          find.widgetWithText(SwitchListTile, 'I budoucí zápasy'),
        ),
        findsOneWidget,
      );
      expect(
        inSection(
          'Hraný zápas',
          find.widgetWithText(SwitchListTile, 'Hraný zápas přes celý panel'),
        ),
        findsOneWidget,
      );
      expect(arrow(tester, KioskModule.matches, Icons.arrow_upward).onPressed,
          isNull);
      expect(
          arrow(tester, KioskModule.matches, Icons.arrow_downward).onPressed,
          isNull);
    });

    testWidgets('no module in a panel: no panel rows and no sums; the match '
        'list\'s and the live match\'s sections go with the matches', (
      tester,
    ) async {
      tall(tester);
      await tester.pumpWidget(app(
        settings: laid(
          KioskPanels.defaults
              .withSide(KioskModule.notices, PanelSide.off)
              .withSide(KioskModule.matches, PanelSide.off),
        ),
      ));
      await tester.pumpAndSettle();

      expect(panelRow(PanelSide.left), findsNothing);
      expect(panelRow(PanelSide.right), findsNothing);
      expect(find.textContaining(RegExp(r'^(Vlevo|Vpravo) \d+ %')),
          findsNothing);
      expect(find.text('Podíly se přepočítají na celou výšku panelu.'),
          findsNothing);
      for (final m in KioskModule.values) {
        expect(inRow(moduleRow(m), find.text('Vypnuto')), findsOneWidget,
            reason: m.name);
      }
      expect(section('Zápasy'), findsNothing);
      expect(section('Hraný zápas'), findsNothing);
      expect(find.widgetWithText(SwitchListTile, 'I budoucí zápasy'),
          findsNothing);
      expect(
        find.widgetWithText(SwitchListTile, 'Hraný zápas přes celý panel'),
        findsNothing,
      );
      expect(section('Nástěnka'), findsOneWidget);
      expect(section('Služby na kantýně'), findsOneWidget);
    });

    testWidgets('„Zápasy“: the list\'s options of the old side panel, in '
        'order, each PATCHing its own column', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(
        inSection('Zápasy', find.textContaining('Seznam zápasů kuželny')),
        findsOneWidget,
      );
      double top(Finder f) => tester.getTopLeft(f).dy;
      final options = [
        find.widgetWithText(SwitchListTile, 'I budoucí zápasy'),
        find.widgetWithText(SwitchListTile, 'Seznam sleduje tabuli'),
        find.widgetWithText(TextField, 'Odehrané zápasy: týdnů zpět'),
        find.widgetWithText(TextField, 'Budoucí zápasy: týdnů dopředu'),
      ];
      for (var i = 0; i < options.length; i++) {
        expect(inSection('Zápasy', options[i]), findsOneWidget,
            reason: 'option $i');
        if (i > 0) {
          expect(top(options[i - 1]), lessThan(top(options[i])),
              reason: 'option $i');
        }
      }
      await tester.ensureVisible(options[1]);
      await tester.tap(options[1]);
      await tester.pumpAndSettle();
      expect(lastPatch(), {'kiosk_follow_board': false});
    });

    testWidgets('a module of a newer app is not listed and goes back '
        'unchanged with every PATCH', (tester) async {
      tall(tester);
      await tester.pumpWidget(app(
        settings: laid(
          KioskPanels.fromJson({
            'left': {'days': 2, 'open': false},
            'right': {'days': 2, 'open': false},
            'modules': [
              {'id': 'duty', 'side': 'off', 'share': 30},
              {'id': 'notices', 'side': 'right', 'share': 40},
              {'id': 'matches', 'side': 'right', 'share': 60},
              {'id': 'guide', 'side': 'off', 'share': 45},
              {'id': 'week', 'side': 'off', 'share': 55},
              {'id': 'radar', 'side': 'left', 'share': 50},
            ],
          }),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(DropdownButtonFormField<PanelSide>), findsNWidgets(5));
      // Nothing this app shows is on the left: no row for that panel.
      expect(panelRow(PanelSide.left), findsNothing);

      await type(tester, width(PanelSide.right), '3');
      expect(
        patchedModules(),
        contains(equals({'id': 'radar', 'side': 'left', 'share': 50})),
      );
    });

    testWidgets('on a phone a placed module\'s share and arrows go under its '
        'name and its list', (tester) async {
      // Narrower than the table's one-line width (520 inside the page's
      // padding) — and wide enough for the other lists in the test font.
      tester.view.physicalSize = const Size(500, 8000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      final row = moduleRow(KioskModule.notices);
      await tester.ensureVisible(row);
      final list =
          inRow(row, find.byType(DropdownButtonFormField<PanelSide>));
      expect(
        tester.getTopLeft(share(KioskModule.notices)).dy,
        greaterThan(tester.getBottomLeft(list).dy),
      );
      expect(inRow(row, find.byTooltip('Posunout níž')), findsOneWidget);
      // No head on two-line rows: each control says what it is.
      expect(find.byKey(const ValueKey('kiosk-modules-header')), findsNothing);
      expect(inRow(row, find.text('Panel')), findsOneWidget);
    });
  });
```

**Edit 6 — „Dnešní zápasy v záhlaví“ sits above „Panely“ now** (`test/features/kiosk_screen_test.dart`). Replace:

```dart
    expect(
      tester.getTopLeft(todays).dy,
      lessThan(tester.getTopLeft(find.text('Nástěnka')).dy),
    );
```

with:

```dart
    expect(
      tester.getTopLeft(todays).dy,
      lessThan(tester.getTopLeft(section('Panely')).dy),
    );
```

**Edit 7 — The duty: two places in its section, the card is the table's** (`test/features/kiosk_screen_test.dart`). Replace:

```dart
    testWidgets('three places, each its own switch, all off by default: '
        'each PATCHes its own column', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.text('Služby na kantýně'), findsOneWidget);
      expect(
        find.textContaining('Správě → Služby. Každé místo se zapíná zvlášť.'),
        findsOneWidget,
      );
      for (final (title, column) in [
        ('V záhlaví', 'kiosk_duty_header'),
        ('V kalendáři', 'kiosk_duty_board'),
        ('V panelu', 'kiosk_duty_drawer'),
      ]) {
        final tile = find.widgetWithText(SwitchListTile, title);
```

with:

```dart
    testWidgets('two places in its section, each its own switch, both off '
        'by default: each PATCHes its own column; the card in a panel is '
        'the Panely table\'s', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(inSection('Služby na kantýně', find.text('Služby na kantýně')),
          findsOneWidget);
      expect(
        find.textContaining('Správě → Služby. Každé místo se zapíná zvlášť'),
        findsOneWidget,
      );
      for (final (title, column) in [
        ('V záhlaví', 'kiosk_duty_header'),
        ('V kalendáři', 'kiosk_duty_board'),
      ]) {
        final tile = inSection(
          'Služby na kantýně',
          find.widgetWithText(SwitchListTile, title),
        );
```

**Edit 8 — The duty: what each place is — no drawer switch, no share** (`test/features/kiosk_screen_test.dart`). Replace:

```dart
      expect(find.text('Pás se jmény přes dny služby v hlavičkách dnů '
          'tabule.'), findsOneWidget);
      expect(find.text('Karta se službou a plánem v postranním panelu.'),
          findsOneWidget);
      // Without the card there is no share of the drawer to set, without
      // the band no place for it.
      expect(find.widgetWithText(TextField, 'Podíl karty v panelu'),
          findsNothing);
      expect(find.text('Kde je pás'), findsNothing);
```

with:

```dart
      expect(find.text('Pás se jmény přes dny služby v hlavičkách dnů '
          'tabule.'), findsOneWidget);
      // The card's place and share are a row of the Panely table.
      expect(find.widgetWithText(SwitchListTile, 'V panelu'), findsNothing);
      expect(find.widgetWithText(TextField, 'Podíl karty v panelu'),
          findsNothing);
      expect(inSection('Panely', find.text('Služba na kantýně')),
          findsOneWidget);
      // Without the band no place for it.
      expect(find.text('Kde je pás'), findsNothing);
```

**Edit 9 — The band's list: in the duty's section (its drawer switch is gone)** (`test/features/kiosk_screen_test.dart`). Replace:

```dart
      expect(
        top(field),
        greaterThan(top(find.widgetWithText(SwitchListTile, 'V kalendáři'))),
      );
      expect(
        top(field),
        lessThan(top(find.widgetWithText(SwitchListTile, 'V panelu'))),
      );
```

with:

```dart
      expect(
        top(field),
        greaterThan(top(find.widgetWithText(SwitchListTile, 'V kalendáři'))),
      );
      expect(inSection('Služby na kantýně', field), findsOneWidget);
```

**Edit 10 — Delete the duty share test (the share is the table's, tested in the panels group); the group's closing line stays** (`test/features/kiosk_screen_test.dart`). Replace:

```dart

    testWidgets('with the card in the drawer its share shows: 30 % by '
        'default, 10–90, PATCHes kiosk_duty_share', (tester) async {
      tall(tester);
      await tester.pumpWidget(app(
        settings: const ScheduleSettings(
          laneCount: 4,
          trainingWeekdays: {1},
          bookingHorizonDays: 14,
          maxActiveReservations: 3,
          kioskDutyDrawer: true,
          tenantId: 't',
        ),
      ));
      await tester.pumpAndSettle();

      expect(
        tester.widget<SwitchListTile>(
          find.widgetWithText(SwitchListTile, 'V panelu'),
        ).value,
        isTrue,
      );
      final share = find.widgetWithText(TextField, 'Podíl karty v panelu');
      expect(tester.widget<TextField>(share).controller!.text, '30');
      expect(find.text('Kolik výšky panelu karta zabere; zbytek si dělí '
          'nástěnka a zápasy.'), findsOneWidget);
      // Right under its switch, still in the duty's section.
      expect(
        tester.getTopLeft(share).dy,
        greaterThan(
            tester.getTopLeft(find.widgetWithText(SwitchListTile, 'V panelu'))
                .dy),
      );
      expect(
        tester.getTopLeft(share).dy,
        lessThan(tester.getTopLeft(find.text('Postranní panel')).dy),
      );

      await enter(tester, 'Podíl karty v panelu', '95');
      expect(find.text('Zadej číslo od 10 do 90.'), findsOneWidget);
      expect(requests.where((r) => r.method == 'PATCH'), isEmpty);
      await enter(tester, 'Podíl karty v panelu', '50');
      expect(lastPatch(), {'kiosk_duty_share': 50});

      await tester.tap(find.widgetWithText(SwitchListTile, 'V panelu'));
      await tester.pumpAndSettle();
      expect(lastPatch(), {'kiosk_duty_drawer': false});
    });
  });
```

with:

```dart
  });
```

**Edit 11 — The typed numbers: the panel width and the notices' share are the table's now** (`test/features/kiosk_screen_test.dart`). Replace:

```dart
    // The defaults are in the fields: 60 s, 2 columns, 2 weeks back.
    String shown(String label) =>
        tester.widget<TextField>(find.widgetWithText(TextField, label))
            .controller!.text;
    expect(shown('Doba nečinnosti'), '60');
    expect(shown('Šířka panelu'), '2');
    expect(shown('Odehrané zápasy: týdnů zpět'), '2');

    await enter(tester, 'Doba nečinnosti', '300');
    expect(lastPatch(), {'kiosk_idle_seconds': 300});
    await enter(tester, 'Střídání oznamů', '20');
    expect(lastPatch(), {'kiosk_notices_rotation_seconds': 20});
    await enter(tester, 'Šířka panelu', '3');
    expect(lastPatch(), {'kiosk_drawer_columns': 3});
    await enter(tester, 'Podíl nástěnky na výšce panelu', '60');
    expect(lastPatch(), {'kiosk_notices_share': 60});
    await enter(tester, 'Odehrané zápasy: týdnů zpět', '0');
```

with:

```dart
    // The defaults are in the fields: 60 s, 2 weeks back.
    String shown(String label) =>
        tester.widget<TextField>(find.widgetWithText(TextField, label))
            .controller!.text;
    expect(shown('Doba nečinnosti'), '60');
    expect(shown('Odehrané zápasy: týdnů zpět'), '2');

    await enter(tester, 'Doba nečinnosti', '300');
    expect(lastPatch(), {'kiosk_idle_seconds': 300});
    await enter(tester, 'Střídání oznamů', '20');
    expect(lastPatch(), {'kiosk_notices_rotation_seconds': 20});
    await enter(tester, 'Odehrané zápasy: týdnů zpět', '0');
```

**Edit 12 — The screen block ends above „Stavový řádek“** (`test/features/kiosk_screen_test.dart`). Replace:

```dart
      top(find.text('Posun tabule do minulosti')),
      top(find.text('Nástěnka')),
    ];
```

with:

```dart
      top(find.text('Posun tabule do minulosti')),
      top(section('Stavový řádek')),
    ];
```

**Edit 13 — Leaving a number field: the right panel's width, the whole layout** (`test/features/kiosk_screen_test.dart`). Replace:

```dart
    final field = find.widgetWithText(TextField, 'Šířka panelu');
    await tester.ensureVisible(field);
    await tester.enterText(field, '3');
    // Focus moves on to another field: the first one commits.
    await tester.tap(find.widgetWithText(TextField, 'Doba nečinnosti'));
    await tester.pumpAndSettle();
    expect(jsonDecode(requests.lastWhere((r) => r.method == 'PATCH').body),
        {'kiosk_drawer_columns': 3});
  });
```

with:

```dart
    final field = find.descendant(
      of: find.byKey(const ValueKey('kiosk-panel:right')),
      matching: find.widgetWithText(TextField, 'Šířka'),
    );
    await tester.ensureVisible(field);
    await tester.enterText(field, '3');
    // Focus moves on to another field: the first one commits — the whole
    // layout, with the right panel three days wide.
    await tester.tap(find.widgetWithText(TextField, 'Doba nečinnosti'));
    await tester.pumpAndSettle();
    expect(jsonDecode(requests.lastWhere((r) => r.method == 'PATCH').body), {
      'kiosk_panels': {
        'left': {'days': 2, 'open': false},
        'right': {'days': 3, 'open': false},
        'modules': [
          {'id': 'duty', 'side': 'off', 'share': 30},
          {'id': 'notices', 'side': 'right', 'share': 40},
          {'id': 'matches', 'side': 'right', 'share': 60},
          {'id': 'guide', 'side': 'off', 'share': 45},
          {'id': 'week', 'side': 'off', 'share': 55},
        ],
      },
    });
  });
```

**Edit 14 — The new section order** (`test/features/kiosk_screen_test.dart`). Replace:

```dart
  testWidgets('the options come in sections: screen, notices, canteen duty, '
      'panel, live match, then the address and the accounts', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    final order = [
      top('Obrazovka kiosku'),
      top('Stavový řádek'),
      top('Nástěnka'),
      top('Služby na kantýně'),
      top('Postranní panel'),
      top('Hraný zápas'),
      top('Adresa pro tablet'),
      top('Kioskové účty'),
    ];
    for (var i = 1; i < order.length; i++) {
      expect(order[i - 1], lessThan(order[i]), reason: 'section $i');
    }
  });
```

with:

```dart
  testWidgets('the options come in sections: screen, status line, panels, '
      'notices, canteen duty, matches, live match, stream, performance, then '
      'the address and the accounts', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    double top(Finder f) => tester.getTopLeft(f).dy;
    const sections = [
      'Obrazovka kiosku',
      'Stavový řádek',
      'Panely',
      'Nástěnka',
      'Služby na kantýně',
      'Zápasy',
      'Hraný zápas',
      'Stream zápasu',
      'Optimalizace výkonu',
    ];
    for (final title in sections) {
      expect(inSection(title, find.text(title)), findsOneWidget,
          reason: title);
    }
    final order = [
      for (final title in sections) top(section(title)),
      top(find.text('Adresa pro tablet')),
      top(find.text('Kioskové účty')),
    ];
    for (var i = 1; i < order.length; i++) {
      expect(order[i - 1], lessThan(order[i]), reason: 'section $i');
    }
    expect(find.text('Postranní panel'), findsNothing);
  });
```

**Edit 15 — Delete the panel switch test (no switch: a panel is on when it holds a module, tested in the panels group)** (`test/features/kiosk_screen_test.dart`). Delete this block, with the blank line after it:

```dart
  testWidgets('the panel switch comes first, and what needs it hides with it',
      (tester) async {
    tall(tester);
    await tester.pumpWidget(app(panelEnabled: false));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(SwitchListTile, 'Panel zapnutý'), findsOneWidget);
    for (final dependent in [
      'Výchozně rozbalený',
      'Zápasy v panelu',
      'Hraný zápas přes celý panel',
      // The duty's card has no drawer to go to; header and board stay.
      'V panelu',
    ]) {
      expect(find.widgetWithText(SwitchListTile, dependent), findsNothing);
    }
    expect(find.text('Šířka panelu'), findsNothing);
    expect(find.text('Podíl karty v panelu'), findsNothing);
    expect(find.text('Hraný zápas'), findsNothing);
    expect(find.widgetWithText(SwitchListTile, 'V záhlaví'), findsOneWidget);
    expect(find.widgetWithText(SwitchListTile, 'V kalendáři'), findsOneWidget);
    // The notices can still go to the status bar without the panel.
    expect(find.text('Kde se oznamy zobrazí'), findsOneWidget);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Panel zapnutý'));
    await tester.pumpAndSettle();
    expect(jsonDecode(requests.lastWhere((r) => r.method == 'PATCH').body),
        {'kiosk_panel_enabled': true});
  });

```

**Edit 16 — The rotations: the notices off in the header and in the panels** (`test/features/kiosk_screen_test.dart`). Replace:

```dart
  testWidgets('a rotation shows only with what it rotates', (tester) async {
    tall(tester);
    await tester.pumpWidget(app(
      settings: const ScheduleSettings(
        laneCount: 4,
        trainingWeekdays: {1},
        bookingHorizonDays: 14,
        maxActiveReservations: 3,
        kioskNoticesMode: KioskNoticesMode.off,
        kioskLiveMode: false,
        tenantId: 't',
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Střídání oznamů'), findsNothing);
    expect(find.text('Střídání hraných zápasů'), findsNothing);
    expect(find.text('Kontrola výsledků'), findsNothing);
    // Without the notices the notices' share has nothing to share either.
    expect(find.text('Podíl nástěnky na výšce panelu'), findsNothing);
```

with:

```dart
  testWidgets('a rotation shows only with what it rotates', (tester) async {
    tall(tester);
    await tester.pumpWidget(app(
      settings: ScheduleSettings(
        laneCount: 4,
        trainingWeekdays: const {1},
        bookingHorizonDays: 14,
        maxActiveReservations: 3,
        kioskNoticesHeader: false,
        kioskPanels: KioskPanels.defaults.withSide(
          KioskModule.notices,
          PanelSide.off,
        ),
        kioskLiveMode: false,
        tenantId: 't',
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Střídání oznamů'), findsNothing);
    expect(find.text('Střídání hraných zápasů'), findsNothing);
    expect(find.text('Kontrola výsledků'), findsNothing);
```


- [ ] **Step 2: Run the tests — they fail**

Run: `TZ=Europe/Prague flutter test test/features/kiosk_screen_test.dart`

Expected: FAIL, `+36 -20: Some tests failed.` — every test of the group `panels (0077)`, the notices' header and rotation tests, the section order, the screen block, today's matches, both canteen-duty tests that look in the duty's section, „leaving a number field writes it too“ and „a rotation shows only with what it rotates“; e.g. `Found 0 widgets with type "DropdownButtonFormField<PanelSide>"`, `Found 0 widgets with key [<'kiosk-panel:left'>]`, and `Found 1 widget with text "Střídání oznamů"` (the old notices mode still drives the rotation).

- [ ] **Step 3: Implement the „Panely“ section and move the options**

Edits in `lib/features/admin/kiosk_screen.dart` (and one doc comment in `lib/data/providers.dart`), applied in this order; each old block occurs exactly once at that point.

**Edit 1 — Import the layout model** (`lib/features/admin/kiosk_screen.dart`). Replace:

```dart
import '../../domain/models.dart';
import '../../domain/weather.dart' show WeatherPlace;
```

with:

```dart
import '../../domain/kiosk_layout.dart';
import '../../domain/models.dart';
import '../../domain/weather.dart' show WeatherPlace;
```

**Edit 2 — Replace `_noticesLabel` (its enum goes in Task 5) with the labels of the panels and the modules** (`lib/features/admin/kiosk_screen.dart`). Replace:

```dart
  static String _noticesLabel(KioskNoticesMode m) => switch (m) {
    KioskNoticesMode.off => 'Nezobrazovat',
    KioskNoticesMode.drawer => 'Jen v panelu',
    KioskNoticesMode.header => 'Jen v záhlaví',
    KioskNoticesMode.both => 'V záhlaví i v panelu',
  };
```

with:

```dart
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
  };
```

**Edit 3 — Key every section by its title (tests find „Nástěnka“, „Zápasy“ and „V záhlaví“ within their section)** (`lib/features/admin/kiosk_screen.dart`). Replace:

```dart
  /// A section: its title, a line on what it is about, and its options.
  Widget _section(
    BuildContext context,
    String title,
    String about,
    List<Widget> children,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
```

with:

```dart
  /// A section: its title, a line on what it is about, and its options.
  /// Keyed by its title: „Nástěnka“ and „Zápasy“ are rows of the Panely
  /// table too, and „V záhlaví“ is a switch in two sections.
  Widget _section(
    BuildContext context,
    String title,
    String about,
    List<Widget> children,
  ) => Padding(
    key: ValueKey('section:$title'),
    padding: const EdgeInsets.only(bottom: 24),
```

**Edit 4 — Add the layout writer and the „Panely“ section after `_panel`** (`lib/features/admin/kiosk_screen.dart`). Replace:

```dart
  ) => tryAction(
    context,
    () => Api.setKioskPanel(changes, tenantId: settings.tenantId),
    errorText: friendlyDbError,
  );
```

with:

```dart
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
  /// list, its share, its two arrows (an [IconButton] is 48 wide).
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
```

**Edit 5 — Insert „Panely“ right after „Stavový řádek“** (`lib/features/admin/kiosk_screen.dart`). Replace:

```dart
                      'státní svátek bez jména jeho název.',
                ),
              ],
            ),
            _section(
              context,
              'Nástěnka',
```

with:

```dart
                      'státní svátek bez jména jeho název.',
                ),
              ],
            ),
            _panelsSection(context, settings),
            _section(
              context,
              'Nástěnka',
```

**Edit 6 — „Nástěnka“: the header is its own switch (`kiosk_notices_header`); the panel half is the table's** (`lib/features/admin/kiosk_screen.dart`). Replace:

```dart
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
```

with:

```dart
              [
                _switch(
                  context,
                  settings,
                  'V záhlaví',
                  settings?.kioskNoticesHeader ?? true,
                  'kiosk_notices_header',
                  subtitle:
                      'Nadpis jednoho oznamu ve stavovém řádku nahoře. Do '
                      'panelu vlevo nebo vpravo dáš nástěnku v Panelech (výš).',
                ),
                if ((settings?.kioskNoticesHeader ?? true) ||
                    _placed(settings, KioskModule.notices))
                  _number(
```

**Edit 7 — „Služby na kantýně“: the card's switch and share go to the table** (`lib/features/admin/kiosk_screen.dart`). Replace:

```dart
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
```

with:

```dart
                  ),
              ],
            ),
```

**Edit 8 — „Postranní panel“ goes: its list options become the new „Zápasy“ section; „Hraný zápas“ follows the matches** (`lib/features/admin/kiosk_screen.dart`). Replace:

```dart
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
```

with:

```dart
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
                        'Když návštěvník posune tabuli na jiné dny, seznam '
                        'zápasů naskočí na zápasy těch dnů.',
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
```

**Edit 9 — The writer's doc no longer names dropped columns** (`lib/data/providers.dart`). Replace:

```dart
  /// Writes the kiosk drawer's options (0064) — the keys of
  /// `schedule_settings` (`kiosk_notices_mode`, `kiosk_show_matches`,
  /// `kiosk_matches_history_days`, `kiosk_drawer_open`). Optimistic, same
  /// reasoning as [setKioskFitDay].
```

with:

```dart
  /// Writes kiosk settings — any columns of `schedule_settings`, the whole
  /// panels' layout `kiosk_panels` (0077) among them. Optimistic, same
  /// reasoning as [setKioskFitDay].
```


- [ ] **Step 4: Run the tests and the analyzer — they pass**

Run: `TZ=Europe/Prague flutter test test/features/kiosk_screen_test.dart`
Expected: PASS, `+56: All tests passed!`

Run: `flutter analyze`
Expected: `No issues found!`

Run: `grep -n -e KioskNoticesMode -e kioskNoticesMode -e kioskShowNotices -e kioskNoticesInHeader -e kioskPanelEnabled -e kioskDrawerOpen -e kioskDrawerColumns -e kioskNoticesShare -e kioskShowMatches -e kioskDutyDrawer -e kioskDutyShare lib/features/admin/kiosk_screen.dart test/features/kiosk_screen_test.dart`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add lib/features/admin/kiosk_screen.dart lib/data/providers.dart test/features/kiosk_screen_test.dart
git commit -m "feat(admin): Panely — oba panely a tabulka modulů na jednom místě" -m "Sekce Postranní panel mizí. Panel s modulem má řádek se šířkou (1–13 dní) a výchozím rozbalením; tabulka modulů dává každému panel (Vypnuto/Vlevo/Vpravo), podíl 5–95 % a pořadí šipkami, pod ní součty podílů za panel. Každá změna PATCHuje celé kiosk_panels. Nástěnka má vlastní přepínač V záhlaví (kiosk_notices_header), seznam zápasů vlastní sekci Zápasy; Zápasy a Hraný zápas se ukážou, jen když jsou zápasy v panelu. Nové pořadí sekcí: Obrazovka, Stavový řádek, Panely, Nástěnka, Služby, Zápasy, Hraný zápas, Stream, Optimalizace." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 6: A failing test for the texts that assumed one right-hand panel**

**Edit 1 — A test of the reworded texts, last in the file** (`test/features/kiosk_screen_test.dart`). Replace:

```dart
    await tester.tap(find.widgetWithText(
        SwitchListTile, 'Hraný zápas přes celý panel'));
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_live_mode': false});
  });
}
```

with:

```dart
    await tester.tap(find.widgetWithText(
        SwitchListTile, 'Hraný zápas přes celý panel'));
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_live_mode': false});
  });

  testWidgets('the texts speak of two panels', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    for (final text in [
      // Doba nečinnosti.
      'Po tolika sekundách bez dotyku kiosk zapomene vybraného hráče, zavře '
          'okna i zápis, vrátí tabuli na dnešek a panely do výchozího stavu.',
      // Dní na obrazovce.
      'Kolik dní (sloupců) je na celé obrazovce najednou; další jsou o kus '
          'vedle. Rozbalené panely z nich zakryjí tolik, kolik je jejich '
          'šířka.',
      // Kde se okno objeví.
      'Okno překryje panel na své straně; vyber roh na straně bez panelu. '
          'Další okna do dalších rohů — nejdřív na stejné straně.',
      // Opakující se animace.
      'Tlačítka panelů se každé čtyři sekundy rozzáří a ikona živého '
          'přenosu pulzuje; při tom se překresluje celá obrazovka, i když se '
          'kiosku nikdo nedotýká. Vypnuto = obojí je v klidu.',
      // Hraný zápas přes celý panel.
      'Souboje hraného zápasu zaberou celý panel se zápasy a ten zůstane '
          'rozbalený — i když ho návštěvník zavře, po době nečinnosti se '
          'rozbalí znovu. Vypnuto = hraný zápas je jen řádek v seznamu.',
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    // The duty's card is placed in the Panely table.
    expect(
      inSection(
        'Služby na kantýně',
        find.text(
          'Kdo právě slouží na kantýně a kdo přijde na řadu — podle plánu ve '
          'Správě → Služby. Každé místo se zapíná zvlášť; kartu do panelu '
          'dáš v Panelech (výš).',
        ),
      ),
      findsOneWidget,
    );
    // Nothing says the panel is on the right, or that there is one button.
    expect(find.textContaining('Panel je vpravo'), findsNothing);
    expect(find.textContaining('Tlačítko panelu'), findsNothing);
    expect(find.textContaining('a panel do výchozího stavu'), findsNothing);
  });
}
```


- [ ] **Step 7: Run it — it fails**

Run: `TZ=Europe/Prague flutter test test/features/kiosk_screen_test.dart --plain-name "the texts speak of two panels"`
Expected: FAIL, `Found 0 widgets with text "Po tolika sekundách bez dotyku kiosk zapomene …"`.

- [ ] **Step 8: Reword the texts**

All edits in `lib/features/admin/kiosk_screen.dart`:

**Edit 1 — Doba nečinnosti: both panels** (`lib/features/admin/kiosk_screen.dart`). Replace:

```dart
                      'Po tolika sekundách bez dotyku kiosk zapomene '
                      'vybraného hráče, zavře okna i zápis, vrátí tabuli na '
                      'dnešek a panel do výchozího stavu.',
```

with:

```dart
                      'Po tolika sekundách bez dotyku kiosk zapomene '
                      'vybraného hráče, zavře okna i zápis, vrátí tabuli na '
                      'dnešek a panely do výchozího stavu.',
```

**Edit 2 — Dní na obrazovce: both panels** (`lib/features/admin/kiosk_screen.dart`). Replace:

```dart
                      'Kolik dní (sloupců) je na celé obrazovce najednou; '
                      'další jsou o kus vedle. Rozbalený panel z nich zakryje '
                      'tolik, kolik je jeho šířka.',
```

with:

```dart
                      'Kolik dní (sloupců) je na celé obrazovce najednou; '
                      'další jsou o kus vedle. Rozbalené panely z nich '
                      'zakryjí tolik, kolik je jejich šířka.',
```

**Edit 3 — Služby na kantýně: where the card goes** (`lib/features/admin/kiosk_screen.dart`). Replace:

```dart
              'Kdo právě slouží na kantýně a kdo přijde na řadu — podle plánu '
                  've Správě → Služby. Každé místo se zapíná zvlášť.',
```

with:

```dart
              'Kdo právě slouží na kantýně a kdo přijde na řadu — podle plánu '
                  've Správě → Služby. Každé místo se zapíná zvlášť; kartu '
                  'do panelu dáš v Panelech (výš).',
```

**Edit 4 — Hraný zápas: the panel with the matches** (`lib/features/admin/kiosk_screen.dart`). Replace:

```dart
                        'Souboje hraného zápasu zaberou celý panel a panel '
                        'zůstane rozbalený — i když ho návštěvník zavře, po '
                        'době nečinnosti se rozbalí znovu. Vypnuto = hraný '
                        'zápas je jen řádek v seznamu.',
```

with:

```dart
                        'Souboje hraného zápasu zaberou celý panel se zápasy '
                        'a ten zůstane rozbalený — i když ho návštěvník '
                        'zavře, po době nečinnosti se rozbalí znovu. Vypnuto '
                        '= hraný zápas je jen řádek v seznamu.',
```

**Edit 5 — Kde se okno objeví: a window covers the panel on its side (the old one-line helper was cut off, hence `helperMaxLines`)** (`lib/features/admin/kiosk_screen.dart`). Replace:

```dart
                        helperText:
                            'Panel je vpravo; vlevo dole mu okno nepřekáží. '
                            'Další okna do dalších rohů — nejdřív na stejné '
                            'straně.',
                        border: OutlineInputBorder(),
```

with:

```dart
                        helperText:
                            'Okno překryje panel na své straně; vyber roh na '
                            'straně bez panelu. Další okna do dalších rohů — '
                            'nejdřív na stejné straně.',
                        helperMaxLines: 3,
                        border: OutlineInputBorder(),
```

**Edit 6 — Opakující se animace: both buttons** (`lib/features/admin/kiosk_screen.dart`). Replace:

```dart
                      'Tlačítko panelu se každé čtyři sekundy rozzáří a ikona '
```

with:

```dart
                      'Tlačítka panelů se každé čtyři sekundy rozzáří a ikona '
```


- [ ] **Step 9: Run the tests and the analyzer — they pass**

Run: `TZ=Europe/Prague flutter test test/features/kiosk_screen_test.dart`
Expected: PASS, `+57: All tests passed!`

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 10: Commit**

```bash
git add lib/features/admin/kiosk_screen.dart test/features/kiosk_screen_test.dart
git commit -m "fix(admin): texty nastavení kiosku počítají se dvěma panely" -m "Doba nečinnosti vrací panely, Dní na obrazovce mluví o rozbalených panelech, okno streamu překryje panel na své straně, animace rozzáří tlačítka panelů, Hraný zápas zabere panel se zápasy a služba odkazuje kartu do Panelů. Nápověda rohu okna už se neořízne na jeden řádek." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```


### Task 5: Pryč se starými poli postranního panelu a s `kioskDrawerWidthFor`

The cleanup after Tasks 3 and 4. Those two tasks move every **reader** of the old fields to `kioskPanels`, `kioskNoticesHeader` and `kioskPanelWidths`. This task deletes the fields themselves, the enum and the old width function, plus whatever the tests still pass for them. It changes no behaviour.

**Files:**
- Modify: `lib/domain/models.dart` (the enum, ten fields/getters, constructor, `fromJson`, the doc comments that name them)
- Modify: `lib/features/kiosk/kiosk_info_panel.dart` (only if `kioskDrawerWidthFor` is still defined: the function and its import)
- Modify: `lib/data/providers.dart` (the doc comment of `Api.setKioskPanel`)
- Modify: `test/domain/models_test.dart` (the 0073 duty test; a new cached-row test)
- Modify: `test/features/kiosk_test.dart` (the harness `app()` of the side-drawer group)
- Modify: `test/features/kiosk_screen_test.dart` (the harness `app()`)

**Interfaces:**
- Consumes:
  - From Task 2: `KioskPanels`, `ScheduleSettings.kioskPanels` and `ScheduleSettings.kioskNoticesHeader`.
  - From Task 3: every kiosk read of the old fields replaced, as the inventory below records. That covers `kioskPanelContentProvider` as a family, `kioskLiveProvider` gated on `matches` being placed, `KioskPanelView` taking its `width`, the shell calling `kioskPanelWidths`, and the header notices reading `kioskNoticesHeader`.
  - From Task 4: every admin read or write of the old columns replaced.
- Produces:
  - `ScheduleSettings` without `kioskNoticesMode`, `kioskShowNotices`, `kioskNoticesInHeader`, `kioskPanelEnabled`, `kioskDrawerOpen`, `kioskDrawerColumns`, `kioskNoticesShare`, `kioskShowMatches`, `kioskDutyDrawer` and `kioskDutyShare`.
  - No `enum KioskNoticesMode`.
  - No `kioskDrawerWidthFor`.

**Inventory: every use at HEAD `719a8ad`, and the task that replaces it.**

Run `grep -rnE "KioskNoticesMode|kioskShowNotices|kioskNoticesInHeader|kioskPanelEnabled|kioskDrawerOpen|kioskDrawerColumns|kioskNoticesShare|kioskShowMatches|kioskDutyDrawer|kioskDutyShare|kioskDrawerWidthFor|kiosk_(panel_enabled|drawer_open|drawer_columns|notices_mode|notices_share|show_matches|duty_drawer|duty_share)" lib test`. At HEAD it lists the following uses.

| File:line (HEAD) | Use | Replaced by |
|---|---|---|
| `lib/domain/models.dart:634–636` | `enum KioskNoticesMode` and its doc | **Task 5** (Step 3a) |
| `lib/domain/models.dart:745–746, 753–755, 759, 784–785` | constructor defaults of the eight fields | **Task 5** (Step 3b) |
| `lib/domain/models.dart:809–824` | `kioskNoticesMode`, getters `kioskShowNotices`/`kioskNoticesInHeader`, `kioskShowMatches` | **Task 5** (Step 3c) |
| `lib/domain/models.dart:885–896` | `kioskDutyDrawer`, `kioskDutyShare` (+ doc naming them) | **Task 5** (Step 3d) |
| `lib/domain/models.dart:910–920` | `kioskDrawerOpen`, `kioskDrawerColumns` (doc names `kioskDrawerWidthFor`), `kioskNoticesShare` | **Task 5** (Step 3e) |
| `lib/domain/models.dart:930–932` | `kioskPanelEnabled` | **Task 5** (Step 3f) |
| `lib/domain/models.dart:940–941` | `kioskVisibleDays` doc names `[kioskDrawerColumns]` | **Task 5** (Step 3g) |
| `lib/domain/models.dart:1004–1008, 1016–1018, 1024, 1059–1060` | `fromJson` of the eight columns | **Task 5** (Step 3h) |
| `lib/features/kiosk/kiosk_info_panel.dart:36, 39–51` | `kioskDrawerWidthFor` and its only import (`calendarRulerWidth`) | callers: Task 3; **definition: Task 5** (Step 9) if Task 3 left it |
| `lib/features/kiosk/kiosk_info_panel.dart:74` | `kioskLiveProvider` gated on `kioskPanelEnabled` | Task 3 (gated on `sideOf(KioskModule.matches) != PanelSide.off && kioskLiveMode`) |
| `lib/features/kiosk/kiosk_info_panel.dart:100, 103, 107, 117` | `kioskPanelContentProvider`: `kioskPanelEnabled`, `kioskShowNotices`, `kioskShowMatches`, `kioskDutyDrawer` | Task 3 (`Provider.family<KioskPanelContent?, PanelSide>`) |
| `lib/features/kiosk/kiosk_info_panel.dart:200–204` | `KioskDrawer.build` computes its width with `kioskDrawerWidthFor(… kioskDrawerColumns …)` | Task 3 (`KioskPanelView` takes `width`) |
| `lib/features/kiosk/kiosk_info_panel.dart:211, 240` | `kioskNoticesShare`, `kioskDutyShare` (nested flex) | Task 3 (`KioskPanelEntry.share`, flat `Expanded(flex:)`) |
| `lib/features/kiosk/kiosk_shell.dart:307–311` | `kioskDrawerWidthFor(… kioskDrawerColumns …)` | Task 3 (`kioskPanelWidths`) |
| `lib/features/kiosk/kiosk_shell.dart:317–319` | comment naming `kioskDrawerWidthFor` | Task 3 (rewrites `_boardWithPanel`) |
| `lib/features/kiosk/kiosk_shell.dart:328–329` | `restingOpen` from `kioskDrawerOpen` | Task 3 (`kioskPanels.panel(side).open`) |
| `lib/features/kiosk/kiosk_shell.dart:560` | header notices from `kioskNoticesInHeader` | Task 3 (`kioskNoticesHeader`) |
| `lib/features/admin/kiosk_screen.dart:103–108` | `_noticesLabel(KioskNoticesMode)` | Task 4 |
| `lib/features/admin/kiosk_screen.dart:656–699` | dropdown 'Kde se oznamy zobrazí' (`kiosk_notices_mode`), rotation shown by `kioskNoticesMode` | Task 4 ('V záhlaví' = `kiosk_notices_header`; rotation shown when header or a panel) |
| `lib/features/admin/kiosk_screen.dart:755–780` | 'V panelu' (`kiosk_duty_drawer`), 'Podíl karty v panelu' (`kiosk_duty_share`) | Task 4 (module table in 'Panely') |
| `lib/features/admin/kiosk_screen.dart:783–898` | section 'Postranní panel' (`kiosk_panel_enabled`, `kiosk_drawer_open`, `kiosk_drawer_columns`, `kiosk_notices_share`, `kiosk_show_matches`, `kioskShowNotices`) | Task 4 ('Panely' + 'Zápasy') |
| `lib/features/admin/kiosk_screen.dart:899` | 'Hraný zápas' shown by `kioskPanelEnabled` | Task 4 (shown when `matches` is placed) |
| `lib/data/providers.dart:1119–1122` | `Api.setKioskPanel` doc lists `kiosk_notices_mode`, `kiosk_show_matches`, `kiosk_drawer_open` (and a column that never existed) | **Task 5** (Step 10) |
| `test/domain/models_test.dart:167–195` | the 0073 test reads `kiosk_duty_drawer`/`kiosk_duty_share` | **Task 5** (Step 2) |
| `test/features/kiosk_screen_test.dart:80, 85–93` | harness param `bool? panelEnabled` → `ScheduleSettings(kioskPanelEnabled:)` | Task 4 (Step 1 Edit 4, with its only caller, l. 1397); Task 5 Step 6 only checks |
| `test/features/kiosk_screen_test.dart:631–655` | 'the panel options PATCH their own columns' (`kiosk_notices_mode`, `kiosk_show_matches`, `kiosk_drawer_open`) | Task 4 |
| `test/features/kiosk_screen_test.dart:834–870` | duty section test: 'V panelu' → `kiosk_duty_drawer`, its subtitle, 'Podíl karty v panelu' | Task 4 |
| `test/features/kiosk_screen_test.dart:945–991` | duty share test (`kioskDutyDrawer: true`, 'Postranní panel', `kiosk_duty_share`, `kiosk_duty_drawer`) | Task 4 |
| `test/features/kiosk_screen_test.dart:1009, 1016–1019` | numbers test: 'Šířka panelu' → `kiosk_drawer_columns`, 'Podíl nástěnky na výšce panelu' → `kiosk_notices_share` | Task 4 |
| `test/features/kiosk_screen_test.dart:1330–1342` | 'leaving a number field writes it too' via 'Šířka panelu' → `kiosk_drawer_columns` | Task 4 |
| `test/features/kiosk_screen_test.dart:1344–1363` | section order with 'Postranní panel' | Task 4 |
| `test/features/kiosk_screen_test.dart:1394–1422` | 'the panel switch comes first' (`app(panelEnabled: false)`, `kiosk_panel_enabled`) | Task 4 |
| `test/features/kiosk_screen_test.dart:1424–1446` | 'a rotation shows only with what it rotates' (`kioskNoticesMode: KioskNoticesMode.off`, 'Podíl nástěnky…') | Task 4 (layout with notices off + `kioskNoticesHeader: false`; not `const` if built with `withSide`) |
| `test/features/kiosk_test.dart:1865–1872, 1877–1878, 1882, 1901–1902` | harness `shown()` passes `kioskDrawerOpen`, `kioskNoticesMode`, `kioskShowMatches`, `kioskDrawerColumns`, `kioskNoticesShare`, `kioskPanelEnabled`, `kioskDutyDrawer`, `kioskDutyShare` | **Task 5** (Step 4); Task 3 adds `kioskPanels:`/`kioskNoticesHeader:` beside them |
| `test/features/kiosk_test.dart:1810–1823, 1849–1850` | harness params `drawerOpen`, `showNotices`, `headerNotices`, `showMatches`, `drawerColumns`, `share`, `panelEnabled`, `dutyDrawer`, `dutyShare` | stay while they feed `kioskPanels` (Task 3); **Task 5** (Step 5) removes any that feed nothing |
| `test/features/kiosk_test.dart` call sites 2609, 3230, 3417 (`drawerColumns`), 3453, 3646, 3707 (`showNotices`), 3466 (`showMatches`), 3919 (`share`), 4106, 4639 (`panelEnabled`), 4842 (`headerNotices`), 5830–6072 (`dutyDrawer`/`dutyShare`), 46× `drawerOpen: true` | tests driving the old drawer | Task 3 (their expectations); Task 5 only removes an argument whose parameter Step 5 removes |

Not in this inventory, and not this task's job:
- the `KioskCorner.fromHere` doc (`models.dart:718–721`, "the drawer's side") is Task 3's stream-corner comment;
- the stale `columnBasisWidth` doc (`kiosk_board_view.dart:91–95`) is Task 3's;
- `docs/SCHEMA.md` is Task 1's;
- the changelog is Task 13's.

- [ ] **Step 1: The failing check**

```bash
cd /Users/mvazan/Home/rezervator && grep -rnE "KioskNoticesMode|kioskShowNotices|kioskNoticesInHeader|kioskPanelEnabled|kioskDrawerOpen|kioskDrawerColumns|kioskNoticesShare|kioskShowMatches|kioskDutyDrawer|kioskDutyShare|kioskDrawerWidthFor" lib test
```

Expected now: FAIL (non-empty). The output may contain only these lines:
- `lib/domain/models.dart`;
- the definition in `lib/features/kiosk/kiosk_info_panel.dart`, if Task 3 left it;
- `test/domain/models_test.dart` (the 0073 duty test);
- the `ScheduleSettings(...)` call in the `app()` harness of `test/features/kiosk_test.dart`.

If it lists anything else, the task named in the inventory is unfinished. That covers a reader in `kiosk_shell.dart`, `kiosk_info_panel.dart` (other than the definition) or `kiosk_screen.dart`, or a test body. Stop and finish it in that task, not here.

- [ ] **Step 2: Update `models_test.dart`**

In `test/domain/models_test.dart`, replace the 0073 test that reads the duty's drawer columns, and add a test that pins the old APK's fallback. A cached row with the dropped columns reads as the default layout.

Old:

```dart
    test('fromJson reads the kiosk\'s duty places and the card\'s share '
        '(0073); off and 30 % when absent', () {
      const base = {
        'lane_count': 4,
        'training_weekdays': [1, 2, 4],
        'booking_horizon_days': 14,
        'max_active_reservations': 3,
      };
      final on = ScheduleSettings.fromJson({
        ...base,
        'kiosk_duty_header': true,
        'kiosk_duty_board': true,
        'kiosk_duty_drawer': true,
        'kiosk_duty_share': 55,
      });
      expect(on.kioskDutyHeader, isTrue);
      expect(on.kioskDutyBoard, isTrue);
      expect(on.kioskDutyDrawer, isTrue);
      expect(on.kioskDutyShare, 55);
      final old = ScheduleSettings.fromJson(base);
      expect(old.kioskDutyHeader, isFalse);
      expect(old.kioskDutyBoard, isFalse);
      expect(old.kioskDutyDrawer, isFalse);
      expect(old.kioskDutyShare, 30);
      expect(ScheduleSettings.defaults.kioskDutyHeader, isFalse);
      expect(ScheduleSettings.defaults.kioskDutyBoard, isFalse);
      expect(ScheduleSettings.defaults.kioskDutyDrawer, isFalse);
      expect(ScheduleSettings.defaults.kioskDutyShare, 30);
    });
```

New:

```dart
    test('fromJson reads the kiosk\'s duty places (0073); off when absent',
        () {
      const base = {
        'lane_count': 4,
        'training_weekdays': [1, 2, 4],
        'booking_horizon_days': 14,
        'max_active_reservations': 3,
      };
      final on = ScheduleSettings.fromJson({
        ...base,
        'kiosk_duty_header': true,
        'kiosk_duty_board': true,
      });
      expect(on.kioskDutyHeader, isTrue);
      expect(on.kioskDutyBoard, isTrue);
      final old = ScheduleSettings.fromJson(base);
      expect(old.kioskDutyHeader, isFalse);
      expect(old.kioskDutyBoard, isFalse);
      expect(ScheduleSettings.defaults.kioskDutyHeader, isFalse);
      expect(ScheduleSettings.defaults.kioskDutyBoard, isFalse);
    });

    test('a cached row from before 0077, with the dropped drawer columns '
        'still in it, reads as the default layout', () {
      final s = ScheduleSettings.fromJson({
        'lane_count': 4,
        'training_weekdays': [1, 2, 4],
        'booking_horizon_days': 14,
        'max_active_reservations': 3,
        'kiosk_panel_enabled': false,
        'kiosk_drawer_open': true,
        'kiosk_drawer_columns': 5,
        'kiosk_notices_mode': 'off',
        'kiosk_notices_share': 70,
        'kiosk_show_matches': false,
        'kiosk_duty_drawer': true,
        'kiosk_duty_share': 55,
      });
      expect(s.kioskPanels, KioskPanels.defaults);
      expect(s.kioskNoticesHeader, isTrue);
    });
```

- [ ] **Step 3: Delete the fields from `lib/domain/models.dart`**

Make eight edits.

(a) The enum.

Old (with the blank line after it; New is nothing):

```dart
/// Where the kiosk shows the notices (0064, `kiosk_notices_mode`): not at
/// all, in the drawer, one title at a time in the status bar, or both.
enum KioskNoticesMode { off, drawer, header, both }

```

New: nothing.

(b) The constructor.

Old:

```dart
    this.kioskFitDay = true,
    this.kioskNoticesMode = KioskNoticesMode.both,
    this.kioskShowMatches = true,
    this.kioskShowUpcoming = true,
```

New:

```dart
    this.kioskFitDay = true,
    this.kioskShowUpcoming = true,
```

Old:

```dart
    this.kioskWeeksAhead = 1,
    this.kioskDrawerOpen = false,
    this.kioskDrawerColumns = 2,
    this.kioskNoticesShare = 40,
    this.kioskZapisPercent = 80,
    this.kioskNoticesRotationSeconds = 12,
    this.kioskLiveRotationSeconds = 12,
    this.kioskPanelEnabled = true,
    this.kioskPastDays = 0,
```

New:

```dart
    this.kioskWeeksAhead = 1,
    this.kioskZapisPercent = 80,
    this.kioskNoticesRotationSeconds = 12,
    this.kioskLiveRotationSeconds = 12,
    this.kioskPastDays = 0,
```

Old:

```dart
    this.kioskDutyBoard = false,
    this.kioskDutyDrawer = false,
    this.kioskDutyShare = 30,
    this.kioskDutyBandPosition
```

New:

```dart
    this.kioskDutyBoard = false,
    this.kioskDutyBandPosition
```

(c) The notices mode, its getters and `kioskShowMatches`. The paragraph about the list moves onto `kioskShowUpcoming`.

Old:

```dart
  /// What the kiosk's side drawer lists (0064): the active notices
  /// and the matches — of the current week plus [kioskWeeksBack] weeks
  /// back and (when [kioskShowUpcoming]) [kioskWeeksAhead] weeks ahead. A
  /// match being played takes the whole drawer when [kioskLiveMode].
  final KioskNoticesMode kioskNoticesMode;

  /// The drawer lists the notices.
  bool get kioskShowNotices =>
      kioskNoticesMode == KioskNoticesMode.drawer ||
      kioskNoticesMode == KioskNoticesMode.both;

  /// The status bar shows one notice's title at a time.
  bool get kioskNoticesInHeader =>
      kioskNoticesMode == KioskNoticesMode.header ||
      kioskNoticesMode == KioskNoticesMode.both;
  final bool kioskShowMatches;
  final bool kioskShowUpcoming;
```

New:

```dart
  /// The panels' match list (module `matches`, 0064) covers the current
  /// week plus [kioskWeeksBack] weeks back and, with this on,
  /// [kioskWeeksAhead] weeks ahead. A match being played takes over the
  /// panel holding the list when [kioskLiveMode].
  final bool kioskShowUpcoming;
```

(d) The duty's drawer card.

Old:

```dart
  /// board's day headers ([kioskDutyBoard]); a card with the duty and the
  /// plan in the side drawer ([kioskDutyDrawer]).
  final bool kioskDutyHeader;
  final bool kioskDutyBoard;
  final bool kioskDutyDrawer;

  /// Percent of the drawer's height the duty card takes (0073); the
  /// notices and the matches share the rest as before.
  final int kioskDutyShare;
```

New:

```dart
  /// board's day headers ([kioskDutyBoard]). The card with the duty and the
  /// plan is the panels' module `duty` ([kioskPanels]).
  final bool kioskDutyHeader;
  final bool kioskDutyBoard;
```

(e) The drawer's geometry and the notices' share.

Old (with the blank line after it; New is nothing):

```dart
  /// Whether the drawer is open when nobody has touched the kiosk for a
  /// minute (a live match opens it regardless); a visitor may open or
  /// close it meanwhile.
  final bool kioskDrawerOpen;

  /// How many of the board's day columns the open drawer covers (0064) —
  /// at most one fewer than [kioskVisibleDays], see `kioskDrawerWidthFor`.
  final int kioskDrawerColumns;

  /// Percent of the drawer's height the notices get beside the matches.
  final int kioskNoticesShare;

```

New: nothing.

(f) The switch for the whole drawer.

Old (with the blank line after it; New is nothing):

```dart
  /// The whole drawer on or off (0064); the options above matter only while
  /// it is on.
  final bool kioskPanelEnabled;

```

New: nothing.

(g) The visible-days doc.

Old:

```dart
  /// How many day columns the board fits on the whole screen (0064); the
  /// open drawer covers [kioskDrawerColumns] of them.
```

New:

```dart
  /// How many day columns the board fits on the whole screen (0064); an
  /// open panel covers its `days` of them (`kioskPanelWidths`).
```

(h) `fromJson`.

Old:

```dart
        kioskFitDay: json['kiosk_fit_day'] as bool? ?? true,
        kioskNoticesMode: KioskNoticesMode.values.firstWhere(
          (m) => m.name == json['kiosk_notices_mode'],
          orElse: () => KioskNoticesMode.both,
        ),
        kioskShowMatches: json['kiosk_show_matches'] as bool? ?? true,
        kioskShowUpcoming:
```

New:

```dart
        kioskFitDay: json['kiosk_fit_day'] as bool? ?? true,
        kioskShowUpcoming:
```

Old:

```dart
        kioskWeeksAhead: json['kiosk_weeks_ahead'] as int? ?? 1,
        kioskDrawerOpen: json['kiosk_drawer_open'] as bool? ?? false,
        kioskDrawerColumns: json['kiosk_drawer_columns'] as int? ?? 2,
        kioskNoticesShare: json['kiosk_notices_share'] as int? ?? 40,
        kioskZapisPercent:
```

New:

```dart
        kioskWeeksAhead: json['kiosk_weeks_ahead'] as int? ?? 1,
        kioskZapisPercent:
```

Old:

```dart
            json['kiosk_live_rotation_seconds'] as int? ?? 12,
        kioskPanelEnabled: json['kiosk_panel_enabled'] as bool? ?? true,
        kioskPastDays:
```

New:

```dart
            json['kiosk_live_rotation_seconds'] as int? ?? 12,
        kioskPastDays:
```

Old:

```dart
        kioskDutyBoard: json['kiosk_duty_board'] as bool? ?? false,
        kioskDutyDrawer: json['kiosk_duty_drawer'] as bool? ?? false,
        kioskDutyShare: json['kiosk_duty_share'] as int? ?? 30,
        kioskDutyBandPosition:
```

New:

```dart
        kioskDutyBoard: json['kiosk_duty_board'] as bool? ?? false,
        kioskDutyBandPosition:
```

- [ ] **Step 4: Remove the old arguments from the kiosk harness**

In `test/features/kiosk_test.dart`, the `ScheduleSettings(...)` call inside `shown()` in the side-drawer group's `app()` harness loses exactly these named arguments. Each one is unique in the file.

```dart
            kioskDrawerOpen: drawerOpen,
            kioskNoticesMode: switch ((showNotices, headerNotices)) {
              (true, true) => KioskNoticesMode.both,
              (true, false) => KioskNoticesMode.drawer,
              (false, true) => KioskNoticesMode.header,
              (false, false) => KioskNoticesMode.off,
            },
            kioskShowMatches: showMatches,
```

```dart
            kioskDrawerColumns: drawerColumns,
            kioskNoticesShare: share,
```

```dart
            kioskPanelEnabled: panelEnabled,
```

```dart
            kioskDutyDrawer: dutyDrawer,
            kioskDutyShare: dutyShare,
```

Nothing else in the call changes. The `kioskPanels:` and `kioskNoticesHeader:` arguments that Task 3 added stay. Task 3 builds those from the harness's own parameters, for example `kioskPanels: panels ?? kioskPanelsFromLegacy(panelEnabled: panelEnabled, drawerOpen: drawerOpen, drawerColumns: drawerColumns, noticesMode: showNotices ? 'drawer' : 'off', noticesShare: share, showMatches: showMatches, liveMode: liveMode, dutyDrawer: dutyDrawer, dutyShare: dutyShare)` and `kioskNoticesHeader: headerNotices`. So the removed arguments change nothing that a test sees.

- [ ] **Step 5: Drop harness parameters that now feed nothing**

```bash
cd /Users/mvazan/Home/rezervator && h=$(sed -n '/^    Widget app({$/,/home: KioskShell()/p' test/features/kiosk_test.dart) && for p in drawerOpen showNotices headerNotices showMatches drawerColumns share panelEnabled dutyDrawer dutyShare; do printf '%s %s\n' "$p" "$(printf '%s\n' "$h" | grep -cw "$p")"; done
```

Expected: every count is 2 or more, meaning a declaration plus a use in `kioskPanels:` or `kioskNoticesHeader:`. A count of 1 means the parameter is only declared.
- Delete its declaration line from the parameter list. For example, delete `      int share = 40,` for `share`.
- Then find its call sites with `grep -nw "<name>:" test/features/kiosk_test.dart` and delete that `<name>: …` argument at each one. For an inline call such as line 3417 today, delete the `, drawerColumns: 3` fragment.

- [ ] **Step 6: Simplify the admin harness**

In `test/features/kiosk_screen_test.dart`, Task 4 removed the only call `app(panelEnabled: false)` together with its test. The harness parameter goes too. If Task 4 already did this, skip the step.

Old:

```dart
    ScheduleSettings? settings,
    bool? panelEnabled,
    Venue? alleyVenue,
    http.Client? openMeteo,
  }) {
    final shown = settings ??
        (panelEnabled == null
            ? defaults0
            : ScheduleSettings(
                laneCount: 4,
                trainingWeekdays: const {1, 2, 4},
                bookingHorizonDays: 14,
                maxActiveReservations: 3,
                kioskPanelEnabled: panelEnabled,
              ));
```

New:

```dart
    ScheduleSettings? settings,
    Venue? alleyVenue,
    http.Client? openMeteo,
  }) {
    final shown = settings ?? defaults0;
```

- [ ] **Step 7: Run the check, the analyzer and the tests, expect PASS**

```bash
cd /Users/mvazan/Home/rezervator && grep -rnE "KioskNoticesMode|kioskShowNotices|kioskNoticesInHeader|kioskPanelEnabled|kioskDrawerOpen|kioskDrawerColumns|kioskNoticesShare|kioskShowMatches|kioskDutyDrawer|kioskDutyShare" lib test
```

Expected: no output. `kioskDrawerWidthFor` is Step 9's.

```bash
cd /Users/mvazan/Home/rezervator && grep -rnE "kiosk_(panel_enabled|drawer_open|drawer_columns|notices_mode|notices_share|show_matches|duty_drawer|duty_share)" lib test
```

Expected: only the eight keys of the new cached-row test in `test/domain/models_test.dart` (Task 4 Step 3 Edit 9 already rewrote the doc in `lib/data/providers.dart`).

Run: `cd /Users/mvazan/Home/rezervator && flutter analyze`

Expected: `No issues found!`

Run: `cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/domain/models_test.dart test/domain/kiosk_layout_test.dart test/features/kiosk_test.dart test/features/kiosk_screen_test.dart`

Expected: `All tests passed!`

Run: `cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test`

Expected: `All tests passed!`

- [ ] **Step 8: Commit**

```bash
cd /Users/mvazan/Home/rezervator && git add lib/domain/models.dart test/domain/models_test.dart test/features/kiosk_test.dart test/features/kiosk_screen_test.dart && git commit -m "refactor(kiosk): pryč staré sloupce postranního panelu z ScheduleSettings

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 9: Remove `kioskDrawerWidthFor`, if Task 3 left it**

```bash
cd /Users/mvazan/Home/rezervator && grep -rn "kioskDrawerWidthFor" lib test
```

If there is no output, skip to Step 10. The definition alone may remain, `lib/features/kiosk/kiosk_info_panel.dart:43` at HEAD. Any other hit is a Task 3 leftover. In that case, delete the definition from `lib/features/kiosk/kiosk_info_panel.dart`.

Old (with the blank line after it; New is nothing):

```dart
/// The drawer's width for a screen [screenWidth] wide: [columns] of the
/// board's [visibleDays] day columns (the board sizes them on the whole
/// screen), at least one and at most one fewer than all — so open or
/// closed, the board shows whole days only.
double kioskDrawerWidthFor(
  double screenWidth, {
  required int columns,
  required int visibleDays,
}) {
  final days = visibleDays < 2 ? 2 : visibleDays;
  final column = (screenWidth - calendarRulerWidth) / days;
  return columns.clamp(1, days - 1) * column;
}

```

New: nothing.

Then run `grep -n "calendarRulerWidth" lib/features/kiosk/kiosk_info_panel.dart`. If the only hit is the import, delete that line as well:

```dart
import '../schedule/widgets/calendar_board.dart' show calendarRulerWidth;
```

Then run the following and commit:

Run: `cd /Users/mvazan/Home/rezervator && grep -rn "kioskDrawerWidthFor" lib test`

Expected: no output.

Run: `cd /Users/mvazan/Home/rezervator && flutter analyze`

Expected: `No issues found!`

Run: `cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/features/kiosk_test.dart`

Expected: `All tests passed!`

```bash
cd /Users/mvazan/Home/rezervator && git add lib/features/kiosk/kiosk_info_panel.dart && git commit -m "refactor(kiosk): pryč kioskDrawerWidthFor, šířky panelů počítá kioskPanelWidths

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 10: Docs that still speak of one drawer**

`lib/data/providers.dart`, the doc of `Api.setKioskPanel`. If Task 4 already rewrote it, skip this edit.

Old:

```dart
  /// Writes the kiosk drawer's options (0064) — the keys of
  /// `schedule_settings` (`kiosk_notices_mode`, `kiosk_show_matches`,
  /// `kiosk_matches_history_days`, `kiosk_drawer_open`). Optimistic, same
  /// reasoning as [setKioskFitDay].
```

New:

```dart
  /// Writes Správa → Kiosk's options — the given columns of
  /// `schedule_settings`, `kiosk_panels` always whole (0077). Optimistic,
  /// same reasoning as [setKioskFitDay].
```

`lib/domain/models.dart` has two more doc comments.

Old:

```dart
  /// The kiosk's animations on their own: the drawer button breathes — a
  /// glow every few seconds (0065) — and the live-stream badge pulses (the
```

New:

```dart
  /// The kiosk's animations on their own: the panels' buttons breathe — a
  /// glow every few seconds (0065) — and the live-stream badge pulses (the
```

Old:

```dart
  /// How a match being played is drawn in the drawer (0064).
```

New:

```dart
  /// How a match being played is drawn in the panel holding the match
  /// list (0064).
```

Run: `cd /Users/mvazan/Home/rezervator && grep -rnE "kiosk_(panel_enabled|drawer_open|drawer_columns|notices_mode|notices_share|show_matches|duty_drawer|duty_share)" lib`

Expected: no output.

Run: `cd /Users/mvazan/Home/rezervator && flutter analyze`

Expected: `No issues found!`

```bash
cd /Users/mvazan/Home/rezervator && git add lib/data/providers.dart lib/domain/models.dart && git commit -m "docs(kiosk): komentáře mluví o dvou panelech, ne o jednom šuplíku

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```


### Task 6: QR kód Rezervátoru na Google Play (`kiosk_qr.dart`)

The „Jak začít“ card (Task 7) shows a QR code of the app's Google Play page. No QR package is added: the module matrix is generated once in the scratchpad with `qr` 3.0.2 from the pub cache and committed as a `const List<String>`; a small `CustomPainter` draws it black on a white tile in device pixels. The matrix below is the real output of the generator (version 4, 33 × 33, level L, mask 2) and was decoded back to the URL with macOS Core Image while drafting this plan.

**Files:**
- Create: `lib/features/kiosk/kiosk_qr.dart`
- Test: `test/features/kiosk_qr_test.dart` (new)
- Scratch only, never in the repo: `/private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/qrgen/pubspec.yaml`, `/private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/qrgen/bin/qrgen.dart`, `/private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/qrgen/decode.swift`

**Interfaces:**
- Consumes: nothing from Tasks 1–5 (independent). The test reads `UpdateScreen.playUrl` (`lib/features/auth/update_screen.dart`, `static const`) to keep the two URLs equal.
- Produces (`lib/features/kiosk/kiosk_qr.dart`):
  - `const kioskPlayUrl = 'https://play.google.com/store/apps/details?id=cz.kuzelky.rezervator';`
  - `const kioskPlayQrLabel = 'QR kód: Rezervátor na Google Play';` (semantics label; addition to the contract)
  - `const kioskQrQuietZone = 4;` (addition to the contract)
  - `const kioskPlayQr = <String>[…]` — 33 strings of 33 chars, `'#'` dark, `'.'` light
  - `double kioskQrTile(double size, double dpr, int modules)` — `modules` is the matrix side (33); the quiet zone is added inside: `m = ⌊size · dpr / (modules + 8)⌋`, returns `m · (modules + 8) / dpr`, or 0 when `m < 3`
  - `class KioskQr extends StatelessWidget { const KioskQr({super.key, required this.rows, required this.size, this.semanticLabel}); }` — takes exactly `kioskQrTile(size, dpr, rows.length)` × that, logical px

- [ ] **Step 1: Generate the matrix in the scratchpad (not in the repo)**

```bash
mkdir -p /private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/qrgen/bin
```

Create `/private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/qrgen/pubspec.yaml`:

```yaml
name: qrgen
publish_to: none
environment:
  sdk: ^3.10.0
dependencies:
  qr: 3.0.2
```

Create `/private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/qrgen/bin/qrgen.dart`:

```dart
// One-off generator of the kiosk's Google Play QR code (Rezervátor,
// lib/features/kiosk/kiosk_qr.dart). Not part of the app: run from this
// scratch directory with `dart pub get --offline && dart run bin/qrgen.dart`,
// paste the printed rows into kioskPlayQr.
import 'package:qr/qr.dart';

const url =
    'https://play.google.com/store/apps/details?id=cz.kuzelky.rezervator';

void main() {
  final code = QrCode.fromData(
    data: url,
    errorCorrectLevel: QrErrorCorrectLevel.L,
  );
  final image = QrImage(code);
  final n = image.moduleCount;
  print('// version ${image.typeNumber}, $n x $n, level L, '
      'mask ${image.maskPattern}');
  for (var r = 0; r < n; r++) {
    final row = StringBuffer();
    for (var c = 0; c < n; c++) {
      row.write(image.isDark(r, c) ? '#' : '.');
    }
    print("  '$row',");
  }
}
```

Run (offline — `qr-3.0.2` and `meta` are already in `~/.pub-cache`):

```bash
cd /private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/qrgen && dart pub get --offline && dart run bin/qrgen.dart
```

Expected output — a header line and exactly these 33 rows (they are the `kioskPlayQr` const of Step 5):

```text
// version 4, 33 x 33, level L, mask 2
  '#######...#.###.########..#######',
  '#.....#.#.#..#.##.#.#.....#.....#',
  '#.###.#.....#..##..###.#..#.###.#',
  '#.###.#.###.####.#.##.###.#.###.#',
  '#.###.#..#......#.##.#.#..#.###.#',
  '#.....#.##.##.##....###.#.#.....#',
  '#######.#.#.#.#.#.#.#.#.#.#######',
  '.........###..#...##.##..........',
  '#####.####.#.######.#....#.#.#.#.',
  '#####...#.#.#.#.##.##..#..#...###',
  '##....###.#..#.#......#..##.##.#.',
  '..#.##..#...#...#...#######.#.#..',
  '.#######.##.###..#.#..#..#.###...',
  '.###.#........#...####.#..#....##',
  '#.#..##.##.########.##...#..#..#.',
  '..#.#..###.#...#.....###.##...#..',
  '.######....#.##.##.#..####.##..#.',
  '##.#.#....#.#...##.######.#..#.##',
  '......#.#.#....####.##...#####.#.',
  '.###....#...#.#...#..#......#.#..',
  '....#.#.###.###..##...####.##..#.',
  '#..##..#.#....#.########..##.#.##',
  '#.#.###..####.##.#...#...#...#.#.',
  '#..#...#..##...##.#.##.#.#.####..',
  '#.##..##.###.##..#..#.########..#',
  '........###.##..#######.#...#.#.#',
  '#######.###..######.#..##.#.#.##.',
  '#.....#..#..#.###...#####...#####',
  '#.###.#.###.####.#......#####....',
  '#.###.#.###...#.#..##..#....##...',
  '#.###.#.#..###.#......#.#.#...##.',
  '#.....#.##.#........###..##..##..',
  '#######.#..##...##....###.##...#.',
```

- [ ] **Step 2: Decode the rows back to the URL (macOS Core Image)**

Create `/private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/qrgen/decode.swift`:

```swift
// Decodes rows.txt ('#' dark) with Core Image's QR detector, as a check
// that the generated matrix scans.
import CoreImage
import Foundation

let rows = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
  .split(separator: "\n").map(String.init)
let n = rows.count
let scale = 10, quiet = 4
let side = (n + 2 * quiet) * scale
var pixels = [UInt8](repeating: 255, count: side * side)
for (r, row) in rows.enumerated() {
  for (c, ch) in row.enumerated() where ch == "#" {
    for y in 0..<scale { for x in 0..<scale {
      pixels[((r + quiet) * scale + y) * side + (c + quiet) * scale + x] = 0
    } }
  }
}
let provider = CGDataProvider(data: Data(pixels) as CFData)!
let cg = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8,
  bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
  bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
  shouldInterpolate: false, intent: .defaultIntent)!
let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
for f in detector.features(in: CIImage(cgImage: cg)) {
  print((f as! CIQRCodeFeature).messageString ?? "nil")
}
```

Run:

```bash
cd /private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/qrgen && dart run bin/qrgen.dart | grep "^  '" | sed "s/^  '//; s/',$//" > rows.txt && swift decode.swift rows.txt
```

Expected: exactly one line, `https://play.google.com/store/apps/details?id=cz.kuzelky.rezervator`. Anything else (no line, another text) — stop: the matrix does not scan.

- [ ] **Step 3: Write the failing test**

Create `test/features/kiosk_qr_test.dart`:

```dart
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/features/auth/update_screen.dart';
import 'package:rezervator/features/kiosk/kiosk_qr.dart';

/// The kiosk's Google Play QR code (kiosk_qr.dart): a bundled matrix — no
/// decoder runs here, so its structure is checked against the standard
/// (version 4: finder, timing and alignment patterns, the dark module) —
/// and the tile that draws it, whole device pixels a module.
void main() {
  const n = 33;
  bool dark(int r, int c) => kioskPlayQr[r][c] == '#';

  group('kioskPlayQr', () {
    test('leads to the app\'s Google Play page, as the update screen', () {
      expect(kioskPlayUrl, UpdateScreen.playUrl);
    });

    test('is a square of version 4: 33 rows of 33 modules, # or .', () {
      expect(kioskPlayQr, hasLength(4 * 4 + 17));
      for (final row in kioskPlayQr) {
        expect(row, hasLength(n));
        expect(RegExp(r'^[#.]+$').hasMatch(row), isTrue, reason: row);
      }
    });

    test('has the three 7 × 7 finder patterns, each with its light '
        'separator', () {
      for (final (top, left) in [(0, 0), (0, n - 7), (n - 7, 0)]) {
        for (var i = 0; i < 7; i++) {
          for (var j = 0; j < 7; j++) {
            final ring = i == 0 || i == 6 || j == 0 || j == 6;
            final core = i >= 2 && i <= 4 && j >= 2 && j <= 4;
            expect(
              dark(top + i, left + j),
              ring || core,
              reason: 'finder at ($top, $left), module ($i, $j)',
            );
          }
        }
        // The separator: the light row and column on its inner sides.
        final sepRow = top == 0 ? 7 : n - 8;
        final sepCol = left == 0 ? 7 : n - 8;
        for (var k = 0; k < 8; k++) {
          expect(dark(sepRow, left == 0 ? k : n - 8 + k), isFalse);
          expect(dark(top == 0 ? k : n - 8 + k, sepCol), isFalse);
        }
      }
    });

    test('has the timing row and column between the finders: dark and '
        'light in turn, dark on the even modules', () {
      for (var k = 8; k < n - 8; k++) {
        expect(dark(6, k), k.isEven, reason: 'timing row, column $k');
        expect(dark(k, 6), k.isEven, reason: 'timing column, row $k');
      }
    });

    test('has version 4\'s alignment pattern at (26, 26) and the dark '
        'module at (25, 8)', () {
      for (var i = -2; i <= 2; i++) {
        for (var j = -2; j <= 2; j++) {
          final ring = i.abs() == 2 || j.abs() == 2;
          expect(dark(26 + i, 26 + j), ring || (i == 0 && j == 0));
        }
      }
      expect(dark(4 * 4 + 9, 8), isTrue);
    });
  });

  group('kioskQrTile', () {
    test('whole device pixels a module, the quiet zone included: 41 '
        'modules', () {
      expect(kioskQrTile(220, 1, n), 205); // 5 px a module
      expect(kioskQrTile(300, 1, n), 287); // 7
      expect(kioskQrTile(123, 1, n), 123); // 3
      // 1.5 device pixels to one: 8 device pixels a module.
      expect(kioskQrTile(220, 1.5, n), closeTo(328 / 1.5, 1e-9));
      for (final dpr in [1.0, 1.5, 2.0, 2.625, 3.0]) {
        for (var size = 100.0; size <= 320; size += 7.3) {
          final tile = kioskQrTile(size, dpr, n);
          if (tile == 0) continue;
          final device = tile * dpr;
          expect(device, closeTo(device.roundToDouble(), 1e-6));
          expect(device.round() % 41, 0, reason: 'size $size at $dpr');
          expect(tile, lessThanOrEqualTo(size + 1e-9));
        }
      }
    });

    test('0 under 3 device pixels a module', () {
      expect(kioskQrTile(122, 1, n), 0); // 2 px a module
      expect(kioskQrTile(81.9, 1.5, n), 0); // 2.99… px
      expect(kioskQrTile(82, 1.5, n), 82); // 3 px: drawn
    });

    test('a size that is itself a tile keeps its modules', () {
      for (final dpr in [1.0, 1.5, 2.625, 3.0]) {
        for (var m = 3; m < 12; m++) {
          final tile = m * 41 / dpr;
          expect(kioskQrTile(tile, dpr, n), closeTo(tile, 1e-9));
        }
      }
    });
  });

  group('KioskQr', () {
    Future<RenderRepaintBoundary> pump(
      WidgetTester tester, {
      required double size,
      double dpr = 1,
    }) async {
      tester.view.physicalSize = const Size(800, 600) * dpr;
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: key,
              child: KioskQr(
                rows: kioskPlayQr,
                size: size,
                semanticLabel: kioskPlayQrLabel,
              ),
            ),
          ),
        ),
      );
      return tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
    }

    testWidgets('takes the tile of whole modules that fits its size', (
      tester,
    ) async {
      await pump(tester, size: 220);
      expect(tester.getSize(find.byType(KioskQr)), const Size(205, 205));
      await pump(tester, size: 220, dpr: 1.5);
      expect(
        tester.getSize(find.byType(KioskQr)).width,
        closeTo(328 / 1.5, 1e-9),
      );
    });

    testWidgets('is read out as what it is', (tester) async {
      await pump(tester, size: 220);
      expect(find.bySemanticsLabel(kioskPlayQrLabel), findsOneWidget);
    });

    testWidgets('draws black modules on a white tile, the quiet zone '
        'white, every module a whole 5 × 5 device pixels', (tester) async {
      final boundary = await pump(tester, size: 220);
      final bytes = await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        image.dispose();
        return data!;
      });
      const side = 205;
      int luma(int x, int y) => bytes!.getUint8((y * side + x) * 4);
      // Every pixel of every module, by the matrix; the quiet zone white
      // (its rounded corners left aside).
      for (var y = 0; y < side; y++) {
        for (var x = 0; x < side; x++) {
          final r = y ~/ 5 - kioskQrQuietZone;
          final c = x ~/ 5 - kioskQrQuietZone;
          final inCode = r >= 0 && r < n && c >= 0 && c < n;
          final corner =
              (x < 8 || x >= side - 8) && (y < 8 || y >= side - 8);
          if (corner) continue;
          expect(
            luma(x, y),
            inCode && dark(r, c) ? 0 : 255,
            reason: 'pixel ($x, $y)',
          );
        }
      }
    });
  });
}
```

- [ ] **Step 4: Run it — expect FAIL**

```bash
cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/features/kiosk_qr_test.dart
```

Expected: FAIL — compilation error `Error when reading 'lib/features/kiosk/kiosk_qr.dart': No such file or directory`, „Some tests failed.“

- [ ] **Step 5: Implement `lib/features/kiosk/kiosk_qr.dart`**

```dart
/// The kiosk's QR code of Rezervátor on Google Play, for the „Jak začít“
/// card (kiosk_guide.dart): its modules bundled as text, drawn as a black
/// code on a white tile — no QR package, nothing encoded on the device.
///
/// Generated once, outside the app, with the Dart package qr 3.0.2
/// (pub.dev, BSD-3-Clause) from [kioskPlayUrl]: byte mode, error correction
/// level L — a screen is never scratched or smudged like a printed code,
/// so the lowest level gives the largest modules — which makes version 4,
/// 33 × 33 modules, mask 2 (the package's pick). To generate it again: a
/// scratch package depending on `qr: 3.0.2`, `QrImage(QrCode.fromData(data:
/// kioskPlayUrl, errorCorrectLevel: QrErrorCorrectLevel.L))`, one string per
/// row of `isDark(row, col)`. Checked by decoding the rows back to the URL
/// (macOS Core Image's QR detector); after any change, scan the kiosk's
/// screen with a phone before a release.
library;

import 'package:flutter/material.dart';

/// Where the code leads: Rezervátor's page on Google Play (as
/// UpdateScreen.playUrl).
const kioskPlayUrl =
    'https://play.google.com/store/apps/details?id=cz.kuzelky.rezervator';

/// What a screen reader says for the code.
const kioskPlayQrLabel = 'QR kód: Rezervátor na Google Play';

/// The light modules around a code that a scanner needs to find it (the
/// standard's quiet zone), on every side.
const kioskQrQuietZone = 4;

/// [kioskPlayUrl] as a QR code, one string per row, top to bottom: '#' a
/// dark module, '.' a light one.
const kioskPlayQr = <String>[
  '#######...#.###.########..#######',
  '#.....#.#.#..#.##.#.#.....#.....#',
  '#.###.#.....#..##..###.#..#.###.#',
  '#.###.#.###.####.#.##.###.#.###.#',
  '#.###.#..#......#.##.#.#..#.###.#',
  '#.....#.##.##.##....###.#.#.....#',
  '#######.#.#.#.#.#.#.#.#.#.#######',
  '.........###..#...##.##..........',
  '#####.####.#.######.#....#.#.#.#.',
  '#####...#.#.#.#.##.##..#..#...###',
  '##....###.#..#.#......#..##.##.#.',
  '..#.##..#...#...#...#######.#.#..',
  '.#######.##.###..#.#..#..#.###...',
  '.###.#........#...####.#..#....##',
  '#.#..##.##.########.##...#..#..#.',
  '..#.#..###.#...#.....###.##...#..',
  '.######....#.##.##.#..####.##..#.',
  '##.#.#....#.#...##.######.#..#.##',
  '......#.#.#....####.##...#####.#.',
  '.###....#...#.#...#..#......#.#..',
  '....#.#.###.###..##...####.##..#.',
  '#..##..#.#....#.########..##.#.##',
  '#.#.###..####.##.#...#...#...#.#.',
  '#..#...#..##...##.#.##.#.#.####..',
  '#.##..##.###.##..#..#.########..#',
  '........###.##..#######.#...#.#.#',
  '#######.###..######.#..##.#.#.##.',
  '#.....#..#..#.###...#####...#####',
  '#.###.#.###.####.#......#####....',
  '#.###.#.###...#.#..##..#....##...',
  '#.###.#.#..###.#......#.#.#...##.',
  '#.....#.##.#........###..##..##..',
  '#######.#..##...##....###.##...#.',
];

/// The side of the tile for a code of [modules] × [modules] (its quiet zone
/// around it), in logical pixels, given [size] logical pixels of room on a
/// screen of [dpr] device pixels to one: every module the same whole number
/// of device pixels, m = ⌊size · dpr / (modules + 8)⌋, so no module is a
/// pixel wider than its neighbour. 0 when m < 3 — too small to scan from a
/// step away.
double kioskQrTile(double size, double dpr, int modules) {
  final span = modules + 2 * kioskQrQuietZone;
  // The epsilon keeps a size that is itself a tile (m · span / dpr) from
  // flooring a module short on the division's rounding.
  final m = (size * dpr / span + 1e-9).floor();
  return m < 3 ? 0 : m * span / dpr;
}

/// A QR code of [rows] (as [kioskPlayQr]): black modules on a white tile
/// with the quiet zone, in either kiosk theme — a light code on a dark card
/// is one that some scanners do not read. As large as fits [size]
/// ([kioskQrTile]), drawn in device pixels without anti-aliasing, so the
/// edges are sharp even at the web kiosk's lower resolution.
class KioskQr extends StatelessWidget {
  const KioskQr({
    super.key,
    required this.rows,
    required this.size,
    this.semanticLabel,
  });

  final List<String> rows;

  /// The room the tile may take, in logical pixels.
  final double size;

  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final tile = kioskQrTile(size, dpr, rows.length);
    return Semantics(
      label: semanticLabel,
      image: true,
      child: SizedBox.square(
        dimension: tile,
        child: tile == 0
            ? null
            : CustomPaint(painter: _QrPainter(rows: rows, dpr: dpr)),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  const _QrPainter({required this.rows, required this.dpr});

  final List<String> rows;
  final double dpr;

  @override
  void paint(Canvas canvas, Size size) {
    final span = rows.length + 2 * kioskQrQuietZone;
    // One module in device pixels — a whole number by kioskQrTile.
    final m = (size.width * dpr / span).roundToDouble();
    canvas.save();
    // Device pixels from here on: whole modules, whose edges snap to the
    // pixels without anti-aliasing.
    canvas.scale(1 / dpr);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, span * m, span * m),
        // Rounded within the quiet zone, never into the code.
        Radius.circular(m * 1.5),
      ),
      Paint()..color = Colors.white,
    );
    final dark = Path();
    for (var r = 0; r < rows.length; r++) {
      final row = rows[r];
      for (var c = 0; c < row.length; c++) {
        if (row.codeUnitAt(c) != 0x23) continue; // '#'
        dark.addRect(
          Rect.fromLTWH(
            (c + kioskQrQuietZone) * m,
            (r + kioskQrQuietZone) * m,
            m,
            m,
          ),
        );
      }
    }
    canvas.drawPath(
      dark,
      Paint()
        ..color = Colors.black
        // Anti-aliased, two modules side by side would show a hairline
        // seam where their edges meet.
        ..isAntiAlias = false,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.rows != rows || old.dpr != dpr;
}
```

- [ ] **Step 6: Check the committed rows against the generator**

```bash
diff <(cd /private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/qrgen && dart run bin/qrgen.dart | grep "^  '") <(grep "^  '" /Users/mvazan/Home/rezervator/lib/features/kiosk/kiosk_qr.dart) && echo ROWS-MATCH
```

Expected: `ROWS-MATCH` and no diff lines.

- [ ] **Step 7: Run the tests and the analyzer — expect PASS**

```bash
cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/features/kiosk_qr_test.dart && flutter analyze
```

Expected: `+11: All tests passed!`; analyzer `No issues found!`. (The pixel test renders the tile at 1 device pixel to one through `RenderRepaintBoundary.toImage` inside `tester.runAsync` and checks every pixel of every module, the rounded corners left aside.)

- [ ] **Step 8: Commit**

```bash
cd /Users/mvazan/Home/rezervator
git add lib/features/kiosk/kiosk_qr.dart test/features/kiosk_qr_test.dart
git commit -m "$(cat <<'EOF'
feat(kiosk): QR kód Rezervátoru na Google Play

Matice kódu (verze 4, 33 × 33, úroveň L) vygenerovaná jednou balíčkem
qr 3.0.2 mimo projekt a uložená jako text — žádný nový balíček. KioskQr
ji kreslí černě na bílé dlaždici s tichou zónou 4 modulů, v celých
pixelech zařízení na modul a bez vyhlazování.
Testy: struktura matice (vyhledávací, časovací a zarovnávací vzory),
velikost dlaždice při různých hustotách pixelů, pixely kresby.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

### Task 7: Karta „Jak začít“, dialog a modul `guide` v panelech

The guide card (`KioskGuideCard`, a `KioskCard` titled „JAK ZAČÍT“ with `Icons.lightbulb_outline`), its dialog (`showKioskGuide`, the whole text and a 300 px QR code), and the wiring: `KioskPanelView` draws the card for `KioskModule.guide` (replacing Task 3's placeholder) and the shell opens the dialog through `_touchable`.

Fit, as measured with Manrope while drafting (1920 × 1080, 8 days on the screen; a 2-day panel is 468.5 × 981 px, the card 444.5 px wide): at 45 % beside a second module the card is 425.25 px tall and the code sits beside the second paragraph at 164 px (4 px a module — the text column's 200 px caps it at 8 days; at 7 days it is 205 px); at 35 % no code fits and the paragraph says „ťukni pro QR kód“, whole; at 30 % the text is cut with „Více“; a 1-day panel with the guide alone puts the code under the paragraph (164 px).

`kiosk_guide.dart` imports `KioskCard` from `kiosk_info_panel.dart`, and from Step 9 on `kiosk_info_panel.dart` imports `KioskGuideCard` from `kiosk_guide.dart` — a mutual import, legal in Dart, forced by the contract keeping `KioskCard` in `kiosk_info_panel.dart` (Task 12's `kiosk_week.dart` does the same).

**Files:**
- Create: `lib/features/kiosk/kiosk_guide.dart`
- Modify: `lib/features/kiosk/kiosk_info_panel.dart` (`KioskPanelView`: import, `onOpenGuide`, the `KioskModule.guide` arm)
- Modify: `lib/features/kiosk/kiosk_shell.dart` (import, `_openGuide`, `onOpenGuide:` in the `panel(...)` helper)
- Test: `test/features/kiosk_guide_test.dart` (new; its own Manrope-loaded harness, the shell's provider overrides copied from `kiosk_test.dart`'s side-drawer `app()`)

**Interfaces:**
- Consumes:
  - Task 2 (`lib/domain/kiosk_layout.dart`): `KioskModule`, `PanelSide`, `KioskPanel`, `KioskModulePlacement`, `KioskPanels` (const constructors); `ScheduleSettings.kioskPanels`, `ScheduleSettings.kioskVisibleDays`.
  - Task 3 (`lib/features/kiosk/kiosk_info_panel.dart`): `class KioskCard({required IconData icon, required String title, required Widget child, bool fill = false, Widget? action})`; `KioskPanelContent({required side, required entries, notices, hasMatches, live, duty})`; `KioskPanelEntry(KioskModule module, int share)`; `KioskPanelView({side, width, content, open, hidden, onOpenNotice, onOpenMatch, onPlay, resetToken, boardDays, showLive, onShowLive})` whose `card(KioskModule)` switch has `KioskModule.guide => const SizedBox.shrink(),`; `kioskPanelContentProvider(side)` listing `guide` always. Shell (`kiosk_shell.dart`): `panel(...)` helper passing `onOpenMatch: _openMatch,`, `_touchable`, `kioskReserveLabel`.
  - Task 6: `kioskPlayQr`, `kioskPlayQrLabel`, `kioskQrTile`, `KioskQr`.
- Produces (`lib/features/kiosk/kiosk_guide.dart`):
  - `class KioskGuideCard extends StatelessWidget { const KioskGuideCard({super.key, required this.onOpen}); final VoidCallback onOpen; }`
  - `Future<void> showKioskGuide(BuildContext context, {required Widget Function(Widget child) wrap})`
  - `class KioskGuideDialog extends StatelessWidget` (addition)
  - consts `kioskGuideSteps` (`List<String>`, the three steps without numbers), `kioskGuideMobile` (the second paragraph with „(QR)“); additions: `kioskGuideStepsTitle`, `kioskGuideMobileTitle`, `kioskGuideMobileTap` (the variant with „— ťukni pro QR kód —“), `kioskGuideWeb` (`'rezervator.online'`, drawn bold)
  - `KioskPanelView` gains `final VoidCallback? onOpenGuide;` (addition to the contract's parameter list; Task 12 adds its own callback the same way)

- [ ] **Step 1: Check Task 3's anchors**

```bash
cd /Users/mvazan/Home/rezervator && grep -n "^class KioskCard\|KioskModule.guide => const SizedBox.shrink(),\|required this.onOpenNotice," lib/features/kiosk/kiosk_info_panel.dart && grep -n "onOpenMatch: _openMatch," lib/features/kiosk/kiosk_shell.dart
```

Expected: four lines in all — from `kiosk_info_panel.dart` `required this.onOpenNotice,` (`KioskPanelView`'s constructor), `KioskModule.guide => const SizedBox.shrink(),` and `class KioskCard extends StatelessWidget {`; from the shell `onOpenMatch: _openMatch,` once. If any is missing, Task 3 is not done — stop.

- [ ] **Step 2: Write the failing tests of the card and the dialog**

Create `test/features/kiosk_guide_test.dart`:

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/theme.dart';
import 'package:rezervator/features/kiosk/kiosk_guide.dart';
import 'package:rezervator/features/kiosk/kiosk_qr.dart';
import 'package:rezervator/features/kiosk/kiosk_shell.dart';
import 'package:rezervator/features/schedule/widgets/calendar_board.dart'
    show calendarRulerWidth;

/// The app's own font: the test font's glyphs are wider than Manrope's, so
/// a fit measured against it would not be the kiosk's.
Future<void> _loadManrope() async {
  final loader = FontLoader(appFontFamily);
  for (final weight in ['Regular', 'Medium', 'Bold', 'ExtraBold']) {
    final bytes = File('assets/fonts/Manrope-$weight.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

/// „Jak začít“ (module `guide`, 0077): the card's fit on a Full HD kiosk —
/// the QR code beside the second paragraph, under it, or left out with the
/// text sending a visitor to the tap — the dialog with the whole text and
/// the large code, and the card in a panel and in the shell.
void main() {
  setUpAll(_loadManrope);

  // One day column of a Full HD kiosk with 8 days on the screen; a panel
  // is whole columns of it (kioskPanelWidths).
  const column = (1920 - calendarRulerWidth) / 8;
  // The shell's panel at 1080: the status bar (96) and the idle bar (3)
  // take the rest.
  const panelHeight = 981.0;
  // A panel's padding (12 around) and the gap between two modules.
  const pad = 12.0;

  /// The guide's card as the panel lays it out: [days] columns wide, its
  /// [share] of the panel shared with one module more (100 = alone).
  Size cardSize({required int days, required int share}) => Size(
    days * column - 2 * pad,
    share == 100
        ? panelHeight - 2 * pad
        : (panelHeight - 2 * pad - pad) * share / 100,
  );

  void fullHd(WidgetTester tester, {double dpr = 1}) {
    tester.view.physicalSize = const Size(1920, 1080) * dpr;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpCard(
    WidgetTester tester,
    Size size, {
    VoidCallback? onOpen,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox.fromSize(
              size: size,
              child: KioskGuideCard(onOpen: onOpen ?? () {}),
            ),
          ),
        ),
      ),
    );
  }

  final qr = find.byType(KioskQr);
  final withQr = find.text(kioskGuideMobile);
  final tapHint = find.text(kioskGuideMobileTap);
  final more = find.text('Více');

  group('KioskGuideCard', () {
    test('the first step names the kiosk\'s button as it reads', () {
      expect(kioskGuideSteps.first, contains('„$kioskReserveLabel“'));
    });

    testWidgets('2 of 8 days at 45 %: the QR code beside the second '
        'paragraph, the text whole', (tester) async {
      fullHd(tester);
      await pumpCard(tester, cardSize(days: 2, share: 45));
      expect(qr, findsOneWidget);
      expect(withQr, findsOneWidget);
      expect(tapHint, findsNothing);
      expect(more, findsNothing);
      final code = tester.getRect(qr);
      final text = tester.getRect(withQr);
      expect(code.width, greaterThanOrEqualTo(120));
      // Beside: right of the text, the text column at least 200 wide.
      expect(code.left, greaterThan(text.right));
      expect(text.width, greaterThanOrEqualTo(200));
      // Whole device pixels a module: 41 of them, quiet zone included.
      expect(code.width % 41, 0);
    });

    testWidgets('at 1.5 device pixels to one the tile is still whole device '
        'pixels a module', (tester) async {
      fullHd(tester, dpr: 1.5);
      await pumpCard(tester, cardSize(days: 2, share: 45));
      final device = tester.getSize(qr).width * 1.5;
      expect(device, closeTo(device.roundToDouble(), 1e-6));
      expect(device.round() % 41, 0);
    });

    testWidgets('35 %: no room for the code — the text sends a visitor to '
        'the tap, whole', (tester) async {
      fullHd(tester);
      await pumpCard(tester, cardSize(days: 2, share: 35));
      expect(qr, findsNothing);
      expect(withQr, findsNothing);
      expect(tapHint, findsOneWidget);
      expect(more, findsNothing);
    });

    testWidgets('30 %: the text itself is cut, faded, with „Více“', (
      tester,
    ) async {
      fullHd(tester);
      await pumpCard(tester, cardSize(days: 2, share: 30));
      expect(qr, findsNothing);
      expect(tapHint, findsOneWidget);
      expect(more, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('one narrow day alone: the code under the paragraph', (
      tester,
    ) async {
      fullHd(tester);
      await pumpCard(tester, cardSize(days: 1, share: 100));
      expect(qr, findsOneWidget);
      expect(withQr, findsOneWidget);
      expect(
        tester.getRect(qr).top,
        greaterThan(tester.getRect(withQr).bottom),
      );
      expect(tester.getSize(qr).width, greaterThanOrEqualTo(120));
    });

    testWidgets('a tap anywhere on the card opens the guide', (tester) async {
      fullHd(tester);
      var opened = 0;
      await pumpCard(
        tester,
        cardSize(days: 2, share: 30),
        onOpen: () => opened++,
      );
      await tester.tap(find.text('JAK ZAČÍT'));
      await tester.tap(more);
      expect(opened, 2);
    });
  });

  group('showKioskGuide', () {
    testWidgets('the whole text, the code at 300 px, in the theme [wrap] '
        'gives it; „Zavřít“ closes it', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showKioskGuide(
                  context,
                  wrap: (child) =>
                      Theme(data: buildTheme(Brightness.dark), child: child),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final dialog = find.byType(AlertDialog);
      expect(find.text('Jak začít'), findsOneWidget);
      expect(find.text(kioskGuideStepsTitle), findsOneWidget);
      for (final (i, step) in kioskGuideSteps.indexed) {
        expect(find.text('${i + 1}. $step'), findsOneWidget);
      }
      expect(find.text(kioskGuideMobileTitle), findsOneWidget);
      expect(withQr, findsOneWidget);
      // 300 px of room: 7 px a module.
      expect(tester.getSize(qr), const Size(287, 287));
      expect(
        Theme.of(tester.element(dialog)).brightness,
        Brightness.dark,
      );

      await tester.tap(find.text('Zavřít'));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
    });
  });
}
```

- [ ] **Step 3: Run them — expect FAIL**

```bash
cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/features/kiosk_guide_test.dart
```

Expected: FAIL — compilation error `Error when reading 'lib/features/kiosk/kiosk_guide.dart': No such file or directory`.

- [ ] **Step 4: Implement `lib/features/kiosk/kiosk_guide.dart`**

```dart
/// „Jak začít“ on the kiosk (the panels' module `guide`, 0077): how to book
/// a training at the wall tablet, and where else Rezervátor is — the
/// Android app, with its Google Play QR code (kiosk_qr.dart), and the web.
/// One page of fixed text, no turning; a tap opens it whole with a large
/// code ([showKioskGuide]). Display only, like the rest of the panels.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'kiosk_info_panel.dart' show KioskCard;
import 'kiosk_qr.dart';

/// The first paragraph: booking here, step by step.
const kioskGuideStepsTitle = 'Rezervace na kiosku';
const kioskGuideSteps = <String>[
  'Ťukni na „Rezervace tréninku“ a najdi své jméno.',
  'Ťukni na volnou dráhu v tabuli a potvrď.',
  // Only with an account: a player without one (0022) has no e-mail and
  // no app, and nothing comes.
  'Máš-li v Rezervátoru účet, přijde ti potvrzení — v aplikaci, a když ji '
      'nepoužíváš, e-mailem s odkazem na zrušení.',
];

/// The second paragraph: Rezervátor beyond the kiosk.
const kioskGuideMobileTitle = 'Rezervátor i v mobilu';

/// The second paragraph's text with the QR code beside or under it.
const kioskGuideMobile =
    'Rezervace, zrušení a upozornění odkudkoli: aplikace pro Android (QR) '
    'nebo web rezervator.online.';

/// The same when the card has no room for the code: the tap shows it.
const kioskGuideMobileTap =
    'Rezervace, zrušení a upozornění odkudkoli: aplikace pro Android — '
    'ťukni pro QR kód — nebo web rezervator.online.';

/// Drawn bold in either text.
const kioskGuideWeb = 'rezervator.online';

const _headingStyle = TextStyle(fontSize: 18, fontWeight: FontWeight.w800);
// Nástěnka's body.
const _bodyStyle = TextStyle(fontSize: 16, height: 1.3);
const _headingGap = 6.0;
const _stepGap = 4.0;
const _paragraphGap = 14.0;

/// Between the text and the code beside or under it.
const _qrGap = 12.0;

/// The code's largest and smallest tile in the card (the dialog's is
/// larger), and the least the text keeps beside it.
const _qrMax = 220.0;
const _qrMin = 120.0;
const _textMin = 200.0;

/// The „Více“ line under a cut text (as Nástěnka's).
const _footerHeight = 32.0;

/// Where the card puts the QR code.
enum _QrPlace { beside, under, none }

/// The card: the two paragraphs, the code beside the second one when the
/// card is wide and tall enough for a tile of at least [_qrMin] (whole
/// device pixels a module, [kioskQrTile]), under it when only the height
/// allows, else none — the text then sends a visitor to the tap. A text
/// taller than the card is cut, faded, with „Více“. A tap anywhere opens
/// the whole of it ([onOpen]).
class KioskGuideCard extends StatelessWidget {
  const KioskGuideCard({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onOpen,
      child: KioskCard(
        icon: Icons.lightbulb_outline,
        title: 'JAK ZAČÍT',
        fill: true,
        child: LayoutBuilder(
          builder: (context, box) {
            final fit = _fit(context, box);
            final text = _GuideText(qr: fit.place, qrSize: fit.qrSize);
            if (!fit.cut) {
              return Align(alignment: Alignment.topLeft, child: text);
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ShaderMask(
                    // The last lines fade out: the text goes on.
                    shaderCallback: (rect) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0.8, 1],
                      colors: [Colors.white, Colors.transparent],
                    ).createShader(rect),
                    blendMode: BlendMode.dstIn,
                    child: SingleChildScrollView(
                      physics: const NeverScrollableScrollPhysics(),
                      child: text,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: _footerHeight - 8,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        'Více',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: scheme.primary,
                        ),
                      ),
                      Icon(Icons.expand_more, size: 20, color: scheme.primary),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Where the code goes in [box] (the card's interior), how much room it
  /// gets, and whether the text is cut. Measured with the styles the text
  /// is drawn in, merged into the ambient one, at the visitor's text size.
  ({_QrPlace place, double qrSize, bool cut}) _fit(
    BuildContext context,
    BoxConstraints box,
  ) {
    final base = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    double height(InlineSpan span, double width) {
      final painter = TextPainter(
        text: span,
        textDirection: direction,
        textScaler: scaler,
      )..layout(maxWidth: math.max(width, 0));
      final h = painter.height;
      painter.dispose();
      return h;
    }

    TextSpan plain(String text, TextStyle style) =>
        TextSpan(text: text, style: base.merge(style));
    double mobile(double width, String text) =>
        height(plain(kioskGuideMobileTitle, _headingStyle), width) +
        _headingGap +
        height(_mobileSpan(text, base.merge(_bodyStyle)), width);

    final width = box.maxWidth;
    final room = box.hasBoundedHeight ? box.maxHeight : double.infinity;
    var steps =
        height(plain(kioskGuideStepsTitle, _headingStyle), width) + _headingGap;
    for (final (i, step) in kioskGuideSteps.indexed) {
      if (i > 0) steps += _stepGap;
      steps += height(plain('${i + 1}. $step', _bodyStyle), width);
    }
    final left = room - steps - _paragraphGap;
    bool shown(double size) =>
        kioskQrTile(size, dpr, kioskPlayQr.length) >= _qrMin;

    // Beside the second paragraph: as large as the height left and the
    // text's least width allow.
    final beside = math.min(_qrMax, math.min(left, width - _qrGap - _textMin));
    if (shown(beside)) {
      final tile = kioskQrTile(beside, dpr, kioskPlayQr.length);
      if (mobile(width - _qrGap - tile, kioskGuideMobile) <= left) {
        return (place: _QrPlace.beside, qrSize: beside, cut: false);
      }
    }
    // Under it, the paragraph at the card's width.
    final text = mobile(width, kioskGuideMobile);
    final under = math.min(_qrMax, math.min(left - text - _qrGap, width));
    if (shown(under)) {
      return (place: _QrPlace.under, qrSize: under, cut: false);
    }
    return (
      place: _QrPlace.none,
      qrSize: 0,
      cut: mobile(width, kioskGuideMobileTap) > left,
    );
  }
}

/// [text] with [kioskGuideWeb] in it drawn bold.
TextSpan _mobileSpan(String text, TextStyle? style) {
  final at = text.indexOf(kioskGuideWeb);
  return TextSpan(
    style: style,
    children: [
      TextSpan(text: text.substring(0, at)),
      const TextSpan(
        text: kioskGuideWeb,
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
      TextSpan(text: text.substring(at + kioskGuideWeb.length)),
    ],
  );
}

/// The two paragraphs, the code [qr] (beside or under the second one, at
/// [qrSize]) or none — the card's and the dialog's.
class _GuideText extends StatelessWidget {
  const _GuideText({required this.qr, required this.qrSize});

  final _QrPlace qr;
  final double qrSize;

  @override
  Widget build(BuildContext context) {
    final code = KioskQr(
      rows: kioskPlayQr,
      size: qrSize,
      semanticLabel: kioskPlayQrLabel,
    );
    final mobile = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(kioskGuideMobileTitle, style: _headingStyle),
        const SizedBox(height: _headingGap),
        Text.rich(
          _mobileSpan(
            qr == _QrPlace.none ? kioskGuideMobileTap : kioskGuideMobile,
            null,
          ),
          style: _bodyStyle,
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(kioskGuideStepsTitle, style: _headingStyle),
        const SizedBox(height: _headingGap),
        for (final (i, step) in kioskGuideSteps.indexed) ...[
          if (i > 0) const SizedBox(height: _stepGap),
          Text('${i + 1}. $step', style: _bodyStyle),
        ],
        const SizedBox(height: _paragraphGap),
        switch (qr) {
          _QrPlace.beside => Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: mobile),
              const SizedBox(width: _qrGap),
              code,
            ],
          ),
          _QrPlace.under => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              mobile,
              const SizedBox(height: _qrGap),
              Center(child: code),
            ],
          ),
          _QrPlace.none => mobile,
        },
      ],
    );
  }
}

/// Opens „Jak začít“ over the kiosk: the whole text and the code at 300 px.
/// [wrap] is the shell's: the kiosk's theme, and a touch on the dialog
/// counts for the idle timer — whose reset closes it, with every other
/// dialog.
Future<void> showKioskGuide(
  BuildContext context, {
  required Widget Function(Widget child) wrap,
}) => showDialog<void>(
  context: context,
  builder: (context) => wrap(const KioskGuideDialog()),
);

/// „Jak začít“ whole: both paragraphs and the code under them, large.
class KioskGuideDialog extends StatelessWidget {
  const KioskGuideDialog({super.key});

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Jak začít'),
    content: const SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: _GuideText(qr: _QrPlace.under, qrSize: 300),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Zavřít'),
      ),
    ],
  );
}
```

- [ ] **Step 5: Run the tests and the analyzer — expect PASS**

```bash
cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/features/kiosk_guide_test.dart && flutter analyze
```

Expected: `+8: All tests passed!`; analyzer `No issues found!`.

- [ ] **Step 6: Commit the card and the dialog**

```bash
cd /Users/mvazan/Home/rezervator
git add lib/features/kiosk/kiosk_guide.dart test/features/kiosk_guide_test.dart
git commit -m "$(cat <<'EOF'
feat(kiosk): karta „Jak začít“ s QR kódem a dialogem

Pevný text: rezervace na kiosku ve třech krocích a Rezervátor v mobilu
(aplikace pro Android, web rezervator.online). QR kód stojí vedle
druhého odstavce, když se vejde dlaždice aspoň 120 px a text si nechá
200 px; jinak pod ním, nebo vůbec — pak text zve „ťukni pro QR kód“.
Co se nevejde, karta ořízne do ztracena s „Více“. Ťuknutí otevře celý
návod s kódem 300 px.
Testy: rozvržení na Full HD (2 z 8 dnů: 45 % → kód vedle textu, 35 % →
odkaz na ťuknutí, 30 % → „Více“; 1 den → kód pod textem), dialog.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 7: Write the failing tests of the wiring (panel and shell)**

In `test/features/kiosk_guide_test.dart`, replace the imports

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/theme.dart';
import 'package:rezervator/features/kiosk/kiosk_guide.dart';
import 'package:rezervator/features/kiosk/kiosk_qr.dart';
```

with

```dart
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/theme.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/kiosk_layout.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/kiosk/kiosk_connection.dart';
import 'package:rezervator/features/kiosk/kiosk_guide.dart';
import 'package:rezervator/features/kiosk/kiosk_info_panel.dart';
import 'package:rezervator/features/kiosk/kiosk_qr.dart';
```

and replace the end of the file

```dart
      await tester.tap(find.text('Zavřít'));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
    });
  });
}
```

with

```dart
      await tester.tap(find.text('Zavřít'));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
    });
  });

  group('in the panels', () {
    Message notice() => Message(
      id: 'n1',
      kind: MessageKind.notice,
      audience: MessageAudience.all,
      authorId: 'a',
      authorRole: MessageAuthorRole.admin,
      onDate: null,
      blockId: null,
      title: 'Brigáda',
      body: 'Sejdeme se v devět.',
      expiresAt: null,
      notify: true,
      showOnKiosk: true,
      createdAt: DateTime(2026, 9, 1),
      updatedAt: DateTime(2026, 9, 1),
    );

    testWidgets('KioskPanelView: the guide takes its share and opens on a '
        'tap', (tester) async {
      fullHd(tester);
      var opened = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(
              (ref) => Stream.value(
                const ScheduleSettings(
                  laneCount: 2,
                  trainingWeekdays: {1, 2, 3, 4, 5, 6, 7},
                  bookingHorizonDays: 14,
                  maxActiveReservations: 3,
                ),
              ),
            ),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.dark),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  height: panelHeight,
                  child: KioskPanelView(
                    side: PanelSide.left,
                    width: 2 * column,
                    open: true,
                    content: KioskPanelContent(
                      side: PanelSide.left,
                      entries: const [
                        KioskPanelEntry(KioskModule.guide, 45),
                        KioskPanelEntry(KioskModule.notices, 55),
                      ],
                      notices: [notice()],
                    ),
                    onOpenNotice: (_) {},
                    onOpenMatch: (_) {},
                    onOpenGuide: () => opened++,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final card = find.byType(KioskGuideCard);
      final want = cardSize(days: 2, share: 45);
      expect(tester.getSize(card).width, closeTo(want.width, 1e-6));
      expect(tester.getSize(card).height, closeTo(want.height, 1e-6));
      expect(qr, findsOneWidget);
      await tester.tap(card);
      expect(opened, 1);
      // The notices' turn timer goes with the tree.
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the shell: the guide in the left panel beside a notice, a '
        'tap opens it in the kiosk\'s theme, the idle reset closes it', (
      tester,
    ) async {
      fullHd(tester);
      const panels = KioskPanels(
        left: KioskPanel(days: 2, open: true),
        right: KioskPanel(days: 2, open: false),
        modules: [
          KioskModulePlacement(id: 'duty', side: PanelSide.off, share: 30),
          KioskModulePlacement(id: 'guide', side: PanelSide.left, share: 45),
          KioskModulePlacement(id: 'notices', side: PanelSide.left, share: 55),
          KioskModulePlacement(id: 'matches', side: PanelSide.off, share: 60),
          KioskModulePlacement(id: 'week', side: PanelSide.off, share: 55),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(
              (ref) => Stream.value(
                const ScheduleSettings(
                  laneCount: 2,
                  trainingWeekdays: {1, 2, 3, 4, 5, 6, 7},
                  bookingHorizonDays: 14,
                  maxActiveReservations: 3,
                  kioskVisibleDays: 8,
                  kioskPanels: panels,
                ),
              ),
            ),
            nowProvider.overrideWith(
              (ref) => Stream.value(DateTime(2026, 10, 8, 12)),
            ),
            timeBlocksProvider.overrideWith((ref) => Stream.value(const [])),
            dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
            prioritySlotsProvider.overrideWithValue(const []),
            rentalsProvider.overrideWith((ref) => Stream.value(const [])),
            weekReservationsProvider.overrideWith(
              (ref, monday) => Stream.value(const []),
            ),
            playersProvider.overrideWith((ref) async => const []),
            messagesProvider.overrideWith((ref) => Stream.value([notice()])),
            kioskSocketOpenProvider.overrideWithValue(() => true),
            matchResultsProvider.overrideWith((ref) => Stream.value(const {})),
            matchPlayerResultsProvider.overrideWith(
              (ref, id) => Stream.value(const []),
            ),
            dutyPeriodsProvider.overrideWith((ref) => Stream.value(const [])),
            dutyAssignmentsProvider.overrideWith(
              (ref) => Stream.value(const []),
            ),
          ],
          // The app's light theme around the kiosk's dark one: the dialog
          // is dark only through the shell's wrap.
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: const KioskShell(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final panel = tester.getSize(find.byType(KioskPanelView));
      expect(panel.width, 2 * column);
      final card = find.byType(KioskGuideCard);
      expect(
        tester.getSize(card).height,
        closeTo((panel.height - 3 * pad) * 0.45, 1e-6),
      );
      expect(qr, findsOneWidget);

      await tester.tap(card);
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget);
      expect(Theme.of(tester.element(dialog)).brightness, Brightness.dark);

      // A minute without a touch: the kiosk starts over, the guide shut.
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
```

- [ ] **Step 8: Run them — expect FAIL**

```bash
cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/features/kiosk_guide_test.dart
```

Expected: FAIL — compilation error `No named parameter with the name 'onOpenGuide'.`

- [ ] **Step 9: Wire the card into `KioskPanelView` and the shell**

`lib/features/kiosk/kiosk_info_panel.dart` — four edits.

(a) the import; old:

```dart
import 'kiosk_duty.dart' show kioskDutyPlanProvider;
```

new:

```dart
import 'kiosk_duty.dart' show kioskDutyPlanProvider;
import 'kiosk_guide.dart' show KioskGuideCard;
```

(b) `KioskPanelView`'s constructor; old:

```dart
    required this.onOpenNotice,
    required this.onOpenMatch,
```

new:

```dart
    required this.onOpenNotice,
    required this.onOpenMatch,
    this.onOpenGuide,
```

(c) its fields; old:

```dart
  final void Function(Message notice) onOpenNotice;
  final void Function(PrioritySlot match) onOpenMatch;
```

new:

```dart
  final void Function(Message notice) onOpenNotice;
  final void Function(PrioritySlot match) onOpenMatch;

  /// A tap on „Jak začít“: the whole guide with the large QR code; null =
  /// a tap does nothing.
  final VoidCallback? onOpenGuide;
```

(d) the module's card in `build`'s `card(KioskModule module)` switch (Task 3's placeholder); old:

```dart
      KioskModule.guide => const SizedBox.shrink(),
```

new:

```dart
      KioskModule.guide => KioskGuideCard(onOpen: () => onOpenGuide?.call()),
```

The guide card keeps no state of its own, so it takes no `resetToken` key; its slot is keyed by the module as the others (Task 3).

`lib/features/kiosk/kiosk_shell.dart` — three edits.

(a) the import; old:

```dart
import 'kiosk_duty.dart';
```

new:

```dart
import 'kiosk_duty.dart';
import 'kiosk_guide.dart';
```

(b) after `_openDuty`; old:

```dart
  void _openDuty() =>
      unawaited(showKioskDutyDialog(context, wrap: _touchable));
```

new:

```dart
  void _openDuty() =>
      unawaited(showKioskDutyDialog(context, wrap: _touchable));

  /// „Jak začít“ whole, with the large QR code — a tap on its card in a
  /// panel.
  void _openGuide() => unawaited(showKioskGuide(context, wrap: _touchable));
```

(c) in `_boardWithPanel`'s `panel(...)` helper, the one `KioskPanelView(` both sides are built with (the board and the status bar take `_openMatchOrStream`, so the string is unique); old:

```dart
          onOpenMatch: _openMatch,
```

new:

```dart
          onOpenMatch: _openMatch,
          onOpenGuide: _openGuide,
```

(Keep the indentation the helper has; the two lines above show Task 3's.)

- [ ] **Step 10: Run the tests and the analyzer — expect PASS**

```bash
cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/features/kiosk_guide_test.dart test/features/kiosk_qr_test.dart test/features/kiosk_test.dart && flutter analyze
```

Expected: all pass (`kiosk_guide_test.dart` now 10 tests: the guide's card 444.5 × 425.25 in a `KioskPanelView` of 468.5 × 981 with the QR code; in the shell 45 % of the left panel with the QR code, the dialog dark over the light app theme, gone after 61 s without a touch); `kiosk_test.dart` unchanged and green; analyzer `No issues found!`.

- [ ] **Step 11: Commit the wiring**

```bash
cd /Users/mvazan/Home/rezervator
git add lib/features/kiosk/kiosk_info_panel.dart lib/features/kiosk/kiosk_shell.dart test/features/kiosk_guide_test.dart
git commit -m "$(cat <<'EOF'
feat(kiosk): „Jak začít“ v panelech

Modul guide kreslí v panelu kartu „Jak začít“; ťuknutí otevře celý
návod přes _touchable — v tématu kiosku, dotyk v dialogu se počítá a
návrat po nečinnosti ho zavře.
Testy: karta dostane svůj podíl panelu a QR kód, v levém panelu kiosku
vedle Nástěnky (Full HD, 2 z 8 dnů, 45 %), dialog v tmavém tématu,
zavření po nečinnosti.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

The scan of the code from the kiosk itself (the spec's „the user scans the code from the kiosk before release“) is part of Task 13's browser check.


### Task 8: Migration 0078 — gender in `site_player_regnums`, `kiosk_week_players` RPC

**Files:**
- Create: `supabase/migrations/0078_week_players.sql`
- Modify: `supabase/tests/tenancy_rls.sql` (a new block just before the final `rollback;`, after Task 1's 0077 block)
- Modify: `supabase/schema.sql` (regenerated by the snapshot script only, never by hand)
- Modify: `docs/SCHEMA.md`
- Test: `supabase/tests/tenancy_rls.sql`

**Interfaces:**
- Consumes: `current_tenant_id()` and `is_approved_or_kiosk()` (security-definer helpers, `profiles` of `auth.uid()`); `priority_slots` (`import_key`, `parent_id`, `date`, `starts_at`, `is_away`, `competition`, `home_team`/`away_team`, `home_team_slug`/`away_team_slug`), `match_results` (`status`, `discipline`), `match_player_results` (`side`, `position`, `player_name`, `player_slug`, `total`, `errors`, `lanes`, `sub_name`), `teams` (`tenant_id`, `site_slug`, `name`, `club_id`), `clubs` (`name`, `color`), `site_player_regnums` (0059, service role only).
- Produces:
  - `site_player_regnums.gender text` with the named check `site_player_regnums_gender_check` (`gender in ('m', 'f')`, null = unknown) and `site_player_regnums.gender_checked_at timestamptz` (null = never asked). Both are service role only, through 0059's table grants. Task 10 writes them.
  - `kiosk_week_players(p_monday date default null) returns table(match_id uuid, date date, player_name text, player_slug text, total int, errors int, throws int, is_away boolean, competition text, team_name text, opponent text, club_id uuid, club_name text, club_color int, gender text)`: `security definer`, `stable`, `set search_path = public`. It raises `not_allowed` unless `is_approved_or_kiosk()`. `revoke all … from public, anon; grant execute … to authenticated` (Supabase's default ACL keeps `service_role`, as on `refresh_match`). Row contract for Tasks 10 and 11: `throws` is 120, 100 or null; `club_color` is never null (−1 without a club); `gender` is `'m'`, `'f'` or null; `player_slug`, `competition`, `club_id` and `club_name` may be null. Rows come ordered by date, start time, match, side and position, and the client does the ranking. Any day of a week names its Monday (`date_trunc('week', p_monday)`); null means the previous week's Monday in Europe/Prague.

- [ ] **Step 1: Write the failing tenancy block**

The block uses an alley of its own, H (`…000078`, profiles `78000000-…-0001` player, `-0002` kiosk, `-0003` pending). It plays the previous Prague week, which is the function's default, so the null default can be checked against the same rows. It has two `pg_temp` helpers for a federation match with its result and for one player line. Alley A plays a match in the same week, which H must not see. The block starts with `reset role;` because Task 1's 0077 block, or whatever ends the file, may leave a role set.


`supabase/tests/tenancy_rls.sql` — replace:

```sql
rollback;
```

with:

```sql
-- 0078: „Hráči týdne“. kiosk_week_players gives an alley's approved members
-- and its kiosk the lines of the alley's OWN side in the finished federation
-- matches of one Monday to Sunday. The side is told by team slug, never by
-- name. Substitutes' lines and lines without a total stay out, and the
-- register's gender comes with each line. Another alley sees none of them,
-- and anon may not call it at all. 0078 runs twice (it re-runs). An alley
-- of its own, H, plays the previous week in Prague, the function's default.
reset role;
\ir ../migrations/0078_week_players.sql
\ir ../migrations/0078_week_players.sql
insert into tenants (id, name) values
  ('00000000-0000-0000-0000-000000000078', 'Kuželna H (0078)');
insert into auth.users (id, email) values
  ('78000000-0000-0000-0000-000000000001', 'h1@example.com'),
  ('78000000-0000-0000-0000-000000000002', 'h2@example.com'),
  ('78000000-0000-0000-0000-000000000003', 'h3@example.com')
on conflict do nothing;
insert into profiles (id, tenant_id, display_name, email, role, status) values
  ('78000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000078',
   'Hráč H', 'h1@example.com', 'player', 'approved'),
  ('78000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000078',
   'Kiosk H', 'h2@example.com', 'kiosk', 'approved'),
  ('78000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000078',
   'Čekající H', 'h3@example.com', 'player', 'pending');

-- A federation match of an alley with its result, and one player line.
create function pg_temp.wk_match(
  p_tenant uuid, p_key text, p_date date, p_home text, p_home_slug text,
  p_away text, p_away_slug text, p_is_away boolean, p_status text,
  p_discipline text default 'T120')
returns uuid language plpgsql as $$
declare
  v_id uuid;
begin
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     home_team_slug, away_team_slug, is_away, competition, import_key,
     created_by)
  values
    (p_tenant, p_date, '17:00', '20:00',
     (select id from priority_slot_types
       where tenant_id = p_tenant and is_match and builtin),
     p_home, p_away, p_home_slug, p_away_slug, p_is_away, 'Divize H', p_key,
     (select id from profiles where tenant_id = p_tenant order by id limit 1))
  returning id into v_id;
  insert into match_results (match_id, tenant_id, status, discipline)
  values (v_id, p_tenant, p_status, p_discipline);
  return v_id;
end $$;
create function pg_temp.wk_line(
  p_match uuid, p_side text, p_position int, p_name text, p_slug text,
  p_total int, p_errors int default 0, p_lanes int default 4,
  p_sub text default null)
returns void language sql as $$
  insert into match_player_results
    (match_id, tenant_id, side, position, player_name, player_slug, total,
     errors, lanes, sub_name)
  select p_match, s.tenant_id, p_side, p_position, p_name, p_slug, p_total,
         p_errors,
         (select coalesce(jsonb_agg(jsonb_build_object('lane', n)), '[]'::jsonb)
            from generate_series(1, p_lanes) n),
         p_sub
    from priority_slots s where s.id = p_match
$$;

do $$
declare
  v_h constant uuid := '00000000-0000-0000-0000-000000000078';
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_mon constant date :=
    date_trunc('week', now() at time zone 'Europe/Prague')::date - 7;
  v_club uuid;
  m uuid;
begin
  insert into clubs (tenant_id, name, color) values (v_h, 'Klub H', 3)
  returning id into v_club;
  insert into teams (tenant_id, name, club_id, site_slug) values
    (v_h, 'Domácí A', v_club, 'domaci-a-muzi'),
    (v_h, 'Domácí B', null, 'domaci-b-muzi');

  -- Monday at home: our two lines count. A substitute's line, a line with
  -- no total and the guests' line do not.
  m := pg_temp.wk_match(v_h, 'cka:78001', v_mon, 'Domácí A', 'domaci-a-muzi',
                        'Soupeř X', 'souper-x-muzi', false, 'finished');
  perform pg_temp.wk_line(m, 'home', 1, 'Jan Dvořák', 'wk-jan-dvorak', 600, 2);
  perform pg_temp.wk_line(m, 'home', 2, 'Eva Malá', 'wk-eva-mala', 550, 1);
  perform pg_temp.wk_line(m, 'home', 3, 'Petr Starý', 'wk-petr-stary', 520, 0,
                          4, 'Karel Nový');
  perform pg_temp.wk_line(m, 'home', 4, 'Bez Výsledku', null, null);
  perform pg_temp.wk_line(m, 'away', 1, 'Cizí Hráč', 'wk-cizi-hrac', 610);
  -- Sunday away, forfeited, with no discipline stored: 2 lanes are 100
  -- throws, and 3 lanes say nothing.
  m := pg_temp.wk_match(v_h, 'cka:78002', v_mon + 6, 'Soupeř Y', 'souper-y-muzi',
                        'Domácí B', 'domaci-b-muzi', true, 'forfeit', '');
  perform pg_temp.wk_line(m, 'away', 1, 'Jan Dvořák', 'wk-jan-dvorak', 450, 3, 2);
  perform pg_temp.wk_line(m, 'away', 2, 'Lída Tříková', 'wk-lida-trikova', 300,
                          4, 3);
  perform pg_temp.wk_line(m, 'home', 1, 'Hostitel Y', 'wk-hostitel-y', 500, 0, 2);
  -- Our team's NAME on a side whose slug is not ours: not ours.
  m := pg_temp.wk_match(v_h, 'cka:78003', v_mon + 2, 'Domácí A', 'jiny-tym-muzi',
                        'Soupeř Z', 'souper-z-muzi', false, 'finished');
  perform pg_temp.wk_line(m, 'home', 1, 'Jen Jménem', 'wk-jen-jmenem', 580);
  -- Not finished yet.
  m := pg_temp.wk_match(v_h, 'cka:78004', v_mon + 3, 'Domácí A', 'domaci-a-muzi',
                        'Soupeř X', 'souper-x-muzi', false, 'in_progress');
  perform pg_temp.wk_line(m, 'home', 1, 'Ještě Hraje', 'wk-jeste-hraje', 590);
  -- The Sunday before and the Monday after.
  m := pg_temp.wk_match(v_h, 'cka:78005', v_mon - 1, 'Domácí A', 'domaci-a-muzi',
                        'Soupeř X', 'souper-x-muzi', false, 'finished');
  perform pg_temp.wk_line(m, 'home', 1, 'Minulý Týden', 'wk-minuly-tyden', 570);
  m := pg_temp.wk_match(v_h, 'cka:78006', v_mon + 7, 'Domácí A', 'domaci-a-muzi',
                        'Soupeř X', 'souper-x-muzi', false, 'finished');
  perform pg_temp.wk_line(m, 'home', 1, 'Příští Týden', 'wk-pristi-tyden', 560);
  -- A hand-made match (no cka: key) is not a federation match.
  m := pg_temp.wk_match(v_h, null, v_mon + 1, 'Domácí A', 'domaci-a-muzi',
                        'Soupeř X', 'souper-x-muzi', false, 'finished');
  perform pg_temp.wk_line(m, 'home', 1, 'Ruční Zápas', 'wk-rucni-zapas', 540);
  -- Another alley plays the same week.
  insert into teams (tenant_id, name, site_slug)
  values (v_a, 'Áčko 0078', 'acko-0078-muzi');
  m := pg_temp.wk_match(v_a, 'cka:78101', v_mon + 1, 'Áčko 0078', 'acko-0078-muzi',
                        'Soupeř X', 'souper-x-muzi', false, 'finished');
  perform pg_temp.wk_line(m, 'home', 1, 'Hráč Áčka', 'wk-hrac-acka', 530);

  -- The register: a man found, a woman whose number is ambiguous, and no
  -- row at all for Lída Tříková.
  insert into site_player_regnums (slug, regnum, status, gender, gender_checked_at)
  values ('wk-jan-dvorak', '701', 'found', 'm', now()),
         ('wk-eva-mala', null, 'ambiguous', 'f', now());
  begin
    insert into site_player_regnums (slug, regnum, status, gender)
    values ('wk-x', null, 'none', 'x');
    raise exception 'FAIL: a gender other than m / f went into site_player_regnums (0078)';
  exception when check_violation then null;
  end;
  if has_column_privilege('authenticated', 'public.site_player_regnums', 'gender', 'select')
     or has_column_privilege('authenticated', 'public.site_player_regnums',
                             'gender_checked_at', 'select') then
    raise exception 'FAIL: the app can read the register''s gender (0078)';
  end if;
  if has_function_privilege('anon', 'kiosk_week_players(date)', 'execute') then
    raise exception 'FAIL: anon may execute kiosk_week_players (0078)';
  end if;
  if not has_function_privilege('authenticated', 'kiosk_week_players(date)', 'execute') then
    raise exception 'FAIL: the app may not execute kiosk_week_players (0078)';
  end if;
end $$;

-- A player of H: the week's lines of our side, whichever day names the week.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"78000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_mon constant date :=
    date_trunc('week', now() at time zone 'Europe/Prague')::date - 7;
  v_week constant text :=
    'Eva Malá 550 120 doma f, Jan Dvořák 450 100 venku m, '
    'Jan Dvořák 600 120 doma m, Lída Tříková 300 - venku -';
  v_day date;
  v_got text;
  r record;
begin
  foreach v_day in array array[v_mon, v_mon + 3, v_mon + 6, null] loop
    select string_agg(format('%s %s %s %s %s', w.player_name, w.total,
                             coalesce(w.throws::text, '-'),
                             case when w.is_away then 'venku' else 'doma' end,
                             coalesce(w.gender, '-')),
                      ', ' order by w.player_name, w.total)
      into v_got from kiosk_week_players(v_day) w;
    if v_got is distinct from v_week then
      raise exception 'FAIL: kiosk_week_players(%) gave [%], expected [%] (0078)',
        coalesce(v_day::text, 'null'), v_got, v_week;
    end if;
  end loop;
  select string_agg(w.player_name, ', ') into v_got
    from kiosk_week_players(v_mon + 7) w;
  if v_got is distinct from 'Příští Týden' then
    raise exception 'FAIL: the following week gave [%] (0078)', v_got;
  end if;

  select * into r from kiosk_week_players(v_mon) w where w.total = 600;
  if r.match_id is distinct from
       (select id from priority_slots where import_key = 'cka:78001')
     or r.date <> v_mon or r.errors <> 2 or r.player_slug <> 'wk-jan-dvorak'
     or r.competition <> 'Divize H' or r.team_name <> 'Domácí A'
     or r.opponent <> 'Soupeř X' or r.club_id is null
     or r.club_name <> 'Klub H' or r.club_color <> 3 then
    raise exception 'FAIL: a home line of kiosk_week_players is wrong: % (0078)', to_jsonb(r);
  end if;
  select * into r from kiosk_week_players(v_mon) w where w.total = 450;
  if r.date <> v_mon + 6 or r.team_name <> 'Domácí B' or r.opponent <> 'Soupeř Y'
     or r.club_id is not null or r.club_name is not null or r.club_color <> -1 then
    raise exception 'FAIL: an away line of kiosk_week_players is wrong: % (0078)', to_jsonb(r);
  end if;
  raise notice 'OK: kiosk_week_players — the week of any of its days (none = the previous one in Prague), our side by slug only, substitutes, lines without a total, unfinished, hand-made and other weeks'' matches out, throws by discipline or lanes, home/away of the alley, team, opponent, club and the register''s gender (0078)';
end $$;

-- H's kiosk reads the same lines; a pending player reads nothing.
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"78000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
begin
  if (select count(*) from kiosk_week_players(
        date_trunc('week', now() at time zone 'Europe/Prague')::date - 7)) <> 4 then
    raise exception 'FAIL: the kiosk does not read its alley''s week (0078)';
  end if;
end $$;
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"78000000-0000-0000-0000-000000000003","role":"authenticated"}';
do $$
begin
  begin
    perform kiosk_week_players(null);
    raise exception 'FAIL: a pending player read the week''s players (0078)';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
end $$;

-- Alley A sees its own line and none of H's; H never saw A's.
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_mon constant date :=
    date_trunc('week', now() at time zone 'Europe/Prague')::date - 7;
begin
  if not exists (select 1 from kiosk_week_players(v_mon) w
                  where w.player_name = 'Hráč Áčka')
     or exists (select 1 from kiosk_week_players(v_mon) w
                 where w.team_name in ('Domácí A', 'Domácí B')) then
    raise exception 'FAIL: kiosk_week_players crosses alleys (0078)';
  end if;
  raise notice 'OK: kiosk_week_players keeps to the caller''s alley, the kiosk included, not a pending player (0078)';
end $$;

-- Anon may not call it at all.
reset role;
set local role anon;
set local request.jwt.claims = '{"role":"anon"}';
do $$
begin
  begin
    perform kiosk_week_players(null);
    raise exception 'FAIL: anon called kiosk_week_players (0078)';
  exception when insufficient_privilege then null;
  end;
  raise notice 'OK: anon has no EXECUTE on kiosk_week_players; the gender is the service role''s alone (0078)';
end $$;
reset role;

rollback;
```


- [ ] **Step 2: Run the suite and watch it fail**

Run: `/private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/snap_repo.sh /Users/mvazan/Home/rezervator`
Expected: `tenancy FAILED`. `/private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/supa-throwaway/tenancy.log` ends with `error: …/supabase/tests/../migrations/0078_week_players.sql: No such file or directory`. The snapshot line shows no change to `supabase/schema.sql`, because no migration was added yet.

- [ ] **Step 3: Write the migration**

The migration is re-runnable: `add column if not exists` with the named check inside the column clause (the 0066 pattern), `create or replace function`, and idempotent revoke/grant. Every column in the function body is qualified, because the `returns table` columns (`date`, `total`, `errors`, `gender`, …) are plpgsql variables. Create `supabase/migrations/0078_week_players.sql`:

```sql
-- 0078 — „Hráči týdne“ on the kiosk: the previous week's best results of
-- the alley's own players, by 100 / 120 throws and men / women.
--
-- Gender comes from the ČKA member register (evidence.kuzelky.cz), which
-- already gives the registration numbers: regnum-lookup reads the
-- register's gender together with the number and keeps it per
-- results-service slug in site_player_regnums. gender is 'm' or 'f', and
-- null means unknown. gender_checked_at says when the function last asked
-- for it (null = never), so a player the register does not settle is asked
-- again only after a week (GENDER_RETRY_DAYS in _shared/regnum.ts). Like
-- the rest of the table, both columns are for the service role only (0059).
--
-- kiosk_week_players(monday) gives the kiosk the week's lines of ours. It is
-- computed on demand, because a late fetch, a correction within 14 days and
-- a gender found later all change a past week. It returns one row per line
-- of our side in a finished or forfeited federation match from that Monday
-- to Sunday. Our side is the side whose team slug is one of the alley's
-- teams.site_slug, the rule the sync itself uses (0045); names are never
-- used. A substitute's line and a line without a total stay out. The
-- function is security definer so it can read the gender, which the app
-- cannot. It is limited to the caller's alley, to approved members and to
-- the kiosk.
--
-- Re-runnable on purpose, like 0064 and 0065.

alter table site_player_regnums
  add column if not exists gender text
    constraint site_player_regnums_gender_check check (gender in ('m', 'f')),
  add column if not exists gender_checked_at timestamptz;

comment on table site_player_regnums is
  'regnum-lookup cache of MATCH players, by results-service player slug (0059): resolved by the service page''s club and age against the register. Since 0078 it also keeps the register''s gender (m / f, null = unknown) and when that was last asked for. Service role only.';
comment on column site_player_regnums.gender is
  'The ČKA register''s gender of the player (0078): m or f, null = unknown. regnum-lookup writes it with the number, or alone for a player found earlier; kiosk_week_players joins it.';
comment on column site_player_regnums.gender_checked_at is
  'When regnum-lookup last asked the register for this player''s gender (0078), null = never. While gender is null it is asked again after a week.';

create or replace function kiosk_week_players(p_monday date default null)
returns table (
  match_id uuid, date date, player_name text, player_slug text,
  total int, errors int, throws int, is_away boolean, competition text,
  team_name text, opponent text, club_id uuid, club_name text,
  club_color int, gender text)
language plpgsql stable security definer set search_path = public as $$
declare
  -- Any day of a week stands for its Monday. Without a day it is the
  -- previous week in Prague, since the database runs in UTC. The app always
  -- passes one, so its title and its gender look-ups name the same week.
  v_monday constant date := coalesce(
    date_trunc('week', p_monday)::date,
    date_trunc('week', now() at time zone 'Europe/Prague')::date - 7);
begin
  if not is_approved_or_kiosk() then
    raise exception 'not_allowed';
  end if;
  -- Every column is qualified: the output columns are variables here.
  return query
  select p.id, p.date, l.player_name, l.player_slug, l.total, l.errors,
         case
           when r.discipline = 'T120' then 120
           when r.discipline = 'T100' then 100
           -- No discipline stored: the lanes tell (4 × 30 or 2 × 50 throws).
           when jsonb_typeof(l.lanes) <> 'array' then null
           when jsonb_array_length(l.lanes) = 4 then 120
           when jsonb_array_length(l.lanes) = 2 then 100
         end,
         -- The alley's home or away, as on the board, not the line's side:
         -- in a derby at our alley both sides are at home.
         p.is_away, p.competition, t.name,
         case l.side when 'home' then p.away_team else p.home_team end,
         c.id, c.name, coalesce(c.color, -1), g.gender
    from priority_slots p
    join match_results r on r.match_id = p.id
    join match_player_results l on l.match_id = p.id
    join teams t
      on t.tenant_id = p.tenant_id
     and t.site_slug = case l.side when 'home' then p.home_team_slug
                                   else p.away_team_slug end
    left join clubs c on c.id = t.club_id
    left join site_player_regnums g on g.slug = l.player_slug
   where p.tenant_id = current_tenant_id()
     and p.import_key like 'cka:%'
     and p.parent_id is null
     and p.date between v_monday and v_monday + 6
     and r.status in ('finished', 'forfeit')
     and l.sub_name is null
     and l.total is not null
   order by p.date, p.starts_at, p.id, l.side, l.position;
end;
$$;

-- As refresh_match (0062): the app's members and its kiosk, never anon.
revoke all on function kiosk_week_players(date) from public, anon;
grant execute on function kiosk_week_players(date) to authenticated;
```

- [ ] **Step 4: Run the suite and regenerate the snapshot**

Run: `/private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/snap_repo.sh /Users/mvazan/Home/rezervator`
Expected: `tenancy OK`, then a diff-stat line for `supabase/schema.sql`. Check the snapshot:

Run: `cd /Users/mvazan/Home/rezervator && grep -n 'kiosk_week_players\|site_player_regnums_gender_check\|"gender_checked_at"' supabase/schema.sql`
Expected: the function definition, `REVOKE ALL ON FUNCTION "public"."kiosk_week_players"("p_monday" "date") FROM PUBLIC;`, `GRANT ALL ON FUNCTION … TO "authenticated";` and `… TO "service_role";` (no `"anon"` line), the `gender` check and the `gender_checked_at` column with their comments.

- [ ] **Step 5: Document the columns and the RPC in `docs/SCHEMA.md`**


`docs/SCHEMA.md` — replace:

```markdown
Resolved by the player's page on vysledky.kuzelky.cz (club and age) against the register. | no policy, no grant for `anon` / `authenticated`
```

with:

```markdown
Resolved by the player's page on vysledky.kuzelky.cz (club and age) against the register. `gender` (0078: the register's m \| f, null = unknown; `site_player_regnums_gender_check`) and `gender_checked_at` (0078: when the function last asked the register for it, null = never; asked again after a week while unknown) are written with the number, or alone by `regnum-lookup`'s `week` mode for a `found` player, whose number stays; `kiosk_week_players` joins the gender. | no policy, no grant for `anon` / `authenticated`
```

`docs/SCHEMA.md` — replace:

```markdown
| `apply_federation_matches(tenant, competition_slug, matches, keep_ids)`
```

with:

```markdown
| `kiosk_week_players(monday default null)` (0078) | approved member or kiosk | „Hráči týdne“ on the kiosk, computed on demand: one row per line of OUR side — the side whose team slug is a `teams.site_slug` of the caller's alley, as the sync tells ours (0045); never by name — in the alley's `cka:` matches (not an Úklid child) of the week of `monday` (any day stands for its Monday; null = the previous week's Monday in Europe/Prague, though the app always passes it) whose `match_results.status` is finished or forfeit. A substitute's line (`sub_name`) and a line without a `total` stay out. Columns `match_id`, `date`, `player_name`, `player_slug`, `total`, `errors`, `throws` (120 for `T120`, 100 for `T100`, else 4 lanes → 120, 2 → 100, otherwise null), `is_away` (`priority_slots.is_away`: the alley's home/away as on the board, not the line's side), `competition`, `team_name` (our `teams.name`), `opponent` (the other side's name), `club_id` / `club_name` / `club_color` (the team's club, −1 without one) and `gender` (`site_player_regnums`: m \| f \| null). Security definer, because the gender is the service role's; EXECUTE for `authenticated` only. `not_allowed`. |
| `apply_federation_matches(tenant, competition_slug, matches, keep_ids)`
```


- [ ] **Step 6: Commit**

```bash
cd /Users/mvazan/Home/rezervator
git add supabase/migrations/0078_week_players.sql supabase/tests/tenancy_rls.sql supabase/schema.sql docs/SCHEMA.md
git commit -m "feat(db): pohlaví hráčů z registru a hráči týdne pro kiosk (0078)" \
  -m "site_player_regnums.gender (m/f, null = neznámé) a gender_checked_at, jen pro service role. kiosk_week_players(p_monday): řádky naší strany (podle slugu týmu, nikdy podle jména) v dohraných zápasech ČKA týdne, bez střídání a bez výkonu, s pohlavím z registru; security definer, EXECUTE jen authenticated. Tenancy test, snapshot, SCHEMA.md." \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```


### Task 9: Gender from the ČKA register in `_shared/regnum.ts`

**Files:**
- Modify: `supabase/functions/_shared/regnum.ts`
- Test: `supabase/functions/_shared/regnum_test.ts`

**Interfaces:**
- Consumes: nothing new. The gender codes were read once from the live register while this plan was written (`GET https://evidence.kuzelky.cz/frontend-api/members?fulltext=Pavlů`, only the `gender` field of the two rows). Tomáš Pavlů (a man) has `gender: 1` and Jana Pavlů (a woman) has `gender: 2`, both of SKK Veverky Brno and both JSON numbers. The executor does not fetch the register again. The fixture pins exactly those two values, with made-up ids and numbers.
- Produces (exact names from the contract):
  - `export type Gender = "m" | "f";`
  - `RegisterRow.gender: "m" | "f" | null`, filled by `parseRows`: the number 1 → `"m"`, the number 2 → `"f"`, anything else (0, 3, the string `"1"`, null, missing) → null.
  - `Resolved` = `{ status: "found"; regnum: string; gender: Gender | null } | { status: "none" } | { status: "ambiguous"; gender: Gender | null }`. On `found` the gender is the found rows' common gender. On `ambiguous` it is the common gender of that exit's candidates: the age-filtered rows of the name, or all rows of the name when the page has no age. It is null when they differ.
  - `export const GENDER_RETRY_DAYS = 7;`
  - `export function needsGender(row: { gender: string | null; gender_checked_at: string | null }, now: Date): boolean`: gender is null and `gender_checked_at` is null, unparseable, or at least 7 days old.
  - `export function genderForFound(rows: RegisterRow[], regnum: string): Gender | null`: the common gender of the rows that bear `regnum`, else null.
  - Addition, not in the contract, used by Task 10: `export function genderAction(row: { status: string; looked_up_at: string; gender: string | null; gender_checked_at: string | null } | undefined, now: Date, retryAfterMs: number): "skip" | "gender" | "resolve"`. No row → `resolve`. `!needsGender` → `skip`. A `found` row → `gender`. A `none` or `ambiguous` row returns `resolve` when `looked_up_at` is at least `retryAfterMs` old, else `skip`. It keeps the week mode's whole decision in tested code, because `regnum-lookup/index.ts` cannot be imported by a test (it builds its client and calls `Deno.serve` at load).
  - Private: `genderOf(value)` and `commonGender(rows)`. The `profile_candidates` answer still maps `{id, club, category, age}` explicitly, so the gender never leaves the function.

- [ ] **Step 1: Write the failing tests**

First give every existing `pickForSitePlayer` expectation (and `resolveSitePlayer`'s) the new `gender` key. This rewrites 12 single-line literals (9 `found`, 3 `ambiguous`). The multi-line `pickForProfile` / `resolveProfile` `found` literals are `ProfileMatch`, which does not change, and the regex does not touch them:

```bash
cd /Users/mvazan/Home/rezervator
perl -pi -e 's/\{ status: "found", regnum: "(\d+)" \}/{ status: "found", regnum: "$1", gender: null }/g; s/\{ status: "ambiguous" \}/{ status: "ambiguous", gender: null }/g' supabase/functions/_shared/regnum_test.ts
grep -c 'gender: null }' supabase/functions/_shared/regnum_test.ts
```

Expected: `12`.

Then make these edits, in order.


**(a) imports** `supabase/functions/_shared/regnum_test.ts` — replace:

```ts
  fetchSitePlayer,
  foldName,
  isSiteSlug,
  MAX_ROWS,
  parseRows,
```

with:

```ts
  fetchSitePlayer,
  foldName,
  type Gender,
  GENDER_RETRY_DAYS,
  genderAction,
  genderForFound,
  isSiteSlug,
  MAX_ROWS,
  needsGender,
  parseRows,
```

**(b) imports** `supabase/functions/_shared/regnum_test.ts` — replace:

```ts
  resolveSitePlayer,
  sharedNames,
} from "./regnum.ts";
```

with:

```ts
  resolveSitePlayer,
  searchRegister,
  sharedNames,
} from "./regnum.ts";
```

**(c) the `row` helper gains `gender` (before the unused `id`)** `supabase/functions/_shared/regnum_test.ts` — replace:

```ts
  category: number | null = MUZI,
  id = `id${regnum}`,
): RegisterRow => ({ id, name, club, regnum, category, categoryName: "" });
```

with:

```ts
  category: number | null = MUZI,
  gender: Gender | null = null,
  id = `id${regnum}`,
): RegisterRow => ({ id, name, club, regnum, category, categoryName: "", gender });
```

**(d) the new gender tests, before the profile section** `supabase/functions/_shared/regnum_test.ts` — replace:

```ts
// ------------------------------------------------------------- a profile

```

with:

```ts
// ------------------------------------------- a match player's gender (0078)

Deno.test("site player: found carries his rows' gender, null when they disagree", () => {
  assertEquals(
    pickForSitePlayer(
      [row("Jana Nováková", SOKOL, "100", MUZI, "f")],
      "Jana Nováková",
      { club: SOKOL, age: 40 },
      "",
    ),
    { status: "found", regnum: "100", gender: "f" },
  );
  // Two rows of one number, the club deciding: only that number's rows count.
  assertEquals(
    pickForSitePlayer(
      [row("Jan Novák", SOKOL, "100", MUZI, "m"), row("Jan Novák", "KK Jihlava", "200", MUZI, "f")],
      "Jan Novák",
      { club: SOKOL, age: 40 },
      "",
    ),
    { status: "found", regnum: "100", gender: "m" },
  );
  assertEquals(
    pickForSitePlayer(
      [row("Jan Novák", SOKOL, "100", MUZI, "m", "a"), row("Jan Novák", SOKOL, "100", MUZI, null, "b")],
      "Jan Novák",
      { club: SOKOL, age: 40 },
      "",
    ),
    { status: "found", regnum: "100", gender: null },
  );
});

Deno.test("site player: ambiguous for want of a club still tells a gender all candidates share", () => {
  // One number, no age on the page, a club that does not fit.
  assertEquals(
    pickForSitePlayer([row("Jana Nováková", "KK Jihlava", "100", MUZI, "f")], "Jana Nováková", { club: SOKOL, age: null }, ""),
    { status: "ambiguous", gender: "f" },
  );
  // Several numbers and no age: every row of the name is a candidate.
  assertEquals(
    pickForSitePlayer(
      [row("Jan Novák", SOKOL, "100", MUZI, "m"), row("Jan Novák", SOKOL, "200", SENIOR, "m")],
      "Jan Novák",
      { club: null, age: null },
      "",
    ),
    { status: "ambiguous", gender: "m" },
  );
  assertEquals(
    pickForSitePlayer(
      [row("Jan Novák", SOKOL, "100", MUZI, "m"), row("Jan Novák", SOKOL, "200", SENIOR, "f")],
      "Jan Novák",
      { club: null, age: null },
      "",
    ),
    { status: "ambiguous", gender: null },
  );
});

Deno.test("site player: ambiguous within his age category counts only that category's genders", () => {
  const rows = [
    row("Jan Novák", SOKOL, "100", MUZI, "m"),
    row("Jan Novák", SOKOL, "200", MUZI, "m"),
    // Filtered out by the age: her gender does not spoil theirs.
    row("Jan Novák", SOKOL, "300", DOROST, "f"),
  ];
  assertEquals(
    pickForSitePlayer(rows, "Jan Novák", { club: SOKOL, age: 40 }, ""),
    { status: "ambiguous", gender: "m" },
  );
  assertEquals(
    pickForSitePlayer(
      [row("Jan Novák", SOKOL, "100", MUZI, "m"), row("Jan Novák", SOKOL, "200", MUZI, null)],
      "Jan Novák",
      { club: SOKOL, age: 40 },
      "",
    ),
    { status: "ambiguous", gender: null },
  );
});

Deno.test("site player: none has no gender", () => {
  assertEquals(
    pickForSitePlayer([row("Jan Novák", SOKOL, "100", DOROST, "m")], "Jan Novák", { club: SOKOL, age: 40 }, ""),
    { status: "none" },
  );
});

Deno.test("needsGender: unknown, and never asked or asked a week ago or more", () => {
  const now = new Date("2026-10-15T12:00:00Z");
  assertEquals(GENDER_RETRY_DAYS, 7);
  assertEquals(needsGender({ gender: null, gender_checked_at: null }, now), true);
  assertEquals(needsGender({ gender: "m", gender_checked_at: null }, now), false);
  assertEquals(needsGender({ gender: "f", gender_checked_at: "2020-01-01T00:00:00Z" }, now), false);
  assertEquals(
    needsGender({ gender: null, gender_checked_at: "2026-10-08T12:00:01Z" }, now),
    false,
    "a second short of a week",
  );
  assertEquals(needsGender({ gender: null, gender_checked_at: "2026-10-08T12:00:00Z" }, now), true);
  assertEquals(needsGender({ gender: null, gender_checked_at: "nonsense" }, now), true);
});

Deno.test("genderForFound: the gender of the rows with the stored number, nobody else's", () => {
  const rows = [
    row("Jan Novák", SOKOL, "100", SENIOR, "m"),
    row("Jan Novák", "KK Jihlava", "200", MUZI, "f"),
  ];
  assertEquals(genderForFound(rows, "100"), "m");
  assertEquals(genderForFound(rows, "200"), "f");
  assertEquals(genderForFound(rows, "300"), null, "the number is not on the page any more");
  assertEquals(genderForFound([row("Jan Novák", SOKOL, "100", SENIOR, null)], "100"), null);
  assertEquals(genderForFound([], "100"), null);
});

Deno.test("genderAction: a found player's gender alone, an unsettled one resolved again, the rest left", () => {
  const now = new Date("2026-10-15T12:00:00Z");
  const week = 7 * 24 * 3600e3;
  const cached = (
    status: string,
    looked_up_at: string,
    gender: string | null = null,
    gender_checked_at: string | null = null,
  ) => ({ status, looked_up_at, gender, gender_checked_at });
  assertEquals(genderAction(undefined, now, week), "resolve", "nobody asked yet");
  assertEquals(genderAction(cached("found", "2026-01-01T00:00:00Z"), now, week), "gender");
  assertEquals(
    genderAction(cached("found", "2026-10-15T11:00:00Z"), now, week),
    "gender",
    "however fresh the number",
  );
  assertEquals(genderAction(cached("found", "2026-01-01T00:00:00Z", "m"), now, week), "skip");
  assertEquals(
    genderAction(cached("found", "2026-01-01T00:00:00Z", null, "2026-10-14T00:00:00Z"), now, week),
    "skip",
    "asked yesterday",
  );
  assertEquals(
    genderAction(cached("found", "2026-01-01T00:00:00Z", null, "2026-10-01T00:00:00Z"), now, week),
    "gender",
    "asked two weeks ago",
  );
  assertEquals(genderAction(cached("none", "2026-10-01T00:00:00Z"), now, week), "resolve");
  assertEquals(genderAction(cached("ambiguous", "2026-10-01T00:00:00Z"), now, week), "resolve");
  assertEquals(
    genderAction(cached("ambiguous", "2026-10-14T00:00:00Z"), now, week),
    "skip",
    "settled for a week yet",
  );
  assertEquals(genderAction(cached("none", "2026-10-01T00:00:00Z", "f"), now, week), "skip");
});

// ------------------------------------------------------------- a profile

```

**(e) parseRows title** `supabase/functions/_shared/regnum_test.ts` — replace:

```ts
Deno.test("parseRows keeps only id, name, club, category and number; skips archived and odd numbers", () => {
```

with:

```ts
Deno.test("parseRows keeps only id, name, club, category, gender and number; skips archived and odd numbers", () => {
```

**(f) a woman in the parseRows fixture** `supabase/functions/_shared/regnum_test.ts` — replace:

```ts
      { id: 8, state: "carence", name: "New", surname: "Transfer", club: "TJ", registrationNumber: "4", ageCategory: "muži, ženy" },
```

with:

```ts
      { id: 8, state: "carence", gender: 2, name: "New", surname: "Transfer", club: "TJ", registrationNumber: "4", ageCategory: "muži, ženy" },
```

**(g) parseRows expectations + the pinned codes** `supabase/functions/_shared/regnum_test.ts` — replace:

```ts
    { id: "7113", name: "Pavel Strnad", club: "TJ Sokol Rudná", regnum: "787", category: SENIOR, categoryName: "senioři, seniorky" },
    { id: "8", name: "New Transfer", club: "TJ", regnum: "4", category: MUZI, categoryName: "muži, ženy" },
    { id: "5", name: "No Category", club: "TJ", regnum: "9", category: null, categoryName: "" },
  ]);
});
```

with:

```ts
    { id: "7113", name: "Pavel Strnad", club: "TJ Sokol Rudná", regnum: "787", category: SENIOR, categoryName: "senioři, seniorky", gender: "m" },
    { id: "8", name: "New Transfer", club: "TJ", regnum: "4", category: MUZI, categoryName: "muži, ženy", gender: "f" },
    { id: "5", name: "No Category", club: "TJ", regnum: "9", category: null, categoryName: "", gender: null },
  ]);
});

Deno.test("parseRows: the register's gender 1 is a man, 2 a woman, anything else unknown", () => {
  // The codes as the register's JSON gave them in October 2026 for Tomáš
  // (1) and Jana (2) Pavlů of SKK Veverky Brno; the ids and numbers here
  // are made up.
  const rows = parseRows({
    data: [
      { id: 1, state: "active", gender: 1, name: "Tomáš", surname: "Pavlů", club: "SKK Veverky Brno", registrationNumber: "11" },
      { id: 2, state: "active", gender: 2, name: "Jana", surname: "Pavlů", club: "SKK Veverky Brno", registrationNumber: "12" },
      { id: 3, state: "active", gender: 0, name: "A", surname: "Nula", club: "TJ", registrationNumber: "13" },
      { id: 4, state: "active", gender: 3, name: "B", surname: "Tři", club: "TJ", registrationNumber: "14" },
      { id: 5, state: "active", gender: "1", name: "C", surname: "Text", club: "TJ", registrationNumber: "15" },
      { id: 6, state: "active", gender: null, name: "D", surname: "Nic", club: "TJ", registrationNumber: "16" },
      { id: 7, state: "active", name: "E", surname: "Bez", club: "TJ", registrationNumber: "17" },
    ],
  });
  assertEquals(rows.map((r) => [r.name, r.gender]), [
    ["Tomáš Pavlů", "m"],
    ["Jana Pavlů", "f"],
    ["A Nula", null],
    ["B Tři", null],
    ["C Text", null],
    ["D Nic", null],
    ["E Bez", null],
  ]);
});
```

**(h) the shared site fixture carries the gender** `supabase/functions/_shared/regnum_test.ts` — replace:

```ts
    { id: 7113, state: "active", name: "Pavel", surname: "Strnad", club: "TJ Sokol Rudná", registrationNumber: "787", ageCategory: "muži, ženy" },
    { id: 31056, state: "active", name: "Pavel", surname: "Strnad", club: "TJ Jiskra Hylváty", registrationNumber: "18424", ageCategory: "muži, ženy" },
```

with:

```ts
    { id: 7113, state: "active", gender: 1, name: "Pavel", surname: "Strnad", club: "TJ Sokol Rudná", registrationNumber: "787", ageCategory: "muži, ženy" },
    { id: 31056, state: "active", gender: 1, name: "Pavel", surname: "Strnad", club: "TJ Jiskra Hylváty", registrationNumber: "18424", ageCategory: "muži, ženy" },
```

**(i) resolveSitePlayer answers it** `supabase/functions/_shared/regnum_test.ts` — replace:

```ts
    await resolveSitePlayer("Pavel Strnad", "pavel-strnad", "TJ Sokol Rudná A", fn),
    { status: "found", regnum: "787", gender: null },
```

with:

```ts
    await resolveSitePlayer("Pavel Strnad", "pavel-strnad", "TJ Sokol Rudná A", fn),
    { status: "found", regnum: "787", gender: "m" },
```

**(j) a found player's gender: one register request** `supabase/functions/_shared/regnum_test.ts` — replace:

```ts
Deno.test("resolveSitePlayer: a bad slug asks nobody", async () => {
```

with:

```ts
Deno.test("a found player's gender: one register request by his name, his number's row", async () => {
  const { fn, calls } = sites(LIST, PAGE);
  assertEquals(genderForFound(await searchRegister("Pavel Strnad", fn), "18424"), "m");
  assertEquals(calls, [
    "https://evidence.kuzelky.cz/frontend-api/members?fulltext=Pavel%20Strnad",
  ]);
});

Deno.test("resolveSitePlayer: a bad slug asks nobody", async () => {
```


- [ ] **Step 2: Run the tests and watch them fail**

Run: `cd /Users/mvazan/Home/rezervator && deno test --allow-read supabase/functions/_shared/regnum_test.ts`
Expected: FAIL in type-checking (`error: Type checking failed`). The errors include `TS2305 … has no exported member 'Gender'` (and `'GENDER_RETRY_DAYS'`, `'genderAction'`, `'genderForFound'`, `'needsGender'`), and `TS2353 … 'gender' does not exist in type '{ status: "found"; regnum: string; }'`.

- [ ] **Step 3: Implement gender in `regnum.ts`**


**(a) header: gender is read and kept** `supabase/functions/_shared/regnum.ts` — replace:

```ts
// filter cookie; that page is gone.) Each row carries more than a number;
// only the name, club, age category, state, number and the register's own row
// id are ever read, and nothing else is kept, logged or returned.
```

with:

```ts
// filter cookie; that page is gone.) Each row carries more than a number;
// only the name, club, age category, gender, state, number and the register's
// own row id are ever read, and nothing else is kept, logged or returned. Of
// those, the number and (since 0078, for the kiosk's „Hráči týdne“) the
// gender are kept.
```

**(b) `Gender`, `RegisterRow.gender`, `Resolved.gender`** `supabase/functions/_shared/regnum.ts` — replace:

```ts
export type RegisterRow = {
  /** The register's own row id: opaque, only to point at one candidate. */
  id: string;
  name: string;
  club: string;
  regnum: string;
  /** Index into [CATEGORIES], null when the register gives none. */
  category: number | null;
  /** The register's own label of it, for a player to recognise himself. */
  categoryName: string;
};

export type Resolved =
  | { status: "found"; regnum: string }
  | { status: "none" }
  | { status: "ambiguous" };
```

with:

```ts
export type Gender = "m" | "f";

export type RegisterRow = {
  /** The register's own row id: opaque, only to point at one candidate. */
  id: string;
  name: string;
  club: string;
  regnum: string;
  /** Index into [CATEGORIES], null when the register gives none. */
  category: number | null;
  /** The register's own label of it, for a player to recognise himself. */
  categoryName: string;
  /** The register's ♂ / ♀, null when it gives neither ([genderOf]). */
  gender: Gender | null;
};

/** A match player's answer. A found one carries the gender of his rows; an
 * ambiguous one the gender all its candidates share (one of two namesakes
 * of one gender is that gender either way); null when they differ. */
export type Resolved =
  | { status: "found"; regnum: string; gender: Gender | null }
  | { status: "none" }
  | { status: "ambiguous"; gender: Gender | null };
```

**(c) the codes and the common gender** `supabase/functions/_shared/regnum.ts` — replace:

```ts
const regnumsOf = (rows: RegisterRow[]) => new Set(rows.map((r) => r.regnum));

```

with:

```ts
const regnumsOf = (rows: RegisterRow[]) => new Set(rows.map((r) => r.regnum));

/** The register's gender codes, as its JSON gives them (read off Tomáš and
 * Jana Pavlů of SKK Veverky Brno, October 2026): 1 a man, 2 a woman. Any
 * other value, or none, is unknown. */
function genderOf(value: unknown): Gender | null {
  if (value === 1) return "m";
  if (value === 2) return "f";
  return null;
}

/** The gender every one of [rows] has; null when they differ, one of them
 * has none, or there are no rows. */
function commonGender(rows: RegisterRow[]): Gender | null {
  const first = rows[0]?.gender ?? null;
  return rows.every((r) => r.gender === first) ? first : null;
}

```

**(d) `pickForSitePlayer` carries the gender; `GENDER_RETRY_DAYS`, `needsGender`, `genderForFound`, `genderAction`** `supabase/functions/_shared/regnum.ts` — replace:

```ts
  if (candidates.length === 0) return { status: "none" };
  if (regnumsOf(candidates).size === 1) {
    // Without an age to check, one namesake of another club proves nothing.
    if (age === null && !clubFits(candidates, site.club, team)) {
      return { status: "ambiguous" };
    }
    return { status: "found", regnum: candidates[0].regnum };
  }
  const ofClub = candidates.filter((r) => clubFits([r], site.club, team));
  return regnumsOf(ofClub).size === 1
    ? { status: "found", regnum: ofClub[0].regnum }
    : { status: "ambiguous" };
}
```

with:

```ts
  if (candidates.length === 0) return { status: "none" };
  if (regnumsOf(candidates).size === 1) {
    // Without an age to check, one namesake of another club proves nothing.
    if (age === null && !clubFits(candidates, site.club, team)) {
      return { status: "ambiguous", gender: commonGender(candidates) };
    }
    return {
      status: "found",
      regnum: candidates[0].regnum,
      gender: commonGender(candidates),
    };
  }
  const ofClub = candidates.filter((r) => clubFits([r], site.club, team));
  return regnumsOf(ofClub).size === 1
    ? { status: "found", regnum: ofClub[0].regnum, gender: commonGender(ofClub) }
    : { status: "ambiguous", gender: commonGender(candidates) };
}

/** Days after which the register is asked again for a gender it did not
 * give. */
export const GENDER_RETRY_DAYS = 7;

/** Whether a cached match player's gender is worth a question: it is
 * unknown, and the register was never asked for it or not in the last
 * [GENDER_RETRY_DAYS] — whatever the row's status. */
export function needsGender(
  row: { gender: string | null; gender_checked_at: string | null },
  now: Date,
): boolean {
  if (row.gender !== null) return false;
  if (row.gender_checked_at === null) return true;
  const checked = Date.parse(row.gender_checked_at);
  return Number.isNaN(checked) ||
    now.getTime() - checked >= GENDER_RETRY_DAYS * 24 * 3600e3;
}

/** The gender of a player found earlier, from a search of his name alone:
 * the rows that bear his stored number. Null when the number is gone from
 * the answer or its rows disagree. */
export function genderForFound(
  rows: RegisterRow[],
  regnum: string,
): Gender | null {
  return commonGender(rows.filter((r) => r.regnum === regnum));
}

/** What the week's players need from the sites for a gender, by one cached
 * row (undefined = none yet): `skip` while the gender is known or was asked
 * for lately ([needsGender]), and for a `none` / `ambiguous` row younger than
 * [retryAfterMs] (it is settled for now); `gender` for a `found` row, whose
 * number and status stay — the register by name alone ([genderForFound]);
 * `resolve` for no row, or a `none` / `ambiguous` one past [retryAfterMs] —
 * the Zápis's resolve, which keeps the gender with the answer. */
export function genderAction(
  row:
    | {
      status: string;
      looked_up_at: string;
      gender: string | null;
      gender_checked_at: string | null;
    }
    | undefined,
  now: Date,
  retryAfterMs: number,
): "skip" | "gender" | "resolve" {
  if (row === undefined) return "resolve";
  if (!needsGender(row, now)) return "skip";
  if (row.status === "found") return "gender";
  return now.getTime() - Date.parse(row.looked_up_at) >= retryAfterMs
    ? "resolve"
    : "skip";
}
```

**(e) `parseRows` reads the gender** `supabase/functions/_shared/regnum.ts` — replace:

```ts
      category: categoryOf(categoryName),
      categoryName,
    });
```

with:

```ts
      category: categoryOf(categoryName),
      categoryName,
      gender: genderOf(r.gender),
    });
```


- [ ] **Step 4: Run the tests and watch them pass**

Run: `cd /Users/mvazan/Home/rezervator && deno test --allow-read supabase/functions/_shared/regnum_test.ts`
Expected: `ok | 36 passed | 0 failed` (27 before, plus 9).

Run: `cd /Users/mvazan/Home/rezervator && deno check --import-map supabase/functions/import_map.json supabase/functions/regnum-lookup/index.ts`
Expected: `Check …/regnum-lookup/index.ts` with no error. `index.ts` is unchanged so far and still compiles against the new types.

Run: `cd /Users/mvazan/Home/rezervator && deno test --allow-read supabase/functions`
Expected: `ok | 335 passed | 0 failed` (326 before).

- [ ] **Step 5: Commit**

```bash
cd /Users/mvazan/Home/rezervator
git add supabase/functions/_shared/regnum.ts supabase/functions/_shared/regnum_test.ts
git commit -m "feat(regnum): pohlaví z registru ČKA ve sdílené logice" \
  -m "parseRows čte gender (1 = muž, 2 = žena, cokoli jiného neznámé; kódy připnuté ve fixture podle Tomáše a Jany Pavlů), Resolved nese pohlaví u found i u obou výstupů ambiguous, needsGender, genderForFound, genderAction a GENDER_RETRY_DAYS; testy." \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```


### Task 10: `regnum-lookup` week mode — the genders of the week's players

**Files:**
- Modify: `supabase/functions/regnum-lookup/index.ts`
- Modify: `docs/SCHEMA.md` (Edge functions → regnum-lookup)
- Test: none for `index.ts`. It cannot be imported by a test, because the service client is built from env at load and the file calls `Deno.serve`. Its decisions live in `_shared/regnum.ts` (`genderAction`, `needsGender`, `genderForFound`, `pickForSitePlayer`), which Task 9 tests. This task is verified by `deno check` plus the whole Deno suite. Task 13 checks it end to end on the seeded local stack.

**Interfaces:**
- Consumes: `kiosk_week_players(p_monday)` from Task 8, called with the caller's JWT (`asUser.rpc`), and its columns `player_name`, `player_slug`, `team_name`, `gender`; `site_player_regnums.gender` / `gender_checked_at` from Task 8; `genderAction`, `genderForFound`, `Resolved` (with `gender`) from Task 9; the existing `searchRegister`, `resolveSitePlayer`, `isSiteSlug`, `BUDGET` (25), `PAUSE_MS`, `RETRY_AFTER_MS` (7 days).
- Produces (for Task 11's `Api.lookupWeekGenders(Day monday)`): `POST /functions/v1/regnum-lookup` with body `{ "mode": "week", "monday": "YYYY-MM-DD" }` → `200 { "more": boolean }` (`more` = players were left for want of budget, so call again). The other answers are `400 { "error": "missing_monday" }` (no or malformed date), `403 { "error": "not_allowed" }` (the RPC refused: a pending member), `401` without a session, and `500 { "error": "internal" }`. Side effects: a `found` row gets only `gender` and `gender_checked_at` (`update … where slug = … and status = 'found' and gender is null`), and its number and status are never written. A resolve upserts `regnum`, `status`, `looked_up_at`, `gender` (a known one stays when the new answer has none) and `gender_checked_at`, in match mode too. A failing site stamps nothing, so the next call tries again.

- [ ] **Step 1: Write week mode**

Make these edits to `supabase/functions/regnum-lookup/index.ts`, in order. Edit (e) replaces the whole match-players section, from `type SiteAsk` to the end of `resolveSitePlayers`. Its single-player resolve and save become `resolveAndSave`, which both modes share.


**(a) header: the week mode** `supabase/functions/regnum-lookup/index.ts` — replace:

```ts
//   { mode: "match", match_id, league?: true }
//       The Zápis of a match: { regnums: { "<player slug>": "<number>" },
//       more } for its players that are known by a results-service slug,
//       found ones only. The players are read from the match as the CALLER
//       sees it (RLS), so the function answers for a match the caller may
//       open, never for a name the caller makes up. Cached per slug.

```

with:

```ts
//   { mode: "match", match_id, league?: true }
//       The Zápis of a match: { regnums: { "<player slug>": "<number>" },
//       more } for its players that are known by a results-service slug,
//       found ones only. The players are read from the match as the CALLER
//       sees it (RLS), so the function answers for a match the caller may
//       open, never for a name the caller makes up. Cached per slug, with
//       the register's gender (0078).
//
//   { mode: "week", monday }
//       „Hráči týdne“ on the kiosk: the genders of the players of the week
//       starting on that Monday, so its rankings can split men and women.
//       The lines are read by calling kiosk_week_players AS THE CALLER, so
//       „our players“ is defined once, in SQL, and the caller's alley and
//       role are checked there (an approved member or the kiosk). For the
//       players with a slug and no gender: a `found` one is looked up in the
//       register by his name alone and gets the gender of the row with his
//       stored number, which stays as it is. A player without a cached row,
//       or with a `none` / `ambiguous` one past RETRY_AFTER_MS, is resolved
//       as in a Zápis, which keeps the gender too. Each attempt stamps
//       `gender_checked_at`, so a gender the register does not give is asked
//       for again after GENDER_RETRY_DAYS. { more }: the budget ran out.

```

**(b) header: what is read and kept** `supabase/functions/regnum-lookup/index.ts` — replace:

```ts
// The register is asked at most BUDGET times per call, one name at a time. Its
// rows carry personal data beyond a number: only id, name, club, age category,
// state and number are read, and only club and category leave this function.
```

with:

```ts
// The register is asked at most BUDGET times per call, one name at a time. Its
// rows carry personal data beyond a number: only id, name, club, age category,
// gender, state and number are read. The number is kept (site_player_regnums,
// profiles.regnum), and so is a match player's gender (site_player_regnums,
// 0078); only club and category leave this function.
```

**(c) imports** `supabase/functions/regnum-lookup/index.ts` — replace:

```ts
import {
  foldName,
  isSiteSlug,
  named,
  resolveProfile,
  resolveSitePlayer,
  searchRegister,
  sharedNames,
} from "../_shared/regnum.ts";
```

with:

```ts
import {
  foldName,
  genderAction,
  genderForFound,
  isSiteSlug,
  named,
  type Resolved,
  resolveProfile,
  resolveSitePlayer,
  searchRegister,
  sharedNames,
} from "../_shared/regnum.ts";
```

**(d) the cached row carries the gender** `supabase/functions/regnum-lookup/index.ts` — replace:

```ts
type Status = "found" | "none" | "ambiguous";
type Cached = { status: Status; regnum: string | null; looked_up_at: string };
```

with:

```ts
type Status = "found" | "none" | "ambiguous";
type Cached = {
  slug: string;
  status: Status;
  regnum: string | null;
  looked_up_at: string;
  gender: "m" | "f" | null;
  gender_checked_at: string | null;
};
```

**(e) shared resolve-and-save, the found-gender fill, `fillGenders`** `supabase/functions/regnum-lookup/index.ts` — replace:

```ts
type SiteAsk = { name: string; slug: string; team: string };

/** The numbers of [asks] by slug, from `site_player_regnums` and — for the
 * ones missing there — from the sites, at most [budget] questions. */
async function resolveSitePlayers(
  asks: SiteAsk[],
  budget: number,
): Promise<{ found: Map<string, string>; more: boolean }> {
  const bySlug = new Map<string, SiteAsk>();
  for (const a of asks) if (isSiteSlug(a.slug)) bySlug.set(a.slug, a);
  const found = new Map<string, string>();
  if (bySlug.size === 0) return { found, more: false };

  const { data: cached, error } = await admin
    .from("site_player_regnums")
    .select("slug, regnum, status, looked_up_at")
    .in("slug", [...bySlug.keys()]);
  if (error) throw error;
  const known = new Map((cached ?? []).map((r) => [r.slug as string, r as Cached & { slug: string }]));

  let asked = 0;
  let more = false;
  for (const [slug, ask] of bySlug) {
    const row = known.get(slug);
    if (row?.status === "found") found.set(slug, row.regnum as string);
    if (settled(row)) continue;
    if (asked >= budget) {
      more = true;
      continue;
    }
    await pause(asked);
    asked++;
    try {
      const answer = await resolveSitePlayer(ask.name, slug, ask.team);
      const { error: saveError } = await admin.from("site_player_regnums").upsert({
        slug,
        regnum: answer.status === "found" ? answer.regnum : null,
        status: answer.status,
        looked_up_at: new Date().toISOString(),
      });
      if (saveError) console.error("regnum-lookup: save failed:", saveError.message);
      if (answer.status === "found") found.set(slug, answer.regnum);
    } catch (e) {
      // A site is down or changed: nothing is remembered, the next call
      // tries again.
      console.warn("regnum-lookup: lookup failed:", (e as Error).message);
    }
  }
  return { found, more };
}
```

with:

```ts
type SiteAsk = { name: string; slug: string; team: string };

/** [asks] by slug, the ones that are no slug left out. */
function bySlugOf(asks: SiteAsk[]): Map<string, SiteAsk> {
  const bySlug = new Map<string, SiteAsk>();
  for (const a of asks) if (isSiteSlug(a.slug)) bySlug.set(a.slug, a);
  return bySlug;
}

/** The cached rows of [slugs], by slug. */
async function cachedRows(slugs: string[]): Promise<Map<string, Cached>> {
  const { data, error } = await admin
    .from("site_player_regnums")
    .select("slug, regnum, status, looked_up_at, gender, gender_checked_at")
    .in("slug", slugs);
  if (error) throw error;
  return new Map((data ?? []).map((r) => [r.slug as string, r as Cached]));
}

/** Resolves one match player against both sites and remembers the answer:
 * the number, the status and the register's gender — a gender known before
 * stays when the new answer has none — with both stamps. Null when a site
 * failed: then nothing is remembered and the next call tries again. */
async function resolveAndSave(
  ask: SiteAsk,
  row: Cached | undefined,
): Promise<Resolved | null> {
  let answer: Resolved;
  try {
    answer = await resolveSitePlayer(ask.name, ask.slug, ask.team);
  } catch (e) {
    console.warn("regnum-lookup: lookup failed:", (e as Error).message);
    return null;
  }
  const now = new Date().toISOString();
  const { error } = await admin.from("site_player_regnums").upsert({
    slug: ask.slug,
    regnum: answer.status === "found" ? answer.regnum : null,
    status: answer.status,
    looked_up_at: now,
    gender: (answer.status === "none" ? null : answer.gender) ?? row?.gender ?? null,
    gender_checked_at: now,
  });
  if (error) console.error("regnum-lookup: save failed:", error.message);
  return answer;
}

/** The gender of a player found earlier, from the register alone: the row of
 * his name that bears his stored number. Number and status are not touched.
 * `gender_checked_at` is stamped whatever the register says, so a code it
 * does not give is not asked about on every call; a failing site stamps
 * nothing and the next call tries again. */
async function fillFoundGender(ask: SiteAsk, regnum: string): Promise<void> {
  let gender: "m" | "f" | null;
  try {
    gender = genderForFound(await searchRegister(ask.name), regnum);
  } catch (e) {
    console.warn("regnum-lookup: gender lookup failed:", (e as Error).message);
    return;
  }
  const { error } = await admin
    .from("site_player_regnums")
    .update({ gender, gender_checked_at: new Date().toISOString() })
    .eq("slug", ask.slug)
    .eq("status", "found")
    .is("gender", null);
  if (error) console.error("regnum-lookup: gender save failed:", error.message);
}

/** The numbers of [asks] by slug, from `site_player_regnums` and — for the
 * ones missing there — from the sites, at most [budget] questions. */
async function resolveSitePlayers(
  asks: SiteAsk[],
  budget: number,
): Promise<{ found: Map<string, string>; more: boolean }> {
  const bySlug = bySlugOf(asks);
  const found = new Map<string, string>();
  if (bySlug.size === 0) return { found, more: false };
  const known = await cachedRows([...bySlug.keys()]);

  let asked = 0;
  let more = false;
  for (const [slug, ask] of bySlug) {
    const row = known.get(slug);
    if (row?.status === "found") found.set(slug, row.regnum as string);
    if (settled(row)) continue;
    if (asked >= budget) {
      more = true;
      continue;
    }
    await pause(asked);
    asked++;
    const answer = await resolveAndSave(ask, row);
    if (answer?.status === "found") found.set(slug, answer.regnum);
  }
  return { found, more };
}

/** Fills the genders of [asks], the week's players whose gender is not
 * known, at most [budget] questions ([genderAction] says which question, if
 * any). Answers whether any were left for want of budget. */
async function fillGenders(asks: SiteAsk[], budget: number): Promise<boolean> {
  const bySlug = bySlugOf(asks);
  if (bySlug.size === 0) return false;
  const known = await cachedRows([...bySlug.keys()]);
  const now = new Date();

  let asked = 0;
  let more = false;
  for (const [slug, ask] of bySlug) {
    const row = known.get(slug);
    const action = genderAction(row, now, RETRY_AFTER_MS);
    if (action === "skip") continue;
    if (asked >= budget) {
      more = true;
      continue;
    }
    await pause(asked);
    asked++;
    if (action === "gender") {
      // A found row always has its number (site_player_regnums_check).
      await fillFoundGender(ask, row!.regnum!);
    } else {
      await resolveAndSave(ask, row);
    }
  }
  return more;
}
```

**(f) the `week` branch, before `profiles`** `supabase/functions/regnum-lookup/index.ts` — replace:

```ts
    if (body?.mode === "profiles") {
```

with:

```ts
    if (body?.mode === "week") {
      const monday = typeof body.monday === "string" &&
          /^\d{4}-\d{2}-\d{2}$/.test(body.monday) &&
          !Number.isNaN(Date.parse(body.monday))
        ? body.monday as string
        : null;
      if (!monday) return json({ error: "missing_monday" }, 400);
      // As the caller: the RPC keeps to the caller's alley and its own side,
      // and refuses anyone but an approved member or the kiosk.
      const { data: lines, error } = await asUser.rpc("kiosk_week_players", {
        p_monday: monday,
      });
      if (error?.message === "not_allowed") return json({ error: "not_allowed" }, 403);
      if (error) throw error;
      const asks: SiteAsk[] = ((lines ?? []) as {
        player_name: string;
        player_slug: string | null;
        team_name: string;
        gender: string | null;
      }[])
        .filter((l) => typeof l.player_slug === "string" && l.gender === null)
        .map((l) => ({
          name: l.player_name,
          slug: l.player_slug as string,
          // Our side's team stands in for the club when the player's page
          // names none, as in a Zápis.
          team: l.team_name,
        }));
      return json({ more: await fillGenders(asks, BUDGET) });
    }

    if (body?.mode === "profiles") {
```


- [ ] **Step 2: Type-check every function as CI does**

Run:
```bash
cd /Users/mvazan/Home/rezervator
deno check --import-map supabase/functions/import_map.json supabase/functions/notify/index.ts supabase/functions/cancel/index.ts supabase/functions/calendar-oauth-callback/index.ts supabase/functions/calendar-manage/index.ts supabase/functions/kiosk-password/index.ts supabase/functions/react/index.ts supabase/functions/regnum-lookup/index.ts
for f in supabase/functions/*/index.ts; do grep -q "Deno.serve" "$f" || echo "$f has no Deno.serve"; done
```
Expected: one `Check …` line per function and no error; the loop prints nothing.

- [ ] **Step 3: Run the whole Deno suite**

Run: `cd /Users/mvazan/Home/rezervator && deno test --allow-read supabase/functions`
Expected: `ok | 335 passed | 0 failed`.

- [ ] **Step 4: Read the flow back against the spec**

Run:
```bash
cd /Users/mvazan/Home/rezervator
grep -n -A2 '"site_player_regnums"' supabase/functions/regnum-lookup/index.ts
grep -n 'genderAction(row\|asUser.rpc("kiosk_week_players"' supabase/functions/regnum-lookup/index.ts
```
Expected: exactly three touches of the table:
- the `.select("slug, regnum, status, looked_up_at, gender, gender_checked_at")` in `cachedRows`
- the `.upsert({` in `resolveAndSave`, the only write of `regnum`
- the `.update({ gender, gender_checked_at: … })` in `fillFoundGender`, which writes no number and no status

Then `genderAction(row, now, RETRY_AFTER_MS)` in `fillGenders`, and `asUser.rpc("kiosk_week_players", …)` in the `week` branch, which runs as the caller and not as `admin`.

- [ ] **Step 5: Document the week mode in `docs/SCHEMA.md`**


`docs/SCHEMA.md` — replace:

```markdown
- **regnum-lookup** (0057, 0059) — registration numbers from the ČKA member
```

with:

```markdown
- **regnum-lookup** (0057, 0059, 0078) — registration numbers from the ČKA member
```

`docs/SCHEMA.md` — replace:

```markdown
  budget ran out). The register is a PHP page: POST `/` with `ffulltext` →
  302 + a `filter` cookie, then `GET /?aajax=t` is the list for that filter —
  and the WHOLE register without the cookie, with fields (birth date and
  number, …) far beyond a number. Only id, name, club, age and number are
  read; a list longer than 50 rows is treated as an unapplied filter and
  dropped unread (`_shared/regnum.ts`).
```

with:

```markdown
  budget ran out). Since 0078 a resolve keeps the register's gender with the
  number (`gender`, `gender_checked_at`), and `{mode: "week", monday}`
  („Hráči týdne“ on the kiosk) fills in the gender of the week's players. It
  reads their lines by calling `kiosk_week_players` as the CALLER, so „ours“
  is defined once, in SQL. For those with a slug and no gender, a `found`
  player is searched for by name alone and gets the gender of the row with
  his stored number; his number and status are untouched. A player without a
  cached row, or with a `none` / `ambiguous` row older than a week, is
  resolved as for a Zápis. Every attempt stamps `gender_checked_at`, so an
  unknown gender is asked for again after a week; `{more}` as above. The
  register is a JSON API: `GET /frontend-api/members?fulltext=<name>` lists
  the members of that name, and without a filter the WHOLE register, with
  fields far beyond a number. Only id, name, club, age category, gender,
  state and number are read. The gender codes are 1 (man) and 2 (woman);
  anything else is unknown. A list longer than 200 rows is treated as an
  unapplied filter and dropped unread (`_shared/regnum.ts`).
```


- [ ] **Step 6: Commit**

```bash
cd /Users/mvazan/Home/rezervator
git add supabase/functions/regnum-lookup/index.ts docs/SCHEMA.md
git commit -m "feat(regnum-lookup): režim week — pohlaví hráčů týdne" \
  -m "Hráče týdne čte voláním kiosk_week_players jako volající, takže „naši“ jsou definováni jen v SQL. Nalezeným doplní pohlaví z registru podle jména, číslo a stav nechá; bez řádku nebo s none/ambiguous starším než týden projdou běžným dohledáním, které teď ukládá i pohlaví (i v režimu match). Každý pokus razítkuje gender_checked_at; odpověď { more }. SCHEMA.md." \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```


### Task 11: „Hráči týdne“ — data on the client (`week_players.dart`, `Api`, `weekPlayersProvider`)

**Files:**
- Create: `lib/domain/week_players.dart`
- Create: `test/domain/week_players_test.dart`
- Modify: `lib/data/providers.dart` (import; `Api.kioskWeekPlayers` after `Api.refreshMatch`; `Api.lookupWeekGenders` after `Api.fillProfileRegnums`; `weekPlayersProvider` after `profileRegnumsProvider`; one line in `resetTenantScopedProviders`)

**Interfaces:**
- Consumes: `Day` / `Day.parse` / `Day.fromDateTime` / `Day.toSql` (`lib/domain/models.dart`), `mondayOf(Day)` (`lib/domain/kiosk_panel.dart`), `compareCzech` (`lib/domain/collation.dart`), `nowProvider` (`lib/data/clock.dart`), `LiveRefresh.stream` (`lib/data/live_refresh.dart`, already imported by providers.dart), `_authUidProvider` and `_db` (providers.dart). Server side: Task 8's `kiosk_week_players(p_monday date)` returning `match_id uuid, date date, player_name text, player_slug text, total int, errors int, throws int, is_away boolean, competition text, team_name text, opponent text, club_id uuid, club_name text, club_color int (-1 = no club), gender text ('m' | 'f' | null)`; Task 10's `regnum-lookup` body `{mode: 'week', monday: 'YYYY-MM-DD'}` answering `{more: boolean}`.
- Produces (contract names, exact):
  - `enum WeekGender { male, female }`
  - `class WeekLine { matchId, Day date, playerName, String? playerSlug, int total, int errors, int? throws, bool isAway, String? competition, String teamName, String opponent, String? clubId, String? clubName, int clubColor, WeekGender? gender; factory WeekLine.fromJson(Map<String, dynamic>); String get key; }` — plus `bool get needsGender` (a slug and no gender).
  - `enum WeekCategory { men120, women120, men100, women100 }` with `gender`, `throws`, `label` (`'Muži · 120 HS'`, `'Ženy · 120 HS'`, `'Muži · 100 HS'`, `'Ženy · 100 HS'`).
  - `Map<WeekCategory, List<WeekLine>> weekCategories(List<WeekLine> lines)`
  - `List<({String name, List<WeekLine> lines})> weekByCompetition(List<WeekLine> lines)`
  - `List<({String name, int color, List<WeekLine> lines})> weekByClub(List<WeekLine> lines)`
  - `List<WeekLine> weekWhere(List<WeekLine> lines, {bool? away})`
  - `List<WeekLine> weekRanked(List<WeekLine> lines)`
  - `Day previousWeekMonday(DateTime now)`, `String weekRangeLabel(Day monday)`
  - helpers beyond the contract (used by Task 12): `List<int> weekPlaces(List<WeekLine> ranked)` (1, 2, 2, 4), `const weekOtherGroup = 'Ostatní'` (lines without a competition / club, last — the name picker's word), `const weekGenderRounds = 4`, `Future<List<WeekLine>> loadWeekLines(Day monday, {required read, required lookup, int rounds, void Function(Object)? onError})` (the provider's read → lookup rounds → re-read, pure and tested).
  - `Api.kioskWeekPlayers(Day monday) → Future<List<WeekLine>>`, `Api.lookupWeekGenders(Day monday) → Future<bool>`, `final weekPlayersProvider = FutureProvider<List<WeekLine>>(…)`.

Notes for the implementer:
- The app reads the kiosk's wall clock as Prague (the suite runs with `TZ=Europe/Prague`); `previousWeekMonday` takes `now.toLocal()`, so a UTC instant is read on that clock too. The client always passes the Monday to the RPC (spec), so the title, the RPC and the gender lookups name one week.
- Hourly re-read and the week's turn come from `nowProvider.select(… (previousWeekMonday(t), t.hour))`: the minute clock reaches the provider only when the hour or the Monday changes (Monday 00:00 is both). No timer of its own — the repo's clock convention (`kioskDutyPlanProvider` selects the day the same way). Resume = `LiveRefresh.stream` → `ref.invalidateSelf()`.
- Rankings are by result, best first — the spec's one deliberate exception to the alphabetical/chronological rule; groups stay `compareCzech`.
- The provider itself has no unit test (it needs Supabase): everything it decides is in `loadWeekLines` and `previousWeekMonday`, both tested here; Task 12 overrides it in widget tests and Task 13's browser check runs it for real.

- [ ] **Step 1: Write the failing unit test**

Create `test/domain/week_players_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/week_players.dart';

/// „Hráči týdne“ (0078): the pure half — the server's rows, the rankings
/// (one entry per player, best first, ties), the categories, groups and
/// filters, the week before today in Prague and its label, and the read
/// with the gender lookups. Every date is fixed; nothing reads the clock.
/// Run with TZ=Europe/Prague, as the whole suite.
void main() {
  WeekLine line(
    String name,
    int total, {
    String? slug,
    int errors = 0,
    int? throws = 120,
    WeekGender? gender = WeekGender.male,
    bool away = false,
    String? competition = 'Divize AS',
    String team = 'Termínátor A',
    String match = 'm1',
    String? clubId,
    String? clubName,
    int clubColor = -1,
  }) => WeekLine(
    matchId: match,
    date: Day(2026, 10, 10),
    playerName: name,
    playerSlug: slug ?? name.toLowerCase().replaceAll(' ', '-'),
    total: total,
    errors: errors,
    throws: throws,
    isAway: away,
    competition: competition,
    teamName: team,
    opponent: 'KK Slavoj',
    clubId: clubId,
    clubName: clubName,
    clubColor: clubColor,
    gender: gender,
  );

  List<String> names(List<WeekLine> lines) => [
    for (final l in lines) l.playerName,
  ];

  group('WeekLine.fromJson', () {
    test('reads a kiosk_week_players row', () {
      final l = WeekLine.fromJson({
        'match_id': 'a1b2',
        'date': '2026-10-10',
        'player_name': 'Jan Novák',
        'player_slug': 'jan-novak',
        'total': 598,
        'errors': 3,
        'throws': 120,
        'is_away': true,
        'competition': 'Divize AS',
        'team_name': 'Termínátor A',
        'opponent': 'KK Slavoj',
        'club_id': 'c1',
        'club_name': 'Termínátor',
        'club_color': 4,
        'gender': 'm',
      });
      expect(l.matchId, 'a1b2');
      expect(l.date, Day(2026, 10, 10));
      expect(l.playerName, 'Jan Novák');
      expect(l.playerSlug, 'jan-novak');
      expect(l.total, 598);
      expect(l.errors, 3);
      expect(l.throws, 120);
      expect(l.isAway, isTrue);
      expect(l.competition, 'Divize AS');
      expect(l.teamName, 'Termínátor A');
      expect(l.opponent, 'KK Slavoj');
      expect(l.clubId, 'c1');
      expect(l.clubName, 'Termínátor');
      expect(l.clubColor, 4);
      expect(l.gender, WeekGender.male);
      expect(l.key, 'jan-novak');
      expect(l.needsGender, isFalse);
    });

    test('nulls and unknowns: no slug keys by the name, a gender other '
        'than m/f is unknown, no club is -1', () {
      final l = WeekLine.fromJson({
        'match_id': 'a1b2',
        'date': '2026-10-10',
        'player_name': 'Jana Pavlů',
        'player_slug': '',
        'total': 401,
        'errors': null,
        'throws': null,
        'is_away': false,
        'competition': null,
        'team_name': 'Termínátor B',
        'opponent': 'TJ Sokol',
        'club_id': null,
        'club_name': null,
        'club_color': -1,
        'gender': 'x',
      });
      expect(l.playerSlug, isNull);
      expect(l.key, 'Jana Pavlů');
      expect(l.errors, 0);
      expect(l.throws, isNull);
      expect(l.competition, isNull);
      expect(l.clubId, isNull);
      expect(l.clubColor, -1);
      expect(l.gender, isNull);
      // Without a slug the register is never asked.
      expect(l.needsGender, isFalse);
      expect(
        WeekLine.fromJson({
          'match_id': 'a',
          'date': '2026-10-10',
          'player_name': 'Jana Pavlů',
          'player_slug': 'jana-pavlu',
          'total': 401,
          'gender': 'f',
        }).gender,
        WeekGender.female,
      );
      expect(line('Petr Malý', 500, gender: null).needsGender, isTrue);
    });
  });

  group('weekRanked', () {
    test('best first: more pins, then fewer errors, then the name in Czech '
        'order', () {
      final ranked = weekRanked([
        line('Zdeněk Říha', 540),
        line('Šimon Hrubý', 560, errors: 4),
        line('Adam Čech', 560, errors: 2),
        line('Cyril Bárta', 560, errors: 4),
      ]);
      // Cyril before Šimon: equal pins and errors, C before Š.
      expect(names(ranked), [
        'Adam Čech',
        'Cyril Bárta',
        'Šimon Hrubý',
        'Zdeněk Říha',
      ]);
    });

    test('one entry per player — his best line; two matches in a week do '
        'not take two places', () {
      final ranked = weekRanked([
        line('Jan Novák', 540, match: 'm1'),
        line('Petr Malý', 550, match: 'm1'),
        line('Jan Novák', 571, match: 'm2'),
        line('Jan Novák', 571, errors: 1, match: 'm3'),
      ]);
      expect(names(ranked), ['Jan Novák', 'Petr Malý']);
      expect(ranked.first.matchId, 'm2');
      expect(ranked.first.total, 571);
    });

    test('by the slug: two players of one name are two entries; without '
        'slugs the name is the player', () {
      final twoJans = weekRanked([
        line('Jan Novák', 540, slug: 'jan-novak'),
        line('Jan Novák', 530, slug: 'jan-novak-2'),
      ]);
      expect(twoJans.length, 2);
      final noSlugs = weekRanked([
        WeekLine(
          matchId: 'm1',
          date: Day(2026, 10, 6),
          playerName: 'Jan Novák',
          total: 540,
        ),
        WeekLine(
          matchId: 'm2',
          date: Day(2026, 10, 10),
          playerName: 'Jan Novák',
          total: 560,
        ),
      ]);
      expect(noSlugs.single.matchId, 'm2');
    });

    test('weekPlaces: equal pins and errors share a place, the next one '
        'skips it', () {
      final ranked = weekRanked([
        line('A', 600),
        line('B', 580, errors: 2),
        line('C', 580, errors: 2),
        line('D', 580, errors: 5),
        line('E', 570),
      ]);
      expect(weekPlaces(ranked), [1, 2, 2, 4, 5]);
      expect(weekPlaces(const []), isEmpty);
    });
  });

  group('categories, groups, filters', () {
    test('weekCategories: Muži 120, Ženy 120, Muži 100, Ženy 100 — empty '
        'ones left out, unknown gender or throws in none', () {
      final categories = weekCategories([
        line('Jana Pavlů', 410, throws: 100, gender: WeekGender.female),
        line('Tomáš Pavlů', 590),
        line('Petr Malý', 600),
        line('Bez Pohlaví', 650, gender: null),
        line('Bez Hodů', 650, throws: null),
        line('Eva Malá', 520, gender: WeekGender.female),
      ]);
      expect(categories.keys, [
        WeekCategory.men120,
        WeekCategory.women120,
        WeekCategory.women100,
      ]);
      expect(names(categories[WeekCategory.men120]!), [
        'Petr Malý',
        'Tomáš Pavlů',
      ]);
      expect(names(categories[WeekCategory.women120]!), ['Eva Malá']);
      expect(names(categories[WeekCategory.women100]!), ['Jana Pavlů']);
      expect(WeekCategory.men120.label, 'Muži · 120 HS');
      expect(WeekCategory.women100.label, 'Ženy · 100 HS');
      expect(weekCategories(const []), isEmpty);
    });

    test('weekByCompetition: groups in Czech order, each ranked, every '
        'line in one — unknown gender too; none named last', () {
      final groups = weekByCompetition([
        line('A', 500, competition: 'Divize AS'),
        line('B', 520, competition: 'Česká liga', gender: null),
        line('C', 510, competition: 'Celostátní liga', throws: null),
        line('D', 530, competition: 'Divize AS'),
        line('E', 480, competition: null),
      ]);
      expect([for (final g in groups) g.name], [
        'Celostátní liga',
        'Česká liga',
        'Divize AS',
        weekOtherGroup,
      ]);
      expect(names(groups[2].lines), ['D', 'A']);
      expect(names(groups.last.lines), ['E']);
    });

    test('weekByClub: by our team\'s club, Czech order, with its colour; '
        'teams without a club last', () {
      final groups = weekByClub([
        line('A', 500, clubId: 's', clubName: 'Sokol', clubColor: 2),
        line('B', 520, clubId: 'c', clubName: 'Čechie', clubColor: 5),
        line('C', 540),
        line('D', 560, clubId: 's', clubName: 'Sokol', clubColor: 2),
      ]);
      expect([for (final g in groups) g.name], [
        'Čechie',
        'Sokol',
        weekOtherGroup,
      ]);
      expect([for (final g in groups) g.color], [5, 2, -1]);
      expect(names(groups[1].lines), ['D', 'A']);
    });

    test('weekWhere: home, away or all', () {
      final lines = [
        line('Doma', 500),
        line('Venku', 510, away: true),
      ];
      expect(names(weekWhere(lines)), ['Doma', 'Venku']);
      expect(names(weekWhere(lines, away: false)), ['Doma']);
      expect(names(weekWhere(lines, away: true)), ['Venku']);
    });
  });

  group('the week', () {
    test('previousWeekMonday: the Monday of the week before, from Monday '
        '00:00 on', () {
      // Thursday.
      expect(previousWeekMonday(DateTime(2026, 10, 15, 12)), Day(2026, 10, 5));
      // Monday just past midnight: last week is the one that just ended.
      expect(previousWeekMonday(DateTime(2026, 10, 12, 0, 30)), Day(2026, 10, 5));
      // Sunday late: the week is still on, the one before it shows.
      expect(previousWeekMonday(DateTime(2026, 10, 11, 23, 30)), Day(2026, 9, 28));
    });

    test('previousWeekMonday reads a UTC instant on the Prague clock', () {
      // Monday 00:30 in Prague (CEST, UTC+2) is still Sunday in UTC.
      expect(
        previousWeekMonday(DateTime.utc(2026, 10, 11, 22, 30)),
        Day(2026, 10, 5),
      );
      // Sunday 23:30 in Prague.
      expect(
        previousWeekMonday(DateTime.utc(2026, 10, 11, 21, 30)),
        Day(2026, 9, 28),
      );
      // Monday 00:30 after the clocks went back (CET, UTC+1).
      expect(
        previousWeekMonday(DateTime.utc(2026, 10, 25, 23, 30)),
        Day(2026, 10, 19),
      );
    });

    test('weekRangeLabel: the month once when shared', () {
      expect(weekRangeLabel(Day(2026, 10, 5)), '5.–11. 10.');
      expect(weekRangeLabel(Day(2026, 9, 28)), '28. 9.–4. 10.');
      expect(weekRangeLabel(Day(2026, 12, 28)), '28. 12.–3. 1.');
    });
  });

  group('loadWeekLines', () {
    final monday = Day(2026, 10, 5);

    test('every line with a slug has its gender: one read, no lookup', () async {
      var reads = 0;
      var lookups = 0;
      final lines = await loadWeekLines(
        monday,
        read: (m) async {
          expect(m, monday);
          reads++;
          return [
            line('Jan Novák', 500),
            WeekLine(
              matchId: 'm1',
              date: monday,
              playerName: 'Bez Slugu',
              total: 480,
            ),
          ];
        },
        lookup: (_) async {
          lookups++;
          return false;
        },
      );
      expect(reads, 1);
      expect(lookups, 0);
      expect(lines.length, 2);
    });

    test('a gender missing: asks while there is more, at most four times, '
        'then reads again', () async {
      var reads = 0;
      var lookups = 0;
      final lines = await loadWeekLines(
        monday,
        read: (_) async {
          reads++;
          return [
            line('Jan Novák', 500, gender: reads == 1 ? null : WeekGender.male),
          ];
        },
        lookup: (m) async {
          expect(m, monday);
          lookups++;
          return true;
        },
      );
      expect(lookups, weekGenderRounds);
      expect(reads, 2);
      expect(lines.single.gender, WeekGender.male);
    });

    test('the lookup done in one round: no second ask', () async {
      var lookups = 0;
      await loadWeekLines(
        monday,
        read: (_) async => [line('Jan Novák', 500, gender: null)],
        lookup: (_) async {
          lookups++;
          return false;
        },
      );
      expect(lookups, 1);
    });

    test('a failed lookup still reads again (an earlier round may have '
        'found some); a failed second read keeps the first', () async {
      final errors = <Object>[];
      var reads = 0;
      final again = await loadWeekLines(
        monday,
        read: (_) async {
          reads++;
          return [line('Jan Novák', 500 + reads, gender: null)];
        },
        lookup: (_) async => throw StateError('offline'),
        onError: errors.add,
      );
      expect(reads, 2);
      expect(again.single.total, 502);
      expect(errors.single, isA<StateError>());

      errors.clear();
      reads = 0;
      final first = await loadWeekLines(
        monday,
        read: (_) async {
          if (++reads > 1) throw StateError('offline');
          return [line('Jan Novák', 500, gender: null)];
        },
        lookup: (_) async => false,
        onError: errors.add,
      );
      expect(first.single.total, 500);
      expect(errors.single, isA<StateError>());
    });

    test('a failed first read is the caller\'s error', () async {
      await expectLater(
        loadWeekLines(
          monday,
          read: (_) async => throw StateError('offline'),
          lookup: (_) async => false,
        ),
        throwsStateError,
      );
    });
  });
}
```

- [ ] **Step 2: Run it — it must fail**

Run: `cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/domain/week_players_test.dart`
Expected: FAIL — compilation error `Error when reading 'lib/domain/week_players.dart': No such file or directory` (and `Undefined name` errors for every symbol).

- [ ] **Step 3: Implement `lib/domain/week_players.dart`**

```dart
/// „Hráči týdne“ on the kiosk (0078), the pure half: the lines of the
/// alley's own players in the previous week's matches, as the server's
/// `kiosk_week_players` returns them, sorted into the rankings the card and
/// its full-screen detail show. Pure Dart, unit-tested; kiosk_week.dart only
/// renders it.
///
/// A ranking is ordered by result, best first — the one deliberate
/// exception to the app's rule that lists go alphabetically or
/// chronologically: a ranking is what the module is. The groups of the
/// detail (competitions, clubs) are still alphabetical.
library;

import 'collation.dart';
import 'kiosk_panel.dart' show mondayOf;
import 'models.dart';

/// A player's gender as the ČKA register gives it (0078).
enum WeekGender { male, female }

/// One line of ours in a finished match of the week: one player's whole
/// game (a substitute's shared line never comes — the server leaves it
/// out).
class WeekLine {
  const WeekLine({
    required this.matchId,
    required this.date,
    required this.playerName,
    this.playerSlug,
    required this.total,
    this.errors = 0,
    this.throws,
    this.isAway = false,
    this.competition,
    this.teamName = '',
    this.opponent = '',
    this.clubId,
    this.clubName,
    this.clubColor = -1,
    this.gender,
  });

  /// The match (`priority_slots.id`): a tap on the line opens its Zápis.
  final String matchId;
  final Day date;
  final String playerName;

  /// The results service's slug of the player; null when the site gave
  /// none.
  final String? playerSlug;

  /// Pins knocked down.
  final int total;
  final int errors;

  /// 120 or 100 throws; null when neither the match's discipline nor its
  /// lanes tell.
  final int? throws;

  /// The alley's home or away, as on the board — not the line's side.
  final bool isAway;
  final String? competition;

  /// Our team, by the app's name for it.
  final String teamName;

  /// The other side's team, as the site names it.
  final String opponent;

  /// Our team's club (`teams.club_id`) and its name and palette colour
  /// (-1 = none); all three empty for a team without a club.
  final String? clubId;
  final String? clubName;
  final int clubColor;

  /// Null = the register has not said (yet).
  final WeekGender? gender;

  factory WeekLine.fromJson(Map<String, dynamic> json) {
    final slug = json['player_slug'] as String?;
    return WeekLine(
      matchId: json['match_id'] as String,
      date: Day.parse(json['date'] as String),
      playerName: json['player_name'] as String? ?? '',
      playerSlug: slug == null || slug.isEmpty ? null : slug,
      total: (json['total'] as num).toInt(),
      errors: (json['errors'] as num?)?.toInt() ?? 0,
      throws: (json['throws'] as num?)?.toInt(),
      isAway: json['is_away'] as bool? ?? false,
      competition: json['competition'] as String?,
      teamName: json['team_name'] as String? ?? '',
      opponent: json['opponent'] as String? ?? '',
      clubId: json['club_id'] as String?,
      clubName: json['club_name'] as String?,
      clubColor: (json['club_color'] as num?)?.toInt() ?? -1,
      // Only the two codes the server writes; anything else is unknown.
      gender: switch (json['gender']) {
        'm' => WeekGender.male,
        'f' => WeekGender.female,
        _ => null,
      },
    );
  }

  /// Who the line is: the slug, else the name — one entry per player in a
  /// ranking ([weekRanked]).
  String get key => playerSlug ?? playerName;

  /// The register could still tell this player's gender: the lookup goes
  /// by the slug, a line without one is never asked about.
  bool get needsGender => playerSlug != null && gender == null;
}

/// The card's and the detail's categories, in this order. A line of an
/// unknown gender or number of throws is in none of them — only in the
/// competitions and the clubs.
enum WeekCategory {
  men120(WeekGender.male, 120, 'Muži · 120 HS'),
  women120(WeekGender.female, 120, 'Ženy · 120 HS'),
  men100(WeekGender.male, 100, 'Muži · 100 HS'),
  women100(WeekGender.female, 100, 'Ženy · 100 HS');

  const WeekCategory(this.gender, this.throws, this.label);

  final WeekGender gender;
  final int throws;
  final String label;
}

/// Best first: more pins, then fewer errors, then the name (Czech
/// alphabetical) and the player's key, so the order never depends on the
/// order the lines came in.
int _better(WeekLine a, WeekLine b) {
  final byTotal = b.total.compareTo(a.total);
  if (byTotal != 0) return byTotal;
  final byErrors = a.errors.compareTo(b.errors);
  if (byErrors != 0) return byErrors;
  final byName = compareCzech(a.playerName, b.playerName);
  if (byName != 0) return byName;
  return a.key.compareTo(b.key);
}

/// [lines] as a ranking: one entry per player ([WeekLine.key]) with his
/// best line — two matches in a week do not take two places — best first.
List<WeekLine> weekRanked(List<WeekLine> lines) {
  final best = <String, WeekLine>{};
  for (final line in lines) {
    final held = best[line.key];
    if (held == null || _better(line, held) < 0) best[line.key] = line;
  }
  return best.values.toList()..sort(_better);
}

/// The places of a [ranked] list: 1, 2, 3 … — equal pins and errors share
/// a place, and the next one skips it (1, 2, 2, 4).
List<int> weekPlaces(List<WeekLine> ranked) {
  final places = <int>[];
  for (final (i, line) in ranked.indexed) {
    final prev = i == 0 ? null : ranked[i - 1];
    places.add(
      prev != null && prev.total == line.total && prev.errors == line.errors
          ? places.last
          : i + 1,
    );
  }
  return places;
}

/// The categories that have a line, each ranked ([weekRanked]), in
/// [WeekCategory] order.
Map<WeekCategory, List<WeekLine>> weekCategories(List<WeekLine> lines) {
  final out = <WeekCategory, List<WeekLine>>{};
  for (final category in WeekCategory.values) {
    final ranked = weekRanked([
      for (final l in lines)
        if (l.gender == category.gender && l.throws == category.throws) l,
    ]);
    if (ranked.isNotEmpty) out[category] = ranked;
  }
  return out;
}

/// The group of the lines without a competition or a club: last, after the
/// named ones (the name picker's word for players without a club).
const weekOtherGroup = 'Ostatní';

/// [lines] by competition, Czech alphabetical, each ranked; lines without a
/// competition last, under [weekOtherGroup].
List<({String name, List<WeekLine> lines})> weekByCompetition(
  List<WeekLine> lines,
) {
  final byName = <String, List<WeekLine>>{};
  final other = <WeekLine>[];
  for (final line in lines) {
    final name = line.competition;
    if (name == null || name.isEmpty) {
      other.add(line);
    } else {
      (byName[name] ??= []).add(line);
    }
  }
  final names = byName.keys.toList()..sort(compareCzech);
  return [
    for (final name in names) (name: name, lines: weekRanked(byName[name]!)),
    if (other.isNotEmpty) (name: weekOtherGroup, lines: weekRanked(other)),
  ];
}

/// [lines] by our team's club, Czech alphabetical by its name, each ranked,
/// with the club's palette colour; the teams without a club last, under
/// [weekOtherGroup] (colour -1).
List<({String name, int color, List<WeekLine> lines})> weekByClub(
  List<WeekLine> lines,
) {
  final byClub = <String, List<WeekLine>>{};
  final other = <WeekLine>[];
  for (final line in lines) {
    final id = line.clubId;
    if (id == null) {
      other.add(line);
    } else {
      (byClub[id] ??= []).add(line);
    }
  }
  final groups = [
    for (final club in byClub.values)
      (
        name: club.first.clubName ?? '',
        color: club.first.clubColor,
        lines: weekRanked(club),
      ),
  ]..sort((a, b) => compareCzech(a.name, b.name));
  return [
    ...groups,
    if (other.isNotEmpty)
      (name: weekOtherGroup, color: -1, lines: weekRanked(other)),
  ];
}

/// [lines] played at home ([away] false), away (true) or all (null).
List<WeekLine> weekWhere(List<WeekLine> lines, {bool? away}) => away == null
    ? lines
    : [
        for (final l in lines)
          if (l.isAway == away) l,
      ];

/// The Monday of the week before [now]'s, by the kiosk's wall clock (the
/// device's zone, Prague): what „Hráči týdne“ shows from Monday 00:00 on.
/// A UTC instant is read on that clock too.
Day previousWeekMonday(DateTime now) =>
    mondayOf(Day.fromDateTime(now.toLocal())).addDays(-7);

/// „5.–11. 10.“ — the week from [monday] to its Sunday, the month once
/// when both days share it („28. 9.–4. 10.“ when not), as the duty band's
/// short range.
String weekRangeLabel(Day monday) {
  final sunday = monday.addDays(6);
  final start = monday.month == sunday.month
      ? '${monday.day}.'
      : '${monday.day}. ${monday.month}.';
  return '$start–${sunday.day}. ${sunday.month}.';
}

/// How many times one read asks for the week's genders: each ask covers
/// a limited number of players (regnum-lookup's budget).
const weekGenderRounds = 4;

/// The week from [monday] as the kiosk reads it: [read] the lines; while a
/// line with a slug lacks its gender, [lookup] the genders in rounds while
/// it says there are more (at most [rounds]), then [read] again. The
/// genders are best effort: a failed lookup, or a failed second read,
/// leaves the first read ([onError] hears why). A failed first read throws.
Future<List<WeekLine>> loadWeekLines(
  Day monday, {
  required Future<List<WeekLine>> Function(Day monday) read,
  required Future<bool> Function(Day monday) lookup,
  int rounds = weekGenderRounds,
  void Function(Object error)? onError,
}) async {
  final lines = await read(monday);
  if (!lines.any((l) => l.needsGender)) return lines;
  try {
    for (var round = 0; round < rounds; round++) {
      if (!await lookup(monday)) break;
    }
  } catch (e) {
    // A round before the failed one may have found some: read anyway.
    onError?.call(e);
  }
  try {
    return await read(monday);
  } catch (e) {
    onError?.call(e);
    return lines;
  }
}
```

- [ ] **Step 4: Run the test — it must pass**

Run: `cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/domain/week_players_test.dart`
Expected: PASS — `+18: All tests passed!`

- [ ] **Step 5: Commit the pure half**

```bash
cd /Users/mvazan/Home/rezervator
git add lib/domain/week_players.dart test/domain/week_players_test.dart
git commit -m "feat(kiosk): Hráči týdne — řádky týdne, žebříčky a minulý týden v Praze" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 6: `Api.kioskWeekPlayers`, `Api.lookupWeekGenders` and `weekPlayersProvider` in `lib/data/providers.dart`**

(a) Import — old:

```dart
import '../domain/models.dart';
import '../domain/public_week.dart';
```

new:

```dart
import '../domain/models.dart';
import '../domain/public_week.dart';
import '../domain/week_players.dart';
```

(b) After `Api.refreshMatch` — old:

```dart
      await _db.rpc('refresh_match', params: {
        'p_match_id': matchId,
        if (force) 'p_force': true,
      }) as String;
```

new:

```dart
      await _db.rpc('refresh_match', params: {
        'p_match_id': matchId,
        if (force) 'p_force': true,
      }) as String;

  /// „Hráči týdne“ (0078 `kiosk_week_players`): one row per line of the
  /// alley's own players in the finished federation matches of the week
  /// from [monday], computed by the server on every call. Approved members
  /// and the kiosk only (`not_allowed` otherwise).
  static Future<List<WeekLine>> kioskWeekPlayers(Day monday) async => [
        for (final row in await _db.rpc('kiosk_week_players',
            params: {'p_monday': monday.toSql()}) as List)
          WeekLine.fromJson((row as Map).cast<String, dynamic>()),
      ];
```

(c) After `Api.fillProfileRegnums` — old:

```dart
    return (
      filled: data is Map && data['filled'] is int ? data['filled'] as int : 0,
      more: data is Map && data['more'] == true,
    );
  }
```

new:

```dart
    return (
      filled: data is Map && data['filled'] is int ? data['filled'] as int : 0,
      more: data is Map && data['more'] == true,
    );
  }

  /// Asks the server to find in the ČKA register the genders the lines of
  /// the week from [monday] lack (`regnum-lookup` week mode, 0078) — it
  /// reads the lines as the caller, so the kiosk may ask. True: it ran out
  /// of budget before every player — ask again.
  static Future<bool> lookupWeekGenders(Day monday) async {
    final response = await _db.functions.invoke(
      'regnum-lookup',
      body: {'mode': 'week', 'monday': monday.toSql()},
    );
    final data = response.data;
    return data is Map && data['more'] == true;
  }
```

(d) After `profileRegnumsProvider` — old:

```dart
    // What a round before a failed one filled is on the profiles already.
    if (filled > 0 && ref.mounted) ref.invalidate(contactsProvider);
    return filled;
  },
  retry: (_, _) => null,
);
```

new:

```dart
    // What a round before a failed one filled is on the profiles already.
    if (filled > 0 && ref.mounted) ref.invalidate(contactsProvider);
    return filled;
  },
  retry: (_, _) => null,
);

/// „Hráči týdne“ on the kiosk (0078): the lines of the alley's own players
/// in the finished matches of the previous Monday–Sunday in Prague
/// ([previousWeekMonday] of the app clock). Computed by the server on every
/// read — a late fetch, a correction within 14 days or a gender found later
/// all change a past week — and read again every hour, at the week's turn
/// (Monday 00:00 is an hour's turn too) and when the app wakes. While lines
/// lack a gender, each read first lets the server look them up
/// ([loadWeekLines]). A failed read keeps the lines shown before it.
final weekPlayersProvider = FutureProvider<List<WeekLine>>((ref) async {
  if (ref.watch(_authUidProvider) == null) return const [];
  // The minute clock reaches this provider only when the hour or the week
  // turns.
  final (monday, _) = ref.watch(
    nowProvider.select((now) {
      final t = now.value ?? DateTime.now();
      return (previousWeekMonday(t), t.hour);
    }),
  );
  final wake = LiveRefresh.stream.listen((_) => ref.invalidateSelf());
  ref.onDispose(wake.cancel);
  return loadWeekLines(
    monday,
    read: Api.kioskWeekPlayers,
    lookup: Api.lookupWeekGenders,
    onError: (e) => debugPrint('Hráči týdne $monday: $e'),
  );
});
```

(e) In `resetTenantScopedProviders` — old:

```dart
  ref.invalidate(matchResultsProvider);
  ref.invalidate(leagueMatchesProvider);
```

new:

```dart
  ref.invalidate(matchResultsProvider);
  ref.invalidate(weekPlayersProvider);
  ref.invalidate(leagueMatchesProvider);
```

- [ ] **Step 7: Analyze and re-run**

Run: `cd /Users/mvazan/Home/rezervator && flutter analyze lib/data/providers.dart lib/domain/week_players.dart test/domain/week_players_test.dart`
Expected: `No issues found!`

Run: `cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/domain/week_players_test.dart`
Expected: PASS — `+18: All tests passed!`

- [ ] **Step 8: Commit the data access**

```bash
cd /Users/mvazan/Home/rezervator
git add lib/data/providers.dart
git commit -m "feat(kiosk): Hráči týdne — čtení týdne ze serveru a dohledání pohlaví" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: `KioskWeekCard`, the full-screen detail and the module in the panels

**Files:**
- Create: `lib/features/kiosk/kiosk_week.dart`
- Create: `test/features/kiosk_week_test.dart`
- Modify: `lib/features/kiosk/kiosk_info_panel.dart` (import; `kioskPanelContentProvider`'s `week` arm; `KioskPanelView.onOpenWeek` and the week card replacing Task 3's placeholder)
- Modify: `lib/features/kiosk/kiosk_shell.dart` (import; `_openWeek`; `onOpenWeek: _openWeek` in `panel(…)`)

**Interfaces:**
- Consumes: everything Task 11 produces; `KioskCard` (public frame of a module, `kiosk_info_panel.dart`: `icon`, `title`, `child`, `fill`, `action`); Task 3's `kioskPanelContentProvider` (`Provider.family<KioskPanelContent?, PanelSide>`, local helper `here(KioskModule)`), `KioskPanelContent({side, entries, notices, hasMatches, live, duty})`, `KioskPanelEntry(module, share)`, `KioskPanelView({side, width, content, open, hidden, onOpenNotice, onOpenMatch, onPlay, resetToken, boardDays, showLive, onShowLive})` and its local `card(KioskModule)` switch; Task 7's `onOpenGuide` / `_openGuide` (only as anchors for the edits); Task 2's `KioskPanels`, `KioskPanel`, `KioskModulePlacement(id:, side:, share:)`, `KioskModule`, `PanelSide`, `KioskPanels.defaults.withSide(…)`, `.withPanel(side, open:)`; `prioritySlotsProvider`; `ClubColors.of(int, Brightness)` (`lib/domain/palette.dart`); the shell's `_touchable`, `_openMatch`, `_resets`.
- Produces: `class KioskWeekCard extends ConsumerWidget` (`const KioskWeekCard({super.key, required this.onOpen})`), `Future<void> showKioskWeekPlayers(BuildContext context, {required Widget Function(Widget) wrap, required void Function(PrioritySlot) onOpenMatch})` (contract); also `class KioskWeekPlayersPage extends ConsumerStatefulWidget` (public, the detail's page — found by type in tests, like `KioskGuideDialog`) and `KioskPanelView.onOpenWeek` (`VoidCallback?`, beside Task 7's `onOpenGuide`).

Behaviour pinned here (spec Part 3 · Client):
- Card: `KioskCard(icon: Icons.emoji_events_outlined, title: 'HRÁČI TÝDNE · 5.–11. 10.', fill: true)`; the categories that fit whole (measured with `TextPainter` at the visitor's text scale, as the guide card), each its best three — „1. Jan Novák“ + „598“ and, smaller, „Termínátor A · doma“; „Více“ (Nástěnka's footer) when categories were left out; the first one is always shown (clipped when even it does not fit). A tap anywhere → `onOpen`. Equal pins and errors share a place (`weekPlaces`).
- Gap the spec leaves open, filled here: while the week has lines but none with a known gender and number of throws (right after 0078, before the lookups), the card stacks the competitions instead of the categories, so a module the panel shows is never empty.
- Detail: `showGeneralDialog` covering the whole screen, faded in like the Zápis, `wrap` = the shell's `_touchable` (kiosk theme, touches count, the idle reset pops it); „Hráči týdne 5.–11. 10.“ and a close button (tooltip „Zavřít“); chips **Vše / Doma / Venku** (`weekWhere`); segments **Kategorie / Soutěže / Oddíly**; one column per group (each ≥ 320 px, sharing the width, else a horizontal `ListView`); each a full ranking: place, name, result, and smaller „team – opponent · doma/venku“; the club view shows the club's colour dot. A tap on a line → `onOpenMatch(slot)` with the slot from `prioritySlotsProvider` by `matchId` (a match the slots do not hold opens nothing). Nothing for a filter: „Žádné výsledky pro tento výběr.“ (as the results screen's „Žádné zápasy pro tento výběr.“).
- Panel: `week` is content only while `weekPlayersProvider` has lines (read only while the module is placed on that side); the card is keyed by `resetToken` like the other cards.

- [ ] **Step 1: Write the failing widget tests for the card and the detail**

Create `test/features/kiosk_week_test.dart`:

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/theme.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/week_players.dart';
import 'package:rezervator/features/kiosk/kiosk_week.dart';
import 'package:rezervator/features/schedule/widgets/calendar_board.dart'
    show calendarRulerWidth;

/// The app's own font: the test font's glyphs are wider than Manrope's, so
/// a fit measured against it would not be the kiosk's.
Future<void> _loadManrope() async {
  final loader = FontLoader(appFontFamily);
  for (final weight in ['Regular', 'Medium', 'Bold', 'ExtraBold']) {
    final bytes = File('assets/fonts/Manrope-$weight.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

/// „Hráči týdne“ (module `week`, 0078): the card's fit on a Full HD kiosk
/// (the categories that fit, each its best three, „Více“ for the rest), the
/// full-screen detail (chips, segments, columns, the tap to the Zápis), and
/// the module in a panel and in the shell — no line in the week, no room.
void main() {
  setUpAll(_loadManrope);

  // Thursday 15 October: the week shown is 5.–11. 10.
  final now = DateTime(2026, 10, 15, 12);

  // One day column of a Full HD kiosk with 8 days on the screen; a panel
  // is whole columns of it (kioskPanelWidths).
  const column = (1920 - calendarRulerWidth) / 8;
  // The shell's panel at 1080: the status bar and the idle bar take the
  // rest.
  const panelHeight = 981.0;
  // A panel's padding (12 around) and the gap between two modules.
  const pad = 12.0;

  Size cardSize({required int days, required int share}) => Size(
    days * column - 2 * pad,
    share == 100
        ? panelHeight - 2 * pad
        : (panelHeight - 2 * pad - pad) * share / 100,
  );

  void fullHd(WidgetTester tester) {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  WeekLine line(
    String name,
    int total, {
    WeekGender? gender = WeekGender.male,
    int? throws = 120,
    bool away = false,
    String match = 'm1',
    String competition = 'Divize AS',
    String team = 'Termínátor A',
    String? clubId = 'c1',
    String? clubName = 'Termínátor',
    int clubColor = 4,
  }) => WeekLine(
    matchId: match,
    date: Day(2026, 10, 10),
    playerName: name,
    playerSlug: name.toLowerCase().replaceAll(' ', '-'),
    total: total,
    throws: throws,
    isAway: away,
    competition: competition,
    teamName: team,
    opponent: 'KK Slavoj',
    clubId: clubId,
    clubName: clubName,
    clubColor: clubColor,
    gender: gender,
  );

  // Four players in each of the four categories.
  final week = [
    for (final (category, gender, throws) in const [
      ('M', WeekGender.male, 120),
      ('Z', WeekGender.female, 120),
      ('N', WeekGender.male, 100),
      ('R', WeekGender.female, 100),
    ])
      for (var i = 0; i < 4; i++)
        line(
          'Hráč $category$i',
          600 - 10 * i,
          gender: gender,
          throws: throws,
          away: i.isOdd,
        ),
  ];

  List<Override> overrides(List<WeekLine> lines) => [
    nowProvider.overrideWith((ref) => Stream.value(now)),
    weekPlayersProvider.overrideWith((ref) async => lines),
  ];

  Future<void> pumpCard(
    WidgetTester tester,
    Size size,
    List<WeekLine> lines, {
    VoidCallback? onOpen,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(lines),
        child: MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox.fromSize(
                size: size,
                child: KioskWeekCard(onOpen: onOpen ?? () {}),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  final more = find.text('Více');

  group('KioskWeekCard', () {
    testWidgets('the title names the week; alone in a panel every category '
        'fits, each its best three', (tester) async {
      fullHd(tester);
      await pumpCard(tester, cardSize(days: 2, share: 100), week);
      expect(find.text('HRÁČI TÝDNE · 5.–11. 10.'), findsOneWidget);
      for (final category in WeekCategory.values) {
        expect(find.text(category.label), findsOneWidget);
      }
      expect(find.text('1. Hráč M0'), findsOneWidget);
      expect(find.text('600'), findsNWidgets(4));
      expect(find.text('3. Hráč M2'), findsOneWidget);
      // The fourth is in the detail only.
      expect(find.text('4. Hráč M3'), findsNothing);
      expect(find.text('Termínátor A · doma'), findsNWidgets(8));
      expect(find.text('Termínátor A · venku'), findsNWidgets(4));
      expect(more, findsNothing);
    });

    testWidgets('at 30 % only the categories that fit whole, „Více“ for '
        'the rest', (tester) async {
      fullHd(tester);
      await pumpCard(tester, cardSize(days: 2, share: 30), week);
      expect(find.text(WeekCategory.men120.label), findsOneWidget);
      expect(find.text(WeekCategory.women100.label), findsNothing);
      expect(more, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('one entry per player: two matches in the week, his best '
        'line once', (tester) async {
      fullHd(tester);
      await pumpCard(tester, cardSize(days: 2, share: 100), [
        line('Jan Novák', 571, match: 'm1'),
        line('Jan Novák', 590, match: 'm2', away: true),
        line('Petr Malý', 580),
      ]);
      expect(find.text('1. Jan Novák'), findsOneWidget);
      expect(find.text('2. Petr Malý'), findsOneWidget);
      expect(find.textContaining('Jan Novák'), findsOneWidget);
      expect(find.text('590'), findsOneWidget);
      expect(find.text('571'), findsNothing);
    });

    testWidgets('no gender known yet: the competitions instead of the '
        'categories', (tester) async {
      fullHd(tester);
      await pumpCard(tester, cardSize(days: 2, share: 55), [
        line('Jan Novák', 571, gender: null),
        line('Petr Malý', 580, gender: null, competition: '1. KLM'),
      ]);
      expect(find.text('1. KLM'), findsOneWidget);
      expect(find.text('Divize AS'), findsOneWidget);
      expect(find.text('1. Petr Malý'), findsOneWidget);
    });

    testWidgets('a tap anywhere on the card opens the week', (tester) async {
      fullHd(tester);
      var opened = 0;
      await pumpCard(
        tester,
        cardSize(days: 2, share: 30),
        week,
        onOpen: () => opened++,
      );
      await tester.tap(find.text('HRÁČI TÝDNE · 5.–11. 10.'));
      await tester.tap(more);
      await tester.tap(find.text('1. Hráč M0'));
      expect(opened, 3);
    });
  });

  group('showKioskWeekPlayers', () {
    PrioritySlot slot(String id) => PrioritySlot(
      id: id,
      date: Day(2026, 10, 10),
      startsAt: const HourMinute(14, 0),
      endsAt: const HourMinute(17, 0),
      type: PrioritySlot.fallbackMatchType,
      homeTeam: 'Termínátor A',
      awayTeam: 'KK Slavoj',
      importKey: 'cka:$id',
    );

    Future<List<PrioritySlot>> pumpDetail(
      WidgetTester tester,
      List<WeekLine> lines, {
      List<PrioritySlot>? slots,
    }) async {
      final opened = <PrioritySlot>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...overrides(lines),
            prioritySlotsProvider.overrideWithValue(
              slots ?? [slot('m1'), slot('m2')],
            ),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showKioskWeekPlayers(
                    context,
                    wrap: (child) =>
                        Theme(data: buildTheme(Brightness.dark), child: child),
                    onOpenMatch: opened.add,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return opened;
    }

    final page = find.byType(KioskWeekPlayersPage);
    Finder inPage(Finder f) => find.descendant(of: page, matching: f);

    testWidgets('full screen in the theme [wrap] gives it: the title, one '
        'column per category, each a full ranking; „Zavřít“ closes it', (
      tester,
    ) async {
      fullHd(tester);
      await pumpDetail(tester, week);
      expect(tester.getSize(page).width, 1920);
      expect(tester.getSize(page).height, 1080);
      expect(Theme.of(tester.element(page)).brightness, Brightness.dark);
      expect(find.text('Hráči týdne 5.–11. 10.'), findsOneWidget);
      for (final category in WeekCategory.values) {
        expect(inPage(find.text(category.label)), findsOneWidget);
      }
      // All four of a category, the fourth too.
      expect(inPage(find.text('Hráč M3')), findsOneWidget);
      expect(
        inPage(find.text('Termínátor A – KK Slavoj · venku')),
        findsNWidgets(8),
      );
      // Side by side: men's 120 left of women's.
      expect(
        tester.getCenter(find.text(WeekCategory.men120.label)).dx,
        lessThan(tester.getCenter(find.text(WeekCategory.women120.label)).dx),
      );

      await tester.tap(find.byTooltip('Zavřít'));
      await tester.pumpAndSettle();
      expect(page, findsNothing);
    });

    testWidgets('Doma / Venku keep the lines played there; Vše all', (
      tester,
    ) async {
      fullHd(tester);
      await pumpDetail(tester, week);
      await tester.tap(find.text('Venku'));
      await tester.pumpAndSettle();
      expect(inPage(find.text('Hráč M1')), findsOneWidget);
      expect(inPage(find.text('Hráč M0')), findsNothing);
      // Ranked among themselves: first of its column.
      expect(
        find.descendant(
          of: find
              .ancestor(of: find.text('Hráč M1'), matching: find.byType(Row))
              .first,
          matching: find.text('1.'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Doma'));
      await tester.pumpAndSettle();
      expect(inPage(find.text('Hráč M0')), findsOneWidget);
      expect(inPage(find.text('Hráč M1')), findsNothing);

      await tester.tap(find.text('Vše'));
      await tester.pumpAndSettle();
      expect(inPage(find.text('Hráč M0')), findsOneWidget);
      expect(inPage(find.text('Hráč M1')), findsOneWidget);
    });

    testWidgets('Soutěže and Oddíly: a column per competition and per club, '
        'Czech order, the ones without one last; unknown gender there too', (
      tester,
    ) async {
      fullHd(tester);
      final lines = [
        line('Jan Novák', 571),
        line('Eva Malá', 520, competition: 'Česká liga', gender: null),
        line(
          'Petr Malý',
          580,
          competition: 'Celostátní liga',
          clubId: null,
          clubName: null,
          clubColor: -1,
        ),
        line(
          'Ota Bílý',
          560,
          clubId: 'c2',
          clubName: 'Čechie',
          clubColor: 2,
        ),
      ];
      await pumpDetail(tester, lines);
      // Eva's gender is unknown: in no category.
      expect(inPage(find.text('Eva Malá')), findsNothing);

      await tester.tap(find.text('Soutěže'));
      await tester.pumpAndSettle();
      final competitions = [
        for (final name in ['Celostátní liga', 'Česká liga', 'Divize AS'])
          tester.getCenter(inPage(find.text(name))).dx,
      ];
      expect(competitions, orderedEquals([...competitions]..sort()));
      expect(inPage(find.text('Eva Malá')), findsOneWidget);

      await tester.tap(find.text('Oddíly'));
      await tester.pumpAndSettle();
      final clubs = [
        for (final name in ['Čechie', 'Termínátor', weekOtherGroup])
          tester.getCenter(inPage(find.text(name))).dx,
      ];
      expect(clubs, orderedEquals([...clubs]..sort()));
    });

    testWidgets('columns that do not fit scroll sideways', (tester) async {
      fullHd(tester);
      await pumpDetail(tester, [
        for (var i = 0; i < 8; i++)
          line('Hráč $i', 500 + i, competition: 'Soutěž $i'),
      ]);
      await tester.tap(find.text('Soutěže'));
      await tester.pumpAndSettle();
      expect(inPage(find.text('Soutěž 0')), findsOneWidget);
      expect(inPage(find.text('Soutěž 7')), findsNothing);
      await tester.drag(find.text('Soutěž 0'), const Offset(-2000, 0));
      await tester.pumpAndSettle();
      expect(inPage(find.text('Soutěž 7')), findsOneWidget);
    });

    testWidgets('a tap on a line opens that match\'s Zápis; a match the '
        'slots do not hold opens nothing', (tester) async {
      fullHd(tester);
      final opened = await pumpDetail(
        tester,
        [
          line('Jan Novák', 571, match: 'm2'),
          line('Petr Malý', 560, match: 'gone'),
        ],
      );
      await tester.tap(inPage(find.text('Jan Novák')));
      await tester.tap(inPage(find.text('Petr Malý')));
      expect([for (final s in opened) s.id], ['m2']);
    });

    testWidgets('nothing for the filter: says so', (tester) async {
      fullHd(tester);
      await pumpDetail(tester, [line('Jan Novák', 571)]);
      await tester.tap(find.text('Venku'));
      await tester.pumpAndSettle();
      expect(find.text('Žádné výsledky pro tento výběr.'), findsOneWidget);
    });
  });
}
```

- [ ] **Step 2: Run them — they must fail**

Run: `cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/features/kiosk_week_test.dart`
Expected: FAIL — compilation error `Error when reading 'lib/features/kiosk/kiosk_week.dart': No such file or directory`.

- [ ] **Step 3: Implement `lib/features/kiosk/kiosk_week.dart`**

```dart
/// „Hráči týdne“ on the kiosk (the panels' module `week`, 0078): the best
/// results of the alley's own players in the previous Monday–Sunday. The
/// card shows as many categories as fit, each with its best three, and a
/// tap anywhere on it opens the whole week full screen
/// ([showKioskWeekPlayers]): every player of ours, home, away or both,
/// ranked by category, competition or club — a tap on a line opens that
/// match's Zápis. Display only, like the rest of the panels; the rankings
/// themselves are pure (week_players.dart).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/palette.dart';
import '../../domain/week_players.dart';
import 'kiosk_info_panel.dart' show KioskCard;

const _blockTitleStyle = TextStyle(fontSize: 15, fontWeight: FontWeight.w800);
const _entryStyle = TextStyle(fontSize: 17, fontWeight: FontWeight.w700);
const _entryTeamStyle = TextStyle(fontSize: 13);
const _titleGap = 4.0;
const _entryGap = 6.0;
const _blockGap = 14.0;

/// The „Více“ line under the blocks that fit (as Nástěnka's).
const _footerHeight = 32.0;

/// How many players of a category the card lists.
const _cardTop = 3;

/// The week's Monday by the app clock: what the title names — the same one
/// [weekPlayersProvider] reads, flipping with it at Monday 00:00.
Day _monday(WidgetRef ref) => ref.watch(
  nowProvider.select((now) => previousWeekMonday(now.value ?? DateTime.now())),
);

/// „doma“ / „venku“: the alley's home or away, as on the board.
String _where(WeekLine line) => line.isAway ? 'venku' : 'doma';

/// What the card stacks: the categories, ranked — or, while no line has a
/// known gender and number of throws yet (the register still being asked),
/// the competitions, so the card is never empty with lines in the week.
List<({String title, List<WeekLine> lines})> _cardBlocks(
  List<WeekLine> lines,
) {
  final categories = weekCategories(lines);
  if (categories.isNotEmpty) {
    return [
      for (final MapEntry(key: category, value: ranked) in categories.entries)
        (title: category.label, lines: ranked),
    ];
  }
  return [
    for (final group in weekByCompetition(lines))
      (title: group.name, lines: group.lines),
  ];
}

/// The card: „HRÁČI TÝDNE · 5.–11. 10.“, then the categories that fit
/// whole, each its best three — „1. Jan Novák 598“ and, smaller, „Termínátor
/// A · doma“ — and „Více“ when some were left out (the first one is shown
/// even when cut). A tap anywhere opens the whole week ([onOpen]). The
/// panel shows it only while the week has lines.
class KioskWeekCard extends ConsumerWidget {
  const KioskWeekCard({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final lines = ref.watch(weekPlayersProvider).value ?? const <WeekLine>[];
    final blocks = _cardBlocks(lines);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onOpen,
      child: KioskCard(
        icon: Icons.emoji_events_outlined,
        title: 'HRÁČI TÝDNE · ${weekRangeLabel(_monday(ref))}',
        fill: true,
        child: LayoutBuilder(
          builder: (context, box) {
            final fit = _fit(context, box, blocks);
            final shown = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (i, block) in blocks.take(fit.count).indexed) ...[
                  if (i > 0) const SizedBox(height: _blockGap),
                  _CardBlock(title: block.title, ranked: block.lines),
                ],
              ],
            );
            if (!fit.cut) {
              return Align(alignment: Alignment.topLeft, child: shown);
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ClipRect(
                    child: SingleChildScrollView(
                      physics: const NeverScrollableScrollPhysics(),
                      child: shown,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: _footerHeight - 8,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        'Více',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: scheme.primary,
                        ),
                      ),
                      Icon(Icons.expand_more, size: 20, color: scheme.primary),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// How many of [blocks] the card's interior [box] shows, and whether
  /// some are left out (or the only one shown is cut). Measured with the
  /// styles the lines are drawn in, merged into the ambient one, at the
  /// visitor's text size; every line is one line high (ellipsized).
  ({int count, bool cut}) _fit(
    BuildContext context,
    BoxConstraints box,
    List<({String title, List<WeekLine> lines})> blocks,
  ) {
    if (blocks.isEmpty) return (count: 0, cut: false);
    final base = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    double line(TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: 'Ág', style: base.merge(style)),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final h = painter.height;
      painter.dispose();
      return h;
    }

    final title = line(_blockTitleStyle);
    final entry = line(_entryStyle) + line(_entryTeamStyle);
    double height(int players) {
      final n = math.min(players, _cardTop);
      return title + _titleGap + n * entry + (n - 1) * _entryGap;
    }

    final room = box.hasBoundedHeight ? box.maxHeight : double.infinity;
    var total = 0.0;
    for (final (i, block) in blocks.indexed) {
      total += (i > 0 ? _blockGap : 0) + height(block.lines.length);
    }
    if (total <= room) return (count: blocks.length, cut: false);
    // Not all of them: „Více“ takes its line, the blocks that fit whole
    // above it stay — at least the first one, cut.
    final left = room - _footerHeight;
    var used = 0.0;
    var count = 0;
    for (final block in blocks) {
      final next = (count > 0 ? _blockGap : 0) + height(block.lines.length);
      if (used + next > left) break;
      used += next;
      count++;
    }
    return (count: math.max(count, 1), cut: true);
  }
}

/// One category of the card: its label and its best three.
class _CardBlock extends StatelessWidget {
  const _CardBlock({required this.title, required this.ranked});

  final String title;
  final List<WeekLine> ranked;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final places = weekPlaces(ranked);
    final shown = ranked.take(_cardTop).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _blockTitleStyle.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: _titleGap),
        for (final (i, line) in shown.indexed) ...[
          if (i > 0) const SizedBox(height: _entryGap),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${places[i]}. ${line.playerName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _entryStyle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${line.total}',
                maxLines: 1,
                style: _entryStyle.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          Text(
            '${line.teamName} · ${_where(line)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _entryTeamStyle.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

/// Opens „Hráči týdne“ full screen over the kiosk, fading in like the
/// Zápis. [wrap] is the shell's: the kiosk's theme, and a touch counts for
/// the idle timer — whose reset closes it, with every other route.
/// [onOpenMatch] opens a match's Zápis (over this page).
Future<void> showKioskWeekPlayers(
  BuildContext context, {
  required Widget Function(Widget child) wrap,
  required void Function(PrioritySlot match) onOpenMatch,
}) => showGeneralDialog<void>(
  context: context,
  barrierColor: Colors.black54,
  transitionDuration: const Duration(milliseconds: 250),
  transitionBuilder: (context, animation, _, child) => FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
    child: child,
  ),
  pageBuilder: (context, _, _) =>
      wrap(KioskWeekPlayersPage(onOpenMatch: onOpenMatch)),
);

/// The detail's three ways to group the week.
enum _WeekView { categories, competitions, clubs }

/// One column of the detail: a full ranking, with the club's palette
/// colour in the club view.
typedef _Group = ({String title, int? color, List<WeekLine> lines});

/// The whole week: „Hráči týdne 5.–11. 10.“, chips Vše / Doma / Venku,
/// segments Kategorie / Soutěže / Oddíly, and one column per group — side
/// by side, scrolling sideways when they do not fit. Each column a full
/// ranking: the place, the name, the result, and smaller the team, the
/// opponent and home or away. A tap on a line opens that match's Zápis.
class KioskWeekPlayersPage extends ConsumerStatefulWidget {
  const KioskWeekPlayersPage({super.key, required this.onOpenMatch});

  final void Function(PrioritySlot match) onOpenMatch;

  @override
  ConsumerState<KioskWeekPlayersPage> createState() =>
      _KioskWeekPlayersPageState();
}

class _KioskWeekPlayersPageState extends ConsumerState<KioskWeekPlayersPage> {
  /// Home (false), away (true) or all (null).
  bool? _away;
  _WeekView _view = _WeekView.categories;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lines = weekWhere(
      ref.watch(weekPlayersProvider).value ?? const <WeekLine>[],
      away: _away,
    );
    final slots = {for (final s in ref.watch(prioritySlotsProvider)) s.id: s};
    final List<_Group> groups = switch (_view) {
      _WeekView.categories => [
        for (final MapEntry(key: category, value: ranked)
            in weekCategories(lines).entries)
          (title: category.label, color: null, lines: ranked),
      ],
      _WeekView.competitions => [
        for (final g in weekByCompetition(lines))
          (title: g.name, color: null, lines: g.lines),
      ],
      _WeekView.clubs => [
        for (final g in weekByClub(lines))
          (title: g.name, color: g.color, lines: g.lines),
      ],
    };
    // A line whose match the slots do not hold (yet) opens nothing.
    VoidCallback? open(WeekLine line) => switch (slots[line.matchId]) {
      final slot? => () => widget.onOpenMatch(slot),
      null => null,
    };
    return Material(
      color: scheme.surfaceContainerLowest,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Hráči týdne ${weekRangeLabel(_monday(ref))}',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    iconSize: 32,
                    tooltip: 'Zavřít',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final (label, away) in const [
                    ('Vše', null),
                    ('Doma', false),
                    ('Venku', true),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: _away == away,
                      onSelected: (_) => setState(() => _away = away),
                    ),
                  const SizedBox(width: 16),
                  SegmentedButton<_WeekView>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: _WeekView.categories,
                        label: Text('Kategorie'),
                      ),
                      ButtonSegment(
                        value: _WeekView.competitions,
                        label: Text('Soutěže'),
                      ),
                      ButtonSegment(
                        value: _WeekView.clubs,
                        label: Text('Oddíly'),
                      ),
                    ],
                    selected: {_view},
                    onSelectionChanged: (chosen) =>
                        setState(() => _view = chosen.first),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: groups.isEmpty
                    ? Center(
                        child: Text(
                          'Žádné výsledky pro tento výběr.',
                          style: TextStyle(
                            fontSize: 16,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : _Columns(groups: groups, open: open),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The groups side by side, sharing the width — or, when they would be
/// narrower than [minWidth], each [minWidth] wide in a row that scrolls
/// sideways.
class _Columns extends StatelessWidget {
  const _Columns({required this.groups, required this.open});

  static const minWidth = 320.0;
  static const gap = 16.0;

  final List<_Group> groups;
  final VoidCallback? Function(WeekLine line) open;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final fits =
          groups.length * minWidth + (groups.length - 1) * gap <=
          box.maxWidth;
      if (fits) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, group) in groups.indexed) ...[
              if (i > 0) const SizedBox(width: gap),
              Expanded(
                child: _GroupColumn(group: group, open: open),
              ),
            ],
          ],
        );
      }
      return ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: groups.length,
        separatorBuilder: (_, _) => const SizedBox(width: gap),
        itemBuilder: (context, i) => SizedBox(
          width: minWidth,
          child: _GroupColumn(group: groups[i], open: open),
        ),
      );
    },
  );
}

/// One group's full ranking, under its name (and the club's colour).
class _GroupColumn extends StatelessWidget {
  const _GroupColumn({required this.group, required this.open});

  final _Group group;
  final VoidCallback? Function(WeekLine line) open;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ranked = group.lines;
    final places = weekPlaces(ranked);
    final club = group.color == null
        ? null
        : ClubColors.of(group.color!, scheme.brightness);
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 14, 10, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  if (club != null) ...[
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: club.$1,
                        shape: BoxShape.circle,
                        border: Border.all(color: club.$2),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      group.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: ranked.length,
                itemBuilder: (context, i) => _DetailRow(
                  place: places[i],
                  line: ranked[i],
                  onTap: open(ranked[i]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One player in a column: the place, the name and the result, and under
/// them, smaller, the team, the opponent and home or away.
class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.place,
    required this.line,
    required this.onTap,
  });

  static const placeWidth = 36.0;

  final int place;
  final WeekLine line;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                SizedBox(
                  width: placeWidth,
                  child: Text(
                    '$place.',
                    style: _entryStyle.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    line.playerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _entryStyle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${line.total}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: placeWidth),
              child: Text(
                '${line.teamName} – ${line.opponent} · ${_where(line)}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: _entryTeamStyle.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run the tests — they must pass**

Run: `cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/features/kiosk_week_test.dart`
Expected: PASS — `+11: All tests passed!`

Run: `cd /Users/mvazan/Home/rezervator && flutter analyze lib/features/kiosk/kiosk_week.dart test/features/kiosk_week_test.dart`
Expected: `No issues found!`

- [ ] **Step 5: Commit the card and the detail**

```bash
cd /Users/mvazan/Home/rezervator
git add lib/features/kiosk/kiosk_week.dart test/features/kiosk_week_test.dart
git commit -m "feat(kiosk): karta Hráči týdne a celoobrazovkový přehled týdne" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 6: Write the failing tests for the module in the panels**

In `test/features/kiosk_week_test.dart` add the imports — old:

```dart
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/week_players.dart';
import 'package:rezervator/features/kiosk/kiosk_week.dart';
```

new:

```dart
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/kiosk_layout.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/week_players.dart';
import 'package:rezervator/features/kiosk/kiosk_connection.dart';
import 'package:rezervator/features/kiosk/kiosk_info_panel.dart';
import 'package:rezervator/features/kiosk/kiosk_shell.dart';
import 'package:rezervator/features/kiosk/kiosk_week.dart';
```

and append this group at the end of `main()` (after the `showKioskWeekPlayers` group, before main's closing brace):

```dart
  group('in the panels', () {
    const settings = ScheduleSettings(
      laneCount: 2,
      trainingWeekdays: {1, 2, 3, 4, 5, 6, 7},
      bookingHorizonDays: 14,
      maxActiveReservations: 3,
      kioskVisibleDays: 8,
      kioskPanels: KioskPanels(
        left: KioskPanel(days: 2, open: true),
        right: KioskPanel(days: 2, open: false),
        modules: [
          KioskModulePlacement(id: 'duty', side: PanelSide.off, share: 30),
          KioskModulePlacement(id: 'notices', side: PanelSide.off, share: 40),
          KioskModulePlacement(id: 'matches', side: PanelSide.off, share: 60),
          KioskModulePlacement(id: 'guide', side: PanelSide.left, share: 45),
          KioskModulePlacement(id: 'week', side: PanelSide.left, share: 55),
        ],
      ),
    );

    Future<KioskPanelContent?> leftContent(List<WeekLine> lines) async {
      final container = ProviderContainer(
        overrides: [
          ...overrides(lines),
          settingsProvider.overrideWith((ref) => Stream.value(settings)),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(
        kioskPanelContentProvider(PanelSide.left),
        (_, _) {},
      );
      addTearDown(sub.close);
      await container.read(settingsProvider.future);
      await container.read(nowProvider.future);
      await container.read(weekPlayersProvider.future);
      return container.read(kioskPanelContentProvider(PanelSide.left));
    }

    test('the module takes room only while the week has lines', () async {
      final empty = await leftContent(const []);
      expect([for (final e in empty!.entries) e.module], [KioskModule.guide]);
      final full = await leftContent(week);
      expect(
        [for (final e in full!.entries) (e.module, e.share)],
        [(KioskModule.guide, 45), (KioskModule.week, 55)],
      );
    });

    testWidgets('KioskPanelView: the card takes its share and opens the '
        'week on a tap', (tester) async {
      fullHd(tester);
      var opened = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...overrides(week),
            settingsProvider.overrideWith((ref) => Stream.value(settings)),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.dark),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  height: panelHeight,
                  child: KioskPanelView(
                    side: PanelSide.left,
                    width: 2 * column,
                    open: true,
                    content: const KioskPanelContent(
                      side: PanelSide.left,
                      entries: [KioskPanelEntry(KioskModule.week, 55)],
                    ),
                    onOpenNotice: (_) {},
                    onOpenMatch: (_) {},
                    onOpenWeek: () => opened++,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final card = find.byType(KioskWeekCard);
      // Alone in the panel: all of it.
      final want = cardSize(days: 2, share: 100);
      expect(tester.getSize(card).width, closeTo(want.width, 1e-6));
      expect(tester.getSize(card).height, closeTo(want.height, 1e-6));
      await tester.tap(card);
      expect(opened, 1);
    });

    Future<void> pumpShell(WidgetTester tester, List<WeekLine> lines) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...overrides(lines),
            settingsProvider.overrideWith(
              (ref) => Stream.value(
                ScheduleSettings(
                  laneCount: 2,
                  trainingWeekdays: const {1, 2, 3, 4, 5, 6, 7},
                  bookingHorizonDays: 14,
                  maxActiveReservations: 3,
                  kioskVisibleDays: 8,
                  // The week alone on the left: without lines, no panel.
                  kioskPanels: KioskPanels.defaults
                      .withSide(KioskModule.notices, PanelSide.off)
                      .withSide(KioskModule.matches, PanelSide.off)
                      .withSide(KioskModule.week, PanelSide.left)
                      .withPanel(PanelSide.left, open: true),
                ),
              ),
            ),
            timeBlocksProvider.overrideWith((ref) => Stream.value(const [])),
            dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
            prioritySlotsProvider.overrideWithValue(const []),
            rentalsProvider.overrideWith((ref) => Stream.value(const [])),
            weekReservationsProvider.overrideWith(
              (ref, monday) => Stream.value(const []),
            ),
            playersProvider.overrideWith((ref) async => const []),
            messagesProvider.overrideWith((ref) => Stream.value(const [])),
            kioskSocketOpenProvider.overrideWithValue(() => true),
            matchResultsProvider.overrideWith((ref) => Stream.value(const {})),
            matchPlayerResultsProvider.overrideWith(
              (ref, id) => Stream.value(const []),
            ),
            dutyPeriodsProvider.overrideWith((ref) => Stream.value(const [])),
            dutyAssignmentsProvider.overrideWith(
              (ref) => Stream.value(const []),
            ),
          ],
          // The app's light theme around the kiosk's dark one: the detail
          // is dark only through the shell's wrap.
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: const KioskShell(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the shell: no line in the week, no left panel', (
      tester,
    ) async {
      fullHd(tester);
      await pumpShell(tester, const []);
      expect(find.byType(KioskPanelView), findsNothing);
      expect(find.byType(KioskWeekCard), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the shell: the week in the left panel, a tap opens it full '
        'screen in the kiosk\'s theme, the idle reset closes it', (
      tester,
    ) async {
      fullHd(tester);
      await pumpShell(tester, week);
      final card = find.byType(KioskWeekCard);
      expect(card, findsOneWidget);
      expect(tester.getSize(find.byType(KioskPanelView)).width, 2 * column);

      await tester.tap(card);
      await tester.pumpAndSettle();
      final page = find.byType(KioskWeekPlayersPage);
      expect(page, findsOneWidget);
      expect(Theme.of(tester.element(page)).brightness, Brightness.dark);

      // A minute without a touch: the kiosk starts over, the week shut.
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(page, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
```

(The shell test's overrides are the ones Task 7's shell test uses for the guide.)

- [ ] **Step 7: Run them — they must fail**

Run: `cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/features/kiosk_week_test.dart`
Expected: FAIL — compilation error `No named parameter with the name 'onOpenWeek'.`

- [ ] **Step 8: Wire the module into `kiosk_info_panel.dart`**

(a) Import, after Task 7's guide import — old:

```dart
import 'kiosk_guide.dart' show KioskGuideCard;
```

new:

```dart
import 'kiosk_guide.dart' show KioskGuideCard;
import 'kiosk_week.dart' show KioskWeekCard;
```

(b) `kioskPanelContentProvider`: read the week only when its card is on this side. After the `duty` local — old:

```dart
      final duty = plan != null && (plan.now != null || plan.next.isNotEmpty)
          ? plan
          : null;
```

new:

```dart
      final duty = plan != null && (plan.now != null || plan.next.isNotEmpty)
          ? plan
          : null;
      // The previous week's lines of ours (0078) are read only with their
      // card here; a week without a line has nothing to rank.
      final hasWeek =
          here(KioskModule.week) &&
          (ref.watch(weekPlayersProvider).value?.isNotEmpty ?? false);
```

and Task 3's placeholder arm of the `shows` switch — old:

```dart
          // Nothing to show yet: it takes no room.
          KioskModule.week => false,
```

new:

```dart
          KioskModule.week => hasWeek,
```

(c) `KioskPanelView`: the parameter, after Task 7's `onOpenGuide` — old:

```dart
    this.onOpenGuide,
    this.onPlay,
```

new:

```dart
    this.onOpenGuide,
    this.onOpenWeek,
    this.onPlay,
```

the field — old:

```dart
  final VoidCallback? onOpenGuide;
```

new:

```dart
  final VoidCallback? onOpenGuide;

  /// A tap on „Hráči týdne“: the whole week full screen; null = a tap does
  /// nothing.
  final VoidCallback? onOpenWeek;
```

and Task 3's placeholder card in `card(KioskModule)` — old:

```dart
      KioskModule.week => const SizedBox.shrink(),
```

new:

```dart
      // A new key after every idle reset, as the other cards of the
      // panel: the card starts over.
      KioskModule.week => KioskWeekCard(
        key: ValueKey(resetToken),
        onOpen: () => onOpenWeek?.call(),
      ),
```

- [ ] **Step 9: Wire the detail into `kiosk_shell.dart`**

(a) Import — old:

```dart
import 'kiosk_stream_window.dart';
import 'kiosk_zapis_page.dart';
```

new:

```dart
import 'kiosk_stream_window.dart';
import 'kiosk_week.dart';
import 'kiosk_zapis_page.dart';
```

(b) After Task 7's `_openGuide` — old:

```dart
  void _openGuide() => unawaited(showKioskGuide(context, wrap: _touchable));
```

new:

```dart
  void _openGuide() => unawaited(showKioskGuide(context, wrap: _touchable));

  /// „Hráči týdne“ full screen (0078) — a tap on its card in a panel; a tap
  /// on a line there opens that match's Zápis over it.
  void _openWeek() => unawaited(
    showKioskWeekPlayers(context, wrap: _touchable, onOpenMatch: _openMatch),
  );
```

(c) In `_boardWithPanel`'s `panel(…)` builder, the `KioskPanelView` arguments — old:

```dart
          onOpenGuide: _openGuide,
```

new:

```dart
          onOpenGuide: _openGuide,
          onOpenWeek: _openWeek,
```

- [ ] **Step 10: Run the tests — they must pass**

Run: `cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/features/kiosk_week_test.dart`
Expected: PASS — `+15: All tests passed!`

Run: `cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/features/kiosk_test.dart test/features/kiosk_guide_test.dart test/features/kiosk_screen_test.dart`
Expected: PASS — the panels without the week never read `weekPlayersProvider`, so nothing else needs an override.

Run: `cd /Users/mvazan/Home/rezervator && flutter analyze lib/features/kiosk test/features/kiosk_week_test.dart`
Expected: `No issues found!`

- [ ] **Step 11: Commit the wiring**

```bash
cd /Users/mvazan/Home/rezervator
git add lib/features/kiosk/kiosk_info_panel.dart lib/features/kiosk/kiosk_shell.dart test/features/kiosk_week_test.dart
git commit -m "feat(kiosk): modul Hráči týdne v panelech — jen s řádky týdne, ťuk otevře přehled" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Changelog, the local seed, the final verification

**Files:**
- Modify: `lib/features/profile/changelog_data.dart` (the top web-only entry `Release(null, '15. 10. 2026', …)`, which exists on `main` — merged into, not a second entry of the same date)
- Create (scratchpad, NOT in the repo, never committed): `/private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/week_seed.sql`, `/private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/week_seed_cleanup.sql`
- Test: `test/changelog_test.dart`, `test/features/store_notes_test.dart` (existing)

**Interfaces:**
- Consumes: `Release(String? version, String date, List<String> changes, {List<String>? store})`, `storeNotes`, `storeText` (`lib/features/profile/store_notes.dart`); Tasks 1–12 for the verification; Task 8's `kiosk_week_players` and 0078 columns for the seed.
- Produces: the merged changelog entry with a `store:` summary; two local SQL scripts; the verification record.

Store rule (memory + PLAY.md): an entry — web-only batches included — that does not fit Google Play's 500 characters whole carries a hand-written `store:` summary in the same change; `store_notes_test.dart` enforces it for every web-only batch. The merged entry is 1156 characters bulleted, so it gets one (413 characters). When the next release folds the web-only batches into one versioned entry (PLAY.md), that entry's summary is rewritten then.

- [ ] **Step 1: Merge the three parts into the 15. 10. entry (without a store summary yet)**

In `lib/features/profile/changelog_data.dart` — old:

```dart
  Release(null, '15. 10. 2026', [
    'Kiosk: hlavní tlačítko „Rezervace tréninku“ je větší a výraznější. Po '
        'výběru hráče záhlaví ukáže jeho přezdívku (bez rámečku) a postranní '
        'panel ustoupí tabuli.',
    'Kiosk, výběr hráče: správce zvolí, zda začíná písmeny, oddíly (dlaždice '
        'v barvě oddílu, hráči bez oddílu pod „Ostatní“), nebo obojím. '
        'Upozornění při rezervaci je širší a má méně řádků.',
  ]),
```

new (the new parts first — a batch is written most important first; „postranní panel“ becomes plural, there are two now):

```dart
  Release(null, '15. 10. 2026', [
    'Kiosk: panely jsou dva, vlevo i vpravo od tabule. Ve Správě → Kiosk → '
        'Panely správce každému modulu (služba na kantýně, nástěnka, zápasy, '
        'Jak začít, Hráči týdne) určí panel, podíl na výšce a pořadí; každý '
        'panel má svou šířku a může začínat rozbalený. Nástěnku v záhlaví '
        'zapíná přepínač „V záhlaví“, volby seznamu zápasů mají svou sekci '
        'Zápasy.',
    'Kiosk: modul „Hráči týdne“ — nejlepší výkony našich hráčů za minulý '
        'týden v kategoriích muži a ženy na 120 a 100 hodů. Ťuknutí otevře '
        'celý týden podle kategorií, soutěží nebo oddílů, doma i venku, a '
        'z řádku zápis zápasu. Pohlaví hráčů je z registru ČKA.',
    'Kiosk: modul „Jak začít“ — jak si na kiosku zarezervovat trénink a kde '
        'je Rezervátor dál: aplikace pro Android (QR kód do Google Play) a web '
        'rezervator.online. Ťuknutí ukáže celý text s velkým QR kódem.',
    'Kiosk: hlavní tlačítko „Rezervace tréninku“ je větší a výraznější. Po '
        'výběru hráče záhlaví ukáže jeho přezdívku (bez rámečku) a postranní '
        'panely ustoupí tabuli.',
    'Kiosk, výběr hráče: správce zvolí, zda začíná písmeny, oddíly (dlaždice '
        'v barvě oddílu, hráči bez oddílu pod „Ostatní“), nebo obojím. '
        'Upozornění při rezervaci je širší a má méně řádků.',
  ]),
```

(If a later change on `main` added bullets to this entry meanwhile, keep them and put the three new bullets first.)

- [ ] **Step 2: Run the store test — it must fail**

Run: `cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/features/store_notes_test.dart`
Expected: FAIL — `the newest release and every web-only batch reach the store whole …` with `záznam 15. 10. 2026 se do 500 znaků pro Google Play nevejde a automatické zkrácení by z něj vypustilo odrážky — dopiš mu v changelog_data.dart store: [...] s kratšími odrážkami`.

- [ ] **Step 3: Add the store summary**

In the same entry — old (its closing line):

```dart
    'Kiosk, výběr hráče: správce zvolí, zda začíná písmeny, oddíly (dlaždice '
        'v barvě oddílu, hráči bez oddílu pod „Ostatní“), nebo obojím. '
        'Upozornění při rezervaci je širší a má méně řádků.',
  ]),
  Release(null, '14. 10. 2026', [
```

new:

```dart
    'Kiosk, výběr hráče: správce zvolí, zda začíná písmeny, oddíly (dlaždice '
        'v barvě oddílu, hráči bez oddílu pod „Ostatní“), nebo obojím. '
        'Upozornění při rezervaci je širší a má méně řádků.',
  ], store: [
    'Kiosk: dva panely, vlevo i vpravo od tabule; správce do nich rozmístí '
        'moduly ve Správě → Kiosk → Panely.',
    'Kiosk: Hráči týdne — nejlepší výkony našich hráčů za minulý týden, '
        'muži a ženy na 120 a 100 hodů, i podle soutěží a oddílů.',
    'Kiosk: Jak začít — rezervace na kiosku krok za krokem a QR kód '
        'aplikace pro Android.',
    'Kiosk: větší tlačítko „Rezervace tréninku“; výběr hráče začíná '
        'písmeny, oddíly nebo obojím.',
  ]),
  Release(null, '14. 10. 2026', [
```

- [ ] **Step 4: Run the changelog tests — they must pass**

Run: `cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test test/changelog_test.dart test/features/store_notes_test.dart`
Expected: PASS — `+21: All tests passed!`

- [ ] **Step 5: Commit the changelog**

```bash
cd /Users/mvazan/Home/rezervator
git add lib/features/profile/changelog_data.dart
git commit -m "docs(changelog): kiosk — dva panely, Jak začít, Hráči týdne" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 6: Write the local seed for the browser check (scratchpad, not a migration)**

Create `/private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/week_seed.sql` (checked: run inside a rolled-back transaction on the dev DB with Task 8's 0078 applied in it, `kiosk_week_players` as the kiosk returns exactly the 21 lines listed in its header):

```sql
-- „Hráči týdne“ — seed for the browser check on the LOCAL dev stack.
-- NOT a migration: never copy it into supabase/migrations, never run it
-- against production.
--
-- Run after `supabase migration up --local` (0077, 0078 applied):
--   PGPASSWORD=postgres psql -h 127.0.0.1 -p 54322 -U postgres -d postgres \
--     -X -v ON_ERROR_STOP=1 -f week_seed.sql
-- Undo with week_seed_cleanup.sql. Re-runnable: fixed ids and upserts; a
-- run in a later week moves the matches into that week's previous week.
--
-- Into the tenant of the first kiosk account: three teams of ours (two
-- with a club, one without), five federation matches of the PREVIOUS
-- Monday–Sunday in Prague (T120 at home, T120 away, T100 away, a women's
-- match without a discipline but with 4 lanes, and one still in progress),
-- the lines of both sides (a substitute's line among ours), and the
-- register's genders: m, f, a player checked without a gender, and one
-- never looked up.
--
-- Expected on the kiosk (the module „Hráči týdne“ placed in a panel):
--   Muži · 120 HS  1. Jan Novák 598 (Termínátor A · doma), 2. Martin Král
--                  575 (venku — his better line of two), 3. Petr Svoboda 571
--                  and Tomáš Černý 571 sharing 3. (equal pins and errors)
--   Ženy · 120 HS  Jana Nováková 552, Eva Dvořáková 548 (in a men's team),
--                  Petra Pokorná 547, Klára Svobodová 538, Lenka Sedláková 529
--   Muži · 100 HS  Pavel Horák 412, Radek Malý 401, Jiří Němec 398
--   Ženy · 100 HS  Hana Veselá 405, Ivana Pokorná 391, Lucie Procházková 387
--   Only in Soutěže / Oddíly: Zdeněk Marek (no gender), Lukáš Beneš (never
--   looked up). Nowhere: Karel Dvořák (substituted), the in-progress 650,
--   the opponents (Host …).
--   Soutěže: 2. KLŽ, Divize AS, Krajský přebor. Oddíly: Sokol Čáslav,
--   TJ Termínátor, Ostatní.

begin;

-- The slots are in the past week: no reservation cancelling, no calendar
-- jobs, no Úklid children — the triggers stay off for this transaction
-- (so do the foreign-key checks; the rows below are consistent).
set local session_replication_role = replica;

do $$
declare
  v_tenant uuid := (
    select tenant_id from profiles where role = 'kiosk' order by id limit 1);
  v_type uuid;
  v_admin uuid;
  v_monday date := date_trunc('week', now() at time zone 'Europe/Prague')::date - 7;
  v_ours_club uuid;
  v_other_club uuid;
begin
  if v_tenant is null then
    raise exception 'no kiosk account on this stack';
  end if;
  select id into v_type from priority_slot_types
   where tenant_id = v_tenant and is_match and builtin limit 1;
  select id into v_admin from profiles
   where tenant_id = v_tenant and role = 'admin' order by id limit 1;

  insert into clubs (tenant_id, name, color) values (v_tenant, 'TJ Termínátor', 0)
  on conflict (tenant_id, name) do update set name = excluded.name
  returning id into v_ours_club;
  insert into clubs (tenant_id, name, color) values (v_tenant, 'Sokol Čáslav', 5)
  on conflict (tenant_id, name) do update set name = excluded.name
  returning id into v_other_club;

  insert into teams (tenant_id, name, club_id, site_slug, site_name,
                     competition_slug, competition_name)
  values
    (v_tenant, 'Termínátor A', v_ours_club, 'seed-terminator-a-muzi',
     'TJ Termínátor A', 'divize-as', 'Divize AS'),
    (v_tenant, 'Termínátor B', v_other_club, 'seed-terminator-b-muzi',
     'TJ Termínátor B', 'krajsky-prebor', 'Krajský přebor'),
    (v_tenant, 'Termínátor ženy', null, 'seed-terminator-zeny',
     'TJ Termínátor', '2-klz', '2. KLŽ')
  on conflict (tenant_id, site_slug) do update
    set name = excluded.name, club_id = excluded.club_id, active = true;

  insert into priority_slots (id, tenant_id, date, starts_at, ends_at,
      home_team, away_team, home_team_slug, away_team_slug, is_away,
      competition, round, import_key, type_id, created_by)
  values
    ('e2000000-0000-4000-8000-000000000001', v_tenant, v_monday + 1,
     '08:00', '11:00', 'Termínátor A', 'KK Slavoj Praha A',
     'seed-terminator-a-muzi', 'seed-kk-slavoj-praha-a-muzi', false,
     'Divize AS', 5, 'cka:seed-week-1', v_type, v_admin),
    ('e2000000-0000-4000-8000-000000000002', v_tenant, v_monday + 2,
     '08:00', '11:00', 'TJ Lokomotiva Plzeň', 'Termínátor A',
     'seed-lokomotiva-plzen-muzi', 'seed-terminator-a-muzi', true,
     'Divize AS', 6, 'cka:seed-week-2', v_type, v_admin),
    ('e2000000-0000-4000-8000-000000000003', v_tenant, v_monday + 5,
     '08:00', '11:00', 'Sokol Brno B', 'Termínátor B',
     'seed-sokol-brno-b-muzi', 'seed-terminator-b-muzi', true,
     'Krajský přebor', 3, 'cka:seed-week-3', v_type, v_admin),
    ('e2000000-0000-4000-8000-000000000004', v_tenant, v_monday + 6,
     '08:00', '11:00', 'Termínátor ženy', 'KK Zlín ženy',
     'seed-terminator-zeny', 'seed-kk-zlin-zeny', false,
     '2. KLŽ', 4, 'cka:seed-week-4', v_type, v_admin),
    ('e2000000-0000-4000-8000-000000000005', v_tenant, v_monday + 3,
     '08:00', '11:00', 'Termínátor A', 'SKK Veverky Brno',
     'seed-terminator-a-muzi', 'seed-skk-veverky-brno-muzi', false,
     'Divize AS', 7, 'cka:seed-week-5', v_type, v_admin)
  on conflict (id) do update
    set date = excluded.date, home_team = excluded.home_team,
        away_team = excluded.away_team,
        home_team_slug = excluded.home_team_slug,
        away_team_slug = excluded.away_team_slug, is_away = excluded.is_away,
        competition = excluded.competition, import_key = excluded.import_key;

  insert into match_results (match_id, tenant_id, status, match_type,
                             discipline, decided_at)
  values
    ('e2000000-0000-4000-8000-000000000001', v_tenant, 'finished',
     'TEAMS_OF_6', 'T120', now()),
    ('e2000000-0000-4000-8000-000000000002', v_tenant, 'finished',
     'TEAMS_OF_6', 'T120', now()),
    ('e2000000-0000-4000-8000-000000000003', v_tenant, 'finished',
     'TEAMS_OF_6', 'T100', now()),
    -- No discipline stored: the 4 lanes of its lines say 120.
    ('e2000000-0000-4000-8000-000000000004', v_tenant, 'finished',
     'TEAMS_OF_4', '', now()),
    ('e2000000-0000-4000-8000-000000000005', v_tenant, 'in_progress',
     'TEAMS_OF_6', 'T120', null)
  on conflict (match_id) do update
    set status = excluded.status, match_type = excluded.match_type,
        discipline = excluded.discipline, decided_at = excluded.decided_at;

  delete from match_player_results
   where match_id::text like 'e2000000-0000-4000-8000-%';
  insert into match_player_results (match_id, tenant_id, side, position,
      player_name, player_slug, errors, total, lanes, sub_name, sub_slug,
      sub_from_throw)
  select l.match_id::uuid, v_tenant, l.side, l.position, l.name, l.slug,
         l.errors, l.total,
         (select jsonb_agg(jsonb_build_object(
                   'lane', n, 'fulls', 0, 'spares', 0, 'errors', 0,
                   'total', l.total / l.lanes, 'setPoints', 0))
            from generate_series(1, l.lanes) n),
         l.sub_name, l.sub_slug, l.sub_from
    from (values
      -- 1: T120 at home, ours at home.
      ('e2000000-0000-4000-8000-000000000001', 'home', 1, 'Jan Novák', 'seed-jan-novak', 2, 598, 4, null, null, null),
      ('e2000000-0000-4000-8000-000000000001', 'home', 2, 'Petr Svoboda', 'seed-petr-svoboda', 5, 571, 4, null, null, null),
      ('e2000000-0000-4000-8000-000000000001', 'home', 3, 'Martin Král', 'seed-martin-kral', 3, 560, 4, null, null, null),
      ('e2000000-0000-4000-8000-000000000001', 'home', 4, 'Eva Dvořáková', 'seed-eva-dvorakova', 4, 548, 4, null, null, null),
      ('e2000000-0000-4000-8000-000000000001', 'home', 5, 'Tomáš Černý', 'seed-tomas-cerny', 5, 571, 4, null, null, null),
      ('e2000000-0000-4000-8000-000000000001', 'home', 6, 'Karel Dvořák', 'seed-karel-dvorak', 6, 520, 4, 'Ondřej Kučera', 'seed-ondrej-kucera', 61),
      ('e2000000-0000-4000-8000-000000000001', 'away', 1, 'Host Jedna', 'seed-host-1', 3, 590, 4, null, null, null),
      ('e2000000-0000-4000-8000-000000000001', 'away', 2, 'Host Dva', 'seed-host-2', 3, 580, 4, null, null, null),
      -- 2: T120 away, ours on the site's away side.
      ('e2000000-0000-4000-8000-000000000002', 'away', 1, 'Martin Král', 'seed-martin-kral', 1, 575, 4, null, null, null),
      ('e2000000-0000-4000-8000-000000000002', 'away', 2, 'Jan Novák', 'seed-jan-novak', 4, 540, 4, null, null, null),
      ('e2000000-0000-4000-8000-000000000002', 'away', 3, 'Tomáš Černý', 'seed-tomas-cerny', 2, 552, 4, null, null, null),
      ('e2000000-0000-4000-8000-000000000002', 'away', 4, 'Petr Svoboda', 'seed-petr-svoboda', 3, 549, 4, null, null, null),
      ('e2000000-0000-4000-8000-000000000002', 'away', 5, 'Zdeněk Marek', 'seed-zdenek-marek', 2, 566, 4, null, null, null),
      ('e2000000-0000-4000-8000-000000000002', 'away', 6, 'Lukáš Beneš', 'seed-lukas-benes', 7, 530, 4, null, null, null),
      ('e2000000-0000-4000-8000-000000000002', 'home', 1, 'Host Tři', 'seed-host-3', 2, 600, 4, null, null, null),
      -- 3: T100 away.
      ('e2000000-0000-4000-8000-000000000003', 'away', 1, 'Pavel Horák', 'seed-pavel-horak', 3, 412, 2, null, null, null),
      ('e2000000-0000-4000-8000-000000000003', 'away', 2, 'Jiří Němec', 'seed-jiri-nemec', 4, 398, 2, null, null, null),
      ('e2000000-0000-4000-8000-000000000003', 'away', 3, 'Hana Veselá', 'seed-hana-vesela', 2, 405, 2, null, null, null),
      ('e2000000-0000-4000-8000-000000000003', 'away', 4, 'Ivana Pokorná', 'seed-ivana-pokorna', 5, 391, 2, null, null, null),
      ('e2000000-0000-4000-8000-000000000003', 'away', 5, 'Lucie Procházková', 'seed-lucie-prochazkova', 6, 387, 2, null, null, null),
      ('e2000000-0000-4000-8000-000000000003', 'away', 6, 'Radek Malý', 'seed-radek-maly', 3, 401, 2, null, null, null),
      ('e2000000-0000-4000-8000-000000000003', 'home', 1, 'Host Čtyři', 'seed-host-4', 1, 430, 2, null, null, null),
      -- 4: women, no discipline, 4 lanes.
      ('e2000000-0000-4000-8000-000000000004', 'home', 1, 'Jana Nováková', 'seed-jana-novakova', 3, 552, 4, null, null, null),
      ('e2000000-0000-4000-8000-000000000004', 'home', 2, 'Klára Svobodová', 'seed-klara-svobodova', 5, 538, 4, null, null, null),
      ('e2000000-0000-4000-8000-000000000004', 'home', 3, 'Petra Pokorná', 'seed-petra-pokorna', 2, 547, 4, null, null, null),
      ('e2000000-0000-4000-8000-000000000004', 'home', 4, 'Lenka Sedláková', 'seed-lenka-sedlakova', 6, 529, 4, null, null, null),
      ('e2000000-0000-4000-8000-000000000004', 'away', 1, 'Host Pět', 'seed-host-5', 2, 560, 4, null, null, null),
      -- 5: still in progress — none of it counts.
      ('e2000000-0000-4000-8000-000000000005', 'home', 1, 'Jan Novák', 'seed-jan-novak', 0, 650, 4, null, null, null)
    ) as l(match_id, side, position, name, slug, errors, total, lanes,
           sub_name, sub_slug, sub_from);

  insert into site_player_regnums (slug, regnum, status, gender,
                                   gender_checked_at)
  values
    ('seed-jan-novak', '9000001', 'found', 'm', now()),
    ('seed-petr-svoboda', '9000002', 'found', 'm', now()),
    ('seed-martin-kral', '9000003', 'found', 'm', now()),
    ('seed-eva-dvorakova', '9000004', 'found', 'f', now()),
    ('seed-tomas-cerny', '9000005', 'found', 'm', now()),
    ('seed-karel-dvorak', '9000006', 'found', 'm', now()),
    -- Asked, and the register did not say: no gender, not asked for a week.
    ('seed-zdenek-marek', null, 'none', null, now()),
    ('seed-pavel-horak', '9000008', 'found', 'm', now()),
    ('seed-jiri-nemec', '9000009', 'found', 'm', now()),
    ('seed-hana-vesela', '9000010', 'found', 'f', now()),
    ('seed-ivana-pokorna', '9000011', 'found', 'f', now()),
    ('seed-lucie-prochazkova', '9000012', 'found', 'f', now()),
    ('seed-radek-maly', '9000013', 'found', 'm', now()),
    ('seed-jana-novakova', '9000014', 'found', 'f', now()),
    ('seed-klara-svobodova', '9000015', 'found', 'f', now()),
    ('seed-petra-pokorna', '9000016', 'found', 'f', now()),
    ('seed-lenka-sedlakova', '9000017', 'found', 'f', now())
    -- seed-lukas-benes: no row, never looked up.
  on conflict (slug) do update
    set regnum = excluded.regnum, status = excluded.status,
        gender = excluded.gender,
        gender_checked_at = excluded.gender_checked_at;

  raise notice 'seeded the week of % for tenant %', v_monday, v_tenant;
end;
$$;

commit;
```

Create `/private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/week_seed_cleanup.sql`:

```sql
-- Undoes week_seed.sql on the LOCAL dev stack (not a migration):
--   PGPASSWORD=postgres psql -h 127.0.0.1 -p 54322 -U postgres -d postgres \
--     -X -v ON_ERROR_STOP=1 -f week_seed_cleanup.sql
-- The clubs stay: the seed only reuses them by name.

begin;

-- As in the seed: no calendar jobs for the deleted slots. The foreign-key
-- cascades are triggers too, so the children go first, by hand.
set local session_replication_role = replica;

delete from match_player_results
 where match_id::text like 'e2000000-0000-4000-8000-%';
delete from match_results
 where match_id::text like 'e2000000-0000-4000-8000-%';
delete from priority_slots
 where id::text like 'e2000000-0000-4000-8000-%';
delete from teams where site_slug like 'seed-%';
delete from site_player_regnums where slug like 'seed-%';

commit;
```

Neither file is added to git.

- [ ] **Step 7: Static checks and the whole suite**

Run: `cd /Users/mvazan/Home/rezervator && flutter analyze`
Expected: `No issues found!`

Run: `cd /Users/mvazan/Home/rezervator && TZ=Europe/Prague flutter test`
Expected: `All tests passed!` (`test/domain/week_players_test.dart` +18 and `test/features/kiosk_week_test.dart` +15 among them).

- [ ] **Step 8: Schema snapshot and tenancy suite (throwaway stack)**

Run: `/private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/snap_repo.sh /Users/mvazan/Home/rezervator`
Expected: prints `tenancy OK`, and the last line (`git diff --stat supabase/schema.sql`) is empty — Tasks 1 and 8 committed the snapshot. Only if it shows a diff (a migration changed after its snapshot), commit the regenerated file:

```bash
cd /Users/mvazan/Home/rezervator
git add supabase/schema.sql
git commit -m "chore(db): obnovený snímek schématu po 0077 a 0078" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 9: Edge functions (the CI invocation)**

Run:

```bash
cd /Users/mvazan/Home/rezervator
deno check --import-map supabase/functions/import_map.json supabase/functions/notify/index.ts supabase/functions/cancel/index.ts supabase/functions/calendar-oauth-callback/index.ts supabase/functions/calendar-manage/index.ts supabase/functions/kiosk-password/index.ts supabase/functions/react/index.ts supabase/functions/regnum-lookup/index.ts
deno test --allow-read supabase/functions
for f in supabase/functions/*/index.ts; do grep -q "Deno.serve" "$f" || echo "$f has no Deno.serve"; done
```

Expected: `deno check` silent (exit 0); `deno test` ends `ok | … passed | 0 failed` (Task 9's `regnum_test.ts` gender cases included); the loop prints nothing.

- [ ] **Step 10: Browser check on the local stack (1920 × 1080)**

Apply the two migrations to the dev DB without a reset (never `db reset` / `tool/schema_snapshot.sh` on it), seed, build the web as the kiosk display runs it (wasm), serve:

```bash
cd /Users/mvazan/Home/rezervator
supabase migration up --local
PGPASSWORD=postgres psql -h 127.0.0.1 -p 54322 -U postgres -d postgres -X -v ON_ERROR_STOP=1 -f /private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/week_seed.sql
eval "$(supabase status -o env | grep -E '^(ANON_KEY|SERVICE_ROLE_KEY)=')"
flutter build web --release --wasm -o build/web-local --dart-define=SUPABASE_URL=http://127.0.0.1:54321 --dart-define=SUPABASE_ANON_KEY="$ANON_KEY"
(cd build/web-local && python3 -m http.server 8766)
```

Expected: `migration up` applies `0077_kiosk_panels.sql` and `0078_week_players.sql`; the seed prints `NOTICE:  seeded the week of <the previous Monday> for tenant …`; the build ends `✓ Built build/web-local`.

Sign-in links (single use; the user opens each in an incognito window — the service worker keeps old builds; hard-reload Cmd+Shift+R after every rebuild):

```bash
for who in spravce kiosk; do
  curl -s -X POST http://127.0.0.1:54321/auth/v1/admin/generate_link \
    -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
    -H 'Content-Type: application/json' \
    -d "{\"type\":\"magiclink\",\"email\":\"$who@local.test\",\"redirect_to\":\"http://localhost:8766/\"}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["action_link"])'
done
```

Checklist (window 1920 × 1080):
1. Admin, Správa → Kiosk: sections in the order Obrazovka kiosku, Stavový řádek, Panely, Nástěnka, Služby na kantýně, Zápasy, Hraný zápas, Stream zápasu, Optimalizace výkonu. In Panely set Jak začít → Vlevo 45 %, Hráči týdne → Vlevo 55 %, Nástěnka and Zápasy → Vpravo; Levý panel 2 dny, Výchozně rozbalený on. The sums read „Vlevo 100 % · Vpravo 100 %“; ↑↓ move a module within its panel.
2. Kiosk: both panel buttons; the left one centred on the hour ruler, today's first lane still bookable beside it; each panel opens and closes by its button and slides from its edge.
3. Left panel: „JAK ZAČÍT“ with the QR code beside the second paragraph; „HRÁČI TÝDNE · <the previous week>“ with Muži · 120 HS 1. Jan Novák 598 (Termínátor A · doma), 2. Martin Král 575 (· venku), 3. Petr Svoboda 571 — and „Více“ when the card cannot hold all four categories.
4. Tap the card: full screen „Hráči týdne …“ in the kiosk theme. Kategorie shows the four columns of the seed header (Petr Svoboda and Tomáš Černý both „3.“). Venku: only Martin Král 575, Jan Novák 540 … and the Krajský přebor lines. Soutěže: 2. KLŽ, Divize AS, Krajský přebor — Zdeněk Marek and Lukáš Beneš appear here and under Oddíly, never under Kategorie. Oddíly: Sokol Čáslav, TJ Termínátor (with their colour dots), Ostatní. Nowhere: Karel Dvořák, the 650, any „Host …“. Narrow the window below ~1100 px: the columns scroll sideways.
5. Tap „Jan Novák“: that match's Zápis opens over the detail; closing it returns to the detail.
6. Leave the kiosk untouched for the idle time: the Zápis and the detail close, both panels return to their resting state.
7. Pick a player („Rezervace tréninku“): both panels and buttons step aside; clearing the pick brings them back.
8. Admin: move Hráči týdne → Vpravo — the card moves at once; Vypnuto — it is gone. Run `week_seed_cleanup.sql`, reload the kiosk: with Hráči týdne placed again but no line in the week, the module takes no room.
9. The user scans the QR code from the kiosk screen with a phone: it opens Rezervátor on Google Play.

Afterwards:

```bash
PGPASSWORD=postgres psql -h 127.0.0.1 -p 54322 -U postgres -d postgres -X -v ON_ERROR_STOP=1 -f /private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/week_seed_cleanup.sql
```

Expected: `COMMIT`; `select count(*) from teams where site_slug like 'seed-%'` → 0.

- [ ] **Step 11: Branch state**

Run: `cd /Users/mvazan/Home/rezervator && git status --short && git log --oneline main..HEAD`
Expected: a clean tree (no `build/`, no scratchpad files) and one commit per logical change of Tasks 1–13. Nothing is pushed — push and the PR only on the user's word (`kiosk-live-refresh` PR #200 touches `kiosk_info_panel.dart`; whichever merges second resolves).
