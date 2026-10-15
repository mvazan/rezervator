-- 0077 — the kiosk's two panels (Správa → Kiosk → Panely): one on each
-- side of the board, each so many day columns wide and open or closed at
-- rest, and the modules placed in them — off, left or right, a share of
-- the panel's height, an order. One jsonb column holds it all:
--
--   {"left":  {"days": 2, "open": false},
--    "right": {"days": 2, "open": false},
--    "modules": [{"id": "duty", "side": "off", "share": 30}, …]}
--
-- The modules are duty (the canteen duty, 0073), notices (Nástěnka),
-- matches (the list and the match being played), guide (Jak začít) and
-- week (Hráči týdne); the array's order is their order in a panel, and a
-- share is a weight — a panel need not sum to 100. kiosk_panels_valid
-- checks the shape, not the ids: the app skips an id it does not know and
-- writes it back unchanged, so a later module needs no migration.
-- kiosk_notices_header is the half of kiosk_notices_mode that was not about
-- the panel: Nástěnka's line in the status bar.
--
-- The eight columns of the old single drawer (0064, 0073) are converted
-- and dropped. No function, trigger, view or edge function reads them;
-- public_week is an allow-list since 0066.
--
-- Re-runnable on purpose, like 0064 and 0065: the conversion runs only
-- while all eight old columns exist. The tenancy suite re-runs 0064 and
-- 0073, which bring them back, and then this file.

-- Whether a value is a panel layout. It never raises: every value is
-- looked at with jsonb_typeof before it is read, so a bad layout is a
-- check violation and nothing else. The CHECK runs as the admin who saves:
-- authenticated executes it, anon does not.
create or replace function kiosk_panels_valid(p jsonb) returns boolean
    language plpgsql immutable set search_path = public as $$
declare
  v_side text;
  v_panel jsonb;
  v_module jsonb;
  v_ids text[] := '{}';
begin
  if jsonb_typeof(p) is distinct from 'object' then
    return false;
  end if;
  foreach v_side in array array['left', 'right'] loop
    v_panel := p -> v_side;
    if jsonb_typeof(v_panel) is distinct from 'object'
       or jsonb_typeof(v_panel -> 'days') is distinct from 'number'
       or jsonb_typeof(v_panel -> 'open') is distinct from 'boolean' then
      return false;
    end if;
    -- A JSON number: its text always casts to numeric.
    if (v_panel ->> 'days')::numeric <> trunc((v_panel ->> 'days')::numeric)
       or (v_panel ->> 'days')::numeric not between 1 and 13 then
      return false;
    end if;
  end loop;
  if jsonb_typeof(p -> 'modules') is distinct from 'array' then
    return false;
  end if;
  for v_module in select value from jsonb_array_elements(p -> 'modules') loop
    if jsonb_typeof(v_module) is distinct from 'object'
       or jsonb_typeof(v_module -> 'id') is distinct from 'string'
       or jsonb_typeof(v_module -> 'side') is distinct from 'string'
       or jsonb_typeof(v_module -> 'share') is distinct from 'number' then
      return false;
    end if;
    if v_module ->> 'id' = '' or v_module ->> 'id' = any (v_ids)
       or v_module ->> 'side' not in ('off', 'left', 'right')
       or (v_module ->> 'share')::numeric
            <> trunc((v_module ->> 'share')::numeric)
       or (v_module ->> 'share')::numeric not between 5 and 95 then
      return false;
    end if;
    v_ids := v_ids || (v_module ->> 'id');
  end loop;
  return true;
end;
$$;
revoke all on function kiosk_panels_valid(jsonb) from public, anon;
grant execute on function kiosk_panels_valid(jsonb) to authenticated, service_role;
comment on function kiosk_panels_valid(jsonb) is
  'Whether a value is a kiosk panel layout (0077), for the check on schedule_settings.kiosk_panels; never raises. authenticated executes it: the check runs as the admin who saves.';

-- A new alley: the right panel with the notices and the matches, closed —
-- what the old drawer's defaults convert to.
alter table schedule_settings
  add column if not exists kiosk_panels jsonb not null default
    '{"left": {"days": 2, "open": false},
      "right": {"days": 2, "open": false},
      "modules": [{"id": "duty", "side": "off", "share": 30},
                  {"id": "notices", "side": "right", "share": 40},
                  {"id": "matches", "side": "right", "share": 60},
                  {"id": "guide", "side": "off", "share": 45},
                  {"id": "week", "side": "off", "share": 55}]}'::jsonb
    constraint schedule_settings_kiosk_panels_check
    check (kiosk_panels_valid(kiosk_panels)),
  add column if not exists kiosk_notices_header boolean not null default true;
comment on column schedule_settings.kiosk_panels is
  'The kiosk''s two panels and the modules in them (0077): left/right {days 1–13, open}, modules [{id, side off|left|right, share 5–95}] in their order. kiosk_panels_valid checks the shape only; the app keeps an id it does not know.';
comment on column schedule_settings.kiosk_notices_header is
  'Nástěnka''s line in the kiosk''s status bar, one notice title at a time (0077: the header half of the dropped kiosk_notices_mode). Default on.';

-- The old drawer, converted. plpgsql plans the update, which names the old
-- columns, only when it runs, so the block also runs once they are gone.
-- The right panel is the old drawer; a module goes in it when the drawer
-- was on and showed it — the matches also when only the match being played
-- did (with the list off it took the drawer all the same; now it needs the
-- matches placed, so such an alley gets the list too). The shares flatten
-- the old nested weights (the duty d % of the drawer, the notices n % of
-- the rest), in numeric — round() half away from zero, as Dart's round() —
-- and each is clamped to 5–95. A module left off keeps its default share.
do $$
begin
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'schedule_settings'
         and column_name in ('kiosk_panel_enabled', 'kiosk_drawer_open',
                             'kiosk_drawer_columns', 'kiosk_notices_mode',
                             'kiosk_notices_share', 'kiosk_show_matches',
                             'kiosk_duty_drawer', 'kiosk_duty_share')) < 8 then
    return;
  end if;
  with placed as (
    select tenant_id,
           kiosk_panel_enabled and kiosk_duty_drawer as duty,
           kiosk_panel_enabled
             and kiosk_notices_mode in ('drawer', 'both') as notices,
           kiosk_panel_enabled
             and (kiosk_show_matches or kiosk_live_mode) as matches,
           kiosk_duty_share::numeric as d,
           kiosk_notices_share::numeric as n
      from schedule_settings
  ), shares as (
    -- The duty d; with the notices and the matches both placed, the
    -- notices (100 − d)·n/100 and the matches the rest to 100; with one of
    -- them, that one 100 − d. Without the duty, the notices n and the
    -- matches 100 − n. A module alone fills its panel whatever its share.
    select tenant_id, duty, notices, matches,
           d as duty_share,
           case when not duty then n
                when matches then round((100 - d) * n / 100)
                else 100 - d end as notices_share,
           case when not duty then 100 - n
                when notices then 100 - d - round((100 - d) * n / 100)
                else 100 - d end as matches_share
      from placed
  )
  update schedule_settings s
     set kiosk_panels = jsonb_build_object(
           'left', jsonb_build_object('days', 2, 'open', false),
           'right', jsonb_build_object('days', s.kiosk_drawer_columns,
                                       'open', s.kiosk_drawer_open),
           'modules', jsonb_build_array(
             jsonb_build_object(
               'id', 'duty',
               'side', case when x.duty then 'right' else 'off' end,
               'share', case when x.duty
                             then greatest(5, least(95, x.duty_share))::int
                             else 30 end),
             jsonb_build_object(
               'id', 'notices',
               'side', case when x.notices then 'right' else 'off' end,
               'share', case when x.notices
                             then greatest(5, least(95, x.notices_share))::int
                             else 40 end),
             jsonb_build_object(
               'id', 'matches',
               'side', case when x.matches then 'right' else 'off' end,
               'share', case when x.matches
                             then greatest(5, least(95, x.matches_share))::int
                             else 60 end),
             jsonb_build_object('id', 'guide', 'side', 'off', 'share', 45),
             jsonb_build_object('id', 'week', 'side', 'off', 'share', 55))),
         kiosk_notices_header = s.kiosk_notices_mode in ('header', 'both')
    from shares x
   where x.tenant_id = s.tenant_id;
end $$;

-- Their checks (schedule_settings_kiosk_drawer_columns_check,
-- …_kiosk_notices_mode_check, …_kiosk_share_check and
-- …_kiosk_duty_share_check) go with them.
alter table schedule_settings
  drop column if exists kiosk_panel_enabled,
  drop column if exists kiosk_drawer_open,
  drop column if exists kiosk_drawer_columns,
  drop column if exists kiosk_notices_mode,
  drop column if exists kiosk_notices_share,
  drop column if exists kiosk_show_matches,
  drop column if exists kiosk_duty_drawer,
  drop column if exists kiosk_duty_share;
