-- 0023 — Google Calendar: a player's live reservations mirror into an
-- app-owned Google calendar, kept in step by a small job engine.
--
-- Ported from Termínátor (0025 notification_jobs, 0027 google_calendar,
-- 0030/0033 reminders, 0034 final status set). Linking is one OAuth round
-- trip: start_calendar_link() issues a single-use nonce that travels as the
-- OAuth `state`, Google redirects to the calendar-oauth-callback edge
-- function, which consumes the nonce (service role), stores the refresh
-- token and creates the calendar "Rezervátor" in the player's account
-- (scope calendar.app.created — the app sees no other calendar). Two tables
-- on purpose: google_calendar_links is what the client sees (status, e-mail,
-- reminders; streamed over Realtime, no secret in it), google_calendar_tokens
-- never leaves the server.
--
-- Everything that changes a reservation without the player's own request —
-- an admin move or cancel, a cascade, a re-timed template block — goes
-- through notification_jobs: producers enqueue ONE `calendar_sync` job per
-- (player, reservation), the dedupe key debounces a burst into a single run,
-- and a minutely pg_cron tick POSTs {"type":"CRON"} to the notify edge
-- function through the Vault-configured webhook whenever a job is due. The
-- handler RECONCILES: it re-reads the reservation and upserts or deletes the
-- event, so a stale job can never write a wrong one and one job kind covers
-- book, move and cancel alike. Jobs are produced only for players whose link
-- is `linked`; backfill_calendar_jobs seeds them right after linking.
-- User-initiated actions (link, disconnect, reminders) are synchronous in
-- the edge functions and use the service-role RPCs at the bottom.

-- pg_cron ships with the Supabase image (it is in shared_preload_libraries
-- on both the hosted and the local stack); idempotent where the dashboard
-- already enabled it. pg_net exists since 0016 (notify_webhook).
create extension if not exists pg_cron;

-- ---------------------------------------------------------------------------
-- Job engine
-- ---------------------------------------------------------------------------

create table notification_jobs (
  id bigint generated always as identity primary key,
  kind text not null,                       -- only 'calendar_sync' for now
  dedupe_key text not null unique,          -- 'calendar:<user_id>:<reservation_id>'
  payload jsonb not null default '{}'::jsonb,
  run_at timestamptz not null default now(),
  attempts int not null default 0,          -- the handler backs off 2^attempts minutes
  created_at timestamptz not null default now()
);
create index notification_jobs_due_idx on notification_jobs (run_at);

comment on column notification_jobs.dedupe_key is
  'One pending job per key: a repeat re-arms run_at instead of adding a row.';

-- Server-only: RLS on with no policy, and the app roles lose even the plain
-- DML the 0017 defaults hand every new table. Producers are security
-- definer; the notify function (service_role) consumes.
alter table notification_jobs enable row level security;
revoke all on notification_jobs from anon, authenticated;
grant all on notification_jobs to service_role;
-- The identity sequence is the schema's first: the image's default
-- privileges hand UPDATE (nextval/setval) to the app roles — 0017 pinned
-- tables and functions only. Nothing for them here either.
revoke all on sequence notification_jobs_id_seq from anon, authenticated;

-- Debounce: the same key re-arms run_at (and refreshes the payload) instead
-- of inserting a second row.
create or replace function enqueue_notification(
  p_kind text, p_dedupe_key text, p_payload jsonb,
  p_delay interval default interval '3 minutes')
returns void
language sql security definer set search_path = public
as $$
  insert into notification_jobs (kind, dedupe_key, payload, run_at)
  values (p_kind, p_dedupe_key, p_payload, now() + p_delay)
  on conflict (dedupe_key)
    do update set run_at = excluded.run_at, payload = excluded.payload;
$$;
revoke all on function enqueue_notification(text, text, jsonb, interval)
  from public, anon, authenticated;

-- The minute tick: nothing due → nothing sent. URL and secret are the Vault
-- entries notify_webhook() uses (SETUP.md §2); without them the due jobs
-- simply wait for the next tick — that warning is the local-stack path.
create or replace function trigger_notification_jobs()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_url text;
  v_secret text;
begin
  if not exists (select 1 from notification_jobs where run_at <= now()) then
    return;
  end if;
  select c.url, c.secret into v_url, v_secret from notify_webhook_config() c;
  if v_url is null or v_secret is null then
    raise warning 'trigger_notification_jobs: vault secrets notify_url / webhook_secret missing, due jobs not dispatched';
    return;
  end if;
  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-webhook-secret', v_secret
    ),
    body := '{"type":"CRON","table":"notification_jobs","record":null,"old_record":null}'::jsonb
  );
end;
$$;
revoke all on function trigger_notification_jobs()
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Link state (client-visible) vs. tokens (server-only)
-- ---------------------------------------------------------------------------

-- No secret here: the profile card streams this row over Realtime and flips
-- the moment the callback function writes the outcome. pending = token
-- stored, calendar not created yet; broken = Google revoked the token or
-- the calendar is gone (the card offers a re-link); unlinked = disconnected,
-- the reminder preference kept for the next link.
create table google_calendar_links (
  user_id uuid primary key references profiles (id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'linked', 'broken', 'unlinked')),
  google_email text,
  last_error text,
  -- Calendar API shape (reminders[].minutes): at most 5, each 0..40320
  -- (4 weeks); set_calendar_reminders_for stores them sorted descending.
  reminder_minutes int[] not null default '{}'
    check (coalesce(array_length(reminder_minutes, 1), 0) <= 5
           and 0 <= all (reminder_minutes)
           and 40320 >= all (reminder_minutes)),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on column google_calendar_links.status is
  'pending (token stored, calendar not yet created) | linked | broken (token revoked / calendar gone) | unlinked (disconnected)';

alter table google_calendar_links enable row level security;
-- Own row readable, every write the server's. Teammates see nothing of each
-- other — no reason for anyone to learn a foreign Google e-mail.
revoke all on google_calendar_links from anon, authenticated;
grant select on google_calendar_links to authenticated;
grant all on google_calendar_links to service_role;
create policy google_calendar_links_select_own on google_calendar_links
  for select to authenticated using (user_id = auth.uid());

alter publication supabase_realtime add table google_calendar_links;

-- Refresh token + the id of the calendar we created. A separate table on
-- purpose: the links row is streamed to the client and Realtime does not
-- reliably honour column grants — the token must not sit in a streamed
-- table at all. RLS on, zero policies, service_role only.
create table google_calendar_tokens (
  user_id uuid primary key references profiles (id) on delete cascade,
  refresh_token text not null,
  google_calendar_id text,
  updated_at timestamptz not null default now()
);
alter table google_calendar_tokens enable row level security;
revoke all on google_calendar_tokens from anon, authenticated;
grant all on google_calendar_tokens to service_role;

-- ---------------------------------------------------------------------------
-- OAuth `state` nonce: CSRF guard + binds Google's redirect to one player
-- ---------------------------------------------------------------------------

-- The callback function runs with --no-verify-jwt (Google cannot send our
-- JWT), so the trust is this nonce — unguessable, one-shot, 10-minute TTL,
-- issued only to a signed-in approved player and bound to them. Server-only
-- like the tokens.
create table oauth_nonces (
  nonce text primary key default encode(gen_random_bytes(24), 'hex'),
  user_id uuid not null references profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  consumed_at timestamptz
);
alter table oauth_nonces enable row level security;
revoke all on oauth_nonces from anon, authenticated;
grant all on oauth_nonces to service_role;

-- The app calls this and opens Google's consent URL with the nonce as
-- `state`. EXECUTE comes from the 0017 defaults like every app RPC. The
-- kiosk account is a shared device, not a person — no calendar for it.
create or replace function start_calendar_link()
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_nonce text;
begin
  if not is_approved() or is_kiosk() then
    raise exception 'not_allowed';
  end if;
  -- Closing the consent screen and trying again must not pile up rows.
  delete from oauth_nonces
    where user_id = auth.uid() and consumed_at is null;
  insert into oauth_nonces (user_id) values (auth.uid())
    returning nonce into v_nonce;
  return v_nonce;
end;
$$;

-- One shot: the bound player of an unconsumed nonce younger than 10 minutes,
-- stamped consumed on the way out; null otherwise. Callback function only.
create or replace function consume_calendar_nonce(p_nonce text)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_user uuid;
begin
  update oauth_nonces
    set consumed_at = now()
    where nonce = p_nonce
      and consumed_at is null
      and created_at > now() - interval '10 minutes'
    returning user_id into v_user;
  return v_user;
end;
$$;
revoke all on function consume_calendar_nonce(text)
  from public, anon, authenticated;
grant execute on function consume_calendar_nonce(text) to service_role;

-- ---------------------------------------------------------------------------
-- Producers: one reconcile job per (player, reservation)
-- ---------------------------------------------------------------------------

-- The single gate: only a linked player gets jobs. Book, move and cancel
-- share the key — the handler reads the reservation at run time and upserts
-- or deletes the event accordingly, so a book-then-cancel inside the
-- debounce window collapses into one job that does the right thing.
create or replace function enqueue_calendar_sync(p_user uuid, p_reservation uuid)
returns void
language sql security definer set search_path = public
as $$
  select enqueue_notification('calendar_sync',
    'calendar:' || p_user || ':' || p_reservation,
    jsonb_build_object('user_id', p_user, 'reservation_id', p_reservation))
  where exists (
    select 1 from google_calendar_links
    where user_id = p_user and status = 'linked');
$$;
revoke all on function enqueue_calendar_sync(uuid, uuid)
  from public, anon, authenticated;

-- Every insert or update of a reservation row: a booking, a cancel (RPC,
-- cascade or one-click link), a move. When the row changes hands (the 0022
-- merge re-points player_id) the previous owner's event must go as well.
create or replace function reservations_enqueue_calendar()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and old.player_id <> new.player_id then
    perform enqueue_calendar_sync(old.player_id, new.id);
  end if;
  perform enqueue_calendar_sync(new.player_id, new.id);
  return new;
end;
$$;
create trigger reservations_enqueue_calendar
  after insert or update on reservations
  for each row execute function reservations_enqueue_calendar();

-- A re-timed template block moves every reservation on it without touching
-- their rows — the one change the row-level webhook never saw. Only a real
-- change of the times counts (a save that leaves them as they were enqueues
-- nothing); deactivation cancels through cascade_schedule_change, which
-- updates the rows and so lands in the trigger above.
create or replace function time_blocks_enqueue_calendar()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  perform enqueue_calendar_sync(r.player_id, r.id)
    from reservations r
    where r.block_id = new.id
      and r.cancelled_at is null
      and r.date >= (now() at time zone 'Europe/Prague')::date;
  return new;
end;
$$;
create trigger time_blocks_enqueue_calendar
  after update of starts_at, ends_at on time_blocks
  for each row
  when (old.starts_at is distinct from new.starts_at
        or old.ends_at is distinct from new.ends_at)
  execute function time_blocks_enqueue_calendar();

-- ---------------------------------------------------------------------------
-- Service-role RPCs for the edge functions
-- ---------------------------------------------------------------------------

-- Right after linking: one job per live future reservation of the player,
-- due now (a one-off action, not a click to debounce); a job already
-- pending is re-armed to now. Returns how many reservations were queued.
create or replace function backfill_calendar_jobs(p_user uuid)
returns int
language plpgsql security definer set search_path = public
as $$
declare
  v_count int;
begin
  insert into notification_jobs (kind, dedupe_key, payload, run_at)
  select 'calendar_sync',
         'calendar:' || p_user || ':' || r.id,
         jsonb_build_object('user_id', p_user, 'reservation_id', r.id),
         now()
    from reservations r
    where r.player_id = p_user
      and r.cancelled_at is null
      and r.date >= (now() at time zone 'Europe/Prague')::date
  on conflict (dedupe_key)
    do update set run_at = excluded.run_at, payload = excluded.payload;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function backfill_calendar_jobs(uuid)
  from public, anon, authenticated;
grant execute on function backfill_calendar_jobs(uuid) to service_role;

-- Reminder preference on behalf of a player (calendar-manage runs as the
-- service role, so auth.uid() is null there). Normalised distinct + sorted
-- descending: "a day and 2 hours" is one array whichever order it was
-- typed in, and the card and Google both list from the farthest. Google's
-- limits: at most 5 reminders, each 0..40320 minutes. Returns what was
-- stored; the caller rewrites the events itself.
create or replace function set_calendar_reminders_for(p_user uuid, p_minutes int[])
returns int[]
language plpgsql security definer set search_path = public
as $$
declare
  v_minutes int[];
begin
  select coalesce(array_agg(distinct m order by m desc), '{}'::int[])
    into v_minutes
    from unnest(coalesce(p_minutes, '{}'::int[])) as m
    where m is not null;
  if array_length(v_minutes, 1) > 5
     or exists (select 1 from unnest(v_minutes) m where m < 0 or m > 40320) then
    raise exception 'bad_reminders';
  end if;
  update google_calendar_links
    set reminder_minutes = v_minutes, updated_at = now()
    where user_id = p_user;
  if not found then
    raise exception 'unknown_link';
  end if;
  return v_minutes;
end;
$$;
revoke all on function set_calendar_reminders_for(uuid, int[])
  from public, anon, authenticated;
grant execute on function set_calendar_reminders_for(uuid, int[]) to service_role;

-- The events' raw material for one player — the same definition of "live"
-- as backfill_calendar_jobs: not cancelled, Prague-today or later. Times
-- come from the block (a re-timed block re-times the event), the name from
-- the tenant. `language sql` on purpose: in plpgsql the OUT names would
-- shadow the columns.
create or replace function my_future_reservations(p_user uuid)
returns table (
  reservation_id uuid, date date, starts_at time, ends_at time,
  lane smallint, alley_name text)
language sql stable security definer set search_path = public
as $$
  select r.id, r.date, b.starts_at, b.ends_at, r.lane, t.name
    from reservations r
    join time_blocks b on b.id = r.block_id
    join tenants t on t.id = r.tenant_id
    where r.player_id = p_user
      and r.cancelled_at is null
      and r.date >= (now() at time zone 'Europe/Prague')::date
    order by r.date, b.starts_at;
$$;
revoke all on function my_future_reservations(uuid)
  from public, anon, authenticated;
grant execute on function my_future_reservations(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Cron: the minute tick
-- ---------------------------------------------------------------------------

-- Re-applying the migration, or a backend where the tick was created by
-- hand, must not leave two of them behind.
do $$
begin
  if exists (select 1 from cron.job where jobname = 'notification-jobs') then
    perform cron.unschedule('notification-jobs');
  end if;
  perform cron.schedule('notification-jobs', '* * * * *',
    'select public.trigger_notification_jobs()');
end $$;
