-- 0032 — a second Google calendar and per-team event colours.
--
-- Google's calendar.app.created scope hides calendarList for an app-created
-- calendar (measured against the production API, 401 either way), so a
-- colour or a default reminder can never live on the calendar itself — only
-- on the event. That makes a followed team more than a name: it now needs
-- its OWN calendar (primary/secondary) and its OWN Google event colourId
-- (1-11, null = none), so a bare text[] no longer holds it. A team becomes a
-- ROW.
--
-- google_calendar_links.match_teams stays untouched and readable — the app
-- (calendar-manage) still writes it — but nothing here reads it any more;
-- it is dead weight until Task 3 drops it and set_calendar_match_teams_for
-- together, once the edge functions have moved to set_calendar_teams_for.

create table calendar_teams (
  user_id  uuid not null references profiles(id) on delete cascade,
  team     text not null,
  calendar text not null default 'primary'
    check (calendar in ('primary', 'secondary')),
  color_id smallint check (color_id between 1 and 11),
  primary key (user_id, team)
);
comment on table calendar_teams is
  'One row per player+followed team (0032, replaces google_calendar_links.match_teams): which of the two calendars its matches go to and which Google event colourId they get.';
comment on column calendar_teams.calendar is
  'Which of the player''s Google calendars this team''s matches go to; secondary only means something once google_calendar_links.secondary_enabled is true.';
comment on column calendar_teams.color_id is
  'Google Calendar event colorId (1-11); null = no colour, the event takes the calendar''s own.';

-- Own row only, both ways — the Flutter app streams and edits this table
-- directly (no RPC round trip needed just to tick a box), unlike the
-- server-only calendar tables below.
alter table calendar_teams enable row level security;
create policy calendar_teams_own on calendar_teams
  using (user_id = auth.uid()) with check (user_id = auth.uid());

alter table google_calendar_links
  add column secondary_enabled boolean not null default false,
  add column reminder_minutes_secondary integer[] not null default '{}'
    check (coalesce(array_length(reminder_minutes_secondary, 1), 0) <= 5
           and 0 <= all (reminder_minutes_secondary)
           and 40320 >= all (reminder_minutes_secondary)),
  add column training_color_id smallint check (training_color_id between 1 and 11);
comment on column google_calendar_links.secondary_enabled is
  'Player turned on the second Google calendar ("Rezervátor 2"); calendar_teams rows may then target it.';
comment on column google_calendar_links.reminder_minutes_secondary is
  'Reminders for events written to the secondary calendar; same shape and bounds as reminder_minutes.';
comment on column google_calendar_links.training_color_id is
  'Google Calendar event colorId (1-11) for trainings, which always go to the primary calendar; null = no colour.';

alter table google_calendar_tokens add column google_calendar_id_secondary text;
comment on column google_calendar_tokens.google_calendar_id_secondary is
  'The player''s secondary Google calendar id; null until secondary_enabled is turned on.';

-- Spill today's picks into rows — nobody's calendar changes. calendar stays
-- the default 'primary', color_id the default null, matching how those
-- teams behave today.
insert into calendar_teams (user_id, team)
select user_id, unnest(match_teams) from google_calendar_links
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Functions — same bodies, now reading calendar_teams
-- ---------------------------------------------------------------------------

-- Every linked player of the tenant who follows one of the two teams.
-- distinct: a player who follows BOTH teams of a derby has two calendar_teams
-- rows that both match, and must still come back once.
create or replace function match_calendar_followers(
  p_tenant uuid, p_home text, p_away text)
returns setof uuid
language sql stable security definer set search_path = public
as $$
  select distinct l.user_id
    from google_calendar_links l
    join profiles p on p.id = l.user_id
    join calendar_teams t on t.user_id = l.user_id and t.team in (p_home, p_away)
    where p.tenant_id = p_tenant
      and l.status = 'linked';
$$;

-- The events' raw material for one player: live future matches of the teams
-- they follow, in their kuželna, each carrying the calendar and colour its
-- team was given. A derby (both teams followed) is one match, not two rows —
-- the lateral picks the home team's calendar_teams row when both match, same
-- as the join condition on either side would; ties never occur otherwise
-- since a player has at most one row per team name.
drop function my_future_matches(uuid);
create function my_future_matches(p_user uuid)
returns table (
  match_id uuid, date date, starts_at time, ends_at time,
  home_team text, away_team text, is_away boolean, description text,
  alley_name text, calendar text, color_id smallint)
language sql stable security definer set search_path = public
as $$
  select s.id, s.date, s.starts_at, s.ends_at,
         s.home_team, s.away_team, s.is_away, s.description, t.name,
         c.calendar, c.color_id
    from priority_slots s
    join priority_slot_types y on y.id = s.type_id and y.is_match
    join tenants t on t.id = s.tenant_id
    join profiles p on p.id = p_user and p.tenant_id = s.tenant_id
    join google_calendar_links l on l.user_id = p_user
    join lateral (
      select ct.calendar, ct.color_id
        from calendar_teams ct
        where ct.user_id = p_user and ct.team in (s.home_team, s.away_team)
        order by (ct.team = s.home_team) desc
        limit 1
    ) c on true
    where s.parent_id is null
      and s.date >= (now() at time zone 'Europe/Prague')::date
    order by s.date, s.starts_at;
$$;
revoke all on function my_future_matches(uuid) from public, anon, authenticated;
grant execute on function my_future_matches(uuid) to service_role;

-- Replaces set_calendar_match_teams_for (which stays for now, see header):
-- the player's team+calendar+colour choices on their behalf (calendar-manage
-- runs as the service role, so auth.uid() is null there). Returns the
-- PREVIOUS rows as jsonb so the caller can diff and delete dropped teams'
-- events, same contract as the function it replaces. calendar/color_id
-- bounds are the table's own CHECK constraints (check_violation) — no need
-- to repeat them here; only the row count is something only this function
-- can enforce. delete+insert is one statement, so a bad row rolls the whole
-- write back.
create function set_calendar_teams_for(p_user uuid, p_teams jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_teams jsonb := coalesce(p_teams, '[]'::jsonb);
  v_previous jsonb;
begin
  if jsonb_typeof(v_teams) <> 'array' then
    raise exception 'bad_teams';
  end if;
  if jsonb_array_length(v_teams) > 20 then
    raise exception 'bad_teams';
  end if;
  if not exists (select 1 from google_calendar_links where user_id = p_user) then
    raise exception 'unknown_link';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'team', team, 'calendar', calendar, 'color_id', color_id)
           order by team), '[]'::jsonb)
    into v_previous
    from calendar_teams where user_id = p_user;

  delete from calendar_teams where user_id = p_user;
  insert into calendar_teams (user_id, team, calendar, color_id)
  select p_user, trim(x.team), coalesce(x.calendar, 'primary'), x.color_id
    from jsonb_to_recordset(v_teams) as x(team text, calendar text, color_id smallint);

  return v_previous;
end;
$$;
revoke all on function set_calendar_teams_for(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function set_calendar_teams_for(uuid, jsonb) to service_role;

-- Widened with a calendar slot (default 'primary' = today's only behaviour,
-- so every existing 2-argument call keeps working unchanged); writes the
-- matching reminders column. The 2-argument overload is dropped first —
-- otherwise it would keep winning over the new default for 2-argument
-- calls, and the 3rd argument would never engage.
drop function set_calendar_reminders_for(uuid, integer[]);
create function set_calendar_reminders_for(
  p_user uuid, p_minutes integer[], p_calendar text default 'primary')
returns integer[]
language plpgsql security definer set search_path = public
as $$
declare
  v_minutes int[];
begin
  if p_calendar not in ('primary', 'secondary') then
    raise exception 'bad_calendar';
  end if;
  select coalesce(array_agg(distinct m order by m desc), '{}'::int[])
    into v_minutes
    from unnest(coalesce(p_minutes, '{}'::int[])) as m
    where m is not null;
  if array_length(v_minutes, 1) > 5
     or exists (select 1 from unnest(v_minutes) m where m < 0 or m > 40320) then
    raise exception 'bad_reminders';
  end if;
  if p_calendar = 'secondary' then
    update google_calendar_links
      set reminder_minutes_secondary = v_minutes, updated_at = now()
      where user_id = p_user;
  else
    update google_calendar_links
      set reminder_minutes = v_minutes, updated_at = now()
      where user_id = p_user;
  end if;
  if not found then
    raise exception 'unknown_link';
  end if;
  return v_minutes;
end;
$$;
revoke all on function set_calendar_reminders_for(uuid, integer[], text)
  from public, anon, authenticated;
grant execute on function set_calendar_reminders_for(uuid, integer[], text) to service_role;
