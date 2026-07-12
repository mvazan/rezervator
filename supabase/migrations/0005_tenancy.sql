-- 0005 — multi-tenancy: multiple fully-isolated alleys (kuželny) in one
-- Supabase project. Every table gains tenant_id; RLS + every RPC/trigger
-- scope by the caller's tenant (current_tenant_id(), null → fail closed).
-- Tenants are created ONLY by the superadmin (plain SQL insert — see
-- SETUP.md runbook); players pick their alley at registration. The first
-- approved-less registrant of a tenant becomes its admin, guarded by the
-- optional tenants.founder_email. Existing data backfills as tenant #1.
begin;

-- ---------------------------------------------------------------------------
-- 1) tenants
-- ---------------------------------------------------------------------------
create table tenants (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  -- When set, only this e-mail can claim founder-admin of the tenant;
  -- null keeps the pure first-registrant rule. Never client-readable.
  founder_email text,
  created_at timestamptz not null default now()
);

insert into tenants (id, name)
values ('00000000-0000-0000-0000-000000000001', 'Kuželna č. 1');

alter table tenants enable row level security;
create policy tenants_select on tenants for select to authenticated using (true);
revoke all on tenants from anon, authenticated;
grant select (id, name) on tenants to authenticated;

-- ---------------------------------------------------------------------------
-- 2) profiles.tenant_id + the scoping helper
-- ---------------------------------------------------------------------------
alter table profiles add column tenant_id uuid not null
  default '00000000-0000-0000-0000-000000000001' references tenants (id);
alter table profiles alter column tenant_id drop default;
create index profiles_tenant_idx on profiles (tenant_id);

create or replace function current_tenant_id()
returns uuid
language sql stable security definer set search_path = public
as $$ select tenant_id from profiles where id = auth.uid() $$;
-- null when the caller has no profile yet → every tenant-scoped policy and
-- RPC predicate fails closed.

-- ---------------------------------------------------------------------------
-- 3) tenant_id everywhere (backfill via temp default = tenant #1, then the
--    client-insertable tables default to current_tenant_id())
-- ---------------------------------------------------------------------------
alter table schedule_settings add column tenant_id uuid not null
  default '00000000-0000-0000-0000-000000000001' references tenants (id);
alter table schedule_settings alter column tenant_id drop default;

alter table time_blocks add column tenant_id uuid not null
  default '00000000-0000-0000-0000-000000000001' references tenants (id);
alter table time_blocks alter column tenant_id set default current_tenant_id();

alter table day_overrides add column tenant_id uuid not null
  default '00000000-0000-0000-0000-000000000001' references tenants (id);
alter table day_overrides alter column tenant_id drop default;

alter table priority_slots add column tenant_id uuid not null
  default '00000000-0000-0000-0000-000000000001' references tenants (id);
alter table priority_slots alter column tenant_id set default current_tenant_id();

alter table priority_slot_types add column tenant_id uuid not null
  default '00000000-0000-0000-0000-000000000001' references tenants (id);
alter table priority_slot_types alter column tenant_id set default current_tenant_id();

alter table rentals add column tenant_id uuid not null
  default '00000000-0000-0000-0000-000000000001' references tenants (id);
alter table rentals alter column tenant_id set default current_tenant_id();

alter table reservations add column tenant_id uuid not null
  default '00000000-0000-0000-0000-000000000001' references tenants (id);
alter table reservations alter column tenant_id drop default;

alter table clubs add column tenant_id uuid not null
  default '00000000-0000-0000-0000-000000000001' references tenants (id);
alter table clubs alter column tenant_id set default current_tenant_id();

-- ---------------------------------------------------------------------------
-- 4) constraint rewrites: global uniques become per-tenant; the settings
--    singleton becomes one-row-per-tenant.
--    (reservations_slot_live_idx stays as-is: block_id is a per-tenant uuid,
--    so (date, block_id, lane) can never collide across tenants.)
-- ---------------------------------------------------------------------------
alter table schedule_settings drop constraint schedule_settings_pkey;
alter table schedule_settings drop column id;
alter table schedule_settings add primary key (tenant_id);

alter table day_overrides drop constraint day_overrides_pkey;
alter table day_overrides add primary key (tenant_id, date);

alter table priority_slots drop constraint matches_import_key_key;
create unique index priority_slots_import_key_idx
  on priority_slots (tenant_id, import_key);

alter table clubs drop constraint clubs_name_key;
alter table clubs add unique (tenant_id, name);

alter table priority_slot_types drop constraint priority_slot_types_name_key;
alter table priority_slot_types add unique (tenant_id, name);

-- ---------------------------------------------------------------------------
-- 5) every future tenant auto-gets its settings row and built-in Zápas type
--    (removes two footguns from the new-alley runbook).
-- ---------------------------------------------------------------------------
create or replace function seed_tenant_defaults()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into schedule_settings (tenant_id) values (new.id);
  insert into priority_slot_types (tenant_id, name, is_match, builtin)
  values (new.id, 'Zápas', true, true);
  return new;
end;
$$;

create trigger tenant_seed_defaults
  after insert on tenants
  for each row execute function seed_tenant_defaults();

-- ---------------------------------------------------------------------------
-- 6) players view: tenant-filtered (postgres-owned, RLS-bypassing — without
--    the predicate it would leak names across tenants).
-- ---------------------------------------------------------------------------
drop view players;
create view players as
  select p.id, p.display_name, p.club, p.nick,
         p.club_id, coalesce(c.color, -1) as club_color
  from profiles p
  left join clubs c on c.id = p.club_id
  where p.status = 'approved' and p.role <> 'kiosk'
    and p.tenant_id = current_tenant_id();
revoke all on players from anon;
grant select on players to authenticated;

-- ---------------------------------------------------------------------------
-- 7) RPC rewrites
-- ---------------------------------------------------------------------------

-- Old 2-arg signature must go first: `create or replace` with a new default
-- param would leave an overload and PostgREST couldn't pick a candidate.
drop function register_profile(text, text);

create function register_profile(
  p_display_name text, p_club text default '', p_tenant_id uuid default null
)
returns profiles
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_profile profiles;
  v_tenant tenants;
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

  select * into v_tenant from tenants where id = p_tenant_id;
  if not found then
    raise exception 'unknown_tenant';
  end if;

  -- Serialize concurrent registrations into the same tenant so exactly one
  -- founder can win the race.
  perform pg_advisory_xact_lock(
    hashtext('register_profile'), hashtext(p_tenant_id::text));

  select not exists (
    select 1 from profiles
    where tenant_id = p_tenant_id and status = 'approved'
  ) into v_first;
  if v_tenant.founder_email is not null then
    v_first := v_first
      and lower(coalesce(auth.email(), '')) = lower(v_tenant.founder_email);
  end if;

  insert into profiles
    (id, tenant_id, display_name, club, email, role, status, approved_at)
  values (
    v_uid,
    p_tenant_id,
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
  where id = p_user_id and status = 'pending'
    and tenant_id = current_tenant_id();
end;
$$;

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
  where id = p_user_id and tenant_id = current_tenant_id();
end;
$$;

create or replace function set_nick(p_user_id uuid, p_nick text default '')
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if auth.uid() <> p_user_id and not is_admin() then
    raise exception 'not_allowed';
  end if;
  if char_length(trim(coalesce(p_nick, ''))) > 14 then
    raise exception 'nick_too_long';
  end if;
  update profiles set nick = trim(coalesce(p_nick, ''))
  where id = p_user_id
    and (id = auth.uid() or tenant_id = current_tenant_id());
end;
$$;

create or replace function set_player_club(p_user_id uuid, p_club_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  if p_club_id is not null and not exists (
    select 1 from clubs
    where id = p_club_id and tenant_id = current_tenant_id()
  ) then
    raise exception 'unknown_club';
  end if;
  update profiles set club_id = p_club_id
  where id = p_user_id and tenant_id = current_tenant_id();
end; $$;

create or replace function upsert_club(p_id uuid, p_name text, p_color smallint)
returns clubs language plpgsql security definer set search_path = public as $$
declare v clubs;
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  if trim(coalesce(p_name,'')) = '' then raise exception 'empty_name'; end if;
  if p_id is null then
    insert into clubs (tenant_id, name, color)
    values (current_tenant_id(), trim(p_name), p_color) returning * into v;
  else
    update clubs set name = trim(p_name), color = p_color
    where id = p_id and tenant_id = current_tenant_id() returning * into v;
  end if;
  return v;
end; $$;

create or replace function delete_club(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  delete from clubs
  where id = p_id and tenant_id = current_tenant_id();
end; $$;

-- create_reservation: every lookup scoped by the caller's tenant. CRITICAL:
-- schedule_settings is no longer a singleton — an unscoped `select into`
-- would grab an arbitrary tenant's row.
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
  v_now time := (now() at time zone 'Europe/Prague')::time;
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
      and tenant_id = v_caller.tenant_id
  ) then
    raise exception 'player_not_approved';
  end if;

  select * into v_settings from schedule_settings
  where tenant_id = v_caller.tenant_id;
  select * into v_block from time_blocks
  where id = p_block_id and tenant_id = v_caller.tenant_id;
  if not found then
    raise exception 'unknown_block';
  end if;
  if p_lane < 1 or p_lane > v_settings.lane_count then
    raise exception 'invalid_lane';
  end if;

  select * into v_override from day_overrides
  where tenant_id = v_caller.tenant_id and date = p_date;
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
    if p_date = v_today and v_block.starts_at <= v_now then
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
    select 1 from priority_slots s
    join priority_slot_types t on t.id = s.type_id
    where s.date = p_date
      and s.tenant_id = v_caller.tenant_id
      and (t.lanes is null or p_lane = any (t.lanes))
      and (case when extract(epoch from s.starts_at) / 60 >= s.prep_minutes
                then s.starts_at - make_interval(mins => s.prep_minutes)
                else time '00:00' end) < v_block.ends_at
      and s.ends_at > v_block.starts_at
  ) then
    raise exception 'blocked_by_priority';
  end if;

  if exists (
    select 1 from rentals r
    where r.tenant_id = v_caller.tenant_id
      and (
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
    insert into reservations
      (tenant_id, player_id, date, block_id, lane, created_via, created_by)
    values
      (v_caller.tenant_id, p_player_id, p_date, p_block_id, p_lane, v_via, v_uid)
    returning * into v_res;
  exception when unique_violation then
    raise exception 'slot_taken';
  end;

  return v_res;
end;
$$;

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

  if v_caller.role = 'admin' and v_caller.status = 'approved'
     and v_res.tenant_id = v_caller.tenant_id then
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

-- CRITICAL scope: the cascading cancel would otherwise kill other alleys'
-- reservations sharing the same calendar date.
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

  insert into day_overrides (tenant_id, date, closed, reason, block_ids, created_by)
  values (current_tenant_id(), p_date, p_closed, trim(coalesce(p_reason, '')),
          p_block_ids, auth.uid())
  on conflict (tenant_id, date) do update
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
    and r.tenant_id = current_tenant_id()
    and r.cancelled_at is null
    and (p_closed or (p_block_ids is not null and not (r.block_id = any (p_block_ids))));
end;
$$;

create or replace function monthly_attendance(p_year int, p_month int)
returns table (player_id uuid, display_name text, club text, attended bigint)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;

  return query
  select p.id, p.display_name,
         coalesce(c.name, nullif(p.club, ''), ''),
         count(r.id)
  from profiles p
  left join clubs c on c.id = p.club_id
  join reservations r on r.player_id = p.id
  where p.tenant_id = current_tenant_id()
    and r.cancelled_at is null
    and extract(year from r.date)::int = p_year
    and extract(month from r.date)::int = p_month
    and r.date <= (now() at time zone 'Europe/Prague')::date
  group by p.id, p.display_name, coalesce(c.name, nullif(p.club, ''), '')
  order by count(r.id) desc, p.display_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8) conflict triggers: scope the cancels to the row's own tenant. CRITICAL:
--    a tenant-A match/rental must never cancel tenant-B reservations that
--    happen to share the date/time.
-- ---------------------------------------------------------------------------
create or replace function cancel_res_for_priority_slot(p_slot priority_slots)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_type priority_slot_types;
begin
  select * into v_type from priority_slot_types where id = p_slot.type_id;
  update reservations r
  set cancelled_at = now(), cancelled_via = 'admin',
      cancel_note = case when v_type.is_match
                         then 'zápas: ' || p_slot.away_team
                         else v_type.name end
  from time_blocks b
  where r.block_id = b.id
    and r.tenant_id = p_slot.tenant_id
    and r.cancelled_at is null
    and r.date >= (now() at time zone 'Europe/Prague')::date
    and r.date = p_slot.date
    and (v_type.lanes is null or r.lane = any (v_type.lanes))
    and (case when extract(epoch from p_slot.starts_at) / 60 >= p_slot.prep_minutes
              then p_slot.starts_at - make_interval(mins => p_slot.prep_minutes)
              else time '00:00' end) < b.ends_at
    and p_slot.ends_at > b.starts_at;
end;
$$;

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
    and r.tenant_id = new.tenant_id
    and r.cancelled_at is null
    and r.date >= (now() at time zone 'Europe/Prague')::date
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

-- ---------------------------------------------------------------------------
-- 9) RLS: every policy gains `tenant_id = current_tenant_id()`. The helpers
--    stay unscoped — combined with the tenant predicate they mean "admin/
--    approved member OF THIS ROW'S TENANT".
-- ---------------------------------------------------------------------------
drop policy profiles_select on profiles;
create policy profiles_select on profiles for select
  using (id = auth.uid() or (is_admin() and tenant_id = current_tenant_id()));
-- profiles_update_own unchanged (id = auth.uid()); column grants unchanged.

drop policy settings_select on schedule_settings;
drop policy settings_update on schedule_settings;
create policy settings_select on schedule_settings for select
  using (tenant_id = current_tenant_id() and is_approved_or_kiosk());
create policy settings_update on schedule_settings for update
  using (tenant_id = current_tenant_id() and is_admin())
  with check (tenant_id = current_tenant_id() and is_admin());

drop policy blocks_select on time_blocks;
drop policy blocks_insert on time_blocks;
drop policy blocks_update on time_blocks;
drop policy blocks_delete on time_blocks;
create policy blocks_select on time_blocks for select
  using (tenant_id = current_tenant_id() and is_approved_or_kiosk());
create policy blocks_insert on time_blocks for insert
  with check (tenant_id = current_tenant_id() and is_admin());
create policy blocks_update on time_blocks for update
  using (tenant_id = current_tenant_id() and is_admin())
  with check (tenant_id = current_tenant_id() and is_admin());
create policy blocks_delete on time_blocks for delete
  using (tenant_id = current_tenant_id() and is_admin());

drop policy overrides_select on day_overrides;
drop policy overrides_insert on day_overrides;
drop policy overrides_update on day_overrides;
drop policy overrides_delete on day_overrides;
create policy overrides_select on day_overrides for select
  using (tenant_id = current_tenant_id() and is_approved_or_kiosk());
create policy overrides_insert on day_overrides for insert
  with check (tenant_id = current_tenant_id() and is_admin());
create policy overrides_update on day_overrides for update
  using (tenant_id = current_tenant_id() and is_admin())
  with check (tenant_id = current_tenant_id() and is_admin());
create policy overrides_delete on day_overrides for delete
  using (tenant_id = current_tenant_id() and is_admin());

-- priority_slots kept the renamed matches_* policies through 0004.
drop policy matches_select on priority_slots;
drop policy matches_insert on priority_slots;
drop policy matches_update on priority_slots;
drop policy matches_delete on priority_slots;
create policy priority_select on priority_slots for select
  using (tenant_id = current_tenant_id() and is_approved_or_kiosk());
create policy priority_insert on priority_slots for insert
  with check (tenant_id = current_tenant_id() and is_admin());
create policy priority_update on priority_slots for update
  using (tenant_id = current_tenant_id() and is_admin())
  with check (tenant_id = current_tenant_id() and is_admin());
create policy priority_delete on priority_slots for delete
  using (tenant_id = current_tenant_id() and is_admin());

drop policy slot_types_select on priority_slot_types;
drop policy slot_types_insert on priority_slot_types;
drop policy slot_types_update on priority_slot_types;
drop policy slot_types_delete on priority_slot_types;
create policy slot_types_select on priority_slot_types for select
  using (tenant_id = current_tenant_id() and is_approved_or_kiosk());
create policy slot_types_insert on priority_slot_types for insert
  with check (tenant_id = current_tenant_id() and is_admin());
create policy slot_types_update on priority_slot_types for update
  using (tenant_id = current_tenant_id() and is_admin())
  with check (tenant_id = current_tenant_id() and is_admin());
create policy slot_types_delete on priority_slot_types for delete
  using (tenant_id = current_tenant_id() and is_admin() and not builtin);

drop policy rentals_select on rentals;
drop policy rentals_insert on rentals;
drop policy rentals_update on rentals;
drop policy rentals_delete on rentals;
create policy rentals_select on rentals for select
  using (tenant_id = current_tenant_id() and is_approved_or_kiosk());
create policy rentals_insert on rentals for insert
  with check (tenant_id = current_tenant_id() and is_admin());
create policy rentals_update on rentals for update
  using (tenant_id = current_tenant_id() and is_admin())
  with check (tenant_id = current_tenant_id() and is_admin());
create policy rentals_delete on rentals for delete
  using (tenant_id = current_tenant_id() and is_admin());

drop policy reservations_select on reservations;
create policy reservations_select on reservations for select
  using (tenant_id = current_tenant_id() and is_approved_or_kiosk());
-- still no insert/update/delete policies: RPC only.

drop policy clubs_select on clubs;
drop policy clubs_write on clubs;
create policy clubs_select on clubs for select
  using (tenant_id = current_tenant_id() and is_approved_or_kiosk());
create policy clubs_write on clubs for all
  using (tenant_id = current_tenant_id() and is_admin())
  with check (tenant_id = current_tenant_id() and is_admin());

-- tenants deliberately NOT in the realtime publication (one-shot fetch).

commit;
