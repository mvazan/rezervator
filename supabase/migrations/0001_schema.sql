-- Rezervátor — canonical schema. Training reservations for one bowling alley.
-- Access model: magic-link auth + admin approval. Roles: player / admin /
-- kiosk. The virtual schedule = settings + blocks + overrides + matches +
-- rentals + reservations; there are no materialized slot rows.
-- Reservations are mutated ONLY through RPCs (validation lives server-side).

create extension if not exists pgcrypto;
create extension if not exists pg_net;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null,
  club text not null default '',
  email text not null default '',
  role text not null default 'player' check (role in ('player', 'admin', 'kiosk')),
  status text not null default 'pending' check (status in ('pending', 'approved')),
  fcm_token text,
  approved_by uuid references profiles (id),
  approved_at timestamptz,
  created_at timestamptz not null default now()
);

-- Singleton alley configuration (readable by players and the kiosk).
create table schedule_settings (
  id boolean primary key default true check (id),
  lane_count smallint not null default 4 check (lane_count between 1 and 12),
  training_weekdays smallint[] not null default '{1,2,4}',  -- ISO: 1=Mon..7=Sun
  booking_horizon_days smallint not null default 14
    check (booking_horizon_days between 1 and 90),
  max_active_reservations smallint not null default 3
    check (max_active_reservations between 1 and 50)
);
insert into schedule_settings default values;

-- Standard training blocks. Deactivate instead of delete once referenced
-- (reservations FK here with on delete restrict). Inactive blocks stay
-- selectable in day overrides ("special" blocks for one date).
create table time_blocks (
  id uuid primary key default gen_random_uuid(),
  starts_at time not null,
  ends_at time not null check (ends_at > starts_at),
  position smallint not null,
  active boolean not null default true
);

-- Per-date exception. Row absent -> weekday rule from settings.
-- closed -> closed with reason. Open -> block_ids (null = default blocks).
create table day_overrides (
  date date primary key,
  closed boolean not null default false,
  reason text not null default '',
  block_ids uuid[],
  created_by uuid not null references profiles (id),
  created_at timestamptz not null default now()
);

-- League matches block ALL lanes and are shown even on closed days
-- (spectators want to see who plays). import_key = idempotency hook for a
-- future federation-file importer.
create table matches (
  id uuid primary key default gen_random_uuid(),
  date date not null,
  starts_at time not null,
  ends_at time not null check (ends_at > starts_at),
  opponent text not null,
  description text not null default '',
  import_key text unique,
  created_by uuid not null references profiles (id),
  created_at timestamptz not null default now()
);
create index matches_date_idx on matches (date);

-- Public renters are not users; the admin books on their behalf.
-- One-time (date) XOR weekly recurring (weekday within valid window).
create table rentals (
  id uuid primary key default gen_random_uuid(),
  renter_name text not null,
  lanes smallint[] not null check (cardinality(lanes) > 0),
  date date,
  weekday smallint check (weekday between 1 and 7),
  starts_at time not null,
  ends_at time not null check (ends_at > starts_at),
  valid_from date,
  valid_until date,
  note text not null default '',
  created_by uuid not null references profiles (id),
  created_at timestamptz not null default now(),
  check ((date is null) <> (weekday is null))
);

create table reservations (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references profiles (id),
  date date not null,
  block_id uuid not null references time_blocks (id) on delete restrict,
  lane smallint not null check (lane >= 1),
  created_via text not null check (created_via in ('app', 'kiosk', 'admin')),
  created_by uuid not null references profiles (id),
  created_at timestamptz not null default now(),
  cancelled_at timestamptz,
  cancelled_via text check (cancelled_via in ('app', 'one_click', 'admin')),
  cancel_note text not null default ''
);

-- The airtight double-booking backstop: two players tapping the same free
-- cell race on this index; the loser gets a friendly 'slot_taken' error.
create unique index reservations_slot_live_idx
  on reservations (date, block_id, lane) where cancelled_at is null;
create index reservations_player_idx on reservations (player_id, date);
create index reservations_date_idx on reservations (date);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function is_approved()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from profiles where id = auth.uid() and status = 'approved'
  );
$$;

create or replace function is_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and role = 'admin' and status = 'approved'
  );
$$;

create or replace function is_kiosk()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from profiles where id = auth.uid() and role = 'kiosk'
  );
$$;

create or replace function is_approved_or_kiosk()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and (status = 'approved' or role = 'kiosk')
  );
$$;

-- Name directory safe for every session incl. the kiosk: no emails, no
-- tokens, no kiosk account itself. Owned by postgres -> bypasses profiles RLS.
create view players as
  select id, display_name, club
  from profiles
  where status = 'approved' and role <> 'kiosk';
revoke all on players from anon;
grant select on players to authenticated;

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------

-- First sign-in: create the caller's profile. The very first user becomes
-- an auto-approved admin (founder pattern); everyone else waits for approval.
create or replace function register_profile(p_display_name text, p_club text default '')
returns profiles
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_profile profiles;
  v_first boolean;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select * into v_profile from profiles where id = v_uid;
  if found then
    return v_profile;
  end if;

  if trim(p_display_name) = '' then
    raise exception 'empty_display_name';
  end if;

  select not exists (select 1 from profiles where status = 'approved')
    into v_first;

  insert into profiles (id, display_name, club, email, role, status, approved_at)
  values (
    v_uid,
    trim(p_display_name),
    trim(coalesce(p_club, '')),
    coalesce(auth.email(), ''),
    case when v_first then 'admin' else 'player' end,
    case when v_first then 'approved' else 'pending' end,
    case when v_first then now() end
  )
  returning * into v_profile;

  return v_profile;
end;
$$;

create or replace function approve_player(p_user_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;

  update profiles
  set status = 'approved', approved_by = auth.uid(), approved_at = now()
  where id = p_user_id and status = 'pending';
end;
$$;

-- Promote/demote roles (second admin, the kiosk account). Kiosk accounts are
-- also force-approved so is_approved_or_kiosk() reads stay simple.
create or replace function set_role(p_user_id uuid, p_role text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if p_role not in ('player', 'admin', 'kiosk') then
    raise exception 'invalid_role';
  end if;
  if p_user_id = auth.uid() and p_role <> 'admin' then
    raise exception 'cannot_demote_self';
  end if;

  update profiles
  set role = p_role,
      status = case when p_role = 'kiosk' then 'approved' else status end
  where id = p_user_id;
end;
$$;

-- The single write path for bookings. Authorization: approved player books
-- SELF; admin books anyone; kiosk books any approved player. Validates the
-- day, block, lane, collisions, horizon and per-player limit in one
-- transaction; the partial unique index catches the tap-race.
create or replace function create_reservation(
  p_player_id uuid, p_date date, p_block_id uuid, p_lane smallint
)
returns reservations
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_caller profiles;
  v_settings schedule_settings;
  v_block time_blocks;
  v_override day_overrides;
  v_via text;
  v_today date := (now() at time zone 'Europe/Prague')::date;
  v_active_count int;
  v_block_ok boolean;
  v_res reservations;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  select * into v_caller from profiles where id = v_uid;
  if not found then
    raise exception 'no_profile';
  end if;

  if v_caller.role = 'admin' and v_caller.status = 'approved' then
    v_via := case when p_player_id = v_uid then 'app' else 'admin' end;
  elsif v_caller.role = 'kiosk' then
    v_via := 'kiosk';
  elsif v_caller.status = 'approved' and p_player_id = v_uid then
    v_via := 'app';
  else
    raise exception 'not_allowed';
  end if;

  if not exists (
    select 1 from profiles
    where id = p_player_id and status = 'approved' and role <> 'kiosk'
  ) then
    raise exception 'player_not_approved';
  end if;

  select * into v_settings from schedule_settings;
  select * into v_block from time_blocks where id = p_block_id;
  if not found then
    raise exception 'unknown_block';
  end if;
  if p_lane < 1 or p_lane > v_settings.lane_count then
    raise exception 'invalid_lane';
  end if;

  select * into v_override from day_overrides where date = p_date;
  if found then
    if v_override.closed then
      raise exception 'day_closed';
    end if;
    v_block_ok := case
      when v_override.block_ids is null then v_block.active
      else p_block_id = any (v_override.block_ids)
    end;
  else
    if not (extract(isodow from p_date)::smallint = any (v_settings.training_weekdays)) then
      raise exception 'day_closed';
    end if;
    v_block_ok := v_block.active;
  end if;
  if not v_block_ok then
    raise exception 'invalid_block';
  end if;

  if v_caller.role <> 'admin' then
    if p_date < v_today then
      raise exception 'date_past';
    end if;
    if p_date > v_today + v_settings.booking_horizon_days then
      raise exception 'beyond_horizon';
    end if;
    select count(*) into v_active_count
    from reservations
    where player_id = p_player_id and cancelled_at is null and date >= v_today;
    if v_active_count >= v_settings.max_active_reservations then
      raise exception 'limit_reached';
    end if;
  end if;

  if exists (
    select 1 from matches m
    where m.date = p_date
      and m.starts_at < v_block.ends_at and m.ends_at > v_block.starts_at
  ) then
    raise exception 'blocked_by_match';
  end if;

  if exists (
    select 1 from rentals r
    where (
        (r.date is not null and r.date = p_date)
        or (
          r.weekday is not null
          and r.weekday = extract(isodow from p_date)::smallint
          and (r.valid_from is null or p_date >= r.valid_from)
          and (r.valid_until is null or p_date <= r.valid_until)
        )
      )
      and p_lane = any (r.lanes)
      and r.starts_at < v_block.ends_at and r.ends_at > v_block.starts_at
  ) then
    raise exception 'blocked_by_rental';
  end if;

  begin
    insert into reservations (player_id, date, block_id, lane, created_via, created_by)
    values (p_player_id, p_date, p_block_id, p_lane, v_via, v_uid)
    returning * into v_res;
  exception when unique_violation then
    raise exception 'slot_taken';
  end;

  return v_res;
end;
$$;

-- Owner cancels own reservation until the block starts; admin cancels
-- anything anytime (a retro-cancel = marking a no-show, note e.g. 'nepřišel').
-- The kiosk role cannot cancel at all.
create or replace function cancel_reservation(p_id uuid, p_note text default '')
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_caller profiles;
  v_res reservations;
  v_block time_blocks;
  v_via text;
  v_now timestamptz := now();
  v_starts timestamptz;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  select * into v_caller from profiles where id = v_uid;
  if not found then
    raise exception 'no_profile';
  end if;

  select * into v_res from reservations where id = p_id;
  if not found then
    raise exception 'not_found';
  end if;
  if v_res.cancelled_at is not null then
    return;  -- already cancelled, idempotent
  end if;

  if v_caller.role = 'admin' and v_caller.status = 'approved' then
    v_via := 'admin';
  elsif v_res.player_id = v_uid and v_caller.status = 'approved' then
    select * into v_block from time_blocks where id = v_res.block_id;
    v_starts := (v_res.date + v_block.starts_at) at time zone 'Europe/Prague';
    if v_now >= v_starts then
      raise exception 'too_late';
    end if;
    v_via := 'app';
  else
    raise exception 'not_allowed';
  end if;

  update reservations
  set cancelled_at = v_now, cancelled_via = v_via, cancel_note = trim(coalesce(p_note, ''))
  where id = p_id;
end;
$$;

-- Upsert a per-date exception and cancel reservations it invalidates, so
-- affected players get notified (via the reservations UPDATE webhook later).
create or replace function set_day_override(
  p_date date, p_closed boolean, p_reason text default '', p_block_ids uuid[] default null
)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;

  insert into day_overrides (date, closed, reason, block_ids, created_by)
  values (p_date, p_closed, trim(coalesce(p_reason, '')), p_block_ids, auth.uid())
  on conflict (date) do update
    set closed = excluded.closed,
        reason = excluded.reason,
        block_ids = excluded.block_ids,
        created_by = excluded.created_by,
        created_at = now();

  update reservations r
  set cancelled_at = now(),
      cancelled_via = 'admin',
      cancel_note = coalesce(nullif(trim(p_reason), ''), 'změna rozvrhu')
  where r.date = p_date
    and r.cancelled_at is null
    and (p_closed or (p_block_ids is not null and not (r.block_id = any (p_block_ids))));
end;
$$;

-- Monthly attendance: uncancelled reservation = attended. Admin-only.
create or replace function monthly_attendance(p_year int, p_month int)
returns table (player_id uuid, display_name text, club text, attended bigint)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;

  return query
  select p.id, p.display_name, p.club, count(r.id)
  from profiles p
  join reservations r on r.player_id = p.id
  where r.cancelled_at is null
    and extract(year from r.date)::int = p_year
    and extract(month from r.date)::int = p_month
    and r.date <= (now() at time zone 'Europe/Prague')::date
  group by p.id, p.display_name, p.club
  order by count(r.id) desc, p.display_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- Conflict triggers: a new/edited match or rental cancels the live
-- reservations it overlaps, so nobody is silently double-booked.
-- ---------------------------------------------------------------------------

create or replace function cancel_res_for_match()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  update reservations r
  set cancelled_at = now(), cancelled_via = 'admin',
      cancel_note = 'zápas: ' || new.opponent
  from time_blocks b
  where r.block_id = b.id
    and r.cancelled_at is null
    and r.date = new.date
    and b.starts_at < new.ends_at and b.ends_at > new.starts_at;
  return new;
end;
$$;

create trigger match_conflicts
  after insert or update on matches
  for each row execute function cancel_res_for_match();

create or replace function cancel_res_for_rental()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  update reservations r
  set cancelled_at = now(), cancelled_via = 'admin',
      cancel_note = 'pronájem: ' || new.renter_name
  from time_blocks b
  where r.block_id = b.id
    and r.cancelled_at is null
    and r.lane = any (new.lanes)
    and b.starts_at < new.ends_at and b.ends_at > new.starts_at
    and (
      (new.date is not null and r.date = new.date)
      or (
        new.weekday is not null
        and extract(isodow from r.date)::smallint = new.weekday
        and (new.valid_from is null or r.date >= new.valid_from)
        and (new.valid_until is null or r.date <= new.valid_until)
      )
    );
  return new;
end;
$$;

create trigger rental_conflicts
  after insert or update on rentals
  for each row execute function cancel_res_for_rental();

-- ---------------------------------------------------------------------------
-- Notification webhook (Edge Function `notify` arrives in Phase 3; failing
-- posts are async and never block the write). SETUP.md tells the user to
-- replace <PROJECT_REF> and <WEBHOOK_SECRET> before running this file.
-- ---------------------------------------------------------------------------

create or replace function notify_webhook()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  perform net.http_post(
    url := 'https://<PROJECT_REF>.supabase.co/functions/v1/notify',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-webhook-secret', '<WEBHOOK_SECRET>'
    ),
    body := jsonb_build_object(
      'type', tg_op,
      'table', tg_table_name,
      'schema', tg_table_schema,
      'record', case when tg_op = 'DELETE' then null else to_jsonb(new) end,
      'old_record', case when tg_op = 'INSERT' then null else to_jsonb(old) end
    )
  );
  return coalesce(new, old);
end;
$$;

create trigger notify_profiles
  after insert on profiles
  for each row execute function notify_webhook();
create trigger notify_reservations
  after insert or update on reservations
  for each row execute function notify_webhook();

-- ---------------------------------------------------------------------------
-- Row Level Security. Reservations have NO write policies on purpose:
-- all mutations flow through the RPCs above.
-- ---------------------------------------------------------------------------

alter table profiles          enable row level security;
alter table schedule_settings enable row level security;
alter table time_blocks       enable row level security;
alter table day_overrides     enable row level security;
alter table matches           enable row level security;
alter table rentals           enable row level security;
alter table reservations      enable row level security;

-- profiles: own row (needed while pending) or admin. Names for everyone else
-- come from the `players` view. Column grants keep role/status/email writes
-- out of reach (those go through RPCs).
revoke update on profiles from authenticated;
grant update (display_name, club, fcm_token) on profiles to authenticated;

create policy profiles_select on profiles for select
  using (id = auth.uid() or is_admin());
create policy profiles_update_own on profiles for update
  using (id = auth.uid()) with check (id = auth.uid());

create policy settings_select on schedule_settings for select
  using (is_approved_or_kiosk());
create policy settings_update on schedule_settings for update
  using (is_admin()) with check (is_admin());

create policy blocks_select on time_blocks for select
  using (is_approved_or_kiosk());
create policy blocks_insert on time_blocks for insert with check (is_admin());
create policy blocks_update on time_blocks for update
  using (is_admin()) with check (is_admin());
create policy blocks_delete on time_blocks for delete using (is_admin());

create policy overrides_select on day_overrides for select
  using (is_approved_or_kiosk());
create policy overrides_insert on day_overrides for insert with check (is_admin());
create policy overrides_update on day_overrides for update
  using (is_admin()) with check (is_admin());
create policy overrides_delete on day_overrides for delete using (is_admin());

create policy matches_select on matches for select
  using (is_approved_or_kiosk());
create policy matches_insert on matches for insert with check (is_admin());
create policy matches_update on matches for update
  using (is_admin()) with check (is_admin());
create policy matches_delete on matches for delete using (is_admin());

create policy rentals_select on rentals for select
  using (is_approved_or_kiosk());
create policy rentals_insert on rentals for insert with check (is_admin());
create policy rentals_update on rentals for update
  using (is_admin()) with check (is_admin());
create policy rentals_delete on rentals for delete using (is_admin());

create policy reservations_select on reservations for select
  using (is_approved_or_kiosk());
-- no insert/update/delete policies: RPC only.

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------

alter publication supabase_realtime add table
  profiles, schedule_settings, time_blocks, day_overrides,
  matches, rentals, reservations;
