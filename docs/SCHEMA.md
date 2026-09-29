# Rezervátor — effective database schema

Source of truth: `supabase/migrations/` (append-only, 0001 → latest).
`supabase/schema.sql` is the `pg_dump` of what those migrations build
(`tool/schema_snapshot.sh`; the CI job `backend` fails when it is stale).
This page is the human summary — what each object is for, who may touch it
and what cascades — and is updated with every migration.

## Tenancy model

- The Demo kuželna (Google Play review) holds the memorable id
  `00000000-0000-0000-0000-000000000001` — the only tenant id any code knows
  (`AppConfig.demoTenantId` hides it in the registration picker). 0026 moved
  it there from `…0000de` and gave the pre-multitenancy bootstrap kuželna a
  random uuid, so every other tenant id is random. 0026 renumbers a primary
  key: it repoints children dynamically over the foreign keys onto `tenants`
  with `session_replication_role = replica`, checks for orphans, and is a
  no-op once done. `supabase/tests/tenancy_rls.sql` owns its own two tenants
  (`…00000a`, `…000002`) and never borrows the bootstrap one.
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
- The player on duty (služba na kantýně, 0050) is no role, and has two
  rights with two clocks, both only through security-definer RPCs — no table
  policy is wider — see **The player on duty** under RPCs. For both the
  player is an approved `player` account, not a placeholder, assigned
  (`duty_assignments`) to a `duty_periods` row of the alley they are in.
  - **Reservations of others** (book, cancel): only WHILE on duty —
    `is_on_duty()`, a period covering Prague today — on any date from
    today on, the other duties' days included.
  - **Blocks of a day** (add or edit a block, move its trainings — and
    re-seat the players of a removed block —, close the day, return it to
    the weekly rules, cancel a block's reservations): only on dates inside
    a period of their OWN, never in the past — on duty today or not
    (`duty_edit_gate(date)`). A duty next week Monday to Wednesday edits
    those three days already today, and no others.

  A pending or demoted player, a placeholder, the kiosk, an admin (who has
  the admin path anyway) and a visiting superadmin (the tenant match) have
  neither; at midnight every call is judged again.

## Tables

| Table | Purpose / key columns | RLS (all `tenant_id = current_tenant_id()` unless noted) |
|---|---|---|
| `tenants` | `name` unique, `founder_email` (only the founder can become the first admin), `status`, `approved_at`. **Public overview** (0043): `public_slug` unique, 3–40 lower-case letters/digits/hyphens (`tenants_public_slug_format`), `public_enabled` default off, `tenants_public_needs_slug` (can't enable without a slug) | select for `authenticated` `using (true)` **but column grants expose only `id, name, status`** — `founder_email` never leaves the server; `public_slug`/`public_enabled` are likewise outside the `authenticated` grant, read only by `public_tenant_id`/`my_public_overview`. Writes: RPC only. |
| `profiles` | `id` (= `auth.uid()` for real accounts; no FK to `auth.users` since 0022), `display_name`, `nick` ≤ 14, `email` ('' for placeholders), `role`, `status`, `club_id → clubs`, `fcm_token` (the device's push token; 0052: one profile per token — registering it takes it from every other profile, trigger `fcm_token_claim`), `superadmin`, `home_tenant_id`, `approved_by/at`, `placeholder` (hand-made row: player ∧ approved ∧ not superadmin), `own_color` (0024: the colour the player picked for their own reservations in their own view, −1 = club colour, else a packed RGB — 0042 moved the picker to the Google palette + wheel, both stored as `0x1000000\|rgb`; a legacy palette index 0-11 from the 1.2.6 app still renders), `followed_teams` (≤ 20 names, the Můj přehled list — separate from the calendar's `calendar_teams`), `default_view` (`calendar` | `trainings`, what the app opens at launch); both own-row updatable (0029); `phone` (0048: E.164 `+<digits>`, `profiles_phone_check` = `^\+[1-9][0-9]{7,14}$`, null = none), `show_email` / `show_phone` (0048: default true, for existing rows too — whether `contacts()` hands the e-mail / phone to the alley's players) | select: own row, or admin of the same tenant. update: own row, columns `display_name`, `fcm_token`, `own_color`, `followed_teams`, `default_view`, `notify_before_minutes`, `phone`, `show_email`, `show_phone` only. insert/delete: RPC only. |
| `schedule_settings` | PK `tenant_id`; `lane_count` 1–12, `training_weekdays smallint[]` (ISO 1–7), `booking_horizon_days` 1–90, `max_active_reservations` 1–50, `kiosk_dark`, `kiosk_fit_day`, `duty_reminder_enabled` (0050: the reminder before a canteen duty, default off) and `duty_reminder_days` (0050: its lead, 1–14 days, default 1, `schedule_settings_duty_reminder_days_check`; switching the reminder off keeps it) | select approved/kiosk; update admin — the duty reminder columns too, through the same `settings_update` policy and 0017's table-wide UPDATE grant. `public_week` masks the two duty columns (0050), so the public settings stay what 0043 handed out. |
| `time_blocks` | `starts_at`, `ends_at`, `position`, `active`. `position = -1` marks a day-special block: inactive, reachable only through `day_overrides.block_ids` | select approved/kiosk; insert/update/delete admin. A day-special block is added through `add_special_block` (0050: the admin, or a player with a duty period that has not ended). FK from `reservations` is RESTRICT — only never-used blocks can be deleted. |
| `day_overrides` | PK (`tenant_id`, `date`); `closed`, `reason`, `block_ids uuid[]` (`null` = the default active set) | select approved/kiosk; write admin. Normally written through `set_day_override` and deleted through `delete_day_override` (0050), which a player may call too on the days of their own duty periods, from today on. |
| `priority_slot_types` | `name` unique per tenant, `color` (−1 = none), `lanes smallint[]` (`null` = whole alley), `is_match`, `builtin` ('Zápas', 'Úklid před zápasem' seeded per tenant) | select approved/kiosk; insert/update admin (**column grants: `name, color, lanes` only**); delete admin ∧ `not builtin`. |
| `priority_slots` | `date`, `starts_at`, `ends_at`, `type_id`, `home_team`, `away_team`, `prep_minutes` 0–240, `description`, `parent_id` (the auto-managed úklid child), `is_away` (announced, blocks nothing), `import_key` (unique per tenant; `null` = entered by hand in the app, otherwise `rozpis:<soutěž>:<kolo>:<domácí> – <hosté>` set by the old xlsx importer (retired, see **Výsledkový servis ČKA** below) — date-free, so a postponed match is an update of the same row; rows keyed `xlsx:<date>:<teams>` by the 2026/27 grid workbook were re-keyed by the first run of the flat-list importer), `hand_edited` (0038: an imported row whose match columns changed outside an import run — the sync skips it; see **Výsledkový servis ČKA** below). Federation columns (0045, written only by the sync, never compared by the hand-edit trigger, all public in `public_week`): `video_url`, `competition`, `round`, `site_slug` (the match's page on vysledky.kuzelky.cz), `site_match_id`, `venue` / `venue_slug` (from the match detail — once known, they decide `is_away`), `home_team_slug` / `away_team_slug` (the site's team slugs, `teams.site_slug` for ours — how the sync tells our teams in a stored match, since `home_team`/`away_team` follow an admin's rename only at the next sync). Since 0045 the sync keys its rows `cka:<site_match_id>`. | select approved/kiosk; write admin. |
| `rentals` | `renter_name`, `lanes`, exactly one of `date` / `weekday`, `starts_at`, `ends_at`, `valid_from/until`, `note`, `color` (−2 = default tint). **Grouped dates** (0041): `group_id` — see `rental_groups`. **Exception rows** (0021): `parent_id → rentals` (cascade delete) + `date` = the one occurrence of that weekly series they override, with their own `lanes`, `starts_at`, `ends_at`, `note`; `skipped` = the occurrence does not happen. One per (`parent_id`, `date`). `renter_name`/`color` are copied from the series by `rental_exception_guard`, which also rejects an off-series date, a one-time or child parent and a foreign tenant (`rental_exception_invalid`); `rental_series_changed` prunes children a series edit orphans and re-copies name/colour. | select approved/kiosk; write admin. |
| `rental_groups` | `renter_name`, `color` (−2 = default tint; the same domain as `rentals.color`, hand-picked values included — `rental_groups_color_check`). One renter with several one-time dates (0041): `rentals.group_id → rental_groups` (cascade delete), allowed only on a row with `date` and no `parent_id` (`rentals_group_shape_check`). `rental_group_guard` copies name/colour onto a grouped row and refuses a foreign tenant (`rental_group_invalid`); `rental_group_changed` propagates a group edit; `rental_group_prune` deletes a group with its last date. A lone one-time rental has no group. **Not in the Realtime publication, on purpose**: the app derives groups from the `rentals` rows it already streams (`rentalGroupsOf`), and a rename reaches the client through `rental_group_changed` copying name/colour onto those rows — a second stream would carry nothing the client needs. | select approved/kiosk; write admin. |
| `reservations` | `player_id`, `date`, `block_id`, `lane`, `created_via` app\|kiosk\|admin\|group (0044)\|duty (0050), `cancelled_at/via` app\|one_click\|admin\|group (0044)\|duty (0050), `cancelled_by` (0044: who actually cancelled it — the owner, a fellow group member or (0050) the player on duty, for "Petr ti zrušil trénink"), `cancel_note`, `notify_player`, `notify_message` (per-change intent for the notify function) | **select only** (approved/kiosk). Every write is an RPC, a trigger, or the `cancel` edge function. Live slots are unique: `(date, block_id, lane) where cancelled_at is null`. |
| `clubs` | `name` unique per tenant, `color` (−1 = none), `site_slug` / `site_name` (0047: the venue club on vysledky.kuzelky.cz this club is linked to — its `detail-klubu/<slug>`, unique per tenant when set — and its name there; null = not linked. Only discovery writes them (`apply_federation_discovery`), so a rename or recolour in the app keeps the link) | select approved/kiosk; all admin. |
| `player_groups` | (0044) `tenant_id`, `created_by` | **server-only**: RLS on, zero policies, every grant revoked from `anon`/`authenticated`. Internal bookkeeping only — the app reads `player_group_members`. |
| `player_group_members` | (0044) `group_id → player_groups` (cascade), `user_id → profiles` (cascade), `tenant_id` (denormalised so the admin policy never has to read `player_groups` — no policy cycle), `status` invited\|member, `invited_by`. PK (`group_id`, `user_id`). Partial unique index `player_group_one_membership` on `user_id where status = 'member'` — one group per player. In the Realtime publication. | select: own rows (`user_id = auth.uid()`), the caller's own group (`my_group_id()`), or the alley's admin (`tenant_id = current_tenant_id()`). No insert/update/delete for `authenticated`, nothing for `anon` — written only through the `group_*` RPCs below. |
| `teams` | (0045) The alley's own teams as the federation lists them: `name` (unique per tenant, 1–80 chars — **the string the app keys by**: `priority_slots.home_team`/`away_team`, `followed_teams`, `calendar_teams`, `team_colors`; set at discovery, editable by the admin), `club_id → clubs` (set null), `site_team_id`, `site_slug` (unique per tenant — discovery's identity), `site_name`, `competition_slug`, `competition_name`, `active` (an inactive team's competition is not synced). In the Realtime publication. | select approved/kiosk. No insert/update/delete for `authenticated`, nothing for `anon` — discovery (`upsert_federation_teams`) and `update_team` write it. |
| `federation_sync` | (0045) PK `tenant_id`: `venue_slug` (the alley's kuželna on the site, `''` = not configured, otherwise lower-case letters/digits/hyphens like `tenants.public_slug` but without its 3–40 length bound), `enabled` (default off), `last_run_at`, `last_success_at` (stamped only by `competition:<slug>` runs — the nightly sync's; since 0047 not by `discover`, so `last_run_at` null means never synced, which the setup wizard reads; match and venue jobs never touch them), `last_error` (the error of the newest live `last_report` entry that has one), `last_report jsonb` (`discover` and `competition:<slug>` — the last run's report + `at`, or `{error, at}` when it failed; `match:<site_match_id>` and `venue:<slug>` — `{error, at}` only while that match's or venue's fetch is failing; keys that can no longer run are dropped on every write — see **Runs** below). In the Realtime publication. | select **admin** only. Written by `set_federation_sync` and `record_federation_run`; `update_team`, `upsert_federation_teams` and `set_federation_sync` re-derive `last_error` (`federation_refresh_error`). |
| `match_results` | (0045) PK `match_id → priority_slots` (cascade), `tenant_id`, `status` scheduled \| preparation \| in_progress \| finished \| forfeit, `match_type`, `discipline`, per side `points`, `total`, `fulls`, `spares`, `errors`, `set_points` (`home_*`/`away_*`), `fetched_at`. In the Realtime publication. | select approved/kiosk; server-only writes (`apply_federation_result`). |
| `match_player_results` | (0045) `match_id → priority_slots` (cascade), `tenant_id`, `side` home\|away, `position`, `player_name`, `player_site_id`, `player_slug`, `fulls`, `spares`, `errors`, `total`, `set_points`, `team_points`, `lanes jsonb` (`[{lane, fulls, spares, errors, total, setPoints}]`), (0053) `sub_name`, `sub_site_id`, `sub_slug`, `sub_from_throw` — who took over the starter's line and from which throw (null without a change). Unique (`match_id`, `side`, `position`); index (`tenant_id`, `player_site_id`). Replaced whole on every fetch. In the Realtime publication, replica identity full (the app's stream is filtered by `match_id`, and Realtime checks a DELETE against the identity alone). | as `match_results`. |
| `league_matches` | (0055) The **foreign** matches (neither side is a team of ours) of a competition one of our active teams plays — so Výsledky can show the whole competition by round. Deliberately not `priority_slots` (a slot blocks lanes, feeds the calendar, the public board, the team picker, the calendar/reminder triggers). `tenant_id`, `site_match_id` (unique per tenant), `site_slug`, `competition_slug`, `competition`, `round`, `date`, `starts_at` (null = the site has no time yet), team names + slugs, `video_url`, `venue`/`venue_slug` (display only, never fetched), `status`, `match_type`, `discipline` and the team result columns named as in `match_results`, `fetched_at`, `detail_status`/`detail_fetched_at` (the status the player lines were fetched at). Round page → `apply_league_matches` (totals, no detail); the detail (player lines) is fetched once when the match is finished (`federation_league_match` job, 5 per tick, last) or on `refresh_match`. Index (`tenant_id`, `competition_slug`); replica identity full; in the Realtime publication. Rows of a competition no active team plays are dropped by the nightly `enqueue_federation_jobs`. | select approved/kiosk of the tenant; server-only writes. |
| `league_player_results` | (0055) `match_player_results`, column for column (incl. `sub_*`), for a league match: `match_id → league_matches` (cascade). | as `league_matches`. |
| `venues` | (0045) The alleys (kuželny) the tenant's matches are played at, from their page on vysledky.kuzelky.cz: `slug` (the site's `/detail-kuzelny/<slug>`, unique per tenant — matches `priority_slots.venue_slug` and `federation_sync.venue_slug`), `name`, `address`, `phone`, `email`, `lat`/`lng` (from the page's mapy.cz link), `sections jsonb` (`[{title, items: [{label, value}]}]` — the page's technical/contact blocks as shown), `clubs text[]` (club names at the alley), `fetched_at`. In the Realtime publication. | select approved/kiosk; server-only writes (`upsert_federation_venue`). |
| `duty_periods` | (0050) A canteen duty: `starts_on`, `ends_on` (inclusive; `duty_periods_order_check` ends ≥ starts, `duty_periods_length_check` at most 62 days), `note` (trimmed, ≤ 80 chars, `duty_periods_note_check`; `''` = none), `created_by → profiles` (set null), `created_at`. `duty_periods_no_overlap` — `exclude using gist (tenant_id with =, daterange(starts_on, ends_on, '[]') with &&)`: periods of one alley never overlap, touching is fine (needs `btree_gist`, installed into `extensions`). Index (`tenant_id`, `starts_on`). In the Realtime publication. | select approved/kiosk (the whole alley reads the roster). No insert/update/delete for `authenticated`, nothing for `anon` — written only through the admin's `duty_*` RPCs. |
| `duty_assignments` | (0050) Who works a period: `period_id → duty_periods` (cascade — a deleted period takes its assignees), `user_id → profiles` (cascade), `tenant_id` (the period's, denormalised like `player_group_members`), `assigned_by → profiles` (set null), `created_at`. PK (`period_id`, `user_id`), index (`tenant_id`, `user_id`). Approved non-kiosk members of the alley, placeholders included (counted, never given the duty's rights). A placeholder's rows are history: `delete_placeholder_player` refuses, `merge_placeholder_player` moves them. In the Realtime publication. | as `duty_periods`; written only through `duty_set_assignees`. |
| `duty_seasons` | (0050) Season boundaries for the duty counts: PK (`tenant_id`, `started_on`), `name` (1–40 chars, `duty_seasons_name_check`, e.g. „2026/27“), `created_by → profiles` (set null), `created_at`. A period belongs to the season with the greatest `started_on ≤ starts_on`; the periods before the first boundary are the implicit first season. A reset inserts a row and moves nothing; undo deletes the newest. **Not in the Realtime publication**: the app reads it as a future and invalidates it after a change. | as `duty_periods`; written only through `duty_season_start` / `duty_season_delete`. |
| `messages` | (0051) A notice or a message: `kind` notice \| message, `audience` all \| day \| block \| admins \| duty (`messages_kind_audience_check`: a notice goes to `all`, a message to one of the other four), `author_id → profiles` (set null), `author_role` admin \| player (a snapshot of the sender's `profiles.role` at send time — players cannot read other profiles, so the app and notify label „Od správce“ / „Od služby“ from it), `on_date` + `block_id → time_blocks` (set null) — the day for `day`, day and block for `block` (a block removed later leaves the message on its day), optional context for `admins`/`duty`, none for `all` (`messages_context_check`), `title` (notice only, 1–80 chars), `body` (non-blank, ≤ 500 for a message, ≤ 2000 for a notice), `expires_at` (notice only; null = „do odvolání“), `notify` (a notice's ping choice; always true for a message), `created_at`, `updated_at`. Indexes (`tenant_id`, `kind`, `created_at`), (`tenant_id`, `on_date`). Messages (not notices) over 90 days old are pruned daily (`prune_messages`). In the Realtime publication. | select `tenant_id = (select current_tenant_id()) and id in (select visible_message_ids())` (the alley first, so a player's stream is an index scan of her own alley; the helper's set once per query, not a helper call per row): nothing unless the caller is an approved non-kiosk member of the alley — an account later set as the kiosk or back to pending loses what it once got — then a notice to every such member (recipient row or not), a message to its author and its recipients; exactly what `can_read_message` admits. No insert/update/delete for `authenticated`, nothing for `anon` — written only through `message_send` / `message_update` / `message_delete`. |
| `message_recipients` | (0051) Who got a message, materialised by `message_send`: `message_id → messages` (cascade), `user_id → profiles` (cascade), `tenant_id` (the message's, denormalised like `duty_assignments`), `read_at`, `reaction` up \| down \| null, `reply` (≤ 200 chars), `reacted_at` (the BEFORE UPDATE trigger `message_recipients_reacted_at` stamps it when `reaction` or `reply` changes and clears it when both are null, and answers a reaction or a reply on a notice's row with `not_allowed` — notices have no reactions). PK (`message_id`, `user_id`), index (`tenant_id`, `user_id`, `read_at`). In the Realtime publication, default replica identity: a DELETE event (`message_delete`, the prune's cascade) carries the (`message_id`, `user_id`) key to every subscriber, unchecked by RLS — accepted, like `duty_assignments` / `player_group_members` (§Zprávy a nástěnka → Realtime DELETE events). | select `tenant_id = (select current_tenant_id())` and either the caller's own row (while an approved non-kiosk member) or `message_id in (select visible_recipient_message_ids())`: a notice's rows to the alley's admins („Kdo si to zobrazil“; a player sees her own row of a notice only), a `message`'s rows to its author and its recipients (everyone's reaction, and read time — accepted, no screen shows a message's reads), nothing to a bystander, the kiosk or a pending account. update: own row while an approved non-kiosk member (`message_recipients_update_own`, `user_id = auth.uid() and is_approved() and not is_kiosk()`), columns `read_at`, `reaction`, `reply` only — the `profiles_update_own` pattern. No insert/delete for `authenticated`, nothing for `anon`. |

Every `color` column above is one `integer` (0030): the negative values are the "none"/default markers, 0–8 a palette entry from `domain/palette.dart` (0031 dropped the three that measured under ΔE2000 10 from a neighbour and kept every affected row on its exact colour as a hand-picked one), and `0x1000000 | rgb` (16777216–33554431) a hand-picked colour. Dart derives the four rendered shades (dark and light background plus its text) from a hand-picked value rather than painting it raw, so it stays readable in both themes; `upsert_club` takes `integer` for the same reason.
| `app_config` | single row: `min_build` (0025) — the oldest app build the backend still supports; the app streams it (Realtime) and blocks on an update screen while older. Raised by a migration with a breaking release. | select for `authenticated`; writes: migrations only. |
| `notification_jobs` | Deferred-job queue (0023): `kind` (`calendar_sync`; 0045 adds `federation_discover`, `federation_competition`, `federation_match`, `federation_venue`; 0055 `federation_league_match`), `dedupe_key` unique (`calendar:<user_id>:<reservation_id>` — a repeat re-arms `run_at` instead of adding a row), `payload` jsonb, `run_at`, `attempts` (the handler backs off 2^attempts minutes and drops the job at 5), `created_at`. Index on `run_at`. | **server-only**: RLS on, no policy; `service_role` all, `anon`/`authenticated` nothing. Written by the security-definer producers (§Google kalendář) and `backfill_calendar_jobs`, consumed by the notify function on the cron tick. |
| `google_calendar_links` | One row per *person* (not per tenant; `user_id → profiles`, cascade): `status` pending \| linked \| broken \| unlinked, `google_email`, `last_error`, `reminder_minutes int[]` (Calendar API shape — ≤ 5 entries, each 0–40320, CHECK-enforced, stored sorted descending), `created_at`, `updated_at`, plus (0032) `secondary_enabled` (the player turned on the second Google calendar "Rezervátor 2"), `reminder_minutes_secondary` (same shape/bounds, for events written there), `training_color_id` (Google event `colorId` 1–11 for trainings, which always go to the primary calendar; `null` = no colour). `match_teams` (0027) is gone (0033) — see `calendar_teams` for what replaced it. Holds no secret: it is in the Realtime publication and the profile card streams it. | select own row only (`user_id = auth.uid()`); `authenticated` has SELECT and nothing else — every write is the server's (`service_role`). |
| `google_calendar_tokens` | `user_id → profiles` (cascade), `refresh_token`, `google_calendar_id` (the app-created "Rezervátor" calendar), `google_calendar_id_secondary` (0032: the second one, "Rezervátor 2"; `null` until `secondary_enabled`), `updated_at`. A separate table on purpose: a streamed table must never carry the token. | **server-only**: RLS on, zero policies; `service_role` only. |
| `calendar_teams` | (0032) One row per player **+** followed team — replaces `google_calendar_links.match_teams`, because a team now needs to say more than its name: `user_id → profiles` (cascade), `team` (a `priority_slots.home_team`/`away_team` string), `calendar` (`primary` \| `secondary`, default `primary` — which of the player's two Google calendars this team's matches go to). PK (`user_id`, `team`). In the Realtime publication (0035) — the profile card streams it. Colour (`color_id`) lived here until 0036 moved it to `team_colors` below, independent of this table. | select own rows only (`user_id = auth.uid()`); `authenticated` has SELECT and nothing else (0035) — every write is the server's, through `calendar-manage`/`set_calendar_teams_for`, which also keeps `google_calendar_links.match_teams` mirrored for the 1.2.1 app. |
| `team_colors` | (0036) One row per player **+** team the player has coloured — `user_id → profiles` (cascade), `team`, `color_id` (Google event `colorId` 1–11, `not null` — no row at all means no colour). PK (`user_id`, `team`). Independent of **both** team lists (`profiles.followed_teams` and `calendar_teams`) and of whether a calendar is even linked: the one colour shown for a team in Můj přehled and in its Google Calendar event alike. In the Realtime publication. | select own rows only (`user_id = auth.uid()`); `authenticated` has SELECT and nothing else (0037) — every write is the server's, through `calendar-manage`/`set_team_colors_for`, which saves a colour and immediately repaints the affected future Google Calendar events in the same request. |
| `match_exceptions` | (0039) One row per player **+** match where the player disagrees with their teams — `user_id → profiles` (cascade), `match_id → priority_slots` (cascade), `shown` (`true` adds a match no team gives them, `false` hides one a team does), `calendar` (`primary` \| `secondary`, default `primary`; only ever consulted for an added match, and the app offers no choice — the column is there for the day it does). PK (`user_id`, `match_id`). Agreeing with the teams stores nothing: the row is deleted instead, so "back to what the team says" is the absence of a row rather than a third state. In the Realtime publication. | select own rows only (`user_id = auth.uid()`); `authenticated` has SELECT and nothing else — the one way in is `set_match_exception`, callable by the app. |
| `reminders_sent` | (0040) The receipt for a reminder already delivered — `user_id → profiles` (cascade), `event_key` (`r:<uuid>` for a reservation, `m:<uuid>` for a match, `d:<uuid>` for a canteen duty period (0050) — one column instead of nullable foreign keys and a CHECK to police them), `offset_minutes`, `sent_at`, `starts_at` (0049: the start the reminder announced; null = no known start, counts for any). PK the first three. A receipt covers the event's longer lead times for the same start, and a moved event rings again at its new time (0049). Nothing schedules reminders; `due_reminders()` asks every minute what is due *now* from the data as it stands, and this table is the only state that carries over, so a repeated tick or a retried send does not ring twice. No foreign key to the event and therefore no cascade: the tick prunes anything older than 30 days. | **server-only**: RLS on, zero policies, every grant revoked. |
| `oauth_nonces` | The OAuth `state`: `nonce` (48 hex chars from `gen_random_bytes(24)`), `user_id → profiles` (cascade), `created_at`, `consumed_at`. One-shot with a 10-minute TTL — the callback function runs without a JWT, so this is what binds Google's redirect to a signed-in player. | **server-only** like the tokens. |

View `players` (owned by postgres → bypasses `profiles` RLS on purpose):
approved, non-kiosk members of the caller's tenant minus visiting
superadmins — `id, display_name, nick, club_id, club_color, placeholder`
(0022 appended `placeholder` with `create or replace`, which keeps the
ACL). This is the only profile data the kiosk account can read. SELECT for
`authenticated` only.

`contacts()` (0048) is the one other way to another player's profile: the
players' own switches decide whether their e-mail and phone leave the
database at all (see RPCs).

## Privileges (0017, 0046)

`authenticated` has select/insert/update/delete on the app tables (policies
decide rows), the column-restricted exceptions above, SELECT on `players`
and `tenants(id, name, status)`. `anon` has nothing (the one exception:
`execute` on `public_week`, 0043). `service_role`
(edge functions) has everything. The 0023 calendar tables are server-only:
`notification_jobs`, `google_calendar_tokens` and `oauth_nonces` revoke
everything from `anon`/`authenticated` (RLS on, no policy),
`google_calendar_links` keeps SELECT only. Internal helper functions have
EXECUTE revoked from the app roles (see below).

**Since 0046 nothing is granted by default** — the same behaviour Supabase
enforces on every project from 2026-10-30. A migration that creates a table
grants it itself, next to the `create table`:
`grant select, insert, update, delete on <t> to authenticated` (or less),
`grant all on <t> to service_role`, nothing for `anon`. A `drop … create`
of a view comes back with no grants and must re-grant. A serial /
standalone sequence needs `grant usage` for a role that inserts; an
identity column does not. `tenancy_rls.sql` fails when a default grant
reappears, when `service_role` lacks DML on any table or view, or when
`anon` holds anything. (0017/0020 had pinned defaults instead; 0035 and
0037 show why a default grant was never the safe side anyway.)

## RPCs

| Function | Who | Effect / raises |
|---|---|---|
| `register_profile(display_name, tenant_id, club_id?, nick?, phone?)` | signed-in user without a profile | First approved member of a tenant (or the `founder_email` match) becomes approved admin, everyone else pending; placeholders never count as the first member. `phone` (0048) is stored as given when E.164, blank = none — the app normalises it first (`lib/domain/phone.dart`). 0048 dropped the four-argument signature: a call without `p_phone` (the 1.2.x app) resolves to this one through the default. `empty_display_name`, `nick_too_long`, `invalid_phone`, `unknown_tenant`, `unknown_club`. |
| `create_tenant_and_register(tenant_name, display_name, nick?, phone?)` | signed-in user | Creates a pending tenant with the caller as founder, then registers through `register_profile`, the founder's `phone` (0048) included, all in one transaction: an `invalid_phone` founds no tenant. 0048 dropped the three-argument signature; a call without `p_phone` resolves through the default. `empty_tenant_name`, `tenant_exists`, `invalid_phone`. |
| `registration_clubs(tenant_id)` | signed-in, pre-profile | Club list for the register screen. |
| `approve_player(user_id)`, `set_role(user_id, role)`, `set_player_club(user_id, club_id)`, `upsert_club(...)`, `delete_club(id)` | admin | Member and club administration. `cannot_demote_self`, `placeholder_no_account` (a hand-made profile stays a player), `unknown_club`. |
| `kiosk_password_target(user_id)` (0028) | admin | The gate behind the `kiosk-password` edge function: returns the id of a kiosk of the caller's OWN alley, so the function sets a password only where the caller may. Called with the CALLER's JWT (the function then uses the service role). `not_allowed`, `unknown_kiosk`. |
| `save_placeholder_player(id?, display_name, nick, club_id)`, `delete_placeholder_player(id)`, `merge_placeholder_player(placeholder_id, target_id, display_name, nick, club_id)` | admin | Players without an account. Save: `id = null` inserts an approved placeholder of the caller's tenant, otherwise edits one (`unknown_player`); `empty_display_name`, `nick_too_long`, `unknown_club`. Delete: `player_has_history` when any reservation or (0050) canteen duty references it. Merge: the source must be a placeholder, the target any non-placeholder non-kiosk profile of the tenant (`invalid_merge`); repoints the reservations and (0050) the duty assignments — a period the target is on already keeps the target's row once — writes the chosen fields, approves a pending target, deletes the source. |
| `set_nick(user_id, nick)` | self or admin | `nick_too_long`. |
| `contacts()` (0048) | approved member, not the kiosk (a visiting superadmin counts, for the alley they are in) | Klubovna → Kontakty: the caller's alley's registered players — approved, not the kiosk, not a placeholder, not a visiting superadmin (the `players` view's rule) — as `(id, display_name, nick, club_id, club_name, club_color, email, phone)`, ordered by `display_name` (the app re-sorts Czech). `email` is null unless `show_email` (and for an empty one), `phone` null unless `show_phone`: a hidden one never leaves the database. Admin screens keep reading `profiles` as before; the switches do not apply there. `not_allowed`; anon has no EXECUTE. |
| `create_reservation(player_id, date, block_id, lane)` | player for self, kiosk for any approved member, admin for anyone, **member of the same group for a fellow member (0044)**, **the player on duty for another member of the alley (0050)** | Admin skips past/horizon/limit. A group booking follows the target player's own rules and the target's own cap (`same_group` from `same_group(caller, player_id)`), not the caller's; so does a duty booking (0050, `created_via = 'duty'`, `is_on_duty()`). Branch order admin → kiosk → self → group → duty: the duty booking a group mate books as `group`, their own booking stays `app`. Raises `player_not_approved`, `unknown_block`, `invalid_lane`, `day_closed` / `invalid_block` (via `block_day_status`), `date_past` (also a block that has started today), `beyond_horizon`, `limit_reached` (own cap) / `member_at_limit` (0044: a group booking against the target's cap — the same limit, an honest message) / `player_at_limit` (0050: the same for a duty booking), `blocked_by_priority`, `blocked_by_rental` (via `rental_occurrences`), `slot_taken`. |
| `cancel_reservation(id, note?, notify?)` | owner before the block starts, admin anytime, **member of the same group before the block starts (0044)**, **the player on duty for another member's training of the alley before the block starts (0050)** | `too_late`, `not_allowed`; sets `cancelled_via` app / admin / group (0044) / duty (0050) and `cancelled_by` to the caller; the note (trimmed) and `notify_player` (null = true) are the caller's. Branch order admin → owner/group → duty. |
| `group_invite(user)` (0044) | approved player, not kiosk | Invites `user` (an approved, non-kiosk, non-placeholder account of the same alley, not the caller) into the caller's group, founding one if the caller has none. `not_allowed`, `unknown_player`, `already_member`, `already_invited`. |
| `group_accept(group)`, `group_decline(group)` (0044) | the invited player | Accept joins (one group per player — `already_in_group` if already in one); decline removes the invite. Both: `not_authenticated`, `unknown_invite`. |
| `group_leave()` (0044) | any member | Leaves the caller's group; the group (and its pending invites) is deleted once its last member leaves. No-op outside a group. |
| `group_cancel_invite(group, user)` (0044) | a member of `group` | Withdraws a pending invite. `not_allowed` (not the caller's group), `unknown_invite`. |
| `group_remove_member(user)` (0044) | admin | Removes `user` from their group (of the caller's own tenant), pruning the group with its last member. `not_allowed` (foreign player or not admin). |
| `duty_generate(from, days smallint, until)` (0050) | admin | Správa → Služby → „Vygenerovat…“: periods `[s, least(s + days − 1, until)]` for `s` = `from`, `from + days`, … up to `until` — the last one clipped; a period overlapping an existing one is skipped whole (a second run over the same range creates nothing; a concurrent insert counts as skipped too). Returns `{"created": n, "skipped": m}`. `not_allowed`, `invalid_days` (not 1–31), `invalid_range` (`until` before `from`, or more than 400 days with both ends counted). The app's preview (`planDutyPeriods`) mirrors it. |
| `duty_period_save(id?, starts_on, ends_on, note)` (0050) | admin | `id = null` inserts a period of the caller's alley, otherwise edits that one; the note is trimmed. Returns the id. `not_allowed`, `invalid_range` (a date missing or the end before the start), `duty_too_long` (more than 62 days), `duty_overlap` (the `duty_periods_no_overlap` exclusion violation, re-raised), `unknown_period` (unknown or another alley's); a note over 80 chars trips `duty_periods_note_check`. |
| `duty_period_delete(id)` (0050) | admin | Deletes the period with its assignees. `not_allowed`, `unknown_period`. |
| `duty_periods_delete_unassigned(from)` (0050) | admin | „Smazat neobsazené budoucí…“: deletes the alley's periods starting on `from` or later that nobody is assigned to; returns how many. `not_allowed`, `invalid_range` (no date). |
| `duty_set_assignees(period, users uuid[])` (0050) | admin | Replaces the period's assignees with `users` (duplicates collapse, `{}` clears; rows that stay are kept, not re-inserted). Each must be an approved non-kiosk member of the alley that is not a visiting superadmin — the `players` view's rule, placeholders allowed — or nothing changes: `unknown_player` (a null too). The period row is locked, so two admins saving it at once end with one set. `not_allowed`, `unknown_period`. |
| `duty_season_start(started_on, name)` (0050) | admin | „Nová sezóna…“: inserts a boundary; nothing else moves. The name is trimmed — `empty_name` when blank, `duty_seasons_name_check` past 40 chars. `season_order` unless it starts after the newest boundary (serialised per alley by an advisory lock). `not_allowed`. |
| `duty_season_delete(started_on)` (0050) | admin | „Vrátit poslední sezónu“: deletes that boundary, which must be the newest (`not_newest` otherwise, and when there is none). `not_allowed`. |
| `move_reservation(...)` | admin; the player on duty from today on (0050, `duty_gate`: on duty today, any future day); a player on the days of their own duty periods, on duty today or not (`duty_edit_gate`) | Re-seat one reservation; same collision rules as create (rentals resolved by `rental_occurrences`). It serves both rights: it is how the players of a block the duty removes for a day get new seats (the day dialog's per-player moves), and it is a reservation-level re-seat while on duty. A caller who is not on duty today needs a period that has not ended before a word about the reservation is said (`not_allowed`), then the reservation's day must be one of their own periods (`duty_edit_gate`); one on duty today is held to `duty_gate` (any day from today on). A move keeps the date, so source and target are one. On today the duty moves nothing out of or into a block that has started (`too_late`); the admin may. `not_allowed`, `date_past`, `too_late`, `slot_taken`, `blocked_by_*`. |
| `move_day_reservations(...)` | admin; a player on the days of their own duty periods, from today on (0050, `duty_edit_gate`) | Re-seat all reservations of a day's block into another block; same collision rules. On today the duty moves nothing out of or into a block that has started (`too_late`); the admin may. `not_allowed`, `date_past`, `unknown_block`, `too_late`, `slot_taken`. |
| `cancel_block_day_reservations(date, block, note?)` | admin; a player on the days of their own duty periods, from today on (0050, `duty_edit_gate`) | Bulk cancel before hiding a template block for one day. The duty's call spares the trainings of a block that has started today (like `cancel_stranded_reservations`); the admin's cancels them too. `not_allowed`, `date_past`, `unknown_block`. |
| `set_day_override(date, closed, reason?, block_ids?)` | admin; a player on the days of their own duty periods, from today on (0050, `duty_edit_gate`) | Upsert the override and cancel the reservations it displaces — the duty's call not those whose block has started today (like `cancel_stranded_reservations`), the admin's all of them. `not_allowed`, `date_past`. |
| `add_special_block(starts_at, ends_at)` (0050) | admin; a player with a duty period that has not ended (`duty_edit_days_gate()`: no date here — the `set_day_override` that points a day at the block names it and holds them to their own periods; `duty_edit_gate(date)` refuses a null date with `date_past`, the admin's too) | Inserts an inactive day-only block of the caller's alley (`position -1` — the SPECIAL sentinel the Rozvrh list hides — `active false`, so the weekly template ignores it) that a day override then points at; returns its id. Behind `Api.addSpecialBlock` instead of a direct insert, so the duty needs no wider `time_blocks` policy. `not_allowed` (no duty period left, and not an admin); `time_blocks_check` when the end is not after the start. |
| `delete_day_override(date)` (0050) | admin; a player on the days of their own duty periods, from today on (`duty_edit_gate`) | Deletes the day's override: the day returns to the weekly template (`override_changed` cancels what no longer fits). No override is no error. Behind `Api.deleteDayOverride` instead of a direct delete. `not_allowed`, `date_past`. |
| `rental_add_date(rental, date, starts_at, ends_at, lanes, note)` | admin | Adds a one-time date next to `rental` (a one-time row of the caller's tenant): creates its `rental_groups` row from the rental's name/colour and adopts it when it has none, then inserts the date with its own lanes/times/note. The source row is read `for update`, so two admins adding a date to the same groupless rental at once cannot each create a group and split it in half. Returns the new row id. Raises `not_authenticated`, `not_allowed`, `unknown_rental` (foreign, exception or weekly row). |
| `monthly_attendance(year, month)` | admin | Rows (player, club name, attended) — uncancelled reservation = attendance. |
| `admin_list_tenants()`, `approve_tenant(id)`, `reject_tenant(id)`, `switch_tenant(id)` | superadmin (`not_allowed` otherwise) | `reject_tenant`: pending only (`not_pending`), refuses while the caller is switched into it (`switch_home_first`), deletes the whole tenant. |
| `start_calendar_link()` | approved member, not the kiosk (`not_allowed`) | Issues the OAuth `state` nonce (48 hex) and returns it; the caller's earlier unconsumed nonce is replaced. The app opens Google's consent URL with it. |
| `consume_calendar_nonce(nonce)` | service_role only (calendar-oauth-callback) | One shot: returns the bound `user_id` for an unconsumed nonce younger than 10 minutes and stamps `consumed_at`; null otherwise. |
| `backfill_calendar_jobs(user)` | service_role only (callback, right after `status = 'linked'`) | One `calendar_sync` job per live reservation of the player from Prague-today on, due now (a pending job is re-armed); returns the count. |
| `set_calendar_reminders_for(user, minutes int[], calendar text default 'primary')` | service_role only (calendar-manage) | Normalises (distinct, sorted descending, nulls dropped), stores on `reminder_minutes` or (0032) `reminder_minutes_secondary` and returns the stored array. `bad_calendar` (not `primary`/`secondary`), `bad_reminders` (more than 5, or any outside 0–40320), `unknown_link` (no links row). |
| `my_future_reservations(user)` | service_role only (callback, calendar-manage) | `(reservation_id, date, starts_at, ends_at, lane, alley_name)` for the player's live reservations from Prague-today on — block times, tenant name — ordered by date, starts_at. The raw material of the calendar events. |
| `public_week(slug, monday)` (0043) | **anon** i signed-in | Veřejný přehled: týden (`monday` se zarovná na pondělí) publikované a schválené kuželny — `tenant_name`, `settings`, `blocks`, `slot_types`, `overrides`/`priority_slots`/`rentals` za neděli před … pondělí po, `occupied` (`block_id, date, lane, club_color`) za týden. Žádná jména, `player_id`, `renter_name`, `note`, `created_by`; od 0050 ani `duty_reminder_enabled` / `duty_reminder_days` ze `settings`. Služby na kantýně (0050) se sem nedostanou vůbec. `unknown_tenant` pro neznámý, vypnutý i neschválený slug (stejně). |
| `set_public_overview(slug, enabled)`, `my_public_overview()` (0043) | admin | Slug (trim + lower, `''` = žádný) a přepínač vlastní kuželny; čtení vrací `{public_slug, public_enabled, tenant_name}`. `not_allowed`, `invalid_slug` (formát / zapnutí bez slugu), `slug_taken`. |
| `set_federation_sync(venue_slug, enabled)` (0045) | admin | Upserts the caller's `federation_sync` (slug trimmed + lower-cased, must be non-empty) and drops the old kuželna's `venue:` key when no match of the alley is there either, re-deriving `last_error`. Since 0047 a changed slug also drops `last_report.discover` and the `federation_discover:<tenant>` job, both the old kuželna's: the setup wizard never offers step 3 for its teams, and a failed discovery backing off to retry no longer counts in `federation_sync_progress` (the card's loader) nor runs for the new kuželna unasked. `not_allowed`, `invalid_venue_slug`. |
| `request_federation_discovery()`, `request_federation_sync()` (0045) | admin | Enqueue a `federation_discover` job / one `federation_competition` job per active team's competition, due now, and kick the dispatcher. `not_allowed`; `federation_not_configured` (no venue slug) / `federation_disabled` (sync off or no slug). |
| `federation_sync_progress()` (0047) | admin | The caller's federation jobs due now (`run_at <= now()`) or leased (`attempts > 0` and `run_at` within the notify tick's 10-minute lease), per kind → `{discover, competitions, matches, venues}`; a match's future checkpoint never counts. The ČKA card polls it. `not_allowed`. |
| `update_team(id, name, club_id, active)` (0045) | admin | Renames (trimmed), assigns a club of the same alley, switches the team on/off; a team switched off takes its competition's and matches' errors off the admin card at once (the keys die — see **Runs** below). `not_allowed` (foreign team, not admin), `unknown_club` (not a club of this alley, e.g. deleted meanwhile), `empty_name`, `team_name_taken`. |
| `refresh_match(match_id, force default false)` (0045, 0054) | approved member or kiosk | On-demand refresh of a live match → `queued` (a `federation_match` job due now, at most one request per 5 minutes — see below), `fresh` (fetched < 5 min ago) or `not_live` (not a federation match, foreign, played only by switched-off teams of ours — `federation_match_switched_off`, whose job would stop unwritten and leave no gate — or outside the window: `in_progress` until start + 12 h, `preparation` from start − 1 h to start + 12 h — the site shows it days before some matches — and `scheduled` from start − 1 h to start + 6 h; the same windows as the job's checkpoints and the app's `isLive`). With `force` (the refresh button, 0054) the 5-minute gate shrinks to a 15-second floor against a double tap; the background pokes keep 5 minutes. `not_allowed`. |
| `apply_federation_matches(tenant, competition_slug, matches, keep_ids)`, `apply_federation_result(tenant, site_match_id, result)`, `apply_league_matches(tenant, competition_slug, matches)`, `apply_league_result(tenant, site_match_id, result)`, `league_competition_is_ours(tenant, competition_slug)` (0055), `upsert_federation_teams(tenant, teams)`, `record_federation_run(tenant, key, report, error)`, `enqueue_federation_match(tenant, site_match_id, slug, run_at)`, `upsert_federation_venue(tenant, venue)`, `federation_last_error(tenant, report)` (0045), `apply_federation_discovery(tenant, clubs, teams)` (0047) | service_role only (notify function) | The sync's writes — see **Výsledkový servis ČKA** below. `apply_federation_matches` raises `federation_tenant_not_ready` when the tenant has no approved admin or no builtin match type. |

Internal, no EXECUTE for app roles: `current_tenant_id`, `is_*`,
`block_day_status`, `cancel_stranded_reservations`, `rental_occurs`,
`rental_occurrences`, `cancel_res_for_priority_slot`,
`enqueue_notification`, `enqueue_calendar_sync`,
`trigger_notification_jobs` (called by cron), `notify_webhook_config`,
`seed_demo_member` (service_role only — Play-review demo account),
`public_tenant_id`, `same_group`, `_group_drop_member` (0044),
`federation_description`, `enqueue_federation_jobs` (called by cron),
`enqueue_federation_venue`, `federation_live_report`,
`federation_refresh_error` (0045), `is_on_duty`, `duty_gate`,
`duty_edit_gate`, `duty_edit_days_gate` (0050),
`message_recipients_stamp_reacted` (0051, the `reacted_at` trigger's),
`prune_messages` (0051, service_role only — called by cron).
(`is_admin()` is the exception to `is_*`: policies call it, so it stays
PUBLIC-executable. 0051's policy helpers `can_read_message`,
`visible_message_ids` and `visible_recipient_message_ids` are not
internal either: `authenticated` executes them, `anon` does not —
§Zprávy a nástěnka.)

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

**The player on duty (0050).** Two rights, two clocks, and nothing else —
only through RPCs:
- **Reservations of others — WHILE on duty** (`is_on_duty()`: a period
  covering Prague today; `not_allowed` otherwise), from today on, the other
  duties' days included. `create_reservation` / `cancel_reservation`: the
  duty branch (via `'duty'`), with the booked player's rules — their cap
  (`player_at_limit`), the horizon, no past day, no started block
  (`date_past`, `too_late`). Only the admin goes past them.
  `duty_gate(date)` is this right's gate: the admin passes on any date;
  anyone else needs `is_on_duty()` (`not_allowed`) and a date of Prague
  today or later (`date_past`). A player whose only period lies ahead books
  and cancels for nobody until it starts. Re-seating one reservation
  (`move_reservation`) follows either right, see below.
- **Blocks of a day — on the days of their OWN periods**, never in the past,
  on duty today or not: `set_day_override`, `cancel_block_day_reservations`,
  `move_day_reservations`, `delete_day_override` and `add_special_block`,
  gated by `duty_edit_gate(date)`. The admin passes on any date. Anyone else
  needs a period of their own (`duty_assignments`, an approved non-placeholder
  `player` of the alley — `is_on_duty()`'s account conditions without its
  „covers today“) that covers the date, else `not_allowed` — someone else's
  period, a day nobody serves and a duty that has ended are alike — and then a
  date of Prague today or later, else `date_past` (asked second, so a day
  outside the periods is never „past“). A duty starting next Monday to
  Wednesday edits those three days already today, and Thursday, today or
  another duty's days not at all; two consecutive periods of one player are
  both theirs. `add_special_block` has no date: its gate asks for a period
  of their own that has not ended (`ends_on` ≥ Prague today), and the
  `set_day_override` that points a day at the block names the real date.
  `move_reservation`, the per-player step of removing a block for a day
  (the day dialog's re-seating of its sign-ups), passes the same way: for a
  player on duty today `duty_gate(date)`, otherwise `duty_edit_gate(date)`
  — so a duty next week re-seats the players of next week's blocks now.
  A block that has started today is the duty's limit too: the moves refuse
  to take a training out of it or into it (`too_late`), and closing the day
  or cancelling a block spares its trainings, as the override cascade does —
  they are played, and `monthly_attendance` counts them. The admin's calls do
  all of it.
- Still the admin's alone, because no policy got wider: the weekly
  template (`time_blocks` writes), `priority_slots`, rentals, slot types,
  clubs, settings, profiles, attendance and every other admin RPC. A direct
  INSERT is refused (42501); an UPDATE or DELETE finds no row.

**`public_week` skládá týden znovu, na serveri (0043).** Anon nemá na
tabulky žádný grant a jména se musí maskovat na serveru, takže veřejný
přehled nečte streamy appky. Nový vstup do `buildWeekSchedule` (nový
parametr = nová tabulka ovlivňující sloty) proto znamená doplnit ho i do
`public_week` a do `PublicWeek.fromJson` — klientskou stranu vynutí
kompilátor (parametry jsou povinné), SQL stranu ne.

## Cascades — what cancels reservations

Every cascade sets `cancelled_via = 'admin'`, `notify_player = true`, and
the notify function mails "Trénink zrušen" with the note as the reason
(past dates stay silent). That holds when the player on duty closes or
edits a day, too (0050): only `cancel_reservation` marks a cancel `'duty'`.
The duty's `set_day_override` / `cancel_block_day_reservations` spare what
has started today, like the triggers; the admin's cancel it as well.

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
`prep_minutes`), `priority_slots_hand_edit` (0038, before update: flags an
imported match whose match columns change while `import.run` is not `on`;
the 0045 federation columns are not compared), `rental_exception_guard` (before insert/update of a rental
exception: validation + name/colour copy), `rental_series_changed` (after
update of a weekly rental: prune orphaned exceptions, propagate name/colour), `notify_profiles` / `notify_reservations` /
`notify_tenants` (`notify_webhook` → the notify function),
`reservations_enqueue_calendar` / `time_blocks_enqueue_calendar` (the
calendar job producers, next section), `fcm_token_claim` (0052, after a
profile writes a non-null `fcm_token`: clears that token from every other
profile, in any alley — a device pushes for one account only, whichever
app version saved it; the app also clears its own token on sign-out, only
while it is still this device's).

## Výsledkový servis ČKA (0045)

The federation's results site (vysledky.kuzelky.cz) is the importer now:
the notify edge function scrapes it and writes through security-definer
functions callable by `service_role` only (they cannot `set role`, so they
write `tenant_id` and `created_by` — the tenant's first approved admin,
never a visiting superadmin — explicitly; `priority_conflicts`,
`match_uklid_sync` and the calendar producers take the tenant from the row
and run exactly as for a match saved in the app). The app only reads the
tables and calls the RPCs above. The old xlsx importer (0038) is
superseded and retired.

- **Discovery** (`federation_discover` job, `request_federation_discovery`):
  the venue's clubs and their teams → `apply_federation_discovery` (0047),
  one transaction. Every venue club (`detail-klubu/<slug>` on the venue
  page) becomes a club of ours: the one linked to its slug
  (`clubs.site_slug`, whatever the admin renamed it to; `site_name`
  follows the site), else the unlinked club the edge function matched by
  name (it gets linked), else a new one — the site's name cut to 80, in
  the first palette colour no club of the alley uses, else the least used
  one. A name another club already has creates nothing. A deleted club
  that still plays at the venue is created again. Then
  `upsert_federation_teams`: a new team arrives active under the site's
  name, cut to 80 chars (a clash with an existing name gets
  ` (<competition>)` appended; if that is taken too,
  `<site_name> (<site_slug>)`), with its venue club's club; an existing
  one (same `site_slug`) keeps the admin's name, club and switch — only
  the site's facts are refreshed, and one without a club gets its venue
  club's. A team rolled over to the next season's competition leaves the
  past season's `competition:` and `match:` keys dead, so their errors
  leave `last_error` at once. Its report (`last_report.discover`):
  `{teams, competitions, created, teams_created, clubs_created,
  clubs_linked, at}` — `teams_created` (0047) names the teams this run
  created, as the alley has them (a clash's suffixed name), sorted by name:
  the discovered `site_slug`s no team of the alley had before
  `upsert_federation_teams` ran. A report written before it has no
  `teams_created`, which the app reads as none named.
- **Schedule** (`federation_competition` job per active team's
  competition): `apply_federation_matches` in one transaction with
  `set_config('import.run', 'on', true)`, so the 0038 hand-edit trigger
  stays quiet.
  - **Identity** is `import_key = cka:<site_match_id>` — a postponed match
    is an UPDATE of its row (same uuid, same Google Calendar event).
  - **Rekeying:** a match carrying `legacy_id` (a `rozpis:` row of the old
    importer, paired by the edge function) takes over that row in place —
    its `import_key` becomes `cka:<id>`, uuid and `match_exceptions` stay.
    The edge function pairs in five passes, each only on a unique hit:
    first date + the teams the other way round (home rights swapped — the
    leg takes its own date's row, not the other leg's; only when that
    pair is unique both ways and neither side has the straight match that
    day); the `rozpis:` key's round + teams up to 183 days apart (a
    postponed match, never next season's same round); date + teams; date +
    start time + one team in common (a renamed opponent — here the legacy
    row must also have just one candidate); last, for the rows still
    unpaired, the same home and the same away up to 60 days apart (a match
    moved before the site listed it) — only when exactly one such pair
    exists each way within that reach. A `rozpis:` row the site never
    lists stays free for every later sync; both bounds keep it off next
    season's match of the same two teams. Team names compare without
    case, accents and a trailing ` A`, and a word may stand for a run of
    the other name's words by their initials (`KK MS Brno B` =
    `KK Moravská Slavia Brno B`, `Kamenice n.L.` = `Kamenice nad Lipou`);
    the team letter and digits must match exactly.
  - **Update in place, only on a difference.** `video_url`, `competition`,
    `round`, `site_slug`, `site_match_id`, `home_team_slug`,
    `away_team_slug` are always rewritten and never count as `updated`; the match columns (date, times, teams,
    `prep_minutes`, `description`, `is_away`) only when not `hand_edited` —
    a hand-edited row is listed in the report's `skipped_hand_edited`
    instead. Home/away: an insert takes the guess `home_is_ours`; a stored
    row keeps its `is_away` until a match detail told us the venue (then
    the venue decides), so a legacy row the old import had right is never
    flipped by the guess. Each competition run therefore queues an
    immediate `federation_match` for every listed stored match without a
    `venue_slug` — and for every one whose `match:<id>` entry in
    `last_report` holds an error: its job may have given up (5 failures,
    or dropped after the runtime killed it) and a finished match has no
    checkpoint left, so the nightly pass and „Synchronizovat teď“ are its
    daily retry, and the fetch that works clears the error.
  - **Calendar:** 0045 redefines `priority_slots_enqueue_calendar` so an
    UPDATE enqueues calendar jobs only when a column the event shows or
    its followers depend on changed (`tenant_id`, `date`, `starts_at`,
    `ends_at`, `home_team`, `away_team`, `is_away`, `description`,
    `type_id`, `parent_id`). The sync-only columns and `import_key` do not
    — the calendar handler deletes events of past matches it no longer
    lists, so a T+24 h video link or the first run's rekey would otherwise
    wipe played matches from followers' calendars. For the same reason an
    UPDATE of a match dated before Prague today both before and after
    (the first run rewriting an old away row's description or times)
    enqueues nothing; INSERT and DELETE are unchanged.
  - **Delete only the future:** a `cka:` match of this competition that
    has not started yet (`date + starts_at` after Prague now), that the
    site no longer lists and that is not hand-edited, is deleted together
    with its `federation_match` job; a match already under way or played
    never is. `keep_ids` are matches of ours the site still lists but the
    edge function did not write (no start time yet, or none of our teams
    in it is active) — they are never "dropped". An empty list is a
    failed fetch and deletes nothing.
  - Report: `{inserted, updated, rekeyed, deleted, skipped_hand_edited[]}`;
    the edge function adds `skipped_no_time[]`, `match_jobs` and
    `legacy_unpaired[]` — up to 20 `{date, title}` of `rozpis:` rows still
    unpaired after the apply that fall within the competition's dates and
    involve one of its teams (by name). On the first run these are the
    rows to check by hand: a match that stays `rozpis:` next to a new
    `cka:` row is a duplicate.
  - **Deactivating a team** (`update_team(…, active := false)`) stops
    syncing it: its matches are no longer written, and the ones already
    stored stay as they are. When the competition is still synced for
    another active team of the alley, the inactive team's listed matches
    go as `keep_ids`, so they are never "no longer listed", and the run
    arms no `federation_match` job for a match with no active team of
    ours in it; a job armed before the switch (or queued by
    `refresh_match`) stops at its next run without writing — see **Match
    detail**; when no active team is left in the competition, the
    competition is not synced at all. The switch also clears that
    competition's and those matches' errors from `last_error` at once.
- **Match detail** (`federation_match` job): `apply_federation_result`
  upserts `match_results`, replaces `match_player_results`, writes
  `video_url` and, when the detail names the venue, `venue`/`venue_slug`
  and — unless hand-edited — `is_away` (venue ≠ `federation_sync.venue_slug`),
  `prep_minutes` (0 away) and the description (`<soutěž> · <n>. kolo`, plus
  ` · <kuželna>` away). It answers `false` (and writes nothing) when the
  tenant has no slot for the match any more — withdrawn, or deleted by
  hand — and the job then stops instead of re-arming. The job also stops,
  without calling it, when the fetched page shows neither side is an
  active team of ours (`teams.site_slug`): a job armed before the admin
  switched the team off polls no further. `refresh_match` queues no job
  for such a match at all — nothing would stamp `fetched_at`, so every
  request would fetch again.
  After each fetch the job re-arms itself by the match's status:
  `scheduled` at start − 24 h, then start − 1 h, then every 15 minutes
  until start + 6 h; `in_progress` every 15 minutes until start + 12 h;
  `preparation` like `scheduled` until start − 1 h (the site shows it
  days before some matches), then every 15 minutes until start + 12 h;
  after that, and for `finished`/`forfeit`, at start + 24 h and at
  start + 72 h, then it stops. A competition run arms a job at once for
  a live match (`in_progress`, or `preparation` from start − 1 h); a
  `scheduled` or earlier `preparation` one only within 48 h of its
  start, at its next checkpoint.
  `enqueue_federation_match` arms the job with dedupe key
  `federation_match:<tenant>:<site_match_id>`; an earlier
  `run_at` wins, so a later checkpoint never pushes back an earlier one,
  and a re-arm keeps the payload's `requested_at`.
- **Runs:** `record_federation_run(tenant, key, report, error)` keeps one
  `last_report` entry per thing that can fail on its own. Keys:
  - `discover` and `competition:<slug>` keep their last run: a success
    merges `{key: report + at}`, a failure `{key: {error, at}}` — the
    key's entry is whatever happened last. Only `competition:<slug>` runs
    are the sync's runs (0047; `discover` was one too until then): they
    stamp `last_run_at`, a success also `last_success_at` (the card's
    „Poslední synchronizace“).
  - `match:<site_match_id>` (one per match; the notify function puts the
    match slug in the error text, `federation_match <slug>: …`) and
    `venue:<slug>` only report trouble and never touch the run
    timestamps: a failure writes `{error, at}`, a success removes the
    key, and a success with no key to remove writes nothing at all — no
    row update, no Realtime event — so `last_report` does not grow by an
    entry per fetched match.
  - **Dead keys** — ones that can no longer run — are dropped on every
    write and never count (`federation_live_report`): a `competition:`
    no active team of the alley plays; a `venue:` that is neither
    `federation_sync.venue_slug` nor any of the alley's matches'
    `venue_slug`; a `match:` with no `cka:<id>` slot any more, or whose
    teams of ours are all switched off (`federation_match_switched_off`:
    by `teams.site_slug` = `home_team_slug`/`away_team_slug`, as the match
    job tells them — never by name, so renaming a team and switching it
    off in one save still kills its matches; a match none of our teams
    plays stays live), or whose competition no active team of the alley
    plays (its `site_slug` is `<competition>-kolo-…` of a past season —
    no competition run would ever retry it).
  - `last_error` (`federation_last_error(tenant, report)`) is the `error`
    of the newest live entry that has one, or null: a match or venue
    failure shows until that key succeeds again (a failed match is retried
    by every run of its competition), a retry that worked
    leaves no stale error, one key's success never clears another key's
    error, and an error of something that no longer runs never shows.
    `update_team`, `upsert_federation_teams` and `set_federation_sync`
    call `federation_refresh_error(tenant)` — drop the dead keys, re-derive
    `last_error`, write only on a change — so switching a team off clears
    its competition's error at once, not at the next run.

  A job the runtime killed more than 5 times (leased, never finished) is
  dropped and recorded as `dropped after N attempts`; a match's is
  retried by the next run of its competition, like one that failed 5
  times.
- **Venues** (`federation_venue` job, dedupe key
  `federation_venue:<tenant>:<slug>`, payload `{tenant_id, slug}`): the
  venue page `/detail-kuzelny/<slug>` → `upsert_federation_venue(tenant,
  {slug, name, address, phone, email, lat, lng, sections, clubs})`, one
  row per tenant and slug, `fetched_at = now()` on every write. Enqueued
  (via `enqueue_federation_venue`, due now) by `apply_federation_result`
  when a match detail names a venue the tenant has no row for yet, and by
  `request_federation_sync` for the alley's own `federation_sync.venue_slug`
  when missing — so the home alley appears after the first sync.
  `apply_federation_result` leaves alone a venue that already has a
  pending job or whose `venue:<slug>` entry in `last_report` is an error
  less than 24 hours old — live matches refresh every few minutes, and
  re-arming would cancel the backoff or refetch a broken page forever;
  the nightly pass is the daily retry. The notify tick runs up to 3 per
  tick, after the match jobs, so live match checks never wait behind
  venue pages.
- **Nightly:** `cron.job` `federation-nightly` (`0 1 * * *` UTC) runs
  `enqueue_federation_jobs()` — one `federation_competition` job per
  distinct active competition of every enabled tenant with a venue slug,
  spaced one minute apart, then one `federation_venue` job per distinct
  slug among the tenant's `federation_sync.venue_slug` and its
  `priority_slots.venue_slug` whose `venues` row is missing or older than
  7 days, continuing the one-minute spacing.
- **Live refresh:** `refresh_match` lets any member ask for a fresh
  result of a live match, gated on the server so no client can hammer the
  site: `fresh` while `fetched_at` is under 5 minutes old; otherwise it
  upserts the `federation_match` job stamped `requested_at = now()` and
  due now, but a job already requested less than 5 minutes ago (pending,
  running or backing off) is left alone — still answered `queued`, without
  kicking the dispatcher.
- **Deploy order:** `deploy-backend.yml` runs `supabase db push` before
  deploying the functions, so for a minute the old `notify` (which logs
  and drops job kinds it does not know) runs against 0045. Harmless:
  federation jobs are created only by the admin RPCs or the 01:00 UTC
  nightly cron. `request_federation_sync` and the cron need a tenant with
  the sync enabled — enable it only after the new `notify` is deployed.
  `request_federation_discovery` needs only a saved venue slug: a
  „Načíst týmy z webu“ clicked while the old `notify` is still deployed
  is dropped and just needs clicking again after the function deploy.
- **After the first run** (Správa → Oddíly → Synchronizovat teď), check
  what each competition did:

  ```sql
  select t.name as alley, e.k as job, e.v->>'at' as at, e.v->>'error' as error,
         e.v->'rekeyed' as rekeyed, e.v->'inserted' as inserted,
         e.v->'updated' as updated, e.v->'deleted' as deleted,
         e.v->'skipped_hand_edited' as skipped_hand_edited,
         e.v->'skipped_no_time' as skipped_no_time,
         e.v->'legacy_unpaired' as legacy_unpaired
    from federation_sync s
    join tenants t on t.id = s.tenant_id
    cross join jsonb_each(s.last_report) as e(k, v)
   where s.enabled
   order by t.name, e.k;
  ```

  Every
  `legacy_unpaired` entry is an old row the sync did not take over — fix
  it by hand (delete it, or edit the new `cka:` match) before players
  notice a duplicate.
- **What the sync never touches:** a row with `import_key is null` (the
  admin's own match), a hand-edited row's match columns, and every user
  table — `profiles.followed_teams`, `calendar_teams`, `team_colors`,
  `match_exceptions`. Team picks are names; `teams.name` is the name the
  sync writes into `home_team`/`away_team` for the alley's own team.

## Google kalendář — jobs, triggers, cron (0023)

A player links their Google account once (`start_calendar_link` →
Google consent → the calendar-oauth-callback function consumes the nonce,
stores the refresh token in `google_calendar_tokens`, creates the
app-owned calendar "Rezervátor" and flips `google_calendar_links.status`
to `linked`, then `backfill_calendar_jobs`). From then on every live
reservation of theirs is one event, id `sha256("<user_id>:<reservation_id>")`
→ base32hex[0..32], so a job never needs to remember whether the event
exists.

Changes made by someone else (an admin move or cancel, a cascade, a
re-timed block) reach Google through `notification_jobs`:

- **Producers.** Trigger `reservations_enqueue_calendar` (AFTER INSERT OR
  UPDATE ON `reservations`) calls `enqueue_calendar_sync(new.player_id,
  new.id)` — and, when the row changed hands (the 0022 merge re-points
  `player_id`), for `old.player_id` too, so the previous owner's event
  goes. Trigger `time_blocks_enqueue_calendar` (AFTER UPDATE OF
  `starts_at`, `ends_at` ON `time_blocks`, only when the times actually
  changed) enqueues every live future reservation on the block — the one
  change that re-times reservations without touching their rows.
  `enqueue_calendar_sync` is the single gate: it enqueues only when the
  player's link is `linked`.
- **Debounce.** `enqueue_notification(kind, dedupe_key, payload, delay =
  3 min)` upserts on `dedupe_key` (`calendar:<user_id>:<reservation_id>`):
  a repeat re-arms `run_at` and refreshes the payload. Book, move and
  cancel share the key — the handler RECONCILES (re-reads the reservation
  and upserts or deletes the event), so a book-then-cancel inside the
  window collapses into one job that does the right thing.
- **Tick.** `cron.job` `notification-jobs` (`* * * * *`) runs
  `trigger_notification_jobs()`: nothing due → nothing sent; otherwise one
  `net.http_post` to the Vault `notify_url` with `x-webhook-secret` and
  body `{"type":"CRON","table":"notification_jobs","record":null,
  "old_record":null}`. Without the Vault secrets it warns and the jobs
  wait (the local stack). The notify function's `processJobs` takes ≤ 100
  due jobs (never a `federation_%` kind — since 0045 the same tick runs
  `processFederationJobs` after the reminders: at most 1 discover,
  1 competition, 10 match, 3 venue and 5 league-match jobs per tick within a 60 s budget,
  §Výsledkový servis ČKA), deletes a job on success, on failure sets
  `attempts + 1`, `run_at = now() + 2^attempts minutes`, and drops it
  after 5 attempts;
  a revoked token or a deleted PRIMARY calendar marks the link `broken` and
  notifies the player. A deleted SECONDARY calendar (0032/0035) does not: it
  is cleared (`clearSecondaryCalendar`) and the write falls back to the
  primary, since the second calendar was always optional and must never
  take trainings — or the first calendar — down with it.
- **Not jobs.** Link, disconnect and reminders are user requests and run
  synchronously in the edge functions (`consume_calendar_nonce`,
  `backfill_calendar_jobs`, `set_calendar_reminders_for`,
  `my_future_reservations` are their service-role RPCs).

### Matches in the calendar (0027)

- Producers: trigger `priority_slots_enqueue_calendar` (insert / update /
  delete) fans out one `calendar_sync` job per follower of either team
  (`match_calendar_followers`; teams before AND after the change), payload
  `{user_id, match_id}`, dedupe `calendar:<user>:match:<slot>`. Úklid
  children and other blockages enqueue nothing. `backfill_calendar_jobs`
  also queues the followed future matches.
- Handler (`notify`): a `match_id` payload reads the slot at run time
  (`my_future_matches`) and either writes or deletes the event — see
  **Second calendar and match colours** below for exactly where.

### Second calendar and match colours (0032, colour moved to `team_colors` by 0036, wired up in Task 3)

Google's `calendar.app.created` scope hides `calendarList` for an
app-created calendar (measured against the production API: 401 either
way), so neither a colour nor a default reminder can ever live on the
calendar itself — only on the event. A followed team therefore needs its
own calendar (`primary` \| `secondary`) and its own Google event `colorId`
(1–11, `null` = none), which a `text[]` entry cannot carry — so a team
became a row, `calendar_teams` (table above), replacing
`google_calendar_links.match_teams`. The 0032 migration spilled the
pre-existing picks into rows (`calendar = 'primary'`, `color_id = null`) so
nobody's calendar changed at the time. 0033 dropped
`set_calendar_match_teams_for`, but **kept the `match_teams` column as a
read-only mirror**: builds up to 1.2.1 read it off the realtime stream, and
an empty list there would tell a player their team picks had vanished.
`set_calendar_teams_for` writes the mirror on every save; a later migration
drops it once a build with the new screen is out.

0036 moved the colour itself off `calendar_teams` onto its own table,
`team_colors` (table above): the colour is a player+team preference, shown
alike in Můj přehled and in the Google Calendar event, so it cannot live on
a table that only exists for players who linked a calendar, nor on the
calendar's own team list rather than the app's. `calendar_teams.color_id`
is gone (its rows spilled into `team_colors` first); `calendar_teams` now
carries only routing (which calendar), `team_colors` only preference
(which colour).

- calendar-oauth-callback's relink: when the previous PRIMARY calendar is
  not reachable under the fresh consent (`calendarExists` false — the old
  grant was revoked), the old consent's SECONDARY calendar is gone right
  along with it, so the callback clears `google_calendar_id_secondary` and
  `secondary_enabled` too (`clearSecondaryCalendar`, 0035). Without this a
  stale secondary id would survive the relink, route a team's matches at an
  unreachable calendar, and break the link again within a minute of the
  next sync — taking trainings down with it, since a broken link stops
  `calendarLink()` from returning anything at all.

- `set_training_color_for(user, color)` — 0034. Stores the colour of the
  player's trainings (Google event `colorId` 1–11, `null` = none) and raises
  `bad_color` on anything else. Server-only, like the other calendar RPCs;
  `calendar-manage`'s `training_color` action calls it and repaints the
  future trainings on the spot.

- `match_calendar_followers(tenant, home, away)` — same producers, same
  signature, joins `calendar_teams`; `distinct` because a player following
  both teams of a derby has two matching rows and must still come back once.
- `my_future_matches(user)` — same live-future-matches list, with two extra
  columns: `calendar`, read off the `calendar_teams` row for whichever
  followed team is on that match (derby, both teams followed: the home
  team's row wins, via a `lateral` join ordered `team = home_team desc,
  limit 1`), and (0036) `color_id`, a separate `left join` onto
  `team_colors` for that SAME resolved team — a match whose team has no
  `team_colors` row simply comes back with `color_id = null`, exactly like
  an uncoloured team always has.
- `set_calendar_teams_for(user, teams jsonb) returns jsonb` — the only way
  `calendar_teams` is written server-side: validates ≤ 20 items
  (`bad_teams`) and that the caller has a links row (`unknown_link`);
  `calendar` bounds are the table's own CHECK constraint, so a bad value
  surfaces as `check_violation`. It does **not** trim, dedupe or reject a
  blank team name itself (unlike the function it replaced) — per-item shape
  is validated in TypeScript instead, see below. Returns the **previous**
  rows as `[{team, calendar}]` before a delete+insert overwrites them — one
  statement, so a bad row rolls the whole write back. (0036: dropped
  `color_id` from both the input and the returned shape — colour is
  `team_colors`'s contract now, immediately below.)
- `set_team_colors_for(user, colors jsonb) returns jsonb` — (0036)
  server-only like the other calendar RPCs, even though `team_colors`
  itself is directly writable by the client (see table above): calendar-manage
  calls it so a colour change can repaint the affected future Google
  Calendar events in the same request, the same reason `set_training_color_for`
  is server-only. Unlike `set_calendar_teams_for` this is **not** a full
  replace: it validates ≤ 40 items (`bad_colors`), then per named team
  either deletes the row (`color_id: null`) or upserts it — every other
  team's colour, not named in this call, is untouched, since a colour lives
  independently of whatever `calendar_teams` currently says. Bounds (1–11)
  are the table's own CHECK. Returns the **previous** `{team, color_id}` of
  only the teams the call named (a team with no previous row is simply
  absent from the result, not returned as null).
- `set_calendar_reminders_for` (table above) takes a third argument,
  `calendar`, defaulting to `'primary'` so every existing 2-argument call
  is unchanged; `'secondary'` writes `reminder_minutes_secondary` instead.
- `_shared/google_calendar.ts`: `EventBody.colorId?` (Google's own "1".."11",
  never a bare RGB — set only when a colour is actually chosen, so a body
  without one is byte-identical to before colours existed);
  `reservationEventBody`/`matchEventBody` take an optional `colorId`;
  `matchTarget(calendar, {primary, secondary})` — pure routing: which
  calendar id a match's `calendar` column means right now (`secondary`
  without a live second calendar falls back to `primary`, so a team never
  loses its event just because the player turned the toggle off) and which
  OTHER id must be swept; `writeFutureMatches(db, user, token, calendars)`
  upserts every live match into its target and, only after that upsert
  succeeds, deletes the same deterministic event id from the other
  calendar — a team moving calendars is then just "next sync writes it into
  the new one and cleans up the old one", no separate move path. It returns
  `{written, sweepFailed}`: a sweep that fails transiently (Google 5xx/429)
  is reported, not just logged, so `calendar-manage` still enqueues a
  backfill even when every write itself succeeded — otherwise the event
  would sit duplicated in both calendars with nothing left to retry it.
  `possibleMatchCalendars`/`worstResult` support cleaning up a match that is
  no longer live at all: since an event's id never records which calendar it
  was last written to, deletion is attempted against every calendar it could
  be sitting in, folding the results into one retry verdict. `notify`'s own
  `matchSync` folds its write and sweep the same way, and additionally: a
  write that lands on the SECONDARY calendar and comes back "gone" (deleted
  by hand in Google) clears it (`clearSecondaryCalendar`) and retries
  against the primary instead of breaking the whole link over a calendar
  that was always optional.
- `notify`'s `jobCalendarSync`: a `match_id` payload reads `my_future_matches`
  at run time (the revalidation) — a live row is written via `matchTarget`
  with that team's reminders (`reminder_minutes` or `_secondary`, by which
  calendar it landed in) and colour, then swept from the other calendar; no
  row means the match is gone/unfollowed/played, deleted from every calendar
  it could be sitting in (`possibleMatchCalendars`). A `reservation_id`
  payload always targets the primary calendar with `training_color_id`.
- `calendar-manage` actions: `teams` (`Api.setCalendarTeams` →
  `[{team, calendar}]`, validated by `validateTeamChoices` — trims, rejects
  a blank/too-long team name or an unknown calendar, de-duplicates by team
  name (first occurrence wins); a `color_id` key is not read at all any
  more, however malformed — colour is `team_colors`'s contract now — before
  `set_calendar_teams_for`; the previous state it returns is diffed to
  delete the events of teams dropped entirely, then `writeFutureMatches`
  settles the rest); `team_colors` (0036, `Api.setTeamColors` →
  `[{team, color_id}]`, validated by `validateTeamColors` — same
  trim/blank/too-long/de-dupe discipline as `validateTeamChoices`, plus a
  `color_id` outside Google's 1–11 (a missing key and an explicit `null`
  both mean "clear this team's colour"); ≤ 40 items — before
  `set_team_colors_for`. Unlike `teams` this never drops or adds a followed
  team or changes any routing: it is a PARTIAL upsert of only the named
  teams' colours, so there is nothing to delete, only `writeFutureMatches`
  to rewrite every future match right away); `secondary` (`{enabled}` — ON
  creates "Rezervátor 2" and rewrites future matches into it, OFF deletes
  it in Google, which takes its events with it, resets any `calendar_teams`
  rows pointed at `'secondary'` back to `'primary'`, and rewrites future
  matches back into the primary); `reminders` (takes `calendar`,
  `'primary'` \| `'secondary'`, and rewrites both trainings and matches so
  every event stays correct regardless of which reminder list just
  changed); `match_teams` (0035 — the shipped 1.2.1 app's action, a bare
  team-name `string[]`, no colour: maps it onto `teams` via
  `mapLegacyMatchTeams`, keeping each surviving team's `calendar` and
  defaulting a newly added one to primary, then runs the same `setTeams`
  path; colour is untouched either way — `team_colors` is a table this
  legacy path never reads or writes).

### One match in, one match out (0039)

Teams answer the question wholesale. Sometimes it is about ONE match: a
B-team player turns out for the A team, or a match is simply worth watching
— and the other way round, next weekend one is away and would rather not see
it at all. Following or unfollowing a whole team is the wrong size of
answer, so the exception is per MATCH:

- **`match_exceptions`** (table above). Written only through
  **`set_match_exception(p_match, p_shown)`** — unlike the calendar RPCs
  this one is called straight from the app (it writes the caller's own row
  and nothing else). `true` adds, `false` hides, `null` drops the row and
  lets the teams decide again. It refuses a match that is not this alley's,
  is not a match (an úklid child, a blockage), or is already over
  (`unknown_match` / `match_past`); the kiosk and a pending profile get
  `not_allowed`. The reason for an exception is nowhere in the model — the
  app records the decision, not the motive.
- **`my_future_matches`** decides whether a match is the player's with
  `coalesce(e.shown, c.team is not null)` (the `calendar_teams` lateral join
  became a LEFT join): the exception if there is one, the teams otherwise,
  both directions in one expression. An added match takes the exception's
  calendar, which is the main one — and since the sync writes to the target
  and sweeps the same deterministic event id from the other calendar, adding
  a match to the main calendar is also what takes it out of the second one.
  Its colour falls back to the one the player gave OUR team of the match
  (`is_away` says which side that is) — the same rule `matchColorOf` follows
  in the app, so the trophy in Můj přehled and the Google event agree.
- **Jobs.** A trigger on `match_exceptions` queues
  `enqueue_match_calendar_sync` on insert, update and delete — including the
  delete the match's own cascade causes, which is what takes the Google
  event away with the match. A hidden match needs no new code either:
  `my_future_matches` stops returning it, and "no row" has meant "delete the
  event from every calendar it could be in" since 0027. `priority_slots_enqueue_calendar` additionally
  fans out to everyone holding an exception on the row:
  `match_calendar_followers` only knows `calendar_teams`, and the whole
  point of an exception is a player who follows neither team.
- **`calendar-manage`'s `teams`** skips a match with an exception when it
  deletes the events of dropped teams: that loop reads `priority_slots`
  directly (the one path that does not go through `my_future_matches`), so
  without the check, dropping a team would take a guest match with it.

### Připomínky před akcí (0040)

A player with a Google calendar gets reminded by Google (`reminder_minutes`,
0032). A player without one had nothing: the app announced what had
*happened* — a cancelled training, a booking made at the kiosk — never what
was *coming*. `profiles.notify_before_minutes` is the other half, set the
same way (up to five lead times, 0 to four weeks) and delivered through the
same door as every other message: push where the profile has an `fcm_token`
and FCM is configured, e-mail otherwise.

- **Nothing is scheduled.** A row queued at (start − lead) would have to be
  re-planned every time anything moved — a cancelled reservation, a re-timed
  block, a postponed match, a dropped team, a new exception, a changed lead
  time. Six triggers that must agree, and one forgotten means a reminder for
  a training that no longer exists. Instead `due_reminders()` answers, every
  minute, what is due *right now* from the data as it stands.
- **`due_reminders()`** unions `my_future_reservations` with
  **`my_upcoming_matches`** — the server-side twin of what `upcomingTimeline`
  computes in the app: followed teams plus added exceptions, minus hidden
  ones (0039). Not `my_future_matches`, which is about the Google calendar
  and returns nothing without a link. A reminder is due when
  `starts − lead <= now()` and the event has not started yet: after an
  outage a late reminder ("za 20 minut") is worth sending, one for a training
  already under way is not. A receipt at that lead time or a closer one,
  for the same start, covers it (0049): a longer lead time added after a
  closer reminder went out does not ring on its own, a closer one still
  rings after a longer one, and an event moved since rings again.
- **One push per event.** When several lead times of one event are due at
  once (booked, moved or followed inside them, reminders switched on, an
  outage), notify sends only the closest and marks the rest
  (`oneReminderPerEvent`, `_shared/reminders.ts`). The title names the
  chosen lead time when sent on its minute and the time actually left when
  late; whole days count Prague calendar dates. A reminder FCM or Resend
  could not take just now (429, 5xx, a dead push token — e-mail next time)
  is not marked and is due again next minute (`deliverDueReminders`,
  `_shared/delivery.ts`).
- **`notifications_due()`** is the gate the minutely tick reads, a function
  of its own so a test can ask it directly — without Vault configured the
  tick returns before posting, so calling it proves nothing.
- **`mark_reminder_sent(user, event_key, offset, starts_at)`** writes the
  receipt once a reminder was delivered or cannot be (no address, refused
  for good), with the start it was for (0049; marking the same lead time for
  a new start moves the receipt there), and prunes the table. A send that
  throws or that FCM or Resend could not take just now is simply due again
  next minute, which is what one wants from a reminder: late beats never.
  0049 gave the receipts written before it the start their event had then;
  one without a known start counts for any.

### Připomínka služby na kantýně (0050)

The alley's admin switches the reminder before a canteen duty on or off and
picks its lead (`schedule_settings.duty_reminder_enabled` /
`duty_reminder_days`, 1–14 days; off keeps the lead). Like 0040, nothing is
scheduled: the minutely tick asks what is due now, so a moved or deleted
period, a changed roster or a changed lead simply answers differently.

- **`due_duty_reminders()`** (security definer, stable, `service_role`
  only) returns (`user_id`, `email`, `fcm_token`, `period_id`, `starts_on`,
  `ends_on`, `days`, `co_assignees text[]`) — one row per assigned account
  and period where the period's alley has the reminder on, 18:00 Prague on
  `starts_on − days` has passed (a period planned or a player assigned
  inside the lead is reminded at once, late), the duty has not started
  (`starts_on` after Prague today) and there is no receipt. Accounts only:
  approved, no placeholder (no login, nowhere to send), never the kiosk;
  an admin on the duty is reminded too. No tenant match, unlike
  `is_on_duty()`: a superadmin visiting another alley still serves in their
  own. `co_assignees` are the others on the roster, placeholders included
  (they serve too). A function of its own, so `due_reminders()` and its
  tests stay as they were.
- **The receipt** is `reminders_sent` with `event_key = 'd:<period id>'`,
  `offset_minutes = days × 1440` and `starts_at` = Prague midnight of
  `starts_on`, read with 0049's meaning: a receipt at this lead or a closer
  one, for this start, covers it — a lead lengthened after the reminder went
  out does not ring again, and a period moved to other dates does. The tick
  prunes it after 30 days like every receipt; by then the duty has long
  started, and a started duty is never due.
- **`notifications_due()`** also wakes for a due duty reminder.
- **notify** sends them in the CRON branch after the other reminders
  (`sendDueDutyReminders`, `_shared/duty_reminders.ts`), through the same
  push-or-e-mail door and the same delivery contract as
  `deliverDueReminders`: marked when delivered or undeliverable, due again
  next minute after a retry or a throw. Title „Zítra sloužíš na kantýně“ /
  „Za 2 dny sloužíš na kantýně“, counting the Prague calendar days actually
  left (never „Dnes“; a duty that began between the query and the send is
  skipped); body „po 5. 10. – ne 11. 10.“ (a one-day duty names its day
  once) plus „, spolu s: …“ sorted Czech-alphabetically; the e-mail adds
  what the duty may do. Push data `kind = duty_reminder`.

### Zprávy a nástěnka (0051)

The admin and the player on canteen duty write to players (a block, a day,
everyone); any account player writes to the admins or to today's duty. A
notice (`kind = 'notice'`, `audience = 'all'`, Klubovna → Nástěnka) is the
same machinery with a title, an expiry and no reactions. Not a chat: no
threads, no player-to-player messages. Every error is a bare code.

- **`message_send(kind, audience, on_date?, block_id?, title?, body,
  expires_at?, notify?)`** (security definer, `authenticated`) returns the
  new id. The caller must be an approved account member of the alley, not
  the kiosk (`not_allowed`). A notice: admin only (`not_allowed`), audience
  `all` (`invalid_audience`), a title (`title_required`) of at most 80
  characters (`title_too_long` — `char_length`, i.e. code points: 👍🏽 is
  two, so the app counts runes, not what the screen shows; never the raw
  `messages_title_check`), ≤ 2000 chars;
  `notify` is the admin's choice (null = true). A message to a `day` /
  `block`: the admin, or the duty through `duty_edit_gate(on_date)` (a
  period of their own covers the date, on duty today or not — `not_allowed`;
  not a past date — `date_past`; the block edits' gate, 0050; a missing date
  is `date_past` too); the block must be an active block of the alley or a
  day-special one that `day_overrides.block_ids` names for that date
  (`unknown_block`). A message to `admins` / `duty`: any approved account
  member, admins included; `on_date` / `block_id` are optional context (the
  training written about), the block must be the alley's (`unknown_block`).
  A message has no title, no expiry and always pings, ≤ 500 chars; an
  unknown kind is `invalid_kind`, an unknown audience `invalid_audience`, a
  blank body `body_required`, a long one `body_too_long` — title and body
  trimmed of any whitespace (newlines and tabs too) first, and stored so. Recipients are
  materialised in the same transaction. Every audience draws from the same
  members — the `players` view's rule (approved, not the kiosk, not a
  placeholder, not a visiting superadmin) — minus the author. So a pending
  account gets nothing, not even a `day` / `block` message for a live
  booking of its own (the composer's preview names recipients from that
  same roster), and a pending assignee is off duty (`is_on_duty`, 0050):

  | audience | recipients (among those members) |
  |---|---|
  | `all` | all of them (admins included) |
  | `day` | those with a live reservation on `on_date`, any block |
  | `block` | those with a live reservation on `on_date` in `block_id` |
  | `admins` | the admins |
  | `duty` | the assignees of the period covering Prague today |

  A message to an empty set is `no_recipients`, except `duty`:
  `nobody_on_duty` (no period today, or every assignee on it is the
  author, a placeholder or pending). A notice to an empty set (an alley
  whose admin is its only account so far) goes up with no recipient rows:
  the board is not recipient-based — every member reads every notice —
  and the rows are there only for the push and „Kdo si to zobrazil“.
- **`can_read_message(id)`** (security definer, stable, `authenticated`) —
  whether the caller reads a message: it is the caller's alley's, the
  caller an approved non-kiosk member (so an account later set as the
  kiosk or back to pending reads nothing, not even what it once got), and
  it is a notice, or the caller wrote it, or has a recipient row.
- **`visible_message_ids()`** (security definer, stable, `authenticated`,
  `setof uuid`) — the same rule as a set, for `messages_select`
  (`id in (select visible_message_ids())`, one call per query instead of
  one per row: ~13 ms → ~0.4 ms for a player's stream at 150 messages).
- **`visible_recipient_message_ids()`** (same shape) — the messages whose
  every recipient row the caller sees, for `message_recipients_select`
  (besides the caller's own row): a notice to the alley's admins, a
  `message` to its author and its recipients, nothing to the kiosk or a
  pending account (~400 ms → ~0.7 ms for a player's stream of recipient
  rows at 40 members × 100 notices against a per-row helper). Security
  definer so the policy does not recurse into its own table's RLS.
- **`message_update(id, title, body, expires_at)`** — notices of the
  caller's alley only (a message or another alley's notice is
  `unknown_message`), admin (`not_allowed`); `title_required`,
  `title_too_long`, `body_required`, `body_too_long` (trimmed and counted
  as in `message_send`). No
  "leave unchanged" sentinel: the form sends its whole state, so
  `expires_at = null` is „do odvolání“; „Sejmout“ is the same call with
  `expires_at = now()`. Bumps `updated_at`.
- **`message_delete(id)`** — the author or the alley's admin, while an
  approved non-kiosk member (`not_allowed`; `unknown_message` otherwise);
  the recipients cascade.
- **`prune_messages()`** (`service_role` only) deletes messages — never
  notices — whose key day (`on_date`, else `created_at` in Prague) is more
  than 90 days old and returns how many; `cron.job` `messages-prune`
  (`20 3 * * *` UTC) runs it.
- **Delivery.** `notify_messages` (after insert on `messages`) and
  `notify_message_reactions` (after update of `reaction`, `reply` on
  `message_recipients`, `when` either is distinct from before) post the
  row to notify through `notify_webhook()`, like every other row webhook;
  notify fans the message out and tells the author about a reaction
  (§Edge functions → notify). A read (`read_at` alone) is no update of
  those columns, and a write that leaves both as they were (a no-op PATCH,
  the same 👍 clicked twice in the e-mail) fails the `when` — neither
  reaches pg_net. **Accepted:** there is no throttle, so a recipient who
  flips 👍 → 👎 → 👍 over and over, or rewrites her reply over and over
  (her own row, which she may write), notifies the author once per
  change — a push, or a Resend e-mail when the author has no push token,
  which spends the free tier's quota. The spec wants every reaction and
  reply told; the abuse is bounded to authors of messages she received,
  in her own alley.
- **Realtime DELETE events.** Both tables are in the publication with the
  default replica identity. Realtime checks no RLS on a DELETE (Postgres
  cannot evaluate a policy against a row that is gone) and sends the old
  row's key to every subscriber of the table — so when `message_delete`
  or the daily prune cascades, any account streaming `message_recipients`
  unfiltered receives the (`message_id`, `user_id`) pairs, from every
  alley, and `messages` subscribers the deleted `id`. UUIDs only, no
  text; **accepted**, the same as `duty_assignments` and
  `player_group_members` (INSERT and UPDATE events do go through the
  select policies).

## Edge functions

- **notify** — called by `notify_webhook()` (pg_net POST; URL and
  `x-webhook-secret` come from Vault `notify_url` / `webhook_secret`,
  SETUP.md §2). Events: profile insert (pending) → tenant admins
  (placeholders are inserted approved, so none); kiosk
  reservation insert → the player, with a one-click cancel link (HMAC
  token signed with `CANCEL_TOKEN_SECRET`, valid until the block starts);
  reservation update: admin cancel of an upcoming date → the player
  (honours `notify_player`, `cancel_note` as the reason), move → the player
  ("Termín přesunut", `notify_message` overrides the wording); a booking by
  a group mate (0044) or by the player on duty (0050, `created_via = 'duty'`,
  push kind `duty_booking`) → the player, „X ti zarezervoval(a) trénink: …“;
  a cancel by the player on duty (`cancelled_via = 'duty'`, 0050) → like the
  admin's (honours `notify_player`, silent for past dates), the default
  reason „zrušil(a) X (služba na kantýně)“ instead of „zrušeno správcem“
  (the duty's day-level cancels are `'admin'` with a non-empty note);
  tenant
  insert (pending) → superadmins; a `messages` insert (0051) → every one of
  its `message_recipients` — pushes one at a time, e-mails as Resend
  `/emails/batch` requests of up to 100 (one request, not one per
  recipient: Resend's per-second rate limit; each under the
  `Idempotency-Key` `message/<id>/<n>`, so a batch answered 429/5xx, tried
  once more a second later under the same key, is never sent twice; a
  batch refused as invalid — 400/422, Resend's strict validation fails all
  of it over one bad address — goes out one by one, 500 ms apart, each
  under `message/<id>/<n>/<j>`, a busy one tried once more a second later,
  a refused one logged while the rest still go — but one refused over
  something other than its address (a bad key; a malformed sender, which
  Resend answers as a 400 `validation_error` naming `from`) before any
  went through stops the rest, logged once; `_shared/resend.ts`; a
  recipient whose push or signed links fail, or a batch that throws, is
  logged and skipped, the others still get theirs) — unless `notify` is
  false; a failed load of the recipients is logged and answers 500
  instead of sending nothing; a `message` (not a notice) without
  `CANCEL_TOKEN_SECRET` answers 500 before any delivery, its 👍/👎 links
  cannot be signed — a notice: its title and the text cut to 120
  characters, the e-mail „Otevřít nástěnku“; a message: „Zpráva od
  správce“ / „Zpráva od služby“ (by `author_role`) to players, „Zpráva od
  hráče: {jméno}“ from a player to staff (an admin to staff: „Zpráva od
  správce ({jméno})“ — the author's role decides, not the audience), the
  context („pá 2. 10. · 16:00–17:00“) on its own line, the e-mail with signed
  one-click 👍/👎 links to **react** (`signReactToken`,
  `CANCEL_TOKEN_SECRET`) and „Odpovědět v aplikaci“;
  push data `{kind: notice | message, message_id, tenant_id}` (the alley,
  for the app's deep-link guard); a `message_recipients`
  update of `reaction` / `reply` (0051) → the message's author, „Reakce na
  tvou zprávu“ / „Petr Novák: 👍 Přijdu dřív.“, push data `{kind:
  message_reaction, message_id, tenant_id}` — only when a reaction or a
  non-blank reply is new, never on a clear (whole or half), never for a
  notice, and never to an author who may no longer read the message (set
  as the kiosk, back to pending or moved to another alley:
  `_shared/membership.ts`'s `isMemberOf`, the rule react's `mayReact`
  applies — the service role bypasses the RLS that says it).
  Channel: FCM push when the profile has an
  `fcm_token` and `FIREBASE_SERVICE_ACCOUNT` is set, otherwise Resend
  e-mail. Fails closed on a missing `WEBHOOK_SECRET` (401) or
  `CANCEL_TOKEN_SECRET` (500). Since 0023 it also takes the cron tick
  (`type = "CRON"`, `table = "notification_jobs"`) and works the due jobs
  (§Google kalendář) and, since 0045, the federation jobs (§Výsledkový
  servis ČKA).
- **calendar-oauth-callback** — Google's redirect target (no JWT; the
  trust is the nonce): `consume_calendar_nonce`, code exchange, writes
  `google_calendar_tokens` + `google_calendar_links` with the service
  role, creates or reuses the "Rezervátor" calendar, `backfill_calendar_jobs`
  + a synchronous first write of `my_future_reservations`, then redirects
  to the landing page.
- **calendar-manage** — JWT-verified user actions: `disconnect` (deletes
  the Google calendar, revokes the token, forgets the token row, sets
  `status = 'unlinked'`); `reminders` (`set_calendar_reminders_for` for
  either calendar, then rewrites the events of `my_future_reservations` and
  `my_future_matches`); `teams` (stores `calendar_teams` via
  `set_calendar_teams_for`, deletes dropped teams' events, rewrites the
  rest — §Second calendar and match colours); `secondary` (creates or
  deletes "Rezervátor 2", same section).
- **cancel** — GET only reads (link scanners follow it) and redirects to
  the confirmation page `web/cancel.html` on rezervator.online with the
  token; that page's button POSTs it back, and the POST verifies the token,
  updates `reservations` directly with the service role
  (`cancelled_via = 'one_click'`) and redirects to the same page with the
  outcome. Both methods also refuse (`vyprselo`) once the block the
  reservation is in *now* has started: the token's expiry is the start it
  had when the link went out, and a move keeps the row and its token — after
  the start, cancelling is an admin decision (attendance). Never HTML from
  the function itself: the edge runtime rewrites the Content-Type to
  text/plain. This is the one reservation write outside the RPCs; the
  notify function ignores `one_click` cancels.
- **react** (0051) — the 👍/👎 links of a message e-mail (no JWT —
  deployed `--no-verify-jwt`, like cancel; the trust is the token). GET
  `?t=<token>` (HMAC over `{m, u, r, x}` — message, recipient, reaction,
  issue time — signed with `CANCEL_TOKEN_SECRET`, valid 30 days from `x`
  — `_shared/react_token.ts`) → checks the `message_recipients` row
  still exists and its account may still react — the app's
  `message_recipients_update_own` rule, which the service role bypasses:
  an approved non-kiosk member of the row's alley (`mayReact`) — and
  writes its `reaction` with the service role (the `reacted_at` trigger
  and `notify_message_reactions` fire as from the app), then a 303 to
  `reakce.html?ok=1`; a bad, expired or orphaned token, a recipient set as
  the kiosk, back to pending or moved to another alley → `?ok=0`; a
  database error → `?ok=retry` (the link is fine; the page asks to try
  again). A database error and a missing `CANCEL_TOKEN_SECRET`
  (500) are logged with `console.error`, as in cancel. One click, no
  confirm page (unlike cancel): a reaction is harmless and reversible in
  the app. Only GET writes: HEAD (what a link scanner or mail gateway
  probes with) answers the same 303 as far as the token tells and never
  touches the database; any other method → 405 (`Allow: GET, HEAD`).
  Logic in `_shared/react_handler.ts`.

## Prod vs git

- Prod additionally has Supabase's platform function `rls_auto_enable`
  (event-trigger helper) — not ours, not in migrations.
- Vault secrets `notify_url` and `webhook_secret` are per-backend
  configuration, never in migrations; the 0023 cron tick reads the same
  two entries through `notify_webhook_config()`.
- `pg_cron` is enabled by 0023 (`create extension if not exists`); the
  `cron` schema and the job rows `notification-jobs`,
  `federation-nightly` (0045) and `messages-prune` (0051) live outside
  `public`, so they are not in `supabase/schema.sql` — check with
  `select jobname from cron.job`.
- `btree_gist` (0050, for `duty_periods_no_overlap`) is installed into the
  `extensions` schema, so like `pg_cron` it is not in `supabase/schema.sql`
  — check with `select extnamespace::regnamespace from pg_extension where
  extname = 'btree_gist'`.
- No default table/sequence grants (0046): every new table grants itself,
  so a git-built database and prod match without relying on the platform.
- `supabase db dump` does not emit publications — `supabase_realtime`
  membership (below) is invisible to both `supabase/schema.sql` and a plain
  migration read; only `tenancy_rls.sql`'s own query against
  `pg_publication_tables` (0035) catches a streamed table left out of it.

## Checks

- `tool/schema_snapshot.sh` regenerates `supabase/schema.sql` after a new
  migration (local stack only).
- `supabase/tests/tenancy_rls.sql` — cross-tenant isolation, superadmin
  visiting, the 0018 cascade, the 0021 rental exceptions, the
  `reject_tenant` guard, the 0022 placeholder lifecycle, the 0023
  calendar plumbing (nonce lifecycle, server-only privileges, the job
  producers and their dedupe, backfill, reminders,
  `my_future_reservations`, the dispatcher without Vault, the cron row),
  the 0032/0035 calendar_teams privileges, the 0036 `team_colors` own-row
  RLS (read/write own, invisible/untouchable foreign row through RLS, not
  through a grant), its CHECK bounds, and `set_team_colors_for` (server-only,
  previous-state return, a null colour deletes the row), the 0038
  `hand_edited` rule (flags an app edit of an imported match, not the
  import's own update, a no-op update or a manual match; an import-run
  update that resets the flag clears it — the sync never does) together
  with the assertion that an import-style update / delete / insert on
  `priority_slots` leaves every user's team picks byte-identical,
  the 0040 reminders (the player's own lead times inside their checks and on
  their own row only, due at the lead time and only once, following Můj
  přehled through teams / added / hidden matches, the tick's gate awake for a
  reminder with an empty job queue, and the ledger server-only), the 0049
  ledger (a closer receipt covers a longer lead time added later, a longer
  one sent first does not silence the closer one, a receipt keeps its start,
  a moved event rings again and is re-marked at its new start, a receipt
  without a start counts for any, the old three-argument call still
  resolves, the three-argument signature is gone and only the service can
  mark),
  the 0039 exceptions (select-only table + client-callable RPC, a match of
  nobody's team routed to the main calendar with our team's colour, an
  exception outranking the team's own calendar, hiding a match a team does
  give, clearing an exception handing the match back to the team, the
  unknown/foreign/past/úklid refusals, the kiosk refusal, and the jobs —
  queued when switched on, when the match is re-timed under it, and when the
  match is deleted), the 0041 rental groups (one-time dates only,
  name/colour — a hand-picked one included — copied and propagated, a grouped
  date blocks like a lone rental, the group vanishes with its last date,
  invisible across tenants, writes refused for a non-admin who can read
  them, full-DML privileges), the 0043 public overview (anon may call only
  `public_week`; slug format, normalisation and uniqueness; admin-only
  setting; unknown and switched-off slugs indistinguishable; occupancy in
  club colours without any name, player id, renter, note or other tenant),
  the 0044 player groups (invite/accept/decline/leave/cancel-invite, one
  group per player, nobody but approved account holders of the alley
  invitable, a member books and cancels for a member under the member's cap
  and until the training starts, outsiders never, the group dies with its
  last member, admin prune and foreign-admin isolation, RLS and
  privileges), the 0045 results sync (`apply_federation_matches`: home and
  away matches inserted as `cka:<id>` by the alley's admin, idempotent with
  a video link alone no update, a `rozpis:` row rekeyed in place, a
  hand-edited match reported and never overwritten, only future matches
  the site dropped deleted with their match job — never on an empty list,
  a started match or `keep_ids` — and a stored match keeping home/away
  until its venue is known; `apply_federation_result`: result, players and
  the venue deciding home/away except on a hand-edited match, `false`
  without a slot; discovery keeping the admin's name and switch and
  `update_team` admin-only, per alley, unique and non-empty; the five
  tables read-only for the app, per alley and in `supabase_realtime`,
  `match_player_results` with replica identity full, the server functions
  the service's; the sync settings admin-only with a validated slug and
  the admin-only sync/discovery requests; the `refresh_match` gate; the
  nightly producer; `record_federation_run` per key — only discovery and
  competitions stamping a run, a match or venue success removing just its
  own key or writing nothing — and `last_error` as the newest error of a
  live key, dead keys (a switched-off competition, a deleted or
  switched-off match — told by team slug, so also when renamed in the
  same save — a past season's match, a foreign venue) pruned on every
  write and at once
  on `update_team`, `set_federation_sync` and a discovery rollover, per
  alley; the calendar-trigger rule — only a change of what the event shows
  enqueues, and never for a match in the past before and after; and the
  venues — upsert, one fetch for an unknown match venue, the nightly and
  sync-request producers, no re-arm of a pending or recently failed
  fetch), the 0048 contacts (`contacts()` lists the alley's registered
  players only — no placeholder, kiosk, pending member or visiting
  superadmin, who may still read it — with a hidden e-mail or phone null
  and the other still shown; the kiosk and a pending member refused, anon
  without EXECUTE, another alley invisible; phone and switches own-row
  only, even against the admin; the E.164 check and its 8- and 15-digit
  bounds; `register_profile` with a phone, a refused one, a blank one, a
  named call without `p_phone`; `create_tenant_and_register` without a
  phone, with the founder's phone, and with a bad one that founds no
  tenant), the 0050 canteen duties — data and planning (the three tables
  RLS-on and select-only for the app, closed to anon, the admin's seven
  RPCs security definer and not anon's, the overlap guard; the generator
  creating, clipping the last period, skipping a whole overlapping one and
  a second run, days 1–31 and at most 400 days both ends counted, the
  400-day edge included; `duty_period_save` insert/edit, overlap on insert
  and on edit, touching allowed, 62 days the most, the date order, an
  unknown id and an 80-character note; another alley planning the same
  dates and reaching none of ours; the assignee set replaced whole, a
  placeholder in, the kiosk, a pending player, another alley's player,
  an unknown id and a null out without touching the set; the bulk delete
  of unassigned periods from a date on and a deleted period taking its
  assignees; seasons in order, `empty_name`, the name check, only the
  newest undone; the reminder columns written by the admin through
  `settings_update`, 1–14 days, off keeping the lead, not by a player; a
  placeholder's duties refusing its delete and moving with the merge,
  duplicates dropped; a player, the kiosk and a pending member reading
  the roster or not, writing nothing and calling no admin RPC; anon
  reaching neither), the 0050 duty's rights (in an alley of its own, clear
  of A's time-relative matches: `is_on_duty` / `duty_gate` /
  `duty_edit_gate` internal, the two new day RPCs the app's and not anon's, `is_admin()` still
  PUBLIC-executable, both via CHECKs allowing `'duty'` and validated;
  `is_on_duty()` true inside the period only — not after, not before, not
  for a placeholder or an admin on the period, not once demoted to pending,
  not for a superadmin visiting another alley, and back when home; a duty
  booking as `'duty'` under the target's cap (`player_at_limit`), no
  yesterday and no started block (`date_past`), the horizon
  (`beyond_horizon`), no player of another alley, the duty's own booking
  `'app'` and a group mate's `'group'`; a duty cancel as `'duty'` keeping
  the note and notify choice, a null choice notifying, `too_late` for a
  started training, `not_allowed` for another alley's; every day RPC on
  the days of the duty's own periods from today on and `date_past` for
  yesterday; a started block of today (the
  00:00 one) neither left nor entered by the duty's moves (`too_late`) and
  spared by the duty's block cancel and day close, while tomorrow's 00:00
  moves freely; the admin through the same RPCs on yesterday (move,
  block move, block cancel, close, override delete) and on a started block
  today (out, in, cancelled by the block list and as a block), and adding a
  day-only block; a player whose duty ended refused
  with `not_allowed` everywhere — an unknown reservation too — changing
  nothing, while their own booking still works; on duty, no direct
  write to blocks, matches, rentals, settings or overrides; and the block
  edits on the days of the duty's OWN periods only (`duty_edit_gate`):
  another duty's days and days nobody serves `not_allowed` while booking,
  re-seating and cancelling there still work, both of two consecutive own
  periods edited edge to edge, a past day `date_past` inside an own period
  and `not_allowed` outside, a duty that starts later editing exactly its
  own days, adding a block and re-seating players on them but booking and
  cancelling for no one, a pending player, a placeholder, a kiosk account and a visiting
  superadmin refused, a duty ended yesterday refused (no block added) and
  one ending today still editing today, the admin editing any day), the 0050 duty
  reminder (`due_duty_reminders()` stable, security definer and the
  service's alone, `notifications_due()` still the service's; nothing due
  and the tick asleep while the reminder is off; on, due from 18:00 Prague
  on the lead day — yesterday's passed, tomorrow's not, today's by the
  clock — until the duty starts, not on its first day; for the period's
  accounts and the admin, never a placeholder, a pending player or the
  kiosk, with the others as `co_assignees`; a demoted player not reminded
  until approved again; a receipt silencing only its player, a closer lead
  covering a longer one, a moved period ringing again and its receipt
  moving with it; switched off, nothing due and the lead kept), the 0051
  messages (in an alley of its own: select-only tables with the three
  own-row update columns; each audience's recipients with the author,
  placeholders, cancelled bookings, a pending account (booked or not),
  the kiosk and a visiting superadmin out and a double booking counted
  once; `no_recipients` for a message (a notice in an alley whose admin
  is its only account goes up with no recipient rows), `nobody_on_duty`
  with no period today, with
  every assignee excluded (the author, a placeholder) and with the only
  account assignee pending; the admin, the duty on the days of her own
  period (also one starting tomorrow, on duty today or not; `date_past`
  inside a period, `not_allowed` outside it) and a
  plain player per audience (the admin to a past day and block too), the
  kiosk, a placeholder and a pending
  account sending nothing, another alley reaching only its own admins;
  every error code (`title_too_long` over 80 code points — 41 × 👍🏽 —
  in both RPCs, 80 once trimmed still fine); a day-only block counting on the date its override
  names it and no other; blank as any whitespace and the stored text
  trimmed of it; `can_read_message` for the author, a recipient,
  a bystander, the kiosk, a pending account and another alley, a notice
  for a player approved after it went out (no recipient row), a recipient
  later set as the kiosk or back to pending reading and replying to
  nothing; recipient rows — a notice's own row for a player and every
  row for any admin, a message's every row for its author and its
  recipients, none for a bystander (the admin included) or another
  alley; both select policies led by the alley and set-based, and
  `visible_message_ids()` equal to what `can_read_message` admits for
  every account in the file; own-row reactions with `reacted_at` stamped
  and cleared, none on a notice (`not_allowed`), exactly `read_at`,
  `reaction`, `reply` updatable and every other write a privilege error;
  `message_update` notices-only with Sejmout and do odvolání;
  `message_delete` by the author or the admin, cascading, not by an
  author back to pending or set as the kiosk;
  `prune_messages` keeping notices and recent messages; the triggers and
  their shape (`after update of reaction, reply … when` either changed,
  `after insert` on `messages`), the cron job and a removed block leaving its message on its day), the 0052 push tokens
  (registering a device token takes it from the previous account, in another
  alley too, and leaves other devices' tokens alone; sign-out clears the
  token only while it is still this device's), and the
  0035 assertion (now including `team_colors`, `match_exceptions`, 0050's
  `duty_periods` / `duty_assignments` and 0051's `messages` /
  `message_recipients`) that every table
  `lib/data/providers.dart` streams is in the `supabase_realtime`
  publication; run with `psql … -v ON_ERROR_STOP=1 -f` against the local
  stack (CI does).
