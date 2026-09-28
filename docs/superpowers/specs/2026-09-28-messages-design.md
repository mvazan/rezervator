# Zprávy a nástěnka (messages and notice board)

Requested by the user on 2026-09-28. The app speaks Czech; the user writes Slovak. Migration
`0051_messages.sql` (the canteen duty branch is at 0050 and this builds on its rights:
`is_on_duty()`, `duty_gate(date)`). The branch `messages` starts from `canteen-duty`; once
PR #144 merges it is rebased onto `main`.

## Decided with the user

- **Not a chat.** No threads, no player→player messages. Two kinds of traffic: the admin and
  the player on canteen duty write to players (a block, a day, everyone); a player writes to
  the admins or to today's duty. Recipients answer with a reaction (👍/👎) and one short reply.
  Everything else stays on WhatsApp/phone (Kontakty already offer both).
- **Why in-app at all:** the recipients are computed from the reservations („all players
  booked in the 16:00 block on Friday“) — the admin need not know who is booked or look up
  numbers — the message is tied to a day or block, and the reactions are counted.
- **Reactions are visible to the author and to every recipient** of that message, never
  outside it.
- **E-mail recipients react from the e-mail** through signed one-click links (like the kiosk
  cancel link); a reply in text needs the app.
- **A push tap deep-links** to the message. This is the first in-app handling of a notification
  tap (today the OS only opens the app).
- **Two hub entries:** Klubovna → Nástěnka (the admin's notices, with history) and Klubovna →
  Zprávy (messages to and from me).
- **A player picks the addressee:** „Správci“ or „Službě“ (today's duty).
- **A notice has an optional expiry:** a date, or „do odvolání“.
- **Only the admin posts notices;** the duty writes to a day or block during their duty, from
  today on — the same window as their other rights.
- **The admin sees who has seen a notice** („12 z 40“, and who has not).
- **Attachments later** (images, PDFs — not now, the free Supabase plan has 1 GB of storage).
  The model leaves room for them; see „Attachments“.

## Why

Whoever opens the alley or serves in the canteen sometimes has to tell the booked players
something at short notice: a rental fell through and the 16:00 players may come at 15:00; the
opener is stuck at work and the first block will start late; the alley closes early. Today the
only channel is cancelling a reservation with a note, or WhatsApp — where the sender has to
work out who is booked. The other way round, a player wants to tell the duty „I'll be 20
minutes late“ without hunting for a number. And the admin wants a place for lasting notices
(new lanes, where the spare key is) that every player sees and that stays readable.

## Decisions (trade-offs resolved)

1. **One table for notices and messages.** A notice is a message to everyone with an expiry.
   Recipients, read state, reactions, delivery and the deep link are the same machinery; two
   tables would double the RPCs, the fan-out and the tests. Attachments do not change this —
   they are a one-to-many child table either way.
2. **Recipients are materialised at send time**, from the reservations as they are at that
   moment. History stays true when someone later cancels, and reactions have a fixed set to be
   counted against. Notices get recipient rows too, for push and read receipts; the board
   itself is not recipient-based — every player of the alley sees every notice.
3. **Delivery through the row webhook, immediately** (`notify_webhook` → notify edge
   function, one fan-out call), like „new player“ → all admins today. The queue with retries
   (`notification_jobs`) was rejected: a minute of latency defeats „I'll open late“, and the
   deploy order (migration before function) is a known trap for new job kinds. Delivery stays
   one attempt per recipient, push or e-mail, as for every message today.
4. **Every reaction on a `message` notifies its author** (push or e-mail). For a block of six
   players that is at most six pushes; for a player's question to the admins it is the answer.
   Notices have no reactions.
5. **Read and react are own-row UPDATEs** on `message_recipients` through column grants (the
   `team_colors` / `match_exceptions` pattern), so the app can apply them optimistically.
   Every other write goes through a security-definer RPC, and no table policy is widened for
   the duty — the 0050 rule.
6. **A security-definer helper `can_read_message(id)` drives the read policies.** A policy
   that queries its own table (recipients of the same message) ends in Postgres's „infinite
   recursion detected in policy“; the helper reads past RLS. Accepted consequence: the same
   policy governs `message_recipients_select`, so a participant in a `message` sees every
   other participant's `read_at` as well as their reaction — Postgres RLS is row-level, not
   column-level, so hiding `read_at` from non-admins while keeping reactions visible to
   everyone would need a second table or a view; not worth it here, since `read_at` on a
   `message` is never surfaced by any screen in this design (only a notice's admin-only „Kdo
   si to zobrazil“ reads it, and that path is already admin-gated in the app). Document this
   in the migration's comment on the policy rather than build the extra indirection.
7. **Notices are kept, messages are pruned after 90 days.** The board's history is the point
   of the board; a message about a day is noise three months later.
8. **Sorting follows the app rule:** chronological, past collapsed. Notices by posting date,
   messages by the day they are about. The reaction lists are Czech-sorted.

## Data model (`0051_messages.sql`)

- **`messages`**
  - `id uuid pk`, `tenant_id → tenants cascade`, `author_id → profiles set null`,
    `created_at`, `updated_at`.
  - `kind text` check in (`notice`, `message`).
  - `audience text` check in (`all`, `day`, `block`, `admins`, `duty`).
    - `notice` ⇒ `all`; `message` ⇒ one of the other four.
  - `on_date date`, `block_id uuid → time_blocks set null`: required for `day` (date only)
    and `block` (both); optional for `admins`/`duty` (the training the player writes about,
    display only); null for `all`.
  - `title text` (notice only, 1–80 chars), `body text` (message ≤ 500, notice ≤ 2000, not
    blank). Named CHECKs per kind.
  - `expires_at timestamptz` (notice only; null = „do odvolání“), `notify boolean not null`
    (notice: the admin's choice; message: always true).
  - Index `(tenant_id, kind, created_at)`, `(tenant_id, on_date)`.
- **`message_recipients`**
  - `message_id → messages cascade`, `user_id → profiles cascade`, `tenant_id` (denormalised
    like `duty_assignments`), `read_at`, `reaction text` check in (`up`, `down`) null,
    `reply text` (≤ 200) null, `reacted_at`.
  - Primary key `(message_id, user_id)`; index `(tenant_id, user_id, read_at)`.
  - A BEFORE UPDATE trigger stamps `reacted_at = now()` when `reaction` or `reply` changes,
    and clears it when both are null.
- Both tables join the `supabase_realtime` publication (idempotent DO block as in 0050) and
  `v_streamed` in `supabase/tests/tenancy_rls.sql`.

### Recipients

Computed by `message_send` from the alley's data at that moment, the author always excluded,
players without an account („hráč bez účtu“) and the kiosk always excluded:

| audience | recipients |
|---|---|
| `all` | every approved player of the alley (admins included) |
| `day` | players with a live reservation on `on_date`, any block |
| `block` | players with a live reservation on `on_date` in `block_id` |
| `admins` | every approved admin of the alley |
| `duty` | the assignees of the duty period covering Prague today |

An empty set raises `no_recipients`; `duty` raises `nobody_on_duty` whenever the computed duty
set is empty — no period covers today, or every assignee on it is excluded (placeholder, the
author). The app computes the same sets to grey the option out before the call (it has the
reservations, the roster and the duty assignments). `admins` follows the `players` view's own
rule for who counts as a home member: a visiting superadmin (`is_admin()` true, not of this
alley) is not a recipient.

### Rights (RLS and RPCs)

- **Read.** `can_read_message(p_id uuid) returns boolean` — security definer, stable,
  executable by `authenticated`: true when the message is in my alley and (it is a notice
  and I am an approved non-kiosk player) or (I am its author) or (I have a recipient row).
  - `messages_select`: `can_read_message(id)`.
  - `message_recipients_select`: `can_read_message(message_id)` — so every participant sees
    everyone's reactions.
  - The kiosk reads nothing here.
- **Own row.** `message_recipients_update_own`: `user_id = auth.uid()`; grants: `update
  (read_at, reaction, reply)` to `authenticated` — the `profiles_update_own` pattern (own-row
  UPDATE policy plus a column-scoped GRANT), not `team_colors`/`match_exceptions`, which are
  select-only for `authenticated` and never grant UPDATE at all. Nothing else is granted on
  either table to `anon`/`authenticated` beyond `select`; `service_role` gets all.
- **`message_send(p_kind, p_audience, p_on_date, p_block_id, p_title, p_body, p_expires_at,
  p_notify) returns uuid`** — security definer:
  - `notice`: `is_admin()`.
  - `day` / `block`: `is_admin()`, or the duty via `duty_gate(p_on_date)` (on duty today, date
    from today on). `block_id` must be an active block of the alley (`unknown_block`).
  - `admins` / `duty`: any approved player with an account (admins too).
  - Validates lengths (`body_too_long`, `title_required`), inserts the message and its
    recipients in one transaction, returns the id.
- **`message_update(p_id, p_title, p_body, p_expires_at)`** — notices only, admin. There is no
  „leave unchanged“ sentinel: the form always sends its full current state, so `p_expires_at
  = null` always means „do odvolání“, never „don't touch this field“. „Sejmout“ is the same
  RPC called with `p_expires_at = now()` and the title/body left as they were.
- **`message_delete(p_id)`** — the author or an admin; hard delete, recipients cascade.
- **`prune_messages()`** — service role, daily pg_cron: deletes `kind = 'message'` rows whose
  key day (`on_date`, else `created_at` in Prague) is older than 90 days. Notices stay.
- Every new function: `revoke all … from public, anon`, grant to who needs it; the server-only
  ones to `service_role`.

## Delivery

- Trigger `notify_messages` AFTER INSERT ON `messages` → `notify_webhook()`.
- Trigger `notify_message_reactions` AFTER UPDATE OF `reaction, reply` ON
  `message_recipients` → `notify_webhook()`.
- The notify function gains two branches in `handle()`:
  - **`messages` INSERT:** when `record.notify`, load the recipients joined with
    `profiles(email, fcm_token)` (service role) and `notifyRecipient` each. Sequentially, or in
    small chunks (2 at a time) — not one `Promise.all` over the whole recipient list: Resend's
    free tier rate-limits around 2 requests/second, and a 40-player „all“ notice would trip it
    with no retry (every message send here is fire-and-forget, like today's). Push `data`:
    `{kind: 'message' | 'notice', message_id}`.
  - **`message_recipients` UPDATE:** when the message is a `message` and `reaction` or `reply`
    changed to a non-null value, notify the author: „Reakce na tvou zprávu“, body
    „Petr Novák: 👍 Přijdu dřív“ (reply appended when present). Clearing a reaction sends
    nothing. Push `data`: `{kind: 'message_reaction', message_id}` (deep-links to the
    message).
- The day label these texts use is the spaced Czech form „pá 3. 10.“ (`dutyDayLabel` in
  `_shared/duty_reminders.ts` on the Deno side, and its namesake in `lib/domain/duties.dart` on
  the Flutter side) — not `_shared/format.ts`'s `dayLabel`, which is unspaced („pá 3.10.“), and
  not `lib/core/ui.dart`'s `dayLabel` either. Pull the Deno one out into `_shared/format.ts` as
  a shared export so `message_texts.ts` and `duty_reminders.ts` both use it, rather than
  duplicating it a third time.
- Texts live in `_shared/message_texts.ts` as pure functions with unit tests (the
  `group_messages.ts` template):
  - notice: title = the notice's title; body = the first 120 characters, cut on a word.
  - staff → players: title „Zpráva od správce“ / „Zpráva od služby“; body = the text, then
    the context on its own line: „pá 3. 10. · 16:00–17:00“ or „celý den pá 3. 10.“.
  - player → staff: title „Zpráva od {jméno}“; body = the text, then the context when the
    message carries one („k tréninku ne 5. 10. · 18:00–19:00“).
- **E-mail** (`RESEND_*`, the existing fallback for anyone without a push token, i.e. every web
  user): the full text and context; for a `message` two buttons **👍** and **👎** (signed
  links, next section) and „Odpovědět v aplikaci“ → `https://rezervator.online/#/zpravy/<id>`;
  for a notice „Otevřít nástěnku“ → `/#/nastenka/<id>`.
- Deploy order: the migration lands before the function. The new triggers post webhooks for
  tables the old notify has never seen; the implementation must confirm `handle()` ignores an
  unknown table (returns 200) — if it throws, the triggers are created by a follow-up migration
  after the function deploy.

## Reactions from e-mail

- Link: `<functions>/react?t=<token>`; token = base64url of `{m: message_id, u: user_id,
  r: 'up' | 'down', x: <issued-at epoch ms>}` plus an HMAC with the secret `_shared/cancel_token.ts`
  already uses (the helper is generalised to sign/verify any small payload; the kiosk cancel
  link keeps working).
- New edge function `react` (deployed `--no-verify-jwt`, like `cancel`): verifies the
  signature and expiry (30 days), checks the recipient row still exists, writes `reaction`
  (service role — the reacted-at trigger and the reaction webhook fire as from the app), and
  answers **`Response.redirect(..., 303)` → `https://rezervator.online/reakce.html?ok=1`**; a
  bad, expired or orphaned token → `?ok=0`. This follows `calendar-oauth-callback`'s shape
  (redirect to a static page), not `cancel`'s — `cancel` itself renders an HTML confirm page on
  GET and only acts on POST, precisely because a GET link can be prefetched by a mail scanner;
  `react`'s link is a plain one-click GET with no confirm step, which is an accepted tradeoff
  here (a reaction is harmless and reversible in the app) — say so in the function's header
  comment so it isn't "fixed" into a two-step flow later. The function itself never returns
  HTML (edge-function bodies are served as `text/plain`; the rule stays redirect-to-a-static-
  page, as `calendar-oauth-callback` already does).
- `web/reakce.html`: static page, „Díky, reakce je uložená.“ / „Odkaz už neplatí.“, with a
  link „Otevřít Rezervátor“ → `/#/zpravy`.

## Deep link

- Push `data.kind` ∈ {`message`, `notice`, `message_reaction`} with `message_id`.
- `lib/push/push.dart` gains: `FirebaseMessaging.onMessageOpenedApp` (warm), `getInitialMessage()`
  (cold start), and `onDidReceiveNotificationResponse` for the foreground local notification
  (its payload carries the same data). Each writes a `PendingLink` (`notice` or `message` +
  id) into `pendingLinkProvider`.
- `HomeShell` consumes it once the profile is loaded: pushes `MessageDetailScreen(id)` (or the
  notice detail) and clears the provider; an unknown or deleted id → snack „Zpráva už
  neexistuje.“. Web (no push) never sets it.
- go_router routes `/zpravy/:id` and `/nastenka/:id` for the e-mail links on web and for any
  later Android app-link, plus the bare `/zpravy` and `/nastenka` (what the static result page
  and a plain "open the app" e-mail link point at) — both render the normal screen with nothing
  pre-opened. Every one of the four renders `AuthGate` and seeds `pendingLinkProvider` once
  signed in. This is the first in-app route outside auth/kiosk/public. **Known gap:** today's
  magic-link sign-in on web does not carry a URL fragment across the redirect
  (`AppConfig.authRedirectUrl` is origin + path only, and `authErrorRedirect` only maps auth
  fragments back to `/`) — so a `/zpravy/<id>` link opened signed-out on web lands on the plain
  Zprávy list after sign-in, not the one message. Fixing that (carrying the fragment through
  the redirect and widening the Supabase redirect allow-list) is out of scope for this feature;
  it only affects the signed-out-on-web case, which is rare (most players stay signed in).

## UI

### Hub (Klubovna)

Entries, Czech-alphabetical: Kontakty, Kuželny, **Nástěnka** (icon `campaign_outlined`,
subtitle „Oznámení správce“), Služby, Výsledky, **Zprávy** (icon `forum_outlined`, subtitle
„Zprávy pro tebe a od tebe“). `HubMenu` gets an optional `badge` (count) per entry: Zprávy
shows unread messages, Nástěnka unread notices. The Klubovna destination in the bottom bar /
rail shows a dot when either is non-zero. `HubEntry` is today a Dart record typedef, which has
no notion of an optional field with a default — adding `badge` means either passing `badge:
null` at every existing entry literal (Klubovna's four, and Správa's own `HubMenu` use in
`admin_screen.dart`) or turning `HubEntry` into a small class with a default constructor
value; either is fine, pick whichever touches less of the existing call sites.

### Nástěnka (every player)

- Active notices (not expired) in posting order, oldest first; expired ones collapsed under
  „Starší (N)“ in the same order. Card: title, body (long bodies collapsed to three lines with
  „Více“), footer „vyvěšeno so 28. 9. · platí do 12. 10.“ or „vyvěšeno … · do odvolání“.
- Opening the screen marks the listed active notices read (`read_at`), optimistically.
- Empty: „Na nástěnce zatím nic není.“
- **Admin:** FAB „Nový oznam“ → form: Nadpis (required, ≤ 80), Text (≤ 2000), „Platí do“
  (date picker, default +14 days) with a switch „Do odvolání“ that disables the date, switch
  „Poslat upozornění“ (on). Card ⋮: „Upravit“ (same form), „Kdo si to zobrazil“ (sheet:
  „Zobrazilo 12 z 40“, then „Ještě nezobrazili:“ names Czech-sorted), „Sejmout“ (expire now,
  confirm), „Smazat“ (confirm). The eye count „12 z 40“ also sits in the card footer for the
  admin only.

### Zprávy (every player)

- One list, chronological by the message's key day (`on_date`, else the posting day): today and
  ahead open, earlier collapsed under „Starší (N)“. Read state: opening the screen marks my
  unread received messages read.
- Tile: header „Od služby (Jan Novák)“ / „Od správce (…)“ / „Od Petra Nováka“ / „Ode mě
  správci“ / „Ode mě službě“ / „Ode mě hráčům“, a context chip („pá 3. 10. · 16:00–17:00“,
  „celý den pá 3. 10.“, „k tréninku ne 5. 10. · 18:00“, or none), the body.
- **Received `message`:** two toggle chips 👍 / 👎 and a one-line field „Krátká odpověď…“
  (≤ 200, saved on submit; both optimistic with rollback and a snack on failure). Below:
  „👍 Petra, ty · 👎 Tomáš „nestihnu“ · 1 bez reakce“ — names Czech-sorted, my own as „ty“.
- **Sent:** tally „2× 👍 · 1× 👎 · 3 bez reakce“; tapping expands the per-person list with
  replies. Sent messages can be deleted (⋮ „Smazat“, confirm).
- **Player composer** — FAB „Napsat“ → a sheet with „Správci“ and „Službě“ (the latter
  disabled with „Dnes nikdo neslouží“ when no one serves today, or when I am the only one) →
  text (≤ 500) → „Odeslat“. Success snack „Zpráva odeslána.“.
- **Staff composer** (admin, or the duty on today or later) — FAB „Napsat hráčům“ → date
  (default today; the duty cannot pick a past day) → „Celý den“ or one of the day's blocks,
  each with „Dostane 4 hráči: Jan, Petra, …“ (0 → disabled, „Nikdo nemá rezervaci“) → text →
  „Odeslat“.
- Empty: „Zatím žádné zprávy.“ plus the FAB.

### Entry points elsewhere

- **Kalendář:** the portrait day ⋮ menu gets „Napsat hráčům dne…“; the day-mode block dialog
  (`BlockDialog`, edit — where `existing` is the block being edited) gets „Napsat hráčům
  bloku…“. Opened fresh from the header ＋ there is no block yet to message, so that variant
  does not offer it (the day-level „Napsat hráčům dne…“ already covers that case). Both that
  open the staff composer with the date/block prefilled, under the same gate as the other day
  rights (admin, or the duty from today on).
- **Můj přehled, and the calendar's own-reservation cancel dialog** (they share one confirm,
  `confirmCancelOwnReservation`): both gain „Napsat správci…“ / „Napsat službě…“ next to
  „Zrušit“, opening the player composer with the training as context. The two call sites share
  the dialog, so this is one change, not two; the dialog's existing title/message/button copy
  is unchanged.
- **Detail** (`MessageDetailScreen`): the deep-link target — one tile expanded, with the same
  reactions and reply. On a cold start from a push tap the streams have no data yet: show a
  spinner first, and only turn a missing id into „Zpráva už neexistuje.“ once the first
  snapshot has actually arrived and the id is still absent from it.

### Strings (new, Czech)

Nástěnka, Oznámení správce, Zprávy, Zprávy pro tebe a od tebe, Nový oznam, Nadpis, Text,
Platí do, Do odvolání, Poslat upozornění, Upravit, Kdo si to zobrazil, Zobrazilo {n} z {m},
Ještě nezobrazili:, Sejmout, Smazat, vyvěšeno {den}, platí do {den}, do odvolání, Starší
({n}), Na nástěnce zatím nic není., Napsat, Napsat hráčům, Správci, Službě, Dnes nikdo
neslouží, Celý den, Dostane {n} hráči: …, Nikdo nemá rezervaci, Odeslat, Zpráva odeslána.,
Krátká odpověď…, bez reakce, ty, Od správce, Od služby, Ode mě správci, Ode mě službě, Ode mě
hráčům, k tréninku {den} · {čas}, celý den {den}, Napsat hráčům dne…, Napsat hráčům bloku…,
Napsat správci…, Napsat službě…, Zatím žádné zprávy., Zpráva už neexistuje., Reakce na tvou
zprávu, Zpráva od správce, Zpráva od služby, Zpráva od {jméno}, Odpovědět v aplikaci, Otevřít
nástěnku, Díky, reakce je uložená., Odkaz už neplatí., Otevřít Rezervátor.

## Errors and edge cases

- `friendlyDbError` is one flat map from server code to one Czech sentence, plus a single
  `wasOnDuty` context flag — it cannot hold two different texts for the same code
  (`no_recipients` for a day vs. a block) or override an existing code's text just for this
  feature (`date_past` already means „Tenhle termín už je v minulosti.“ everywhere else). So:
  add `nobody_on_duty` „Dnes nikdo neslouží — napiš správci.“, `body_too_long` „Zpráva je moc
  dlouhá.“, `title_required` „Vyplň nadpis.“ and `body_required` to the shared map (they are
  unambiguous everywhere), and give the two composers their own small `errorText` closures on
  top of `friendlyDbError` for the context-dependent ones: `no_recipients` reads „V tomto bloku
  nikdo nemá rezervaci.“ or „V tento den nikdo nemá rezervaci.“ depending on which the composer
  asked for; the staff composer's `date_past` reads „Minulým dnům už nejde psát.“ instead of
  the generic text; a `not_allowed` from the duty composer still goes through the existing
  `wasOnDuty` handling for „Služba skončila — tohle teď může jen správce.“; `unknown_block`
  keeps its existing text.
- Offline: both screens read from `cachedRows`; reactions and reads are `optimisticWrite`
  with rollback; sending needs the network (`tryAction` snack).
- A recipient who is deleted from the alley disappears from the tallies (cascade); a message
  whose block is later removed keeps its `on_date` and shows the chip without the time.
- Delivery is one attempt per recipient, push or e-mail, as today; no receipts of delivery.
- The duty writing at 23:59 whose duty ends at midnight: the server decides (`duty_gate`), the
  app shows the „Služba skončila“ text on refusal — as everywhere in 0050.

## Attachments (later, not in this plan)

`message_attachments (id, message_id → messages cascade, tenant_id, path, mime, bytes,
created_at)` over a Storage bucket `notices` with per-alley RLS and signed URLs; `message_send`
/ `message_update` accept them for notices only; deletion of a notice removes its objects
through an edge function. Nothing in this design blocks it.

## Testing

- **SQL** (`supabase/tests/tenancy_rls.sql`): rights matrix (admin / duty today / duty on a
  past date / plain player / kiosk / other alley) for each audience; recipient sets for each
  audience with placeholders and the author excluded; `can_read_message` for author, recipient,
  non-recipient, notice, other alley; only a recipient may react, only their own row, only the
  granted columns; `reacted_at` trigger; `message_update` notice-only; `message_delete` by
  author/admin only; `prune_messages` keeps notices and recent messages; `v_streamed`.
- **Deno**: `message_texts.ts` (titles, bodies, 120-char cut on a word, contexts); the token
  sign/verify round trip and tampering; the `react` function (valid → 303 ok=1 and the row
  updated; expired / tampered / orphaned → ok=0, nothing written); the notify branches with a
  mocked sender (fan-out count, `notify = false` sends nothing, a reaction notifies the author
  once, clearing sends nothing). None of this can be tested by importing `react/index.ts` or
  `notify/index.ts` directly — both call `Deno.serve` and build a Supabase client from
  `Deno.env.get(...)!` at module load, which is why no existing test does that. Follow
  `_shared/duty_reminders.ts`'s shape: the actual logic (token check, recipient lookup, text
  building, the send call) lives in `_shared/` functions that take their dependencies as
  parameters (a `send` callback, a `now()` clock, a `recipientExists` check); `index.ts` files
  stay thin wiring that only the deployed function runs.
- New edge functions need the same three-place wiring every existing one has: an entry in
  `supabase/config.toml` (`[functions.react] verify_jwt = false`), a line in the CI workflow's
  `deno check` file list, and a deploy step in the backend deploy workflow — grep for how
  `cancel` appears in `.github/workflows/*.yml` and `SETUP.md`/`CICD.md` and add `react` the
  same way in each place; missing one of them means it type-checks locally but 404s in prod.
- **Flutter** — model rows (`Message`, `MessageRecipient`, and their enums) live in
  `lib/domain/models.dart` next to every other model; the pure logic below goes in
  `lib/domain/messages.dart` (a different file from `lib/core/messages.dart`, which is the
  unrelated snack/overlay helper — a name collision only in spelling, not in import path, but
  worth a one-line doc comment on the new file so nobody merges the two by mistake).
  `lib/domain/messages.dart` (pure, unit-tested): key day and the past/ahead
  split, reaction tallies and Czech-sorted name lists with „ty“, unread counts, the composer's
  recipient preview from reservations/roster/duty, context chip text. Widget tests: Nástěnka
  (player: order, collapse, read marking; admin: form defaults, „Do odvolání“, who-has-seen
  sheet, sejmout/smazat), Zprávy (received: react/reply optimistic + rollback, others'
  reactions; sent: tally and expansion; both composers incl. disabled states), hub badges and
  the Klubovna dot, the deep-link consumer (pending link → detail, unknown id → snack), the
  calendar and Můj přehled entry points and their gating, `friendlyDbError` texts.
- Docs: `docs/SCHEMA.md`, `supabase/schema.sql` snapshot, the changelog batch („Nástěnka a
  zprávy: …“ + `store:` line — a new `Release(null, '<release day>', …)` batch on top, or
  appended to the current unreleased web-only batch if this feature ships before that one is
  cut into a version; the implementer picks whichever is true on the day it lands).

## Out of scope

Threads or replies to replies; player→player messages; editing a sent message; delivery
receipts; muting; attachments (see above); pushing the Klubovna dot to the OS badge.
