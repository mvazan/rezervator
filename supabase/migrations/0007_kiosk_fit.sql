-- 0007 — kiosk display mode: fit the whole day to the screen (default,
-- no scrolling) or scroll a comfortably-sized schedule. Admin-editable via
-- the existing settings_update RLS policy, same as kiosk_dark.

alter table schedule_settings
  add column kiosk_fit_day boolean not null default true;
