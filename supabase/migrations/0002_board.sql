-- 0002 — board: nick, match prep + home/away, players view, set_nick.
-- Atomic on purpose: the opponent→away_team rename and the
-- cancel_res_for_match replacement must land together, otherwise the live
-- match_conflicts trigger references a missing column between statements.
begin;

alter table profiles add column nick text not null default ''
  check (char_length(nick) <= 14);

alter table matches rename column opponent to away_team;
alter table matches add column home_team text not null default '';
alter table matches add column prep_minutes smallint not null default 0
  check (prep_minutes between 0 and 240);

drop view players;
create view players as
  select id, display_name, club, nick
  from profiles
  where status = 'approved' and role <> 'kiosk';
revoke all on players from anon;
grant select on players to authenticated;

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
  update profiles set nick = trim(coalesce(p_nick, '')) where id = p_user_id;
end;
$$;

-- The single write path for bookings. Authorization: approved player books
-- SELF; admin books anyone; kiosk books any approved player. Validates the
-- day, block, lane, collisions, horizon and per-player limit in one
-- transaction; the partial unique index catches the tap-race.
-- Match-overlap predicate updated for prep_minutes: a reservation collides
-- with a match's prep window too, clamped so `time − interval` never wraps
-- past midnight.
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
      and (case when extract(epoch from m.starts_at) / 60 >= m.prep_minutes
                then m.starts_at - make_interval(mins => m.prep_minutes)
                else time '00:00' end) < v_block.ends_at
      and m.ends_at > v_block.starts_at
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

-- Conflict trigger: a new/edited match cancels the live reservations it
-- overlaps (including its prep window), so nobody is silently double-booked.
-- Only today/future reservations are touched: retroactively entered matches
-- must not corrupt attendance history.
create or replace function cancel_res_for_match()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  -- Never cancel past reservations: preserves attendance history when a
  -- match is entered retroactively.
  update reservations r
  set cancelled_at = now(), cancelled_via = 'admin',
      cancel_note = 'zápas: ' || new.away_team
  from time_blocks b
  where r.block_id = b.id
    and r.cancelled_at is null
    and r.date >= (now() at time zone 'Europe/Prague')::date
    and r.date = new.date
    and (case when extract(epoch from new.starts_at) / 60 >= new.prep_minutes
              then new.starts_at - make_interval(mins => new.prep_minutes)
              else time '00:00' end) < b.ends_at
    and new.ends_at > b.starts_at;
  return new;
end;
$$;

commit;
