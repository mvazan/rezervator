-- 0004 — priority slots: generalize matches into typed priority slots.
-- A slot type (šablóna) carries the label, palette color and lane scope
-- (null = whole alley); 'Zápas' is the seeded built-in match kind that keeps
-- the team fields + prep window. The `matches` table is RENAMED (data,
-- indexes, FKs, policies and realtime membership survive) rather than
-- copied. Also folds in two unrelated fixes agreed for this release:
--   * create_reservation gains a time-of-day guard (non-admins can no longer
--     book today's already-started block — mirrors the client's inPast),
--   * monthly_attendance resolves the club via clubs.name (club_id) with the
--     legacy free-text profiles.club as fallback.
begin;

create table priority_slot_types (
  id uuid primary key default gen_random_uuid(),
  name text unique not null,
  color smallint not null default -1 check (color between -1 and 11),
  lanes smallint[] check (lanes is null or cardinality(lanes) > 0),
  is_match boolean not null default false,
  builtin boolean not null default false,
  created_at timestamptz not null default now()
);

insert into priority_slot_types (name, is_match, builtin)
values ('Zápas', true, true);

alter table matches rename to priority_slots;
alter table priority_slots add column type_id uuid
  references priority_slot_types (id) on delete restrict;
update priority_slots
  set type_id = (select id from priority_slot_types where builtin and is_match);
alter table priority_slots alter column type_id set not null;
alter table priority_slots alter column away_team set default '';

-- RLS: everyone approved (or the kiosk) reads types; admins manage them, but
-- may never delete the built-in kind nor flip is_match/builtin from a client
-- (column grants restrict updates to name/color/lanes).
alter table priority_slot_types enable row level security;
create policy slot_types_select on priority_slot_types
  for select using (is_approved_or_kiosk());
create policy slot_types_insert on priority_slot_types
  for insert with check (is_admin());
create policy slot_types_update on priority_slot_types
  for update using (is_admin()) with check (is_admin());
create policy slot_types_delete on priority_slot_types
  for delete using (is_admin() and not builtin);
revoke insert, update on priority_slot_types from authenticated;
grant insert (name, color, lanes) on priority_slot_types to authenticated;
grant update (name, color, lanes) on priority_slot_types to authenticated;

alter publication supabase_realtime add table priority_slot_types;

-- The single write path for bookings — full replace of 0002's version.
-- Changes: (1) non-admin time-of-day guard; (2) the match-collision check
-- becomes the priority-slot check (prep-aware AND lane-aware via the type).
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
    -- Mirrors the client's inPast: a block that already started today is
    -- past (the client hides it; this closes the server-side hole).
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

-- Shared cancellation core: cancels live today/future reservations colliding
-- with one priority slot (prep-extended window, lane-scoped by its type).
-- Never touches past reservations (attendance history).
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

drop trigger if exists match_conflicts on priority_slots;
drop function if exists cancel_res_for_match();

create or replace function cancel_res_for_priority()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  perform cancel_res_for_priority_slot(new);
  return new;
end;
$$;

create trigger priority_conflicts
  after insert or update on priority_slots
  for each row execute function cancel_res_for_priority();

-- Editing a TYPE (widening lanes, whole-alley switch) must re-run the
-- cancellation for its future slots, or newly-colliding reservations survive.
create or replace function cancel_res_for_type_change()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_slot priority_slots;
begin
  for v_slot in
    select * from priority_slots
    where type_id = new.id
      and date >= (now() at time zone 'Europe/Prague')::date
  loop
    perform cancel_res_for_priority_slot(v_slot);
  end loop;
  return new;
end;
$$;

create trigger slot_type_conflicts
  after update on priority_slot_types
  for each row execute function cancel_res_for_type_change();

-- Attendance: the clubs table (club_id) is authoritative; the legacy
-- free-text profiles.club only fills in for never-reassigned players.
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
  where r.cancelled_at is null
    and extract(year from r.date)::int = p_year
    and extract(month from r.date)::int = p_month
    and r.date <= (now() at time zone 'Europe/Prague')::date
  group by p.id, p.display_name, coalesce(c.name, nullif(p.club, ''), '')
  order by count(r.id) desc, p.display_name;
end;
$$;

commit;
