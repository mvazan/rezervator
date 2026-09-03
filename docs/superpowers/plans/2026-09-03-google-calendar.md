# Rezervátor — Google Kalendář (plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A player links their Google account once and every live reservation of theirs appears as an event in an app-owned Google calendar "Rezervátor" (created with the narrow `calendar.app.created` scope): booked → event, moved → event re-timed, cancelled → event gone, with optional reminders. The same mechanism as Termínátor (`/Users/mvazan/Home/terminator`), adapted from "starts" to reservations.

**Architecture:** Termínátor's design ported one to one: (1) a tiny job engine (`notification_jobs` + `enqueue_notification`, a pg_cron minute tick that POSTs `{type:"CRON"}` to the existing `notify` edge function through the Vault-configured webhook), (2) two tables split on purpose — `google_calendar_links` (client-visible, Realtime, no secrets) and `google_calendar_tokens` (service-role only), (3) two new edge functions `calendar-oauth-callback` (public GET, Google redirect target) and `calendar-manage` (JWT-verified: disconnect, reminders), plus a `calendar_sync` job handler inside `notify` that RECONCILES one (user, reservation) pair: re-reads reality and upserts or deletes the event whose id is `sha256("<userId>:<reservationId>")` → base32hex[0..32]. User-initiated actions (link, disconnect, reminders) are synchronous; third-party changes (admin moves, cancels, block edits) go through jobs with backoff.

**Tech Stack:** Postgres (pg_cron, pg_net, Vault), Deno edge functions (supabase-js 2.112.4 via `supabase/functions/import_map.json`), Flutter/Riverpod, `url_launcher`. Google Calendar API v3, OAuth code flow with client secret (no PKCE), scope `openid email https://www.googleapis.com/auth/calendar.app.created`.

**Branch:** `google-calendar` from `main` (after PR #60). Migration `0023_google_calendar.sql`.

## Global Constraints

- Czech UI copy, English code/comments. `flutter analyze` clean, `flutter test` green (baseline 368 + 2 from PR #61 = 370). `deno check` + `deno test supabase/functions` green (CI `backend` job also diffs `supabase/schema.sql` — regenerate with `tool/schema_snapshot.sh`).
- No secret ever reaches the app: the client only knows `GOOGLE_CLIENT_ID` (dart-define); the refresh token lives in `google_calendar_tokens` (RLS on, zero policies).
- Copy from Termínátor where the file exists there (paths below) and adapt; do not invent a different mechanism. Every deviation is listed in the contract.
- Commit per task with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`; push + PR at the end. Streams S / F / A run in parallel worktrees with disjoint files; the controller merges, writes SETUP/CICD/privacy docs, runs the gate, opens the PR.
- The Google Cloud side (Calendar API, consent screen, Web OAuth client, `supabase secrets set GOOGLE_CLIENT_ID=… GOOGLE_CLIENT_SECRET=…`, GitHub secret `GOOGLE_CLIENT_ID`) is done by the user after the merge, following SETUP.md; until then the feature is dormant (`AppConfig.hasGoogleCalendar` false → no UI).

---

## Contract (shared by all streams — design against it, flag real problems)

### Database (`supabase/migrations/0023_google_calendar.sql`)

```sql
-- pg_cron: enabled by the migration (idempotent); pg_net already exists (notify_webhook).
create extension if not exists pg_cron;   -- the statement Termínátor 0003 used in prod

create table notification_jobs (
  id bigint generated always as identity primary key,
  kind text not null,                       -- only 'calendar_sync' for now
  dedupe_key text not null unique,          -- 'calendar:<user_id>:<reservation_id>'
  payload jsonb not null default '{}'::jsonb,
  run_at timestamptz not null default now(),
  attempts int not null default 0,
  created_at timestamptz not null default now()
);  -- RLS on, no policies; grant all to service_role; revoke all from anon, authenticated

create table google_calendar_links (
  user_id uuid primary key references profiles (id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'linked', 'broken', 'unlinked')),
  google_email text,
  last_error text,
  reminder_minutes int[] not null default '{}',   -- Calendar API shape, ≤ 5 entries, 0..40320
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);  -- RLS: select own (user_id = auth.uid()); grant select to authenticated (revoke insert/update/delete); all to service_role; alter publication supabase_realtime add table google_calendar_links

create table google_calendar_tokens (
  user_id uuid primary key references profiles (id) on delete cascade,
  refresh_token text not null,
  google_calendar_id text,
  updated_at timestamptz not null default now()
);  -- RLS on, ZERO policies; grant all to service_role only; revoke all from anon, authenticated

create table oauth_nonces (
  nonce text primary key default encode(gen_random_bytes(24), 'hex'),
  user_id uuid not null references profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  consumed_at timestamptz
);  -- server-only like tokens
```

RPCs (all `security definer set search_path = public`; internal ones revoked from `public, anon, authenticated`):

| Function | Who | Behaviour |
|---|---|---|
| `enqueue_notification(p_kind text, p_dedupe_key text, p_payload jsonb, p_delay interval default '3 minutes') returns void` | internal | `insert … on conflict (dedupe_key) do update set run_at = excluded.run_at, payload = excluded.payload` (debounce) |
| `enqueue_calendar_sync(p_user uuid, p_reservation uuid) returns void` | internal | `enqueue_notification('calendar_sync', 'calendar:'‖user‖':'‖reservation, jsonb_build_object('user_id', p_user, 'reservation_id', p_reservation))` |
| `start_calendar_link() returns text` | authenticated | `not_allowed` unless `is_approved()` and the caller's role ≠ 'kiosk'; delete the caller's unconsumed nonces; insert one and return it |
| `consume_calendar_nonce(p_nonce text) returns uuid` | service_role only | one-shot: returns `user_id` and stamps `consumed_at` when unconsumed and younger than 10 minutes, else null |
| `backfill_calendar_jobs(p_user uuid) returns int` | service_role only | enqueue (delay '0 minutes') for every live reservation of the user with `date >= (now() at time zone 'Europe/Prague')::date`; returns the count |
| `set_calendar_reminders_for(p_user uuid, p_minutes int[]) returns int[]` | service_role only | normalise `select distinct … order by desc`, raise `bad_reminders` when > 5 entries or any outside 0..40320, store on the links row (`unknown_link` when none), return the stored array |
| `my_future_reservations(p_user uuid) returns table (reservation_id uuid, date date, starts_at time, ends_at time, lane smallint, alley_name text)` | service_role only | live reservations of the user from Prague-today on, joined `time_blocks` (times) and `tenants` (name), ordered by date, starts_at |
| `trigger_notification_jobs() returns void` | internal (called by cron) | when any job has `run_at <= now()`: read `notify_webhook_config()` (Vault `notify_url` / `webhook_secret`, exactly like `notify_webhook()`; warn + return when missing) and `net.http_post(url, headers {'Content-Type': 'application/json', 'x-webhook-secret': secret}, body '{"type":"CRON","table":"notification_jobs","record":null,"old_record":null}')` |

Triggers producing jobs (only for players whose `google_calendar_links.status = 'linked'`):
- `reservations_enqueue_calendar` AFTER INSERT OR UPDATE ON reservations FOR EACH ROW → `enqueue_calendar_sync(new.player_id, new.id)`; on UPDATE when `old.player_id <> new.player_id` also enqueue for `old.player_id` (the event under the old owner must go).
- `time_blocks_enqueue_calendar` AFTER UPDATE OF starts_at, ends_at ON time_blocks FOR EACH ROW → enqueue for every live future reservation on that block (the weekly template edit re-times reservations without touching their rows — the gap the notify webhook has today).

Cron: `select cron.schedule('notification-jobs', '* * * * *', $$select public.trigger_notification_jobs()$$);` (idempotent guard: unschedule first if a job of that name exists).

Reference SQL to copy/adapt: `/Users/mvazan/Home/terminator/supabase/migrations/0025_notification_jobs.sql` (jobs table 11-23, `enqueue_notification` ~25-40, dispatcher 133-153), `0027_google_calendar.sql` (tables 25-73, `start_calendar_link` 77-96, `consume_calendar_nonce` 100-117, `enqueue_calendar_sync` 159-167, `backfill_calendar_jobs` 261-288), `0030`/`0033` (reminder_minutes + `set_calendar_reminders_for` 17-39, `my_future_starts` 46-73 → `my_future_reservations`), `0034` (final status set). Deviations: Vault-configured webhook instead of a hardcoded URL; reservations instead of rosters/order_slots; the `time_blocks` trigger is new.

### Edge functions (`supabase/functions/`)

- `_shared/google_calendar.ts` — port of Termínátor's `/Users/mvazan/Home/terminator/supabase/functions/_shared/google_calendar.ts`: env `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, test overrides `GOOGLE_CALENDAR_API`, `GOOGLE_TOKEN_ENDPOINT`; `CALENDAR_SUMMARY = "Rezervátor"`, calendar description `"Tvoje tréninky z appky Rezervátor."`, `CALENDAR_TIMEZONE = "Europe/Prague"`; `GoogleAuthError`, `refreshAccessToken`, `exchangeCode`, `emailFromIdToken`, `calendarExists`, `deleteCalendar`, `revokeToken`, `createSecondaryCalendar`, `remindersFor`, `eventIdFor(userId, reservationId)`, `localDateTime(date, time)` (naive `YYYY-MM-DDTHH:MM:SS`, no offset math), `classify(status)` → `ok|auth|gone|retry`, `upsertEvent` (PUT → POST on 404 → re-PUT on 409), `deleteEvent`, and `writeFutureReservations(db, userId, accessToken, calendarId)` (reads `reminder_minutes`, RPC `my_future_reservations`, chunks of 5). Event body builder `reservationEventBody({date, starts_at, ends_at, lane, alley_name}, reminderMinutes)`: `summary: "Trénink · <alley_name>"`, `description: "Dráha <lane>\n\n— spravuje appka Rezervátor, ruční úpravy se přepíšou —"`, `start/end: {dateTime: localDateTime(date, starts_at|ends_at), timeZone: "Europe/Prague"}`, `status: "confirmed"`, reminders from `remindersFor`. No `location`, no colour.
- `calendar-oauth-callback/index.ts` — port of Termínátor's (`--no-verify-jwt`): `REDIRECT_URI = ${SUPABASE_URL}/functions/v1/calendar-oauth-callback`; the flow (error → `zruseno`, missing code/state → `odkaz`, nonce consume, code exchange, refresh_token required, tokens upsert, links `{status:'pending', google_email, last_error:null}` without touching `reminder_minutes`, reuse-or-create the calendar, `status:'linked'`, then `backfill_calendar_jobs` **and** synchronous `writeFutureReservations`; failure → `last_error = 'Kalendář se nepodařilo založit.'`); result is a 302 to `https://mvazan.github.io/rezervator/calendar-linked.html?stav=<ok|zruseno|odkaz|google|kalendar|chyba>`.
- `calendar-manage/index.ts` — port (JWT verified): `POST {"action":"disconnect"}` → `200 {"orphaned":bool}` | `503 {"error":"google_unavailable"}`; `{"action":"reminders","minutes":[…]}` → `200 {"rewritten":n,"saved":[…],"deferred"?:true}` | `400 {"error":"bad_reminders"}`; `400 unknown_action`, `401 unauthorized`, `500 internal`. Disconnect deletes the Google calendar first, revokes second; `invalid_grant` → forget + `orphaned`; retry → 503 untouched. `forget()` deletes the token row and sets `status:'unlinked', google_email:null` (keeps `reminder_minutes`).
- `notify/index.ts` — add: `payload.type === "CRON" && payload.table === "notification_jobs"` → `processJobs()` (≤100 due jobs; calendar jobs `CALENDAR_CONCURRENCY = 5`; success → delete; failure → `attempts + 1`, `run_at = now() + 2**attempts minutes`, dropped at `CALENDAR_MAX_ATTEMPTS = 5`); `jobCalendarSync({user_id, reservation_id})` → `calendarLink(userId)` (status linked + both token columns) → `refreshAccessToken` (`invalid_grant` → `markCalendarBroken` + terminal) → `reservationEvent(userId, reservationId)` (reservation exists, `player_id` matches, `cancelled_at is null`, `date >= pragueToday()`, block found → body; else null ⇒ `deleteEvent`) → `upsertEvent`/`deleteEvent` → `auth` → broken, `gone` → broken ("Kalendář Rezervátor už v Googlu není."), `retry` → false. `markCalendarBroken(userId, reason)` updates `.eq('status','linked')` only, then notifies through the existing `notifyRecipient` path (push when a token exists, else e-mail): title "Google kalendář se odpojil", body "Tréninky se přestaly synchronizovat. Propoj kalendář znovu v Můj profil.", data `{kind:"calendar_broken"}`. Reference: Termínátor `notify/index.ts` 509-743.
- `supabase/config.toml`: `[functions.calendar-oauth-callback] verify_jwt = false`, `[functions.calendar-manage] verify_jwt = true`, both `import_map = "./functions/import_map.json"`. `.github/workflows/deploy-backend.yml`: `supabase functions deploy calendar-oauth-callback --no-verify-jwt` and `supabase functions deploy calendar-manage`. `.github/workflows/ci.yml`: add both `index.ts` to the `deno check` list.
- Deno tests (new, `supabase/functions/_shared/google_calendar_test.ts`, `jsr:@std/assert@1`): `eventIdFor` is deterministic, 32 chars, base32hex charset, differs per reservation; `localDateTime('2026-09-04','16:00:00')` → `2026-09-04T16:00:00`; `classify` mapping; `reservationEventBody` wording and reminders (`useDefault:false`, popup overrides; `[]` → `{useDefault:false, overrides:[]}`).
- Landing page: `web/calendar-linked.html` (Flutter copies `web/` into `build/web`, deployed to Pages under `/rezervator/`), ported from `/Users/mvazan/Home/terminator/docs/calendar-linked.html` with Rezervátor wording per `stav`.

### App (`lib/`)

- `lib/config.dart`: `googleClientId = String.fromEnvironment('GOOGLE_CLIENT_ID')`, `hasGoogleCalendar => googleClientId.isNotEmpty && supabaseUrl.isNotEmpty`, `calendarRedirectUri => '$supabaseUrl/functions/v1/calendar-oauth-callback'`.
- `lib/domain/models.dart`: `enum CalendarLinkStatus { notLinked, pending, linked, broken }` + `parse(String?)` (unknown → `notLinked`), `class CalendarLink { status, googleEmail, lastError, reminderMinutes (sorted desc) }` + `fromJson` + `static const none`, `maxCalendarReminders = 5`, `maxReminderMinutes = 40320`, `reminderOffsetLabel(int)` / `remindersSummary(List<int>)` — port of Termínátor `lib/domain/models.dart:690-770` with the Termínátor Dart tests (`test/domain/calendar_link_test.dart`).
- `lib/data/providers.dart`: `calendarAvailableProvider = Provider<bool>((_) => AppConfig.hasGoogleCalendar)` (overridable in tests); `myCalendarLinkProvider` (Realtime stream of `google_calendar_links` for the uid → `CalendarLink.none` when empty; invalidated on tenant reset like the others); `Api.calendarConsentUrl()` (RPC `start_calendar_link` → `Uri.https('accounts.google.com','/o/oauth2/v2/auth', {client_id, redirect_uri, response_type:'code', scope:'openid email https://www.googleapis.com/auth/calendar.app.created', access_type:'offline', prompt:'consent', state: nonce})`), `Api.disconnectCalendar() → Future<bool> orphaned` (`functions.invoke('calendar-manage', body: {'action':'disconnect'})`), `Api.setCalendarReminders(List<int>)`. A pure `calendarConsentUri({required String nonce})` builder for unit testing.
- `lib/features/profile/profile_screen.dart`: a "Google kalendář" `Card` between the nick card and the sign-out card, shown only when `calendarAvailableProvider` is true and the signed-in profile is not the demo account (`AppConfig.isDemoLogin(me.email)`). Port of Termínátor's `_CalendarLinkTile` + reminders sheet (`lib/features/team/settings_screen.dart:213-457`) into `lib/features/profile/widgets/calendar_link_card.dart`: states notLinked (copy: "Tvoje tréninky se budou samy přidávat do kalendáře „Rezervátor" ve tvém Google účtu." + button "Propojit s Google kalendářem" → `launchWeb(await Api.calendarConsentUrl())` + snack "Dokonči propojení v prohlížeči a vrať se sem."), pending ("Propojuji…"), linked (e-mail, reminders summary, "Připomínky…" sheet with the hours/days segmented unit and the ≤ 4 weeks guard, "Odpojit" with confirm "Kalendář „Rezervátor" se z Googlu smaže i s tréninky. Propojení jde kdykoli obnovit." and the `orphaned` snack), broken (`lastError` + "Propoj ho prosím znovu." + the connect button).
- Workflows: `.github/workflows/release.yml` and `deploy-web.yml` gain `--dart-define=GOOGLE_CLIENT_ID=${{ secrets.GOOGLE_CLIENT_ID }}` (an unset secret = feature dormant).
- Tests: `test/domain/calendar_link_test.dart` (port), `test/data/calendar_consent_test.dart` (URI builder: host/path/scope/state), `test/features/profile_screen_test.dart` (card hidden when unavailable / demo; the four states with `myCalendarLinkProvider` overrides; reminders sheet composes `[1440, 120]`; disconnect confirm copy) with the pure ProviderScope harness (`myProfileProvider`, `clubsProvider`, `calendarAvailableProvider`, `myCalendarLinkProvider`; `PackageInfo` mock as the existing profile test does).

### Docs (controller)

- `docs/SCHEMA.md` (stream S): tables, RPCs, jobs, triggers, cron, "server-only" privilege notes.
- `SETUP.md` new §"Google kalendář" (port of Termínátor SETUP.md 103-165): GCP project = the Firebase project `rezervator-mvazan`; enable Google Calendar API; consent screen External + branding + privacy URL `https://mvazan.github.io/rezervator/privacy.html`; scopes `openid`, `email`, `…/auth/calendar.app.created` (justification text); test users while in Testing (refresh tokens expire after 7 days → weekly re-link until published); Credentials → OAuth client ID → **Web application**, Authorized redirect URI exactly `https://wgwijvcnslkesyqgaeul.supabase.co/functions/v1/calendar-oauth-callback`; `supabase secrets set GOOGLE_CLIENT_ID=… GOOGLE_CLIENT_SECRET=…`; GitHub secret `GOOGLE_CLIENT_ID`; local builds add `--dart-define=GOOGLE_CLIENT_ID=…`; enabling `pg_cron` in the dashboard if the migration cannot.
- `CICD.md`: the two new functions in the deploy list, the secrets, `deno check` entries. `web/privacy.html`: a paragraph on the calendar link (what is stored server-side, the app-created calendar, deletion on disconnect).

---

### Stream S — SQL: migration 0023, tests, snapshot, SCHEMA.md

**Files:** create `supabase/migrations/0023_google_calendar.sql`; modify `supabase/tests/tenancy_rls.sql`, `docs/SCHEMA.md`; regenerate `supabase/schema.sql`.

- [ ] Migration per the contract (copy Termínátor's SQL, adapt names/payloads, Vault dispatcher, the two producer triggers, cron schedule with an unschedule guard).
- [ ] Tests (as tenant A's admin `…0001` unless noted): `start_calendar_link()` returns a 48-hex nonce; a second call replaces it (one unconsumed per user); `reset role` + `consume_calendar_nonce` returns the user once, null the second time, null for a nonce back-dated 11 minutes; `has_table_privilege('authenticated','public.google_calendar_tokens','select')` false, `…google_calendar_links` select true / insert false, `notification_jobs` select false; as service role insert a links row `status='linked'` for A's admin, then `create_reservation` (existing block, future training day) → one `notification_jobs` row `kind='calendar_sync'`, `dedupe_key='calendar:<uid>:<rid>'`, payload ids; cancelling it (`cancel_reservation`) leaves ONE row (dedupe); an unlinked player's booking enqueues nothing; `update time_blocks set starts_at = starts_at + interval '5 minutes'` on the block → a job for the linked player's reservation exists; `backfill_calendar_jobs(uid)` returns ≥ 1; `set_calendar_reminders_for(uid, '{120,1440,120}')` → `{1440,120}`, `'{1,2,3,4,5,6}'` → `bad_reminders`, `'{99999}'` → `bad_reminders`; `my_future_reservations(uid)` returns the reservation with `starts_at`/`ends_at`/`alley_name = 'Kuželna č. 1'`; tenant B sees no links rows; `trigger_notification_jobs()` runs without error (Vault unset locally → warning path); `cron.job` has `notification-jobs`.
- [ ] `tool/schema_snapshot.sh`, `docs/SCHEMA.md`. Verify: `supabase db reset` (local) + `psql … -f supabase/tests/tenancy_rls.sql` → all `OK:` + `ROLLBACK`.

### Stream F — edge functions, config, CI, landing page

**Files:** create `supabase/functions/_shared/google_calendar.ts`, `_shared/google_calendar_test.ts`, `supabase/functions/calendar-oauth-callback/index.ts`, `supabase/functions/calendar-manage/index.ts`, `web/calendar-linked.html`; modify `supabase/functions/notify/index.ts`, `supabase/config.toml`, `.github/workflows/deploy-backend.yml`, `.github/workflows/ci.yml`.

- [ ] Port `_shared/google_calendar.ts` + tests (red → green with `deno test supabase/functions`).
- [ ] Port `calendar-oauth-callback` and `calendar-manage`; `deno check --import-map supabase/functions/import_map.json <all four index.ts>` clean.
- [ ] `notify`: CRON branch, `processJobs`, `jobCalendarSync`, `reservationEvent`, `markCalendarBroken` (via `notifyRecipient`); keep the existing webhook branches untouched.
- [ ] config.toml + workflows + landing page.

### Stream A — app

**Files:** modify `lib/config.dart`, `lib/domain/models.dart`, `lib/data/providers.dart`, `lib/features/profile/profile_screen.dart`, `.github/workflows/release.yml`, `.github/workflows/deploy-web.yml`; create `lib/features/profile/widgets/calendar_link_card.dart`, `test/domain/calendar_link_test.dart`, `test/data/calendar_consent_test.dart`, `test/features/profile_screen_test.dart` (extend if it exists).

- [ ] Config + models + tests.
- [ ] Providers + `Api` + URI test.
- [ ] Profile card + reminders sheet + widget tests.
- [ ] Workflow dart-defines.

### Controller — after the merges

- [ ] SETUP.md §Google kalendář, CICD.md, `web/privacy.html`; `flutter analyze && flutter test`; `deno check`/`deno test`; local `tenancy_rls.sql`; snapshot check; PR.
- [ ] Hand-over to the user: Google Cloud steps (SETUP.md), `supabase secrets set`, GitHub secret `GOOGLE_CLIENT_ID`, rebuild (`build_phone.sh` gains `--dart-define=GOOGLE_CLIENT_ID=…`), then link on the phone and watch `google_calendar_links` flip to `linked` and the events appear.

## Verification

1. Local stack: `supabase db reset` → `tenancy_rls.sql` green; `select jobname from cron.job` shows `notification-jobs`; a booking by a linked user creates a `notification_jobs` row; `deno test supabase/functions` green; `deno check` clean.
2. `flutter analyze && flutter test` green.
3. After the user's Google Cloud setup (prod): Můj profil → Propojit → Google consent → landing page `stav=ok` → the card flips to linked (Realtime) → events for future reservations exist in the "Rezervátor" calendar; book/move/cancel a reservation → the event follows within ~1–4 minutes (3-minute debounce + minute tick); reminders sheet rewrites events; Odpojit deletes the calendar. Break the token (revoke in Google account permissions) → next sync marks `broken` and pushes "Google kalendář se odpojil".
