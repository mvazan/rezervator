-- 0081 — fresh notices on the kiosk (Správa → Kiosk → Nástěnka). A notice
-- is fresh while it has been up for fewer than kiosk_notices_fresh_days
-- days (1–14, default 3), counted from when it went up: visible_from for a
-- notice posted ahead of time (or shown early, below), created_at
-- otherwise. What a fresh notice gets, on the panel's card and in the
-- status bar, is kiosk_notices_fresh_mode:
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
-- message_set_visible_from (0064) is redefined so that visible_from keeps
-- when a notice went up: „Zobrazit hned“ on a notice still waiting
-- (visible_from ahead) records now() instead of clearing it — cleared, the
-- notice counted from created_at, the day it was written, and sank among
-- older notices on the Nástěnka and the kiosk. A notice already up keeps
-- its visible_from (a past one, or none), so it never jumps back to
-- created_at; a time ahead schedules it as before. Its signature, security,
-- grants and the notice_visible job are 0064's.
--
-- Re-runnable on purpose, like 0064 and 0065: the columns come only when
-- missing, each check only when it is not there yet, and the function is
-- create or replace.

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
  'What a fresh notice gets on the kiosk (0081): off | highlight (the NOVÉ label) | longer (twice kiosk_notices_rotation_seconds) | both. Default highlight.';
comment on column schedule_settings.kiosk_notices_fresh_days is
  'A notice is fresh on the kiosk while it has been up (visible_from, else created_at) for fewer days than this (0081), 1–14, default 3.';

-- When a notice shows (admin of its alley): a time ahead schedules it; null
-- or a time gone by shows it now — a notice still waiting records now() as
-- the time it went up, one already up keeps its own (0081; 0064 cleared
-- it). [p_notify] also sets whether it pings (null keeps it). A notice that
-- pings and shows later gets its push and e-mail then: a notice_visible
-- job at that time (one per notice — moving the time re-arms it; a notice
-- shown now has none). The app posts such a notice with notify off and
-- then calls this, so the send itself pings nobody.
create or replace function message_set_visible_from(
  p_id uuid, p_from timestamptz, p_notify boolean default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_from constant timestamptz := case when p_from > now() then p_from end;
  v_notify boolean;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  update messages
     set visible_from = case
           when v_from is not null then v_from
           when visible_from > now() then now()
           else visible_from
         end,
         notify = coalesce(p_notify, notify)
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
revoke all on function message_set_visible_from(uuid, timestamptz, boolean)
  from public, anon;
grant execute on function message_set_visible_from(uuid, timestamptz, boolean)
  to authenticated;
