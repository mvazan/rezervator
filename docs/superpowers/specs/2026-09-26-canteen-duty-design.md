# Služby na kantýně (canteen duty)

Requested by the user on 2026-09-26; the design came out of three independent proposals (backend, admin UX, player UX), two judges and a synthesis. The app speaks Czech; the user writes Slovak. Migration `0050_canteen_duty.sql` (main is at 0049).

## Decided with the user

- **Two rights, two clocks.** The weekly template (Správa → Rozvrh) stays admin-only.
  - **Rule B — reservations of others:** book and cancel trainings for other players only WHILE on duty (a period covering today's Prague date), on any date from today on — also dates that belong to other people's periods — under the booked player's normal rules: the admin's booking horizon, the player's cap on active reservations, no started block, no past date. A player whose only period is next week is not on duty today and books and cancels for nobody yet.
  - **Rule A — blocks of a day:** add a special block for a day, edit a block for a day, move players between blocks, close a day, restore the weekly template for a day, cancel a block's day reservations — only on dates inside one of the player's OWN periods, and never in the past. Moving players between blocks includes re-seating one reservation (`move_reservation`, the per-player step of removing a block for a day); while on duty the player may also do that on any future day. Being on duty today is NOT required: „next week Monday–Wednesday I have duty → I can edit blocks already today, but only for Monday–Wednesday of next week.“ A date outside the own periods (someone else's period, a gap, a duty that ended) is refused and the app does not offer it. The admin edits any date, as ever.
- **Who sees the roster:** every player of the alley — Klubovna → Služby and a „Slouží: …“ line in the Kalendář week header. The admin plans, counts and keeps history in Správa → Služby.
- **Reminder before a duty:** yes; the admin switches it on or off for the alley and picks the lead (1 day, 2 days, …).
- **Booking rules for the duty:** the booked player's usual rules apply — their active-reservation limit, the booking horizon, no block that has already started. Only the admin may go past them.
- **No message on assignment:** the reminder before the duty is enough; the roster shows in Klubovna → Služby.
- **My duty lives in Klubovna → Služby, not in Můj profil** (the user's call after the first draft): a card for my current or next duty on top, and my periods highlighted in the list.

## Why
Each week one or more club members work in the canteen. That person has to book trainings for walk-ins, cancel them, and adjust the day (add or remove a block, close the day), but must not become an admin. The admin plans a fair rotation, sees who served how often, and resets the counts each season without losing history.

## Decisions (trade-offs resolved)
1. **No new `profiles.role` value.** "Kantýnský" means an approved `player` account assigned to a duty period that covers today's Prague date. `set_role`, kiosk, superadmin and the players view stay untouched. All three proposals agreed on this.
2. **The rights live only in security-definer RPCs, and no table policy gets wider.** The app writes directly to tables in two places today (`Api.addSpecialBlock`, `Api.deleteDayOverride`). Both move behind new RPCs with the same Dart signatures. I rejected the extra-policy approach: those policies would need `is_on_duty()` to be executable by `authenticated`, and a direct override delete skips the write order that `restoreDayToTemplate` relies on.
3. **The duty gets kiosk-level rules, not the admin's exemptions.** That means the target player's booking limit, the booking horizon, no past or already-started blocks, and block edits only on the days of the duty's own periods, from today on. All of it is enforced in SQL (`date_past`, `too_late`). Attendance history stays admin-only. I rejected proposal 2's admin-like booking because it lets the duty rewrite `monthly_attendance`.
4. **A new via value `'duty'` instead of reusing `'admin'`.** The booked player learns who booked them, and the audit trail stays honest.
5. **Branch order is admin → kiosk → self → group → duty.** A duty holder who books a group mate still books as `'group'`, and their own bookings stay `'app'`.
6. **Streams are unfiltered, and counts are computed in pure Dart.** These tables hold a few hundred rows per decade. This fixes proposal 1's bug, where counts built from a filtered stream would be wrong from mid-season on. It also removes the need for copied dates and copy triggers.
7. **A season is a boundary row, and a reset moves nothing.** Undo means deleting the newest boundary. I rejected proposal 3's `season_id` foreign key and moving rows on reset.
8. **The generator skips periods that already exist and shows a preview.** Deleting all unassigned future periods in one step makes a rhythm change cheap. The rhythm itself is not stored.
9. **A separate `due_duty_reminders()` function.** `due_reminders()` and the 0049 tests stay untouched.
10. **No grace period at midnight.** When a refused call comes back and the duty has just ended, the app shows a clear message instead.
11. **Portrait mode gets a ⋮ day menu**, because canteen staff hold a phone. Dragging a block to move it stays landscape-only.

## Data model
- **`duty_periods`**
  - Columns: `id uuid pk`, `tenant_id → tenants cascade`, `starts_on date`, `ends_on date` (inclusive), `note text not null default ''` (at most 80 characters), `created_by → profiles set null`, `created_at`.
  - Checks: `ends_on >= starts_on` and `ends_on - starts_on < 62`.
  - `duty_periods_no_overlap exclude using gist (tenant_id with =, daterange(starts_on, ends_on,'[]') with &&)`. This needs `create extension if not exists btree_gist`.
  - Index on `(tenant_id, starts_on)`.
- **`duty_assignments`**
  - Columns: `period_id → duty_periods cascade`, `user_id → profiles cascade`, `tenant_id` (denormalised the same way as `player_group_members`), `assigned_by`, `created_at`.
  - Primary key `(period_id, user_id)`, index on `(tenant_id, user_id)`.
  - Placeholders ("hráč bez účtu") may be assigned.
- **`duty_seasons`**
  - Columns: `tenant_id`, `started_on date`, `name text` (1–40 characters, e.g. „2026/27“), `created_by`, `created_at`. Primary key `(tenant_id, started_on)`.
  - A period belongs to the season with the greatest `started_on ≤ period.starts_on`. Periods before the first boundary form the implicit first season.
- **`schedule_settings`** gets two columns:
  - `duty_reminder_enabled boolean not null default false`
  - `duty_reminder_days smallint not null default 1 check (1..14)`
  - Switching the reminder off keeps the chosen lead time.
- **`reservations`**: `'duty'` is added to `created_via_check` and `cancelled_via_check`. Each constraint is dropped and re-added as `NOT VALID`, then `VALIDATE`d, to avoid a long exclusive lock.
- **RLS**, the same on all three tables:
  - `select using (tenant_id = current_tenant_id() and is_approved_or_kiosk())`, with no write policies.
  - Grants: `grant select to authenticated; grant all to service_role; revoke insert, update, delete from authenticated; revoke all from anon`.
- **Realtime**: `duty_periods` and `duty_assignments` are added to the publication inside a guarded `do` block. `duty_seasons` is not streamed: it is a `FutureProvider` that is invalidated after a reset or undo. `public_week` is unchanged, so no names leak into the public overview.
- **Placeholder lifecycle**:
  - `delete_placeholder_player` raises `player_has_history` when duty rows exist.
  - `merge_placeholder_player` moves the assignments to the account and drops duplicates.

## Rights
```sql
create or replace function is_on_duty() returns boolean language sql stable
security definer set search_path = public as $$
  select exists (select 1 from duty_assignments a
    join duty_periods d on d.id = a.period_id
    join profiles me on me.id = auth.uid()
   where a.user_id = me.id and d.tenant_id = me.tenant_id
     and me.status = 'approved' and me.role = 'player' and not me.placeholder
     and (now() at time zone 'Europe/Prague')::date between d.starts_on and d.ends_on) $$;
```
- **Internal helpers.**
  - `duty_gate(p_date)` (rule B) passes for an admin. Otherwise it requires `is_on_duty()` (else `not_allowed`) and `p_date >= Prague today` (else `date_past`).
  - `duty_edit_gate(p_date)` (rule A) passes for an admin. Otherwise the caller must be an approved, non-placeholder `player` (`is_on_duty()`'s account conditions minus „covers today“) with a `duty_assignments` row on a period of the same tenant that covers `p_date`, else `not_allowed`; only then `p_date < Prague today` raises `date_past`. It calls neither `is_on_duty()` nor `duty_gate()`. With `p_date` null (no date named yet — `add_special_block`) it asks for an own period with `ends_on >= Prague today`.
  - All three functions are revoked from `public`, `anon` and `authenticated`, because only definer bodies call them, the same way `same_group` works.
  - Note for the implementer: `is_admin()` is PUBLIC-executable because policies call it. Do not copy proposal 1's "internal like `is_admin`" comment.
- **`create_reservation`** gets a new branch after the group branch: approved player, `p_player_id <> v_uid`, `is_on_duty()` → `v_via := 'duty'`. The existing non-admin block (past, started, horizon, the target's limit) still applies. The limit error is `player_at_limit` when `v_via = 'duty'`.
- **`cancel_reservation`** gets a new branch after the owner/group branch: approved player, same tenant, `is_on_duty()`, and the block has not started yet (else `too_late`). It sets `v_via 'duty'`, `cancelled_by`, `cancel_note` and `notify_player = p_notify`.
- **`set_day_override`, `cancel_block_day_reservations`, `move_day_reservations`**: the gate `is_admin()` becomes `duty_edit_gate(date)`.
- **`move_reservation`** (one reservation) serves both rights, because removing a block for a day re-seats its players one by one through it: the gate `is_admin()` becomes „`duty_edit_gate(null)` before the row is read (unless on duty today), then `duty_gate(date)` for a player on duty today and `duty_edit_gate(date)` for anyone else“. A move keeps its date, so source and target are one.
- **New RPCs**, both gated by `duty_edit_gate`:
  - `add_special_block(p_starts_at, p_ends_at) → uuid` inserts `position -1, active false`. It has no date, so its gate is `duty_edit_gate(null)`: an own period that has not ended; the `set_day_override` that points a day at the block names the real date and holds the player to their own periods.
  - `delete_day_override(p_date)`.
- **Still admin-only**: the weekly template, `priority_slots`, rentals, slot types, settings, clubs, profiles and every Správa screen.
- **notify changes**:
  - INSERT with `created_via 'duty'` sends `groupBookedMessage` („Jan Novák ti zarezervoval(a) trénink…“), kind `duty_booking`.
  - UPDATE with `cancelled_via 'duty'` follows the admin branch semantics (honours `notify_player`, silent for past dates). The default reason is „zrušil(a) Jan Novák (služba na kantýně)“, never „zrušeno správcem“.
- **Edge cases**:
  - An admin who is also on duty takes the admin path and is still counted.
  - Placeholders are counted but never get rights.
  - A kiosk account can never be assigned.
  - A pending or demoted player loses the rights at once.
  - A visiting superadmin gets no duty rights, because of the tenant match.
  - Periods cannot overlap.
  - At midnight every call is re-evaluated. If the dialog was opened while the duty was running and the duty is over now, `not_allowed` shows as „Služba skončila — tohle teď může jen správce.“ A multi-step BlockDialog save stops at the first refused step, which is the same outcome as an admin losing the connection today. For a date outside the own periods there is no refusal text: the entry is simply not offered.

## Generation & editing
All admin-only, security definer; revoked from `public` and `anon`, granted to `authenticated`.
- **`duty_generate(p_from date, p_days smallint 1..31, p_until date) → jsonb {created, skipped}`**
  - The range is at most 400 days. For each start `s` it computes `e = least(s+days-1, until)`; overlapping periods are skipped, and the last period is clipped.
  - „Týdně, mění se v út“ = 7 days from the next Tuesday. „Po N dnech“ = N days.
  - Defaults come from the last period: start = its `ends_on + 1`, length = its length.
- **`duty_period_save(p_id, p_starts_on, p_ends_on, p_note) → uuid`**: a null `p_id` inserts. An `exclusion_violation` is re-raised as `duty_overlap`. Other errors: `invalid_range`, `duty_too_long`, `unknown_period`.
- **`duty_period_delete(p_id)`** and **`duty_periods_delete_unassigned(p_from) → int`**.
- **`duty_set_assignees(p_period, p_users uuid[])`** replaces the whole set. Each target must be in the same tenant, approved and not a kiosk, with placeholders allowed; otherwise `unknown_player`.
- **`duty_season_start(p_started_on, p_name)`** (`season_order`, `empty_name`) and **`duty_season_delete(p_started_on)`** (newest only, else `not_newest`).
- **Reminder setting**: written directly through the existing `settings_update` policy with `optimisticWrite`.
- **`friendlyDbError` strings**:
  - `duty_overlap` → „Služba se překrývá s jinou.“
  - `invalid_range` → „„Do“ musí být po „Od“.“
  - `duty_too_long` → „Služba může mít nejvýše 62 dní.“
  - `unknown_period` → „Tahle služba už neexistuje.“
  - `season_order` → „Nová sezóna musí začínat po té současné.“
  - `not_newest` → „Vrátit jde jen poslední sezónu.“
  - `player_at_limit` → „Hráč už má maximální počet rezervací.“
  - `player_has_history` → the existing message.
- **Dart**:
  - `lib/domain/duties.dart` is pure and unit-tested: `planDutyPeriods` (mirrors the SQL), `periodOn`, `seasonRanges`, `dutyCounts` (duties, days, served), `dutyHeaderLabel`, `seasonNameFor`.
  - Providers: `dutyPeriodsProvider` and `dutyAssignmentsProvider` use `cachedRows` with the retry and refresh-on-resume wrapper. `myDutyProvider` gives `(current, next, mine, onDuty)` and recomputes on `nowProvider`; `mine` is every period of mine that has not ended (`endsOn >= today`), and `coversDay(day)` says whether one of them covers a day — rule A's client half, independent of `onDuty` (rule B's). All of them are added to `resetTenantScopedProviders`.

## Admin UI (Správa → Služby)
The hub entry „Služby“ (`Icons.local_cafe_outlined`) goes after „Docházka“. The screen is `DutiesAdminScreen` with `AdminScaffold('Služby')`.
- **AppBar ⋮ menu**: „Nová sezóna…“, „Historie“, „Vrátit poslední sezónu“.
- **Header**: „Sezóna 2026/27 · od 1. 9. 2026“.
- **Reminder card**:
  - SwitchListTile „Připomínka služby“; when on, the dropdown „Předstih“ offers 1 den / 2 dny / 3 dny / týden.
  - Subtitle: „Odesílá se v 18:00. Push, jinak e-mail. Hráči bez účtu ji nedostanou.“
- **Plan list**:
  - Chronological. The running period is tinted and has the chip „Teď slouží“.
  - Tile title: „po 5. 10. – ne 11. 10.“, with the note appended.
  - Subtitle: assignees sorted Czech-alphabetically; placeholders get „· bez účtu“; an unassigned period shows „Neobsazeno“ in the error colour.
  - Tapping a tile opens the assign sheet. The ⋮ menu offers „Upravit termín…“ and „Smazat“ (confirm: „Přiřazení hráči o ni přijdou.“).
  - Past periods of the season sit collapsed at the bottom under „Minulé služby (N)“.
  - The bottom ListActionBar (not a FAB) holds „Vygenerovat…“, „Přidat službu“, and in the overflow „Smazat neobsazené budoucí…“.
- **Generator dialog**:
  - Segmented choice „Každý týden“ | „Po N dnech“. Weekly shows weekday chips po–ne; „Po N dnech“ shows „Počet dní“.
  - Date fields „Od“ and „Do“ (default 30. 6.).
  - Live preview: „Vznikne 40 služeb, poslední zkrácená na 3 dny. 2 se překrývají a přeskočí se.“
- **Assign sheet**:
  - Search „jméno nebo přezdívka“, insensitive to diacritics.
  - One checkbox per player, sorted Czech-alphabetically. The trailing text shows the season count, e.g. „2×“, so the admin can balance while picking.
  - Buttons „Uložit a další“ and „Uložit“.
- **„Přehled sezóny“ card**:
  - Every approved player, placeholders and zero counts included, sorted Czech-alphabetically (never by score).
  - Row text: „Jana Nováková — 3 služby · 21 dní (2 odslouženy)“; a zero count shows „—“.
- **History screen** (`AdminScaffold 'Historie služeb'`): season chips in chronological order, then the same read-only list and overview for the chosen season.
- **„Nová sezóna“ dialog**:
  - Fields „Název“ (default „2026/27“) and „Od“ (default today).
  - Text: „Počty služeb začnou od nuly. Naplánované služby zůstanou a pokračují stejně. Historie se dá zobrazit.“
  - Button: „Začít sezónu“.

## Player UI
- **Klubovna → Služby.** The hub sorts entries Czech-alphabetically: Kontakty, Kuželny, Služby, Výsledky. The entry's subtitle is „Kdo slouží na kantýně“, and the screen is read-only.
  - **My duty on top**, only when I have a current or upcoming duty: a card tinted `secondaryContainer`:
    - „Právě sloužíš — do ne 11. 10.“, with the co-assignees „spolu s: Jana Nováková“;
    - otherwise „Tvoje příští služba: po 19. 10. – ne 25. 10.“;
    - when the reminder is on, a line „Připomínku dostaneš 1 den předem.“ (the lead the admin set).
  - Then a card „Teď slouží: …“ with „do ne 11. 10.“ (hidden when I am the only one serving now, as my card already says it).
  - Below it, the upcoming periods in chronological order, then „Minulé služby“ collapsed.
  - **My periods are highlighted** in the list: a 4dp `primary` stripe on the leading edge, my name as „ty“ in w700, and a chip „Tvoje služba“; everyone else stays plain.
  - Empty state: „Služby zatím nejsou naplánované.“
  - Footer: „Během služby můžeš rezervovat a rušit tréninky ostatním a upravovat bloky v jednotlivých dnech.“
  - Admins also get a „Spravovat“ action.
- **Week header in Kalendář.** One extra `labelSmall` line under the range, with an ellipsis; tapping it opens Služby.
  - One period for the whole week: „Slouží: Jan Novák a Petr Svoboda“.
  - A change inside the week: „Slouží: po–st Jan Novák · čt–ne Petr Svoboda“.
  - No period that week: no line.
  - If I am on duty and the week contains today, the line is tinted: „Sloužíš ty · do ne 11. 10.“
  - In every other line I am „ty“, not my name, and last among the names of my period: „Slouží: po–čt ty · pá–ne Jan Novák“, „Slouží: Petr Svoboda a ty“ (untinted; „Sloužíš ty“ is the running duty's line).
- **Calendar while on duty** (`ScheduleActions(duty:)`, `onDuty` = rule B, `canEditDay(date)` = rule A):
  - `canEditDay(date) = blocksFromDb && (isAdmin || (date >= today && myDuty.coversDay(date)))` drives the block gestures per date, whether or not I am on duty today: add in a gap, edit for the day, move, the header ＋ and the portrait ⋮ menu. A date outside my own periods gets none of them.
  - Matches, blockages and rentals keep their admin-only hooks.
  - `_book` opens the player-search dialog. When the selected player is at the limit, the note reads „… už má maximální počet rezervací“ and „Rezervovat“ is disabled.
  - `canCancel(onDuty:)` allows other players' reservations that have not started, through the admin's notify-choice dialog. Still keyed on being on duty today, like booking for others and the own-limit banner.
  - The own-limit banner reads „Máš maximální počet rezervací — jako služba můžeš rezervovat jen pro ostatní.“
- **Closing a day.**
  - The day-mode BlockDialog opened from the header ＋ gains „Zavřít den“ for admin and duty: prompt „Důvod zavření“, then the standard count confirm, then `set_day_override(closed)`.
  - In portrait, `DayHeader` gets a ⋮ menu: „Přidat blok…“, „Zavřít den…“, „Obnovit týdenní rozvrh“.

## Reminders
- `due_duty_reminders()` is security definer and executable by `service_role` only. It returns one row per (assigned account, period) where:
  - `duty_reminder_enabled` is on;
  - 18:00 Prague on `starts_on − days` has passed;
  - the duty has not started yet;
  - the ledger has no entry.
- It excludes placeholders, pending players and kiosk accounts.
- Ledger entry: `reminders_sent` with key `'d:<period_id>'`, offset `days*1440`, and `starts_at` = Prague midnight of `starts_on`. Because it uses the 0049 semantics, a period moved to another date rings again.
- `notifications_due()` gets an extra `or exists (select 1 from due_duty_reminders())`.
- notify calls `sendDueDutyReminders()` after `sendDueReminders()`. The code lives in `_shared/duty_reminders.ts` and delivers and marks the same way as the existing reminders.
  - Title: „Zítra sloužíš na kantýně“ or „Za 2 dny sloužíš na kantýně“. A late send counts the Prague days actually left. „Dnes“ is never used, because a started duty is never due.
  - Body: „po 5. 10. – ne 11. 10.“, plus „, spolu s: Jana Nováková“ when others are assigned. The e-mail adds one sentence about the rights.

## Season reset & history
A reset is `duty_season_start`: it inserts a boundary row and nothing else.
- Counts cover periods whose `starts_on` falls in the current season's range, so everyone starts at 0.
- Periods already generated after the boundary keep running, so no new plan is needed.
- Earlier seasons stay intact and can be viewed in „Historie“.
- A mistaken reset is undone with „Vrátit poslední sezónu“.
- A period that straddles the boundary stays in the season where it started, and the dialog text says so.

## Migration & tests
- **Migration steps**, all idempotent and in this order:
  1. The extension.
  2. The tables, checks, exclusion constraint, indexes and comments.
  3. RLS, policies and grants.
  4. The guarded publication change.
  5. The settings columns.
  6. The via CHECKs.
  7. The helpers.
  8. The admin RPCs.
  9. The two new RPCs.
  10. `create or replace` of the 4 day RPCs, `create_reservation`, `cancel_reservation`, `delete_placeholder_player` and `merge_placeholder_player`, with their signatures unchanged.
  11. `due_duty_reminders()` and `notifications_due()`.
- **After the migration**:
  - Regenerate `supabase/schema.sql` with `tool/schema_snapshot.sh`, and update `docs/SCHEMA.md`.
  - Add the two tables to `v_streamed`.
  - No `min_build` bump: old builds keep working.
  - Deploy order: `db push`, then functions. In between, duty bookings and cancels are silent and duty reminders are not sent.
  - Before merging, check other local branches for a 0050 migration.
- **SQL tests** (new section in `tenancy_rls.sql`, using fixtures built from `now()`):
  - Privileges.
  - Generation, including skip and clip.
  - Assignment: kiosk, pending and foreign players refused; placeholder accepted.
  - `is_on_duty()`: before, inside and after the period; demoted player; other tenant.
  - Duty booking: `created_via 'duty'`, `player_at_limit`, `date_past`, `beyond_horizon`, `too_late`.
  - The block RPCs succeed on the days of the player's own periods (both of two consecutive ones, edges included) and fail with `not_allowed` on another duty's days and on days nobody serves; `date_past` for a past day inside an own period; a duty that starts next week edits exactly those days today and adds a block, and re-seats players on those days, but books and cancels for nobody; a duty ended yesterday adds no block, one ending today still edits today; pending, placeholder, kiosk and a visiting superadmin are refused; the admin edits any day.
  - Booking, re-seating and cancelling for others still work on another duty's days.
  - Direct template, `priority_slots` and `rentals` writes fail with 42501.
  - Everything is `not_allowed` outside the period.
  - The existing kiosk and 0044 group cases still pass.
  - Placeholder history is kept (refused on delete, moved on merge).
  - Seasons, including undo.
  - Reminders: the placeholder is excluded; the mark silences; moving the period re-arms; switching off returns nothing.
- **App tests**:
  - `duties_test.dart` (`myDuty`'s `mine` and `coversDay`), plus schedule `canBook` and `canCancel` with `onDuty`.
  - Week screen: a duty next week Monday–Wednesday gets the block edits (⋮ menu, header ＋) on those three dates and none elsewhere, and no booking dialog or cancel of others today; a duty running today books and cancels for others on any future date but edits blocks on the days of its own period only; the admin gets everything.
  - Klubovna order.
  - Klubovna and admin screens.
  - Week header line.
  - On-duty `ScheduleActions`: priority and rental hooks are null.
  - BlockDialog „Zavřít den“.
  - Služby: my card (current / next / none, reminder line) and my periods highlighted.
- **Deno test**: `duty_reminders_test.ts`.
