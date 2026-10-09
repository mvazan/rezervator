-- 0064 — the kiosk's side panel: notices, matches, the match being played.
--
-- The shared tablet on the alley's wall gets a drawer beside the board
-- with the alley's notices and its matches (the coming ones, the finished
-- ones with their Zápis, and a match being played across the whole panel),
-- and a status line that can show the notices' titles. The admin chooses
-- what it shows and how it looks in Správa → Kiosk.
--
-- Re-runnable on purpose: supabase/tests/tenancy_rls.sql re-runs 0051 (which
-- puts back its own read rule) and then this file.

-- ---------------------------------------------------------- the notices
-- 0051 kept the kiosk away from the whole messages feature. The notice
-- board is public to the alley by nature — what a club pins on its wall —
-- so the kiosk now reads the notices. Only kind = 'notice': messages (day,
-- block, admins, duty) stay with their author and recipients, and the kiosk
-- still reads no message_recipients row (who saw what) and writes nothing.
-- can_read_message and visible_message_ids stay the same rule, one per id
-- and one as a set (the tenancy suite checks that they agree).
create or replace function can_read_message(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
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

create or replace function visible_message_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
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

-- show_on_kiosk: the admin can take one notice off the wall. visible_from:
-- a notice posted ahead of time shows from then on, and its push and
-- e-mail go out then (a notification job, see message_set_visible_from).
-- Both are applied by the app, not by RLS: a row that only becomes
-- readable later never arrives over realtime (no event for a row the
-- subscriber could not read before), so it would stay away until a
-- restart. Whoever can read the notice can read it ahead of time through
-- the API — fine for a notice board.
alter table messages
  add column if not exists show_on_kiosk boolean not null default true,
  add column if not exists visible_from timestamptz;

-- Hide or show one notice on the kiosk (admin of its alley).
create or replace function message_set_kiosk(p_id uuid, p_show boolean)
returns void
language plpgsql security definer set search_path = public as $$
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
revoke all on function message_set_kiosk(uuid, boolean) from public, anon;
grant execute on function message_set_kiosk(uuid, boolean) to authenticated;

-- When a notice shows (admin of its alley): null or a time gone by = now.
-- [p_notify] also sets whether it pings (null keeps it). A notice that
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
revoke all on function message_set_visible_from(uuid, timestamptz, boolean)
  from public, anon;
grant execute on function message_set_visible_from(uuid, timestamptz, boolean)
  to authenticated;

-- ------------------------------------------------ what the kiosk shows
alter table schedule_settings
  -- The drawer on/off, and whether it rests open after the idle time.
  add column if not exists kiosk_panel_enabled boolean not null default true,
  add column if not exists kiosk_drawer_open boolean not null default false,
  add column if not exists kiosk_drawer_width smallint not null default 440
    constraint schedule_settings_kiosk_width_check
    check (kiosk_drawer_width between 280 and 800),
  -- Where the notices show: nowhere, in the drawer, one title at a time in
  -- the status line (header), or both; how fast they take turns; and the
  -- share of the drawer's height they get beside the matches.
  add column if not exists kiosk_notices_mode text not null default 'both'
    constraint schedule_settings_kiosk_notices_mode_check
    check (kiosk_notices_mode in ('off', 'drawer', 'header', 'both')),
  add column if not exists kiosk_notices_rotation_seconds smallint not null default 12
    constraint schedule_settings_kiosk_notices_rotation_check
    check (kiosk_notices_rotation_seconds between 3 and 120),
  add column if not exists kiosk_notices_share smallint not null default 40
    constraint schedule_settings_kiosk_share_check
    check (kiosk_notices_share between 10 and 90),
  -- The matches: on/off, the coming ones too, how many weeks back and
  -- ahead the list opens with (the league plays a round a week; a visitor
  -- can scroll the whole season), and whether the list follows the board
  -- a visitor scrolls to another day.
  add column if not exists kiosk_show_matches boolean not null default true,
  add column if not exists kiosk_show_upcoming boolean not null default true,
  add column if not exists kiosk_weeks_back smallint not null default 2
    constraint schedule_settings_kiosk_back_check
    check (kiosk_weeks_back between 0 and 52),
  add column if not exists kiosk_weeks_ahead smallint not null default 1
    constraint schedule_settings_kiosk_ahead_check
    check (kiosk_weeks_ahead between 0 and 52),
  add column if not exists kiosk_follow_board boolean not null default true,
  -- A match being played (with data) across the whole drawer, how it is
  -- drawn (the duel cards, compact, a table) and how fast several take
  -- turns.
  add column if not exists kiosk_live_mode boolean not null default true,
  add column if not exists kiosk_live_layout text not null default 'full'
    constraint schedule_settings_kiosk_live_layout_check
    check (kiosk_live_layout in ('full', 'compact', 'table')),
  add column if not exists kiosk_live_rotation_seconds smallint not null default 12
    constraint schedule_settings_kiosk_live_rotation_check
    check (kiosk_live_rotation_seconds between 3 and 120),
  -- How often the kiosk asks for a fresh score of a match being played
  -- (refresh_match; the server still fetches at most once a minute).
  add column if not exists kiosk_live_refresh_seconds smallint not null default 60
    constraint schedule_settings_kiosk_live_refresh_check
    check (kiosk_live_refresh_seconds between 30 and 600),
  -- The Zápis modal's share of the screen (100 = full, with a close button).
  add column if not exists kiosk_zapis_percent smallint not null default 80
    constraint schedule_settings_kiosk_zapis_check
    check (kiosk_zapis_percent between 50 and 100),
  -- How many days back the board can be scrolled (who trained yesterday).
  add column if not exists kiosk_past_days smallint not null default 0
    constraint schedule_settings_kiosk_past_check
    check (kiosk_past_days between 0 and 60),
  -- After this long without a touch the kiosk starts over.
  add column if not exists kiosk_idle_seconds smallint not null default 60
    constraint schedule_settings_kiosk_idle_check
    check (kiosk_idle_seconds between 15 and 600),
  -- The board's day columns: 0 = as wide as a week fits the screen (160 to
  -- 220 px), else this many px. And, when the day does not fit the screen
  -- (kiosk_fit_day off), one lane row's height in px per hour.
  add column if not exists kiosk_column_width smallint not null default 0
    constraint schedule_settings_kiosk_column_width_check
    check (kiosk_column_width = 0 or kiosk_column_width between 120 and 600),
  add column if not exists kiosk_row_height smallint not null default 40
    constraint schedule_settings_kiosk_row_height_check
    check (kiosk_row_height between 20 and 120);

-- The public overview (0043) keeps handing out only what it always did:
-- the kiosk's choices are the admin's, not anon's.
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
                          - 'kiosk_drawer_open' - 'kiosk_drawer_width'
                          - 'kiosk_notices_share' - 'kiosk_zapis_percent'
                          - 'kiosk_weeks_back' - 'kiosk_weeks_ahead'
                          - 'kiosk_panel_enabled' - 'kiosk_past_days'
                          - 'kiosk_notices_rotation_seconds'
                          - 'kiosk_live_rotation_seconds'
                          - 'kiosk_idle_seconds'
                          - 'kiosk_live_layout' - 'kiosk_follow_board'
                          - 'kiosk_live_refresh_seconds'
                          - 'kiosk_column_width' - 'kiosk_row_height'
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
