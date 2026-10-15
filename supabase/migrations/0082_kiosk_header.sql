-- 0082 — the kiosk's header modules (Správa → Kiosk → Záhlaví): every
-- module of the status bar but the clock and today's matches is off, left
-- (after the clock) or right (before „Rezervace tréninku“), in an order.
-- One jsonb column holds it:
--
--   {"modules": [{"id": "weather", "side": "left"}, …]}
--
-- The modules are weather (0067), nameday (0067), duty (the canteen duty,
-- 0073) and notices (Nástěnka); the array's order is their order on a
-- side. kiosk_header_valid checks the shape, not the ids: the app keeps an
-- id it does not know and writes it back unchanged, so a later module
-- needs no migration. kiosk_weather_title is the weather's title on the
-- kiosk, the place the admin types („Brno“; the kiosk adds the colon all
-- its titles have); null shows „Počasí“. kiosk_weather_items is what the
-- weather shows beside the temperature now, which it always shows: today's
-- high and low (range), the feels-like temperature (feels), the wind
-- (wind), today's rain or snow (rain). The default is what the kiosk
-- showed before — the high and low and the umbrella — so nothing changes
-- for an alley until its admin picks.
--
-- The four switches the column replaces (kiosk_weather and kiosk_nameday
-- from 0067, kiosk_duty_header from 0073, kiosk_notices_header from 0077)
-- are converted and dropped. No function, trigger, view or edge function
-- reads them; public_week is an allow-list since 0066, so nothing changes
-- there. kiosk_todays_matches (0071) stays: today's matches have no side,
-- they are always in the centre.
--
-- Re-runnable on purpose, like 0077: the conversion runs only while all
-- four old columns exist. The tenancy suite re-runs 0067, 0073 and 0077,
-- which bring them back, and then this file.

-- Whether a value is a header layout. It never raises: every value is
-- looked at with jsonb_typeof before it is read, so a bad layout is a
-- check violation and nothing else. The CHECK runs as the admin who saves:
-- authenticated executes it, anon does not.
create or replace function kiosk_header_valid(p jsonb) returns boolean
    language plpgsql immutable set search_path = public as $$
declare
  v_module jsonb;
  v_ids text[] := '{}';
begin
  if jsonb_typeof(p) is distinct from 'object'
     or jsonb_typeof(p -> 'modules') is distinct from 'array' then
    return false;
  end if;
  for v_module in select value from jsonb_array_elements(p -> 'modules') loop
    if jsonb_typeof(v_module) is distinct from 'object'
       or jsonb_typeof(v_module -> 'id') is distinct from 'string'
       or jsonb_typeof(v_module -> 'side') is distinct from 'string' then
      return false;
    end if;
    if v_module ->> 'id' = '' or v_module ->> 'id' = any (v_ids)
       or v_module ->> 'side' not in ('off', 'left', 'right') then
      return false;
    end if;
    v_ids := v_ids || (v_module ->> 'id');
  end loop;
  return true;
end;
$$;
revoke all on function kiosk_header_valid(jsonb) from public, anon;
grant execute on function kiosk_header_valid(jsonb) to authenticated, service_role;
comment on function kiosk_header_valid(jsonb) is
  'Whether a value is a kiosk header layout (0082), for the check on schedule_settings.kiosk_header; never raises. authenticated executes it: the check runs as the admin who saves.';

-- A new alley: the notices on the right, the rest off — what the old
-- switches' defaults convert to —, and the weather as it was: the
-- temperature, the high and low, the umbrella.
alter table schedule_settings
  add column if not exists kiosk_header jsonb not null default
    '{"modules": [{"id": "weather", "side": "off"},
                  {"id": "nameday", "side": "off"},
                  {"id": "duty", "side": "off"},
                  {"id": "notices", "side": "right"}]}'::jsonb
    constraint schedule_settings_kiosk_header_check
    check (kiosk_header_valid(kiosk_header)),
  add column if not exists kiosk_weather_title text
    constraint schedule_settings_kiosk_weather_title_check
    check (kiosk_weather_title is null
           or char_length(btrim(kiosk_weather_title)) between 1 and 40),
  add column if not exists kiosk_weather_items text[] not null
    default '{range,rain}'
    constraint schedule_settings_kiosk_weather_items_check
    check (kiosk_weather_items
           <@ array['range', 'feels', 'wind', 'rain']::text[]);
comment on column schedule_settings.kiosk_header is
  'The kiosk''s header modules (0082): modules [{id, side off|left|right}] in their order — left after the clock, right before „Rezervace tréninku“. kiosk_header_valid checks the shape only; the app keeps an id it does not know.';
comment on column schedule_settings.kiosk_weather_title is
  'The weather module''s title on the kiosk (0082), typed by the admin („Brno“, shown „Brno:“); null shows „Počasí:“.';
comment on column schedule_settings.kiosk_weather_items is
  'What the weather module shows beside the temperature now, which it always shows (0082): range (today''s high and low), feels (the feels-like temperature now), wind (the wind now in km/h, with its gusts), rain (today''s rain or snow); the kiosk keeps its own order. Empty = the temperature alone.';

-- The old switches, converted: one on goes left — the weather, the name
-- day and the duty stood beside or under the clock — and the notices
-- right, where their line was. plpgsql plans the update, which names the
-- old columns, only when it runs, so the block also runs once they are
-- gone.
do $$
begin
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'schedule_settings'
         and column_name in ('kiosk_weather', 'kiosk_nameday',
                             'kiosk_duty_header',
                             'kiosk_notices_header')) < 4 then
    return;
  end if;
  update schedule_settings
     set kiosk_header = jsonb_build_object('modules', jsonb_build_array(
           jsonb_build_object('id', 'weather', 'side',
             case when kiosk_weather then 'left' else 'off' end),
           jsonb_build_object('id', 'nameday', 'side',
             case when kiosk_nameday then 'left' else 'off' end),
           jsonb_build_object('id', 'duty', 'side',
             case when kiosk_duty_header then 'left' else 'off' end),
           jsonb_build_object('id', 'notices', 'side',
             case when kiosk_notices_header then 'right' else 'off' end)));
end $$;

alter table schedule_settings
  drop column if exists kiosk_weather,
  drop column if exists kiosk_nameday,
  drop column if exists kiosk_duty_header,
  drop column if exists kiosk_notices_header;
