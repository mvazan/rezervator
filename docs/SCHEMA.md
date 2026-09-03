# Rezervátor — effective database schema

Source of truth: `supabase/migrations/` (append-only, 0001 → latest).
`supabase/schema.sql` is the `pg_dump` of what those migrations build
(`tool/schema_snapshot.sh`; the CI job `backend` fails when it is stale).
This page is the human summary — what each object is for, who may touch it
and what cascades — and is updated with every migration.

## Tenancy model

- One row of `tenants` = one kuželna. Every other table carries `tenant_id`;
  `current_tenant_id()` (security definer, reads `profiles.tenant_id` of
  `auth.uid()`) scopes every policy, so a client only ever sees its own
  kuželna.
- `profiles.role` ∈ player | admin | kiosk, `profiles.status` ∈ pending |
  approved. Helpers used by policies: `is_approved()`, `is_admin()`,
  `is_kiosk()`, `is_approved_or_kiosk()`, `is_superadmin()`.
- Superadmin (`profiles.superadmin`, `home_tenant_id`): approves new
  kuželny and may `switch_tenant()` — that rewrites their own `tenant_id`,
  so the whole app shows the chosen kuželna. While `tenant_id ≠
  home_tenant_id` they are *visiting*: hidden from the `players` view and
  from `monthly_attendance`.
- New kuželny start `pending`; the registration dropdown lists approved ones
  only and the founder waits on the waiting screen until approval.
- Players without an account (`profiles.placeholder`, 0022): the admin
  creates the profile by hand (`save_placeholder_player`); it has no
  `auth.users` row — `profiles.id` no longer references `auth.users`, and
  deleting an auth user no longer cascades to its profile. Always an approved
  plain player (`profiles_placeholder_check`): bookable from the calendar and
  the kiosk, never admin/kiosk (`placeholder_no_account`), never a founding
  member. When the person registers, `merge_placeholder_player` moves the
  reservation history onto the account (`profiles.id = auth.uid()` is the
  identity, so the account row is the one that survives), writes the
  admin-chosen name/nick/club, approves it and deletes the placeholder.

## Tables

| Table | Purpose / key columns | RLS (all `tenant_id = current_tenant_id()` unless noted) |
|---|---|---|
| `tenants` | `name` unique, `founder_email` (only the founder can become the first admin), `status`, `approved_at` | select for `authenticated` `using (true)` **but column grants expose only `id, name, status`** — `founder_email` never leaves the server. Writes: RPC only. |
| `profiles` | `id` (= `auth.uid()` for real accounts; no FK to `auth.users` since 0022), `display_name`, `nick` ≤ 14, `email` ('' for placeholders), `role`, `status`, `club_id → clubs`, `fcm_token`, `superadmin`, `home_tenant_id`, `approved_by/at`, `placeholder` (hand-made row: player ∧ approved ∧ not superadmin) | select: own row, or admin of the same tenant. update: own row, columns `display_name`, `fcm_token` only. insert/delete: RPC only. |
| `schedule_settings` | PK `tenant_id`; `lane_count` 1–12, `training_weekdays smallint[]` (ISO 1–7), `booking_horizon_days` 1–90, `max_active_reservations` 1–50, `kiosk_dark`, `kiosk_fit_day` | select approved/kiosk; update admin. |
| `time_blocks` | `starts_at`, `ends_at`, `position`, `active`. `position = -1` marks a day-special block: inactive, reachable only through `day_overrides.block_ids` | select approved/kiosk; insert/update/delete admin. FK from `reservations` is RESTRICT — only never-used blocks can be deleted. |
| `day_overrides` | PK (`tenant_id`, `date`); `closed`, `reason`, `block_ids uuid[]` (`null` = the default active set) | select approved/kiosk; write admin. Normally written through `set_day_override`. |
| `priority_slot_types` | `name` unique per tenant, `color`, `lanes smallint[]` (`null` = whole alley), `is_match`, `builtin` ('Zápas', 'Úklid před zápasem' seeded per tenant) | select approved/kiosk; insert/update admin (**column grants: `name, color, lanes` only**); delete admin ∧ `not builtin`. |
| `priority_slots` | `date`, `starts_at`, `ends_at`, `type_id`, `home_team`, `away_team`, `prep_minutes` 0–240, `description`, `parent_id` (the auto-managed úklid child), `is_away` (announced, blocks nothing), `import_key` (reserved) | select approved/kiosk; write admin. |
| `rentals` | `renter_name`, `lanes`, exactly one of `date` / `weekday`, `starts_at`, `ends_at`, `valid_from/until`, `note`, `color` (−2 = default tint). **Exception rows** (0021): `parent_id → rentals` (cascade delete) + `date` = the one occurrence of that weekly series they override, with their own `lanes`, `starts_at`, `ends_at`, `note`; `skipped` = the occurrence does not happen. One per (`parent_id`, `date`). `renter_name`/`color` are copied from the series by `rental_exception_guard`, which also rejects an off-series date, a one-time or child parent and a foreign tenant (`rental_exception_invalid`); `rental_series_changed` prunes children a series edit orphans and re-copies name/colour. | select approved/kiosk; write admin. |
| `reservations` | `player_id`, `date`, `block_id`, `lane`, `created_via` app\|kiosk\|admin, `cancelled_at/via` app\|one_click\|admin, `cancel_note`, `notify_player`, `notify_message` (per-change intent for the notify function) | **select only** (approved/kiosk). Every write is an RPC, a trigger, or the `cancel` edge function. Live slots are unique: `(date, block_id, lane) where cancelled_at is null`. |
| `clubs` | `name` unique per tenant, `color` 0–11 (−1 = none) | select approved/kiosk; all admin. |

View `players` (owned by postgres → bypasses `profiles` RLS on purpose):
approved, non-kiosk members of the caller's tenant minus visiting
superadmins — `id, display_name, nick, club_id, club_color, placeholder`
(0022 appended `placeholder` with `create or replace`, which keeps the
ACL). This is the only profile data the kiosk account can read. SELECT for
`authenticated` only.

## Privileges (0017)

`authenticated` has select/insert/update/delete on the app tables (policies
decide rows), the column-restricted exceptions above, SELECT on `players`
and `tenants(id, name, status)`. `anon` has nothing. `service_role`
(edge functions) has everything. Default privileges are pinned (0017,
0020) so new tables get exactly that shape on hosted and local stacks —
note that a `drop … create` of a view re-applies the defaults, so a
recreated read-only view must revoke again (that is what 0020 fixes for
`players`). Internal helper functions have EXECUTE revoked from the app
roles (see below).

## RPCs

| Function | Who | Effect / raises |
|---|---|---|
| `register_profile(display_name, tenant_id, club_id?, nick?)` | signed-in user without a profile | First approved member of a tenant (or the `founder_email` match) becomes approved admin, everyone else pending; placeholders never count as the first member. `empty_display_name`, `nick_too_long`, `unknown_tenant`, `unknown_club`. |
| `create_tenant_and_register(tenant_name, display_name, nick?)` | signed-in user | Creates a pending tenant with the caller as founder, then registers. `empty_tenant_name`, `tenant_exists`. |
| `registration_clubs(tenant_id)` | signed-in, pre-profile | Club list for the register screen. |
| `approve_player(user_id)`, `set_role(user_id, role)`, `set_player_club(user_id, club_id)`, `upsert_club(...)`, `delete_club(id)` | admin | Member and club administration. `cannot_demote_self`, `placeholder_no_account` (a hand-made profile stays a player), `unknown_club`. |
| `save_placeholder_player(id?, display_name, nick, club_id)`, `delete_placeholder_player(id)`, `merge_placeholder_player(placeholder_id, target_id, display_name, nick, club_id)` | admin | Players without an account. Save: `id = null` inserts an approved placeholder of the caller's tenant, otherwise edits one (`unknown_player`); `empty_display_name`, `nick_too_long`, `unknown_club`. Delete: `player_has_history` when any reservation references it. Merge: the source must be a placeholder, the target any non-placeholder non-kiosk profile of the tenant (`invalid_merge`); repoints the reservations, writes the chosen fields, approves a pending target, deletes the source. |
| `set_nick(user_id, nick)` | self or admin | `nick_too_long`. |
| `create_reservation(player_id, date, block_id, lane)` | player for self, kiosk for any approved member, admin for anyone | Admin skips past/horizon/limit. Raises `player_not_approved`, `unknown_block`, `invalid_lane`, `day_closed` / `invalid_block` (via `block_day_status`), `date_past`, `beyond_horizon`, `limit_reached`, `blocked_by_priority`, `blocked_by_rental` (via `rental_occurrences`), `slot_taken`. |
| `cancel_reservation(id, note?, notify?)` | owner before the block starts, admin anytime | `too_late`, `not_allowed`; sets `cancelled_via` app / admin. |
| `move_reservation(...)`, `move_day_reservations(...)` | admin | Re-seat one / all reservations of a day; same collision rules as create (rentals resolved by `rental_occurrences`). `slot_taken`, `blocked_by_*`. |
| `cancel_block_day_reservations(date, block, note?)` | admin | Bulk cancel before hiding a template block for one day. |
| `set_day_override(date, closed, reason?, block_ids?)` | admin | Upsert the override and cancel the reservations it displaces. |
| `monthly_attendance(year, month)` | admin | Rows (player, club name, attended) — uncancelled reservation = attendance. |
| `admin_list_tenants()`, `approve_tenant(id)`, `reject_tenant(id)`, `switch_tenant(id)` | superadmin (`not_allowed` otherwise) | `reject_tenant`: pending only (`not_pending`), refuses while the caller is switched into it (`switch_home_first`), deletes the whole tenant. |

Internal, no EXECUTE for app roles: `current_tenant_id`, `is_*`,
`block_day_status`, `cancel_stranded_reservations`, `rental_occurs`,
`rental_occurrences`, `cancel_res_for_priority_slot`,
`notify_webhook_config`, `seed_demo_member` (service_role only —
Play-review demo account).

`block_day_status(tenant, date, block)` → `open` | `day_closed` |
`invalid_block` | `unknown_block` is the one definition of "this block is
bookable on this date" (override wins over the weekly template; an inactive
block counts only when an override lists it). `create_reservation` and the
cascade below both use it.

`rental_occurrences(tenant, date)` → (`rental_id`, `override_id`,
`renter_name`, `lanes`, `starts_at`, `ends_at`) is the one definition of
"which rentals block this date": every top-level row that occurs on it
(`rental_occurs` — one-time date, or weekday inside the validity window),
with the date's exception row overriding lanes/times and a `skipped` one
removing the occurrence. `create_reservation`, `move_reservation` and the
rental cascade all use it; the client mirrors it in `rentalsOn`.

## Cascades — what cancels reservations

Every cascade sets `cancelled_via = 'admin'`, `notify_player = true`, and
the notify function mails "Trénink zrušen" with the note as the reason
(past dates stay silent).

| Event | Mechanism | Which reservations | Note |
|---|---|---|---|
| rental insert/update; exception insert/update/delete | trigger `rental_conflicts` | series: every date ≥ today it occurs on, as resolved by `rental_occurrences` (exceptions applied); exception: its date (and the date it left) — enlarging, un-skipping or deleting an exception cancels what was booked in the freed slots, a shrinking one only frees them | `pronájem: <renter>` |
| priority slot insert/update | trigger `priority_conflicts` → `cancel_res_for_priority_slot` | type's lanes, overlapping time, same date, not away | `zápas: <away>` or the type name |
| slot type update (lanes) | trigger `slot_type_conflicts` | re-runs the above for the type's slots | as above |
| `set_day_override` | inside the RPC | that date: all when closed, else blocks not in `block_ids` | reason or `změna rozvrhu` |
| `cancel_block_day_reservations` | RPC | that date × block | parameter (default `změna rozvrhu`) |
| settings `lane_count` / `training_weekdays` update, block `active` → false, any `day_overrides` write or delete | triggers `settings_shrink`, `block_deactivated`, `override_changed` → `cancel_stranded_reservations` | future, not-yet-started rows with `lane > lane_count` or `block_day_status ≠ open` | override reason or `změna rozvrhu` |

Other triggers: `tenant_seed_defaults` (settings row + builtin types for a
new tenant), `match_uklid_sync` (keeps a match's úklid child in step with
`prep_minutes`), `rental_exception_guard` (before insert/update of a rental
exception: validation + name/colour copy), `rental_series_changed` (after
update of a weekly rental: prune orphaned exceptions, propagate name/colour), `notify_profiles` / `notify_reservations` /
`notify_tenants` (`notify_webhook` → the notify function).

## Edge functions

- **notify** — called by `notify_webhook()` (pg_net POST; URL and
  `x-webhook-secret` come from Vault `notify_url` / `webhook_secret`,
  SETUP.md §2). Events: profile insert (pending) → tenant admins
  (placeholders are inserted approved, so none); kiosk
  reservation insert → the player, with a one-click cancel link (HMAC
  token signed with `CANCEL_TOKEN_SECRET`, valid until the block starts);
  reservation update: admin cancel of an upcoming date → the player
  (honours `notify_player`, `cancel_note` as the reason), move → the player
  ("Termín přesunut", `notify_message` overrides the wording); tenant
  insert (pending) → superadmins. Channel: FCM push when the profile has an
  `fcm_token` and `FIREBASE_SERVICE_ACCOUNT` is set, otherwise Resend
  e-mail. Fails closed on a missing `WEBHOOK_SECRET` (401) or
  `CANCEL_TOKEN_SECRET` (500).
- **cancel** — GET renders the confirmation page, POST verifies the token
  and updates `reservations` directly with the service role
  (`cancelled_via = 'one_click'`). This is the one reservation write outside
  the RPCs; the notify function ignores `one_click` cancels.

## Prod vs git

- Prod additionally has Supabase's platform function `rls_auto_enable`
  (event-trigger helper) — not ours, not in migrations.
- Vault secrets `notify_url` and `webhook_secret` are per-backend
  configuration, never in migrations.
- Hosted default privileges grant `anon`/`authenticated` on every new
  object; 0017 pins explicit defaults so a git-built database matches.

## Checks

- `tool/schema_snapshot.sh` regenerates `supabase/schema.sql` after a new
  migration (local stack only).
- `supabase/tests/tenancy_rls.sql` — cross-tenant isolation, superadmin
  visiting, the 0018 cascade, the 0021 rental exceptions, the
  `reject_tenant` guard and the 0022 placeholder lifecycle; run with
  `psql … -v ON_ERROR_STOP=1 -f` against the local stack (CI does).
