-- 0067 — the kiosk's status line beside the clock (Správa → Kiosk →
-- Stavový řádek): today's weather and whose name day it is.
--
-- kiosk_weather shows the weather for kiosk_weather_place — a label the
-- admin picked (the alley's own venue, or a place found by name) and its
-- coordinates; the kiosk asks Open-Meteo itself. kiosk_nameday shows the
-- Czech name day (a calendar in the app, nothing stored). Both off by
-- default.
--
-- Re-runnable on purpose, like 0064 and 0065.

alter table schedule_settings
  add column if not exists kiosk_weather boolean not null default false,
  add column if not exists kiosk_weather_place text,
  add column if not exists kiosk_weather_lat double precision,
  add column if not exists kiosk_weather_lon double precision,
  add column if not exists kiosk_nameday boolean not null default false;

-- The place comes whole (coordinates in pairs, on Earth, a sane label).
do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'schedule_settings_kiosk_weather_place_check') then
    alter table schedule_settings
      add constraint schedule_settings_kiosk_weather_place_check check (
        (kiosk_weather_lat is null) = (kiosk_weather_lon is null)
        and (kiosk_weather_lat is null or kiosk_weather_lat between -90 and 90)
        and (kiosk_weather_lon is null or kiosk_weather_lon between -180 and 180)
        and (kiosk_weather_place is null
             or char_length(kiosk_weather_place) between 1 and 200));
  end if;
end $$;

-- The public overview (0043) keeps handing out only what it always did,
-- now as an allow-list of its six settings: no kiosk option — these, nor
-- those of the parallel kiosk branches (0066–0069) — ever reaches anon,
-- whichever of those migrations runs last.
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
    -- An allow-list, not a mask: the six settings the public board reads
    -- (the tenancy suite pins the set), so a column added later — every
    -- kiosk option is the admin's — never reaches anon by default.
    'settings', (select jsonb_build_object(
                          'lane_count', s.lane_count,
                          'training_weekdays', s.training_weekdays,
                          'booking_horizon_days', s.booking_horizon_days,
                          'max_active_reservations', s.max_active_reservations,
                          'kiosk_dark', s.kiosk_dark,
                          'kiosk_fit_day', s.kiosk_fit_day)
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
