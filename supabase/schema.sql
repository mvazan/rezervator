


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE OR REPLACE FUNCTION "public"."_group_drop_member"("p_group" "uuid", "p_user" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  delete from player_group_members
   where group_id = p_group and user_id = p_user and status = 'member';
  if not exists (select 1 from player_group_members
                 where group_id = p_group and status = 'member') then
    delete from player_groups where id = p_group;
  end if;
end;
$$;


ALTER FUNCTION "public"."_group_drop_member"("p_group" "uuid", "p_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."add_special_block"("p_starts_at" time without time zone, "p_ends_at" time without time zone) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_id uuid;
begin
  perform duty_edit_days_gate();
  insert into time_blocks (tenant_id, starts_at, ends_at, position, active)
    values (current_tenant_id(), p_starts_at, p_ends_at, -1, false)
    returning id into v_id;
  return v_id;
end;
$$;


ALTER FUNCTION "public"."add_special_block"("p_starts_at" time without time zone, "p_ends_at" time without time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_list_tenants"() RETURNS TABLE("id" "uuid", "name" "text", "status" "text", "founder_email" "text", "created_at" timestamp with time zone, "approved_at" timestamp with time zone, "member_count" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_superadmin() then
    raise exception 'not_allowed';
  end if;
  return query
  select t.id, t.name, t.status, t.founder_email, t.created_at,
         t.approved_at, count(p.id)
  from tenants t
  left join profiles p on p.tenant_id = t.id
  group by t.id
  order by (t.status = 'pending') desc, t.created_at desc;
end;
$$;


ALTER FUNCTION "public"."admin_list_tenants"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_federation_discovery"("p_tenant" "uuid", "p_clubs" "jsonb", "p_teams" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  c jsonb;
  v_club uuid;
  v_name text;
  v_ids jsonb := '{}'::jsonb;
  v_created text[] := '{}';
  v_linked text[] := '{}';
  v_teams jsonb;
  v_had text[];
  v_new integer;
  v_new_names jsonb;
begin
  for c in select * from jsonb_array_elements(coalesce(p_clubs, '[]'::jsonb)) loop
    select id, name into v_club, v_name from clubs
     where tenant_id = p_tenant and site_slug = c->>'slug';
    if v_club is not null then
      update clubs set site_name = c->>'name'
       where id = v_club and site_name is distinct from c->>'name';
    else
      update clubs set site_slug = c->>'slug', site_name = c->>'name'
       where tenant_id = p_tenant and id = (c->>'match_id')::uuid and site_slug is null
      returning id, name into v_club, v_name;
    end if;
    if v_club is not null then
      v_linked := v_linked || v_name;
    else
      v_name := rtrim(left(coalesce(nullif(trim(c->>'name'), ''), c->>'slug'), 80));
      -- Palette entries are 0–8 (clubs_color_check since 0031, ClubColors
      -- in lib/domain/palette.dart); -1 and hand-picked colours use none.
      insert into clubs (tenant_id, name, color, site_slug, site_name)
      values (p_tenant, v_name,
              (select i from generate_series(0, 8) i
                order by (select count(*) from clubs k
                           where k.tenant_id = p_tenant and k.color = i), i
                limit 1),
              c->>'slug', c->>'name')
      on conflict do nothing
      returning id into v_club;
      if v_club is not null then
        v_created := v_created || v_name;
      end if;
    end if;
    if v_club is not null then
      v_ids := v_ids || jsonb_build_object(c->>'slug', v_club);
    end if;
  end loop;
  select coalesce(jsonb_agg(x || jsonb_build_object('club_id', v_ids->(x->>'club_slug'))
                            order by o), '[]'::jsonb)
    into v_teams
    from jsonb_array_elements(coalesce(p_teams, '[]'::jsonb)) with ordinality e(x, o);
  select coalesce(array_agg(site_slug), '{}') into v_had
    from teams where tenant_id = p_tenant;
  v_new := upsert_federation_teams(p_tenant, v_teams);
  select coalesce(jsonb_agg(t.name order by t.name), '[]'::jsonb) into v_new_names
    from teams t
   where t.tenant_id = p_tenant and t.site_slug <> all (v_had)
     and t.site_slug in (select x->>'site_slug' from jsonb_array_elements(v_teams) x);
  return jsonb_build_object(
    'created', v_new,
    'teams_created', v_new_names,
    'clubs_created', to_jsonb(v_created),
    'clubs_linked', to_jsonb(v_linked));
end;
$$;


ALTER FUNCTION "public"."apply_federation_discovery"("p_tenant" "uuid", "p_clubs" "jsonb", "p_teams" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_federation_matches"("p_tenant" "uuid", "p_competition_slug" "text", "p_matches" "jsonb", "p_keep_ids" integer[] DEFAULT '{}'::integer[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
         video_url, competition, round, site_slug, site_match_id,
         home_team_slug, away_team_slug)
      values
        (p_tenant, (m->>'date')::date, (m->>'starts_at')::time, (m->>'ends_at')::time,
         v_type, m->>'home', m->>'away',
         case when v_is_away then 0 else (m->>'prep')::smallint end,
         federation_description(m->>'competition', (m->>'round')::integer, v_is_away, null),
         v_is_away, v_admin, v_key,
         m->>'video_url', m->>'competition', (m->>'round')::smallint,
         m->>'site_slug', (m->>'site_match_id')::integer,
         m->>'home_slug', m->>'away_slug');
      v_ins := v_ins + 1;
      continue;
    end if;

    update priority_slots
       set video_url = m->>'video_url', competition = m->>'competition',
           round = (m->>'round')::smallint, site_slug = m->>'site_slug',
           site_match_id = (m->>'site_match_id')::integer,
           home_team_slug = m->>'home_slug', away_team_slug = m->>'away_slug'
     where id = v_row.id
       and (video_url, competition, round, site_slug, site_match_id,
            home_team_slug, away_team_slug)
           is distinct from
           (m->>'video_url', m->>'competition', (m->>'round')::smallint,
            m->>'site_slug', (m->>'site_match_id')::integer,
            m->>'home_slug', m->>'away_slug');

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


ALTER FUNCTION "public"."apply_federation_matches"("p_tenant" "uuid", "p_competition_slug" "text", "p_matches" "jsonb", "p_keep_ids" integer[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_federation_result"("p_tenant" "uuid", "p_site_match_id" integer, "p_result" "jsonb") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."apply_federation_result"("p_tenant" "uuid", "p_site_match_id" integer, "p_result" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_league_matches"("p_tenant" "uuid", "p_competition_slug" "text", "p_matches" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
  v_slot priority_slots;
  v_n integer;
  v_final constant text[] := array['finished', 'forfeit'];
  v_status text;
  v_type text;
  v_disc text;
  v_sig text;
  v_changed boolean;
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
    v_home := coalesce(m->'home', '{}'::jsonb);
    v_away := coalesce(m->'away', '{}'::jsonb);
    v_status := coalesce(m->>'status', 'scheduled');
    select * into v_slot from priority_slots
     where tenant_id = p_tenant and import_key = 'cka:' || v_id;
    -- Ours and active (has a slot): its own job fetches it. A switched-off
    -- team's slot is stale for good, so its match is kept here instead.
    if found and not federation_match_switched_off(
         p_tenant, v_slot.home_team_slug, v_slot.away_team_slug) then
      continue;
    end if;
    v_seen := v_seen || v_id;
    v_sig := jsonb_build_array(
      v_status, v_home->'points', v_away->'points', v_home->'total', v_away->'total',
      v_home->'fulls', v_away->'fulls', v_home->'spares', v_away->'spares',
      v_home->'errors', v_away->'errors', v_home->'set_points', v_away->'set_points')::text;
    select * into v_row from league_matches
     where tenant_id = p_tenant and site_match_id = v_id;
    if not found then
      insert into league_matches
        (tenant_id, site_match_id, site_slug, competition_slug, competition, round,
         date, starts_at, home_team, away_team, home_team_slug, away_team_slug,
         video_url, status, match_type, discipline,
         home_points, away_points, home_total, away_total, home_fulls, away_fulls,
         home_spares, away_spares, home_errors, away_errors,
         home_set_points, away_set_points, round_sig)
      values
        (p_tenant, v_id, m->>'site_slug', p_competition_slug,
         coalesce(m->>'competition', ''), (m->>'round')::smallint,
         (m->>'date')::date, nullif(m->>'starts_at', '')::time, m->>'home_team', m->>'away_team',
         coalesce(m->>'home_team_slug', ''), coalesce(m->>'away_team_slug', ''),
         m->>'video_url', v_status,
         coalesce(m->>'match_type', ''), coalesce(m->>'discipline', ''),
         (v_home->>'points')::numeric, (v_away->>'points')::numeric,
         (v_home->>'total')::integer, (v_away->>'total')::integer,
         (v_home->>'fulls')::integer, (v_away->>'fulls')::integer,
         (v_home->>'spares')::integer, (v_away->>'spares')::integer,
         (v_home->>'errors')::integer, (v_away->>'errors')::integer,
         (v_home->>'set_points')::numeric, (v_away->>'set_points')::numeric, v_sig);
      v_inserted := v_inserted + 1;
    else
      v_changed := v_row.round_sig is distinct from v_sig;
      -- The format is the round page's when it has one.
      v_type := coalesce(nullif(m->>'match_type', ''), v_row.match_type);
      v_disc := coalesce(nullif(m->>'discipline', ''), v_row.discipline);
      update league_matches set
        site_slug = m->>'site_slug', competition_slug = p_competition_slug,
        competition = coalesce(m->>'competition', ''), round = (m->>'round')::smallint,
        date = (m->>'date')::date, starts_at = nullif(m->>'starts_at', '')::time,
        home_team = m->>'home_team', away_team = m->>'away_team',
        home_team_slug = coalesce(m->>'home_team_slug', ''),
        away_team_slug = coalesce(m->>'away_team_slug', ''),
        video_url = m->>'video_url', match_type = v_type, discipline = v_disc,
        -- The result: only when the round page's own version changed.
        status = case when v_changed then v_status else status end,
        home_points = case when v_changed then (v_home->>'points')::numeric else home_points end,
        away_points = case when v_changed then (v_away->>'points')::numeric else away_points end,
        home_total = case when v_changed then (v_home->>'total')::integer else home_total end,
        away_total = case when v_changed then (v_away->>'total')::integer else away_total end,
        home_fulls = case when v_changed then (v_home->>'fulls')::integer else home_fulls end,
        away_fulls = case when v_changed then (v_away->>'fulls')::integer else away_fulls end,
        home_spares = case when v_changed then (v_home->>'spares')::integer else home_spares end,
        away_spares = case when v_changed then (v_away->>'spares')::integer else away_spares end,
        home_errors = case when v_changed then (v_home->>'errors')::integer else home_errors end,
        away_errors = case when v_changed then (v_away->>'errors')::integer else away_errors end,
        home_set_points = case when v_changed then (v_home->>'set_points')::numeric
                               else home_set_points end,
        away_set_points = case when v_changed then (v_away->>'set_points')::numeric
                               else away_set_points end,
        -- A final match whose result differs from what is stored (the detail
        -- may have written the same already) has its lines fetched again.
        detail_status = case when v_changed and v_status = any (v_final)
                                  and (status, home_points, away_points, home_total, away_total,
                                       home_fulls, away_fulls, home_spares, away_spares,
                                       home_errors, away_errors, home_set_points, away_set_points)
                                      is distinct from
                                      (v_status, (v_home->>'points')::numeric,
                                       (v_away->>'points')::numeric, (v_home->>'total')::integer,
                                       (v_away->>'total')::integer, (v_home->>'fulls')::integer,
                                       (v_away->>'fulls')::integer, (v_home->>'spares')::integer,
                                       (v_away->>'spares')::integer, (v_home->>'errors')::integer,
                                       (v_away->>'errors')::integer, (v_home->>'set_points')::numeric,
                                       (v_away->>'set_points')::numeric)
                             then null else detail_status end,
        detail_queued = case when v_changed then 0 else detail_queued end,
        round_sig = v_sig,
        fetched_at = now()
       where id = v_row.id
         and (v_changed
              or (site_slug, competition_slug, competition, round, date, starts_at,
                  home_team, away_team, home_team_slug, away_team_slug, video_url,
                  match_type, discipline)
                 is distinct from
                 (m->>'site_slug', p_competition_slug, coalesce(m->>'competition', ''),
                  (m->>'round')::smallint, (m->>'date')::date,
                  nullif(m->>'starts_at', '')::time, m->>'home_team', m->>'away_team',
                  coalesce(m->>'home_team_slug', ''), coalesce(m->>'away_team_slug', ''),
                  m->>'video_url', v_type, v_disc));
      get diagnostics v_n = row_count;
      v_updated := v_updated + v_n;
    end if;
  end loop;

  -- A match that turned into one of ours and active (a team discovered or
  -- switched on later, a time set) leaves.
  delete from league_matches l
   where l.tenant_id = p_tenant and l.competition_slug = p_competition_slug
     and exists (select 1 from priority_slots p
                  where p.tenant_id = p_tenant and p.import_key = 'cka:' || l.site_match_id
                    and not federation_match_switched_off(p.tenant_id, p.home_team_slug,
                                                          p.away_team_slug));
  get diagnostics v_n = row_count;
  v_deleted := v_deleted + v_n;
  -- The site no longer lists it: only judged from a non-empty list.
  if jsonb_array_length(coalesce(p_matches, '[]'::jsonb)) > 0 then
    delete from league_matches l
     where l.tenant_id = p_tenant and l.competition_slug = p_competition_slug
       and not (l.site_match_id = any (v_seen));
    get diagnostics v_n = row_count;
    v_deleted := v_deleted + v_n;
  end if;
  perform league_drop_orphan_jobs(p_tenant);

  -- One detail fetch per final match whose player lines are not final yet
  -- (a detail that keeps saying „in progress“ is given up a week after the
  -- match); a pending or backing-off job is left alone (only a stale slug is
  -- mended).
  with due as (
    select l.site_match_id, l.site_slug
      from league_matches l
     where l.tenant_id = p_tenant and l.competition_slug = p_competition_slug
       and l.status = any (v_final)
       and l.detail_queued < 3
       and (l.detail_status is null
            or (not (l.detail_status = any (v_final))
                and l.date >= (now() at time zone 'Europe/Prague')::date - 7))
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
    returning (xmax = 0) as fresh, (j.payload->>'site_match_id')::integer as sid
  ), bump as (
    update league_matches l set detail_queued = l.detail_queued + 1
      from ins
     where ins.fresh and l.tenant_id = p_tenant and l.site_match_id = ins.sid
    returning 1
  )
  select count(*) filter (where fresh) into v_jobs from ins;

  return jsonb_build_object('league_inserted', v_inserted, 'league_updated', v_updated,
                            'league_deleted', v_deleted, 'league_detail_jobs', v_jobs);
end;
$$;


ALTER FUNCTION "public"."apply_league_matches"("p_tenant" "uuid", "p_competition_slug" "text", "p_matches" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_league_result"("p_tenant" "uuid", "p_site_match_id" integer, "p_result" "jsonb") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
    fetched_at = now(), detail_status = v_new, detail_fetched_at = now(),
    detail_queued = case when v_new = any (v_final) then 0 else detail_queued end
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


ALTER FUNCTION "public"."apply_league_result"("p_tenant" "uuid", "p_site_match_id" integer, "p_result" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_player"("p_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;

  update profiles
  set status = 'approved', approved_by = auth.uid(), approved_at = now()
  where id = p_user_id and status = 'pending'
    and tenant_id = current_tenant_id();
end;
$$;


ALTER FUNCTION "public"."approve_player"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_tenant"("p_tenant_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_superadmin() then
    raise exception 'not_allowed';
  end if;
  update tenants
  set status = 'approved', approved_at = now()
  where id = p_tenant_id;
  if not found then
    raise exception 'unknown_tenant';
  end if;
end;
$$;


ALTER FUNCTION "public"."approve_tenant"("p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."backfill_calendar_jobs"("p_user" "uuid") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."backfill_calendar_jobs"("p_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."block_day_status"("p_tenant" "uuid", "p_date" "date", "p_block_id" "uuid") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select case
    when b.id is null then 'unknown_block'
    when o.tenant_id is not null and o.closed then 'day_closed'
    when o.tenant_id is not null then
      case
        when o.block_ids is null then
          case when b.active then 'open' else 'invalid_block' end
        when p_block_id = any (o.block_ids) then 'open'
        else 'invalid_block'
      end
    when not (extract(isodow from p_date)::smallint
              = any (s.training_weekdays)) then 'day_closed'
    when b.active then 'open'
    else 'invalid_block'
  end
  from schedule_settings s
  left join time_blocks b
    on b.id = p_block_id and b.tenant_id = s.tenant_id
  left join day_overrides o
    on o.tenant_id = s.tenant_id and o.date = p_date
  where s.tenant_id = p_tenant;
$$;


ALTER FUNCTION "public"."block_day_status"("p_tenant" "uuid", "p_date" "date", "p_block_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_read_message"("p_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from messages m
     where m.id = p_id and m.tenant_id = current_tenant_id()
       and (
         (is_approved() and not is_kiosk()
          and (m.kind = 'notice'
               or m.author_id = auth.uid()
               or exists (select 1 from message_recipients r
                           where r.message_id = m.id and r.user_id = auth.uid())))
         or (is_kiosk() and m.kind = 'notice')
       )
  )
$$;


ALTER FUNCTION "public"."can_read_message"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_block_day_reservations"("p_date" "date", "p_block" "uuid", "p_note" "text" DEFAULT 'změna rozvrhu'::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_admin boolean := is_admin();
  v_today date := (now() at time zone 'Europe/Prague')::date;
  v_now time := (now() at time zone 'Europe/Prague')::time;
begin
  perform duty_edit_gate(p_date);
  if not exists (
    select 1 from time_blocks
    where id = p_block and tenant_id = current_tenant_id()
  ) then
    raise exception 'unknown_block';
  end if;

  update reservations r
  set cancelled_at = now(),
      cancelled_via = 'admin',
      cancel_note = coalesce(nullif(trim(p_note), ''), 'změna rozvrhu'),
      notify_player = true,
      notify_message = null
  from time_blocks b
  where b.id = r.block_id
    and r.date = p_date
    and r.block_id = p_block
    and r.cancelled_at is null
    and r.tenant_id = current_tenant_id()
    and (v_admin or not (r.date = v_today and b.starts_at <= v_now));
end;
$$;


ALTER FUNCTION "public"."cancel_block_day_reservations"("p_date" "date", "p_block" "uuid", "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_res_for_priority"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform cancel_res_for_priority_slot(new);
  return new;
end;
$$;


ALTER FUNCTION "public"."cancel_res_for_priority"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."current_tenant_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ select tenant_id from profiles where id = auth.uid() $$;


ALTER FUNCTION "public"."current_tenant_id"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."priority_slots" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "date" "date" NOT NULL,
    "starts_at" time without time zone NOT NULL,
    "ends_at" time without time zone NOT NULL,
    "away_team" "text" DEFAULT ''::"text" NOT NULL,
    "description" "text" DEFAULT ''::"text" NOT NULL,
    "import_key" "text",
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "home_team" "text" DEFAULT ''::"text" NOT NULL,
    "prep_minutes" smallint DEFAULT 0 NOT NULL,
    "type_id" "uuid" NOT NULL,
    "tenant_id" "uuid" DEFAULT "public"."current_tenant_id"() NOT NULL,
    "parent_id" "uuid",
    "is_away" boolean DEFAULT false NOT NULL,
    "hand_edited" boolean DEFAULT false NOT NULL,
    "video_url" "text",
    "competition" "text",
    "round" smallint,
    "site_slug" "text",
    "site_match_id" integer,
    "venue" "text",
    "venue_slug" "text",
    "home_team_slug" "text",
    "away_team_slug" "text",
    CONSTRAINT "matches_check" CHECK (("ends_at" > "starts_at")),
    CONSTRAINT "matches_prep_minutes_check" CHECK ((("prep_minutes" >= 0) AND ("prep_minutes" <= 240)))
);


ALTER TABLE "public"."priority_slots" OWNER TO "postgres";


COMMENT ON COLUMN "public"."priority_slots"."hand_edited" IS 'Imported match (import_key set) whose match columns changed outside an import run (session setting import.run <> ''on''). The next import leaves the row alone unless forced. Set by priority_slots_hand_edit.';



CREATE OR REPLACE FUNCTION "public"."cancel_res_for_priority_slot"("p_slot" "public"."priority_slots") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
                         then 'zápas: ' || p_slot.away_team
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


ALTER FUNCTION "public"."cancel_res_for_priority_slot"("p_slot" "public"."priority_slots") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_res_for_rental"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_row rentals;
  v_old_date date;
  v_today date := (now() at time zone 'Europe/Prague')::date;
begin
  if tg_op = 'DELETE' then
    if old.parent_id is null then
      return old;
    end if;
    v_row := old;
  else
    v_row := new;
    if tg_op = 'UPDATE' then
      v_old_date := old.date;
    end if;
  end if;

  update reservations r
  set cancelled_at = now(), cancelled_via = 'admin',
      cancel_note = 'pronájem: ' || x.renter_name,
      notify_player = true,
      notify_message = null
  from (
    select r2.id, o.renter_name
    from reservations r2
    join time_blocks b on b.id = r2.block_id
    cross join lateral rental_occurrences(v_row.tenant_id, r2.date) o
    where r2.tenant_id = v_row.tenant_id
      and r2.cancelled_at is null
      and r2.date >= v_today
      and (v_row.parent_id is null            -- series: every date from today on
           or r2.date = v_row.date             -- exception: its date
           or r2.date = v_old_date)            -- …and the date it left
      and o.rental_id = coalesce(v_row.parent_id, v_row.id)
      and r2.lane = any (o.lanes)
      and b.starts_at < o.ends_at and b.ends_at > o.starts_at
  ) x
  where r.id = x.id;

  return coalesce(new, old);
end;
$$;


ALTER FUNCTION "public"."cancel_res_for_rental"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_res_for_type_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."cancel_res_for_type_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_reservation"("p_id" "uuid", "p_note" "text" DEFAULT ''::"text", "p_notify" boolean DEFAULT true) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid uuid := auth.uid();
  v_caller profiles;
  v_res reservations;
  v_block time_blocks;
  v_via text;
  v_now timestamptz := now();
  v_starts timestamptz;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  select * into v_caller from profiles where id = v_uid;
  if not found then
    raise exception 'no_profile';
  end if;

  select * into v_res from reservations where id = p_id;
  if not found then
    raise exception 'not_found';
  end if;
  if v_res.cancelled_at is not null then
    return;  -- already cancelled, idempotent
  end if;

  if v_caller.role = 'admin' and v_caller.status = 'approved'
     and v_res.tenant_id = v_caller.tenant_id then
    v_via := 'admin';
  elsif v_caller.status = 'approved'
        and (v_res.player_id = v_uid
             or (v_caller.role = 'player' and same_group(v_uid, v_res.player_id))) then
    select * into v_block from time_blocks where id = v_res.block_id;
    v_starts := (v_res.date + v_block.starts_at) at time zone 'Europe/Prague';
    if v_now >= v_starts then
      raise exception 'too_late';
    end if;
    v_via := case when v_res.player_id = v_uid then 'app' else 'group' end;
  elsif v_caller.status = 'approved' and v_caller.role = 'player'
        and v_res.tenant_id = v_caller.tenant_id and is_on_duty() then
    select * into v_block from time_blocks where id = v_res.block_id;
    v_starts := (v_res.date + v_block.starts_at) at time zone 'Europe/Prague';
    if v_now >= v_starts then
      raise exception 'too_late';
    end if;
    v_via := 'duty';
  else
    raise exception 'not_allowed';
  end if;

  update reservations
  set cancelled_at = v_now, cancelled_via = v_via, cancelled_by = v_uid,
      cancel_note = trim(coalesce(p_note, '')),
      notify_player = coalesce(p_notify, true),
      notify_message = null
  where id = p_id;
end;
$$;


ALTER FUNCTION "public"."cancel_reservation"("p_id" "uuid", "p_note" "text", "p_notify" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_stranded_reservations"("p_tenant" "uuid", "p_note" "text" DEFAULT 'změna rozvrhu'::"text") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_today date := (now() at time zone 'Europe/Prague')::date;
  v_now time := (now() at time zone 'Europe/Prague')::time;
  v_count integer;
begin
  with stranded as (
    update reservations r
    set cancelled_at = now(), cancelled_via = 'admin',
        cancel_note = coalesce(nullif(trim(p_note), ''), 'změna rozvrhu'),
        notify_player = true, notify_message = null
    from time_blocks b, schedule_settings s
    where b.id = r.block_id
      and s.tenant_id = r.tenant_id
      and r.tenant_id = p_tenant
      and r.cancelled_at is null
      and (r.date > v_today or (r.date = v_today and b.starts_at > v_now))
      and (r.lane > s.lane_count
           or block_day_status(r.tenant_id, r.date, r.block_id) <> 'open')
    returning 1
  )
  select count(*) into v_count from stranded;
  return v_count;
end;
$$;


ALTER FUNCTION "public"."cancel_stranded_reservations"("p_tenant" "uuid", "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cascade_schedule_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  -- to_jsonb: plpgsql resolves record fields per table, and only
  -- day_overrides has a reason column.
  perform cancel_stranded_reservations(
    coalesce(new.tenant_id, old.tenant_id),
    case when tg_table_name = 'day_overrides' and tg_op <> 'DELETE'
         then to_jsonb(new)->>'reason' else 'změna rozvrhu' end);
  return coalesce(new, old);
end;
$$;


ALTER FUNCTION "public"."cascade_schedule_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."claim_freed_spot_watchers"("p_reservation" "uuid") RETURNS TABLE("user_id" "uuid", "email" "text", "fcm_token" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."claim_freed_spot_watchers"("p_reservation" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."consume_calendar_nonce"("p_nonce" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_user uuid;
begin
  update oauth_nonces
    set consumed_at = now()
    where nonce = p_nonce
      and consumed_at is null
      and created_at > now() - interval '10 minutes'
    returning user_id into v_user;
  return v_user;
end;
$$;


ALTER FUNCTION "public"."consume_calendar_nonce"("p_nonce" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."contacts"() RETURNS TABLE("id" "uuid", "display_name" "text", "nick" "text", "club_id" "uuid", "club_name" "text", "club_color" integer, "email" "text", "phone" "text", "regnum" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_approved() or is_kiosk() then
    raise exception 'not_allowed';
  end if;
  return query
    select p.id, p.display_name, p.nick, p.club_id, c.name,
           coalesce(c.color, -1),
           case when p.show_email then nullif(p.email, '') end,
           case when p.show_phone then p.phone end,
           p.regnum
      from profiles p
      left join clubs c on c.id = p.club_id
     where p.tenant_id = current_tenant_id()
       and p.status = 'approved'
       and p.role <> 'kiosk'
       and not p.placeholder
       and not (p.superadmin
                and p.home_tenant_id is not null
                and p.tenant_id <> p.home_tenant_id)
     order by p.display_name;
end;
$$;


ALTER FUNCTION "public"."contacts"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."reservations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "player_id" "uuid" NOT NULL,
    "date" "date" NOT NULL,
    "block_id" "uuid" NOT NULL,
    "lane" smallint NOT NULL,
    "created_via" "text" NOT NULL,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "cancelled_at" timestamp with time zone,
    "cancelled_via" "text",
    "cancel_note" "text" DEFAULT ''::"text" NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "notify_player" boolean DEFAULT true NOT NULL,
    "notify_message" "text",
    "cancelled_by" "uuid",
    CONSTRAINT "reservations_cancelled_via_check" CHECK (("cancelled_via" = ANY (ARRAY['app'::"text", 'one_click'::"text", 'admin'::"text", 'group'::"text", 'duty'::"text"]))),
    CONSTRAINT "reservations_created_via_check" CHECK (("created_via" = ANY (ARRAY['app'::"text", 'kiosk'::"text", 'admin'::"text", 'group'::"text", 'duty'::"text"]))),
    CONSTRAINT "reservations_lane_check" CHECK (("lane" >= 1))
);


ALTER TABLE "public"."reservations" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_reservation"("p_player_id" "uuid", "p_date" "date", "p_block_id" "uuid", "p_lane" smallint) RETURNS "public"."reservations"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid uuid := auth.uid();
  v_caller profiles;
  v_settings schedule_settings;
  v_block time_blocks;
  v_status text;
  v_via text;
  v_today date := (now() at time zone 'Europe/Prague')::date;
  v_now time := (now() at time zone 'Europe/Prague')::time;
  v_active_count int;
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
  elsif v_caller.status = 'approved' and v_caller.role = 'player'
        and same_group(v_uid, p_player_id) then
    v_via := 'group';
  elsif v_caller.status = 'approved' and v_caller.role = 'player'
        and p_player_id <> v_uid and is_on_duty() then
    v_via := 'duty';
  else
    raise exception 'not_allowed';
  end if;

  if not exists (
    select 1 from profiles
    where id = p_player_id and status = 'approved' and role <> 'kiosk'
      and tenant_id = v_caller.tenant_id
  ) then
    raise exception 'player_not_approved';
  end if;

  select * into v_settings from schedule_settings
  where tenant_id = v_caller.tenant_id;
  select * into v_block from time_blocks
  where id = p_block_id and tenant_id = v_caller.tenant_id;
  if not found then
    raise exception 'unknown_block';
  end if;
  if p_lane < 1 or p_lane > v_settings.lane_count then
    raise exception 'invalid_lane';
  end if;

  v_status := block_day_status(v_caller.tenant_id, p_date, p_block_id);
  if v_status is distinct from 'open' then
    raise exception '%', coalesce(v_status, 'unknown_block');
  end if;

  if v_caller.role <> 'admin' then
    if p_date < v_today then
      raise exception 'date_past';
    end if;
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
      -- "Máš už…" would be a lie about a member's cap.
      raise exception '%',
        case when v_via = 'group' then 'member_at_limit'
             when v_via = 'duty' then 'player_at_limit'
             else 'limit_reached' end;
    end if;
  end if;

  if exists (
    select 1 from priority_slots s
    join priority_slot_types t on t.id = s.type_id
    where s.date = p_date
      and s.tenant_id = v_caller.tenant_id
      and not s.is_away
      and (t.lanes is null or p_lane = any (t.lanes))
      and s.starts_at < v_block.ends_at
      and s.ends_at > v_block.starts_at
  ) then
    raise exception 'blocked_by_priority';
  end if;

  if exists (
    select 1 from rental_occurrences(v_caller.tenant_id, p_date) o
    where p_lane = any (o.lanes)
      and o.starts_at < v_block.ends_at and o.ends_at > v_block.starts_at
  ) then
    raise exception 'blocked_by_rental';
  end if;

  begin
    insert into reservations
      (tenant_id, player_id, date, block_id, lane, created_via, created_by)
    values
      (v_caller.tenant_id, p_player_id, p_date, p_block_id, p_lane, v_via, v_uid)
    returning * into v_res;
  exception when unique_violation then
    raise exception 'slot_taken';
  end;

  return v_res;
end;
$$;


ALTER FUNCTION "public"."create_reservation"("p_player_id" "uuid", "p_date" "date", "p_block_id" "uuid", "p_lane" smallint) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "display_name" "text" NOT NULL,
    "email" "text" DEFAULT ''::"text" NOT NULL,
    "role" "text" DEFAULT 'player'::"text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "fcm_token" "text",
    "approved_by" "uuid",
    "approved_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nick" "text" DEFAULT ''::"text" NOT NULL,
    "club_id" "uuid",
    "tenant_id" "uuid" NOT NULL,
    "superadmin" boolean DEFAULT false NOT NULL,
    "home_tenant_id" "uuid",
    "placeholder" boolean DEFAULT false NOT NULL,
    "own_color" integer DEFAULT '-1'::integer NOT NULL,
    "followed_teams" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "default_view" "text" DEFAULT 'calendar'::"text" NOT NULL,
    "notify_before_minutes" integer[] DEFAULT '{}'::integer[] NOT NULL,
    "phone" "text",
    "show_email" boolean DEFAULT true NOT NULL,
    "show_phone" boolean DEFAULT true NOT NULL,
    "regnum" "text",
    "regnum_checked_at" timestamp with time zone,
    CONSTRAINT "profiles_default_view_check" CHECK (("default_view" = ANY (ARRAY['calendar'::"text", 'trainings'::"text", 'clubhouse'::"text"]))),
    CONSTRAINT "profiles_followed_teams_check" CHECK ((COALESCE("array_length"("followed_teams", 1), 0) <= 20)),
    CONSTRAINT "profiles_nick_check" CHECK (("char_length"("nick") <= 14)),
    CONSTRAINT "profiles_notify_before_minutes_check" CHECK (((COALESCE("array_length"("notify_before_minutes", 1), 0) <= 5) AND (0 <= ALL ("notify_before_minutes")) AND (40320 >= ALL ("notify_before_minutes")))),
    CONSTRAINT "profiles_own_color_check" CHECK (((("own_color" >= '-1'::integer) AND ("own_color" <= 8)) OR (("own_color" >= 16777216) AND ("own_color" <= 33554431)))),
    CONSTRAINT "profiles_phone_check" CHECK ((("phone" IS NULL) OR ("phone" ~ '^\+[1-9][0-9]{7,14}$'::"text"))),
    CONSTRAINT "profiles_placeholder_check" CHECK (((NOT "placeholder") OR (("role" = 'player'::"text") AND ("status" = 'approved'::"text") AND (NOT "superadmin")))),
    CONSTRAINT "profiles_regnum_check" CHECK ((("regnum" IS NULL) OR ("regnum" ~ '^[0-9]{1,8}$'::"text"))),
    CONSTRAINT "profiles_role_check" CHECK (("role" = ANY (ARRAY['player'::"text", 'admin'::"text", 'kiosk'::"text"]))),
    CONSTRAINT "profiles_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text"])))
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


COMMENT ON COLUMN "public"."profiles"."placeholder" IS 'Hand-made profile without an auth user (hráč bez účtu): approved player, bookable, never signs in; merge_placeholder_player folds it into a real account.';



COMMENT ON COLUMN "public"."profiles"."own_color" IS 'The player''s own reservations in their own view (0024): -1 = the club colour, 0x1000000|rgb a hand-picked or Google-palette colour. Palette indices 0-11 are legacy — the 1.2.6 app still writes them and clubTint still renders them, but the current app writes only -1 or a packed RGB (0042).';



COMMENT ON COLUMN "public"."profiles"."followed_teams" IS 'Teams whose matches the player sees in Moje tréninky (names as in priority_slots.home_team/away_team). Display only; the calendar sync has its own list on google_calendar_links.';



COMMENT ON COLUMN "public"."profiles"."default_view" IS 'View the app opens at launch: calendar | trainings | clubhouse.';



COMMENT ON COLUMN "public"."profiles"."notify_before_minutes" IS 'Minutes before a training or a match to send the player a reminder (0040) — up to five, each 0 to 40320 (four weeks), the same bounds google_calendar_links.reminder_minutes uses (deliberately a different name: that one tells GOOGLE when to ring, this one tells us). Empty = no reminders. The channel is the app''s usual one — push where there is a device, e-mail otherwise.';



COMMENT ON COLUMN "public"."profiles"."phone" IS 'The player''s phone in international form (E.164, +<digits>, profiles_phone_check); null = none. The app normalises what the player types (lib/domain/phone.dart).';



COMMENT ON COLUMN "public"."profiles"."show_email" IS 'Whether contacts() hands this player''s e-mail to the other players of the alley (0048). On by default, for existing players too.';



COMMENT ON COLUMN "public"."profiles"."show_phone" IS 'Whether contacts() hands this player''s phone to the other players of the alley (0048). On by default, for existing players too.';



COMMENT ON COLUMN "public"."profiles"."regnum" IS 'Registration number from the ČKA register (evidence.kuzelky.cz), looked up by name and club by the regnum-lookup function (0057); null until found. Not updatable by the app.';



COMMENT ON COLUMN "public"."profiles"."regnum_checked_at" IS 'When regnum-lookup last looked for this profile''s registration number without settling it (0059); asked again after a week. Not updatable by the app.';



CREATE OR REPLACE FUNCTION "public"."create_tenant_and_register"("p_tenant_name" "text", "p_display_name" "text", "p_nick" "text" DEFAULT ''::"text", "p_phone" "text" DEFAULT NULL::"text") RETURNS "public"."profiles"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid uuid := auth.uid();
  v_profile profiles;
  v_tenant_id uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  -- An existing profile means the caller already belongs to an alley; bail
  -- out before creating a tenant nobody would live in.
  select * into v_profile from profiles where id = v_uid;
  if found then
    return v_profile;
  end if;

  if trim(p_tenant_name) = '' then
    raise exception 'empty_tenant_name';
  end if;

  begin
    insert into tenants (name, founder_email)
    values (trim(p_tenant_name), nullif(lower(coalesce(auth.email(), '')), ''))
    returning id into v_tenant_id;
  exception when unique_violation then
    raise exception 'tenant_exists';
  end;

  return register_profile(p_display_name, v_tenant_id, null, p_nick, p_phone);
end;
$$;


ALTER FUNCTION "public"."create_tenant_and_register"("p_tenant_name" "text", "p_display_name" "text", "p_nick" "text", "p_phone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_club"("p_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  delete from clubs
  where id = p_id and tenant_id = current_tenant_id();
end; $$;


ALTER FUNCTION "public"."delete_club"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_day_override"("p_date" "date") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform duty_edit_gate(p_date);
  delete from day_overrides
   where tenant_id = current_tenant_id() and date = p_date;
end;
$$;


ALTER FUNCTION "public"."delete_day_override"("p_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_placeholder_player"("p_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if not exists (
    select 1 from profiles
    where id = p_id and tenant_id = current_tenant_id() and placeholder
  ) then
    raise exception 'unknown_player';
  end if;
  if exists (select 1 from reservations where player_id = p_id)
     or exists (select 1 from duty_assignments where user_id = p_id) then
    raise exception 'player_has_history';
  end if;
  delete from profiles where id = p_id;
end;
$$;


ALTER FUNCTION "public"."delete_placeholder_player"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."due_duty_reminders"() RETURNS TABLE("user_id" "uuid", "email" "text", "fcm_token" "text", "period_id" "uuid", "starts_on" "date", "ends_on" "date", "days" smallint, "co_assignees" "text"[])
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select p.id, p.email, p.fcm_token, d.id, d.starts_on, d.ends_on,
         s.duty_reminder_days,
         array(select o.display_name
                 from duty_assignments oa
                 join profiles o on o.id = oa.user_id
                where oa.period_id = d.id and oa.user_id <> p.id
                order by o.display_name)
    from duty_periods d
    join schedule_settings s on s.tenant_id = d.tenant_id
    join duty_assignments a on a.period_id = d.id
    join profiles p on p.id = a.user_id
   where s.duty_reminder_enabled
     and p.status = 'approved' and not p.placeholder and p.role <> 'kiosk'
     and d.starts_on > (now() at time zone 'Europe/Prague')::date
     and ((d.starts_on - s.duty_reminder_days) + time '18:00')
           at time zone 'Europe/Prague' <= now()
     and not exists (
       select 1 from reminders_sent r
        where r.user_id = p.id
          and r.event_key = 'd:' || d.id
          and r.offset_minutes <= s.duty_reminder_days * 1440
          and (r.starts_at is null
               or r.starts_at = d.starts_on::timestamp at time zone 'Europe/Prague'))
   order by d.starts_on, p.id;
$$;


ALTER FUNCTION "public"."due_duty_reminders"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."due_reminders"() RETURNS TABLE("user_id" "uuid", "email" "text", "fcm_token" "text", "event_key" "text", "offset_minutes" integer, "kind" "text", "starts_at" timestamp with time zone, "ends_at" time without time zone, "lane" smallint, "alley_name" "text", "home_team" "text", "away_team" "text", "is_away" boolean)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
      -- Sent at this lead time or a closer one, for this start (or, with no
      -- known start, for any): the event was announced.
      and not exists (
        select 1 from reminders_sent s
        where s.user_id = e.user_id
          and s.event_key = e.event_key
          and s.offset_minutes <= o.offset_minutes
          and (s.starts_at is null or s.starts_at = e.starts_ts)
      )
    order by e.starts_ts;
$$;


ALTER FUNCTION "public"."due_reminders"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."duty_edit_days_gate"() RETURNS "void"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if is_admin() then
    return;
  end if;
  if not exists (select 1 from duty_assignments a
      join duty_periods d on d.id = a.period_id
      join profiles me on me.id = auth.uid()
     where a.user_id = me.id and d.tenant_id = me.tenant_id
       and me.status = 'approved' and me.role = 'player' and not me.placeholder
       and d.ends_on >= (now() at time zone 'Europe/Prague')::date) then
    raise exception 'not_allowed';
  end if;
end;
$$;


ALTER FUNCTION "public"."duty_edit_days_gate"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."duty_edit_gate"("p_date" "date") RETURNS "void"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
begin
  if p_date is null then
    raise exception 'date_past';
  end if;
  if is_admin() then
    return;
  end if;
  if not exists (select 1 from duty_assignments a
      join duty_periods d on d.id = a.period_id
      join profiles me on me.id = auth.uid()
     where a.user_id = me.id and d.tenant_id = me.tenant_id
       and me.status = 'approved' and me.role = 'player' and not me.placeholder
       and p_date between d.starts_on and d.ends_on) then
    raise exception 'not_allowed';
  end if;
  if p_date < v_today then
    raise exception 'date_past';
  end if;
end;
$$;


ALTER FUNCTION "public"."duty_edit_gate"("p_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."duty_gate"("p_date" "date") RETURNS "void"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if is_admin() then
    return;
  end if;
  if not is_on_duty() then
    raise exception 'not_allowed';
  end if;
  if p_date < (now() at time zone 'Europe/Prague')::date then
    raise exception 'date_past';
  end if;
end;
$$;


ALTER FUNCTION "public"."duty_gate"("p_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."duty_generate"("p_from" "date", "p_days" smallint, "p_until" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_tenant constant uuid := current_tenant_id();
  v_start date := p_from;
  v_end date;
  v_created integer := 0;
  v_skipped integer := 0;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if p_days is null or p_days < 1 or p_days > 31 then
    raise exception 'invalid_days';
  end if;
  if p_from is null or p_until is null or p_until < p_from
     or p_until - p_from + 1 > 400 then
    raise exception 'invalid_range';
  end if;

  while v_start <= p_until loop
    v_end := least(v_start + p_days - 1, p_until);
    if exists (select 1 from duty_periods
                where tenant_id = v_tenant
                  and daterange(starts_on, ends_on, '[]')
                      && daterange(v_start, v_end, '[]')) then
      v_skipped := v_skipped + 1;
    else
      -- Another admin's period may land between the check and the insert.
      begin
        insert into duty_periods (tenant_id, starts_on, ends_on, created_by)
          values (v_tenant, v_start, v_end, auth.uid());
        v_created := v_created + 1;
      exception when exclusion_violation then
        v_skipped := v_skipped + 1;
      end;
    end if;
    v_start := v_start + p_days;
  end loop;

  return jsonb_build_object('created', v_created, 'skipped', v_skipped);
end;
$$;


ALTER FUNCTION "public"."duty_generate"("p_from" "date", "p_days" smallint, "p_until" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."duty_period_delete"("p_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  delete from duty_periods where id = p_id and tenant_id = current_tenant_id();
  if not found then
    raise exception 'unknown_period';
  end if;
end;
$$;


ALTER FUNCTION "public"."duty_period_delete"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."duty_period_save"("p_id" "uuid", "p_starts_on" "date", "p_ends_on" "date", "p_note" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_tenant constant uuid := current_tenant_id();
  v_note constant text := trim(coalesce(p_note, ''));
  v_id uuid;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if p_starts_on is null or p_ends_on is null or p_ends_on < p_starts_on then
    raise exception 'invalid_range';
  end if;
  if p_ends_on - p_starts_on >= 62 then
    raise exception 'duty_too_long';
  end if;

  begin
    if p_id is null then
      insert into duty_periods (tenant_id, starts_on, ends_on, note, created_by)
        values (v_tenant, p_starts_on, p_ends_on, v_note, auth.uid())
        returning id into v_id;
    else
      update duty_periods
         set starts_on = p_starts_on, ends_on = p_ends_on, note = v_note
       where id = p_id and tenant_id = v_tenant
       returning id into v_id;
      if v_id is null then
        raise exception 'unknown_period';
      end if;
    end if;
  exception when exclusion_violation then
    raise exception 'duty_overlap';
  end;
  return v_id;
end;
$$;


ALTER FUNCTION "public"."duty_period_save"("p_id" "uuid", "p_starts_on" "date", "p_ends_on" "date", "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."duty_periods_delete_unassigned"("p_from" "date") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_count integer;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if p_from is null then
    raise exception 'invalid_range';
  end if;
  delete from duty_periods d
   where d.tenant_id = current_tenant_id()
     and d.starts_on >= p_from
     and not exists (select 1 from duty_assignments a where a.period_id = d.id);
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;


ALTER FUNCTION "public"."duty_periods_delete_unassigned"("p_from" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."duty_season_delete"("p_started_on" "date") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_tenant constant uuid := current_tenant_id();
  v_newest date;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  perform pg_advisory_xact_lock(hashtext('duty_season'), hashtext(v_tenant::text));
  select max(started_on) into v_newest from duty_seasons where tenant_id = v_tenant;
  if v_newest is null or p_started_on is distinct from v_newest then
    raise exception 'not_newest';
  end if;
  delete from duty_seasons where tenant_id = v_tenant and started_on = v_newest;
end;
$$;


ALTER FUNCTION "public"."duty_season_delete"("p_started_on" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."duty_season_start"("p_started_on" "date", "p_name" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_tenant constant uuid := current_tenant_id();
  v_name constant text := trim(coalesce(p_name, ''));
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if v_name = '' then
    raise exception 'empty_name';
  end if;
  -- One season change at a time per alley, so "after the newest" holds.
  perform pg_advisory_xact_lock(hashtext('duty_season'), hashtext(v_tenant::text));
  if exists (select 1 from duty_seasons
              where tenant_id = v_tenant and started_on >= p_started_on) then
    raise exception 'season_order';
  end if;
  insert into duty_seasons (tenant_id, started_on, name, created_by)
    values (v_tenant, p_started_on, v_name, auth.uid());
end;
$$;


ALTER FUNCTION "public"."duty_season_start"("p_started_on" "date", "p_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."duty_set_assignees"("p_period" "uuid", "p_users" "uuid"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_tenant constant uuid := current_tenant_id();
  v_users constant uuid[] :=
    array(select distinct u from unnest(coalesce(p_users, '{}')) u);
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  -- Two admins saving the same period end with one of their sets, not a mix.
  perform 1 from duty_periods
   where id = p_period and tenant_id = v_tenant
     for update;
  if not found then
    raise exception 'unknown_period';
  end if;
  if exists (
    select 1 from unnest(v_users) u
     where u is null or not exists (
       select 1 from profiles p
        where p.id = u and p.tenant_id = v_tenant
          and p.status = 'approved' and p.role <> 'kiosk'
          and not (p.superadmin and p.home_tenant_id is not null
                   and p.tenant_id <> p.home_tenant_id))
  ) then
    raise exception 'unknown_player';
  end if;

  delete from duty_assignments
   where period_id = p_period and user_id <> all (v_users);
  insert into duty_assignments (period_id, user_id, tenant_id, assigned_by)
  select p_period, u, v_tenant, auth.uid() from unnest(v_users) u
  on conflict (period_id, user_id) do nothing;
end;
$$;


ALTER FUNCTION "public"."duty_set_assignees"("p_period" "uuid", "p_users" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enqueue_calendar_sync"("p_user" "uuid", "p_reservation" "uuid") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select enqueue_notification('calendar_sync',
    'calendar:' || p_user || ':' || p_reservation,
    jsonb_build_object('user_id', p_user, 'reservation_id', p_reservation))
  where exists (
    select 1 from google_calendar_links
    where user_id = p_user and status = 'linked');
$$;


ALTER FUNCTION "public"."enqueue_calendar_sync"("p_user" "uuid", "p_reservation" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enqueue_federation_jobs"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."enqueue_federation_jobs"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enqueue_federation_match"("p_tenant" "uuid", "p_site_match_id" integer, "p_slug" "text", "p_run_at" timestamp with time zone) RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."enqueue_federation_match"("p_tenant" "uuid", "p_site_match_id" integer, "p_slug" "text", "p_run_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enqueue_federation_venue"("p_tenant" "uuid", "p_slug" "text", "p_delay" interval DEFAULT '00:00:00'::interval) RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select enqueue_notification('federation_venue',
    'federation_venue:' || p_tenant || ':' || p_slug,
    jsonb_build_object('tenant_id', p_tenant, 'slug', p_slug), p_delay);
$$;


ALTER FUNCTION "public"."enqueue_federation_venue"("p_tenant" "uuid", "p_slug" "text", "p_delay" interval) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enqueue_match_calendar_sync"("p_user" "uuid", "p_match" "uuid") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select enqueue_notification('calendar_sync',
    'calendar:' || p_user || ':match:' || p_match,
    jsonb_build_object('user_id', p_user, 'match_id', p_match))
  where exists (
    select 1 from google_calendar_links
    where user_id = p_user and status = 'linked');
$$;


ALTER FUNCTION "public"."enqueue_match_calendar_sync"("p_user" "uuid", "p_match" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enqueue_notification"("p_kind" "text", "p_dedupe_key" "text", "p_payload" "jsonb", "p_delay" interval DEFAULT '00:03:00'::interval) RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  insert into notification_jobs (kind, dedupe_key, payload, run_at)
  values (p_kind, p_dedupe_key, p_payload, now() + p_delay)
  on conflict (dedupe_key)
    do update set run_at = excluded.run_at, payload = excluded.payload;
$$;


ALTER FUNCTION "public"."enqueue_notification"("p_kind" "text", "p_dedupe_key" "text", "p_payload" "jsonb", "p_delay" interval) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fcm_token_claim"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  -- Setting it to null does not fire this trigger again (see WHEN below).
  update profiles set fcm_token = null
  where fcm_token = new.fcm_token and id <> new.id;
  return null;
end;
$$;


ALTER FUNCTION "public"."fcm_token_claim"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."federation_description"("p_competition" "text", "p_round" integer, "p_is_away" boolean, "p_venue" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select concat_ws(' · ', nullif(p_competition, ''), p_round || '. kolo',
    case when p_is_away and coalesce(p_venue, '') <> '' then p_venue end)
$$;


ALTER FUNCTION "public"."federation_description"("p_competition" "text", "p_round" integer, "p_is_away" boolean, "p_venue" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."federation_last_error"("p_tenant" "uuid", "p_report" "jsonb") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(e.value->>'error',
                  'Zápasy ostatních družstev: ' || (e.value->>'league_error'))
    from jsonb_each(federation_live_report(p_tenant, p_report)) e
   where e.value ? 'error' or e.value ? 'league_error'
   order by (e.value->>'at')::timestamptz desc nulls last, e.key
   limit 1
$$;


ALTER FUNCTION "public"."federation_last_error"("p_tenant" "uuid", "p_report" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."federation_live_report"("p_tenant" "uuid", "p_report" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb)
    from jsonb_each(coalesce(p_report, '{}'::jsonb)) e
   cross join lateral (select split_part(e.key, ':', 1) as kind,
                              substr(e.key, strpos(e.key, ':') + 1) as id) k
   where case k.kind
     when 'competition' then exists (
       select 1 from teams t
        where t.tenant_id = p_tenant and t.active and t.competition_slug = k.id)
     when 'venue' then exists (
       select 1 from federation_sync s
        where s.tenant_id = p_tenant and s.venue_slug = k.id)
       or exists (
       select 1 from priority_slots p
        where p.tenant_id = p_tenant and p.venue_slug = k.id)
     when 'match' then exists (
       select 1 from priority_slots p
        where p.tenant_id = p_tenant and p.import_key = 'cka:' || k.id
          and not federation_match_switched_off(p_tenant, p.home_team_slug, p.away_team_slug)
          and exists (select 1 from teams t
                       where t.tenant_id = p_tenant and t.active and t.competition_slug <> ''
                         and p.site_slug like t.competition_slug || '-kolo-%'))
     else true
   end
$$;


ALTER FUNCTION "public"."federation_live_report"("p_tenant" "uuid", "p_report" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."federation_match_switched_off"("p_tenant" "uuid", "p_home_slug" "text", "p_away_slug" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (select 1 from teams t
                  where t.tenant_id = p_tenant and t.site_slug in (p_home_slug, p_away_slug))
     and not exists (select 1 from teams t
                      where t.tenant_id = p_tenant and t.active
                        and t.site_slug in (p_home_slug, p_away_slug))
$$;


ALTER FUNCTION "public"."federation_match_switched_off"("p_tenant" "uuid", "p_home_slug" "text", "p_away_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."federation_refresh_error"("p_tenant" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_report jsonb;
  v_error text;
begin
  select last_report into v_report from federation_sync
   where tenant_id = p_tenant for update;
  if not found then
    return;
  end if;
  v_report := federation_live_report(p_tenant, v_report);
  v_error := federation_last_error(p_tenant, v_report);
  update federation_sync set last_report = v_report, last_error = v_error
   where tenant_id = p_tenant
     and (last_report, last_error) is distinct from (v_report, v_error);
end;
$$;


ALTER FUNCTION "public"."federation_refresh_error"("p_tenant" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."federation_sync_progress"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_tenant constant uuid := current_tenant_id();
  v jsonb;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  select jsonb_build_object(
           'discover', count(*) filter (where kind = 'federation_discover'),
           'competitions', count(*) filter (where kind = 'federation_competition'),
           'matches', count(*) filter (where kind = 'federation_match'),
           'venues', count(*) filter (where kind = 'federation_venue'))
    into v
    from notification_jobs
   where kind in ('federation_discover', 'federation_competition',
                  'federation_match', 'federation_venue')
     and split_part(dedupe_key, ':', 2) = v_tenant::text
     and (run_at <= now()
          or (attempts > 0 and run_at <= now() + interval '10 minutes'));
  return v;
end;
$$;


ALTER FUNCTION "public"."federation_sync_progress"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."group_accept"("p_group" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  update player_group_members set status = 'member'
   where group_id = p_group and user_id = auth.uid() and status = 'invited';
  if not found then
    raise exception 'unknown_invite';
  end if;
exception when unique_violation then
  raise exception 'already_in_group';
end;
$$;


ALTER FUNCTION "public"."group_accept"("p_group" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."group_cancel_invite"("p_group" "uuid", "p_user" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if my_group_id() is distinct from p_group then
    raise exception 'not_allowed';
  end if;
  delete from player_group_members
   where group_id = p_group and user_id = p_user and status = 'invited';
  if not found then
    raise exception 'unknown_invite';
  end if;
end;
$$;


ALTER FUNCTION "public"."group_cancel_invite"("p_group" "uuid", "p_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."group_decline"("p_group" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  delete from player_group_members
   where group_id = p_group and user_id = auth.uid() and status = 'invited';
  if not found then
    raise exception 'unknown_invite';
  end if;
end;
$$;


ALTER FUNCTION "public"."group_decline"("p_group" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."group_invite"("p_user" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid uuid := auth.uid();
  v_caller profiles;
  v_group uuid;
  v_status text;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  select * into v_caller from profiles where id = v_uid;
  if not found or v_caller.status <> 'approved' or v_caller.role = 'kiosk' then
    raise exception 'not_allowed';
  end if;
  if p_user = v_uid or not exists (
    select 1 from profiles
     where id = p_user and tenant_id = v_caller.tenant_id
       and status = 'approved' and role <> 'kiosk' and not placeholder
  ) then
    raise exception 'unknown_player';
  end if;

  select group_id into v_group from player_group_members
   where user_id = v_uid and status = 'member';
  if v_group is null then
    insert into player_groups (tenant_id, created_by)
      values (v_caller.tenant_id, v_uid) returning id into v_group;
    insert into player_group_members (group_id, user_id, tenant_id, status)
      values (v_group, v_uid, v_caller.tenant_id, 'member');
  end if;

  select status into v_status from player_group_members
   where group_id = v_group and user_id = p_user;
  if v_status = 'member' then
    raise exception 'already_member';
  elsif v_status = 'invited' then
    raise exception 'already_invited';
  end if;
  insert into player_group_members (group_id, user_id, tenant_id, status, invited_by)
    values (v_group, p_user, v_caller.tenant_id, 'invited', v_uid);
end;
$$;


ALTER FUNCTION "public"."group_invite"("p_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."group_leave"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_group uuid := my_group_id();
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if v_group is not null then
    perform _group_drop_member(v_group, auth.uid());
  end if;
end;
$$;


ALTER FUNCTION "public"."group_leave"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."group_remove_member"("p_user" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_group uuid;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if not exists (select 1 from profiles
                 where id = p_user and tenant_id = current_tenant_id()) then
    raise exception 'not_allowed';
  end if;
  select group_id into v_group from player_group_members
   where user_id = p_user and status = 'member';
  if v_group is not null then
    perform _group_drop_member(v_group, p_user);
  end if;
end;
$$;


ALTER FUNCTION "public"."group_remove_member"("p_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and role = 'admin' and status = 'approved'
  );
$$;


ALTER FUNCTION "public"."is_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_approved"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from profiles where id = auth.uid() and status = 'approved'
  );
$$;


ALTER FUNCTION "public"."is_approved"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_approved_or_kiosk"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and (status = 'approved' or role = 'kiosk')
  );
$$;


ALTER FUNCTION "public"."is_approved_or_kiosk"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_kiosk"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from profiles where id = auth.uid() and role = 'kiosk'
  );
$$;


ALTER FUNCTION "public"."is_kiosk"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_on_duty"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (select 1 from duty_assignments a
    join duty_periods d on d.id = a.period_id
    join profiles me on me.id = auth.uid()
   where a.user_id = me.id and d.tenant_id = me.tenant_id
     and me.status = 'approved' and me.role = 'player' and not me.placeholder
     and (now() at time zone 'Europe/Prague')::date between d.starts_on and d.ends_on) $$;


ALTER FUNCTION "public"."is_on_duty"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_superadmin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(
    (select superadmin from profiles where id = auth.uid()), false);
$$;


ALTER FUNCTION "public"."is_superadmin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."kiosk_password_target"("p_user_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_id uuid;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  select id into v_id
  from profiles
  where id = p_user_id
    and tenant_id = current_tenant_id()
    and role = 'kiosk';
  if v_id is null then
    raise exception 'unknown_kiosk';
  end if;
  return v_id;
end;
$$;


ALTER FUNCTION "public"."kiosk_password_target"("p_user_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."kiosk_password_target"("p_user_id" "uuid") IS 'Kiosk účtu p_user_id smí správce téže kuželny nastavit nové heslo — vrací jeho id, jinak not_allowed/unknown_kiosk. Volá edge funkce kiosk-password jménem volajícího.';



CREATE OR REPLACE FUNCTION "public"."league_competition_is_ours"("p_tenant" "uuid", "p_competition_slug" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (select 1 from teams t
                  where t.tenant_id = p_tenant and t.active
                    and t.competition_slug = p_competition_slug
                    and t.competition_slug <> '');
$$;


ALTER FUNCTION "public"."league_competition_is_ours"("p_tenant" "uuid", "p_competition_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."league_drop_orphan_jobs"("p_tenant" "uuid" DEFAULT NULL::"uuid") RETURNS integer
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."league_drop_orphan_jobs"("p_tenant" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mark_reminder_sent"("p_user" "uuid", "p_event_key" "text", "p_offset" integer, "p_starts_at" timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into reminders_sent (user_id, event_key, offset_minutes, starts_at)
  values (p_user, p_event_key, p_offset, p_starts_at)
  on conflict (user_id, event_key, offset_minutes) do update
    set starts_at = excluded.starts_at, sent_at = now();
  delete from reminders_sent where sent_at < now() - interval '30 days';
end;
$$;


ALTER FUNCTION "public"."mark_reminder_sent"("p_user" "uuid", "p_event_key" "text", "p_offset" integer, "p_starts_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."match_calendar_followers"("p_tenant" "uuid", "p_home" "text", "p_away" "text") RETURNS SETOF "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select distinct l.user_id
    from google_calendar_links l
    join profiles p on p.id = l.user_id
    join calendar_teams t on t.user_id = l.user_id and t.team in (p_home, p_away)
    where p.tenant_id = p_tenant
      and l.status = 'linked';
$$;


ALTER FUNCTION "public"."match_calendar_followers"("p_tenant" "uuid", "p_home" "text", "p_away" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."match_exceptions_enqueue_calendar"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform enqueue_match_calendar_sync(
    coalesce(new.user_id, old.user_id),
    coalesce(new.match_id, old.match_id));
  return coalesce(new, old);
end;
$$;


ALTER FUNCTION "public"."match_exceptions_enqueue_calendar"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."merge_placeholder_player"("p_placeholder_id" "uuid", "p_target_id" "uuid", "p_display_name" "text", "p_nick" "text", "p_club_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_tenant uuid := current_tenant_id();
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  -- Lock both rows: a concurrent create_reservation for the placeholder
  -- waits here instead of slipping in between the repoint and the delete.
  perform 1 from profiles
  where id = p_placeholder_id and tenant_id = v_tenant and placeholder
  for update;
  if not found then
    raise exception 'invalid_merge';
  end if;
  perform 1 from profiles
  where id = p_target_id and tenant_id = v_tenant
    and not placeholder and role <> 'kiosk'
  for update;
  if not found then
    raise exception 'invalid_merge';
  end if;
  if trim(coalesce(p_display_name, '')) = '' then
    raise exception 'empty_display_name';
  end if;
  if char_length(trim(coalesce(p_nick, ''))) > 14 then
    raise exception 'nick_too_long';
  end if;
  if p_club_id is not null and not exists (
    select 1 from clubs where id = p_club_id and tenant_id = v_tenant
  ) then
    raise exception 'unknown_club';
  end if;

  -- History moves to the account. player_id is the only column that can
  -- reference a placeholder: created_by / approved_by are written from
  -- auth.uid(), which a placeholder never is (profiles_placeholder_check
  -- keeps it a plain player). Anything else pointing at the row makes the
  -- NO ACTION FKs abort the delete below.
  update reservations set player_id = p_target_id
  where player_id = p_placeholder_id;

  -- Duties too (0050), except where the account is on the same period
  -- already: that row is the one kept. What stays on the placeholder goes
  -- with it (the FK cascades).
  update duty_assignments a set user_id = p_target_id
  where a.user_id = p_placeholder_id
    and not exists (select 1 from duty_assignments b
                    where b.period_id = a.period_id and b.user_id = p_target_id);

  update profiles
  set display_name = trim(p_display_name),
      nick = trim(coalesce(p_nick, '')),
      club_id = p_club_id,
      status = 'approved',
      approved_by = coalesce(approved_by, auth.uid()),
      approved_at = coalesce(approved_at, now())
  where id = p_target_id;

  delete from profiles where id = p_placeholder_id;
end;
$$;


ALTER FUNCTION "public"."merge_placeholder_player"("p_placeholder_id" "uuid", "p_target_id" "uuid", "p_display_name" "text", "p_nick" "text", "p_club_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."message_delete"("p_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_approved() or is_kiosk() then
    raise exception 'not_allowed';
  end if;
  delete from messages
   where id = p_id and tenant_id = current_tenant_id()
     and (author_id = auth.uid() or is_admin());
  if not found then
    raise exception 'unknown_message';
  end if;
end;
$$;


ALTER FUNCTION "public"."message_delete"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."message_recipients_stamp_reacted"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if (new.reaction is not null or new.reply is not null)
     and (select kind from messages where id = new.message_id) = 'notice' then
    raise exception 'not_allowed';
  end if;
  if new.reaction is distinct from old.reaction or new.reply is distinct from old.reply then
    if new.reaction is null and new.reply is null then
      new.reacted_at := null;
    else
      new.reacted_at := now();
    end if;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."message_recipients_stamp_reacted"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."message_send"("p_kind" "text", "p_audience" "text", "p_on_date" "date", "p_block_id" "uuid", "p_title" "text", "p_body" "text", "p_expires_at" timestamp with time zone, "p_notify" boolean) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  v_tenant constant uuid := current_tenant_id();
  v_me constant uuid := auth.uid();
  -- Trimmed of any whitespace, not only spaces (trim() alone would take
  -- a body of newlines and tabs as written); what is stored and measured.
  v_title constant text :=
    nullif(regexp_replace(coalesce(p_title, ''), '^\s+|\s+$', '', 'g'), '');
  v_body constant text := regexp_replace(coalesce(p_body, ''), '^\s+|\s+$', '', 'g');
  v_id uuid;
  v_members uuid[];
  v_recipients uuid[];
  v_role text;
begin
  select role into v_role from profiles
    where id = v_me and tenant_id = v_tenant and status = 'approved'
      and not placeholder and role <> 'kiosk';
  if v_role is null then
    raise exception 'not_allowed';
  end if;

  if p_kind = 'notice' then
    if not is_admin() then
      raise exception 'not_allowed';
    end if;
    if p_audience is distinct from 'all' then
      raise exception 'invalid_audience';
    end if;
    if v_title is null then
      raise exception 'title_required';
    end if;
    -- A bare code, never the raw messages_title_check; char_length counts
    -- code points (👍🏽 is two), which is what the app has to count too.
    if char_length(v_title) > 80 then
      raise exception 'title_too_long';
    end if;
  elsif p_kind = 'message' then
    if p_audience in ('day', 'block') then
      if p_on_date is null then
        raise exception 'date_past';
      end if;
      perform duty_edit_gate(p_on_date);
      if p_audience = 'block' then
        -- An active block of this alley, or a day-only block that belongs
        -- to this date through day_overrides (add_special_block leaves
        -- those with active = false).
        if not exists (select 1 from time_blocks b
                        where b.id = p_block_id and b.tenant_id = v_tenant
                          and (b.active or exists (
                            select 1 from day_overrides o
                             where o.tenant_id = v_tenant and o.date = p_on_date
                               and b.id = any (o.block_ids)))) then
          raise exception 'unknown_block';
        end if;
      end if;
    elsif p_audience in ('admins', 'duty') then
      -- Any approved home account, admins included (v_role is already
      -- checked above). on_date/block_id are optional context here —
      -- the block, if given, has to be this alley's.
      if p_block_id is not null and not exists (
          select 1 from time_blocks
           where id = p_block_id and tenant_id = v_tenant) then
        raise exception 'unknown_block';
      end if;
    else
      raise exception 'invalid_audience';
    end if;
  else
    raise exception 'invalid_kind';
  end if;

  if v_body = '' then
    raise exception 'body_required';
  end if;
  if char_length(v_body) > (case when p_kind = 'notice' then 2000 else 500 end) then
    raise exception 'body_too_long';
  end if;

  -- The `players` view's rule, minus the author: whoever may receive.
  v_members := array(select id from profiles
                      where tenant_id = v_tenant and status = 'approved' and role <> 'kiosk'
                        and not placeholder and id <> v_me
                        and not (superadmin and home_tenant_id is not null
                                 and tenant_id <> home_tenant_id));

  v_recipients := case p_audience
    when 'all' then v_members
    when 'day' then
      array(select distinct player_id from reservations
             where tenant_id = v_tenant and date = p_on_date and cancelled_at is null
               and player_id = any (v_members))
    when 'block' then
      array(select distinct player_id from reservations
             where tenant_id = v_tenant and date = p_on_date and block_id = p_block_id
               and cancelled_at is null and player_id = any (v_members))
    when 'admins' then
      array(select id from profiles
             where id = any (v_members) and role = 'admin')
    when 'duty' then
      array(select a.user_id from duty_assignments a
             join duty_periods d on d.id = a.period_id
             where d.tenant_id = v_tenant
               and (now() at time zone 'Europe/Prague')::date
                   between d.starts_on and d.ends_on
               and a.user_id = any (v_members))
  end;

  -- A notice goes up even with nobody else in the alley yet (a new alley,
  -- the spare-key notice before the players join): the board is not
  -- recipient-based, its rows are only for the push and „Kdo si to
  -- zobrazil“. A message with nobody to go to is refused.
  if p_kind = 'message' and array_length(v_recipients, 1) is null then
    if p_audience = 'duty' then
      raise exception 'nobody_on_duty';
    end if;
    raise exception 'no_recipients';
  end if;

  -- A notice keeps no context; a day message no block; only a notice has a
  -- title, an expiry and a choice about pinging (a message always pings).
  insert into messages (tenant_id, author_id, author_role, kind, audience, on_date, block_id,
                        title, body, expires_at, notify)
    values (v_tenant, v_me, v_role, p_kind, p_audience,
            case when p_kind = 'notice' then null else p_on_date end,
            case when p_kind = 'notice' or p_audience = 'day' then null
                 else p_block_id end,
            case when p_kind = 'notice' then v_title end,
            v_body, case when p_kind = 'notice' then p_expires_at end,
            case when p_kind = 'notice' then coalesce(p_notify, true) else true end)
    returning id into v_id;

  insert into message_recipients (message_id, user_id, tenant_id)
    select v_id, u, v_tenant from unnest(v_recipients) u;

  return v_id;
end;
$_$;


ALTER FUNCTION "public"."message_send"("p_kind" "text", "p_audience" "text", "p_on_date" "date", "p_block_id" "uuid", "p_title" "text", "p_body" "text", "p_expires_at" timestamp with time zone, "p_notify" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."message_set_kiosk"("p_id" "uuid", "p_show" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  update messages set show_on_kiosk = coalesce(p_show, true)
   where id = p_id and tenant_id = current_tenant_id() and kind = 'notice';
  if not found then
    raise exception 'unknown_message';
  end if;
end;
$$;


ALTER FUNCTION "public"."message_set_kiosk"("p_id" "uuid", "p_show" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."message_set_visible_from"("p_id" "uuid", "p_from" timestamp with time zone, "p_notify" boolean DEFAULT NULL::boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_from constant timestamptz := case when p_from > now() then p_from end;
  v_notify boolean;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  update messages
     set visible_from = v_from, notify = coalesce(p_notify, notify)
   where id = p_id and tenant_id = current_tenant_id() and kind = 'notice'
  returning notify into v_notify;
  if not found then
    raise exception 'unknown_message';
  end if;
  delete from notification_jobs
   where kind = 'notice_visible' and dedupe_key = 'notice_visible:' || p_id;
  if v_from is not null and v_notify then
    insert into notification_jobs (kind, dedupe_key, payload, run_at)
    values ('notice_visible', 'notice_visible:' || p_id,
            jsonb_build_object('message_id', p_id,
                               'tenant_id', current_tenant_id()),
            v_from);
  end if;
end;
$$;


ALTER FUNCTION "public"."message_set_visible_from"("p_id" "uuid", "p_from" timestamp with time zone, "p_notify" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."message_update"("p_id" "uuid", "p_title" "text", "p_body" "text", "p_expires_at" timestamp with time zone) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  -- Trimmed of any whitespace, as in message_send.
  v_title constant text :=
    nullif(regexp_replace(coalesce(p_title, ''), '^\s+|\s+$', '', 'g'), '');
  v_body constant text := regexp_replace(coalesce(p_body, ''), '^\s+|\s+$', '', 'g');
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if v_title is null then
    raise exception 'title_required';
  end if;
  if char_length(v_title) > 80 then
    raise exception 'title_too_long';
  end if;
  if v_body = '' then
    raise exception 'body_required';
  end if;
  if char_length(v_body) > 2000 then
    raise exception 'body_too_long';
  end if;
  update messages
     set title = v_title, body = v_body, expires_at = p_expires_at, updated_at = now()
   where id = p_id and tenant_id = current_tenant_id() and kind = 'notice';
  if not found then
    raise exception 'unknown_message';
  end if;
end;
$_$;


ALTER FUNCTION "public"."message_update"("p_id" "uuid", "p_title" "text", "p_body" "text", "p_expires_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."monthly_attendance"("p_year" integer, "p_month" integer) RETURNS TABLE("player_id" "uuid", "display_name" "text", "club" "text", "attended" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;

  return query
  select p.id, p.display_name, coalesce(c.name, ''), count(r.id)
  from profiles p
  left join clubs c on c.id = p.club_id
  join reservations r on r.player_id = p.id
  where p.tenant_id = current_tenant_id()
    and not (p.superadmin
             and p.home_tenant_id is not null
             and p.tenant_id <> p.home_tenant_id)
    and r.cancelled_at is null
    and extract(year from r.date)::int = p_year
    and extract(month from r.date)::int = p_month
    and r.date <= (now() at time zone 'Europe/Prague')::date
  group by p.id, p.display_name, coalesce(c.name, '')
  order by count(r.id) desc, p.display_name;
end;
$$;


ALTER FUNCTION "public"."monthly_attendance"("p_year" integer, "p_month" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."move_day_reservations"("p_date" "date", "p_from_block" "uuid", "p_to_block" "uuid", "p_notify" boolean DEFAULT true, "p_message" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform duty_edit_gate(p_date);

  if not exists (
    select 1 from time_blocks
    where id = p_from_block and tenant_id = current_tenant_id()
  ) or not exists (
    select 1 from time_blocks
    where id = p_to_block and tenant_id = current_tenant_id()
  ) then
    raise exception 'unknown_block';
  end if;

  if not is_admin()
     and p_date = (now() at time zone 'Europe/Prague')::date
     and exists (
       select 1 from time_blocks
       where id in (p_from_block, p_to_block)
         and starts_at <= (now() at time zone 'Europe/Prague')::time) then
    raise exception 'too_late';
  end if;

  update reservations
  set block_id = p_to_block,
      notify_player = coalesce(p_notify, true),
      notify_message = nullif(trim(coalesce(p_message, '')), '')
  where date = p_date
    and block_id = p_from_block
    and cancelled_at is null
    and tenant_id = current_tenant_id();
exception when unique_violation then
  raise exception 'slot_taken';
end;
$$;


ALTER FUNCTION "public"."move_day_reservations"("p_date" "date", "p_from_block" "uuid", "p_to_block" "uuid", "p_notify" boolean, "p_message" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."move_reservation"("p_reservation" "uuid", "p_to_block" "uuid", "p_lane" integer, "p_notify" boolean DEFAULT true, "p_message" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_on_duty constant boolean := is_on_duty();
  v_res reservations;
  v_block time_blocks;
  v_lanes int;
begin
  if not v_on_duty then
    perform duty_edit_days_gate();
  end if;

  select * into v_res from reservations
  where id = p_reservation and tenant_id = current_tenant_id();
  if not found or v_res.cancelled_at is not null then
    raise exception 'unknown_reservation';
  end if;
  if v_on_duty then
    perform duty_gate(v_res.date);
  else
    perform duty_edit_gate(v_res.date);
  end if;

  select * into v_block from time_blocks
  where id = p_to_block and tenant_id = current_tenant_id();
  if not found then
    raise exception 'unknown_block';
  end if;

  if not is_admin()
     and v_res.date = (now() at time zone 'Europe/Prague')::date
     and (v_block.starts_at <= (now() at time zone 'Europe/Prague')::time
          or (select starts_at from time_blocks where id = v_res.block_id)
             <= (now() at time zone 'Europe/Prague')::time) then
    raise exception 'too_late';
  end if;

  select lane_count into v_lanes from schedule_settings
  where tenant_id = current_tenant_id();
  if p_lane < 1 or p_lane > v_lanes then
    raise exception 'invalid_lane';
  end if;

  if exists (
    select 1 from priority_slots s
    join priority_slot_types t on t.id = s.type_id
    where s.date = v_res.date
      and s.tenant_id = current_tenant_id()
      and not s.is_away
      and (t.lanes is null or p_lane = any (t.lanes))
      and s.starts_at < v_block.ends_at
      and s.ends_at > v_block.starts_at
  ) then
    raise exception 'blocked_by_priority';
  end if;

  if exists (
    select 1 from rental_occurrences(current_tenant_id(), v_res.date) o
    where p_lane = any (o.lanes)
      and o.starts_at < v_block.ends_at and o.ends_at > v_block.starts_at
  ) then
    raise exception 'blocked_by_rental';
  end if;

  update reservations
  set block_id = p_to_block, lane = p_lane,
      notify_player = coalesce(p_notify, true),
      notify_message = nullif(trim(coalesce(p_message, '')), '')
  where id = p_reservation;
exception when unique_violation then
  raise exception 'slot_taken';
end;
$$;


ALTER FUNCTION "public"."move_reservation"("p_reservation" "uuid", "p_to_block" "uuid", "p_lane" integer, "p_notify" boolean, "p_message" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."my_future_matches"("p_user" "uuid") RETURNS TABLE("match_id" "uuid", "date" "date", "starts_at" time without time zone, "ends_at" time without time zone, "home_team" "text", "away_team" "text", "is_away" boolean, "description" "text", "alley_name" "text", "calendar" "text", "color_id" smallint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select s.id, s.date, s.starts_at, s.ends_at,
         s.home_team, s.away_team, s.is_away, s.description, t.name,
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


ALTER FUNCTION "public"."my_future_matches"("p_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."my_future_reservations"("p_user" "uuid") RETURNS TABLE("reservation_id" "uuid", "date" "date", "starts_at" time without time zone, "ends_at" time without time zone, "lane" smallint, "alley_name" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select r.id, r.date, b.starts_at, b.ends_at, r.lane, t.name
    from reservations r
    join time_blocks b on b.id = r.block_id
    join tenants t on t.id = r.tenant_id
    where r.player_id = p_user
      and r.cancelled_at is null
      and r.date >= (now() at time zone 'Europe/Prague')::date
    order by r.date, b.starts_at;
$$;


ALTER FUNCTION "public"."my_future_reservations"("p_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."my_group_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select group_id from player_group_members
   where user_id = auth.uid() and status = 'member'
$$;


ALTER FUNCTION "public"."my_group_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."my_public_overview"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  return (
    select jsonb_build_object('public_slug', t.public_slug,
                              'public_enabled', t.public_enabled,
                              'tenant_name', t.name)
      from tenants t where t.id = current_tenant_id());
end;
$$;


ALTER FUNCTION "public"."my_public_overview"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."my_upcoming_matches"("p_user" "uuid") RETURNS TABLE("match_id" "uuid", "date" "date", "starts_at" time without time zone, "ends_at" time without time zone, "home_team" "text", "away_team" "text", "is_away" boolean, "description" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select s.id, s.date, s.starts_at, s.ends_at,
         s.home_team, s.away_team, s.is_away, s.description
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


ALTER FUNCTION "public"."my_upcoming_matches"("p_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notifications_due"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (select 1 from notification_jobs where run_at <= now())
      or exists (select 1 from due_reminders())
      or exists (select 1 from due_duty_reminders());
$$;


ALTER FUNCTION "public"."notifications_due"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_webhook"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_url text;
  v_secret text;
begin
  select c.url, c.secret into v_url, v_secret from notify_webhook_config() c;
  if v_url is null or v_secret is null then
    raise warning 'notify_webhook: vault secrets notify_url / webhook_secret missing, notification skipped';
    return coalesce(new, old);
  end if;
  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-webhook-secret', v_secret
    ),
    body := jsonb_build_object(
      'type', tg_op,
      'table', tg_table_name,
      'schema', tg_table_schema,
      'record', case when tg_op = 'DELETE' then null else to_jsonb(new) end,
      'old_record', case when tg_op = 'INSERT' then null else to_jsonb(old) end
    )
  );
  return coalesce(new, old);
end;
$$;


ALTER FUNCTION "public"."notify_webhook"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_webhook_config"() RETURNS TABLE("url" "text", "secret" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select
    (select decrypted_secret from vault.decrypted_secrets
      where name = 'notify_url'),
    (select decrypted_secret from vault.decrypted_secrets
      where name = 'webhook_secret');
$$;


ALTER FUNCTION "public"."notify_webhook_config"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."priority_slots_enqueue_calendar"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."priority_slots_enqueue_calendar"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."priority_slots_mark_hand_edit"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.import_key is not null
     and current_setting('import.run', true) is distinct from 'on'
     and (old.date, old.starts_at, old.ends_at, old.home_team, old.away_team,
          old.prep_minutes, old.description, old.is_away)
         is distinct from
         (new.date, new.starts_at, new.ends_at, new.home_team, new.away_team,
          new.prep_minutes, new.description, new.is_away) then
    new.hand_edited := true;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."priority_slots_mark_hand_edit"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prune_messages"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_count integer;
begin
  delete from messages
   where kind = 'message'
     and coalesce(on_date, (created_at at time zone 'Europe/Prague')::date)
         < (now() at time zone 'Europe/Prague')::date - 90;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;


ALTER FUNCTION "public"."prune_messages"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prune_slot_watches"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_n integer;
begin
  delete from slot_watches
   where date < (now() at time zone 'Europe/Prague')::date;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;


ALTER FUNCTION "public"."prune_slot_watches"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."public_tenant_id"("p_slug" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_tenant uuid;
begin
  select id into v_tenant from tenants
   where public_slug = lower(trim(coalesce(p_slug, '')))
     and public_enabled
     and status = 'approved';
  if v_tenant is null then
    raise exception 'unknown_tenant';
  end if;
  return v_tenant;
end;
$$;


ALTER FUNCTION "public"."public_tenant_id"("p_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."public_week"("p_slug" "text", "p_monday" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_tenant constant uuid := public_tenant_id(p_slug);
  v_monday constant date :=
    date_trunc('week', coalesce(p_monday, current_date))::date;
  v_from constant date := v_monday - 1;
  v_to constant date := v_monday + 7;
begin
  return jsonb_build_object(
    'tenant_name', (select name from tenants where id = v_tenant),
    'settings', (select to_jsonb(s) - 'tenant_id'
                          - 'duty_reminder_enabled' - 'duty_reminder_days'
                          - 'kiosk_notices_mode' - 'kiosk_show_matches'
                          - 'kiosk_show_upcoming' - 'kiosk_live_mode'
                          - 'kiosk_drawer_open' - 'kiosk_drawer_width'
                          - 'kiosk_notices_share' - 'kiosk_zapis_percent'
                          - 'kiosk_weeks_back' - 'kiosk_weeks_ahead'
                          - 'kiosk_panel_enabled' - 'kiosk_past_days'
                          - 'kiosk_notices_rotation_seconds'
                          - 'kiosk_live_rotation_seconds'
                          - 'kiosk_idle_seconds'
                          - 'kiosk_live_layout' - 'kiosk_follow_board'
                   from schedule_settings s where s.tenant_id = v_tenant),
    'blocks', coalesce((
      select jsonb_agg(to_jsonb(b) - 'tenant_id')
        from time_blocks b where b.tenant_id = v_tenant), '[]'),
    'slot_types', coalesce((
      select jsonb_agg(to_jsonb(t) - 'tenant_id' - 'created_at')
        from priority_slot_types t where t.tenant_id = v_tenant), '[]'),
    'overrides', coalesce((
      select jsonb_agg(to_jsonb(o) - 'tenant_id' - 'created_by' - 'created_at')
        from day_overrides o
       where o.tenant_id = v_tenant and o.date between v_from and v_to), '[]'),
    'priority_slots', coalesce((
      select jsonb_agg(to_jsonb(p) - 'tenant_id' - 'created_by' - 'created_at')
        from priority_slots p
       where p.tenant_id = v_tenant and p.date between v_from and v_to), '[]'),
    -- Names and notes never leave: the board says "Obsazeno" instead.
    'rentals', coalesce((
      select jsonb_agg((to_jsonb(r) - 'tenant_id' - 'created_by' - 'created_at')
                       || jsonb_build_object('renter_name', '', 'note', ''))
        from rentals r
       where r.tenant_id = v_tenant
         and (r.date between v_from and v_to
              or (r.weekday is not null
                  and (r.valid_from is null or r.valid_from <= v_to)
                  and (r.valid_until is null or r.valid_until >= v_from)))),
      '[]'),
    -- Who holds a lane is exactly what the public board must not say: a
    -- live reservation is its cell and the player's club colour, nothing more.
    'occupied', coalesce((
      select jsonb_agg(jsonb_build_object(
               'block_id', x.block_id, 'date', x.date, 'lane', x.lane,
               'club_color', coalesce(c.color, -1))
             order by x.date, x.block_id, x.lane)
        from reservations x
        join profiles pr on pr.id = x.player_id
        left join clubs c on c.id = pr.club_id
       where x.tenant_id = v_tenant
         and x.cancelled_at is null
         and x.date between v_monday and v_monday + 6), '[]')
  );
end;
$$;


ALTER FUNCTION "public"."public_week"("p_slug" "text", "p_monday" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_federation_run"("p_tenant" "uuid", "p_key" "text", "p_report" "jsonb", "p_error" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_run constant boolean := p_key like 'competition:%';
  v_keep constant boolean := v_run or p_key = 'discover';
  v_report jsonb;
begin
  select last_report into v_report from federation_sync
   where tenant_id = p_tenant for update;
  if p_error is null and not v_keep and not coalesce(v_report ? p_key, false) then
    return;
  end if;
  if v_report is null then
    insert into federation_sync (tenant_id) values (p_tenant) on conflict do nothing;
    select last_report into v_report from federation_sync
     where tenant_id = p_tenant for update;
  end if;
  v_report := case
    when p_error is not null then v_report || jsonb_build_object(p_key,
      jsonb_build_object('error', p_error, 'at', now()))
    when v_keep then v_report || jsonb_build_object(p_key,
      coalesce(p_report, '{}'::jsonb) || jsonb_build_object('at', now()))
    else v_report - p_key end;
  v_report := federation_live_report(p_tenant, v_report);
  update federation_sync
     set last_run_at = case when v_run then now() else last_run_at end,
         last_success_at = case when v_run and p_error is null then now()
                                else last_success_at end,
         last_report = v_report,
         last_error = federation_last_error(p_tenant, v_report)
   where tenant_id = p_tenant;
end;
$$;


ALTER FUNCTION "public"."record_federation_run"("p_tenant" "uuid", "p_key" "text", "p_report" "jsonb", "p_error" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_match"("p_match_id" "uuid", "p_force" boolean DEFAULT false) RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_slot priority_slots;
  v_league league_matches;
  v_status text;
  v_fetched timestamptz;
  v_start timestamptz;
  v_job bigint;
  v_gap interval := case when p_force then interval '15 seconds' else interval '5 minutes' end;
  -- How long after its start a finished match may still be corrected on the
  -- site — and asked for again by the ⟳ button (0062).
  v_corrections interval := interval '14 days';
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
      -- Final: a missing detail is worth a fetch; a fetched one only when
      -- somebody taps ⟳ (a correction on the site) within v_corrections.
      if v_league.detail_status in ('finished', 'forfeit') and not (
           p_force
           and now() < (v_league.date + coalesce(v_league.starts_at, time '00:00'))
                         at time zone 'Europe/Prague' + v_corrections) then
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
            -- a request sorts before the backfill jobs (the runner takes the
            -- oldest run_at first): someone is waiting for this one
            'epoch'::timestamptz)
    on conflict (dedupe_key) do update
      set run_at = least(notification_jobs.run_at, excluded.run_at),
          payload = notification_jobs.payload || jsonb_build_object('requested_at', now())
      where coalesce((notification_jobs.payload->>'requested_at')::timestamptz, '-infinity')
            < now() - v_gap
    returning id into v_job;
    -- One dispatch for a burst (opening Výsledky pokes every refreshable
    -- match): each would start a whole notify run. The button (force) always
    -- dispatches.
    if v_job is not null and (p_force or not exists (
         select 1 from notification_jobs o
          where o.kind = 'federation_league_match' and o.id <> v_job
            and (o.payload->>'requested_at')::timestamptz > now() - interval '10 seconds')) then
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
  -- A finished match is never polled again, so a correction on the site
  -- (a result, a missing lane) reaches us only when somebody taps ⟳ — within
  -- v_corrections of the start (0062). Opening it alone asks nothing.
  if not ((v_status = 'in_progress' and now() < v_start + interval '12 hours')
          or (v_status = 'preparation'
              and now() between v_start - interval '1 hour' and v_start + interval '12 hours')
          or (v_status = 'scheduled'
              and now() between v_start - interval '1 hour' and v_start + interval '6 hours')
          or (p_force and v_status in ('finished', 'forfeit')
              and now() < v_start + v_corrections)) then
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


ALTER FUNCTION "public"."refresh_match"("p_match_id" "uuid", "p_force" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."register_profile"("p_display_name" "text", "p_tenant_id" "uuid", "p_club_id" "uuid" DEFAULT NULL::"uuid", "p_nick" "text" DEFAULT ''::"text", "p_phone" "text" DEFAULT NULL::"text") RETURNS "public"."profiles"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  v_uid uuid := auth.uid();
  v_profile profiles;
  v_tenant tenants;
  v_first boolean;
  v_phone constant text := nullif(trim(coalesce(p_phone, '')), '');
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select * into v_profile from profiles where id = v_uid;
  if found then
    return v_profile;
  end if;

  if trim(p_display_name) = '' then
    raise exception 'empty_display_name';
  end if;
  if char_length(trim(coalesce(p_nick, ''))) > 14 then
    raise exception 'nick_too_long';
  end if;
  if v_phone is not null and v_phone !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'invalid_phone';
  end if;

  select * into v_tenant from tenants where id = p_tenant_id;
  if not found then
    raise exception 'unknown_tenant';
  end if;

  if p_club_id is not null and not exists (
    select 1 from clubs where id = p_club_id and tenant_id = p_tenant_id
  ) then
    raise exception 'unknown_club';
  end if;

  -- Serialize concurrent registrations into the same tenant so exactly one
  -- founder can win the race.
  perform pg_advisory_xact_lock(
    hashtext('register_profile'), hashtext(p_tenant_id::text));

  select not exists (
    select 1 from profiles
    where tenant_id = p_tenant_id and status = 'approved'
      and not placeholder
  ) into v_first;
  if v_tenant.founder_email is not null then
    v_first := v_first
      and lower(coalesce(auth.email(), '')) = lower(v_tenant.founder_email);
  end if;

  insert into profiles
    (id, tenant_id, display_name, club_id, nick, email, phone,
     role, status, approved_at)
  values (
    v_uid,
    p_tenant_id,
    trim(p_display_name),
    p_club_id,
    trim(coalesce(p_nick, '')),
    coalesce(auth.email(), ''),
    v_phone,
    case when v_first then 'admin' else 'player' end,
    case when v_first then 'approved' else 'pending' end,
    case when v_first then now() end
  )
  returning * into v_profile;

  return v_profile;
end;
$_$;


ALTER FUNCTION "public"."register_profile"("p_display_name" "text", "p_tenant_id" "uuid", "p_club_id" "uuid", "p_nick" "text", "p_phone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registration_clubs"("p_tenant_id" "uuid") RETURNS TABLE("id" "uuid", "name" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select c.id, c.name from clubs c
  where auth.uid() is not null and c.tenant_id = p_tenant_id
  order by c.name;
$$;


ALTER FUNCTION "public"."registration_clubs"("p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reject_tenant"("p_tenant_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_status text;
begin
  if not is_superadmin() then
    raise exception 'not_allowed';
  end if;
  if exists (
    select 1 from profiles where id = auth.uid() and tenant_id = p_tenant_id
  ) then
    raise exception 'switch_home_first';
  end if;
  select status into v_status from tenants where id = p_tenant_id;
  if not found then
    raise exception 'unknown_tenant';
  end if;
  if v_status <> 'pending' then
    raise exception 'not_pending';
  end if;

  delete from reservations where tenant_id = p_tenant_id;
  delete from priority_slots where tenant_id = p_tenant_id;
  delete from rentals where tenant_id = p_tenant_id;
  delete from day_overrides where tenant_id = p_tenant_id;
  delete from time_blocks where tenant_id = p_tenant_id;
  delete from priority_slot_types where tenant_id = p_tenant_id;
  delete from clubs where tenant_id = p_tenant_id;
  delete from profiles where tenant_id = p_tenant_id;
  delete from schedule_settings where tenant_id = p_tenant_id;
  delete from tenants where id = p_tenant_id;
end;
$$;


ALTER FUNCTION "public"."reject_tenant"("p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rental_add_date"("p_rental" "uuid", "p_date" "date", "p_starts_at" time without time zone, "p_ends_at" time without time zone, "p_lanes" smallint[], "p_note" "text" DEFAULT ''::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_src rentals;
  v_group uuid;
  v_new uuid;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  -- for update: dva správci, kteří přidávají termín ke stejnému pronájmu bez
  -- skupiny ve stejnou chvíli, by jinak oba viděli group_id = null, oba
  -- založili skupinu a pronájem by se rozpadl na dva. Zámek na zdrojovém
  -- řádku je drží za sebou — druhý uvidí už osvojený řádek.
  select * into v_src from rentals
   where id = p_rental and tenant_id = current_tenant_id()
   for update;
  -- Týdenní série termíny nepřidává — má výjimky (0021).
  if not found or v_src.parent_id is not null or v_src.weekday is not null then
    raise exception 'unknown_rental';
  end if;

  v_group := v_src.group_id;
  if v_group is null then
    insert into rental_groups (tenant_id, renter_name, color, created_by)
    values (v_src.tenant_id, v_src.renter_name, v_src.color, auth.uid())
    returning id into v_group;
    update rentals set group_id = v_group where id = v_src.id;
  end if;

  insert into rentals (tenant_id, group_id, renter_name, color, date, lanes,
                       starts_at, ends_at, note, created_by)
  values (v_src.tenant_id, v_group, v_src.renter_name, v_src.color, p_date,
          p_lanes, p_starts_at, p_ends_at, coalesce(p_note, ''), auth.uid())
  returning id into v_new;
  return v_new;
end;
$$;


ALTER FUNCTION "public"."rental_add_date"("p_rental" "uuid", "p_date" "date", "p_starts_at" time without time zone, "p_ends_at" time without time zone, "p_lanes" smallint[], "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rental_exception_guard"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_parent rentals;
begin
  select * into v_parent from rentals where id = new.parent_id;
  if not found
     or new.parent_id = new.id
     or v_parent.tenant_id <> new.tenant_id
     or v_parent.parent_id is not null      -- no exception of an exception
     or v_parent.weekday is null            -- one-time rentals have no series
     or new.date is null
     or not rental_occurs(v_parent, new.date)
     or exists (select 1 from rentals where parent_id = new.id) then
    raise exception 'rental_exception_invalid';
  end if;
  new.renter_name := v_parent.renter_name;
  new.color := v_parent.color;
  return new;
end;
$$;


ALTER FUNCTION "public"."rental_exception_guard"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rental_group_changed"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if old.renter_name is distinct from new.renter_name
     or old.color is distinct from new.color then
    update rentals set renter_name = new.renter_name, color = new.color
    where group_id = new.id;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."rental_group_changed"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rental_group_guard"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_group rental_groups;
begin
  select * into v_group from rental_groups where id = new.group_id;
  if not found or v_group.tenant_id <> new.tenant_id then
    raise exception 'rental_group_invalid';
  end if;
  new.renter_name := v_group.renter_name;
  new.color := v_group.color;
  return new;
end;
$$;


ALTER FUNCTION "public"."rental_group_guard"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rental_group_prune"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not exists (select 1 from rentals where group_id = old.group_id) then
    delete from rental_groups where id = old.group_id;
  end if;
  return null;
end;
$$;


ALTER FUNCTION "public"."rental_group_prune"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rental_occurrences"("p_tenant" "uuid", "p_date" "date") RETURNS TABLE("rental_id" "uuid", "override_id" "uuid", "renter_name" "text", "lanes" smallint[], "starts_at" time without time zone, "ends_at" time without time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select p.id, c.id, p.renter_name,
         coalesce(c.lanes, p.lanes),
         coalesce(c.starts_at, p.starts_at),
         coalesce(c.ends_at, p.ends_at)
  from rentals p
  left join rentals c
    on c.parent_id = p.id and c.tenant_id = p.tenant_id and c.date = p_date
  where p.tenant_id = p_tenant
    and p.parent_id is null
    and rental_occurs(p, p_date)
    and not coalesce(c.skipped, false);
$$;


ALTER FUNCTION "public"."rental_occurrences"("p_tenant" "uuid", "p_date" "date") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rentals" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "renter_name" "text" NOT NULL,
    "lanes" smallint[] NOT NULL,
    "date" "date",
    "weekday" smallint,
    "starts_at" time without time zone NOT NULL,
    "ends_at" time without time zone NOT NULL,
    "valid_from" "date",
    "valid_until" "date",
    "note" "text" DEFAULT ''::"text" NOT NULL,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "color" integer DEFAULT '-2'::integer NOT NULL,
    "tenant_id" "uuid" DEFAULT "public"."current_tenant_id"() NOT NULL,
    "parent_id" "uuid",
    "skipped" boolean DEFAULT false NOT NULL,
    "group_id" "uuid",
    CONSTRAINT "rentals_check" CHECK (("ends_at" > "starts_at")),
    CONSTRAINT "rentals_check1" CHECK ((("date" IS NULL) <> ("weekday" IS NULL))),
    CONSTRAINT "rentals_color_check" CHECK (((("color" >= '-2'::integer) AND ("color" <= 8)) OR (("color" >= 16777216) AND ("color" <= 33554431)))),
    CONSTRAINT "rentals_exception_shape_check" CHECK ((("parent_id" IS NULL) OR (("date" IS NOT NULL) AND ("weekday" IS NULL) AND ("valid_from" IS NULL) AND ("valid_until" IS NULL)))),
    CONSTRAINT "rentals_group_shape_check" CHECK ((("group_id" IS NULL) OR (("date" IS NOT NULL) AND ("parent_id" IS NULL)))),
    CONSTRAINT "rentals_lanes_check" CHECK (("cardinality"("lanes") > 0)),
    CONSTRAINT "rentals_skipped_check" CHECK (((NOT "skipped") OR ("parent_id" IS NOT NULL))),
    CONSTRAINT "rentals_weekday_check" CHECK ((("weekday" >= 1) AND ("weekday" <= 7)))
);


ALTER TABLE "public"."rentals" OWNER TO "postgres";


COMMENT ON COLUMN "public"."rentals"."color" IS 'Rental colour: -2 = the rental default, 0-11 a palette entry, 0x1000000|rgb a hand-picked colour.';



COMMENT ON COLUMN "public"."rentals"."parent_id" IS 'Exception row: overrides the series for `date`; skipped = the occurrence does not happen.';



COMMENT ON COLUMN "public"."rentals"."group_id" IS 'The rental_groups row this one-time date belongs to (0041); null for a lone one-time rental, a weekly series or an exception row.';



CREATE OR REPLACE FUNCTION "public"."rental_occurs"("r" "public"."rentals", "p_date" "date") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case
    when r.date is not null then r.date = p_date
    else r.weekday = extract(isodow from p_date)::smallint
         and (r.valid_from is null or p_date >= r.valid_from)
         and (r.valid_until is null or p_date <= r.valid_until)
  end;
$$;


ALTER FUNCTION "public"."rental_occurs"("r" "public"."rentals", "p_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rental_series_changed"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.weekday is null then
    delete from rentals where parent_id = new.id;
  elsif old.weekday is distinct from new.weekday
     or old.valid_from is distinct from new.valid_from
     or old.valid_until is distinct from new.valid_until then
    delete from rentals c
    where c.parent_id = new.id and not rental_occurs(new, c.date);
  end if;
  if old.renter_name is distinct from new.renter_name
     or old.color is distinct from new.color then
    update rentals set renter_name = new.renter_name, color = new.color
    where parent_id = new.id;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."rental_series_changed"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."request_federation_discovery"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."request_federation_discovery"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."request_federation_sync"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."request_federation_sync"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reservations_enqueue_calendar"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if tg_op = 'UPDATE' and old.player_id <> new.player_id then
    perform enqueue_calendar_sync(old.player_id, new.id);
  end if;
  perform enqueue_calendar_sync(new.player_id, new.id);
  return new;
end;
$$;


ALTER FUNCTION "public"."reservations_enqueue_calendar"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."same_group"("a" "uuid", "b" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1
      from player_group_members x
      join player_group_members y on y.group_id = x.group_id
     where x.user_id = a and x.status = 'member'
       and y.user_id = b and y.status = 'member')
$$;


ALTER FUNCTION "public"."same_group"("a" "uuid", "b" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."save_placeholder_player"("p_id" "uuid", "p_display_name" "text", "p_nick" "text", "p_club_id" "uuid") RETURNS "public"."profiles"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_tenant uuid := current_tenant_id();
  v_profile profiles;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if trim(coalesce(p_display_name, '')) = '' then
    raise exception 'empty_display_name';
  end if;
  if char_length(trim(coalesce(p_nick, ''))) > 14 then
    raise exception 'nick_too_long';
  end if;
  if p_club_id is not null and not exists (
    select 1 from clubs where id = p_club_id and tenant_id = v_tenant
  ) then
    raise exception 'unknown_club';
  end if;

  if p_id is null then
    insert into profiles
      (id, tenant_id, display_name, email, role, status, nick, club_id,
       placeholder, approved_by, approved_at)
    values
      (gen_random_uuid(), v_tenant, trim(p_display_name), '', 'player',
       'approved', trim(coalesce(p_nick, '')), p_club_id, true,
       auth.uid(), now())
    returning * into v_profile;
  else
    update profiles
    set display_name = trim(p_display_name),
        nick = trim(coalesce(p_nick, '')),
        club_id = p_club_id
    where id = p_id and tenant_id = v_tenant and placeholder
    returning * into v_profile;
    if not found then
      raise exception 'unknown_player';
    end if;
  end if;
  return v_profile;
end;
$$;


ALTER FUNCTION "public"."save_placeholder_player"("p_id" "uuid", "p_display_name" "text", "p_nick" "text", "p_club_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."seed_demo_member"("p_email" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid uuid;
begin
  select id into v_uid from auth.users where lower(email) = lower(p_email);
  if v_uid is null then
    raise exception 'No auth user for %. Create it in the dashboard first.', p_email;
  end if;
  insert into profiles (id, tenant_id, display_name, email, role, status)
  values (v_uid, '00000000-0000-0000-0000-0000000000de',
          'Recenze', p_email, 'admin', 'approved')
  on conflict (id) do update
    set tenant_id = excluded.tenant_id,
        role = 'admin',
        status = 'approved';
end;
$$;


ALTER FUNCTION "public"."seed_demo_member"("p_email" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."seed_tenant_defaults"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into schedule_settings (tenant_id) values (new.id);
  insert into priority_slot_types (tenant_id, name, is_match, builtin)
  values (new.id, 'Zápas', true, true),
         (new.id, 'Úklid před zápasem', false, true);
  return new;
end;
$$;


ALTER FUNCTION "public"."seed_tenant_defaults"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_calendar_reminders_for"("p_user" "uuid", "p_minutes" integer[], "p_calendar" "text" DEFAULT 'primary'::"text") RETURNS integer[]
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."set_calendar_reminders_for"("p_user" "uuid", "p_minutes" integer[], "p_calendar" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_calendar_teams_for"("p_user" "uuid", "p_teams" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
           'team', team, 'calendar', calendar)
           order by team), '[]'::jsonb)
    into v_previous
    from calendar_teams where user_id = p_user;

  delete from calendar_teams where user_id = p_user;
  insert into calendar_teams (user_id, team, calendar)
  select p_user, trim(x.team), coalesce(x.calendar, 'primary')
    from jsonb_to_recordset(v_teams) as x(team text, calendar text);

  -- The mirror the older (1.2.1) app reads; see 0033.
  update google_calendar_links
     set match_teams = coalesce(
           (select array_agg(team order by team)
              from calendar_teams where user_id = p_user), '{}'),
         updated_at = now()
   where user_id = p_user;

  return v_previous;
end;
$$;


ALTER FUNCTION "public"."set_calendar_teams_for"("p_user" "uuid", "p_teams" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_day_override"("p_date" "date", "p_closed" boolean, "p_reason" "text" DEFAULT ''::"text", "p_block_ids" "uuid"[] DEFAULT NULL::"uuid"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_admin boolean := is_admin();
  v_today date := (now() at time zone 'Europe/Prague')::date;
  v_now time := (now() at time zone 'Europe/Prague')::time;
begin
  perform duty_edit_gate(p_date);

  insert into day_overrides (tenant_id, date, closed, reason, block_ids, created_by)
  values (current_tenant_id(), p_date, p_closed, trim(coalesce(p_reason, '')),
          p_block_ids, auth.uid())
  on conflict (tenant_id, date) do update
    set closed = excluded.closed,
        reason = excluded.reason,
        block_ids = excluded.block_ids,
        created_by = excluded.created_by,
        created_at = now();

  update reservations r
  set cancelled_at = now(),
      cancelled_via = 'admin',
      cancel_note = coalesce(nullif(trim(p_reason), ''), 'změna rozvrhu'),
      notify_player = true,
      notify_message = null
  from time_blocks b
  where b.id = r.block_id
    and r.date = p_date
    and r.tenant_id = current_tenant_id()
    and r.cancelled_at is null
    and (p_closed or (p_block_ids is not null and not (r.block_id = any (p_block_ids))))
    and (v_admin or not (r.date = v_today and b.starts_at <= v_now));
end;
$$;


ALTER FUNCTION "public"."set_day_override"("p_date" "date", "p_closed" boolean, "p_reason" "text", "p_block_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_display_name"("p_user_id" "uuid", "p_name" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_name text := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g');
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if v_name = '' then
    raise exception 'empty_display_name';
  end if;
  if char_length(v_name) > 60 then
    raise exception 'display_name_too_long';
  end if;
  update profiles
     set display_name = v_name,
         regnum_checked_at = case when display_name is distinct from v_name
                                  then null else regnum_checked_at end
   where id = p_user_id and tenant_id = current_tenant_id();
  if not found then
    raise exception 'unknown_player';
  end if;
end;
$$;


ALTER FUNCTION "public"."set_display_name"("p_user_id" "uuid", "p_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_federation_sync"("p_venue_slug" "text", "p_enabled" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  v_tenant constant uuid := current_tenant_id();
  v_slug text := lower(trim(coalesce(p_venue_slug, '')));
  v_old text;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then
    raise exception 'invalid_venue_slug';
  end if;
  select venue_slug into v_old from federation_sync
   where tenant_id = v_tenant for update;
  insert into federation_sync (tenant_id, venue_slug, enabled)
  values (v_tenant, v_slug, p_enabled)
  on conflict (tenant_id) do update
    set venue_slug = excluded.venue_slug, enabled = excluded.enabled,
        last_report = case
          when federation_sync.venue_slug = excluded.venue_slug
            then federation_sync.last_report
          else federation_sync.last_report - 'discover' end;
  if v_old is distinct from v_slug then
    delete from notification_jobs
     where dedupe_key = 'federation_discover:' || v_tenant;
  end if;
  -- A moved kuželna leaves the old one's venue key dead, and its
  -- discovery's error with the report.
  perform federation_refresh_error(v_tenant);
end;
$_$;


ALTER FUNCTION "public"."set_federation_sync"("p_venue_slug" "text", "p_enabled" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_match_exception"("p_match" "uuid", "p_shown" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_slot priority_slots%rowtype;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  -- The kiosk is the alley's tablet, not a player; a pending profile has no
  -- business in anyone's calendar yet.
  if not is_approved() or is_kiosk() then
    raise exception 'not_allowed';
  end if;

  select * into v_slot from priority_slots
   where id = p_match and tenant_id = current_tenant_id();
  if not found
     or v_slot.parent_id is not null
     or not exists (select 1 from priority_slot_types
                    where id = v_slot.type_id and is_match) then
    raise exception 'unknown_match';
  end if;
  if v_slot.date < (now() at time zone 'Europe/Prague')::date then
    raise exception 'match_past';
  end if;

  if p_shown is null then
    delete from match_exceptions
     where user_id = auth.uid() and match_id = p_match;
  else
    insert into match_exceptions (user_id, match_id, shown)
    values (auth.uid(), p_match, p_shown)
    on conflict (user_id, match_id) do update set shown = excluded.shown;
  end if;
end;
$$;


ALTER FUNCTION "public"."set_match_exception"("p_match" "uuid", "p_shown" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_nick"("p_user_id" "uuid", "p_nick" "text" DEFAULT ''::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
  update profiles set nick = trim(coalesce(p_nick, ''))
  where id = p_user_id
    and (id = auth.uid() or tenant_id = current_tenant_id());
end;
$$;


ALTER FUNCTION "public"."set_nick"("p_user_id" "uuid", "p_nick" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_player_club"("p_user_id" "uuid", "p_club_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  if p_club_id is not null and not exists (
    select 1 from clubs
    where id = p_club_id and tenant_id = current_tenant_id()
  ) then
    raise exception 'unknown_club';
  end if;
  update profiles set club_id = p_club_id
  where id = p_user_id and tenant_id = current_tenant_id();
end; $$;


ALTER FUNCTION "public"."set_player_club"("p_user_id" "uuid", "p_club_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_public_overview"("p_slug" "text", "p_enabled" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_slug constant text := nullif(lower(trim(coalesce(p_slug, ''))), '');
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if coalesce(p_enabled, false) and v_slug is null then
    raise exception 'invalid_slug';
  end if;
  update tenants
     set public_slug = v_slug, public_enabled = coalesce(p_enabled, false)
   where id = current_tenant_id();
exception
  when check_violation then raise exception 'invalid_slug';
  when unique_violation then raise exception 'slug_taken';
end;
$$;


ALTER FUNCTION "public"."set_public_overview"("p_slug" "text", "p_enabled" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_regnum"("p_user_id" "uuid", "p_regnum" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  v_regnum text := nullif(trim(coalesce(p_regnum, '')), '');
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if v_regnum is not null and v_regnum !~ '^[0-9]{1,8}$' then
    raise exception 'invalid_regnum';
  end if;
  begin
    update profiles
       set regnum = v_regnum,
           regnum_checked_at = case when v_regnum is null then null else now() end
     where id = p_user_id and tenant_id = current_tenant_id();
  exception when unique_violation then
    raise exception 'regnum_taken';
  end;
  if not found then
    raise exception 'unknown_player';
  end if;
end;
$_$;


ALTER FUNCTION "public"."set_regnum"("p_user_id" "uuid", "p_regnum" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_role"("p_user_id" "uuid", "p_role" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if p_role not in ('player', 'admin', 'kiosk') then
    raise exception 'invalid_role';
  end if;
  if p_user_id = auth.uid() and p_role <> 'admin' then
    raise exception 'cannot_demote_self';
  end if;
  if exists (
    select 1 from profiles
    where id = p_user_id and tenant_id = current_tenant_id() and placeholder
  ) then
    raise exception 'placeholder_no_account';
  end if;

  update profiles
  set role = p_role,
      status = case when p_role = 'kiosk' then 'approved' else status end
  where id = p_user_id and tenant_id = current_tenant_id();
end;
$$;


ALTER FUNCTION "public"."set_role"("p_user_id" "uuid", "p_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_team_colors_for"("p_user" "uuid", "p_colors" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_colors jsonb := coalesce(p_colors, '[]'::jsonb);
  v_previous jsonb;
begin
  if jsonb_typeof(v_colors) <> 'array' then
    raise exception 'bad_colors';
  end if;
  if jsonb_array_length(v_colors) > 40 then
    raise exception 'bad_colors';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('team', tc.team, 'color_id', tc.color_id)
           order by tc.team), '[]'::jsonb)
    into v_previous
    from team_colors tc
    where tc.user_id = p_user
      and tc.team in (
        select trim(y.team) from jsonb_to_recordset(v_colors) as y(team text, color_id smallint)
      );

  delete from team_colors
    where user_id = p_user
      and team in (
        select trim(y.team) from jsonb_to_recordset(v_colors) as y(team text, color_id smallint)
          where y.color_id is null
      );

  -- Collapses a repeated team name itself (distinct on, ordered by each
  -- element's original array position via WITH ORDINALITY) instead of
  -- trusting the caller — a second occurrence for the same team used to
  -- make ON CONFLICT raise "cannot affect row a second time".
  insert into team_colors (user_id, team, color_id)
  select p_user, x.team, x.color_id
    from (
      select distinct on (trim(y.team))
             trim(y.team) as team, y.color_id
        from jsonb_array_elements(v_colors) with ordinality as e(elem, ord)
        cross join lateral jsonb_to_record(e.elem) as y(team text, color_id smallint)
        order by trim(y.team), e.ord
    ) x
    where x.color_id is not null
  on conflict (user_id, team) do update set color_id = excluded.color_id;

  return v_previous;
end;
$$;


ALTER FUNCTION "public"."set_team_colors_for"("p_user" "uuid", "p_colors" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_training_color_for"("p_user" "uuid", "p_color" smallint) RETURNS smallint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_color smallint := p_color;
begin
  -- null = bez barvy (událost vezme barvu kalendáře); jinak jen Googlem
  -- povolených jedenáct, viz calendar_teams.color_id.
  if v_color is not null and (v_color < 1 or v_color > 11) then
    raise exception 'bad_color';
  end if;
  if not exists (select 1 from google_calendar_links where user_id = p_user) then
    raise exception 'unknown_link';
  end if;

  update google_calendar_links
     set training_color_id = v_color, updated_at = now()
   where user_id = p_user;
  return v_color;
end;
$$;


ALTER FUNCTION "public"."set_training_color_for"("p_user" "uuid", "p_color" smallint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."slot_watches_end_on_booking"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  delete from slot_watches
   where user_id = new.player_id and date = new.date
     and (block_ids is null or new.block_id = any (block_ids));
  return new;
end;
$$;


ALTER FUNCTION "public"."slot_watches_end_on_booking"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."start_calendar_link"() RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_nonce text;
begin
  if not is_approved() or is_kiosk() then
    raise exception 'not_allowed';
  end if;
  -- Closing the consent screen and trying again must not pile up rows.
  delete from oauth_nonces
    where user_id = auth.uid() and consumed_at is null;
  insert into oauth_nonces (user_id) values (auth.uid())
    returning nonce into v_nonce;
  return v_nonce;
end;
$$;


ALTER FUNCTION "public"."start_calendar_link"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."switch_tenant"("p_tenant_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_superadmin() then
    raise exception 'not_allowed';
  end if;
  if not exists (select 1 from tenants where id = p_tenant_id) then
    raise exception 'unknown_tenant';
  end if;
  update profiles set tenant_id = p_tenant_id where id = auth.uid();
end;
$$;


ALTER FUNCTION "public"."switch_tenant"("p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_uklid_for_match"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_is_match boolean;
  v_uklid_type uuid;
  v_start time;
begin
  select is_match into v_is_match
  from priority_slot_types where id = new.type_id;
  if not coalesce(v_is_match, false) or new.parent_id is not null then
    return new;
  end if;

  if coalesce(new.is_away, false) or coalesce(new.prep_minutes, 0) <= 0 then
    delete from priority_slots where parent_id = new.id;
    return new;
  end if;

  select id into v_uklid_type from priority_slot_types
  where tenant_id = new.tenant_id and builtin and not is_match
    and name = 'Úklid před zápasem';
  if v_uklid_type is null then
    return new;
  end if;

  v_start := case
    when extract(epoch from new.starts_at) / 60 >= new.prep_minutes
      then new.starts_at - make_interval(mins => new.prep_minutes)
    else time '00:00'
  end;

  update priority_slots
  set date = new.date, starts_at = v_start, ends_at = new.starts_at
  where parent_id = new.id;
  if not found then
    insert into priority_slots
      (tenant_id, date, starts_at, ends_at, type_id, parent_id, created_by)
    values
      (new.tenant_id, new.date, v_start, new.starts_at, v_uklid_type,
       new.id, new.created_by);
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."sync_uklid_for_match"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."time_blocks_enqueue_calendar"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform enqueue_calendar_sync(r.player_id, r.id)
    from reservations r
    where r.block_id = new.id
      and r.cancelled_at is null
      and r.date >= (now() at time zone 'Europe/Prague')::date;
  return new;
end;
$$;


ALTER FUNCTION "public"."time_blocks_enqueue_calendar"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trigger_notification_jobs"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_url text;
  v_secret text;
begin
  if not notifications_due() then
    return;
  end if;
  select c.url, c.secret into v_url, v_secret from notify_webhook_config() c;
  if v_url is null or v_secret is null then
    raise warning 'trigger_notification_jobs: vault secrets notify_url / webhook_secret missing, due jobs not dispatched';
    return;
  end if;
  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-webhook-secret', v_secret
    ),
    body := '{"type":"CRON","table":"notification_jobs","record":null,"old_record":null}'::jsonb
  );
end;
$$;


ALTER FUNCTION "public"."trigger_notification_jobs"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."unwatch_day"("p_date" "date") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  delete from slot_watches where user_id = auth.uid() and date = p_date;
end;
$$;


ALTER FUNCTION "public"."unwatch_day"("p_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_team"("p_id" "uuid", "p_name" "text", "p_club_id" "uuid", "p_active" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if trim(coalesce(p_name, '')) = '' then
    raise exception 'empty_name';
  end if;
  if p_club_id is not null and not exists (
      select 1 from clubs where id = p_club_id and tenant_id = current_tenant_id()) then
    raise exception 'unknown_club';
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
  -- A team switched off can leave its competition and matches dead.
  perform federation_refresh_error(current_tenant_id());
end;
$$;


ALTER FUNCTION "public"."update_team"("p_id" "uuid", "p_name" "text", "p_club_id" "uuid", "p_active" boolean) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."clubs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "color" integer DEFAULT '-1'::integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "tenant_id" "uuid" DEFAULT "public"."current_tenant_id"() NOT NULL,
    "site_slug" "text",
    "site_name" "text",
    CONSTRAINT "clubs_color_check" CHECK (((("color" >= '-1'::integer) AND ("color" <= 8)) OR (("color" >= 16777216) AND ("color" <= 33554431))))
);


ALTER TABLE "public"."clubs" OWNER TO "postgres";


COMMENT ON COLUMN "public"."clubs"."color" IS 'Club colour: -1 = none, 0-11 a palette entry, 0x1000000|rgb a hand-picked colour.';



COMMENT ON COLUMN "public"."clubs"."site_slug" IS 'The venue club on vysledky.kuzelky.cz (detail-klubu/<slug>) this club is linked to; null = not linked. Written by discovery only, so a rename in the app keeps the link.';



COMMENT ON COLUMN "public"."clubs"."site_name" IS 'The linked club''s name on vysledky.kuzelky.cz, refreshed by every discovery.';



CREATE OR REPLACE FUNCTION "public"."upsert_club"("p_id" "uuid", "p_name" "text", "p_color" integer) RETURNS "public"."clubs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v clubs;
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  if trim(coalesce(p_name,'')) = '' then raise exception 'empty_name'; end if;
  if p_id is null then
    insert into clubs (tenant_id, name, color)
    values (current_tenant_id(), trim(p_name), p_color) returning * into v;
  else
    update clubs set name = trim(p_name), color = p_color
    where id = p_id and tenant_id = current_tenant_id() returning * into v;
  end if;
  return v;
end; $$;


ALTER FUNCTION "public"."upsert_club"("p_id" "uuid", "p_name" "text", "p_color" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_federation_teams"("p_tenant" "uuid", "p_teams" "jsonb") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  t jsonb;
  v_name text;
  v_club uuid;
  v_new integer := 0;
begin
  for t in select * from jsonb_array_elements(p_teams) loop
    select id into v_club from clubs
     where id = (t->>'club_id')::uuid and tenant_id = p_tenant;
    update teams
       set site_team_id = (t->>'site_team_id')::integer, site_name = t->>'site_name',
           competition_slug = t->>'competition_slug',
           competition_name = t->>'competition_name',
           club_id = coalesce(club_id, v_club)
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
    values (p_tenant, v_name, v_club, (t->>'site_team_id')::integer,
            t->>'site_slug', t->>'site_name', t->>'competition_slug',
            t->>'competition_name');
    v_new := v_new + 1;
  end loop;
  -- A team rolled over to a new season leaves its old competition dead.
  perform federation_refresh_error(p_tenant);
  return v_new;
end;
$$;


ALTER FUNCTION "public"."upsert_federation_teams"("p_tenant" "uuid", "p_teams" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_federation_venue"("p_tenant" "uuid", "p_venue" "jsonb") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."upsert_federation_venue"("p_tenant" "uuid", "p_venue" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."visible_message_ids"() RETURNS SETOF "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select m.id from messages m
   where m.tenant_id = (select current_tenant_id())
     and ((select is_approved()) and not (select is_kiosk())
          and (m.kind = 'notice'
               or m.author_id = (select auth.uid())
               or exists (select 1 from message_recipients r
                           where r.message_id = m.id
                             and r.user_id = (select auth.uid())))
          or (select is_kiosk()) and m.kind = 'notice')
$$;


ALTER FUNCTION "public"."visible_message_ids"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."visible_recipient_message_ids"() RETURNS SETOF "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select m.id from messages m
   where m.tenant_id = (select current_tenant_id())
     and (select is_approved()) and not (select is_kiosk())
     and ((m.kind = 'notice' and (select is_admin()))
          or (m.kind = 'message'
              and (m.author_id = (select auth.uid())
                   or exists (select 1 from message_recipients r
                               where r.message_id = m.id
                                 and r.user_id = (select auth.uid())))))
$$;


ALTER FUNCTION "public"."visible_recipient_message_ids"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."watch_day"("p_date" "date", "p_block_ids" "uuid"[] DEFAULT NULL::"uuid"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."watch_day"("p_date" "date", "p_block_ids" "uuid"[]) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."app_config" (
    "id" boolean DEFAULT true NOT NULL,
    "min_build" integer DEFAULT 1 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "app_config_id_check" CHECK ("id"),
    CONSTRAINT "app_config_min_build_check" CHECK (("min_build" >= 1))
);


ALTER TABLE "public"."app_config" OWNER TO "postgres";


COMMENT ON TABLE "public"."app_config" IS 'Single row. min_build = the oldest app build the backend still supports; older builds block on the update screen.';



CREATE TABLE IF NOT EXISTS "public"."calendar_teams" (
    "user_id" "uuid" NOT NULL,
    "team" "text" NOT NULL,
    "calendar" "text" DEFAULT 'primary'::"text" NOT NULL,
    CONSTRAINT "calendar_teams_calendar_check" CHECK (("calendar" = ANY (ARRAY['primary'::"text", 'secondary'::"text"])))
);


ALTER TABLE "public"."calendar_teams" OWNER TO "postgres";


COMMENT ON TABLE "public"."calendar_teams" IS 'One row per player+followed team (0032, replaces google_calendar_links.match_teams): which of the two calendars its matches go to. Read-only to the client (0035) — every write goes through calendar-manage (set_calendar_teams_for), which also keeps match_teams mirrored for the 1.2.1 app. Colour moved to team_colors (0036) — independent of this table now.';



COMMENT ON COLUMN "public"."calendar_teams"."calendar" IS 'Which of the player''s Google calendars this team''s matches go to; secondary only means something once google_calendar_links.secondary_enabled is true.';



CREATE TABLE IF NOT EXISTS "public"."day_overrides" (
    "date" "date" NOT NULL,
    "closed" boolean DEFAULT false NOT NULL,
    "reason" "text" DEFAULT ''::"text" NOT NULL,
    "block_ids" "uuid"[],
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "tenant_id" "uuid" NOT NULL
);


ALTER TABLE "public"."day_overrides" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."duty_assignments" (
    "period_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "assigned_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."duty_assignments" OWNER TO "postgres";


COMMENT ON TABLE "public"."duty_assignments" IS 'Who works a duty_periods row (0050): approved players of the alley, placeholders included (they count, but never get the duty''s rights); never the kiosk. tenant_id is the period''s, denormalised like player_group_members. Written only through duty_set_assignees; a merge moves a placeholder''s rows to the account.';



CREATE TABLE IF NOT EXISTS "public"."duty_periods" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "starts_on" "date" NOT NULL,
    "ends_on" "date" NOT NULL,
    "note" "text" DEFAULT ''::"text" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "duty_periods_length_check" CHECK ((("ends_on" - "starts_on") < 62)),
    CONSTRAINT "duty_periods_note_check" CHECK (("char_length"("note") <= 80)),
    CONSTRAINT "duty_periods_order_check" CHECK (("ends_on" >= "starts_on"))
);


ALTER TABLE "public"."duty_periods" OWNER TO "postgres";


COMMENT ON TABLE "public"."duty_periods" IS 'A canteen duty (0050): the days [starts_on, ends_on], both included, at most 62 of them, that the players in duty_assignments work the canteen. Periods of one alley never overlap (duty_periods_no_overlap). Written only through the admin''s duty_* RPCs.';



COMMENT ON COLUMN "public"."duty_periods"."note" IS 'The admin''s note shown next to the dates, trimmed, at most 80 characters; '''' = none.';



CREATE TABLE IF NOT EXISTS "public"."duty_seasons" (
    "tenant_id" "uuid" NOT NULL,
    "started_on" "date" NOT NULL,
    "name" "text" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "duty_seasons_name_check" CHECK ((("char_length"("name") >= 1) AND ("char_length"("name") <= 40)))
);


ALTER TABLE "public"."duty_seasons" OWNER TO "postgres";


COMMENT ON TABLE "public"."duty_seasons" IS 'Season boundaries for the duty counts (0050). A period belongs to the season with the greatest started_on <= its starts_on; the periods before the first boundary form the implicit first season. Starting a season inserts a row and moves nothing; undoing it deletes the newest row (duty_season_start / duty_season_delete).';



CREATE TABLE IF NOT EXISTS "public"."federation_sync" (
    "tenant_id" "uuid" NOT NULL,
    "venue_slug" "text" DEFAULT ''::"text" NOT NULL,
    "enabled" boolean DEFAULT false NOT NULL,
    "last_run_at" timestamp with time zone,
    "last_success_at" timestamp with time zone,
    "last_error" "text",
    "last_report" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "federation_sync_venue_slug_check" CHECK (("venue_slug" ~ '^([a-z0-9]+(-[a-z0-9]+)*)?$'::"text"))
);


ALTER TABLE "public"."federation_sync" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."google_calendar_links" (
    "user_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "google_email" "text",
    "last_error" "text",
    "reminder_minutes" integer[] DEFAULT '{}'::integer[] NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "match_teams" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "secondary_enabled" boolean DEFAULT false NOT NULL,
    "reminder_minutes_secondary" integer[] DEFAULT '{}'::integer[] NOT NULL,
    "training_color_id" smallint,
    CONSTRAINT "google_calendar_links_match_teams_check" CHECK ((COALESCE("array_length"("match_teams", 1), 0) <= 20)),
    CONSTRAINT "google_calendar_links_reminder_minutes_check" CHECK (((COALESCE("array_length"("reminder_minutes", 1), 0) <= 5) AND (0 <= ALL ("reminder_minutes")) AND (40320 >= ALL ("reminder_minutes")))),
    CONSTRAINT "google_calendar_links_reminder_minutes_secondary_check" CHECK (((COALESCE("array_length"("reminder_minutes_secondary", 1), 0) <= 5) AND (0 <= ALL ("reminder_minutes_secondary")) AND (40320 >= ALL ("reminder_minutes_secondary")))),
    CONSTRAINT "google_calendar_links_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'linked'::"text", 'broken'::"text", 'unlinked'::"text"]))),
    CONSTRAINT "google_calendar_links_training_color_id_check" CHECK ((("training_color_id" >= 1) AND ("training_color_id" <= 11)))
);


ALTER TABLE "public"."google_calendar_links" OWNER TO "postgres";


COMMENT ON COLUMN "public"."google_calendar_links"."status" IS 'pending (token stored, calendar not yet created) | linked | broken (token revoked / calendar gone) | unlinked (disconnected)';



COMMENT ON COLUMN "public"."google_calendar_links"."match_teams" IS 'DEPRECATED (0033): a read-only mirror of calendar_teams.team for app builds up to 1.2.1. calendar_teams is the truth; drop this once a build with the new screen is out.';



COMMENT ON COLUMN "public"."google_calendar_links"."secondary_enabled" IS 'Player turned on the second Google calendar ("Rezervátor 2"); calendar_teams rows may then target it.';



COMMENT ON COLUMN "public"."google_calendar_links"."reminder_minutes_secondary" IS 'Reminders for events written to the secondary calendar; same shape and bounds as reminder_minutes.';



COMMENT ON COLUMN "public"."google_calendar_links"."training_color_id" IS 'Google Calendar event colorId (1-11) for trainings, which always go to the primary calendar; null = no colour.';



CREATE TABLE IF NOT EXISTS "public"."google_calendar_tokens" (
    "user_id" "uuid" NOT NULL,
    "refresh_token" "text" NOT NULL,
    "google_calendar_id" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "google_calendar_id_secondary" "text"
);


ALTER TABLE "public"."google_calendar_tokens" OWNER TO "postgres";


COMMENT ON COLUMN "public"."google_calendar_tokens"."google_calendar_id_secondary" IS 'The player''s secondary Google calendar id; null until secondary_enabled is turned on.';



CREATE TABLE IF NOT EXISTS "public"."league_matches" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "site_match_id" integer NOT NULL,
    "site_slug" "text" NOT NULL,
    "competition_slug" "text" NOT NULL,
    "competition" "text" DEFAULT ''::"text" NOT NULL,
    "round" smallint,
    "date" "date" NOT NULL,
    "starts_at" time without time zone,
    "home_team" "text" NOT NULL,
    "away_team" "text" NOT NULL,
    "home_team_slug" "text" DEFAULT ''::"text" NOT NULL,
    "away_team_slug" "text" DEFAULT ''::"text" NOT NULL,
    "video_url" "text",
    "venue" "text",
    "venue_slug" "text",
    "status" "text" DEFAULT 'scheduled'::"text" NOT NULL,
    "match_type" "text" DEFAULT ''::"text" NOT NULL,
    "discipline" "text" DEFAULT ''::"text" NOT NULL,
    "home_points" numeric,
    "away_points" numeric,
    "home_total" integer,
    "away_total" integer,
    "home_fulls" integer,
    "away_fulls" integer,
    "home_spares" integer,
    "away_spares" integer,
    "home_errors" integer,
    "away_errors" integer,
    "home_set_points" numeric,
    "away_set_points" numeric,
    "fetched_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "detail_status" "text",
    "detail_fetched_at" timestamp with time zone,
    "round_sig" "text",
    "detail_queued" smallint DEFAULT 0 NOT NULL,
    CONSTRAINT "league_matches_status_check" CHECK (("status" = ANY (ARRAY['scheduled'::"text", 'preparation'::"text", 'in_progress'::"text", 'finished'::"text", 'forfeit'::"text"])))
);

ALTER TABLE ONLY "public"."league_matches" REPLICA IDENTITY FULL;


ALTER TABLE "public"."league_matches" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."league_player_results" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "match_id" "uuid" NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "side" "text" NOT NULL,
    "position" smallint NOT NULL,
    "player_name" "text" NOT NULL,
    "player_site_id" integer,
    "player_slug" "text",
    "fulls" integer,
    "spares" integer,
    "errors" integer,
    "total" integer,
    "set_points" numeric,
    "team_points" numeric,
    "lanes" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "sub_name" "text",
    "sub_site_id" integer,
    "sub_slug" "text",
    "sub_from_throw" smallint,
    CONSTRAINT "league_player_results_side_check" CHECK (("side" = ANY (ARRAY['home'::"text", 'away'::"text"])))
);

ALTER TABLE ONLY "public"."league_player_results" REPLICA IDENTITY FULL;


ALTER TABLE "public"."league_player_results" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."match_exceptions" (
    "user_id" "uuid" NOT NULL,
    "match_id" "uuid" NOT NULL,
    "shown" boolean DEFAULT true NOT NULL,
    "calendar" "text" DEFAULT 'primary'::"text" NOT NULL,
    CONSTRAINT "match_exceptions_calendar_check" CHECK (("calendar" = ANY (ARRAY['primary'::"text", 'secondary'::"text"])))
);


ALTER TABLE "public"."match_exceptions" OWNER TO "postgres";


COMMENT ON TABLE "public"."match_exceptions" IS 'One row per player+match where the player disagrees with what their teams say (0039): shown = true adds the match (it counts as theirs though neither team is in their lists), false hides one a team would have given them. Agreeing with the teams stores nothing — the row is deleted instead, so "back to what the team says" is not a third tick but the absence of a row. Read-only to the client; every write goes through set_match_exception, whose trigger queues the calendar job.';



COMMENT ON COLUMN "public"."match_exceptions"."shown" IS 'true = show this match (Můj přehled + the calendar below), false = hide it wherever a team would have put it.';



COMMENT ON COLUMN "public"."match_exceptions"."calendar" IS 'Which Google calendar an ADDED match goes to. Always ''primary'' today (the app offers no choice) and only ever consulted for a match no team gives the player — a match a team already gives them needs no row at all.';



CREATE TABLE IF NOT EXISTS "public"."match_player_results" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "match_id" "uuid" NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "side" "text" NOT NULL,
    "position" smallint NOT NULL,
    "player_name" "text" NOT NULL,
    "player_site_id" integer,
    "player_slug" "text",
    "fulls" integer,
    "spares" integer,
    "errors" integer,
    "total" integer,
    "set_points" numeric,
    "team_points" numeric,
    "lanes" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "sub_name" "text",
    "sub_site_id" integer,
    "sub_slug" "text",
    "sub_from_throw" smallint,
    CONSTRAINT "match_player_results_side_check" CHECK (("side" = ANY (ARRAY['home'::"text", 'away'::"text"])))
);

ALTER TABLE ONLY "public"."match_player_results" REPLICA IDENTITY FULL;


ALTER TABLE "public"."match_player_results" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."match_results" (
    "match_id" "uuid" NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "status" "text" NOT NULL,
    "match_type" "text" DEFAULT ''::"text" NOT NULL,
    "discipline" "text" DEFAULT ''::"text" NOT NULL,
    "home_points" numeric,
    "away_points" numeric,
    "home_total" integer,
    "away_total" integer,
    "home_fulls" integer,
    "away_fulls" integer,
    "home_spares" integer,
    "away_spares" integer,
    "home_errors" integer,
    "away_errors" integer,
    "home_set_points" numeric,
    "away_set_points" numeric,
    "fetched_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "match_results_status_check" CHECK (("status" = ANY (ARRAY['scheduled'::"text", 'preparation'::"text", 'in_progress'::"text", 'finished'::"text", 'forfeit'::"text"])))
);


ALTER TABLE "public"."match_results" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."message_recipients" (
    "message_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "read_at" timestamp with time zone,
    "reaction" "text",
    "reply" "text",
    "reacted_at" timestamp with time zone,
    CONSTRAINT "message_recipients_reaction_check" CHECK (("reaction" = ANY (ARRAY['up'::"text", 'down'::"text"]))),
    CONSTRAINT "message_recipients_reply_check" CHECK (("char_length"("reply") <= 200))
);


ALTER TABLE "public"."message_recipients" OWNER TO "postgres";


COMMENT ON TABLE "public"."message_recipients" IS 'Who got a messages row (0051), materialised at send time from the reservations/roster/duty data then. tenant_id is the message''s, denormalised like duty_assignments. read_at/reaction/reply are the recipient''s own-row write.';



CREATE TABLE IF NOT EXISTS "public"."messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "author_id" "uuid",
    "author_role" "text" NOT NULL,
    "kind" "text" NOT NULL,
    "audience" "text" NOT NULL,
    "on_date" "date",
    "block_id" "uuid",
    "title" "text",
    "body" "text" NOT NULL,
    "expires_at" timestamp with time zone,
    "notify" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "show_on_kiosk" boolean DEFAULT true NOT NULL,
    "visible_from" timestamp with time zone,
    CONSTRAINT "messages_audience_check" CHECK (("audience" = ANY (ARRAY['all'::"text", 'day'::"text", 'block'::"text", 'admins'::"text", 'duty'::"text"]))),
    CONSTRAINT "messages_author_role_check" CHECK (("author_role" = ANY (ARRAY['admin'::"text", 'player'::"text"]))),
    CONSTRAINT "messages_body_check" CHECK ((("char_length"(TRIM(BOTH FROM "body")) >= 1) AND ("char_length"(TRIM(BOTH FROM "body")) <=
CASE
    WHEN ("kind" = 'notice'::"text") THEN 2000
    ELSE 500
END))),
    CONSTRAINT "messages_context_check" CHECK (((("audience" = 'all'::"text") AND ("on_date" IS NULL) AND ("block_id" IS NULL)) OR (("audience" = 'day'::"text") AND ("on_date" IS NOT NULL) AND ("block_id" IS NULL)) OR (("audience" = 'block'::"text") AND ("on_date" IS NOT NULL)) OR ("audience" = ANY (ARRAY['admins'::"text", 'duty'::"text"])))),
    CONSTRAINT "messages_expires_check" CHECK ((("kind" = 'notice'::"text") OR ("expires_at" IS NULL))),
    CONSTRAINT "messages_kind_audience_check" CHECK (((("kind" = 'notice'::"text") AND ("audience" = 'all'::"text")) OR (("kind" = 'message'::"text") AND ("audience" = ANY (ARRAY['day'::"text", 'block'::"text", 'admins'::"text", 'duty'::"text"]))))),
    CONSTRAINT "messages_kind_check" CHECK (("kind" = ANY (ARRAY['notice'::"text", 'message'::"text"]))),
    CONSTRAINT "messages_title_check" CHECK (((("kind" = 'notice'::"text") AND (("char_length"(TRIM(BOTH FROM COALESCE("title", ''::"text"))) >= 1) AND ("char_length"(TRIM(BOTH FROM COALESCE("title", ''::"text"))) <= 80))) OR (("kind" = 'message'::"text") AND ("title" IS NULL))))
);


ALTER TABLE "public"."messages" OWNER TO "postgres";


COMMENT ON TABLE "public"."messages" IS 'A notice (kind=notice, audience=all, Klubovna -> Nástěnka) or a message (kind=message, to a day/block/admins/duty, Klubovna -> Zprávy), 0051. Written only through message_send/message_update/message_delete.';



COMMENT ON COLUMN "public"."messages"."expires_at" IS 'Notice only: when it stops showing as active; null = "do odvolání".';



COMMENT ON COLUMN "public"."messages"."notify" IS 'Whether sending this pinged its recipients (push/e-mail). Always true for a message; the admin''s choice for a notice.';



CREATE TABLE IF NOT EXISTS "public"."notification_jobs" (
    "id" bigint NOT NULL,
    "kind" "text" NOT NULL,
    "dedupe_key" "text" NOT NULL,
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "run_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."notification_jobs" OWNER TO "postgres";


COMMENT ON COLUMN "public"."notification_jobs"."dedupe_key" IS 'One pending job per key: a repeat re-arms run_at instead of adding a row.';



ALTER TABLE "public"."notification_jobs" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."notification_jobs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."oauth_nonces" (
    "nonce" "text" DEFAULT "encode"("extensions"."gen_random_bytes"(24), 'hex'::"text") NOT NULL,
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "consumed_at" timestamp with time zone
);


ALTER TABLE "public"."oauth_nonces" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."player_group_members" (
    "group_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "status" "text" NOT NULL,
    "invited_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "player_group_members_status_check" CHECK (("status" = ANY (ARRAY['invited'::"text", 'member'::"text"])))
);


ALTER TABLE "public"."player_group_members" OWNER TO "postgres";


COMMENT ON TABLE "public"."player_group_members" IS 'Membership and pending invites of player_groups (0044). tenant_id is denormalised so the admin policy never has to read player_groups (no policy cycle). Written only through the group_* RPCs.';



CREATE TABLE IF NOT EXISTS "public"."player_groups" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."player_groups" OWNER TO "postgres";


COMMENT ON TABLE "public"."player_groups" IS 'A group of players who may book and cancel trainings for each other (0044). Server-only: the app reads player_group_members.';



CREATE OR REPLACE VIEW "public"."players" AS
 SELECT "p"."id",
    "p"."display_name",
    "p"."nick",
    "p"."club_id",
    COALESCE("c"."color", '-1'::integer) AS "club_color",
    "p"."placeholder"
   FROM ("public"."profiles" "p"
     LEFT JOIN "public"."clubs" "c" ON (("c"."id" = "p"."club_id")))
  WHERE (("p"."status" = 'approved'::"text") AND ("p"."role" <> 'kiosk'::"text") AND ("p"."tenant_id" = "public"."current_tenant_id"()) AND (NOT ("p"."superadmin" AND ("p"."home_tenant_id" IS NOT NULL) AND ("p"."tenant_id" <> "p"."home_tenant_id"))));


ALTER VIEW "public"."players" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."priority_slot_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "color" integer DEFAULT '-1'::integer NOT NULL,
    "lanes" smallint[],
    "is_match" boolean DEFAULT false NOT NULL,
    "builtin" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "tenant_id" "uuid" DEFAULT "public"."current_tenant_id"() NOT NULL,
    CONSTRAINT "priority_slot_types_color_check" CHECK (((("color" >= '-1'::integer) AND ("color" <= 8)) OR (("color" >= 16777216) AND ("color" <= 33554431)))),
    CONSTRAINT "priority_slot_types_lanes_check" CHECK ((("lanes" IS NULL) OR ("cardinality"("lanes") > 0)))
);


ALTER TABLE "public"."priority_slot_types" OWNER TO "postgres";


COMMENT ON COLUMN "public"."priority_slot_types"."color" IS 'Slot type colour: -1 = none, 0-11 a palette entry, 0x1000000|rgb a hand-picked colour.';



CREATE TABLE IF NOT EXISTS "public"."reminders_sent" (
    "user_id" "uuid" NOT NULL,
    "event_key" "text" NOT NULL,
    "offset_minutes" integer NOT NULL,
    "sent_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "starts_at" timestamp with time zone
);


ALTER TABLE "public"."reminders_sent" OWNER TO "postgres";


COMMENT ON TABLE "public"."reminders_sent" IS 'Which reminders have already gone out (0040), so a repeated tick or a retried send does not ring twice. Server-only; pruned after 30 days by the tick itself.';



COMMENT ON COLUMN "public"."reminders_sent"."starts_at" IS 'The start of the event this reminder announced (0049). A moved event rings again at its new time. Null = an old receipt without a known start, counts for any start.';



CREATE TABLE IF NOT EXISTS "public"."rental_groups" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" DEFAULT "public"."current_tenant_id"() NOT NULL,
    "renter_name" "text" NOT NULL,
    "color" integer DEFAULT '-2'::integer NOT NULL,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "rental_groups_color_check" CHECK (((("color" >= '-2'::integer) AND ("color" <= 8)) OR (("color" >= 16777216) AND ("color" <= 33554431))))
);


ALTER TABLE "public"."rental_groups" OWNER TO "postgres";


COMMENT ON TABLE "public"."rental_groups" IS 'One renter with several one-time rental dates (0041): the identity (name, colour) its rentals rows carry a copy of. A lone one-time rental has no group; rental_add_date creates one when a second date arrives, rental_group_prune removes it with the last date.';



COMMENT ON COLUMN "public"."rental_groups"."color" IS 'Group colour, the same domain as rentals.color: -2 = the rental default, 0-8 a palette entry, 0x1000000|rgb a hand-picked colour.';



CREATE TABLE IF NOT EXISTS "public"."schedule_settings" (
    "lane_count" smallint DEFAULT 4 NOT NULL,
    "training_weekdays" smallint[] DEFAULT '{}'::smallint[] NOT NULL,
    "booking_horizon_days" smallint DEFAULT 14 NOT NULL,
    "max_active_reservations" smallint DEFAULT 3 NOT NULL,
    "kiosk_dark" boolean DEFAULT true NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "kiosk_fit_day" boolean DEFAULT true NOT NULL,
    "duty_reminder_enabled" boolean DEFAULT false NOT NULL,
    "duty_reminder_days" smallint DEFAULT 1 NOT NULL,
    "kiosk_panel_enabled" boolean DEFAULT true NOT NULL,
    "kiosk_drawer_open" boolean DEFAULT false NOT NULL,
    "kiosk_drawer_width" smallint DEFAULT 440 NOT NULL,
    "kiosk_notices_mode" "text" DEFAULT 'both'::"text" NOT NULL,
    "kiosk_notices_rotation_seconds" smallint DEFAULT 12 NOT NULL,
    "kiosk_notices_share" smallint DEFAULT 40 NOT NULL,
    "kiosk_show_matches" boolean DEFAULT true NOT NULL,
    "kiosk_show_upcoming" boolean DEFAULT true NOT NULL,
    "kiosk_weeks_back" smallint DEFAULT 2 NOT NULL,
    "kiosk_weeks_ahead" smallint DEFAULT 1 NOT NULL,
    "kiosk_follow_board" boolean DEFAULT true NOT NULL,
    "kiosk_live_mode" boolean DEFAULT true NOT NULL,
    "kiosk_live_layout" "text" DEFAULT 'full'::"text" NOT NULL,
    "kiosk_live_rotation_seconds" smallint DEFAULT 12 NOT NULL,
    "kiosk_zapis_percent" smallint DEFAULT 80 NOT NULL,
    "kiosk_past_days" smallint DEFAULT 0 NOT NULL,
    "kiosk_idle_seconds" smallint DEFAULT 60 NOT NULL,
    CONSTRAINT "schedule_settings_booking_horizon_days_check" CHECK ((("booking_horizon_days" >= 1) AND ("booking_horizon_days" <= 90))),
    CONSTRAINT "schedule_settings_duty_reminder_days_check" CHECK ((("duty_reminder_days" >= 1) AND ("duty_reminder_days" <= 14))),
    CONSTRAINT "schedule_settings_kiosk_ahead_check" CHECK ((("kiosk_weeks_ahead" >= 0) AND ("kiosk_weeks_ahead" <= 12))),
    CONSTRAINT "schedule_settings_kiosk_back_check" CHECK ((("kiosk_weeks_back" >= 0) AND ("kiosk_weeks_back" <= 12))),
    CONSTRAINT "schedule_settings_kiosk_idle_check" CHECK ((("kiosk_idle_seconds" >= 15) AND ("kiosk_idle_seconds" <= 600))),
    CONSTRAINT "schedule_settings_kiosk_live_layout_check" CHECK (("kiosk_live_layout" = ANY (ARRAY['full'::"text", 'compact'::"text", 'table'::"text"]))),
    CONSTRAINT "schedule_settings_kiosk_live_rotation_check" CHECK ((("kiosk_live_rotation_seconds" >= 3) AND ("kiosk_live_rotation_seconds" <= 120))),
    CONSTRAINT "schedule_settings_kiosk_notices_mode_check" CHECK (("kiosk_notices_mode" = ANY (ARRAY['off'::"text", 'drawer'::"text", 'header'::"text", 'both'::"text"]))),
    CONSTRAINT "schedule_settings_kiosk_notices_rotation_check" CHECK ((("kiosk_notices_rotation_seconds" >= 3) AND ("kiosk_notices_rotation_seconds" <= 120))),
    CONSTRAINT "schedule_settings_kiosk_past_check" CHECK ((("kiosk_past_days" >= 0) AND ("kiosk_past_days" <= 60))),
    CONSTRAINT "schedule_settings_kiosk_share_check" CHECK ((("kiosk_notices_share" >= 10) AND ("kiosk_notices_share" <= 90))),
    CONSTRAINT "schedule_settings_kiosk_width_check" CHECK ((("kiosk_drawer_width" >= 280) AND ("kiosk_drawer_width" <= 800))),
    CONSTRAINT "schedule_settings_kiosk_zapis_check" CHECK ((("kiosk_zapis_percent" >= 50) AND ("kiosk_zapis_percent" <= 100))),
    CONSTRAINT "schedule_settings_lane_count_check" CHECK ((("lane_count" >= 1) AND ("lane_count" <= 12))),
    CONSTRAINT "schedule_settings_max_active_reservations_check" CHECK ((("max_active_reservations" >= 1) AND ("max_active_reservations" <= 50)))
);


ALTER TABLE "public"."schedule_settings" OWNER TO "postgres";


COMMENT ON COLUMN "public"."schedule_settings"."duty_reminder_enabled" IS 'Whether the players on a canteen duty get a reminder before it (0050). Off by default; switching it off keeps duty_reminder_days.';



COMMENT ON COLUMN "public"."schedule_settings"."duty_reminder_days" IS 'How many days before a canteen duty the reminder goes out, at 18:00 Prague (0050), 1–14.';



CREATE TABLE IF NOT EXISTS "public"."site_player_regnums" (
    "slug" "text" NOT NULL,
    "regnum" "text",
    "status" "text" NOT NULL,
    "looked_up_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "site_player_regnums_check" CHECK ((("status" = 'found'::"text") = ("regnum" IS NOT NULL))),
    CONSTRAINT "site_player_regnums_regnum_check" CHECK ((("regnum" IS NULL) OR ("regnum" ~ '^[0-9]{1,8}$'::"text"))),
    CONSTRAINT "site_player_regnums_slug_check" CHECK (("slug" ~ '^[a-z0-9][a-z0-9-]{0,99}$'::"text")),
    CONSTRAINT "site_player_regnums_status_check" CHECK (("status" = ANY (ARRAY['found'::"text", 'none'::"text", 'ambiguous'::"text"])))
);


ALTER TABLE "public"."site_player_regnums" OWNER TO "postgres";


COMMENT ON TABLE "public"."site_player_regnums" IS 'regnum-lookup cache of MATCH players, by results-service player slug (0059): resolved by the service page''s club and age against the register. Service role only.';



CREATE TABLE IF NOT EXISTS "public"."slot_watches" (
    "user_id" "uuid" NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "date" "date" NOT NULL,
    "block_ids" "uuid"[],
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_notified_at" timestamp with time zone,
    CONSTRAINT "slot_watches_block_ids_check" CHECK ((("block_ids" IS NULL) OR (("cardinality"("block_ids") >= 1) AND ("cardinality"("block_ids") <= 24))))
);

ALTER TABLE ONLY "public"."slot_watches" REPLICA IDENTITY FULL;


ALTER TABLE "public"."slot_watches" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."team_colors" (
    "user_id" "uuid" NOT NULL,
    "team" "text" NOT NULL,
    "color_id" smallint NOT NULL,
    CONSTRAINT "team_colors_color_id_check" CHECK ((("color_id" >= 1) AND ("color_id" <= 11)))
);


ALTER TABLE "public"."team_colors" OWNER TO "postgres";


COMMENT ON TABLE "public"."team_colors" IS 'One row per player+team the player has coloured (0036) — independent of both team lists (profiles.followed_teams, calendar_teams): the single colour shown for that team in Můj přehled and in the Google Calendar event alike. No row = no colour; a linked calendar is not required. Read-only to the client (0037) — every write goes through calendar-manage (set_team_colors_for), which also repaints the affected future Google Calendar events in the same request.';



COMMENT ON COLUMN "public"."team_colors"."color_id" IS 'Google Calendar event colorId (1-11) — the same eleven calendar_teams.color_id used before 0036 moved it here.';



CREATE TABLE IF NOT EXISTS "public"."teams" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "club_id" "uuid",
    "site_team_id" integer,
    "site_slug" "text" NOT NULL,
    "site_name" "text" DEFAULT ''::"text" NOT NULL,
    "competition_slug" "text" DEFAULT ''::"text" NOT NULL,
    "competition_name" "text" DEFAULT ''::"text" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "teams_name_check" CHECK ((("length"(TRIM(BOTH FROM "name")) >= 1) AND ("length"(TRIM(BOTH FROM "name")) <= 80)))
);


ALTER TABLE "public"."teams" OWNER TO "postgres";


COMMENT ON COLUMN "public"."teams"."name" IS 'The name the app keys by (priority_slots.home_team/away_team, followed_teams, calendar_teams, team_colors). Set at discovery, editable by the admin.';



CREATE TABLE IF NOT EXISTS "public"."tenants" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "founder_email" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "approved_at" timestamp with time zone,
    "public_slug" "text",
    "public_enabled" boolean DEFAULT false NOT NULL,
    CONSTRAINT "tenants_public_needs_slug" CHECK (((NOT "public_enabled") OR ("public_slug" IS NOT NULL))),
    CONSTRAINT "tenants_public_slug_format" CHECK (("public_slug" ~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$'::"text")),
    CONSTRAINT "tenants_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text"])))
);


ALTER TABLE "public"."tenants" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."time_blocks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "starts_at" time without time zone NOT NULL,
    "ends_at" time without time zone NOT NULL,
    "position" smallint NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "tenant_id" "uuid" DEFAULT "public"."current_tenant_id"() NOT NULL,
    CONSTRAINT "time_blocks_check" CHECK (("ends_at" > "starts_at"))
);


ALTER TABLE "public"."time_blocks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."venues" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "slug" "text" NOT NULL,
    "name" "text" NOT NULL,
    "address" "text",
    "phone" "text",
    "email" "text",
    "lat" numeric,
    "lng" numeric,
    "sections" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "clubs" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "fetched_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."venues" OWNER TO "postgres";


ALTER TABLE ONLY "public"."app_config"
    ADD CONSTRAINT "app_config_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."calendar_teams"
    ADD CONSTRAINT "calendar_teams_pkey" PRIMARY KEY ("user_id", "team");



ALTER TABLE ONLY "public"."clubs"
    ADD CONSTRAINT "clubs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."clubs"
    ADD CONSTRAINT "clubs_tenant_id_name_key" UNIQUE ("tenant_id", "name");



ALTER TABLE ONLY "public"."day_overrides"
    ADD CONSTRAINT "day_overrides_pkey" PRIMARY KEY ("tenant_id", "date");



ALTER TABLE ONLY "public"."duty_assignments"
    ADD CONSTRAINT "duty_assignments_pkey" PRIMARY KEY ("period_id", "user_id");



ALTER TABLE ONLY "public"."duty_periods"
    ADD CONSTRAINT "duty_periods_no_overlap" EXCLUDE USING "gist" ("tenant_id" WITH =, "daterange"("starts_on", "ends_on", '[]'::"text") WITH &&);



ALTER TABLE ONLY "public"."duty_periods"
    ADD CONSTRAINT "duty_periods_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."duty_seasons"
    ADD CONSTRAINT "duty_seasons_pkey" PRIMARY KEY ("tenant_id", "started_on");



ALTER TABLE ONLY "public"."federation_sync"
    ADD CONSTRAINT "federation_sync_pkey" PRIMARY KEY ("tenant_id");



ALTER TABLE ONLY "public"."google_calendar_links"
    ADD CONSTRAINT "google_calendar_links_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."google_calendar_tokens"
    ADD CONSTRAINT "google_calendar_tokens_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."league_matches"
    ADD CONSTRAINT "league_matches_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."league_matches"
    ADD CONSTRAINT "league_matches_tenant_id_site_match_id_key" UNIQUE ("tenant_id", "site_match_id");



ALTER TABLE ONLY "public"."league_player_results"
    ADD CONSTRAINT "league_player_results_match_id_side_position_key" UNIQUE ("match_id", "side", "position");



ALTER TABLE ONLY "public"."league_player_results"
    ADD CONSTRAINT "league_player_results_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."match_exceptions"
    ADD CONSTRAINT "match_exceptions_pkey" PRIMARY KEY ("user_id", "match_id");



ALTER TABLE ONLY "public"."match_player_results"
    ADD CONSTRAINT "match_player_results_match_id_side_position_key" UNIQUE ("match_id", "side", "position");



ALTER TABLE ONLY "public"."match_player_results"
    ADD CONSTRAINT "match_player_results_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."match_results"
    ADD CONSTRAINT "match_results_pkey" PRIMARY KEY ("match_id");



ALTER TABLE ONLY "public"."priority_slots"
    ADD CONSTRAINT "matches_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."message_recipients"
    ADD CONSTRAINT "message_recipients_pkey" PRIMARY KEY ("message_id", "user_id");



ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notification_jobs"
    ADD CONSTRAINT "notification_jobs_dedupe_key_key" UNIQUE ("dedupe_key");



ALTER TABLE ONLY "public"."notification_jobs"
    ADD CONSTRAINT "notification_jobs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."oauth_nonces"
    ADD CONSTRAINT "oauth_nonces_pkey" PRIMARY KEY ("nonce");



ALTER TABLE ONLY "public"."player_group_members"
    ADD CONSTRAINT "player_group_members_pkey" PRIMARY KEY ("group_id", "user_id");



ALTER TABLE ONLY "public"."player_groups"
    ADD CONSTRAINT "player_groups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."priority_slot_types"
    ADD CONSTRAINT "priority_slot_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."priority_slot_types"
    ADD CONSTRAINT "priority_slot_types_tenant_id_name_key" UNIQUE ("tenant_id", "name");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."reminders_sent"
    ADD CONSTRAINT "reminders_sent_pkey" PRIMARY KEY ("user_id", "event_key", "offset_minutes");



ALTER TABLE ONLY "public"."rental_groups"
    ADD CONSTRAINT "rental_groups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rentals"
    ADD CONSTRAINT "rentals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."reservations"
    ADD CONSTRAINT "reservations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."schedule_settings"
    ADD CONSTRAINT "schedule_settings_pkey" PRIMARY KEY ("tenant_id");



ALTER TABLE ONLY "public"."site_player_regnums"
    ADD CONSTRAINT "site_player_regnums_pkey" PRIMARY KEY ("slug");



ALTER TABLE ONLY "public"."slot_watches"
    ADD CONSTRAINT "slot_watches_pkey" PRIMARY KEY ("user_id", "date");



ALTER TABLE ONLY "public"."team_colors"
    ADD CONSTRAINT "team_colors_pkey" PRIMARY KEY ("user_id", "team");



ALTER TABLE ONLY "public"."teams"
    ADD CONSTRAINT "teams_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."teams"
    ADD CONSTRAINT "teams_tenant_id_name_key" UNIQUE ("tenant_id", "name");



ALTER TABLE ONLY "public"."teams"
    ADD CONSTRAINT "teams_tenant_id_site_slug_key" UNIQUE ("tenant_id", "site_slug");



ALTER TABLE ONLY "public"."tenants"
    ADD CONSTRAINT "tenants_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."tenants"
    ADD CONSTRAINT "tenants_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tenants"
    ADD CONSTRAINT "tenants_public_slug_key" UNIQUE ("public_slug");



ALTER TABLE ONLY "public"."time_blocks"
    ADD CONSTRAINT "time_blocks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."venues"
    ADD CONSTRAINT "venues_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."venues"
    ADD CONSTRAINT "venues_tenant_id_slug_key" UNIQUE ("tenant_id", "slug");



CREATE UNIQUE INDEX "clubs_tenant_site_slug_key" ON "public"."clubs" USING "btree" ("tenant_id", "site_slug") WHERE ("site_slug" IS NOT NULL);



CREATE INDEX "duty_assignments_tenant_user" ON "public"."duty_assignments" USING "btree" ("tenant_id", "user_id");



CREATE INDEX "duty_periods_tenant_starts_on" ON "public"."duty_periods" USING "btree" ("tenant_id", "starts_on");



CREATE INDEX "league_matches_competition_idx" ON "public"."league_matches" USING "btree" ("tenant_id", "competition_slug");



CREATE INDEX "match_player_results_player_idx" ON "public"."match_player_results" USING "btree" ("tenant_id", "player_site_id");



CREATE INDEX "matches_date_idx" ON "public"."priority_slots" USING "btree" ("date");



CREATE INDEX "message_recipients_tenant_user" ON "public"."message_recipients" USING "btree" ("tenant_id", "user_id", "read_at");



CREATE INDEX "messages_tenant_kind_created" ON "public"."messages" USING "btree" ("tenant_id", "kind", "created_at");



CREATE INDEX "messages_tenant_on_date" ON "public"."messages" USING "btree" ("tenant_id", "on_date");



CREATE INDEX "notification_jobs_due_idx" ON "public"."notification_jobs" USING "btree" ("run_at");



CREATE UNIQUE INDEX "player_group_one_membership" ON "public"."player_group_members" USING "btree" ("user_id") WHERE ("status" = 'member'::"text");



CREATE UNIQUE INDEX "priority_slots_import_key_idx" ON "public"."priority_slots" USING "btree" ("tenant_id", "import_key");



CREATE INDEX "priority_slots_parent_idx" ON "public"."priority_slots" USING "btree" ("parent_id");



CREATE UNIQUE INDEX "profiles_regnum_tenant_idx" ON "public"."profiles" USING "btree" ("tenant_id", "regnum") WHERE ("regnum" IS NOT NULL);



CREATE INDEX "profiles_tenant_idx" ON "public"."profiles" USING "btree" ("tenant_id");



CREATE INDEX "rentals_group_idx" ON "public"."rentals" USING "btree" ("group_id") WHERE ("group_id" IS NOT NULL);



CREATE UNIQUE INDEX "rentals_parent_date_idx" ON "public"."rentals" USING "btree" ("parent_id", "date") WHERE ("parent_id" IS NOT NULL);



CREATE INDEX "reservations_date_idx" ON "public"."reservations" USING "btree" ("date");



CREATE INDEX "reservations_player_idx" ON "public"."reservations" USING "btree" ("player_id", "date");



CREATE UNIQUE INDEX "reservations_slot_live_idx" ON "public"."reservations" USING "btree" ("date", "block_id", "lane") WHERE ("cancelled_at" IS NULL);



CREATE INDEX "slot_watches_day_idx" ON "public"."slot_watches" USING "btree" ("tenant_id", "date");



CREATE OR REPLACE TRIGGER "block_deactivated" AFTER UPDATE OF "active" ON "public"."time_blocks" FOR EACH ROW WHEN (("old"."active" AND (NOT "new"."active"))) EXECUTE FUNCTION "public"."cascade_schedule_change"();



CREATE OR REPLACE TRIGGER "fcm_token_claim" AFTER INSERT OR UPDATE OF "fcm_token" ON "public"."profiles" FOR EACH ROW WHEN (("new"."fcm_token" IS NOT NULL)) EXECUTE FUNCTION "public"."fcm_token_claim"();



CREATE OR REPLACE TRIGGER "match_exceptions_enqueue_calendar" AFTER INSERT OR DELETE OR UPDATE ON "public"."match_exceptions" FOR EACH ROW EXECUTE FUNCTION "public"."match_exceptions_enqueue_calendar"();



CREATE OR REPLACE TRIGGER "match_uklid_sync" AFTER INSERT OR UPDATE ON "public"."priority_slots" FOR EACH ROW EXECUTE FUNCTION "public"."sync_uklid_for_match"();



CREATE OR REPLACE TRIGGER "message_recipients_reacted_at" BEFORE UPDATE ON "public"."message_recipients" FOR EACH ROW EXECUTE FUNCTION "public"."message_recipients_stamp_reacted"();



CREATE OR REPLACE TRIGGER "notify_message_reactions" AFTER UPDATE OF "reaction", "reply" ON "public"."message_recipients" FOR EACH ROW WHEN ((("old"."reaction" IS DISTINCT FROM "new"."reaction") OR ("old"."reply" IS DISTINCT FROM "new"."reply"))) EXECUTE FUNCTION "public"."notify_webhook"();



CREATE OR REPLACE TRIGGER "notify_messages" AFTER INSERT ON "public"."messages" FOR EACH ROW EXECUTE FUNCTION "public"."notify_webhook"();



CREATE OR REPLACE TRIGGER "notify_player_group_members" AFTER INSERT OR UPDATE ON "public"."player_group_members" FOR EACH ROW EXECUTE FUNCTION "public"."notify_webhook"();



CREATE OR REPLACE TRIGGER "notify_profiles" AFTER INSERT ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."notify_webhook"();



CREATE OR REPLACE TRIGGER "notify_reservations" AFTER INSERT OR UPDATE ON "public"."reservations" FOR EACH ROW EXECUTE FUNCTION "public"."notify_webhook"();



CREATE OR REPLACE TRIGGER "notify_tenants" AFTER INSERT ON "public"."tenants" FOR EACH ROW EXECUTE FUNCTION "public"."notify_webhook"();



CREATE OR REPLACE TRIGGER "override_changed" AFTER INSERT OR DELETE OR UPDATE ON "public"."day_overrides" FOR EACH ROW EXECUTE FUNCTION "public"."cascade_schedule_change"();



CREATE OR REPLACE TRIGGER "priority_conflicts" AFTER INSERT OR UPDATE ON "public"."priority_slots" FOR EACH ROW EXECUTE FUNCTION "public"."cancel_res_for_priority"();



CREATE OR REPLACE TRIGGER "priority_slots_enqueue_calendar" AFTER INSERT OR DELETE OR UPDATE ON "public"."priority_slots" FOR EACH ROW EXECUTE FUNCTION "public"."priority_slots_enqueue_calendar"();



CREATE OR REPLACE TRIGGER "priority_slots_hand_edit" BEFORE UPDATE ON "public"."priority_slots" FOR EACH ROW EXECUTE FUNCTION "public"."priority_slots_mark_hand_edit"();



CREATE OR REPLACE TRIGGER "rental_conflicts" AFTER INSERT OR DELETE OR UPDATE ON "public"."rentals" FOR EACH ROW EXECUTE FUNCTION "public"."cancel_res_for_rental"();



CREATE OR REPLACE TRIGGER "rental_exception_guard" BEFORE INSERT OR UPDATE ON "public"."rentals" FOR EACH ROW WHEN (("new"."parent_id" IS NOT NULL)) EXECUTE FUNCTION "public"."rental_exception_guard"();



CREATE OR REPLACE TRIGGER "rental_group_changed" AFTER UPDATE ON "public"."rental_groups" FOR EACH ROW EXECUTE FUNCTION "public"."rental_group_changed"();



CREATE OR REPLACE TRIGGER "rental_group_guard" BEFORE INSERT OR UPDATE ON "public"."rentals" FOR EACH ROW WHEN (("new"."group_id" IS NOT NULL)) EXECUTE FUNCTION "public"."rental_group_guard"();



CREATE OR REPLACE TRIGGER "rental_group_prune" AFTER DELETE ON "public"."rentals" FOR EACH ROW WHEN (("old"."group_id" IS NOT NULL)) EXECUTE FUNCTION "public"."rental_group_prune"();



CREATE OR REPLACE TRIGGER "rental_series_changed" AFTER UPDATE ON "public"."rentals" FOR EACH ROW WHEN (("old"."parent_id" IS NULL)) EXECUTE FUNCTION "public"."rental_series_changed"();



CREATE OR REPLACE TRIGGER "reservations_end_watch" AFTER INSERT ON "public"."reservations" FOR EACH ROW EXECUTE FUNCTION "public"."slot_watches_end_on_booking"();



CREATE OR REPLACE TRIGGER "reservations_enqueue_calendar" AFTER INSERT OR UPDATE ON "public"."reservations" FOR EACH ROW EXECUTE FUNCTION "public"."reservations_enqueue_calendar"();



CREATE OR REPLACE TRIGGER "settings_shrink" AFTER UPDATE OF "lane_count", "training_weekdays" ON "public"."schedule_settings" FOR EACH ROW EXECUTE FUNCTION "public"."cascade_schedule_change"();



CREATE OR REPLACE TRIGGER "slot_type_conflicts" AFTER UPDATE ON "public"."priority_slot_types" FOR EACH ROW EXECUTE FUNCTION "public"."cancel_res_for_type_change"();



CREATE OR REPLACE TRIGGER "tenant_seed_defaults" AFTER INSERT ON "public"."tenants" FOR EACH ROW EXECUTE FUNCTION "public"."seed_tenant_defaults"();



CREATE OR REPLACE TRIGGER "time_blocks_enqueue_calendar" AFTER UPDATE OF "starts_at", "ends_at" ON "public"."time_blocks" FOR EACH ROW WHEN ((("old"."starts_at" IS DISTINCT FROM "new"."starts_at") OR ("old"."ends_at" IS DISTINCT FROM "new"."ends_at"))) EXECUTE FUNCTION "public"."time_blocks_enqueue_calendar"();



ALTER TABLE ONLY "public"."calendar_teams"
    ADD CONSTRAINT "calendar_teams_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."clubs"
    ADD CONSTRAINT "clubs_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."day_overrides"
    ADD CONSTRAINT "day_overrides_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."day_overrides"
    ADD CONSTRAINT "day_overrides_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."duty_assignments"
    ADD CONSTRAINT "duty_assignments_assigned_by_fkey" FOREIGN KEY ("assigned_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."duty_assignments"
    ADD CONSTRAINT "duty_assignments_period_id_fkey" FOREIGN KEY ("period_id") REFERENCES "public"."duty_periods"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."duty_assignments"
    ADD CONSTRAINT "duty_assignments_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."duty_assignments"
    ADD CONSTRAINT "duty_assignments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."duty_periods"
    ADD CONSTRAINT "duty_periods_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."duty_periods"
    ADD CONSTRAINT "duty_periods_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."duty_seasons"
    ADD CONSTRAINT "duty_seasons_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."duty_seasons"
    ADD CONSTRAINT "duty_seasons_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."federation_sync"
    ADD CONSTRAINT "federation_sync_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."google_calendar_links"
    ADD CONSTRAINT "google_calendar_links_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."google_calendar_tokens"
    ADD CONSTRAINT "google_calendar_tokens_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_matches"
    ADD CONSTRAINT "league_matches_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_player_results"
    ADD CONSTRAINT "league_player_results_match_id_fkey" FOREIGN KEY ("match_id") REFERENCES "public"."league_matches"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_player_results"
    ADD CONSTRAINT "league_player_results_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."match_exceptions"
    ADD CONSTRAINT "match_exceptions_match_id_fkey" FOREIGN KEY ("match_id") REFERENCES "public"."priority_slots"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."match_exceptions"
    ADD CONSTRAINT "match_exceptions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."match_player_results"
    ADD CONSTRAINT "match_player_results_match_id_fkey" FOREIGN KEY ("match_id") REFERENCES "public"."priority_slots"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."match_player_results"
    ADD CONSTRAINT "match_player_results_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."match_results"
    ADD CONSTRAINT "match_results_match_id_fkey" FOREIGN KEY ("match_id") REFERENCES "public"."priority_slots"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."match_results"
    ADD CONSTRAINT "match_results_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."priority_slots"
    ADD CONSTRAINT "matches_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."message_recipients"
    ADD CONSTRAINT "message_recipients_message_id_fkey" FOREIGN KEY ("message_id") REFERENCES "public"."messages"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."message_recipients"
    ADD CONSTRAINT "message_recipients_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."message_recipients"
    ADD CONSTRAINT "message_recipients_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_block_id_fkey" FOREIGN KEY ("block_id") REFERENCES "public"."time_blocks"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."oauth_nonces"
    ADD CONSTRAINT "oauth_nonces_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."player_group_members"
    ADD CONSTRAINT "player_group_members_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."player_groups"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."player_group_members"
    ADD CONSTRAINT "player_group_members_invited_by_fkey" FOREIGN KEY ("invited_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."player_group_members"
    ADD CONSTRAINT "player_group_members_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."player_group_members"
    ADD CONSTRAINT "player_group_members_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."player_groups"
    ADD CONSTRAINT "player_groups_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."player_groups"
    ADD CONSTRAINT "player_groups_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."priority_slot_types"
    ADD CONSTRAINT "priority_slot_types_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."priority_slots"
    ADD CONSTRAINT "priority_slots_parent_id_fkey" FOREIGN KEY ("parent_id") REFERENCES "public"."priority_slots"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."priority_slots"
    ADD CONSTRAINT "priority_slots_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."priority_slots"
    ADD CONSTRAINT "priority_slots_type_id_fkey" FOREIGN KEY ("type_id") REFERENCES "public"."priority_slot_types"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_club_id_fkey" FOREIGN KEY ("club_id") REFERENCES "public"."clubs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_home_tenant_id_fkey" FOREIGN KEY ("home_tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."reminders_sent"
    ADD CONSTRAINT "reminders_sent_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rental_groups"
    ADD CONSTRAINT "rental_groups_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."rental_groups"
    ADD CONSTRAINT "rental_groups_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rentals"
    ADD CONSTRAINT "rentals_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."rentals"
    ADD CONSTRAINT "rentals_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."rental_groups"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rentals"
    ADD CONSTRAINT "rentals_parent_id_fkey" FOREIGN KEY ("parent_id") REFERENCES "public"."rentals"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rentals"
    ADD CONSTRAINT "rentals_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."reservations"
    ADD CONSTRAINT "reservations_block_id_fkey" FOREIGN KEY ("block_id") REFERENCES "public"."time_blocks"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."reservations"
    ADD CONSTRAINT "reservations_cancelled_by_fkey" FOREIGN KEY ("cancelled_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."reservations"
    ADD CONSTRAINT "reservations_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."reservations"
    ADD CONSTRAINT "reservations_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."reservations"
    ADD CONSTRAINT "reservations_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."schedule_settings"
    ADD CONSTRAINT "schedule_settings_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."slot_watches"
    ADD CONSTRAINT "slot_watches_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."slot_watches"
    ADD CONSTRAINT "slot_watches_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."team_colors"
    ADD CONSTRAINT "team_colors_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."teams"
    ADD CONSTRAINT "teams_club_id_fkey" FOREIGN KEY ("club_id") REFERENCES "public"."clubs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."teams"
    ADD CONSTRAINT "teams_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."time_blocks"
    ADD CONSTRAINT "time_blocks_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."venues"
    ADD CONSTRAINT "venues_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE "public"."app_config" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "app_config_select" ON "public"."app_config" FOR SELECT USING (true);



CREATE POLICY "blocks_delete" ON "public"."time_blocks" FOR DELETE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



CREATE POLICY "blocks_insert" ON "public"."time_blocks" FOR INSERT WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



CREATE POLICY "blocks_select" ON "public"."time_blocks" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



CREATE POLICY "blocks_update" ON "public"."time_blocks" FOR UPDATE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"())) WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



ALTER TABLE "public"."calendar_teams" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "calendar_teams_own" ON "public"."calendar_teams" FOR SELECT USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."clubs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "clubs_select" ON "public"."clubs" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



CREATE POLICY "clubs_write" ON "public"."clubs" USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"())) WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



ALTER TABLE "public"."day_overrides" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."duty_assignments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "duty_assignments_select" ON "public"."duty_assignments" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



ALTER TABLE "public"."duty_periods" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "duty_periods_select" ON "public"."duty_periods" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



ALTER TABLE "public"."duty_seasons" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "duty_seasons_select" ON "public"."duty_seasons" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



ALTER TABLE "public"."federation_sync" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "federation_sync_select" ON "public"."federation_sync" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



ALTER TABLE "public"."google_calendar_links" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "google_calendar_links_select_own" ON "public"."google_calendar_links" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."google_calendar_tokens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."league_matches" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "league_matches_select" ON "public"."league_matches" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



ALTER TABLE "public"."league_player_results" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "league_player_results_select" ON "public"."league_player_results" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



ALTER TABLE "public"."match_exceptions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "match_exceptions_own" ON "public"."match_exceptions" FOR SELECT USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."match_player_results" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "match_player_results_select" ON "public"."match_player_results" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



ALTER TABLE "public"."match_results" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "match_results_select" ON "public"."match_results" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



ALTER TABLE "public"."message_recipients" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "message_recipients_select" ON "public"."message_recipients" FOR SELECT USING ((("tenant_id" = ( SELECT "public"."current_tenant_id"() AS "current_tenant_id")) AND ((("user_id" = ( SELECT "auth"."uid"() AS "uid")) AND ( SELECT "public"."is_approved"() AS "is_approved") AND (NOT ( SELECT "public"."is_kiosk"() AS "is_kiosk"))) OR ("message_id" IN ( SELECT "public"."visible_recipient_message_ids"() AS "visible_recipient_message_ids")))));



CREATE POLICY "message_recipients_update_own" ON "public"."message_recipients" FOR UPDATE USING ((("user_id" = "auth"."uid"()) AND "public"."is_approved"() AND (NOT "public"."is_kiosk"()))) WITH CHECK ((("user_id" = "auth"."uid"()) AND "public"."is_approved"() AND (NOT "public"."is_kiosk"())));



ALTER TABLE "public"."messages" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "messages_select" ON "public"."messages" FOR SELECT USING ((("tenant_id" = ( SELECT "public"."current_tenant_id"() AS "current_tenant_id")) AND ("id" IN ( SELECT "public"."visible_message_ids"() AS "visible_message_ids"))));



ALTER TABLE "public"."notification_jobs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."oauth_nonces" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "overrides_delete" ON "public"."day_overrides" FOR DELETE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



CREATE POLICY "overrides_insert" ON "public"."day_overrides" FOR INSERT WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



CREATE POLICY "overrides_select" ON "public"."day_overrides" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



CREATE POLICY "overrides_update" ON "public"."day_overrides" FOR UPDATE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"())) WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



ALTER TABLE "public"."player_group_members" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "player_group_members_select" ON "public"."player_group_members" FOR SELECT USING ((("user_id" = "auth"."uid"()) OR ("group_id" = "public"."my_group_id"()) OR ("public"."is_admin"() AND ("tenant_id" = "public"."current_tenant_id"()))));



ALTER TABLE "public"."player_groups" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "priority_delete" ON "public"."priority_slots" FOR DELETE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



CREATE POLICY "priority_insert" ON "public"."priority_slots" FOR INSERT WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



CREATE POLICY "priority_select" ON "public"."priority_slots" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



ALTER TABLE "public"."priority_slot_types" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."priority_slots" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "priority_update" ON "public"."priority_slots" FOR UPDATE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"())) WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles_select" ON "public"."profiles" FOR SELECT USING ((("id" = "auth"."uid"()) OR ("public"."is_admin"() AND ("tenant_id" = "public"."current_tenant_id"()))));



CREATE POLICY "profiles_update_own" ON "public"."profiles" FOR UPDATE USING (("id" = "auth"."uid"())) WITH CHECK (("id" = "auth"."uid"()));



ALTER TABLE "public"."reminders_sent" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rental_groups" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "rental_groups_delete" ON "public"."rental_groups" FOR DELETE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



CREATE POLICY "rental_groups_insert" ON "public"."rental_groups" FOR INSERT WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



CREATE POLICY "rental_groups_select" ON "public"."rental_groups" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



CREATE POLICY "rental_groups_update" ON "public"."rental_groups" FOR UPDATE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"())) WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



ALTER TABLE "public"."rentals" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "rentals_delete" ON "public"."rentals" FOR DELETE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



CREATE POLICY "rentals_insert" ON "public"."rentals" FOR INSERT WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



CREATE POLICY "rentals_select" ON "public"."rentals" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



CREATE POLICY "rentals_update" ON "public"."rentals" FOR UPDATE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"())) WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



ALTER TABLE "public"."reservations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "reservations_select" ON "public"."reservations" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



ALTER TABLE "public"."schedule_settings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "settings_select" ON "public"."schedule_settings" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



CREATE POLICY "settings_update" ON "public"."schedule_settings" FOR UPDATE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"())) WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



ALTER TABLE "public"."site_player_regnums" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "slot_types_delete" ON "public"."priority_slot_types" FOR DELETE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"() AND (NOT "builtin")));



CREATE POLICY "slot_types_insert" ON "public"."priority_slot_types" FOR INSERT WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



CREATE POLICY "slot_types_select" ON "public"."priority_slot_types" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



CREATE POLICY "slot_types_update" ON "public"."priority_slot_types" FOR UPDATE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"())) WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



ALTER TABLE "public"."slot_watches" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "slot_watches_select" ON "public"."slot_watches" FOR SELECT USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."team_colors" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "team_colors_own" ON "public"."team_colors" FOR SELECT USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."teams" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "teams_select" ON "public"."teams" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



ALTER TABLE "public"."tenants" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tenants_select" ON "public"."tenants" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."time_blocks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."venues" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "venues_select" ON "public"."venues" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



REVOKE ALL ON FUNCTION "public"."_group_drop_member"("p_group" "uuid", "p_user" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_group_drop_member"("p_group" "uuid", "p_user" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."add_special_block"("p_starts_at" time without time zone, "p_ends_at" time without time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."add_special_block"("p_starts_at" time without time zone, "p_ends_at" time without time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."add_special_block"("p_starts_at" time without time zone, "p_ends_at" time without time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_list_tenants"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_list_tenants"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_list_tenants"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."apply_federation_discovery"("p_tenant" "uuid", "p_clubs" "jsonb", "p_teams" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."apply_federation_discovery"("p_tenant" "uuid", "p_clubs" "jsonb", "p_teams" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."apply_federation_matches"("p_tenant" "uuid", "p_competition_slug" "text", "p_matches" "jsonb", "p_keep_ids" integer[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."apply_federation_matches"("p_tenant" "uuid", "p_competition_slug" "text", "p_matches" "jsonb", "p_keep_ids" integer[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."apply_federation_result"("p_tenant" "uuid", "p_site_match_id" integer, "p_result" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."apply_federation_result"("p_tenant" "uuid", "p_site_match_id" integer, "p_result" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."apply_league_matches"("p_tenant" "uuid", "p_competition_slug" "text", "p_matches" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."apply_league_matches"("p_tenant" "uuid", "p_competition_slug" "text", "p_matches" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."apply_league_result"("p_tenant" "uuid", "p_site_match_id" integer, "p_result" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."apply_league_result"("p_tenant" "uuid", "p_site_match_id" integer, "p_result" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."approve_tenant"("p_tenant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."approve_tenant"("p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_tenant"("p_tenant_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."backfill_calendar_jobs"("p_user" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."backfill_calendar_jobs"("p_user" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."block_day_status"("p_tenant" "uuid", "p_date" "date", "p_block_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."block_day_status"("p_tenant" "uuid", "p_date" "date", "p_block_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."can_read_message"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."can_read_message"("p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_read_message"("p_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."priority_slots" TO "authenticated";
GRANT ALL ON TABLE "public"."priority_slots" TO "service_role";



REVOKE ALL ON FUNCTION "public"."cancel_stranded_reservations"("p_tenant" "uuid", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cancel_stranded_reservations"("p_tenant" "uuid", "p_note" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."cascade_schedule_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."cascade_schedule_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cascade_schedule_change"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."claim_freed_spot_watchers"("p_reservation" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."claim_freed_spot_watchers"("p_reservation" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."consume_calendar_nonce"("p_nonce" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."consume_calendar_nonce"("p_nonce" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."contacts"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."contacts"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."contacts"() TO "service_role";



GRANT ALL ON TABLE "public"."reservations" TO "authenticated";
GRANT ALL ON TABLE "public"."reservations" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT UPDATE("display_name") ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("fcm_token") ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("own_color") ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("followed_teams") ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("default_view") ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("notify_before_minutes") ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("phone") ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("show_email") ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("show_phone") ON TABLE "public"."profiles" TO "authenticated";



GRANT ALL ON FUNCTION "public"."create_tenant_and_register"("p_tenant_name" "text", "p_display_name" "text", "p_nick" "text", "p_phone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_tenant_and_register"("p_tenant_name" "text", "p_display_name" "text", "p_nick" "text", "p_phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_tenant_and_register"("p_tenant_name" "text", "p_display_name" "text", "p_nick" "text", "p_phone" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_day_override"("p_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_day_override"("p_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_day_override"("p_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_placeholder_player"("p_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_placeholder_player"("p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_placeholder_player"("p_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."due_duty_reminders"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."due_duty_reminders"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."due_reminders"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."due_reminders"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."duty_edit_days_gate"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."duty_edit_days_gate"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."duty_edit_gate"("p_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."duty_edit_gate"("p_date" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."duty_gate"("p_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."duty_gate"("p_date" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."duty_generate"("p_from" "date", "p_days" smallint, "p_until" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."duty_generate"("p_from" "date", "p_days" smallint, "p_until" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."duty_generate"("p_from" "date", "p_days" smallint, "p_until" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."duty_period_delete"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."duty_period_delete"("p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."duty_period_delete"("p_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."duty_period_save"("p_id" "uuid", "p_starts_on" "date", "p_ends_on" "date", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."duty_period_save"("p_id" "uuid", "p_starts_on" "date", "p_ends_on" "date", "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."duty_period_save"("p_id" "uuid", "p_starts_on" "date", "p_ends_on" "date", "p_note" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."duty_periods_delete_unassigned"("p_from" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."duty_periods_delete_unassigned"("p_from" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."duty_periods_delete_unassigned"("p_from" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."duty_season_delete"("p_started_on" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."duty_season_delete"("p_started_on" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."duty_season_delete"("p_started_on" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."duty_season_start"("p_started_on" "date", "p_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."duty_season_start"("p_started_on" "date", "p_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."duty_season_start"("p_started_on" "date", "p_name" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."duty_set_assignees"("p_period" "uuid", "p_users" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."duty_set_assignees"("p_period" "uuid", "p_users" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."duty_set_assignees"("p_period" "uuid", "p_users" "uuid"[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."enqueue_calendar_sync"("p_user" "uuid", "p_reservation" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."enqueue_calendar_sync"("p_user" "uuid", "p_reservation" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."enqueue_federation_jobs"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."enqueue_federation_jobs"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."enqueue_federation_match"("p_tenant" "uuid", "p_site_match_id" integer, "p_slug" "text", "p_run_at" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."enqueue_federation_match"("p_tenant" "uuid", "p_site_match_id" integer, "p_slug" "text", "p_run_at" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."enqueue_federation_venue"("p_tenant" "uuid", "p_slug" "text", "p_delay" interval) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."enqueue_federation_venue"("p_tenant" "uuid", "p_slug" "text", "p_delay" interval) TO "service_role";



REVOKE ALL ON FUNCTION "public"."enqueue_match_calendar_sync"("p_user" "uuid", "p_match" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."enqueue_match_calendar_sync"("p_user" "uuid", "p_match" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."enqueue_notification"("p_kind" "text", "p_dedupe_key" "text", "p_payload" "jsonb", "p_delay" interval) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."enqueue_notification"("p_kind" "text", "p_dedupe_key" "text", "p_payload" "jsonb", "p_delay" interval) TO "service_role";



REVOKE ALL ON FUNCTION "public"."fcm_token_claim"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fcm_token_claim"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."federation_description"("p_competition" "text", "p_round" integer, "p_is_away" boolean, "p_venue" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."federation_description"("p_competition" "text", "p_round" integer, "p_is_away" boolean, "p_venue" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."federation_last_error"("p_tenant" "uuid", "p_report" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."federation_last_error"("p_tenant" "uuid", "p_report" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."federation_live_report"("p_tenant" "uuid", "p_report" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."federation_live_report"("p_tenant" "uuid", "p_report" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."federation_match_switched_off"("p_tenant" "uuid", "p_home_slug" "text", "p_away_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."federation_match_switched_off"("p_tenant" "uuid", "p_home_slug" "text", "p_away_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."federation_refresh_error"("p_tenant" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."federation_refresh_error"("p_tenant" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."federation_sync_progress"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."federation_sync_progress"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."federation_sync_progress"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."group_accept"("p_group" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."group_accept"("p_group" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."group_accept"("p_group" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."group_cancel_invite"("p_group" "uuid", "p_user" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."group_cancel_invite"("p_group" "uuid", "p_user" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."group_cancel_invite"("p_group" "uuid", "p_user" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."group_decline"("p_group" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."group_decline"("p_group" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."group_decline"("p_group" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."group_invite"("p_user" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."group_invite"("p_user" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."group_invite"("p_user" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."group_leave"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."group_leave"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."group_leave"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."group_remove_member"("p_user" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."group_remove_member"("p_user" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."group_remove_member"("p_user" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_on_duty"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_on_duty"() TO "service_role";



GRANT ALL ON FUNCTION "public"."kiosk_password_target"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."kiosk_password_target"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."kiosk_password_target"("p_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."league_competition_is_ours"("p_tenant" "uuid", "p_competition_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."league_competition_is_ours"("p_tenant" "uuid", "p_competition_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."league_drop_orphan_jobs"("p_tenant" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."league_drop_orphan_jobs"("p_tenant" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."mark_reminder_sent"("p_user" "uuid", "p_event_key" "text", "p_offset" integer, "p_starts_at" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."mark_reminder_sent"("p_user" "uuid", "p_event_key" "text", "p_offset" integer, "p_starts_at" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."match_calendar_followers"("p_tenant" "uuid", "p_home" "text", "p_away" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."match_calendar_followers"("p_tenant" "uuid", "p_home" "text", "p_away" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."match_exceptions_enqueue_calendar"() TO "anon";
GRANT ALL ON FUNCTION "public"."match_exceptions_enqueue_calendar"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."match_exceptions_enqueue_calendar"() TO "service_role";



GRANT ALL ON FUNCTION "public"."merge_placeholder_player"("p_placeholder_id" "uuid", "p_target_id" "uuid", "p_display_name" "text", "p_nick" "text", "p_club_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."merge_placeholder_player"("p_placeholder_id" "uuid", "p_target_id" "uuid", "p_display_name" "text", "p_nick" "text", "p_club_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."merge_placeholder_player"("p_placeholder_id" "uuid", "p_target_id" "uuid", "p_display_name" "text", "p_nick" "text", "p_club_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."message_delete"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."message_delete"("p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."message_delete"("p_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."message_recipients_stamp_reacted"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."message_recipients_stamp_reacted"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."message_send"("p_kind" "text", "p_audience" "text", "p_on_date" "date", "p_block_id" "uuid", "p_title" "text", "p_body" "text", "p_expires_at" timestamp with time zone, "p_notify" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."message_send"("p_kind" "text", "p_audience" "text", "p_on_date" "date", "p_block_id" "uuid", "p_title" "text", "p_body" "text", "p_expires_at" timestamp with time zone, "p_notify" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."message_send"("p_kind" "text", "p_audience" "text", "p_on_date" "date", "p_block_id" "uuid", "p_title" "text", "p_body" "text", "p_expires_at" timestamp with time zone, "p_notify" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."message_set_kiosk"("p_id" "uuid", "p_show" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."message_set_kiosk"("p_id" "uuid", "p_show" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."message_set_kiosk"("p_id" "uuid", "p_show" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."message_set_visible_from"("p_id" "uuid", "p_from" timestamp with time zone, "p_notify" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."message_set_visible_from"("p_id" "uuid", "p_from" timestamp with time zone, "p_notify" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."message_set_visible_from"("p_id" "uuid", "p_from" timestamp with time zone, "p_notify" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."message_update"("p_id" "uuid", "p_title" "text", "p_body" "text", "p_expires_at" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."message_update"("p_id" "uuid", "p_title" "text", "p_body" "text", "p_expires_at" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."message_update"("p_id" "uuid", "p_title" "text", "p_body" "text", "p_expires_at" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."my_future_matches"("p_user" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."my_future_matches"("p_user" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."my_future_reservations"("p_user" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."my_future_reservations"("p_user" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."my_group_id"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."my_group_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."my_group_id"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."my_public_overview"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."my_public_overview"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."my_public_overview"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."my_upcoming_matches"("p_user" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."my_upcoming_matches"("p_user" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."notifications_due"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."notifications_due"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."notify_webhook_config"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."notify_webhook_config"() TO "service_role";



GRANT ALL ON FUNCTION "public"."priority_slots_enqueue_calendar"() TO "anon";
GRANT ALL ON FUNCTION "public"."priority_slots_enqueue_calendar"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."priority_slots_enqueue_calendar"() TO "service_role";



GRANT ALL ON FUNCTION "public"."priority_slots_mark_hand_edit"() TO "anon";
GRANT ALL ON FUNCTION "public"."priority_slots_mark_hand_edit"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."priority_slots_mark_hand_edit"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."prune_messages"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."prune_messages"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."prune_slot_watches"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."prune_slot_watches"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."public_tenant_id"("p_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."public_tenant_id"("p_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."public_week"("p_slug" "text", "p_monday" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."public_week"("p_slug" "text", "p_monday" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."public_week"("p_slug" "text", "p_monday" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."public_week"("p_slug" "text", "p_monday" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."record_federation_run"("p_tenant" "uuid", "p_key" "text", "p_report" "jsonb", "p_error" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_federation_run"("p_tenant" "uuid", "p_key" "text", "p_report" "jsonb", "p_error" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."refresh_match"("p_match_id" "uuid", "p_force" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."refresh_match"("p_match_id" "uuid", "p_force" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_match"("p_match_id" "uuid", "p_force" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."register_profile"("p_display_name" "text", "p_tenant_id" "uuid", "p_club_id" "uuid", "p_nick" "text", "p_phone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."register_profile"("p_display_name" "text", "p_tenant_id" "uuid", "p_club_id" "uuid", "p_nick" "text", "p_phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."register_profile"("p_display_name" "text", "p_tenant_id" "uuid", "p_club_id" "uuid", "p_nick" "text", "p_phone" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."reject_tenant"("p_tenant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reject_tenant"("p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reject_tenant"("p_tenant_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."rental_add_date"("p_rental" "uuid", "p_date" "date", "p_starts_at" time without time zone, "p_ends_at" time without time zone, "p_lanes" smallint[], "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rental_add_date"("p_rental" "uuid", "p_date" "date", "p_starts_at" time without time zone, "p_ends_at" time without time zone, "p_lanes" smallint[], "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rental_add_date"("p_rental" "uuid", "p_date" "date", "p_starts_at" time without time zone, "p_ends_at" time without time zone, "p_lanes" smallint[], "p_note" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."rental_exception_guard"() TO "anon";
GRANT ALL ON FUNCTION "public"."rental_exception_guard"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rental_exception_guard"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rental_group_changed"() TO "anon";
GRANT ALL ON FUNCTION "public"."rental_group_changed"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rental_group_changed"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rental_group_guard"() TO "anon";
GRANT ALL ON FUNCTION "public"."rental_group_guard"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rental_group_guard"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rental_group_prune"() TO "anon";
GRANT ALL ON FUNCTION "public"."rental_group_prune"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rental_group_prune"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."rental_occurrences"("p_tenant" "uuid", "p_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rental_occurrences"("p_tenant" "uuid", "p_date" "date") TO "service_role";



GRANT ALL ON TABLE "public"."rentals" TO "authenticated";
GRANT ALL ON TABLE "public"."rentals" TO "service_role";



REVOKE ALL ON FUNCTION "public"."rental_occurs"("r" "public"."rentals", "p_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rental_occurs"("r" "public"."rentals", "p_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."rental_series_changed"() TO "anon";
GRANT ALL ON FUNCTION "public"."rental_series_changed"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rental_series_changed"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."request_federation_discovery"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."request_federation_discovery"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."request_federation_discovery"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."request_federation_sync"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."request_federation_sync"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."request_federation_sync"() TO "service_role";



GRANT ALL ON FUNCTION "public"."reservations_enqueue_calendar"() TO "anon";
GRANT ALL ON FUNCTION "public"."reservations_enqueue_calendar"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."reservations_enqueue_calendar"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."same_group"("a" "uuid", "b" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."same_group"("a" "uuid", "b" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."save_placeholder_player"("p_id" "uuid", "p_display_name" "text", "p_nick" "text", "p_club_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."save_placeholder_player"("p_id" "uuid", "p_display_name" "text", "p_nick" "text", "p_club_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."save_placeholder_player"("p_id" "uuid", "p_display_name" "text", "p_nick" "text", "p_club_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."seed_demo_member"("p_email" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."seed_demo_member"("p_email" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_calendar_reminders_for"("p_user" "uuid", "p_minutes" integer[], "p_calendar" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_calendar_reminders_for"("p_user" "uuid", "p_minutes" integer[], "p_calendar" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_calendar_teams_for"("p_user" "uuid", "p_teams" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_calendar_teams_for"("p_user" "uuid", "p_teams" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_display_name"("p_user_id" "uuid", "p_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_display_name"("p_user_id" "uuid", "p_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_display_name"("p_user_id" "uuid", "p_name" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_federation_sync"("p_venue_slug" "text", "p_enabled" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_federation_sync"("p_venue_slug" "text", "p_enabled" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_federation_sync"("p_venue_slug" "text", "p_enabled" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_match_exception"("p_match" "uuid", "p_shown" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_match_exception"("p_match" "uuid", "p_shown" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_match_exception"("p_match" "uuid", "p_shown" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_public_overview"("p_slug" "text", "p_enabled" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_public_overview"("p_slug" "text", "p_enabled" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_public_overview"("p_slug" "text", "p_enabled" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_regnum"("p_user_id" "uuid", "p_regnum" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_regnum"("p_user_id" "uuid", "p_regnum" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_regnum"("p_user_id" "uuid", "p_regnum" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_team_colors_for"("p_user" "uuid", "p_colors" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_team_colors_for"("p_user" "uuid", "p_colors" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_training_color_for"("p_user" "uuid", "p_color" smallint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_training_color_for"("p_user" "uuid", "p_color" smallint) TO "service_role";



REVOKE ALL ON FUNCTION "public"."slot_watches_end_on_booking"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."slot_watches_end_on_booking"() TO "service_role";



GRANT ALL ON FUNCTION "public"."start_calendar_link"() TO "anon";
GRANT ALL ON FUNCTION "public"."start_calendar_link"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."start_calendar_link"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."switch_tenant"("p_tenant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."switch_tenant"("p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."switch_tenant"("p_tenant_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."time_blocks_enqueue_calendar"() TO "anon";
GRANT ALL ON FUNCTION "public"."time_blocks_enqueue_calendar"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."time_blocks_enqueue_calendar"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."trigger_notification_jobs"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."trigger_notification_jobs"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."unwatch_day"("p_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."unwatch_day"("p_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unwatch_day"("p_date" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_team"("p_id" "uuid", "p_name" "text", "p_club_id" "uuid", "p_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_team"("p_id" "uuid", "p_name" "text", "p_club_id" "uuid", "p_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_team"("p_id" "uuid", "p_name" "text", "p_club_id" "uuid", "p_active" boolean) TO "service_role";



GRANT ALL ON TABLE "public"."clubs" TO "authenticated";
GRANT ALL ON TABLE "public"."clubs" TO "service_role";



GRANT ALL ON FUNCTION "public"."upsert_club"("p_id" "uuid", "p_name" "text", "p_color" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_club"("p_id" "uuid", "p_name" "text", "p_color" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_club"("p_id" "uuid", "p_name" "text", "p_color" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."upsert_federation_teams"("p_tenant" "uuid", "p_teams" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."upsert_federation_teams"("p_tenant" "uuid", "p_teams" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."upsert_federation_venue"("p_tenant" "uuid", "p_venue" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."upsert_federation_venue"("p_tenant" "uuid", "p_venue" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."visible_message_ids"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."visible_message_ids"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."visible_message_ids"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."visible_recipient_message_ids"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."visible_recipient_message_ids"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."visible_recipient_message_ids"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."watch_day"("p_date" "date", "p_block_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."watch_day"("p_date" "date", "p_block_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."watch_day"("p_date" "date", "p_block_ids" "uuid"[]) TO "service_role";



GRANT ALL ON TABLE "public"."app_config" TO "service_role";
GRANT SELECT ON TABLE "public"."app_config" TO "authenticated";



GRANT SELECT ON TABLE "public"."calendar_teams" TO "authenticated";
GRANT ALL ON TABLE "public"."calendar_teams" TO "service_role";



GRANT ALL ON TABLE "public"."day_overrides" TO "authenticated";
GRANT ALL ON TABLE "public"."day_overrides" TO "service_role";



GRANT SELECT ON TABLE "public"."duty_assignments" TO "authenticated";
GRANT ALL ON TABLE "public"."duty_assignments" TO "service_role";



GRANT SELECT ON TABLE "public"."duty_periods" TO "authenticated";
GRANT ALL ON TABLE "public"."duty_periods" TO "service_role";



GRANT SELECT ON TABLE "public"."duty_seasons" TO "authenticated";
GRANT ALL ON TABLE "public"."duty_seasons" TO "service_role";



GRANT SELECT ON TABLE "public"."federation_sync" TO "authenticated";
GRANT ALL ON TABLE "public"."federation_sync" TO "service_role";



GRANT ALL ON TABLE "public"."google_calendar_links" TO "service_role";
GRANT SELECT ON TABLE "public"."google_calendar_links" TO "authenticated";



GRANT ALL ON TABLE "public"."google_calendar_tokens" TO "service_role";



GRANT ALL ON TABLE "public"."league_matches" TO "service_role";
GRANT SELECT ON TABLE "public"."league_matches" TO "authenticated";



GRANT ALL ON TABLE "public"."league_player_results" TO "service_role";
GRANT SELECT ON TABLE "public"."league_player_results" TO "authenticated";



GRANT SELECT ON TABLE "public"."match_exceptions" TO "authenticated";
GRANT ALL ON TABLE "public"."match_exceptions" TO "service_role";



GRANT SELECT ON TABLE "public"."match_player_results" TO "authenticated";
GRANT ALL ON TABLE "public"."match_player_results" TO "service_role";



GRANT SELECT ON TABLE "public"."match_results" TO "authenticated";
GRANT ALL ON TABLE "public"."match_results" TO "service_role";



GRANT ALL ON TABLE "public"."message_recipients" TO "service_role";
GRANT SELECT ON TABLE "public"."message_recipients" TO "authenticated";



GRANT UPDATE("read_at") ON TABLE "public"."message_recipients" TO "authenticated";



GRANT UPDATE("reaction") ON TABLE "public"."message_recipients" TO "authenticated";



GRANT UPDATE("reply") ON TABLE "public"."message_recipients" TO "authenticated";



GRANT ALL ON TABLE "public"."messages" TO "service_role";
GRANT SELECT ON TABLE "public"."messages" TO "authenticated";



GRANT ALL ON TABLE "public"."notification_jobs" TO "service_role";



GRANT UPDATE ON SEQUENCE "public"."notification_jobs_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."oauth_nonces" TO "service_role";



GRANT SELECT ON TABLE "public"."player_group_members" TO "authenticated";
GRANT ALL ON TABLE "public"."player_group_members" TO "service_role";



GRANT ALL ON TABLE "public"."player_groups" TO "service_role";



GRANT SELECT ON TABLE "public"."players" TO "authenticated";
GRANT ALL ON TABLE "public"."players" TO "service_role";



GRANT SELECT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."priority_slot_types" TO "authenticated";
GRANT ALL ON TABLE "public"."priority_slot_types" TO "service_role";



GRANT INSERT("name"),UPDATE("name") ON TABLE "public"."priority_slot_types" TO "authenticated";



GRANT INSERT("color"),UPDATE("color") ON TABLE "public"."priority_slot_types" TO "authenticated";



GRANT INSERT("lanes"),UPDATE("lanes") ON TABLE "public"."priority_slot_types" TO "authenticated";



GRANT ALL ON TABLE "public"."reminders_sent" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."rental_groups" TO "authenticated";
GRANT ALL ON TABLE "public"."rental_groups" TO "service_role";



GRANT ALL ON TABLE "public"."schedule_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."schedule_settings" TO "service_role";



GRANT ALL ON TABLE "public"."site_player_regnums" TO "service_role";



GRANT ALL ON TABLE "public"."slot_watches" TO "service_role";
GRANT SELECT ON TABLE "public"."slot_watches" TO "authenticated";



GRANT SELECT ON TABLE "public"."team_colors" TO "authenticated";
GRANT ALL ON TABLE "public"."team_colors" TO "service_role";



GRANT SELECT ON TABLE "public"."teams" TO "authenticated";
GRANT ALL ON TABLE "public"."teams" TO "service_role";



GRANT ALL ON TABLE "public"."tenants" TO "service_role";



GRANT SELECT("id") ON TABLE "public"."tenants" TO "authenticated";



GRANT SELECT("name") ON TABLE "public"."tenants" TO "authenticated";



GRANT SELECT("status") ON TABLE "public"."tenants" TO "authenticated";



GRANT ALL ON TABLE "public"."time_blocks" TO "authenticated";
GRANT ALL ON TABLE "public"."time_blocks" TO "service_role";



GRANT SELECT ON TABLE "public"."venues" TO "authenticated";
GRANT ALL ON TABLE "public"."venues" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";







