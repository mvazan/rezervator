# Služby na kantýně Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Canteen duty periods planned by the admin, a roster every player sees, temporary server-enforced rights for the players on duty (book and cancel for others, day-level block edits, close a day), a reminder before a duty, and season counts with history.

**Architecture:** One migration `supabase/migrations/0050_canteen_duty.sql` (Tasks 1–3 build it up; it is not deployed until merge, so later tasks append to it and it stays idempotent). Rights live only in security-definer RPCs gated by `is_on_duty()` / `duty_gate(date)`; no table policy gets wider. The app reads two unfiltered streams (`duty_periods`, `duty_assignments`) and one future (`duty_seasons`); counts, labels and "my duty" are pure Dart in `lib/domain/duties.dart`.

**Tech Stack:** Postgres (Supabase, RLS, plpgsql), Deno edge function `notify`, Flutter + Riverpod 3.

Spec: `docs/superpowers/specs/2026-09-26-canteen-duty-design.md` — it is the reference for every Czech string, layout and edge case. Read the sections a task names before writing code.

## Global Constraints

- Czech UI strings exactly as the spec writes them.
- Every list Czech-alphabetical (`compareCzech`) or chronological; never by count.
- Rights are enforced in SQL. The app hides what the server would refuse, but never relies on hiding.
- No `profiles.role` change: on duty = approved `player`, not a placeholder, same tenant, assigned to a period covering today's Prague date.
- The duty follows the booked player's normal rules (their active-reservation limit, the horizon, no started block, no past date). Only the admin bypasses them.
- The weekly template (Správa → Rozvrh), `priority_slots`, rentals, slot types, clubs, settings and every Správa screen stay admin-only.
- Every new table: RLS on; `revoke all from anon`; `grant select to authenticated`; no insert/update/delete for `authenticated`; `grant all to service_role`. Every new function: explicit `revoke … from public, anon` and a grant only to who needs it. (Supabase 2026-10-30 default-grants change.)
- `is_admin()` stays PUBLIC-executable (policies call it). The new `is_on_duty()` / `duty_gate()` are called only inside security-definer bodies: revoke them from `public, anon, authenticated`.
- The migration is idempotent (`if not exists`, `create or replace`, guarded `do` blocks); running it twice must succeed.
- The existing kiosk flow and the 0044 group flow keep working unchanged (their SQL tests must stay green).
- After changing the migration: apply it to the local DB with `psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/migrations/0050_canteen_duty.sql` (twice, to prove idempotence), then regenerate the snapshot with `supabase db dump --local --schema public -f supabase/schema.sql` (never `supabase db reset`), then run `psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql`. Get `DB_URL` with `supabase status -o env | grep ^DB_URL=`.
- Flutter: `flutter analyze` prints "No issues found!", tests run with `TZ=Europe/Prague`. Deno: `deno check --import-map supabase/functions/import_map.json supabase/functions/*/index.ts` and `deno test --allow-read supabase/functions`.
- Flutter 3.38 locally, newer on CI: do not use APIs that are deprecated on newer Flutter (e.g. `containsSemantics`) or missing on 3.38 (e.g. `isSemantics`).
- One commit per task (plus fix commits), message ending with the line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push.

---

### Task 1: Data model and the admin's RPCs

**Files:**
- Create: `supabase/migrations/0050_canteen_duty.sql`
- Modify: `supabase/tests/tenancy_rls.sql` (new section at the end, before the final `rollback;`)
- Modify: `supabase/schema.sql` (regenerated), `docs/SCHEMA.md`

**Produces (SQL, exact names):**
- Tables `duty_periods`, `duty_assignments`, `duty_seasons` exactly as in the spec's „Data model“ (columns, checks, `btree_gist` exclusion `duty_periods_no_overlap`, indexes, comments). `duty_periods` and `duty_assignments` join the `supabase_realtime` publication (guarded `do` block, like 0045 does for `match_results`).
- `schedule_settings.duty_reminder_enabled boolean not null default false`, `schedule_settings.duty_reminder_days smallint not null default 1 check (duty_reminder_days between 1 and 14)`. The existing `settings_update` policy and column grants must let the admin update these two columns (check how 0017/0046 grant columns on `schedule_settings` and extend it).
- RPCs (security definer, `set search_path = public`, admin-only via `is_admin()` → else `not_allowed`, revoke from public/anon, grant execute to authenticated):
  - `duty_generate(p_from date, p_days smallint, p_until date) returns jsonb` → `{"created": n, "skipped": m}`; periods `[s, least(s+p_days-1, p_until)]` for s = p_from, p_from+p_days, … ≤ p_until; a period overlapping an existing one is skipped; `p_days` 1..31 else `invalid_days`; range > 400 days or `p_until < p_from` → `invalid_range`.
  - `duty_period_save(p_id uuid, p_starts_on date, p_ends_on date, p_note text) returns uuid` — null id inserts; errors `invalid_range`, `duty_too_long` (≥ 62 days), `duty_overlap` (catch `exclusion_violation`), `unknown_period`.
  - `duty_period_delete(p_id uuid) returns void`.
  - `duty_periods_delete_unassigned(p_from date) returns integer` — deletes periods with `starts_on >= p_from` that have no assignment.
  - `duty_set_assignees(p_period uuid, p_users uuid[]) returns void` — replaces the set; each user same tenant, `status = 'approved'`, `role <> 'kiosk'` (placeholders allowed) else `unknown_player`; `unknown_period`.
  - `duty_season_start(p_started_on date, p_name text) returns void` — `empty_name` (trimmed, 1–40), `season_order` (must be after the newest boundary).
  - `duty_season_delete(p_started_on date) returns void` — only the newest, else `not_newest`.
- `delete_placeholder_player` raises `player_has_history` when the placeholder has any `duty_assignments` row; `merge_placeholder_player` moves assignments to the account (dropping duplicates). Replace them with `create or replace`, keeping signatures and every other behaviour byte-for-byte (copy the current bodies from `supabase/schema.sql`).

- [ ] **Step 1: SQL tests first** — new section „0050 služby na kantýně — data a správa“ in `tenancy_rls.sql`, using the existing fixtures (tenant A admin/player/kiosk/pending/placeholder, tenant B) and dates built from `now()`:
  - an admin generates 7-day periods over 3 weeks → `{"created":3,"skipped":0}`; again → `created 0, skipped 3`; the last one is clipped to `p_until`;
  - `duty_period_save` overlap → `duty_overlap`; 70 days → `duty_too_long`; `ends < starts` → `invalid_range`;
  - `duty_set_assignees` with a player + a placeholder works; with the kiosk, the pending player or a tenant-B player → `unknown_player`;
  - a plain player calling any of these RPCs → `not_allowed`; `anon` has no EXECUTE;
  - a player can SELECT the tenant's periods and assignments but not tenant B's, and cannot INSERT/UPDATE/DELETE either table (42501);
  - seasons: start, `season_order`, `not_newest`, delete newest;
  - `delete_placeholder_player` on an assigned placeholder → `player_has_history`; merge moves the assignment;
  - both tables are in `supabase_realtime` (add them to `v_streamed`).
- [ ] **Step 2:** apply the empty/partial migration and run the tests — see them fail.
- [ ] **Step 3:** write the migration part; apply twice; regenerate the snapshot; run the tests — green.
- [ ] **Step 4:** `docs/SCHEMA.md`: rows for the three tables, the two settings columns, the RPCs in the RPC table, the test summary.
- [ ] **Step 5: Commit** `feat(db): duty periods, assignees and seasons, planned by the admin (0050)`.

---

### Task 2: The rights of the player on duty

**Files:**
- Modify: `supabase/migrations/0050_canteen_duty.sql` (append)
- Modify: `supabase/tests/tenancy_rls.sql`, `supabase/schema.sql`, `docs/SCHEMA.md`

**Produces:**
- `is_on_duty() returns boolean` exactly as the spec's „Rights“ SQL (stable, security definer, tenant match, approved player, not placeholder, Prague today within the period). `duty_gate(p_date date) returns void`: passes for `is_admin()`; else `not is_on_duty()` → `not_allowed`, `p_date < Prague today` → `date_past`. Revoke both from public, anon, authenticated.
- `reservations.created_via` and `cancelled_via` CHECKs gain `'duty'` (drop + add `NOT VALID` + `VALIDATE`, idempotent).
- `create_reservation`: a new branch after the group branch — approved player, `p_player_id <> v_uid`, `is_on_duty()` → `v_via := 'duty'`. The existing non-admin checks (past, started, horizon, the target's limit) apply; the limit error is `player_at_limit` when `v_via = 'duty'` (else unchanged).
- `cancel_reservation`: a new branch after the owner/group branch — approved player, same tenant, `is_on_duty()`, block not started (else `too_late`) → `v_via := 'duty'`, `notify_player := coalesce(p_notify, true)`.
- `set_day_override`, `cancel_block_day_reservations`, `move_day_reservations`, `move_reservation`: replace the `is_admin()` gate with `perform duty_gate(<date>)` (for `move_reservation` the reservation's date). Signatures and bodies otherwise unchanged.
- New RPCs gated by `duty_gate`: `add_special_block(p_starts_at time, p_ends_at time) returns uuid` (inserts `position -1, active false` for `current_tenant_id()`), `delete_day_override(p_date date) returns void`. Grant execute to authenticated.

- [ ] **Step 1: SQL tests first** — section „0050 — práva služby“:
  - fixture: a period covering today assigned to player P (tenant A), a past period assigned to player Q;
  - `is_on_duty()`: P true; Q false; P demoted to pending → false; P as a tenant-B visitor (superadmin switch) → false;
  - P books for another player → `created_via = 'duty'`; for a player at the limit → `player_at_limit`; past date → `date_past`; beyond horizon → `beyond_horizon`; P's own booking → `'app'`;
  - P cancels another player's future reservation → `cancelled_via = 'duty'`; a started one → `too_late`;
  - P: `set_day_override` today/tomorrow ok, yesterday `date_past`; `add_special_block` ok; `delete_day_override` ok; `cancel_block_day_reservations`, `move_day_reservations`, `move_reservation` ok today;
  - Q (not on duty): every one of these → `not_allowed`;
  - P direct INSERT into `time_blocks`, `priority_slots`, `rentals` → 42501, and P cannot UPDATE a template `time_blocks` row (42501) — the weekly template stays the admin's;
  - `is_on_duty`/`duty_gate` not executable by authenticated;
  - the kiosk and 0044 group sections still pass (re-run the whole file).
- [ ] **Step 2:** tests fail. **Step 3:** implement (copy each replaced function's current body from `supabase/schema.sql`, change only the gate/branch). Apply twice, snapshot, tests green.
- [ ] **Step 4:** SCHEMA.md (rights, RPC table, test summary).
- [ ] **Step 5: Commit** `feat(db): a player on duty books, cancels and edits days for the alley (0050)`.

---

### Task 3: Reminders and messages

**Files:**
- Modify: `supabase/migrations/0050_canteen_duty.sql` (append), `supabase/tests/tenancy_rls.sql`, `supabase/schema.sql`, `docs/SCHEMA.md`
- Create: `supabase/functions/_shared/duty_reminders.ts`, `supabase/functions/_shared/duty_reminders_test.ts`
- Modify: `supabase/functions/notify/index.ts`

**Produces:**
- `due_duty_reminders()` (security definer, stable; execute for `service_role` only) returning `(user_id, email, fcm_token, period_id, starts_on date, ends_on date, days smallint, co_assignees text[])` per the spec's „Reminders“: setting on; assigned account (not placeholder, approved, not kiosk); `18:00 Prague on starts_on − days` ≤ now; `starts_on > Prague today`; no ledger row `(user_id, 'd:'||period_id, days*1440)` with `starts_at` = Prague midnight of `starts_on` (0049 semantics: a moved period rings again).
- `notifications_due()` gains `or exists (select 1 from due_duty_reminders())`.
- `_shared/duty_reminders.ts`: `dutyReminderTitle(startsOn, now)` („Zítra sloužíš na kantýně“, „Za 2 dny sloužíš na kantýně“, counting Prague calendar days; never „Dnes“), `dutyReminderBody(row)` („po 5. 10. – ne 11. 10.“ + „, spolu s: …“ Czech-sorted), `deliverDueDutyReminders(rows, now, send, mark)` — the same delivery contract as `deliverDueReminders` (mark only when not `retry`).
- notify: `sendDueDutyReminders()` after `sendDueReminders()`, marking with `mark_reminder_sent(user, 'd:'||period, days*1440, prague midnight of starts_on)`.
- notify booking messages: INSERT with `created_via 'duty'` → the same message as `'group'` („{name} ti zarezervoval(a) trénink…“); UPDATE with `cancelled_via 'duty'` → honours `notify_player`, silent for past dates, reason default „zrušil(a) {name} (služba na kantýně)“ (see the spec).

- [ ] **Step 1: tests first** — SQL: due rows appear only when on, only after 18:00 of the lead day, never for placeholders/pending/kiosk, a mark silences, moving the period re-arms, switching off empties. Deno: titles (1 day, 2 days, late → real Prague days), body with and without co-assignees, the delivery contract (retry leaves unmarked).
- [ ] **Step 2:** fail. **Step 3:** implement; apply twice; snapshot; SQL tests; `deno check` + `deno test --allow-read supabase/functions` green.
- [ ] **Step 4:** SCHEMA.md reminders section.
- [ ] **Step 5: Commit** `feat(notify): a reminder before a canteen duty, and duty bookings told like group ones (0050)`.

---

### Task 4: App domain, models, providers, API

**Files:**
- Create: `lib/domain/duties.dart`, `test/domain/duties_test.dart`
- Modify: `lib/domain/models.dart` (`DutyPeriod`, `DutyAssignment`, `DutySeason`, `ScheduleSettings.dutyReminderEnabled/dutyReminderDays`), `lib/data/providers.dart`, `lib/core/ui.dart` or wherever `friendlyDbError` lives, tests for models/errors/tenant reset.

**Produces (Dart):**
- Models with `fromJson`.
- `lib/domain/duties.dart` (pure): `planDutyPeriods(from, days, until, existing)` mirroring `duty_generate` (for the preview: created, skipped, last clipped length), `DutyPeriod? periodOn(periods, Day day)`, `seasonRanges(seasons)` (+ the implicit first season), `dutyCounts(periods, assignments, season)` → per user `(duties, days, served)`, `dutyHeaderLabel(week, periods, assignments, names, meId)` (the spec's „Slouží: …“ forms, `null` when none), `MyDuty myDuty(periods, assignments, meId, today)` → `(current, next, onDuty, coAssignees)`.
- Providers: `dutyPeriodsProvider`, `dutyAssignmentsProvider` (`cachedRows` streams with the retry/refresh wrapper used by the other live streams), `dutySeasonsProvider` (FutureProvider), `myDutyProvider` (recomputes on `nowProvider`), all in `resetTenantScopedProviders`.
- `Api`: `dutyGenerate`, `dutyPeriodSave`, `dutyPeriodDelete`, `dutyPeriodsDeleteUnassigned`, `dutySetAssignees`, `dutySeasonStart`, `dutySeasonDelete`, `setDutyReminder(enabled, days)` (optimistic, like the other settings). `Api.addSpecialBlock` and `Api.deleteDayOverride` call the new RPCs (same Dart signatures).
- `friendlyDbError`: every new code with the spec's Czech text, plus `not_allowed` while the caller was on duty → „Služba skončila — tohle teď může jen správce.“ (mapped where the calendar knows `onDuty` was true; the plain `not_allowed` message stays elsewhere).

- [ ] **Step 1: tests first** (domain with fixed `Day`s, never `DateTime.now()`; models; errors; tenant reset includes the new providers). **Step 2** fail. **Step 3** implement. **Step 4** green, analyze clean.
- [ ] **Step 5: Commit** `feat(duty): the duty model, providers and API in the app`.

---

### Task 5: Správa → Služby

**Files:**
- Create: `lib/features/admin/duties_admin_screen.dart` (split into widgets under `lib/features/admin/widgets/` when a file passes ~500 lines), `lib/features/admin/duties_history_screen.dart`, tests under `test/features/`.
- Modify: `lib/features/admin/admin_screen.dart` (entry „Služby“, `Icons.local_cafe_outlined`, after „Docházka“).

Build the spec's „Admin UI (Správa → Služby)“ section: header with the season, the reminder card (switch + „Předstih“), the chronological plan list (current period tinted with „Teď slouží“, „Neobsazeno“ in the error colour, past periods collapsed „Minulé služby (N)“), the ⋮ per period („Upravit termín…“, „Smazat“ with its confirm), the bottom `ListActionBar` („Vygenerovat…“, „Přidat službu“, overflow „Smazat neobsazené budoucí…“), the generator dialog with the live preview from `planDutyPeriods`, the assign sheet (search, Czech-sorted checkboxes, season count „2×“, „Uložit a další“ / „Uložit“), the „Přehled sezóny“ card (every approved player incl. placeholders, Czech-sorted, „— “ for zero), the AppBar ⋮ („Nová sezóna…“, „Historie“, „Vrátit poslední sezónu“), the new-season dialog and the history screen.

- [ ] **Step 1: widget tests first** (Api injected like other admin screens): generator preview counts; assign sheet saves the chosen ids; „Uložit a další“ moves to the next period; delete confirm; counts card order and texts; reminder switch/lead saves; new season dialog; history shows a past season read-only. 360dp without overflow.
- [ ] **Step 2** fail. **Step 3** implement. **Step 4** green.
- [ ] **Step 5: Commit** `feat(duty): Správa → Služby — plan, assign, counts, seasons`.

---

### Task 6: Klubovna → Služby and the week header

**Files:**
- Create: `lib/features/clubhouse/duties_screen.dart`, test.
- Modify: `lib/features/clubhouse/clubhouse_screen.dart` (entry „Služby“, subtitle „Kdo slouží na kantýně“; the hub already sorts Czech-alphabetically), the Kalendář week header (find where the week range is drawn in `lib/features/schedule/`), tests (`clubhouse_screen_test.dart` entry count/order, week header).

Build the spec's „Player UI“ Klubovna → Služby (my duty card on top, „Teď slouží“, upcoming chronological, „Minulé služby“ collapsed, my periods highlighted with the stripe, „ty“ and the chip „Tvoje služba“, empty state, footer, „Spravovat“ for admins) and the week-header line (`dutyHeaderLabel`, tinted „Sloužíš ty · do …“, tap opens Služby).

- [ ] **Step 1: tests first** — my card: current / next / none, reminder line when on; highlight only on my periods; Czech-sorted names; hub order Kontakty, Kuželny, Služby, Výsledky; header forms: one period, a change inside the week, none, me.
- [ ] **Step 2** fail. **Step 3** implement. **Step 4** green.
- [ ] **Step 5: Commit** `feat(duty): Klubovna → Služby and „Slouží:“ in the week header`.

---

### Task 7: The calendar while on duty

**Files:**
- Modify: `lib/features/schedule/schedule_actions.dart`, `week_screen.dart`, `day_pager_view.dart`, the block dialog and day header widgets (find `BlockDialog`, `DayHeader`), and the `canBook`/`canCancel` helpers; tests.

Build the spec's „Calendar while on duty“ and „Closing a day“: `ScheduleActions(onDuty:)` from `myDutyProvider`; `canEditDays = (isAdmin || onDuty) && blocksFromDb` for the day-block gestures (add in a gap, edit for the day, move); the template, matches, blockages and rentals keep their admin-only hooks (null for duty); `_book` for duty opens the player-search dialog (disabled „Rezervovat“ and the limit note for a player at the limit); `canCancel(onDuty:)` for others' not-started reservations through the admin's notify-choice dialog; the own-limit banner text; „Zavřít den“ in the day-mode block dialog for admin and duty; the portrait `DayHeader` ⋮ („Přidat blok…“, „Zavřít den…“, „Obnovit týdenní rozvrh“); `not_allowed` after the duty ended → „Služba skončila — tohle teď může jen správce.“

- [ ] **Step 1: tests first** — a player on duty: can open the booking dialog for another player, can cancel another's future reservation, has the day-block hooks, has NO priority/rental/template hooks; a player off duty: none of it; an admin: unchanged; „Zavřít den“ flow calls `setDayOverride(closed: true)`; the ⋮ menu in portrait.
- [ ] **Step 2** fail. **Step 3** implement. **Step 4** the whole suite green.
- [ ] **Step 5: Commit** `feat(duty): the calendar lets the player on duty run the day`.

---

### Task 8: Changelog and final checks

**Files:** `lib/features/profile/changelog_data.dart` (top unversioned batch), `docs/SCHEMA.md` if anything is missing.

- [ ] Add „Služby na kantýně: správce plánuje služby v Správa → Služby, všichni je vidí v Klubovna → Služby. Kdo má službu, může po dobu služby rezervovat a rušit tréninky ostatním a upravovat bloky v jednotlivých dnech.“ Keep `test/changelog_test.dart` and `test/features/store_notes_test.dart` green (add a `store:` summary if the batch passes 500 characters).
- [ ] Run everything: `flutter analyze`, `TZ=Europe/Prague flutter test`, the SQL test file, `deno check`, `deno test --allow-read supabase/functions`; the migration applied twice; the snapshot current (`supabase db dump --local --schema public` equals `supabase/schema.sql`).
- [ ] **Commit** `docs(duty): changelog line`.
