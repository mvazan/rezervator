-- 0011 — phase 3: notification choice on reservation moves & cancels.
--
-- Two per-change intent columns on reservations carry the admin's choice to
-- the notify Edge Function (the UPDATE trigger ships old+new rows there):
--   notify_player  — send a notification about THIS change?
--   notify_message — optional custom text replacing the standard wording.
-- EVERY mutating path sets them explicitly: the move/cancel RPCs from their
-- new p_notify/p_message params, bulk cancellation paths always true — a
-- silent move must never leave a stale `false` behind that would swallow a
-- later cancellation notice.

alter table reservations
  add column notify_player boolean not null default true,
  add column notify_message text;

-- ---------------------------------------------------------------------------
-- 1) move_reservation gains p_notify + p_message. DROP first: adding
--    defaulted params would otherwise leave an ambiguous overload for
--    PostgREST.
-- ---------------------------------------------------------------------------
drop function move_reservation(uuid, uuid, int);

create function move_reservation(
  p_reservation uuid, p_to_block uuid, p_lane int,
  p_notify boolean default true, p_message text default null
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
      and not s.is_away
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
  set block_id = p_to_block, lane = p_lane,
      notify_player = coalesce(p_notify, true),
      notify_message = nullif(trim(coalesce(p_message, '')), '')
  where id = p_reservation;
exception when unique_violation then
  raise exception 'slot_taken';
end;
$$;

-- ---------------------------------------------------------------------------
-- 2) move_day_reservations gains the same pair.
-- ---------------------------------------------------------------------------
drop function move_day_reservations(date, uuid, uuid);

create function move_day_reservations(
  p_date date, p_from_block uuid, p_to_block uuid,
  p_notify boolean default true, p_message text default null
)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;

  if not exists (
    select 1 from time_blocks
    where id = p_from_block and tenant_id = current_tenant_id()
  ) or not exists (
    select 1 from time_blocks
    where id = p_to_block and tenant_id = current_tenant_id()
  ) then
    raise exception 'unknown_block';
  end if;

  update reservations
  set block_id = p_to_block,
      notify_player = coalesce(p_notify, true),
      notify_message = nullif(trim(coalesce(p_message, '')), '')
  where date = p_date
    and block_id = p_from_block
    and cancelled_at is null
    and tenant_id = current_tenant_id();
exception when unique_violation then
  raise exception 'slot_taken';
end;
$$;

-- ---------------------------------------------------------------------------
-- 3) cancel_reservation gains p_notify (p_note doubles as the message —
--    it already lands in the notification as the reason).
-- ---------------------------------------------------------------------------
drop function cancel_reservation(uuid, text);

create function cancel_reservation(
  p_id uuid, p_note text default '', p_notify boolean default true
)
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
  set cancelled_at = v_now, cancelled_via = v_via,
      cancel_note = trim(coalesce(p_note, '')),
      notify_player = coalesce(p_notify, true),
      notify_message = null
  where id = p_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4) Bulk cancellation paths always notify: reset the intent columns so a
--    stale silent-move `false` can't swallow the cancellation notice.
-- ---------------------------------------------------------------------------
create or replace function cancel_block_day_reservations(
  p_date date, p_block uuid, p_note text default 'změna rozvrhu'
)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if not exists (
    select 1 from time_blocks
    where id = p_block and tenant_id = current_tenant_id()
  ) then
    raise exception 'unknown_block';
  end if;

  update reservations
  set cancelled_at = now(),
      cancelled_via = 'admin',
      cancel_note = coalesce(nullif(trim(p_note), ''), 'změna rozvrhu'),
      notify_player = true,
      notify_message = null
  where date = p_date
    and block_id = p_block
    and cancelled_at is null
    and tenant_id = current_tenant_id();
end;
$$;

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
      cancel_note = coalesce(nullif(trim(p_reason), ''), 'změna rozvrhu'),
      notify_player = true,
      notify_message = null
  where r.date = p_date
    and r.tenant_id = current_tenant_id()
    and r.cancelled_at is null
    and (p_closed or (p_block_ids is not null and not (r.block_id = any (p_block_ids))));
end;
$$;

create or replace function cancel_res_for_rental()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  update reservations r
  set cancelled_at = now(), cancelled_via = 'admin',
      cancel_note = 'pronájem: ' || new.renter_name,
      notify_player = true,
      notify_message = null
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

create or replace function cancel_res_for_priority_slot(p_slot priority_slots)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_type priority_slot_types;
begin
  if coalesce(p_slot.is_away, false) then
    return;
  end if;
  select * into v_type from priority_slot_types where id = p_slot.type_id;
  update reservations r
  set cancelled_at = now(), cancelled_via = 'admin',
      cancel_note = case when v_type.is_match
                         then 'zápas: ' || p_slot.away_team
                         else v_type.name end,
      notify_player = true,
      notify_message = null
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
