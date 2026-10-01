-- 0058 — „Hlídat uvolněná místa“: a player turns a bell on for a DAY, and when
-- somebody cancels a training that day — a spot nobody holds any more — the
-- player gets a push (e-mail without a token) and can book it.
--
-- slot_watches: one row per (player, day), for the whole day (`block_ids` null)
-- or for the blocks the player picked. Read by its owner (the bell's
-- state), written only through watch_day / unwatch_day. `last_notified_at`
-- is the throttle: a burst of cancellations (an admin clearing a block) tells
-- a watcher once per ten minutes, not once per spot.
--
-- claim_freed_spot_watchers(reservation): called by the notify function with
-- the service role when a reservation turns cancelled. Says nothing unless the
-- cell is really bookable again (the block has not started, the day is open,
-- no match or rental sits on the lane, nobody booked it already) — a cancel
-- caused by a closed day or a rental frees nothing. Of the day's watchers it
-- keeps the ones who can book it: approved, not the player who cancelled, not
-- at the reservation cap (an admin has none), the date inside the booking
-- horizon, no live booking of their own in that block. It stamps
-- `last_notified_at` in the same statement, so two cancellations at once do
-- not both claim the same watcher.
--
-- A watcher who books what they watch is done (trigger below): they got what
-- they came for — any booking that day for a whole-day watch, a booking in
-- one of the picked blocks for a block watch. Past days are pruned nightly.

create table if not exists slot_watches (
  user_id uuid not null references profiles(id) on delete cascade,
  tenant_id uuid not null references tenants(id) on delete cascade,
  date date not null,
  -- the blocks of that day the player cares about; null = the whole day
  block_ids uuid[] check (block_ids is null or cardinality(block_ids) between 1 and 24),
  created_at timestamptz not null default now(),
  last_notified_at timestamptz,
  primary key (user_id, date)
);
create index if not exists slot_watches_day_idx on slot_watches (tenant_id, date);
-- Realtime checks a DELETE against the replica identity alone.
alter table slot_watches replica identity full;

alter table slot_watches enable row level security;
drop policy if exists slot_watches_select on slot_watches;
create policy slot_watches_select on slot_watches for select
  using (user_id = auth.uid());

-- service_role first: pg_dump writes GRANTs in ACL order (see 0051).
revoke all on slot_watches from anon, authenticated;
grant all on slot_watches to service_role;
grant select on slot_watches to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public'
                   and tablename = 'slot_watches') then
    alter publication supabase_realtime add table slot_watches;
  end if;
end $$;

-- ---------------------------------------------------------------- watch_day
create or replace function watch_day(p_date date, p_block_ids uuid[] default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_caller profiles;
  v_settings schedule_settings;
  v_today date := (now() at time zone 'Europe/Prague')::date;
  v_blocks uuid[];
begin
  select * into v_caller from profiles where id = v_uid;
  if not found or v_caller.status <> 'approved' or v_caller.role = 'kiosk' then
    raise exception 'not_allowed';
  end if;
  select * into v_settings from schedule_settings
   where tenant_id = v_caller.tenant_id;
  if p_date < v_today then
    raise exception 'date_past';
  end if;
  -- Beyond the horizon nothing is bookable yet, so nothing can be freed.
  if v_caller.role <> 'admin' and p_date > v_today + v_settings.booking_horizon_days then
    raise exception 'beyond_horizon';
  end if;
  -- An empty pick is the whole day; a pick must be blocks of the caller's alley.
  v_blocks := case when p_block_ids is null or cardinality(p_block_ids) = 0
                   then null else p_block_ids end;
  if v_blocks is not null and (
       cardinality(v_blocks) > 24
       or exists (select 1 from unnest(v_blocks) b(id)
                   where not exists (select 1 from time_blocks t
                                      where t.id = b.id and t.tenant_id = v_caller.tenant_id))) then
    raise exception 'unknown_block';
  end if;
  if (select count(*) from slot_watches
       where user_id = v_uid and date >= v_today and date <> p_date) >= 30 then
    raise exception 'too_many_watches';
  end if;
  insert into slot_watches (user_id, tenant_id, date, block_ids)
  values (v_uid, v_caller.tenant_id, p_date, v_blocks)
  on conflict (user_id, date)
    do update set block_ids = excluded.block_ids, last_notified_at = null;
end;
$$;

create or replace function unwatch_day(p_date date) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from slot_watches where user_id = auth.uid() and date = p_date;
end;
$$;

-- ----------------------------------------------- claim_freed_spot_watchers
create or replace function claim_freed_spot_watchers(p_reservation uuid)
returns table (user_id uuid, email text, fcm_token text)
language plpgsql security definer set search_path = public as $$
declare
  v_r reservations;
  v_block time_blocks;
  v_settings schedule_settings;
  v_today date := (now() at time zone 'Europe/Prague')::date;
  v_now time := (now() at time zone 'Europe/Prague')::time;
begin
  select * into v_r from reservations where id = p_reservation;
  if not found or v_r.cancelled_at is null then
    return;
  end if;
  select * into v_block from time_blocks where id = v_r.block_id;
  if not found then
    return;
  end if;
  select * into v_settings from schedule_settings where tenant_id = v_r.tenant_id;

  -- Nobody can book a block that has started, or a day that is over.
  if v_r.date < v_today or (v_r.date = v_today and v_block.starts_at <= v_now) then
    return;
  end if;
  -- The cell must be bookable again: the day open for the block, no match and
  -- no rental on the lane, and not booked by somebody else already.
  if block_day_status(v_r.tenant_id, v_r.date, v_r.block_id) is distinct from 'open' then
    return;
  end if;
  if exists (
    select 1 from priority_slots s
    join priority_slot_types t on t.id = s.type_id
    where s.date = v_r.date and s.tenant_id = v_r.tenant_id and not s.is_away
      and (t.lanes is null or v_r.lane = any (t.lanes))
      and s.starts_at < v_block.ends_at and s.ends_at > v_block.starts_at
  ) then
    return;
  end if;
  if exists (
    select 1 from rental_occurrences(v_r.tenant_id, v_r.date) o
    where v_r.lane = any (o.lanes)
      and o.starts_at < v_block.ends_at and o.ends_at > v_block.starts_at
  ) then
    return;
  end if;
  if exists (
    select 1 from reservations x
    where x.date = v_r.date and x.block_id = v_r.block_id
      and x.lane = v_r.lane and x.cancelled_at is null
  ) then
    return;
  end if;

  return query
  with claimed as (
    update slot_watches w
       set last_notified_at = now()
      from profiles p
     where w.date = v_r.date
       and w.tenant_id = v_r.tenant_id
       and p.id = w.user_id
       and p.status = 'approved'
       and p.role <> 'kiosk'
       and w.user_id <> v_r.player_id
       and (w.block_ids is null or v_r.block_id = any (w.block_ids))
       and (w.last_notified_at is null
            or w.last_notified_at < now() - interval '10 minutes')
       and (p.role = 'admin'
            or (v_r.date <= v_today + v_settings.booking_horizon_days
                and (select count(*) from reservations a
                      where a.player_id = p.id and a.cancelled_at is null
                        and a.date >= v_today) < v_settings.max_active_reservations))
       and not exists (
         select 1 from reservations h
          where h.player_id = p.id and h.date = v_r.date
            and h.block_id = v_r.block_id and h.cancelled_at is null)
    returning w.user_id as uid
  )
  select p.id, p.email, p.fcm_token
    from claimed c join profiles p on p.id = c.uid;
end;
$$;

revoke all on function watch_day(date, uuid[]), unwatch_day(date) from public, anon;
grant execute on function watch_day(date, uuid[]), unwatch_day(date) to authenticated;
revoke all on function claim_freed_spot_watchers(uuid) from public, anon, authenticated;
grant execute on function claim_freed_spot_watchers(uuid) to service_role;

-- ------------------------------------------- a booking ends the day's watch
create or replace function slot_watches_end_on_booking() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from slot_watches
   where user_id = new.player_id and date = new.date
     and (block_ids is null or new.block_id = any (block_ids));
  return new;
end;
$$;
revoke all on function slot_watches_end_on_booking() from public, anon, authenticated;

drop trigger if exists reservations_end_watch on reservations;
create trigger reservations_end_watch
  after insert on reservations
  for each row execute function slot_watches_end_on_booking();

-- ------------------------------------------------------------------- prune
create or replace function prune_slot_watches() returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_n integer;
begin
  delete from slot_watches
   where date < (now() at time zone 'Europe/Prague')::date;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke all on function prune_slot_watches() from public, anon, authenticated;
grant execute on function prune_slot_watches() to service_role;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'slot-watches-prune') then
    perform cron.unschedule('slot-watches-prune');
  end if;
  perform cron.schedule('slot-watches-prune', '25 3 * * *', 'select public.prune_slot_watches()');
end $$;
