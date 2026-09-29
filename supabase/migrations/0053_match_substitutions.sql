-- A substitution on the federation's match detail ("od 41. hodu Miloš Vážan"):
-- the site keeps the starter's line and lists who took over apart from it,
-- so the change rides on the starter's row in match_player_results.
-- Idempotent; apply_federation_result is 0045's with the four new columns.
alter table match_player_results
  add column if not exists sub_name text,
  add column if not exists sub_site_id integer,
  add column if not exists sub_slug text,
  add column if not exists sub_from_throw smallint;

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
