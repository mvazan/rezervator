-- 0021 — one occurrence of a weekly rental may differ without splitting the series.
--
-- A weekly rental blocks its lanes every week for months; giving one evening
-- back (fewer lanes, a shorter slot, the occurrence dropped) meant cutting the
-- series in two, and the "does this rental block this date" predicate lived
-- as a copied expression in create_reservation, move_reservation and the
-- cascade trigger. Exceptions are now child rows of the series in the same
-- table (parent_id + date, like the úklid child of a match in 0009) carrying
-- the full effective lanes/times for that date, or `skipped`; renter_name and
-- color are copied from the series by a trigger and follow its edits.
-- rental_occurrences(tenant, date) is the one resolver every collision check
-- and the cascade go through: an exception that enlarges the rental cancels
-- and notifies like a new rental, one that shrinks it just frees the slots,
-- and deleting it re-applies the series for that date, cancelling whatever
-- was booked in the meantime.

-- ---------------------------------------------------------------------------
-- Columns, constraints, index
-- ---------------------------------------------------------------------------

alter table rentals
  add column parent_id uuid references rentals (id) on delete cascade,
  add column skipped boolean not null default false;

-- A child is date-scoped: the series' weekday/validity never appear on it
-- (rentals_check1 — date XOR weekday — still holds for it).
alter table rentals
  add constraint rentals_exception_shape_check check (
    parent_id is null
    or (date is not null and weekday is null
        and valid_from is null and valid_until is null)),
  add constraint rentals_skipped_check check (not skipped or parent_id is not null);

-- One exception per series and date; also serves the FK cascade lookup.
create unique index rentals_parent_date_idx on rentals (parent_id, date)
  where parent_id is not null;

comment on column rentals.parent_id is
  'Exception row: overrides the series for `date`; skipped = the occurrence does not happen.';

-- ---------------------------------------------------------------------------
-- Resolver
-- ---------------------------------------------------------------------------

-- Does the top-level row r (one-time or weekly) occur on p_date?
create or replace function rental_occurs(r rentals, p_date date)
returns boolean
language sql immutable
as $$
  select case
    when r.date is not null then r.date = p_date
    else r.weekday = extract(isodow from p_date)::smallint
         and (r.valid_from is null or p_date >= r.valid_from)
         and (r.valid_until is null or p_date <= r.valid_until)
  end;
$$;
revoke all on function rental_occurs(rentals, date)
  from public, anon, authenticated;

-- The rentals in force on p_date: every top-level row (one-time AND weekly)
-- occurring that day, the date's child applied — its lanes/times replace the
-- series', a skipped child removes the occurrence. `language sql` on
-- purpose: in plpgsql the OUT names would shadow the columns.
create or replace function rental_occurrences(p_tenant uuid, p_date date)
returns table (
  rental_id uuid, override_id uuid, renter_name text,
  lanes smallint[], starts_at time, ends_at time
)
language sql stable security definer set search_path = public
as $$
  select p.id, c.id, p.renter_name,
         coalesce(c.lanes, p.lanes),
         coalesce(c.starts_at, p.starts_at),
         coalesce(c.ends_at, p.ends_at)
  from rentals p
  left join rentals c
    on c.parent_id = p.id and c.tenant_id = p.tenant_id and c.date = p_date
  where p.tenant_id = p_tenant
    and p.parent_id is null
    and rental_occurs(p, p_date)
    and not coalesce(c.skipped, false);
$$;
revoke all on function rental_occurrences(uuid, date)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Child rows: validation + name/colour copy (BEFORE), series edits (AFTER)
-- ---------------------------------------------------------------------------

-- A child must hang under a weekly series of its own tenant, on a date the
-- series occurs on, and can neither be a series itself nor have children.
-- NOT NULL is checked after BEFORE ROW triggers, so a client may omit
-- renter_name/color on a child — they are always the series'.
create or replace function rental_exception_guard()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_parent rentals;
begin
  select * into v_parent from rentals where id = new.parent_id;
  if not found
     or new.parent_id = new.id
     or v_parent.tenant_id <> new.tenant_id
     or v_parent.parent_id is not null      -- no exception of an exception
     or v_parent.weekday is null            -- one-time rentals have no series
     or new.date is null
     or not rental_occurs(v_parent, new.date)
     or exists (select 1 from rentals where parent_id = new.id) then
    raise exception 'rental_exception_invalid';
  end if;
  new.renter_name := v_parent.renter_name;
  new.color := v_parent.color;
  return new;
end;
$$;
create trigger rental_exception_guard
  before insert or update on rentals
  for each row when (new.parent_id is not null)
  execute function rental_exception_guard();

-- A series edit prunes the children that no longer lie on it (moved weekday
-- or validity window, or the row turned one-time) and re-copies its name
-- and colour onto the rest. Prune BEFORE propagating: an orphan's guard
-- would otherwise reject the copy and abort the edit.
create or replace function rental_series_changed()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.weekday is null then
    delete from rentals where parent_id = new.id;
  elsif old.weekday is distinct from new.weekday
     or old.valid_from is distinct from new.valid_from
     or old.valid_until is distinct from new.valid_until then
    delete from rentals c
    where c.parent_id = new.id and not rental_occurs(new, c.date);
  end if;
  if old.renter_name is distinct from new.renter_name
     or old.color is distinct from new.color then
    update rentals set renter_name = new.renter_name, color = new.color
    where parent_id = new.id;
  end if;
  return new;
end;
$$;
create trigger rental_series_changed
  after update on rentals
  for each row when (old.parent_id is null)
  execute function rental_series_changed();

-- ---------------------------------------------------------------------------
-- Cascade: the resolver decides what a rental covers
-- ---------------------------------------------------------------------------

-- A series row cancels every live future reservation its resolved
-- occurrences cover (exceptions applied); a child row only those on its
-- date — on UPDATE also the date it left, on DELETE the series re-applies
-- and cancels what was booked in the meantime. A deleted series frees
-- slots and cancels nothing, as before. `update … from` cannot LATERAL-join
-- its own target relation, hence the victim subquery.
create or replace function cancel_res_for_rental()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_row rentals;
  v_old_date date;
  v_today date := (now() at time zone 'Europe/Prague')::date;
begin
  if tg_op = 'DELETE' then
    if old.parent_id is null then
      return old;
    end if;
    v_row := old;
  else
    v_row := new;
    if tg_op = 'UPDATE' then
      v_old_date := old.date;
    end if;
  end if;

  update reservations r
  set cancelled_at = now(), cancelled_via = 'admin',
      cancel_note = 'pronájem: ' || x.renter_name,
      notify_player = true,
      notify_message = null
  from (
    select r2.id, o.renter_name
    from reservations r2
    join time_blocks b on b.id = r2.block_id
    cross join lateral rental_occurrences(v_row.tenant_id, r2.date) o
    where r2.tenant_id = v_row.tenant_id
      and r2.cancelled_at is null
      and r2.date >= v_today
      and (v_row.parent_id is null            -- series: every date from today on
           or r2.date = v_row.date             -- exception: its date
           or r2.date = v_old_date)            -- …and the date it left
      and o.rental_id = coalesce(v_row.parent_id, v_row.id)
      and r2.lane = any (o.lanes)
      and b.starts_at < o.ends_at and b.ends_at > o.starts_at
  ) x
  where r.id = x.id;

  return coalesce(new, old);
end;
$$;

drop trigger if exists rental_conflicts on rentals;
create trigger rental_conflicts
  after insert or update or delete on rentals
  for each row execute function cancel_res_for_rental();

-- ---------------------------------------------------------------------------
-- RPCs: the inline rental predicate becomes the resolver (bodies otherwise
-- unchanged from 0018 / 0011)
-- ---------------------------------------------------------------------------

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
    select 1 from rental_occurrences(v_caller.tenant_id, p_date) o
    where p_lane = any (o.lanes)
      and o.starts_at < v_block.ends_at and o.ends_at > v_block.starts_at
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

create or replace function move_reservation(
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
    select 1 from rental_occurrences(current_tenant_id(), v_res.date) o
    where p_lane = any (o.lanes)
      and o.starts_at < v_block.ends_at and o.ends_at > v_block.starts_at
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
