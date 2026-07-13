-- 0008 — moving/cancelling reservations for day-scoped schedule editing:
-- when a day-only "special" block dissolves back into the template block it
-- copies, its reservations silently move over; when an admin removes a block
-- that still has sign-ups, the move dialog re-seats them one by one; and
-- when a special HIDES a template block, that block's live sign-ups for the
-- day are cancelled (mirroring what priority slots do server-side — a
-- hidden block must not keep invisible live reservations that double-book
-- the physical lanes). All admin-only, tenant-scoped.

-- Cancels every live reservation on [p_date] × [p_block] with a note —
-- the client calls this when a day-special hides the block (after an
-- explicit count+confirm), or when unwinding legacy forks.
create function cancel_block_day_reservations(
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
      cancel_note = coalesce(nullif(trim(p_note), ''), 'změna rozvrhu')
  where date = p_date
    and block_id = p_block
    and cancelled_at is null
    and tenant_id = current_tenant_id();
end;
$$;

-- Moves one live reservation to another block/lane. Mirrors
-- create_reservation's physical-collision rules: the target slot must not
-- be seated (slot_taken via the live-slot unique index), rented
-- (blocked_by_rental) or priority-blocked (blocked_by_priority) — a move
-- must not seat a player somewhere the booking path would refuse.
create function move_reservation(
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
      and (case when extract(epoch from s.starts_at) / 60 >= s.prep_minutes
                then s.starts_at - make_interval(mins => s.prep_minutes)
                else time '00:00' end) < v_block.ends_at
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

-- Bulk 1:1-lane move for the dissolve flow ONLY: the source special and the
-- target twin share the exact time window, so anything rentable/blockable
-- on the twin covered the special too — no extra collision rules needed
-- beyond the live-slot unique index (slot_taken).
create function move_day_reservations(
  p_date date, p_from_block uuid, p_to_block uuid
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
  set block_id = p_to_block
  where date = p_date
    and block_id = p_from_block
    and cancelled_at is null
    and tenant_id = current_tenant_id();
exception when unique_violation then
  raise exception 'slot_taken';
end;
$$;
