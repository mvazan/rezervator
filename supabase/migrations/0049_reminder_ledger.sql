-- 0049 — the reminder ledger (reminders_sent, 0040) says what was announced
-- for which start.
--
-- 1) A receipt covers the event's longer lead times. due_reminders skipped
--    only the exact lead time already sent, so a longer one could ring on
--    its own after a closer one: the player adds „1 den“ an hour after „za
--    2 hodiny“ went out, or notify marks the closer one but fails to mark
--    the longer ones it stood in for, and a second push follows („Trénink
--    za 89 minut“). notify sends one reminder per event and marks the rest
--    (_shared/reminders.ts, oneReminderPerEvent); this makes the ledger
--    agree. A closer lead time still rings after a longer one went out (the
--    day-before reminder, then the two-hours-before one).
--
-- 2) A receipt is for the start it was sent for. Matches are re-dated in
--    place (the ČKA sync and hand edits keep the priority_slots id) and a
--    moved reservation keeps its id, so a receipt keyed only by event and
--    lead time silenced the event at its new time too. reminders_sent gets
--    starts_at; mark_reminder_sent stores it, and marking the same lead time
--    for a new start moves the receipt there. A receipt written before 0049
--    has no start and counts for any, so this deploy rings nothing twice;
--    such rows age out with the 30-day prune.
--
-- Safe to run twice.

-- ------------------------------------------------- reminders_sent.starts_at
alter table reminders_sent add column if not exists starts_at timestamptz;
comment on column reminders_sent.starts_at is
  'The start of the event this reminder announced (0049). A moved event rings again at its new time. Null = written before 0049, counts for any start.';

-- ------------------------------------------------- mark_reminder_sent
-- 0040's plus p_starts_at. The three-argument signature is dropped, not
-- overloaded: notify as deployed before this change calls it with three
-- named arguments and resolves to this one through the default (a null
-- start, the pre-0049 meaning).
drop function if exists mark_reminder_sent(uuid, text, integer);

create or replace function mark_reminder_sent(
  p_user uuid, p_event_key text, p_offset integer,
  p_starts_at timestamptz default null)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  insert into reminders_sent (user_id, event_key, offset_minutes, starts_at)
  values (p_user, p_event_key, p_offset, p_starts_at)
  on conflict (user_id, event_key, offset_minutes) do update
    set starts_at = excluded.starts_at, sent_at = now();
  delete from reminders_sent where sent_at < now() - interval '30 days';
end;
$$;
revoke all on function mark_reminder_sent(uuid, text, integer, timestamptz)
  from public, anon, authenticated;
grant execute on function mark_reminder_sent(uuid, text, integer, timestamptz)
  to service_role;

-- ------------------------------------------------- due_reminders
-- Only the ledger condition changes (1 and 2 above). Same signature, so
-- create or replace keeps 0040's grants (service only) and
-- notifications_due(), which reads this function.
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
      -- Sent at this lead time or a closer one, for this start (or before
      -- 0049, for any): the event was announced.
      and not exists (
        select 1 from reminders_sent s
        where s.user_id = e.user_id
          and s.event_key = e.event_key
          and s.offset_minutes <= o.offset_minutes
          and (s.starts_at is null or s.starts_at = e.starts_ts)
      )
    order by e.starts_ts;
$$;
