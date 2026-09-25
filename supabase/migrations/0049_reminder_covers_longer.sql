-- 0049 — a reminder that went out covers the longer lead times of the same
-- event. due_reminders (0040) skipped only the exact lead time already in
-- reminders_sent, so a longer one could ring on its own after a closer one:
-- the player adds „1 den“ an hour after „za 2 hodiny“ went out, or notify
-- marks the closer one but fails to mark the longer ones it stood in for,
-- and a second push follows („Trénink za 89 minut“). notify sends one
-- reminder per event and marks the rest (_shared/reminders.ts,
-- oneReminderPerEvent); this makes the ledger agree. A closer lead time
-- still rings after a longer one went out (the day-before reminder, then
-- the two-hours-before one).
--
-- Only the ledger condition changes: `s.offset_minutes <= o.offset_minutes`
-- instead of `=`. Same signature, so create or replace keeps 0040's grants
-- (service only) and notifications_due(), which reads this function.

create or replace function due_reminders()
returns table (
  user_id uuid, email text, fcm_token text, event_key text,
  offset_minutes integer, kind text, starts_at timestamptz, ends_at time,
  lane smallint, alley_name text, home_team text, away_team text,
  is_away boolean)
language sql stable security definer set search_path = public
as $$
  with people as (
    -- No fcm_token condition: a player without the app is reachable by
    -- e-mail, and notify picks the channel for every message the same way.
    select p.id, p.email, p.fcm_token, p.notify_before_minutes
      from profiles p
      where p.status = 'approved'
        and not p.placeholder  -- hráč bez účtu se nikam nepřihlašuje
        and coalesce(array_length(p.notify_before_minutes, 1), 0) > 0
  ),
  events as (
    select pe.id as user_id, pe.email, pe.fcm_token, pe.notify_before_minutes,
           'training' as kind,
           'r:' || r.reservation_id as event_key,
           ((r.date + r.starts_at) at time zone 'Europe/Prague') as starts_ts,
           r.ends_at, r.lane, r.alley_name,
           null::text as home_team, null::text as away_team,
           null::boolean as is_away
      from people pe
      cross join lateral my_future_reservations(pe.id) r
    union all
    select pe.id, pe.email, pe.fcm_token, pe.notify_before_minutes,
           'match',
           'm:' || m.match_id,
           ((m.date + m.starts_at) at time zone 'Europe/Prague'),
           m.ends_at, null::smallint, null::text,
           m.home_team, m.away_team, m.is_away
      from people pe
      cross join lateral my_upcoming_matches(pe.id) m
  )
  select e.user_id, e.email, e.fcm_token, e.event_key, o.offset_minutes::integer,
         e.kind, e.starts_ts, e.ends_at, e.lane, e.alley_name,
         e.home_team, e.away_team, e.is_away
    from events e
    cross join lateral unnest(e.notify_before_minutes) as o(offset_minutes)
    where e.starts_ts > now()
      and e.starts_ts - make_interval(mins => o.offset_minutes) <= now()
      -- Sent at this lead time or at a closer one: the event was announced.
      and not exists (
        select 1 from reminders_sent s
        where s.user_id = e.user_id
          and s.event_key = e.event_key
          and s.offset_minutes <= o.offset_minutes
      )
    order by e.starts_ts;
$$;
