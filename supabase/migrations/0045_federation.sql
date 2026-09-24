-- 0045 — výsledkový servis ČKA (vysledky.kuzelky.cz): týmy kuželny,
-- nastavení synchronizace, výsledky zápasů. Zápisy dělá jen server (edge
-- funkce notify přes service_role) těmito security-definer funkcemi; appka
-- čte tabulky a volá několik RPC. Spec:
-- docs/superpowers/specs/2026-09-23-federation-results-design.md

-- ---------------------------------------------------------------- teams
create table teams (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 80),
  club_id uuid references clubs(id) on delete set null,
  site_team_id integer,
  site_slug text not null,
  site_name text not null default '',
  competition_slug text not null default '',
  competition_name text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, name),
  unique (tenant_id, site_slug)
);
comment on column teams.name is
  'The name the app keys by (priority_slots.home_team/away_team, followed_teams, calendar_teams, team_colors). Set at discovery, editable by the admin.';
alter table teams enable row level security;
create policy teams_select on teams for select
  using (tenant_id = current_tenant_id() and is_approved_or_kiosk());
revoke all on teams from anon;
revoke insert, update, delete on teams from authenticated;
grant all on teams to service_role;
alter publication supabase_realtime add table teams;

-- ------------------------------------------------------ federation_sync
create table federation_sync (
  tenant_id uuid primary key references tenants(id) on delete cascade,
  venue_slug text not null default ''
    check (venue_slug ~ '^([a-z0-9]+(-[a-z0-9]+)*)?$'),
  enabled boolean not null default false,
  last_run_at timestamptz,
  last_success_at timestamptz,
  last_error text,
  last_report jsonb not null default '{}'::jsonb
);
alter table federation_sync enable row level security;
create policy federation_sync_select on federation_sync for select
  using (tenant_id = current_tenant_id() and is_admin());
revoke all on federation_sync from anon;
revoke insert, update, delete on federation_sync from authenticated;
grant all on federation_sync to service_role;
alter publication supabase_realtime add table federation_sync;

-- ------------------------------------------------ priority_slots columns
-- Federation-only columns: the sync may always rewrite them, so the
-- hand_edited trigger (0038) does not compare them.
alter table priority_slots
  add column video_url text,
  add column competition text,
  add column round smallint,
  add column site_slug text,
  add column site_match_id integer,
  add column venue text,
  add column venue_slug text;

-- 0027/0039's calendar trigger enqueued on every UPDATE. The sync rewrites
-- the columns above (video link a day later, venue, rekey) and the calendar
-- handler drops events of past matches — an UPDATE now enqueues only when
-- something the event shows (or who follows it) changed, and never for a
-- match that stays in the past.
create or replace function priority_slots_enqueue_calendar()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'UPDATE'
     and (old.tenant_id, old.date, old.starts_at, old.ends_at, old.home_team,
          old.away_team, old.is_away, old.description, old.type_id, old.parent_id)
         is not distinct from
         (new.tenant_id, new.date, new.starts_at, new.ends_at, new.home_team,
          new.away_team, new.is_away, new.description, new.type_id, new.parent_id) then
    return new;
  end if;
  -- For a match played before and after, the handler could only delete the
  -- event (the first run rewrites old rows' description and times).
  if tg_op = 'UPDATE'
     and old.date < (now() at time zone 'Europe/Prague')::date
     and new.date < (now() at time zone 'Europe/Prague')::date then
    return new;
  end if;
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
  -- Whoever holds an exception on this match, followed teams or not. On
  -- DELETE the cascade has usually emptied this already (and the trigger
  -- above has queued the job) — then this finds nothing, which is the
  -- right answer either way.
  perform enqueue_match_calendar_sync(e.user_id, coalesce(new.id, old.id))
    from match_exceptions e where e.match_id = coalesce(new.id, old.id);
  return coalesce(new, old);
end;
$$;

-- ------------------------------------------------------- match results
create table match_results (
  match_id uuid primary key references priority_slots(id) on delete cascade,
  tenant_id uuid not null references tenants(id) on delete cascade,
  status text not null
    check (status in ('scheduled', 'preparation', 'in_progress', 'finished', 'forfeit')),
  match_type text not null default '',
  discipline text not null default '',
  home_points numeric, away_points numeric,
  home_total integer, away_total integer,
  home_fulls integer, away_fulls integer,
  home_spares integer, away_spares integer,
  home_errors integer, away_errors integer,
  home_set_points numeric, away_set_points numeric,
  fetched_at timestamptz not null default now()
);
create table match_player_results (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references priority_slots(id) on delete cascade,
  tenant_id uuid not null references tenants(id) on delete cascade,
  side text not null check (side in ('home', 'away')),
  position smallint not null,
  player_name text not null,
  player_site_id integer,
  player_slug text,
  fulls integer, spares integer, errors integer, total integer,
  set_points numeric, team_points numeric,
  lanes jsonb not null default '[]'::jsonb,
  unique (match_id, side, position)
);
create index match_player_results_player_idx
  on match_player_results (tenant_id, player_site_id);
-- The app streams one match's lines filtered by match_id and every fetch
-- replaces them; Realtime checks a DELETE's filter against the replica
-- identity alone, so the default (id only) would hide every delete.
alter table match_player_results replica identity full;

alter table match_results enable row level security;
alter table match_player_results enable row level security;
create policy match_results_select on match_results for select
  using (tenant_id = current_tenant_id() and is_approved_or_kiosk());
create policy match_player_results_select on match_player_results for select
  using (tenant_id = current_tenant_id() and is_approved_or_kiosk());
revoke all on match_results, match_player_results from anon;
revoke insert, update, delete on match_results, match_player_results from authenticated;
grant all on match_results, match_player_results to service_role;
alter publication supabase_realtime add table match_results, match_player_results;

-- -------------------------------------------------------------- venues
-- The alleys our teams play at, as the site's venue page shows them.
create table venues (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  slug text not null,
  name text not null,
  address text,
  phone text,
  email text,
  lat numeric,
  lng numeric,
  sections jsonb not null default '[]'::jsonb,
  clubs text[] not null default '{}',
  fetched_at timestamptz not null default now(),
  unique (tenant_id, slug)
);
alter table venues enable row level security;
create policy venues_select on venues for select
  using (tenant_id = current_tenant_id() and is_approved_or_kiosk());
revoke all on venues from anon;
revoke insert, update, delete on venues from authenticated;
grant all on venues to service_role;
alter publication supabase_realtime add table venues;

-- ------------------------------------------------------------- helpers
create or replace function enqueue_federation_venue(
  p_tenant uuid, p_slug text, p_delay interval default interval '0')
returns void language sql security definer set search_path = public as $$
  select enqueue_notification('federation_venue',
    'federation_venue:' || p_tenant || ':' || p_slug,
    jsonb_build_object('tenant_id', p_tenant, 'slug', p_slug), p_delay);
$$;

create or replace function federation_description(
  p_competition text, p_round integer, p_is_away boolean, p_venue text)
returns text language sql immutable as $$
  select concat_ws(' · ', nullif(p_competition, ''), p_round || '. kolo',
    case when p_is_away and coalesce(p_venue, '') <> '' then p_venue end)
$$;

-- One competition's matches as the site lists them → priority_slots.
-- import.run keeps the 0038 hand-edit trigger quiet; writes happen only
-- when something differs.
-- p_keep_ids: our matches the edge function did not write (no time on the
-- site yet, or only inactive teams of ours) — still listed, so never
-- "dropped".
create or replace function apply_federation_matches(
  p_tenant uuid, p_competition_slug text, p_matches jsonb,
  p_keep_ids integer[] default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_admin uuid;
  v_type uuid;
  v_venue text;
  m jsonb;
  v_key text;
  v_row priority_slots;
  v_found boolean;
  v_is_away boolean;
  v_prep smallint;
  v_desc text;
  v_seen integer[] := '{}';
  v_ins integer := 0;
  v_upd integer := 0;
  v_rekey integer := 0;
  v_del integer := 0;
  v_skipped jsonb := '[]'::jsonb;
begin
  perform set_config('import.run', 'on', true);
  -- A visiting superadmin is not the alley's admin; id breaks created_at ties.
  select id into v_admin from profiles
   where tenant_id = p_tenant and role = 'admin' and status = 'approved' and not placeholder
     and not (superadmin and home_tenant_id is distinct from p_tenant)
   order by created_at, id limit 1;
  select id into v_type from priority_slot_types
   where tenant_id = p_tenant and is_match and builtin;
  if v_admin is null or v_type is null then
    raise exception 'federation_tenant_not_ready';
  end if;
  select venue_slug into v_venue from federation_sync where tenant_id = p_tenant;

  for m in select * from jsonb_array_elements(p_matches) loop
    v_key := 'cka:' || (m->>'site_match_id');
    v_seen := v_seen || (m->>'site_match_id')::integer;
    select * into v_row from priority_slots
     where tenant_id = p_tenant and import_key = v_key;
    v_found := found;
    if not v_found and m->>'legacy_id' is not null then
      select * into v_row from priority_slots
       where tenant_id = p_tenant and id = (m->>'legacy_id')::uuid
         and import_key like 'rozpis:%';
      v_found := found;
      if v_found then
        update priority_slots set import_key = v_key where id = v_row.id;
        v_rekey := v_rekey + 1;
      end if;
    end if;

    if not v_found then
      v_is_away := not (m->>'home_is_ours')::boolean;
      insert into priority_slots
        (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
         prep_minutes, description, is_away, created_by, import_key,
         video_url, competition, round, site_slug, site_match_id)
      values
        (p_tenant, (m->>'date')::date, (m->>'starts_at')::time, (m->>'ends_at')::time,
         v_type, m->>'home', m->>'away',
         case when v_is_away then 0 else (m->>'prep')::smallint end,
         federation_description(m->>'competition', (m->>'round')::integer, v_is_away, null),
         v_is_away, v_admin, v_key,
         m->>'video_url', m->>'competition', (m->>'round')::smallint,
         m->>'site_slug', (m->>'site_match_id')::integer);
      v_ins := v_ins + 1;
      continue;
    end if;

    update priority_slots
       set video_url = m->>'video_url', competition = m->>'competition',
           round = (m->>'round')::smallint, site_slug = m->>'site_slug',
           site_match_id = (m->>'site_match_id')::integer
     where id = v_row.id
       and (video_url, competition, round, site_slug, site_match_id)
           is distinct from
           (m->>'video_url', m->>'competition', (m->>'round')::smallint,
            m->>'site_slug', (m->>'site_match_id')::integer);

    -- Once a detail fetch told us the venue, it decides home/away. Before
    -- that the stored value stands: a legacy row knew it better than the
    -- guess from the site's home team.
    v_is_away := case when v_row.venue_slug is not null
                      then v_row.venue_slug is distinct from v_venue
                      else v_row.is_away end;
    v_prep := case when v_is_away then 0 else (m->>'prep')::smallint end;
    v_desc := federation_description(m->>'competition', (m->>'round')::integer,
                                     v_is_away, v_row.venue);
    if (v_row.date, v_row.starts_at, v_row.ends_at, v_row.home_team, v_row.away_team,
        v_row.prep_minutes, v_row.description, v_row.is_away)
       is distinct from
       ((m->>'date')::date, (m->>'starts_at')::time, (m->>'ends_at')::time,
        m->>'home', m->>'away', v_prep, v_desc, v_is_away) then
      if v_row.hand_edited then
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
          'id', v_row.id, 'date', v_row.date,
          'title', v_row.home_team || ' – ' || v_row.away_team));
      else
        update priority_slots
           set date = (m->>'date')::date, starts_at = (m->>'starts_at')::time,
               ends_at = (m->>'ends_at')::time, home_team = m->>'home',
               away_team = m->>'away', prep_minutes = v_prep,
               description = v_desc, is_away = v_is_away
         where id = v_row.id;
        v_upd := v_upd + 1;
      end if;
    end if;
  end loop;

  -- A match not yet started that the site no longer lists (a team
  -- withdrew). Started matches stay whatever the site says later; an empty
  -- list is a failed fetch, not a withdrawn season.
  if jsonb_array_length(p_matches) > 0 then
    with gone as (
      delete from priority_slots p
       where p.tenant_id = p_tenant and p.parent_id is null
         and p.import_key like 'cka:%'
         and p.site_slug like p_competition_slug || '-kolo-%'
         and (p.date + p.starts_at) > (now() at time zone 'Europe/Prague')
         and not p.hand_edited
         and not (p.site_match_id = any (v_seen || coalesce(p_keep_ids, '{}')))
      returning p.site_match_id),
    gone_jobs as (
      delete from notification_jobs j
       using gone g
       where j.dedupe_key = 'federation_match:' || p_tenant || ':' || g.site_match_id)
    select count(*) into v_del from gone;
  end if;

  return jsonb_build_object('inserted', v_ins, 'updated', v_upd, 'rekeyed', v_rekey,
    'deleted', v_del, 'skipped_hand_edited', v_skipped);
end;
$$;

-- false: no slot for this match (withdrawn, deleted by hand) — the match
-- job stops instead of polling it.
create or replace function apply_federation_result(
  p_tenant uuid, p_site_match_id integer, p_result jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_row priority_slots;
  v_venue text;
  v_is_away boolean;
  v_prep smallint;
  v_desc text;
  v_home jsonb := p_result->'home';
  v_away jsonb := p_result->'away';
  v_vslug text := p_result#>>'{venue,slug}';
begin
  select * into v_row from priority_slots
   where tenant_id = p_tenant and import_key = 'cka:' || p_site_match_id;
  if not found then
    return false;
  end if;
  perform set_config('import.run', 'on', true);
  select venue_slug into v_venue from federation_sync where tenant_id = p_tenant;

  if jsonb_typeof(p_result->'venue') = 'object' then
    update priority_slots
       set venue = p_result#>>'{venue,name}', venue_slug = p_result#>>'{venue,slug}'
     where id = v_row.id
       and (venue, venue_slug) is distinct from
           (p_result#>>'{venue,name}', p_result#>>'{venue,slug}');
    -- Live matches refresh every few minutes: re-arming here would cancel a
    -- failing fetch's backoff, and recreating a dropped one would fetch a
    -- broken page forever — a pending job or a failure within a day stands
    -- (the nightly pass is the daily retry).
    if coalesce(v_vslug, '') <> ''
       and not exists (select 1 from venues where tenant_id = p_tenant and slug = v_vslug)
       and not exists (select 1 from notification_jobs
                        where dedupe_key = 'federation_venue:' || p_tenant || ':' || v_vslug)
       and not exists (select 1 from federation_sync
                        where tenant_id = p_tenant
                          and last_report->('venue:' || v_vslug) ? 'error'
                          and (last_report->('venue:' || v_vslug)->>'at')::timestamptz
                              > now() - interval '24 hours') then
      perform enqueue_federation_venue(p_tenant, v_vslug);
    end if;
    v_is_away := (p_result#>>'{venue,slug}') is distinct from v_venue;
    v_prep := case when v_is_away then 0 else (p_result->>'home_prep')::smallint end;
    v_desc := federation_description(v_row.competition, v_row.round, v_is_away,
                                     p_result#>>'{venue,name}');
    if not v_row.hand_edited
       and (v_row.is_away, v_row.prep_minutes, v_row.description)
           is distinct from (v_is_away, v_prep, v_desc) then
      update priority_slots
         set is_away = v_is_away, prep_minutes = v_prep, description = v_desc
       where id = v_row.id;
    end if;
  end if;

  update priority_slots set video_url = p_result->>'video_url'
   where id = v_row.id and video_url is distinct from p_result->>'video_url';

  insert into match_results as r
    (match_id, tenant_id, status, match_type, discipline,
     home_points, away_points, home_total, away_total, home_fulls, away_fulls,
     home_spares, away_spares, home_errors, away_errors,
     home_set_points, away_set_points, fetched_at)
  values
    (v_row.id, p_tenant, p_result->>'status',
     coalesce(p_result->>'match_type', ''), coalesce(p_result->>'discipline', ''),
     (v_home->>'points')::numeric, (v_away->>'points')::numeric,
     (v_home->>'total')::integer, (v_away->>'total')::integer,
     (v_home->>'fulls')::integer, (v_away->>'fulls')::integer,
     (v_home->>'spares')::integer, (v_away->>'spares')::integer,
     (v_home->>'errors')::integer, (v_away->>'errors')::integer,
     (v_home->>'set_points')::numeric, (v_away->>'set_points')::numeric, now())
  on conflict (match_id) do update set
    status = excluded.status, match_type = excluded.match_type,
    discipline = excluded.discipline,
    home_points = excluded.home_points, away_points = excluded.away_points,
    home_total = excluded.home_total, away_total = excluded.away_total,
    home_fulls = excluded.home_fulls, away_fulls = excluded.away_fulls,
    home_spares = excluded.home_spares, away_spares = excluded.away_spares,
    home_errors = excluded.home_errors, away_errors = excluded.away_errors,
    home_set_points = excluded.home_set_points,
    away_set_points = excluded.away_set_points,
    fetched_at = now();

  delete from match_player_results where match_id = v_row.id;
  insert into match_player_results
    (match_id, tenant_id, side, position, player_name, player_site_id, player_slug,
     fulls, spares, errors, total, set_points, team_points, lanes)
  select v_row.id, p_tenant, p->>'side', (p->>'position')::smallint, p->>'player_name',
         (p->>'player_site_id')::integer, p->>'player_slug',
         (p->>'fulls')::integer, (p->>'spares')::integer, (p->>'errors')::integer,
         (p->>'total')::integer, (p->>'set_points')::numeric,
         (p->>'team_points')::numeric, coalesce(p->'lanes', '[]'::jsonb)
    from jsonb_array_elements(coalesce(p_result->'players', '[]'::jsonb)) p;
  return true;
end;
$$;

-- Discovery: new teams arrive active; an existing team keeps its name,
-- club and switch — only the site's facts are refreshed.
create or replace function upsert_federation_teams(p_tenant uuid, p_teams jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  t jsonb;
  v_name text;
  v_new integer := 0;
begin
  for t in select * from jsonb_array_elements(p_teams) loop
    update teams
       set site_team_id = (t->>'site_team_id')::integer, site_name = t->>'site_name',
           competition_slug = t->>'competition_slug',
           competition_name = t->>'competition_name'
     where tenant_id = p_tenant and site_slug = t->>'site_slug';
    if found then
      continue;
    end if;
    v_name := left(t->>'name', 80);
    if exists (select 1 from teams where tenant_id = p_tenant and name = v_name) then
      v_name := left((t->>'name') || ' (' || (t->>'competition_name') || ')', 80);
    end if;
    if exists (select 1 from teams where tenant_id = p_tenant and name = v_name) then
      v_name := left((t->>'site_name') || ' (' || (t->>'site_slug') || ')', 80);
    end if;
    insert into teams (tenant_id, name, club_id, site_team_id, site_slug, site_name,
                       competition_slug, competition_name)
    values (p_tenant, v_name, (t->>'club_id')::uuid, (t->>'site_team_id')::integer,
            t->>'site_slug', t->>'site_name', t->>'competition_slug',
            t->>'competition_name');
    v_new := v_new + 1;
  end loop;
  return v_new;
end;
$$;

create or replace function upsert_federation_venue(p_tenant uuid, p_venue jsonb)
returns void language sql security definer set search_path = public as $$
  insert into venues as v
    (tenant_id, slug, name, address, phone, email, lat, lng, sections, clubs, fetched_at)
  values
    (p_tenant, p_venue->>'slug', p_venue->>'name', p_venue->>'address',
     p_venue->>'phone', p_venue->>'email', (p_venue->>'lat')::numeric,
     (p_venue->>'lng')::numeric, coalesce(p_venue->'sections', '[]'::jsonb),
     coalesce(array(select jsonb_array_elements_text(p_venue->'clubs')), '{}'), now())
  on conflict (tenant_id, slug) do update set
    name = excluded.name, address = excluded.address, phone = excluded.phone,
    email = excluded.email, lat = excluded.lat, lng = excluded.lng,
    sections = excluded.sections, clubs = excluded.clubs, fetched_at = now();
$$;

create or replace function record_federation_run(
  p_tenant uuid, p_key text, p_report jsonb, p_error text)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into federation_sync (tenant_id) values (p_tenant) on conflict do nothing;
  update federation_sync
     set last_run_at = now(),
         last_success_at = case when p_error is null then now() else last_success_at end,
         -- Match and venue jobs record only failures, so only the keys whose
         -- success clears last_error may set it.
         last_error = case when p_key = 'discover' or p_key like 'competition:%'
                           then p_error else last_error end,
         last_report = last_report || jsonb_build_object(p_key,
           case when p_error is null
             then coalesce(p_report, '{}'::jsonb) || jsonb_build_object('at', now())
             else jsonb_build_object('error', p_error, 'at', now()) end)
   where tenant_id = p_tenant;
end;
$$;

-- An earlier run_at wins: the nightly pass must not push back a
-- checkpoint the job already set (T−24 h, T−1 h …). requested_at is
-- refresh_match's gate and survives a re-arm.
create or replace function enqueue_federation_match(
  p_tenant uuid, p_site_match_id integer, p_slug text, p_run_at timestamptz)
returns void language sql security definer set search_path = public as $$
  insert into notification_jobs (kind, dedupe_key, payload, run_at)
  values ('federation_match', 'federation_match:' || p_tenant || ':' || p_site_match_id,
          jsonb_build_object('tenant_id', p_tenant, 'site_match_id', p_site_match_id,
                             'slug', p_slug),
          p_run_at)
  on conflict (dedupe_key) do update
    set run_at = least(notification_jobs.run_at, excluded.run_at),
        payload = excluded.payload || jsonb_strip_nulls(jsonb_build_object(
                    'requested_at', notification_jobs.payload->'requested_at'));
$$;

create or replace function enqueue_federation_jobs()
returns void language plpgsql security definer set search_path = public as $$
declare
  r record;
  i integer := 0;
begin
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

revoke all on function federation_description(text, integer, boolean, text) from public, anon, authenticated;
revoke all on function apply_federation_matches(uuid, text, jsonb, integer[]) from public, anon, authenticated;
revoke all on function apply_federation_result(uuid, integer, jsonb) from public, anon, authenticated;
revoke all on function upsert_federation_teams(uuid, jsonb) from public, anon, authenticated;
revoke all on function record_federation_run(uuid, text, jsonb, text) from public, anon, authenticated;
revoke all on function enqueue_federation_match(uuid, integer, text, timestamptz) from public, anon, authenticated;
revoke all on function enqueue_federation_jobs() from public, anon, authenticated;
revoke all on function enqueue_federation_venue(uuid, text, interval) from public, anon, authenticated;
revoke all on function upsert_federation_venue(uuid, jsonb) from public, anon, authenticated;
grant execute on function apply_federation_matches(uuid, text, jsonb, integer[]) to service_role;
grant execute on function apply_federation_result(uuid, integer, jsonb) to service_role;
grant execute on function upsert_federation_teams(uuid, jsonb) to service_role;
grant execute on function record_federation_run(uuid, text, jsonb, text) to service_role;
grant execute on function enqueue_federation_match(uuid, integer, text, timestamptz) to service_role;
grant execute on function upsert_federation_venue(uuid, jsonb) to service_role;

-- ---------------------------------------------------------------- RPCs
create or replace function set_federation_sync(p_venue_slug text, p_enabled boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_slug text := lower(trim(coalesce(p_venue_slug, '')));
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then
    raise exception 'invalid_venue_slug';
  end if;
  insert into federation_sync (tenant_id, venue_slug, enabled)
  values (current_tenant_id(), v_slug, p_enabled)
  on conflict (tenant_id) do update
    set venue_slug = excluded.venue_slug, enabled = excluded.enabled;
end;
$$;

create or replace function request_federation_discovery()
returns void language plpgsql security definer set search_path = public as $$
declare
  v_tenant uuid := current_tenant_id();
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if not exists (select 1 from federation_sync
                  where tenant_id = v_tenant and venue_slug <> '') then
    raise exception 'federation_not_configured';
  end if;
  perform enqueue_notification('federation_discover', 'federation_discover:' || v_tenant,
    jsonb_build_object('tenant_id', v_tenant), interval '0');
  perform trigger_notification_jobs();
end;
$$;

create or replace function request_federation_sync()
returns void language plpgsql security definer set search_path = public as $$
declare
  v_tenant uuid := current_tenant_id();
  r record;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if not exists (select 1 from federation_sync
                  where tenant_id = v_tenant and enabled and venue_slug <> '') then
    raise exception 'federation_disabled';
  end if;
  for r in select distinct competition_slug from teams
            where tenant_id = v_tenant and active and competition_slug <> '' loop
    perform enqueue_notification('federation_competition',
      'federation_competition:' || v_tenant || ':' || r.competition_slug,
      jsonb_build_object('tenant_id', v_tenant, 'competition_slug', r.competition_slug),
      interval '0');
  end loop;
  perform enqueue_federation_venue(s.tenant_id, s.venue_slug)
     from federation_sync s
    where s.tenant_id = v_tenant
      and not exists (select 1 from venues v
                       where v.tenant_id = s.tenant_id and v.slug = s.venue_slug);
  perform trigger_notification_jobs();
end;
$$;

create or replace function update_team(
  p_id uuid, p_name text, p_club_id uuid, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if trim(coalesce(p_name, '')) = '' then
    raise exception 'empty_name';
  end if;
  if p_club_id is not null and not exists (
      select 1 from clubs where id = p_club_id and tenant_id = current_tenant_id()) then
    raise exception 'not_allowed';
  end if;
  begin
    update teams set name = trim(p_name), club_id = p_club_id, active = p_active
     where id = p_id and tenant_id = current_tenant_id();
  exception when unique_violation then
    raise exception 'team_name_taken';
  end;
  if not found then
    raise exception 'not_allowed';
  end if;
end;
$$;

-- On-demand refresh of a live match, gated here so no client can hammer
-- the site: at most one fetch per match per 5 minutes.
create or replace function refresh_match(p_match_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_slot priority_slots;
  v_status text;
  v_fetched timestamptz;
  v_start timestamptz;
  v_job bigint;
begin
  if not is_approved_or_kiosk() then
    raise exception 'not_allowed';
  end if;
  select * into v_slot from priority_slots
   where id = p_match_id and tenant_id = current_tenant_id();
  if not found or v_slot.site_match_id is null then
    return 'not_live';
  end if;
  select status, fetched_at into v_status, v_fetched
    from match_results where match_id = p_match_id;
  v_status := coalesce(v_status, 'scheduled');
  v_start := (v_slot.date + v_slot.starts_at) at time zone 'Europe/Prague';
  if not ((v_status in ('preparation', 'in_progress') and now() < v_start + interval '12 hours')
          or (v_status = 'scheduled'
              and now() between v_start - interval '1 hour' and v_start + interval '6 hours')) then
    return 'not_live';
  end if;
  if v_fetched is not null and v_fetched > now() - interval '5 minutes' then
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
          < now() - interval '5 minutes'
  returning id into v_job;
  if v_job is not null then
    perform trigger_notification_jobs();
  end if;
  return 'queued';
end;
$$;

revoke all on function set_federation_sync(text, boolean) from public, anon;
revoke all on function request_federation_discovery() from public, anon;
revoke all on function request_federation_sync() from public, anon;
revoke all on function update_team(uuid, text, uuid, boolean) from public, anon;
revoke all on function refresh_match(uuid) from public, anon;
grant execute on function set_federation_sync(text, boolean) to authenticated;
grant execute on function request_federation_discovery() to authenticated;
grant execute on function request_federation_sync() to authenticated;
grant execute on function update_team(uuid, text, uuid, boolean) to authenticated;
grant execute on function refresh_match(uuid) to authenticated;

-- ---------------------------------------------------------------- cron
do $$
begin
  if exists (select 1 from cron.job where jobname = 'federation-nightly') then
    perform cron.unschedule('federation-nightly');
  end if;
  perform cron.schedule('federation-nightly', '0 1 * * *',
    'select public.enqueue_federation_jobs()');
end $$;
