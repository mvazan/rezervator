-- 0018 — no live reservation may sit outside the rendered grid.
--
-- Rentals and priority slots already cascade-cancel the reservations they
-- displace (0001/0004). The other ways an admin shrinks the grid — fewer
-- lanes, a weekday dropped from training_weekdays, a block deactivated, a
-- day override written or removed outside set_day_override — only warned
-- in the client and then left the rows live but invisible: still counted
-- toward the player's limit and Docházka, impossible to cancel from the
-- grid. The server now cancels them ('změna rozvrhu' or the override's
-- reason, notified) from every path.
--
-- The "does this block render on this date" rule lived only inside
-- create_reservation; block_day_status() makes the RPC and the cascade
-- share one definition.

-- 'open' | 'day_closed' | 'invalid_block' | 'unknown_block' — the codes
-- create_reservation raises. NULL when the tenant has no settings row.
create or replace function block_day_status(
  p_tenant uuid, p_date date, p_block_id uuid
)
returns text
language sql stable security definer set search_path = public
as $$
  select case
    when b.id is null then 'unknown_block'
    when o.tenant_id is not null and o.closed then 'day_closed'
    when o.tenant_id is not null then
      case
        when o.block_ids is null then
          case when b.active then 'open' else 'invalid_block' end
        when p_block_id = any (o.block_ids) then 'open'
        else 'invalid_block'
      end
    when not (extract(isodow from p_date)::smallint
              = any (s.training_weekdays)) then 'day_closed'
    when b.active then 'open'
    else 'invalid_block'
  end
  from schedule_settings s
  left join time_blocks b
    on b.id = p_block_id and b.tenant_id = s.tenant_id
  left join day_overrides o
    on o.tenant_id = s.tenant_id and o.date = p_date
  where s.tenant_id = p_tenant;
$$;
revoke all on function block_day_status(uuid, date, uuid)
  from public, anon, authenticated;

-- Cancels every live, not-yet-started reservation of the tenant that the
-- current grid no longer renders. Returns the number cancelled.
create or replace function cancel_stranded_reservations(
  p_tenant uuid, p_note text default 'změna rozvrhu'
)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_today date := (now() at time zone 'Europe/Prague')::date;
  v_now time := (now() at time zone 'Europe/Prague')::time;
  v_count integer;
begin
  with stranded as (
    update reservations r
    set cancelled_at = now(), cancelled_via = 'admin',
        cancel_note = coalesce(nullif(trim(p_note), ''), 'změna rozvrhu'),
        notify_player = true, notify_message = null
    from time_blocks b, schedule_settings s
    where b.id = r.block_id
      and s.tenant_id = r.tenant_id
      and r.tenant_id = p_tenant
      and r.cancelled_at is null
      and (r.date > v_today or (r.date = v_today and b.starts_at > v_now))
      and (r.lane > s.lane_count
           or block_day_status(r.tenant_id, r.date, r.block_id) <> 'open')
    returning 1
  )
  select count(*) into v_count from stranded;
  return v_count;
end;
$$;
revoke all on function cancel_stranded_reservations(uuid, text)
  from public, anon, authenticated;

create or replace function cascade_schedule_change()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  -- to_jsonb: plpgsql resolves record fields per table, and only
  -- day_overrides has a reason column.
  perform cancel_stranded_reservations(
    coalesce(new.tenant_id, old.tenant_id),
    case when tg_table_name = 'day_overrides' and tg_op <> 'DELETE'
         then to_jsonb(new)->>'reason' else 'změna rozvrhu' end);
  return coalesce(new, old);
end;
$$;

create trigger settings_shrink
  after update of lane_count, training_weekdays on schedule_settings
  for each row execute function cascade_schedule_change();

create trigger block_deactivated
  after update of active on time_blocks
  for each row when (old.active and not new.active)
  execute function cascade_schedule_change();

-- set_day_override still cancels inside the RPC (it also catches today's
-- already-started blocks); this trigger covers direct writes and deletes.
create trigger override_changed
  after insert or update or delete on day_overrides
  for each row execute function cascade_schedule_change();

-- create_reservation: same body as 0010, the override/weekday branch
-- replaced by block_day_status().
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
  v_status text;
  v_via text;
  v_today date := (now() at time zone 'Europe/Prague')::date;
  v_now time := (now() at time zone 'Europe/Prague')::time;
  v_active_count int;
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

  v_status := block_day_status(v_caller.tenant_id, p_date, p_block_id);
  if v_status is distinct from 'open' then
    raise exception '%', coalesce(v_status, 'unknown_block');
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
      and not s.is_away
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

-- reject_tenant: refuse while the superadmin is switched INTO the tenant
-- (the delete would take their own profile with it — 0014 footgun).
create or replace function reject_tenant(p_tenant_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_status text;
begin
  if not is_superadmin() then
    raise exception 'not_allowed';
  end if;
  if exists (
    select 1 from profiles where id = auth.uid() and tenant_id = p_tenant_id
  ) then
    raise exception 'switch_home_first';
  end if;
  select status into v_status from tenants where id = p_tenant_id;
  if not found then
    raise exception 'unknown_tenant';
  end if;
  if v_status <> 'pending' then
    raise exception 'not_pending';
  end if;

  delete from reservations where tenant_id = p_tenant_id;
  delete from priority_slots where tenant_id = p_tenant_id;
  delete from rentals where tenant_id = p_tenant_id;
  delete from day_overrides where tenant_id = p_tenant_id;
  delete from time_blocks where tenant_id = p_tenant_id;
  delete from priority_slot_types where tenant_id = p_tenant_id;
  delete from clubs where tenant_id = p_tenant_id;
  delete from profiles where tenant_id = p_tenant_id;
  delete from schedule_settings where tenant_id = p_tenant_id;
  delete from tenants where id = p_tenant_id;
end;
$$;
