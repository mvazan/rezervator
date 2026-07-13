-- 0008 — moving reservations between blocks (day-scoped schedule editing):
-- when a day-only "special" block dissolves back into the template block it
-- copies, its reservations silently move over; and when an admin removes a
-- block that still has sign-ups, the move dialog re-seats them one by one.
-- Both admin-only, tenant-scoped; the partial unique index
-- reservations_slot_live_idx still guards against double-seating (surfaced
-- as slot_taken).

create function move_reservation(
  p_reservation uuid, p_to_block uuid, p_lane int
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_res reservations;
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

  if not exists (
    select 1 from time_blocks
    where id = p_to_block and tenant_id = current_tenant_id()
  ) then
    raise exception 'unknown_block';
  end if;

  select lane_count into v_lanes from schedule_settings
  where tenant_id = current_tenant_id();
  if p_lane < 1 or p_lane > v_lanes then
    raise exception 'invalid_lane';
  end if;

  update reservations
  set block_id = p_to_block, lane = p_lane
  where id = p_reservation;
exception when unique_violation then
  raise exception 'slot_taken';
end;
$$;

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

  -- Lanes carry over 1:1 — the target's live slots must be free or the
  -- whole move fails atomically (slot_taken).
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
