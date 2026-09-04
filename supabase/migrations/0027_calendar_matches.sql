-- 0027 — zápasy v Google kalendáři: hráč si vybere svůj tým (SKK Veverky
-- Brno A, …), ne celý oddíl, a jeho domácí i venkovní zápasy se zapisují do
-- kalendáře „Rezervátor“ vedle tréninků (0023).
--
-- Tým = řetězec home_team/away_team importovaných zápasů (názvy federace,
-- tool/import_matches.py); seznam k výběru si appka odvodí z priority_slots
-- (domácí zápasy → home_team, venkovní → away_team). Výběr leží na řádku
-- propojení jako text[]; prázdné = žádné zápasy (výchozí, dnešní chování).
--
-- Stejný job engine jako tréninky: kind 'calendar_sync', payload
-- {user_id, match_id}, dedupe 'calendar:<user>:match:<slot>'. Handler čte
-- zápas při běhu a událost zapíše, nebo smaže (zápas zmizel, tým odebrán,
-- už odehráno).

alter table google_calendar_links
  add column match_teams text[] not null default '{}'
    check (coalesce(array_length(match_teams, 1), 0) <= 20);
comment on column google_calendar_links.match_teams is
  'Teams whose matches go to the calendar — home_team/away_team strings of priority_slots; empty = none.';

-- ---------------------------------------------------------------------------
-- Producers
-- ---------------------------------------------------------------------------

-- One reconcile job per (player, match); only a linked player gets jobs.
create or replace function enqueue_match_calendar_sync(p_user uuid, p_match uuid)
returns void
language sql security definer set search_path = public
as $$
  select enqueue_notification('calendar_sync',
    'calendar:' || p_user || ':match:' || p_match,
    jsonb_build_object('user_id', p_user, 'match_id', p_match))
  where exists (
    select 1 from google_calendar_links
    where user_id = p_user and status = 'linked');
$$;
revoke all on function enqueue_match_calendar_sync(uuid, uuid)
  from public, anon, authenticated;

-- Every linked player of the tenant who follows one of the two teams.
create or replace function match_calendar_followers(
  p_tenant uuid, p_home text, p_away text)
returns setof uuid
language sql stable security definer set search_path = public
as $$
  select l.user_id
    from google_calendar_links l
    join profiles p on p.id = l.user_id
    where p.tenant_id = p_tenant
      and l.status = 'linked'
      and l.match_teams && array[p_home, p_away];
$$;
revoke all on function match_calendar_followers(uuid, text, text)
  from public, anon, authenticated;

-- A match inserted, re-timed, re-named or deleted: every follower of its
-- teams (before AND after the change) gets a job. Úklid children and other
-- blockages are not matches and enqueue nothing. Runs AFTER the row change,
-- so the handler sees the new truth; on DELETE it finds nothing and removes
-- the event.
create or replace function priority_slots_enqueue_calendar()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') and old.parent_id is null
     and exists (select 1 from priority_slot_types
                 where id = old.type_id and is_match) then
    perform enqueue_match_calendar_sync(u, old.id)
      from match_calendar_followers(
        old.tenant_id, old.home_team, old.away_team) u;
  end if;
  if tg_op in ('INSERT', 'UPDATE') and new.parent_id is null
     and exists (select 1 from priority_slot_types
                 where id = new.type_id and is_match) then
    perform enqueue_match_calendar_sync(u, new.id)
      from match_calendar_followers(
        new.tenant_id, new.home_team, new.away_team) u;
  end if;
  return coalesce(new, old);
end;
$$;
create trigger priority_slots_enqueue_calendar
  after insert or update or delete on priority_slots
  for each row execute function priority_slots_enqueue_calendar();

-- ---------------------------------------------------------------------------
-- Service-role RPCs for the edge functions
-- ---------------------------------------------------------------------------

-- The player's team choice on their behalf (calendar-manage runs as the
-- service role, so auth.uid() is null there). Trimmed, distinct, sorted;
-- empty strings dropped; at most 20 teams. Returns what was stored; the
-- caller rewrites the events itself (removed teams → delete, kept and new
-- → upsert).
create or replace function set_calendar_match_teams_for(p_user uuid, p_teams text[])
returns text[]
language plpgsql security definer set search_path = public
as $$
declare
  v_teams text[];
begin
  select coalesce(array_agg(distinct t order by t), '{}'::text[])
    into v_teams
    from (select trim(x) as t
            from unnest(coalesce(p_teams, '{}'::text[])) as x) s
    where t <> '';
  if array_length(v_teams, 1) > 20
     or exists (select 1 from unnest(v_teams) t where length(t) > 80) then
    raise exception 'bad_teams';
  end if;
  update google_calendar_links
    set match_teams = v_teams, updated_at = now()
    where user_id = p_user;
  if not found then
    raise exception 'unknown_link';
  end if;
  return v_teams;
end;
$$;
revoke all on function set_calendar_match_teams_for(uuid, text[])
  from public, anon, authenticated;
grant execute on function set_calendar_match_teams_for(uuid, text[]) to service_role;

-- The events' raw material for one player: live future matches of the
-- teams they follow, in their kuželna. Same "live" line as the trainings:
-- Prague-today or later. The alley name is the tenant's — the venue of an
-- away match travels in `description` (the import tool writes it there).
create or replace function my_future_matches(p_user uuid)
returns table (
  match_id uuid, date date, starts_at time, ends_at time,
  home_team text, away_team text, is_away boolean, description text,
  alley_name text)
language sql stable security definer set search_path = public
as $$
  select s.id, s.date, s.starts_at, s.ends_at,
         s.home_team, s.away_team, s.is_away, s.description, t.name
    from priority_slots s
    join priority_slot_types y on y.id = s.type_id and y.is_match
    join tenants t on t.id = s.tenant_id
    join profiles p on p.id = p_user and p.tenant_id = s.tenant_id
    join google_calendar_links l on l.user_id = p_user
    where s.parent_id is null
      and s.date >= (now() at time zone 'Europe/Prague')::date
      and l.match_teams && array[s.home_team, s.away_team]
    order by s.date, s.starts_at;
$$;
revoke all on function my_future_matches(uuid)
  from public, anon, authenticated;
grant execute on function my_future_matches(uuid) to service_role;

-- Right after linking (and as the safety net after a rewrite): one job per
-- live future reservation AND per followed future match, due now. Returns
-- how many rows were queued.
create or replace function backfill_calendar_jobs(p_user uuid)
returns int
language plpgsql security definer set search_path = public
as $$
declare
  v_count int;
  v_matches int;
begin
  insert into notification_jobs (kind, dedupe_key, payload, run_at)
  select 'calendar_sync',
         'calendar:' || p_user || ':' || r.id,
         jsonb_build_object('user_id', p_user, 'reservation_id', r.id),
         now()
    from reservations r
    where r.player_id = p_user
      and r.cancelled_at is null
      and r.date >= (now() at time zone 'Europe/Prague')::date
  on conflict (dedupe_key)
    do update set run_at = excluded.run_at, payload = excluded.payload;
  get diagnostics v_count = row_count;

  insert into notification_jobs (kind, dedupe_key, payload, run_at)
  select 'calendar_sync',
         'calendar:' || p_user || ':match:' || m.match_id,
         jsonb_build_object('user_id', p_user, 'match_id', m.match_id),
         now()
    from my_future_matches(p_user) m
  on conflict (dedupe_key)
    do update set run_at = excluded.run_at, payload = excluded.payload;
  get diagnostics v_matches = row_count;

  return v_count + v_matches;
end;
$$;
