-- 0080 — a club's nickname (Správa → Oddíly → oddíl → Přezdívka): the short
-- name the app shows instead of the club's — and instead of the start of
-- its teams' names, the club's name on the federation's site (site_name, or
-- the club's own name when it is not linked): „TJ Sokol Brno IV B“ reads
-- „Sokol IV B“. null = the full name. Display only: the stored team names
-- stay, since matches, follows, colours and calendars are keyed by them.
-- The server writes the shown names too (team_shown below): reminders,
-- Google Calendar titles, the note on a reservation a match cancels and the
-- club picker at sign-up.
--
-- The admin writes it straight into the row (clubs_write, 0005); 1–30
-- characters, not blank. Re-runnable on purpose, like 0064 and 0065.

alter table clubs
  add column if not exists nickname text
    constraint clubs_nickname_check
    check (nickname is null or char_length(btrim(nickname)) between 1 and 30);

comment on column clubs.nickname is
  'Short name the app shows instead of the club''s name and instead of the start of its teams'' names (site_name, else name). null = the full name. Display only.';

-- ---------------------------------------------------------------------------
-- team_shown: the server's copy of the app's NameDisplay
-- ---------------------------------------------------------------------------
-- [p_team] as the app shows it: a club's own name, or a team name starting
-- with it and a space, reads with the club's nickname instead — the longest
-- matching name wins, so „TJ Sokol Brno IV“ beats „TJ Sokol Brno“. Used for
-- what the server writes for people (reminders, Google Calendar, the note
-- on a reservation a match cancels); keys and filters stay on the stored
-- names. Keep in step with NameDisplay (lib/domain/models.dart).
create or replace function team_shown(p_tenant uuid, p_team text)
returns text
language sql stable set search_path = public
as $$
  select coalesce((
    select btrim(c.nickname) || substr(p_team, char_length(x.prefix) + 1)
      from clubs c
      cross join lateral (values (btrim(c.site_name)), (btrim(c.name))) x(prefix)
     where c.tenant_id = p_tenant
       and c.nickname is not null
       and x.prefix <> ''
       and (p_team = x.prefix
            or left(p_team, char_length(x.prefix) + 1) = x.prefix || ' ')
     order by char_length(x.prefix) desc, c.id
     limit 1), p_team);
$$;
revoke all on function team_shown(uuid, text) from public, anon, authenticated;

-- Google Calendar's event title (google_calendar.ts) — as 0039, with the
-- teams as shown. The joins still go by the stored names.
create or replace function my_future_matches(p_user uuid)
returns table (
  match_id uuid, date date, starts_at time, ends_at time,
  home_team text, away_team text, is_away boolean, description text,
  alley_name text, calendar text, color_id smallint)
language sql stable security definer set search_path = public
as $$
  select s.id, s.date, s.starts_at, s.ends_at,
         team_shown(s.tenant_id, s.home_team),
         team_shown(s.tenant_id, s.away_team),
         s.is_away, s.description, t.name,
         coalesce(e.calendar, c.calendar), tc.color_id
    from priority_slots s
    join priority_slot_types y on y.id = s.type_id and y.is_match
    join tenants t on t.id = s.tenant_id
    join profiles p on p.id = p_user and p.tenant_id = s.tenant_id
    join google_calendar_links l on l.user_id = p_user
    left join lateral (
      select ct.team, ct.calendar
        from calendar_teams ct
        where ct.user_id = p_user and ct.team in (s.home_team, s.away_team)
        order by (ct.team = s.home_team) desc
        limit 1
    ) c on true
    left join match_exceptions e
      on e.user_id = p_user and e.match_id = s.id
    left join team_colors tc
      on tc.user_id = p_user
     and tc.team = coalesce(
           c.team,
           case when s.is_away then s.away_team else s.home_team end)
    where s.parent_id is null
      and s.date >= (now() at time zone 'Europe/Prague')::date
      and coalesce(e.shown, c.team is not null)
    order by s.date, s.starts_at;
$$;

-- A match reminder's text (reminders.ts, via due_reminders) — as 0040,
-- with the teams as shown.
create or replace function my_upcoming_matches(p_user uuid)
returns table (
  match_id uuid, date date, starts_at time, ends_at time,
  home_team text, away_team text, is_away boolean, description text)
language sql stable security definer set search_path = public
as $$
  select s.id, s.date, s.starts_at, s.ends_at,
         team_shown(s.tenant_id, s.home_team),
         team_shown(s.tenant_id, s.away_team),
         s.is_away, s.description
    from priority_slots s
    join priority_slot_types y on y.id = s.type_id and y.is_match
    join profiles p on p.id = p_user and p.tenant_id = s.tenant_id
    left join match_exceptions e on e.user_id = p_user and e.match_id = s.id
    where s.parent_id is null
      and s.date >= (now() at time zone 'Europe/Prague')::date
      and coalesce(
            e.shown,
            p.followed_teams && array[s.home_team, s.away_team])
    order by s.date, s.starts_at;
$$;

-- „zápas: Sokol IV B“ on a reservation a match cancels (and in the push
-- about it) — as 0011, with the opponent as shown.
create or replace function cancel_res_for_priority_slot(p_slot priority_slots)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_type priority_slot_types;
begin
  if coalesce(p_slot.is_away, false) then
    return;
  end if;
  select * into v_type from priority_slot_types where id = p_slot.type_id;
  update reservations r
  set cancelled_at = now(), cancelled_via = 'admin',
      cancel_note = case when v_type.is_match
                         then 'zápas: ' || team_shown(p_slot.tenant_id,
                                                      p_slot.away_team)
                         else v_type.name end,
      notify_player = true,
      notify_message = null
  from time_blocks b
  where r.block_id = b.id
    and r.tenant_id = p_slot.tenant_id
    and r.cancelled_at is null
    and r.date >= (now() at time zone 'Europe/Prague')::date
    and r.date = p_slot.date
    and (v_type.lanes is null or r.lane = any (v_type.lanes))
    and p_slot.starts_at < b.ends_at
    and p_slot.ends_at > b.starts_at;
end;
$$;

-- The club picker at sign-up — as 0006, by the name the app shows.
create or replace function registration_clubs(p_tenant_id uuid)
returns table (id uuid, name text)
language sql stable security definer set search_path = public
as $$
  select c.id, coalesce(btrim(c.nickname), c.name) from clubs c
  where auth.uid() is not null and c.tenant_id = p_tenant_id
  order by 2;
$$;

-- ---------------------------------------------------------------------------
-- A new nickname retitles the calendar events already out there
-- ---------------------------------------------------------------------------
-- Google holds each future match under the title it was written with. When
-- a nickname — or a name it replaces — changes, every future match one of
-- the club's teams plays goes back to the queue for whoever has it in the
-- calendar: its followers, and anyone holding an exception on it (as
-- priority_slots_enqueue_calendar, 0039). Old and new names both count, so
-- a match whose team just stopped matching is retitled too.
create or replace function clubs_enqueue_calendar()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_tenant uuid;
  v_prefixes text[];
begin
  if tg_op = 'UPDATE' then
    if (old.nickname is null and new.nickname is null)
       or (old.nickname, old.name, old.site_name)
          is not distinct from (new.nickname, new.name, new.site_name) then
      return null;
    end if;
    v_tenant := new.tenant_id;
    v_prefixes := array[old.name, old.site_name, new.name, new.site_name];
  else
    if old.nickname is null then
      return null;
    end if;
    v_tenant := old.tenant_id;
    v_prefixes := array[old.name, old.site_name];
  end if;
  perform enqueue_match_calendar_sync(f.user_id, s.id)
     from priority_slots s
     join priority_slot_types y on y.id = s.type_id and y.is_match
     cross join lateral (
       select u from match_calendar_followers(s.tenant_id, s.home_team,
                                              s.away_team) u
       union
       select e.user_id from match_exceptions e where e.match_id = s.id
     ) f(user_id)
    where s.tenant_id = v_tenant
      and s.parent_id is null
      and s.date >= (now() at time zone 'Europe/Prague')::date
      and exists (
        select 1
          from unnest(v_prefixes) x(prefix)
          cross join unnest(array[s.home_team, s.away_team]) t(team)
         where btrim(x.prefix) <> ''
           and (t.team = btrim(x.prefix)
                or left(t.team, char_length(btrim(x.prefix)) + 1)
                   = btrim(x.prefix) || ' '));
  return null;
end;
$$;
revoke all on function clubs_enqueue_calendar() from public, anon, authenticated;

create or replace trigger clubs_enqueue_calendar
  after update or delete on clubs
  for each row execute function clubs_enqueue_calendar();
