-- 0066 — the kiosk's stream window (Správa → Kiosk → Stream zápasu).
--
-- The federation site hands a YouTube link out with a match
-- (priority_slots.video_url). With kiosk_stream on, the kiosk shows the
-- match that is on air in a floating window beside the board — movable,
-- resizable, collapsible by the visitor, untouched by the idle reset.
-- kiosk_stream_corner is where it first appears (tl/tr/bl/br; bottom left
-- by default, the drawer being on the right), kiosk_stream_width its first
-- width in percent of the screen (16:9 gives the height).
--
-- Re-runnable on purpose, like 0064 and 0065.

alter table schedule_settings
  add column if not exists kiosk_stream boolean not null default false,
  add column if not exists kiosk_stream_corner text not null default 'bl'
    constraint schedule_settings_kiosk_stream_corner_check
    check (kiosk_stream_corner in ('tl', 'tr', 'bl', 'br')),
  add column if not exists kiosk_stream_width smallint not null default 35
    constraint schedule_settings_kiosk_stream_width_check
    check (kiosk_stream_width between 20 and 60);

-- The public overview (0043) keeps handing out only what it always did:
-- the kiosk's choices are the admin's, not anon's. The status line's
-- columns (0067, weather and name day, a parallel branch) are masked here
-- too, so whichever of the two migrations runs last, neither set reaches
-- anon. The kiosk warning (0068, a third parallel branch) is masked too.
create or replace function public_week(p_slug text, p_monday date) returns jsonb
    language plpgsql stable security definer set search_path = public as $$
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
                          - 'kiosk_drawer_open' - 'kiosk_drawer_columns'
                          - 'kiosk_notices_share' - 'kiosk_zapis_percent'
                          - 'kiosk_weeks_back' - 'kiosk_weeks_ahead'
                          - 'kiosk_panel_enabled' - 'kiosk_past_days'
                          - 'kiosk_notices_rotation_seconds'
                          - 'kiosk_live_rotation_seconds'
                          - 'kiosk_idle_seconds'
                          - 'kiosk_live_layout' - 'kiosk_follow_board'
                          - 'kiosk_live_refresh_seconds'
                          - 'kiosk_visible_days' - 'kiosk_font_size'
                          - 'kiosk_animations' - 'kiosk_low_res'
                          - 'kiosk_stream' - 'kiosk_stream_corner'
                          - 'kiosk_stream_width'
                          - 'kiosk_weather' - 'kiosk_weather_place'
                          - 'kiosk_weather_lat' - 'kiosk_weather_lon'
                          - 'kiosk_nameday'
                          - 'kiosk_warning'
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

-- ---------------------------------------------- when a result was decided
-- The window streams on for half an hour after the result — counted from
-- when the server FIRST saw the match decided, not from its last read:
-- fetched_at moves with every re-read (the app's ⟳ on a finished match,
-- 0062), and would reopen the window hours later. Stamped once by
-- apply_federation_result (0053's body, this one column more), never moved.
alter table match_results
  add column if not exists decided_at timestamptz;
update match_results
   set decided_at = fetched_at
 where decided_at is null and status in ('finished', 'forfeit');

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
     home_set_points, away_set_points, fetched_at, decided_at)
  values
    (v_row.id, p_tenant, p_result->>'status',
     coalesce(p_result->>'match_type', ''), coalesce(p_result->>'discipline', ''),
     (v_home->>'points')::numeric, (v_away->>'points')::numeric,
     (v_home->>'total')::integer, (v_away->>'total')::integer,
     (v_home->>'fulls')::integer, (v_away->>'fulls')::integer,
     (v_home->>'spares')::integer, (v_away->>'spares')::integer,
     (v_home->>'errors')::integer, (v_away->>'errors')::integer,
     (v_home->>'set_points')::numeric, (v_away->>'set_points')::numeric, now(),
     -- clock_timestamp, not now(): two applies in one transaction (the
     -- tenancy suite) must be able to tell a stamp kept from one re-set.
     case when p_result->>'status' in ('finished', 'forfeit')
          then clock_timestamp() end)
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
    fetched_at = now(),
    decided_at = coalesce(r.decided_at, excluded.decided_at);

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
