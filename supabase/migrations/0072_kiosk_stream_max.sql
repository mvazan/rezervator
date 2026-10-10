-- 0072 — how many stream windows the kiosk shows at once (Správa → Kiosk →
-- Stream zápasu → Oken najednou).
--
-- Any visitor now opens a match's video on the kiosk (▶ — live or the
-- recording), not only the admin's switch for the match on air
-- (kiosk_stream, 0066, now „opens by itself“). kiosk_stream_max 1 keeps
-- one window that turns through the open streams (‹ n/m ›); 2–4 give each
-- stream its own window, in the corners from kiosk_stream_corner on.
--
-- public_week is an allow-list since 0066, so nothing here reaches anon.
-- Re-runnable on purpose, like 0064–0066.

alter table schedule_settings
  add column if not exists kiosk_stream_max smallint not null default 1
    constraint schedule_settings_kiosk_stream_max_check
    check (kiosk_stream_max between 1 and 4);
