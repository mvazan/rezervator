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
   itself is not recipient-based — every player of the alley sees every notice — so a notice
   goes up even with no recipient row at all (an alley whose admin is its only account yet).
3. **Delivery through the row webhook, immediately** (`notify_webhook` → notify edge
   function, one fan-out call), like „new player“ → all admins today. The queue with retries
   (`notification_jobs`) was rejected: a minute of latency defeats „I'll open late“, and the
   deploy order (migration before function) is a known trap for new job kinds. Delivery stays
   one attempt per recipient: a push once; an e-mail inside one Resend batch, which is tried
   once more only when Resend answers it busy or down, under the same idempotency key
   (§Delivery).
4. **Every reaction on a `message` notifies its author** (push or e-mail) — while the author
   may still read it (an approved non-kiosk member of its alley). For a block of six players
   that is at most six pushes; for a player's question to the admins it is the answer.
   Notices have no reactions: the server refuses a reaction or a reply on a notice's row.
5. **Read and react are own-row UPDATEs** on `message_recipients` through column grants (the
   `team_colors` / `match_exceptions` pattern), so the app can apply them optimistically.
   Every other write goes through a security-definer RPC, and no table policy is widened for
   the duty — the 0050 rule.
6. **Set-returning security-definer helpers drive the read policies.** A policy that
   queries its own table (recipients of the same message) ends in Postgres's „infinite
   recursion detected in policy“; a security-definer helper reads past RLS. The helpers
   return the *set* of message ids the caller may see (`visible_message_ids()`,
   `visible_recipient_message_ids()`), and each policy asks `id in (select …)` once per
   query: a per-row helper cost ~400 ms for a player's stream of recipient rows at 40
   members × 100 notices, the set ~0.7 ms (messages: ~13 ms → ~0.4 ms at 150 messages).
   `can_read_message(id)` stays as the per-id form of the messages rule. Recipient rows are
   narrower than messages: a notice's rows are its owner's and the admins' („Kdo si to
   zobrazil“ — who has seen it is the admin's to know, not every member's); a `message`'s
   rows are its author's and its recipients' (the reactions). A participant in a `message`
   therefore also sees the others' `read_at` — RLS is row-level, not column-level, and
   hiding `read_at` there would need a second table or a view; not worth it, since no screen
   shows a message's reads.
7. **Notices are kept, messages are pruned after 90 days.** The board's history is the point
   of the board; a message about a day is noise three months later.
8. **Sorting follows the app rule:** chronological, past collapsed. Notices by posting date,
   messages by the day they are about. The reaction lists are Czech-sorted.

## Data model (`0051_messages.sql`)

- **`messages`**
  - `id uuid pk`, `tenant_id → tenants cascade`, `author_id → profiles set null`,
    `created_at`, `updated_at`.
  - `author_role text not null` check in (`admin`, `player`): a snapshot of the sender's
    `profiles.role` at send time. Players cannot read other profiles, so the app's tile
    header („Od správce“ / „Od služby“) and notify's title („Zpráva od správce“ / „Zpráva od
    služby“) are labelled from it — and a later promotion or demotion does not relabel old
    messages.
  - `kind text` check in (`notice`, `message`).
  - `audience text` check in (`all`, `day`, `block`, `admins`, `duty`).
    - `notice` ⇒ `all`; `message` ⇒ one of the other four.
  - `on_date date`, `block_id uuid → time_blocks set null`: required for `day` (date only)
    and `block` (both); optional for `admins`/`duty` (the training the player writes about,
    display only); null for `all`.
  - `title text` (notice only, 1–80 chars), `body text` (message ≤ 500, notice ≤ 2000, not
    blank). Named CHECKs per kind. Every length here is Postgres' `char_length` — code
    points, not what the screen shows (👍🏽 is two) — so the app counts runes
    (`serverLength` in `lib/domain/messages.dart`), not `TextField.maxLength`'s graphemes.
  - `expires_at timestamptz` (notice only; null = „do odvolání“), `notify boolean not null`
    (notice: the admin's choice; message: always true).
  - Index `(tenant_id, kind, created_at)`, `(tenant_id, on_date)`.
- **`message_recipients`**
  - `message_id → messages cascade`, `user_id → profiles cascade`, `tenant_id` (denormalised
    like `duty_assignments`), `read_at`, `reaction text` check in (`up`, `down`) null,
    `reply text` (≤ 200) null, `reacted_at`.
  - Primary key `(message_id, user_id)`; index `(tenant_id, user_id, read_at)`.
  - A BEFORE UPDATE trigger stamps `reacted_at = now()` when `reaction` or `reply` changes,
    and clears it when both are null; a reaction or a reply on a notice's row it refuses
    with `not_allowed` (notices have no reactions).
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

A message to an empty set raises `no_recipients`; `duty` raises `nobody_on_duty` whenever the
computed duty set is empty — no period covers today, or every assignee on it is excluded
(placeholder, pending, the author). A notice to an empty set goes up with no recipient rows
(Decision 2: the board is not recipient-based). The app computes the same sets to grey the
option out before the call (it has the reservations, the roster and the duty assignments). `admins` follows the `players` view's own
rule for who counts as a home member: a visiting superadmin (`is_admin()` true, not of this
alley) is not a recipient.

### Rights (RLS and RPCs)

- **Read.** Nothing at all unless I am an approved non-kiosk member of the message's alley
  (an account later set as the kiosk or back to pending loses what it once got). Security
  definer, stable, executable by `authenticated`; both policies lead with
  `tenant_id = (select current_tenant_id())`:
  - `can_read_message(p_id uuid) returns boolean`: the message is in my alley and it is a
    notice, or I am its author, or I have a recipient row. `visible_message_ids() returns
    setof uuid` is the same rule as a set.
  - `messages_select`: `id in (select visible_message_ids())` — a notice to every member, a
    message to its author and its recipients.
  - `message_recipients_select`: my own row, or `message_id in (select
    visible_recipient_message_ids())`, which holds a notice for the alley's admins and a
    `message` for its author and its recipients. So on a notice a player sees her own row
    only and the admin sees every row („Kdo si to zobrazil“); on a `message` its author and
    every recipient see everyone's reactions; a bystander sees none of them.
  - The kiosk reads nothing here.
- **Own row.** `message_recipients_update_own`: `user_id = auth.uid()` while an approved
  non-kiosk member; grants: `update (read_at, reaction, reply)` to `authenticated` — the `profiles_update_own` pattern (own-row
  UPDATE policy plus a column-scoped GRANT), not `team_colors`/`match_exceptions`, which are
  select-only for `authenticated` and never grant UPDATE at all. `authenticated` gets
  `select` on both tables and that column-scoped `update` on `message_recipients`, nothing
  more; `anon` gets nothing; `service_role` gets all. A notice's row takes a read only: the
  BEFORE UPDATE trigger answers a reaction or a reply on it with `not_allowed` (notices have
  no reactions).
- **`message_send(p_kind, p_audience, p_on_date, p_block_id, p_title, p_body, p_expires_at,
  p_notify) returns uuid`** — security definer. The caller must be an approved member of
  the alley with an account, not the kiosk (`not_allowed`); then:
  - `notice`: `is_admin()` (`not_allowed`), audience `all` (`invalid_audience`), a title
    (`title_required`) of at most 80 characters (`title_too_long`).
  - `day` / `block`: `is_admin()`, or the duty via `duty_gate(p_on_date)` (on duty today, date
    from today on — `not_allowed` / `date_past`); a missing `p_on_date` is `date_past` too.
    For `block` the block must be an active block of the alley, or a day-only block (one
    `add_special_block` left with `active = false`) that `day_overrides.block_ids` names for
    that date (`unknown_block`).
  - `admins` / `duty`: any approved player with an account (admins too). `p_on_date` /
    `p_block_id` are optional context there; the block only has to be the alley's
    (`unknown_block`).
  - Any other audience of a message is `invalid_audience`; any other kind `invalid_kind`.
  - Trims the title and body of any whitespace (newlines and tabs too) and stores them so;
    validates the trimmed values (`title_required`, `title_too_long`, `body_required`,
    `body_too_long` — every length in code points, see Data model), inserts the message and
    its recipients in one transaction, returns the id.
- **`message_update(p_id, p_title, p_body, p_expires_at)`** — notices only, admin. There is no
  „leave unchanged“ sentinel: the form always sends its full current state, so `p_expires_at
  = null` always means „do odvolání“, never „don't touch this field“. „Sejmout“ is the same
  RPC called with `p_expires_at = now()` and the title/body left as they were. Title and
  body trimmed and checked as in `message_send` (`title_required`, `title_too_long`,
  `body_required`, `body_too_long`). Not an admin → `not_allowed`; a message, another
  alley's notice or an unknown id → `unknown_message`.
- **`message_delete(p_id)`** — the caller must be an approved non-kiosk member
  (`not_allowed`); not the author and not an admin, or an unknown id (another alley's
  included) → `unknown_message`. Hard delete, recipients cascade.
- **`prune_messages()`** — service role, daily pg_cron: deletes `kind = 'message'` rows whose
  key day (`on_date`, else `created_at` in Prague) is older than 90 days. Notices stay.
- Every new function: `revoke all … from public, anon`, grant to who needs it; the server-only
  ones to `service_role`.

## Delivery

- Trigger `notify_messages` AFTER INSERT ON `messages` → `notify_webhook()`.
- Trigger `notify_message_reactions` AFTER UPDATE OF `reaction, reply` ON
  `message_recipients`, `WHEN (old.reaction IS DISTINCT FROM new.reaction OR old.reply IS
  DISTINCT FROM new.reply)` → `notify_webhook()`. A read (`read_at` alone) and a no-op
  write (the same 👍 clicked twice in the e-mail) never reach pg_net. **Accepted:** no
  throttle — a recipient flipping 👍 → 👎 → 👍 notifies the author once per flip (a push,
  or a Resend e-mail); the spec wants every reaction told, and the abuse is bounded to
  authors of messages the flipper received, in her own alley.
- The notify function gains two branches in `handle()`:
  - **`messages` INSERT:** when `record.notify`, load the recipients joined with
    `profiles(email, fcm_token)` (service role; a failed load is logged and answers 500,
    never read as „nobody to tell“) and deliver (`deliverMessage` in
    `_shared/message_notify.ts`):
    - Pushes go one at a time — not one `Promise.all` over the whole recipient list.
    - E-mails go as Resend `/emails/batch` requests of at most 100 (`_shared/resend.ts`) —
      one request per batch, not per recipient, so a 40-player „all“ notice to web users
      cannot trip Resend's per-second rate limit and the fan-out ends inside pg_net's 5 s.
      Each batch goes under the `Idempotency-Key` `message/<id>/<n>`; a batch answered
      429/5xx is retried once after a second under the same key, so a batch Resend accepted
      just before a gateway answered 5xx is never sent twice.
    - A batch refused as invalid (400/422 — Resend's strict validation fails a whole batch
      over one bad address) goes out one by one, 500 ms apart, each under
      `message/<id>/<n>/<j>`: a busy single is tried once more after a second, a refused one
      is logged and the rest still go. A refusal that is not about the address before any
      single went through stops the fallback, logged once: every other one would be refused
      the same. `resendOneOfBatch` reads it as „refused“: a 401, a bad key or a request
      refused whole (Resend's error names), or a malformed sender — which Resend answers as
      a 400 `validation_error` whose message names `from` (and not `to`), with no name of
      its own. Rare and slow on purpose (~50 s for a full batch, inside the
      function's wall clock; pg_net logs its own 5 s timeout for that webhook).
    - A recipient whose push or signed links fail, or a batch that throws, is logged and
      skipped; the others still get theirs.
    - `kind = 'message'` without `CANCEL_TOKEN_SECRET` fails closed (500) before any
      delivery: its 👍/👎 links cannot be signed. Notices still go.
    - Push `data`: `{kind: 'message' | 'notice', message_id, tenant_id}` — the alley, for
      the app's deep-link guard.
  - **`message_recipients` UPDATE:** when the message is a `message` and `reaction` or `reply`
    changed to a non-null value, notify the author: „Reakce na tvou zprávu“, body
    „Petr Novák: 👍 Přijdu dřív“ (reply appended when present). Clearing a reaction sends
    nothing, and so does a reaction on a notice. Only an author who may still read the
    message hears it — an approved non-kiosk member of its alley (`_shared/membership.ts`'s
    `isMemberOf`, react's own rule); one set as the kiosk, back to pending or moved to
    another alley gets nothing. Push `data`: `{kind: 'message_reaction', message_id,
    tenant_id}` (deep-links to the message).
- The day label these texts use is the spaced Czech form „pá 3. 10.“ (`dutyDayLabel` in
  `_shared/duty_reminders.ts` on the Deno side, and its namesake in `lib/domain/duties.dart` on
  the Flutter side) — not `_shared/format.ts`'s `dayLabel`, which is unspaced („pá 3.10.“), and
  not `lib/core/ui.dart`'s `dayLabel` either. Pull the Deno one out into `_shared/format.ts` as
  a shared export so `message_texts.ts` and `duty_reminders.ts` both use it, rather than
  duplicating it a third time.
- Texts live in `_shared/message_texts.ts` as pure functions with unit tests (the
  `group_messages.ts` template):
  - notice: title = the notice's title; body = the first 120 characters, cut on a word.
  - staff → players: title „Zpráva od správce“ / „Zpráva od služby“ (by `author_role`);
    body = the text, then the context on its own line: „pá 3. 10. · 16:00–17:00“ or „celý
    den pá 3. 10.“.
  - player → staff: title „Zpráva od hráče: {jméno}“; body = the text, then the context
    when the message carries one („k tréninku ne 5. 10. · 18:00–19:00“). The title goes by
    `author_role`, not by the audience: the duty is a player here too.
  - admin → staff („Správci“ / „Službě“): title „Zpráva od správce ({jméno})“, e.g.
    „Zpráva od správce (Adam Správce)“ — the tile's „Od správce (…)“ header; body as for a
    player (see Copy decisions).
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
  signature and expiry (30 days), checks the recipient row still exists and its account may
  still react (an approved non-kiosk member of the row's alley — the app's
  `message_recipients_update_own` rule, which the service role bypasses; `mayReact` in
  `_shared/react_handler.ts`), writes `reaction`
  (service role — the reacted-at trigger and the reaction webhook fire as from the app), and
  answers **`Response.redirect(..., 303)` → `https://rezervator.online/reakce.html?ok=1`**; a
  bad, expired or orphaned token, a recipient set as the kiosk, back to pending or moved to
  another alley, or a database error → `?ok=0`. A missing `CANCEL_TOKEN_SECRET` → 500 (fail
  closed), logged.
- **Only GET writes.** HEAD — what a link scanner or mail gateway probes with — verifies the
  token alone (a pure HMAC) and answers the same 303 (`ok=1` for a valid token, `ok=0`
  otherwise) without touching the database; any other method → 405 with `Allow: GET, HEAD`,
  nothing written.
- The redirect follows `calendar-oauth-callback`'s shape
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

- Push `data.kind` ∈ {`message`, `notice`, `message_reaction`} with `message_id` and
  `tenant_id` (the alley the push was sent for).
- `lib/push/push.dart` gains: `FirebaseMessaging.onMessageOpenedApp` (warm), `getInitialMessage()`
  (cold start), and `onDidReceiveNotificationResponse` for the foreground local notification
  (its payload carries the same data). Each publishes a `PendingLink` (`notice` or `message` +
  id + the push's `tenant_id`; `message_reaction` opens the message) onto
  `PendingLinkSource` — `Push.init()` runs before any `ProviderScope` — which
  `pendingLinkProvider` takes up (a cold-start tap waits in a one-slot „initial“ value). A
  malformed payload (a non-string id) opens nothing.
- `HomeShell` listens to `pendingLinkProvider` with `fireImmediately` — a link can already be
  waiting when it mounts (a cold-start tap, or a `/zpravy/:id` route seeded before sign-in) —
  and `AuthGate` builds it only once the profile is loaded. After the frame it clears the
  link and opens it:
  - a message → `MessageDetailScreen(id)`;
  - a notice → `NoticeBoardScreen` (notices have no per-item page: every notice is listed on
    the board). The snack „Oznámení už neexistuje.“ (a message's page says „Zpráva už
    neexistuje.“) comes only when the loaded board lacks the id and the server
    (`Api.messageExists`, the RLS-scoped `messages` table) confirms it is gone; anything
    unanswerable (offline) stays silent.
  - **Tenant guard:** a link whose `tenant_id` is not the signed-in profile's alley (a
    superadmin visiting elsewhere, an account moved since) is dropped without a word — no
    screen, no snack: this alley's RLS cannot see it, and „Zpráva už neexistuje.“ / „Oznámení
    už neexistuje.“ would be wrong. An e-mail link carries no alley; RLS decides what shows.
  - **Sign-out** (`AuthChangeEvent.signedOut`, in `AuthGate`) clears `pendingLinkProvider`
    and the cold-start slot, so a link waiting for one account never opens for the next.
  - Web (no push) never publishes one.
- go_router routes `/zpravy/:id` and `/nastenka/:id` for the e-mail links on web and for any
  later Android app-link, plus the bare `/zpravy` and `/nastenka` (what the static result page
  and a plain "open the app" e-mail link point at) — the bare two are the plain app
  (`AuthGate`, nothing opened). The two with an id render `AuthGate` under `DeepLinkSeed`,
  which seeds `pendingLinkProvider`; `HomeShell` opens it once signed in. This is the first
  in-app route outside auth/kiosk/public. **Known gap:** today's
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
shows unread messages, Nástěnka unread notices (an expired notice left unread does not
count: the board marks only the active ones read, so it could never clear). The Klubovna
destination in the bottom bar / rail shows a dot when either is non-zero, and a screen
reader hears the count with the tab's name. `HubEntry` is today a Dart record typedef, which
has no notion of an optional field with a default — adding `badge` means either passing `badge:
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
  „Zobrazilo 12 z 40“, then „Ještě nezobrazili:“ names Czech-sorted; a spinner until the rows
  load, the error text if they fail), „Sejmout“ (active notices only; expire now, confirm —
  sends the notice as it stands at the confirm, so an edit that arrived meanwhile is kept),
  „Smazat“ (confirm). The eye count „12 z 40“ also sits in the card footer for the admin
  only. The outcome snacks show on the page, so they still appear when the stream removed
  the card first.

### Zprávy (every player)

- One list, chronological by the message's key day (`on_date`, else the posting day): today and
  ahead open, earlier collapsed under „Starší (N)“. Read state: opening the screen marks my
  unread received messages read.
- Tile: header „Od služby (Jan Novák)“ / „Od správce (…)“ / „Od hráče: Petr Novák“ (by the
  author's role, so an admin writing to the staff is „Od správce (…)“; names are never
  inflected — see Copy decisions) / „Ode mě správci“ / „Ode mě službě“ / „Ode mě
  hráčům“, a context chip („pá 3. 10. · 16:00–17:00“, „celý den pá 3. 10.“, „k tréninku ne
  5. 10. · 18:00–19:00“, or none), the body.
- **Received `message`:** two toggle chips 👍 / 👎 (`FilterChip`s named by their emoji, with
  a selected state a screen reader announces; tapping my current reaction clears it) and a
  one-line field „Krátká odpověď…“ (≤ 200, saved on submit; both optimistic with rollback
  and a snack on failure; the field follows my stored reply unless I am typing, a reply of
  mine is still out, or it holds an unsent draft — what I typed stays there until its own
  write goes through, so a failed reply is kept for another try). Below: „👍 Petra, ty · 👎 Tomáš „nestihnu“ · 💬 Jan „přijdu později“ · 1
  bez reakce“ — the groups in the order 👍, 👎, 💬 (a reply without a chip is an answer,
  not „bez reakce“), bez reakce; names Czech-sorted within a group, my own last as „ty“, a
  reply quoted after its name.
- **Sent:** tally „2× 👍 · 1× 👎 · 1× 💬 · 3 bez reakce“ — the same order and buckets, a
  zero group left out, no „bez reakce“ once everybody answered. The tally is a button
  (full tap height, announces expanded/collapsed) that expands the per-person list with
  replies. Sent messages can be deleted (⋮ „Smazat“, confirm).
- **Player composer** — FAB „Napsat“ → a sheet with „Správci“ and „Službě“ (the latter
  disabled with „Dnes nikdo neslouží“ when no one serves today, or when I am the only one) →
  text (≤ 500) → „Odeslat“.
- **Both composers send from inside the sheet:** „Odeslat“ runs with the sheet's own
  context (never the caller's — Zprávy's FABs step aside while the keyboard is up) and waits
  while a send is under way, so one tap is one message. Success closes the sheet and the
  page says „Zpráva odeslána.“; a refusal shows over the sheet and keeps the text for
  another try; the outcome is still told if the sheet was swiped away meanwhile. The sheet
  ends above the keyboard and scrolls; „Odeslat“ is off while the text is over 500 code
  points (the counter says „502/500“).
- **Staff composer** (admin, or the duty on today or later) — FAB „Napsat hráčům“ → date
  (default today; the duty cannot pick a past day) → „Celý den“ or one of the day's blocks,
  each with „Dostane 4 hráči: Jan, Petra, …“ (0 → disabled, „Nikdo nemá rezervaci“) → text →
  „Odeslat“. While the reservations and the roster are still loading no target shows a
  count and „Odeslat“ waits; a prefilled block that turns out empty stays selected,
  disabled, and cannot be sent.
- Empty: „Zatím žádné zprávy.“ plus the FAB.

### Entry points elsewhere

- **Kalendář:** the portrait day ⋮ menu gets „Napsat hráčům dne…“; the day-mode block dialog
  (`BlockDialog`, edit — where `existing` is the block being edited) gets „Napsat hráčům
  bloku…“. Opened fresh from the header ＋ there is no block yet to message, so that variant
  does not offer it (the day-level „Napsat hráčům dne…“ already covers that case). Both that
  open the staff composer with the date/block prefilled, under the same gate as the other day
  rights (admin, or the duty from today on). In the dialog „Napsat hráčům bloku…“ is off
  while the block's times have unsaved changes (opening the composer would drop them).
  Messaging is not editing, so the edit guards do not take it away:
  - a past day's ⋮ (otherwise no edits) offers the admin „Napsat hráčům dne…“ alone; the
    duty gets no ⋮ there (`duty_gate` refuses a past day);
  - a refused block edit — the admin on a past day („Minulé dny nelze upravovat.“), the
    duty on a block already under way today — offers „Napsat hráčům bloku…“ as the action
    on its snack, which still goes away on its own (`persist: false`, so later snacks do
    not queue behind it) and does nothing once the calendar is gone. The duty on a past day
    gets the plain snack.
- **Můj přehled, and the calendar's own-reservation cancel dialog** (they share one confirm,
  `confirmCancelOwnReservation`): both gain „Napsat správci…“ / „Napsat službě…“ next to
  „Zrušit“ (the latter only while someone else with an account serves today), opening the
  player composer with the training as context and that addressee picked. The two call sites share
  the dialog, so this is one change, not two; the dialog's existing title/message/button copy
  is unchanged.
- **Detail** (`MessageDetailScreen`): the deep-link target — one tile expanded (a sent
  message's per-person list open, where a „Reakce na tvou zprávu“ push lands), with the
  same reactions and reply; my unread row is marked read on open. On a cold start from a
  push tap the streams have no data yet: a spinner until every stream has loaded. A loaded
  snapshot without the id proves nothing by itself (the cache replays first, and the
  message is usually newer than it), so the screen asks the server (`Api.messageExists`,
  RLS-scoped) — no fixed timer: gone → snack „Zpráva už neexistuje.“ and back to where the
  link opened from; still there → spinner until the stream catches up; unreachable
  (offline) → the error text with „Zkusit znovu“. A message deleted from this screen says
  „Zpráva smazána.“, never „Zpráva už neexistuje.“.

### Strings (new, Czech)

Nástěnka, Oznámení správce, Zprávy, Zprávy pro tebe a od tebe, Nový oznam, Nadpis, Text,
Platí do, Do odvolání, Poslat upozornění, Upravit, Kdo si to zobrazil, Zobrazilo {n} z {m},
Ještě nezobrazili:, Sejmout, Smazat, vyvěšeno {den}, platí do {den}, do odvolání, Starší
({n}), Na nástěnce zatím nic není., Napsat, Napsat hráčům, Správci, Službě, Dnes nikdo
neslouží, Celý den, Dostane {n} hráči: …, Nikdo nemá rezervaci, Odeslat, Zpráva odeslána.,
Krátká odpověď…, bez reakce, ty, Od správce, Od služby, Od hráče: {jméno}, Ode mě správci,
Ode mě službě, Ode mě hráčům, k tréninku {den} · {čas}, celý den {den}, Napsat hráčům dne…,
Napsat hráčům bloku…, Napsat správci…, Napsat službě…, Zatím žádné zprávy., Zpráva už
neexistuje., Oznámení už neexistuje., Reakce na tvou zprávu, Zpráva od správce, Zpráva od
služby, Zpráva od hráče: {jméno}, Zpráva od správce ({jméno}), Odpovědět v aplikaci, Otevřít nástěnku, Díky, reakce je
uložená., Odkaz už neplatí., Otevřít Rezervátor., {n}× 👍, {n}× 👎, {n}× 💬 (and 💬 opening the
reply-only group of the reaction line), Nadpis je moc dlouhý., Odpověď je moc dlouhá.

Shipped with the plan besides these (dialogs, outcomes and error texts, quoted as the code
has them): Upravit oznam, Platí do: {den}, Oznam vyvěšen., Oznam uložen., Sejmout oznam?,
Oznam přestane platit hned., Oznam sejmut., Smazat oznam?, Tohle nejde vrátit zpět., Oznam
smazán., Smazat zprávu?, Zmizí i všem příjemcům., Zpráva smazána., Zpráva, Text zprávy,
K tréninku {den} · {čas}, Změnit, Více, Méně, Nikdo nemá rezervaci., Dnes nikdo neslouží —
napiš správci., V tomto bloku nikdo nemá rezervaci., V tento den nikdo nemá rezervaci.,
Minulým dnům už nejde psát., Jiného správce tu nemáš., Vyplň nadpis., Vyplň zprávu., Zpráva
je moc dlouhá., Neplatný typ zprávy. The length counters („502/500“) are digits only.

## Errors and edge cases

- `friendlyDbError` is one flat map from server code to one Czech sentence, plus a single
  `wasOnDuty` context flag — it cannot hold two different texts for the same code
  (`no_recipients` for a day vs. a block) or override an existing code's text just for this
  feature (`date_past` already means „Tenhle termín už je v minulosti.“ everywhere else). So
  the shared map gets the codes that read the same everywhere:
  - `nobody_on_duty` „Dnes nikdo neslouží — napiš správci.“
  - `no_recipients` „Nikdo nemá rezervaci.“ (the generic text)
  - `title_required` „Vyplň nadpis.“, `title_too_long` „Nadpis je moc dlouhý.“
  - `body_required` „Vyplň zprávu.“, `body_too_long` „Zpráva je moc dlouhá.“
  - `message_recipients_reply_check` „Odpověď je moc dlouhá.“ — the reply is a plain row
    UPDATE, no RPC, so PostgREST's refusal names the CHECK
  - `unknown_message` „Zpráva už neexistuje.“ (`message_update` / `message_delete` on a
    message that is gone, not the caller's to delete, or of another alley)
  - `invalid_audience` and `invalid_kind` „Neplatný typ zprávy.“ (the app's own composers
    never send either)
- The staff composer has its own `errorText` on top of `friendlyDbError` for the
  context-dependent ones: `no_recipients` reads „V tomto bloku nikdo nemá rezervaci.“ or „V
  tento den nikdo nemá rezervaci.“ depending on which the composer asked for; `date_past`
  (a past day, and a missing date) reads „Minulým dnům už nejde psát.“ instead of the
  generic text; a `not_allowed` sent as the duty still goes through the existing `wasOnDuty`
  handling for „Služba skončila — tohle teď může jen správce.“; `unknown_block` keeps its
  existing text. The player composer has its own `errorText` too
  (`playerSendErrorText`): `no_recipients` to „Správci“ (the writer is the alley's only
  admin) reads „Jiného správce tu nemáš.“ (see Copy decisions); every other code keeps the
  shared text.
- Lengths are checked before the server sees them, in code points as the server counts
  (Data model): „Odeslat“ / „Uložit“ is off and the counter turns to the error colour while
  a field is over its limit, and a reply over 200 is not sent. The server's codes stay the
  enforcement.
- Offline: both screens read from `cachedRows`; reactions and reads are `optimisticWrite`
  with rollback; sending needs the network (its refusal shows over the sheet).
- A recipient who is deleted from the alley disappears from the tallies (cascade); a message
  whose block is later removed keeps its `on_date` and shows the chip without the time.
- Delivery is one attempt per recipient (§Delivery: a push once, an e-mail batch retried
  once only when Resend answers it busy or down); no receipts of delivery.
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
  non-recipient, notice, other alley; recipient rows (a notice: own row for a player, every
  row for the admin; a message: every row for its author and recipients, none for a
  bystander or another alley); only a recipient may react, only their own row, only the
  granted columns, never on a notice; `reacted_at` trigger; `message_update` notice-only; `message_delete` by
  author/admin only; `prune_messages` keeps notices and recent messages; `v_streamed`. Also:
  a notice in an alley with no other member goes up with no recipient rows while a message
  there is `no_recipients`; every error code, `title_too_long` counted in code points in
  both RPCs; a day-only block counting on the date its override names; the admin writing to
  a past day and block; the two notify triggers' exact shape (the reaction trigger's
  `WHEN`).
- **Deno**: `message_texts.ts` (titles, bodies, 120-char cut on a word, contexts); the token
  sign/verify round trip and tampering; the `react` function (valid → 303 ok=1 and the row
  updated; expired / tampered / orphaned, or a recipient who may no longer react → ok=0,
  nothing written; HEAD → the same 303 with no lookup or write; any other method → 405);
  `resend.ts` against a fake fetch (headers, `Idempotency-Key` only when given, the verdict
  mapping); the notify branches with a mocked sender (fan-out count, `notify = false` sends
  nothing, push data with `tenant_id`, one batch key per 100 e-mails reused by its retry,
  an invalid batch going out one by one, a reaction notifies the author once and only while
  the author may still read it, clearing sends nothing). None of this can be tested by importing `react/index.ts` or
  `notify/index.ts` directly — both call `Deno.serve` and build a Supabase client from
  `Deno.env.get(...)!` at module load, which is why no existing test does that. Follow
  `_shared/duty_reminders.ts`'s shape: the actual logic (token check, recipient lookup, text
  building, the send call) lives in `_shared/` functions that take their dependencies as
  parameters (a `send` callback, a `now()` clock, a `recipientMayReact` check); `index.ts` files
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
  the Klubovna dot, the deep-link consumer (pending link → detail, a notice → the board,
  unknown id → snack only once the server says so, another alley's link dropped, sign-out
  clearing the link), the
  calendar and Můj přehled entry points and their gating, `friendlyDbError` texts.
- Docs: `docs/SCHEMA.md`, `supabase/schema.sql` snapshot, the changelog batch („Nástěnka a
  zprávy: …“ + `store:` line — a new `Release(null, '<release day>', …)` batch on top, or
  appended to the current unreleased web-only batch if this feature ships before that one is
  cut into a version; the implementer picks whichever is true on the day it lands).

## Copy decisions

Three texts first shipped as open questions; the user settled them on 2026-09-29. None of
them changes behaviour:

1. **The player-message header.** A message from a player to the staff reads „Od hráče:
   Petr Novák“ on the tile (`headerLabel`) and „Zpráva od hráče: Petr Novák“ in the
   push/e-mail title (`playerMessageText`). Names are never inflected (automatic Czech
   declension of arbitrary names is unreliable) — the colon form needs none. This spec first
   wrote the inflected „Od Petra Nováka“, and the first build shipped „Od Petr Novák“.
   The form goes by the author (`author_role`), not by the audience: an admin may write to
   „Správci“ or „Službě“ too, and their message reads „Od správce (Adam)“ on the tile and
   „Zpráva od správce (Adam)“ in the push/e-mail title (`adminToStaffMessageText`): to
   the staff the title names the admin, as the tile does. The first build shipped the
   player title for it, the next one the nameless „Zpráva od správce“. To players the
   titles stay „Zpráva od správce“ / „Zpráva od služby“, no name.
2. **A sole admin writing to „Správci“.** When the writer is the alley's only admin,
   „Správci“ is still offered, and the send is refused with `no_recipients`; the player
   composer says „Jiného správce tu nemáš.“ (`playerSendErrorText`), not the generic
   „Nikdo nemá rezervaci.“, which speaks of reservations. The first build shipped the
   generic text.
3. **A notice link to a notice that is gone** says „Oznámení už neexistuje.“ on the opened
   board (`HomeShell._snackIfNoticeGone`); „Zpráva už neexistuje.“ stays for messages. The
   first build shipped the message wording for both.

## Out of scope

Threads or replies to replies; player→player messages; editing a sent message; delivery
receipts; muting; attachments (see above); pushing the Klubovna dot to the OS badge.
