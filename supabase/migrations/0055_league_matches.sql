-- League matches: the matches of a competition our teams play in that NONE of
-- our teams plays (two foreign teams), so Výsledky can show the whole
-- competition by round. They are deliberately NOT priority_slots: a match row
-- there blocks lanes (is_away is recomputed from the venue), feeds the
-- calendar, the public board, the team picker and the calendar/reminder
-- triggers. They live in their own tables, together with their result and
-- player lines (same columns as match_results / match_player_results, so the
-- app's models read them unchanged). Idempotent.

-- ------------------------------------------------------------------ tables
create table if not exists league_matches (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  site_match_id integer not null,
  site_slug text not null,
  competition_slug text not null,
  competition text not null default '',
  round smallint,
  date date not null,
  -- null: the site has no time yet
  starts_at time,
  home_team text not null,
  away_team text not null,
  home_team_slug text not null default '',
  away_team_slug text not null default '',
  video_url text,
  -- display only: a foreign venue is never fetched
  venue text,
  venue_slug text,
  status text not null default 'scheduled'
    check (status in ('scheduled', 'preparation', 'in_progress', 'finished', 'forfeit')),
  match_type text not null default '',
  discipline text not null default '',
  home_points numeric, away_points numeric,
  home_total integer, away_total integer,
  home_fulls integer, away_fulls integer,
  home_spares integer, away_spares integer,
  home_errors integer, away_errors integer,
  home_set_points numeric, away_set_points numeric,
  fetched_at timestamptz not null default now(),
  -- the status the player lines were fetched at, and when (null: never)
  detail_status text,
  detail_fetched_at timestamptz,
  unique (tenant_id, site_match_id)
);
create index if not exists league_matches_competition_idx
  on league_matches (tenant_id, competition_slug);

create table if not exists league_player_results (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references league_matches(id) on delete cascade,
  tenant_id uuid not null references tenants(id) on delete cascade,
  side text not null check (side in ('home', 'away')),
  position smallint not null,
  player_name text not null,
  player_site_id integer,
  player_slug text,
  fulls integer, spares integer, errors integer, total integer,
  set_points numeric, team_points numeric,
  lanes jsonb not null default '[]'::jsonb,
  sub_name text,
  sub_site_id integer,
  sub_slug text,
  sub_from_throw smallint,
  unique (match_id, side, position)
);
-- The app streams one match's lines by match_id and one competition's matches
-- by competition_slug; Realtime checks a DELETE against the identity alone.
alter table league_matches replica identity full;
alter table league_player_results replica identity full;

alter table league_matches enable row level security;
alter table league_player_results enable row level security;
drop policy if exists league_matches_select on league_matches;
create policy league_matches_select on league_matches for select
  using (tenant_id = current_tenant_id() and is_approved_or_kiosk());
drop policy if exists league_player_results_select on league_player_results;
create policy league_player_results_select on league_player_results for select
  using (tenant_id = current_tenant_id() and is_approved_or_kiosk());

-- service_role first: pg_dump writes GRANTs in ACL order (see 0051).
revoke all on league_matches, league_player_results from anon, authenticated;
grant all on league_matches, league_player_results to service_role;
grant select on league_matches, league_player_results to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public'
                   and tablename = 'league_matches') then
    alter publication supabase_realtime add table league_matches;
  end if;
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public'
                   and tablename = 'league_player_results') then
    alter publication supabase_realtime add table league_player_results;
  end if;
end $$;

-- ------------------------------------------------- does an active team play it
-- Whether one of the alley's active teams plays [p_competition_slug]: the only
-- reason a foreign match is kept, fetched or refreshed.
create or replace function league_competition_is_ours(p_tenant uuid, p_competition_slug text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from teams t
                  where t.tenant_id = p_tenant and t.active
                    and t.competition_slug = p_competition_slug
                    and t.competition_slug <> '');
$$;

-- A league match's detail job whose match is gone (deleted, or become one of
-- ours) would still cost a page fetch before apply_league_result refused it:
-- drop such jobs. [p_tenant] null = every alley (the nightly cleanup).
create or replace function league_drop_orphan_jobs(p_tenant uuid default null)
returns integer language sql security definer set search_path = public as $$
  with gone as (
    delete from notification_jobs j
     where j.kind = 'federation_league_match'
       and (p_tenant is null or j.payload->>'tenant_id' = p_tenant::text)
       and not exists (select 1 from league_matches l
                        where l.tenant_id = (j.payload->>'tenant_id')::uuid
                          and l.site_match_id = (j.payload->>'site_match_id')::integer)
    returning 1)
  select count(*)::integer from gone;
$$;

-- ---------------------------------------------------- apply_league_matches
-- One competition's matches that no ACTIVE team of ours plays, as the round
-- pages list them (a match of a switched-off team of ours, or one of ours
-- with no time yet, is among them — it is in no slot):
--   [{site_match_id, site_slug, date, starts_at|null, home_team, away_team,
--     home_team_slug, away_team_slug, competition, round, video_url, status,
--     match_type, discipline,
--     home:{points,total,fulls,spares,errors,set_points}, away:{…}}]
-- Upserts by (tenant, site_match_id) and writes only what changed (the
-- nightly run must not flood Realtime), skips a match that has a cka: slot
-- (and drops its league row), deletes this competition's rows the site no
-- longer lists (only from a non-empty list, as apply_federation_matches
-- does) and queues ONE detail fetch for every final match whose player lines
-- are not final yet. A final match whose totals change gets its lines
-- fetched again (a late correction). A competition none of our active teams
-- plays keeps nothing (a stale job after a team was switched off).
create or replace function apply_league_matches(
  p_tenant uuid, p_competition_slug text, p_matches jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  m jsonb;
  v_home jsonb;
  v_away jsonb;
  v_id integer;
  v_inserted integer := 0;
  v_updated integer := 0;
  v_deleted integer := 0;
  v_jobs integer := 0;
  v_seen integer[] := '{}';
  v_row league_matches;
  v_n integer;
  v_final constant text[] := array['finished', 'forfeit'];
  v_status text;
  v_type text;
  v_disc text;
begin
  if not league_competition_is_ours(p_tenant, p_competition_slug) then
    delete from league_matches
     where tenant_id = p_tenant and competition_slug = p_competition_slug;
    get diagnostics v_deleted = row_count;
    perform league_drop_orphan_jobs(p_tenant);
    return jsonb_build_object('league_inserted', 0, 'league_updated', 0,
                              'league_deleted', v_deleted, 'league_detail_jobs', 0);
  end if;

  for m in select * from jsonb_array_elements(coalesce(p_matches, '[]'::jsonb)) loop
    v_id := (m->>'site_match_id')::integer;
    if exists (select 1 from priority_slots
                where tenant_id = p_tenant and import_key = 'cka:' || v_id) then
      continue;
    end if;
    v_seen := v_seen || v_id;
    v_home := coalesce(m->'home', '{}'::jsonb);
    v_away := coalesce(m->'away', '{}'::jsonb);
    select * into v_row from league_matches
     where tenant_id = p_tenant and site_match_id = v_id;
    if not found then
      insert into league_matches
        (tenant_id, site_match_id, site_slug, competition_slug, competition, round,
         date, starts_at, home_team, away_team, home_team_slug, away_team_slug,
         video_url, status, match_type, discipline,
         home_points, away_points, home_total, away_total, home_fulls, away_fulls,
         home_spares, away_spares, home_errors, away_errors,
         home_set_points, away_set_points)
      values
        (p_tenant, v_id, m->>'site_slug', p_competition_slug,
         coalesce(m->>'competition', ''), (m->>'round')::smallint,
         (m->>'date')::date, nullif(m->>'starts_at', '')::time, m->>'home_team', m->>'away_team',
         coalesce(m->>'home_team_slug', ''), coalesce(m->>'away_team_slug', ''),
         m->>'video_url', coalesce(m->>'status', 'scheduled'),
         coalesce(m->>'match_type', ''), coalesce(m->>'discipline', ''),
         (v_home->>'points')::numeric, (v_away->>'points')::numeric,
         (v_home->>'total')::integer, (v_away->>'total')::integer,
         (v_home->>'fulls')::integer, (v_away->>'fulls')::integer,
         (v_home->>'spares')::integer, (v_away->>'spares')::integer,
         (v_home->>'errors')::integer, (v_away->>'errors')::integer,
         (v_home->>'set_points')::numeric, (v_away->>'set_points')::numeric);
      v_inserted := v_inserted + 1;
    else
      -- The status the detail page reported for a final match stands: the
      -- round page and the detail may disagree (finished / forfeit), and
      -- neither may flip the row back every night. The format is the round
      -- page's when it has one.
      v_status := case when v_row.detail_status = any (v_final)
                       then v_row.status else coalesce(m->>'status', 'scheduled') end;
      v_type := coalesce(nullif(m->>'match_type', ''), v_row.match_type);
      v_disc := coalesce(nullif(m->>'discipline', ''), v_row.discipline);
      update league_matches set
        site_slug = m->>'site_slug', competition_slug = p_competition_slug,
        competition = coalesce(m->>'competition', ''), round = (m->>'round')::smallint,
        date = (m->>'date')::date, starts_at = nullif(m->>'starts_at', '')::time,
        home_team = m->>'home_team', away_team = m->>'away_team',
        home_team_slug = coalesce(m->>'home_team_slug', ''),
        away_team_slug = coalesce(m->>'away_team_slug', ''),
        video_url = m->>'video_url', status = v_status,
        match_type = v_type, discipline = v_disc,
        home_points = (v_home->>'points')::numeric, away_points = (v_away->>'points')::numeric,
        home_total = (v_home->>'total')::integer, away_total = (v_away->>'total')::integer,
        home_fulls = (v_home->>'fulls')::integer, away_fulls = (v_away->>'fulls')::integer,
        home_spares = (v_home->>'spares')::integer, away_spares = (v_away->>'spares')::integer,
        home_errors = (v_home->>'errors')::integer, away_errors = (v_away->>'errors')::integer,
        home_set_points = (v_home->>'set_points')::numeric,
        away_set_points = (v_away->>'set_points')::numeric,
        -- A final match whose totals moved has its player lines fetched again.
        detail_status = case
          when v_status = any (v_final)
               and (home_points, away_points, home_total, away_total)
                   is distinct from ((v_home->>'points')::numeric, (v_away->>'points')::numeric,
                                     (v_home->>'total')::integer, (v_away->>'total')::integer)
          then null else detail_status end,
        fetched_at = now()
       where id = v_row.id
         and (site_slug, competition_slug, competition, round, date, starts_at,
              home_team, away_team, home_team_slug, away_team_slug, video_url, status,
              match_type, discipline,
              home_points, away_points, home_total, away_total, home_fulls, away_fulls,
              home_spares, away_spares, home_errors, away_errors,
              home_set_points, away_set_points)
             is distinct from
             (m->>'site_slug', p_competition_slug, coalesce(m->>'competition', ''),
              (m->>'round')::smallint, (m->>'date')::date, nullif(m->>'starts_at', '')::time,
              m->>'home_team', m->>'away_team', coalesce(m->>'home_team_slug', ''),
              coalesce(m->>'away_team_slug', ''), m->>'video_url', v_status,
              v_type, v_disc,
              (v_home->>'points')::numeric, (v_away->>'points')::numeric,
              (v_home->>'total')::integer, (v_away->>'total')::integer,
              (v_home->>'fulls')::integer, (v_away->>'fulls')::integer,
              (v_home->>'spares')::integer, (v_away->>'spares')::integer,
              (v_home->>'errors')::integer, (v_away->>'errors')::integer,
              (v_home->>'set_points')::numeric, (v_away->>'set_points')::numeric);
      get diagnostics v_n = row_count;
      v_updated := v_updated + v_n;
    end if;
  end loop;

  -- A match that turned into one of ours (a team discovered later) leaves.
  delete from league_matches l
   where l.tenant_id = p_tenant and l.competition_slug = p_competition_slug
     and exists (select 1 from priority_slots p
                  where p.tenant_id = p_tenant and p.import_key = 'cka:' || l.site_match_id);
  -- The site no longer lists it: only judged from a non-empty list.
  if jsonb_array_length(coalesce(p_matches, '[]'::jsonb)) > 0 then
    delete from league_matches l
     where l.tenant_id = p_tenant and l.competition_slug = p_competition_slug
       and not (l.site_match_id = any (v_seen));
    get diagnostics v_n = row_count;
    v_deleted := v_deleted + v_n;
  end if;
  perform league_drop_orphan_jobs(p_tenant);

  -- One detail fetch per final match whose player lines are not final yet; a
  -- pending or backing-off job is left alone (only a stale slug is mended).
  with due as (
    select l.site_match_id, l.site_slug
      from league_matches l
     where l.tenant_id = p_tenant and l.competition_slug = p_competition_slug
       and l.status = any (v_final)
       and (l.detail_status is null or not (l.detail_status = any (v_final)))
  ), ins as (
    insert into notification_jobs as j (kind, dedupe_key, payload, run_at)
    select 'federation_league_match',
           'federation_league_match:' || p_tenant || ':' || d.site_match_id,
           jsonb_build_object('tenant_id', p_tenant, 'site_match_id', d.site_match_id,
                              'slug', d.site_slug),
           now()
      from due d
    on conflict (dedupe_key) do update
      set payload = j.payload || jsonb_build_object('slug', excluded.payload->>'slug')
      where j.payload->>'slug' is distinct from excluded.payload->>'slug'
    returning (xmax = 0) as fresh
  )
  select count(*) filter (where fresh) into v_jobs from ins;

  return jsonb_build_object('league_inserted', v_inserted, 'league_updated', v_updated,
                            'league_deleted', v_deleted, 'league_detail_jobs', v_jobs);
end;
$$;

-- ----------------------------------------------------- apply_league_result
-- A foreign match's detail page (resultPayload as apply_federation_result
-- reads it): result, format, venue (display only — no venue job, no is_away)
-- and the player lines. False for an unknown match or a competition none of
-- our active teams plays. A final status is never taken back by a page that
-- still says otherwise (a lagging detail).
create or replace function apply_league_result(
  p_tenant uuid, p_site_match_id integer, p_result jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_row league_matches;
  v_home jsonb := coalesce(p_result->'home', '{}'::jsonb);
  v_away jsonb := coalesce(p_result->'away', '{}'::jsonb);
  v_final constant text[] := array['finished', 'forfeit'];
  v_new text := p_result->>'status';
  v_lagging boolean;
begin
  select * into v_row from league_matches
   where tenant_id = p_tenant and site_match_id = p_site_match_id;
  if not found or not league_competition_is_ours(p_tenant, v_row.competition_slug) then
    return false;
  end if;
  v_lagging := v_row.status = any (v_final) and not (v_new = any (v_final));
  update league_matches set
    status = case when v_lagging then v_row.status else v_new end,
    match_type = coalesce(p_result->>'match_type', ''),
    discipline = coalesce(p_result->>'discipline', ''),
    video_url = p_result->>'video_url',
    venue = case when jsonb_typeof(p_result->'venue') = 'object'
                 then p_result#>>'{venue,name}' else venue end,
    venue_slug = case when jsonb_typeof(p_result->'venue') = 'object'
                      then p_result#>>'{venue,slug}' else venue_slug end,
    home_points = case when v_lagging then home_points else (v_home->>'points')::numeric end,
    away_points = case when v_lagging then away_points else (v_away->>'points')::numeric end,
    home_total = case when v_lagging then home_total else (v_home->>'total')::integer end,
    away_total = case when v_lagging then away_total else (v_away->>'total')::integer end,
    home_fulls = case when v_lagging then home_fulls else (v_home->>'fulls')::integer end,
    away_fulls = case when v_lagging then away_fulls else (v_away->>'fulls')::integer end,
    home_spares = case when v_lagging then home_spares else (v_home->>'spares')::integer end,
    away_spares = case when v_lagging then away_spares else (v_away->>'spares')::integer end,
    home_errors = case when v_lagging then home_errors else (v_home->>'errors')::integer end,
    away_errors = case when v_lagging then away_errors else (v_away->>'errors')::integer end,
    home_set_points = case when v_lagging then home_set_points
                           else (v_home->>'set_points')::numeric end,
    away_set_points = case when v_lagging then away_set_points
                           else (v_away->>'set_points')::numeric end,
    fetched_at = now(), detail_status = v_new, detail_fetched_at = now()
   where id = v_row.id;

  delete from league_player_results where match_id = v_row.id;
  insert into league_player_results
    (match_id, tenant_id, side, position, player_name, player_site_id, player_slug,
     fulls, spares, errors, total, set_points, team_points, lanes,
     sub_name, sub_site_id, sub_slug, sub_from_throw)
  select v_row.id, p_tenant, p->>'side', (p->>'position')::smallint, p->>'player_name',
         (p->>'player_site_id')::integer, p->>'player_slug',
         (p->>'fulls')::integer, (p->>'spares')::integer, (p->>'errors')::integer,
         (p->>'total')::integer, (p->>'set_points')::numeric,
         (p->>'team_points')::numeric, coalesce(p->'lanes', '[]'::jsonb),
         nullif(p->>'sub_name', ''), (p->>'sub_site_id')::integer, p->>'sub_slug',
         (p->>'sub_from_throw')::smallint
    from jsonb_array_elements(coalesce(p_result->'players', '[]'::jsonb)) p;
  return true;
end;
$$;

-- ------------------------------------------------------------ refresh_match
-- 0054's refresh_match, now also for a league match's id: a match of one of
-- our competitions that none of our teams plays. Nothing polls it, so the
-- stored status can be a whole day behind: a match not final yet may be
-- asked for from an hour before its start until 30 hours after it (the
-- nightly round page has surely seen it by then), whatever the status says.
-- A final match is fetched once, when its player lines are missing (also on
-- a plain open). Answers as before.
create or replace function refresh_match(p_match_id uuid, p_force boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_slot priority_slots;
  v_league league_matches;
  v_status text;
  v_fetched timestamptz;
  v_start timestamptz;
  v_job bigint;
  v_gap interval := case when p_force then interval '15 seconds' else interval '5 minutes' end;
begin
  if not is_approved_or_kiosk() then
    raise exception 'not_allowed';
  end if;
  select * into v_slot from priority_slots
   where id = p_match_id and tenant_id = current_tenant_id();
  if not found then
    -- Not one of ours: maybe a match of one of our competitions.
    select * into v_league from league_matches
     where id = p_match_id and tenant_id = current_tenant_id();
    if not found or not league_competition_is_ours(v_league.tenant_id, v_league.competition_slug) then
      return 'not_live';
    end if;
    v_fetched := v_league.detail_fetched_at;
    if v_league.status in ('finished', 'forfeit') then
      -- Final: only a missing detail is worth a fetch.
      if v_league.detail_status in ('finished', 'forfeit') then
        return 'not_live';
      end if;
    else
      if v_league.starts_at is null then
        return 'not_live';
      end if;
      v_start := (v_league.date + v_league.starts_at) at time zone 'Europe/Prague';
      if not (now() between v_start - interval '1 hour' and v_start + interval '30 hours') then
        return 'not_live';
      end if;
    end if;
    if v_fetched is not null and v_fetched > now() - v_gap then
      return 'fresh';
    end if;
    insert into notification_jobs (kind, dedupe_key, payload, run_at)
    values ('federation_league_match',
            'federation_league_match:' || v_league.tenant_id || ':' || v_league.site_match_id,
            jsonb_build_object('tenant_id', v_league.tenant_id,
                               'site_match_id', v_league.site_match_id,
                               'slug', v_league.site_slug, 'requested_at', now()),
            now())
    on conflict (dedupe_key) do update
      set run_at = least(notification_jobs.run_at, excluded.run_at),
          payload = notification_jobs.payload || jsonb_build_object('requested_at', now())
      where coalesce((notification_jobs.payload->>'requested_at')::timestamptz, '-infinity')
            < now() - v_gap
    returning id into v_job;
    if v_job is not null then
      perform trigger_notification_jobs();
    end if;
    return 'queued';
  end if;

  if v_slot.site_match_id is null then
    return 'not_live';
  end if;
  -- Only switched-off teams of ours play it: its job would fetch the page
  -- and stop unwritten, leaving neither a fresh fetched_at nor a pending
  -- requested_at to gate the next request — so no job at all.
  if federation_match_switched_off(v_slot.tenant_id, v_slot.home_team_slug,
                                   v_slot.away_team_slug) then
    return 'not_live';
  end if;
  select status, fetched_at into v_status, v_fetched
    from match_results where match_id = p_match_id;
  v_status := coalesce(v_status, 'scheduled');
  v_start := (v_slot.date + v_slot.starts_at) at time zone 'Europe/Prague';
  -- The site shows 'preparation' days before some matches: like
  -- 'scheduled', it is live only from an hour before the start.
  if not ((v_status = 'in_progress' and now() < v_start + interval '12 hours')
          or (v_status = 'preparation'
              and now() between v_start - interval '1 hour' and v_start + interval '12 hours')
          or (v_status = 'scheduled'
              and now() between v_start - interval '1 hour' and v_start + interval '6 hours')) then
    return 'not_live';
  end if;
  if v_fetched is not null and v_fetched > now() - v_gap then
    return 'fresh';
  end if;
  -- fetched_at alone does not gate a fetch that is pending, running or
  -- backing off: the job's requested_at does.
  insert into notification_jobs (kind, dedupe_key, payload, run_at)
  values ('federation_match',
          'federation_match:' || v_slot.tenant_id || ':' || v_slot.site_match_id,
          jsonb_build_object('tenant_id', v_slot.tenant_id,
                             'site_match_id', v_slot.site_match_id,
                             'slug', v_slot.site_slug, 'requested_at', now()),
          now())
  on conflict (dedupe_key) do update
    set run_at = least(notification_jobs.run_at, excluded.run_at),
        payload = notification_jobs.payload || jsonb_build_object('requested_at', now())
    where coalesce((notification_jobs.payload->>'requested_at')::timestamptz, '-infinity')
          < now() - v_gap
  returning id into v_job;
  if v_job is not null then
    perform trigger_notification_jobs();
  end if;
  return 'queued';
end;
$$;

-- ------------------------------------------------- nightly cleanup (cron)
-- 0045's enqueue_federation_jobs, first dropping the league matches of a
-- competition none of the alley's active teams plays any more (a team
-- switched off, a new season — the slug carries the season) and the detail
-- jobs of matches that are gone. The lines go with the matches (cascade).
create or replace function enqueue_federation_jobs()
returns void language plpgsql security definer set search_path = public as $$
declare
  r record;
  i integer := 0;
begin
  delete from league_matches l
   where not exists (select 1 from teams t
                      where t.tenant_id = l.tenant_id and t.active
                        and t.competition_slug = l.competition_slug);
  perform league_drop_orphan_jobs();
  for r in
    select distinct t.tenant_id, t.competition_slug
      from teams t
      join federation_sync s on s.tenant_id = t.tenant_id
     where s.enabled and s.venue_slug <> '' and t.active and t.competition_slug <> ''
     order by 1, 2
  loop
    perform enqueue_notification('federation_competition',
      'federation_competition:' || r.tenant_id || ':' || r.competition_slug,
      jsonb_build_object('tenant_id', r.tenant_id, 'competition_slug', r.competition_slug),
      make_interval(mins => i));
    i := i + 1;
  end loop;
  for r in
    select distinct x.tenant_id, x.slug
      from federation_sync s
      cross join lateral (
        select s.tenant_id, s.venue_slug as slug
        union
        select p.tenant_id, p.venue_slug from priority_slots p
         where p.tenant_id = s.tenant_id and p.venue_slug is not null) x
     where s.enabled and s.venue_slug <> '' and x.slug <> ''
       and not exists (select 1 from venues v
                        where v.tenant_id = x.tenant_id and v.slug = x.slug
                          and v.fetched_at >= now() - interval '7 days')
     order by 1, 2
  loop
    perform enqueue_federation_venue(r.tenant_id, r.slug, make_interval(mins => i));
    i := i + 1;
  end loop;
end;
$$;

revoke all on function league_competition_is_ours(uuid, text) from public, anon, authenticated;
revoke all on function league_drop_orphan_jobs(uuid) from public, anon, authenticated;
revoke all on function apply_league_matches(uuid, text, jsonb) from public, anon, authenticated;
revoke all on function apply_league_result(uuid, integer, jsonb) from public, anon, authenticated;
grant execute on function league_competition_is_ours(uuid, text) to service_role;
grant execute on function league_drop_orphan_jobs(uuid) to service_role;
grant execute on function apply_league_matches(uuid, text, jsonb) to service_role;
grant execute on function apply_league_result(uuid, integer, jsonb) to service_role;
