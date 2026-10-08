-- 0065 — what the kiosk's side panel shows (admin choice) and which notices.
--
-- The kiosk board has a drawer beside the schedule (0064 let the kiosk read
-- notices): the admin picks, in Správa → Kiosk, whether it lists the notice
-- board and the matches, how far back the finished matches go, and whether
-- the drawer is open when the tablet is idle. On a notice the admin can
-- hide it from the kiosk (show_on_kiosk).
--
-- Hiding is done by the kiosk app, not by RLS: a notice that turned
-- invisible to the kiosk would never be taken back by it (realtime sends no
-- event for a row the subscriber may no longer read), so the hidden notice
-- would stay on the wall until a restart. The kiosk already reads every
-- notice of its alley (0064); the flag only says which one it shows.

alter table schedule_settings
  add column kiosk_show_notices boolean not null default true,
  add column kiosk_show_matches boolean not null default true,
  add column kiosk_matches_history_days smallint not null default 21
    constraint schedule_settings_kiosk_history_check
    check (kiosk_matches_history_days between 0 and 120),
  add column kiosk_drawer_open boolean not null default false;

alter table messages
  add column show_on_kiosk boolean not null default true;

-- Hide or show one notice on the kiosk (admin of its alley). A column of its
-- own rather than message_update: that one is the whole-notice edit (it
-- bumps updated_at, which „Sejmout" and the edit sheet reason about).
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

-- The public overview (0043) keeps handing out only what it always did: the
-- new kiosk columns are admin choices, not for anon.
CREATE OR REPLACE FUNCTION public_week(p_slug text, p_monday date) returns jsonb
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
                          - 'kiosk_show_notices' - 'kiosk_show_matches'
                          - 'kiosk_matches_history_days' - 'kiosk_drawer_open'
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
