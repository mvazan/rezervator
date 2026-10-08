-- 0068 — how long the kiosk waits before it starts over.
--
-- After kiosk_idle_seconds without a touch the kiosk forgets the picked
-- player, closes dialogs and the Zápis, scrolls the board back to today and
-- puts the drawer in its resting state. It was a fixed minute.

alter table schedule_settings
  add column kiosk_idle_seconds smallint not null default 60
    constraint schedule_settings_kiosk_idle_check
    check (kiosk_idle_seconds between 15 and 600);

-- The public overview (0043) still hands out only what it always did.
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
                          - 'kiosk_show_upcoming' - 'kiosk_live_mode'
                          - 'kiosk_drawer_open' - 'kiosk_drawer_width'
                          - 'kiosk_notices_share' - 'kiosk_zapis_percent'
                          - 'kiosk_weeks_back' - 'kiosk_weeks_ahead'
                          - 'kiosk_panel_enabled' - 'kiosk_past_days'
                          - 'kiosk_notices_rotation_seconds'
                          - 'kiosk_live_rotation_seconds'
                          - 'kiosk_idle_seconds'
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
