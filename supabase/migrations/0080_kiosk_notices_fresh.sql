-- 0080 — fresh notices on the kiosk (Správa → Kiosk → Nástěnka). A notice
-- is fresh while it has been up for fewer than kiosk_notices_fresh_days
-- days (1–14, default 3), counted from when it went up: visible_from for a
-- notice posted ahead of time, created_at otherwise. What a fresh notice
-- gets, on the panel's card and in the status bar, is
-- kiosk_notices_fresh_mode:
--
--   off        nothing
--   highlight  the „NOVÉ“ label (the default)
--   longer     twice the turn (kiosk_notices_rotation_seconds) before the
--              next notice
--   both       the label and the longer turn
--
-- The kiosk works it out itself from the settings row and the notices it
-- already reads. public_week needs nothing: it hands out an allow-list of
-- its six settings, so neither column reaches anon.
--
-- Re-runnable on purpose, like 0064 and 0065: the columns come only when
-- missing, and each check only when it is not there yet.

alter table schedule_settings
  add column if not exists kiosk_notices_fresh_mode text not null
    default 'highlight',
  add column if not exists kiosk_notices_fresh_days smallint not null
    default 3;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.schedule_settings'::regclass
                    and conname = 'schedule_settings_kiosk_notices_fresh_mode_check') then
    alter table schedule_settings
      add constraint schedule_settings_kiosk_notices_fresh_mode_check
      check (kiosk_notices_fresh_mode in ('off', 'highlight', 'longer', 'both'));
  end if;
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.schedule_settings'::regclass
                    and conname = 'schedule_settings_kiosk_notices_fresh_days_check') then
    alter table schedule_settings
      add constraint schedule_settings_kiosk_notices_fresh_days_check
      check (kiosk_notices_fresh_days between 1 and 14);
  end if;
end $$;

comment on column schedule_settings.kiosk_notices_fresh_mode is
  'What a fresh notice gets on the kiosk (0080): off | highlight (the NOVÉ label) | longer (twice kiosk_notices_rotation_seconds) | both. Default highlight.';
comment on column schedule_settings.kiosk_notices_fresh_days is
  'A notice is fresh on the kiosk while it has been up (visible_from, else created_at) for fewer days than this (0080), 1–14, default 3.';
