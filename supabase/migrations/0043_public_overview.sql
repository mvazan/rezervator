-- 0043: veřejný přehled. A kuželna may publish a read-only week board at
-- rezervator.online/#/prehled/<slug>. Self-service: its admin picks the slug
-- and switches it on (off by default). Anyone — anon included — reads it
-- through ONE function, public_week, which hands out no names: reservations
-- become bare occupied cells with the club colour, rentals lose renter and
-- note. The slug columns stay outside the tenants column grant; only the
-- functions below read them.

alter table tenants add column public_slug text;
alter table tenants add column public_enabled boolean not null default false;
alter table tenants add constraint tenants_public_slug_key unique (public_slug);
alter table tenants add constraint tenants_public_slug_format
  check (public_slug ~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$');
alter table tenants add constraint tenants_public_needs_slug
  check (not public_enabled or public_slug is not null);

-- The published, approved alley behind a slug. Unknown, switched off and
-- not yet approved all raise the SAME error, so nobody can probe which
-- slugs exist.
create or replace function public_tenant_id(p_slug text)
returns uuid
language plpgsql stable security definer set search_path = public
as $$
declare
  v_tenant uuid;
begin
  select id into v_tenant from tenants
   where public_slug = lower(trim(coalesce(p_slug, '')))
     and public_enabled
     and status = 'approved';
  if v_tenant is null then
    raise exception 'unknown_tenant';
  end if;
  return v_tenant;
end;
$$;
revoke all on function public_tenant_id(text) from public, anon, authenticated;

-- One week of one published alley, shaped like the app's own streams so the
-- client's fromJson factories read it unchanged. overrides/priority_slots/
-- rentals cover Sunday before … Monday after the week: the phone's day
-- pager previews the neighbouring day from the same lists mid-swipe.
create or replace function public_week(p_slug text, p_monday date)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
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
revoke all on function public_week(text, date) from public;
grant execute on function public_week(text, date) to anon, authenticated;

-- The admin's switch: slug (trimmed, lower-cased, '' = none) and on/off for
-- their own alley.
create or replace function set_public_overview(p_slug text, p_enabled boolean)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_slug constant text := nullif(lower(trim(coalesce(p_slug, ''))), '');
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if coalesce(p_enabled, false) and v_slug is null then
    raise exception 'invalid_slug';
  end if;
  update tenants
     set public_slug = v_slug, public_enabled = coalesce(p_enabled, false)
   where id = current_tenant_id();
exception
  when check_violation then raise exception 'invalid_slug';
  when unique_violation then raise exception 'slug_taken';
end;
$$;
revoke all on function set_public_overview(text, boolean) from public, anon;
grant execute on function set_public_overview(text, boolean) to authenticated;

-- What the admin screen shows: the setting and the name to suggest a slug from.
create or replace function my_public_overview()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  return (
    select jsonb_build_object('public_slug', t.public_slug,
                              'public_enabled', t.public_enabled,
                              'tenant_name', t.name)
      from tenants t where t.id = current_tenant_id());
end;
$$;
revoke all on function my_public_overview() from public, anon;
grant execute on function my_public_overview() to authenticated;
