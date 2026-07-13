-- 0009 — priority slots v2: "Úklid před zápasem" becomes a real built-in
-- blocking slot linked to its match (parent_id, cascade delete) instead of
-- the prep_minutes-extended blocking window. Every slot now blocks exactly
-- its own [starts_at, ends_at) — the prep-extension disappears from every
-- collision predicate. A trigger keeps the úklid child in sync with the
-- match's prep_minutes (which remains as the stored duration the dialog
-- edits), so any client — including future drag&drop moves — gets the
-- linked slot for free.

-- ---------------------------------------------------------------------------
-- 1) schema: the match→úklid link + the built-in type per tenant
-- ---------------------------------------------------------------------------
alter table priority_slots
  add column parent_id uuid references priority_slots (id) on delete cascade;
create index priority_slots_parent_idx on priority_slots (parent_id);

insert into priority_slot_types (tenant_id, name, is_match, builtin)
select t.id, 'Úklid před zápasem', false, true
from tenants t
where not exists (
  select 1 from priority_slot_types x
  where x.tenant_id = t.id and x.builtin and not x.is_match
    and x.name = 'Úklid před zápasem'
);

create or replace function seed_tenant_defaults()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into schedule_settings (tenant_id) values (new.id);
  insert into priority_slot_types (tenant_id, name, is_match, builtin)
  values (new.id, 'Zápas', true, true),
         (new.id, 'Úklid před zápasem', false, true);
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2) the sync trigger: a match row maintains exactly one úklid child sized
--    by prep_minutes ([starts-prep, starts)); prep 0 removes it. The child
--    is a normal blocking slot, so ITS insert/update fires the standard
--    priority cancellation trigger — prep-window collisions keep cancelling
--    exactly as before, just via a visible slot.
-- ---------------------------------------------------------------------------
create or replace function sync_uklid_for_match()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_is_match boolean;
  v_uklid_type uuid;
  v_start time;
begin
  select is_match into v_is_match
  from priority_slot_types where id = new.type_id;
  if not coalesce(v_is_match, false) or new.parent_id is not null then
    return new;
  end if;

  select id into v_uklid_type from priority_slot_types
  where tenant_id = new.tenant_id and builtin and not is_match
    and name = 'Úklid před zápasem';
  if v_uklid_type is null then
    return new;
  end if;

  if coalesce(new.prep_minutes, 0) <= 0 then
    delete from priority_slots where parent_id = new.id;
    return new;
  end if;

  v_start := case
    when extract(epoch from new.starts_at) / 60 >= new.prep_minutes
      then new.starts_at - make_interval(mins => new.prep_minutes)
    else time '00:00'
  end;

  update priority_slots
  set date = new.date, starts_at = v_start, ends_at = new.starts_at
  where parent_id = new.id;
  if not found then
    insert into priority_slots
      (tenant_id, date, starts_at, ends_at, type_id, parent_id, created_by)
    values
      (new.tenant_id, new.date, v_start, new.starts_at, v_uklid_type,
       new.id, new.created_by);
  end if;
  return new;
end;
$$;

create trigger match_uklid_sync
  after insert or update on priority_slots
  for each row execute function sync_uklid_for_match();

-- ---------------------------------------------------------------------------
-- 3) collision predicates lose the prep extension (each slot blocks only
--    its own window — the úklid child covers the prep time explicitly)
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
    and p_slot.starts_at < b.ends_at
    and p_slot.ends_at > b.starts_at;
end;
$$;

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
      and s.starts_at < v_block.ends_at
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

-- move_reservation: same predicate change (no prep extension).
create or replace function move_reservation(
  p_reservation uuid, p_to_block uuid, p_lane int
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_res reservations;
  v_block time_blocks;
  v_lanes int;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;

  select * into v_res from reservations
  where id = p_reservation and tenant_id = current_tenant_id();
  if not found or v_res.cancelled_at is not null then
    raise exception 'unknown_reservation';
  end if;

  select * into v_block from time_blocks
  where id = p_to_block and tenant_id = current_tenant_id();
  if not found then
    raise exception 'unknown_block';
  end if;

  select lane_count into v_lanes from schedule_settings
  where tenant_id = current_tenant_id();
  if p_lane < 1 or p_lane > v_lanes then
    raise exception 'invalid_lane';
  end if;

  if exists (
    select 1 from priority_slots s
    join priority_slot_types t on t.id = s.type_id
    where s.date = v_res.date
      and s.tenant_id = current_tenant_id()
      and (t.lanes is null or p_lane = any (t.lanes))
      and s.starts_at < v_block.ends_at
      and s.ends_at > v_block.starts_at
  ) then
    raise exception 'blocked_by_priority';
  end if;

  if exists (
    select 1 from rentals r
    where r.tenant_id = current_tenant_id()
      and (
        (r.date is not null and r.date = v_res.date)
        or (
          r.weekday is not null
          and r.weekday = extract(isodow from v_res.date)::smallint
          and (r.valid_from is null or v_res.date >= r.valid_from)
          and (r.valid_until is null or v_res.date <= r.valid_until)
        )
      )
      and p_lane = any (r.lanes)
      and r.starts_at < v_block.ends_at and r.ends_at > v_block.starts_at
  ) then
    raise exception 'blocked_by_rental';
  end if;

  update reservations
  set block_id = p_to_block, lane = p_lane
  where id = p_reservation;
exception when unique_violation then
  raise exception 'slot_taken';
end;
$$;

-- ---------------------------------------------------------------------------
-- 4) data migration: fire the sync for every existing match — rows with
--    prep_minutes > 0 get their úklid child (the child's own insert trigger
--    re-covers the prep window's cancellations).
-- ---------------------------------------------------------------------------
update priority_slots set prep_minutes = prep_minutes;
