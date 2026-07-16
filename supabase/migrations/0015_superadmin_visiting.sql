-- 0015 — a VISITING superadmin is invisible to the kuželna they inspect.
--
-- switch_tenant (0014) moves profiles.tenant_id; home_tenant_id records
-- where the superadmin actually plays and never moves with a switch.
-- "Visiting" = superadmin AND tenant_id <> home_tenant_id — such a profile
-- stays out of the players view (kiosk pickers, board name lookups, the
-- Hráči screen filters client-side too) and out of monthly_attendance
-- (Docházka). At home they are a regular member and show everywhere.

alter table profiles add column home_tenant_id uuid references tenants (id);

update profiles set home_tenant_id = tenant_id;

-- The superadmin might already BE switched somewhere when this runs — pin
-- their home to tenant #1 (the original kuželna, fixed id from 0005)
-- explicitly rather than trusting the momentary tenant_id.
update profiles
set home_tenant_id = '00000000-0000-0000-0000-000000000001'
where superadmin;

-- ---------------------------------------------------------------------------
-- players view: hide visiting superadmins (kiosk pickers, name lookups).
-- ---------------------------------------------------------------------------
create or replace view players as
  select p.id, p.display_name, p.club, p.nick,
         p.club_id, coalesce(c.color, -1) as club_color
  from profiles p
  left join clubs c on c.id = p.club_id
  where p.status = 'approved' and p.role <> 'kiosk'
    and p.tenant_id = current_tenant_id()
    and not (p.superadmin
             and p.home_tenant_id is not null
             and p.tenant_id <> p.home_tenant_id);

-- ---------------------------------------------------------------------------
-- monthly_attendance: Docházka skips visiting superadmins the same way.
-- ---------------------------------------------------------------------------
create or replace function monthly_attendance(p_year int, p_month int)
returns table (player_id uuid, display_name text, club text, attended bigint)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;

  return query
  select p.id, p.display_name,
         coalesce(c.name, nullif(p.club, ''), ''),
         count(r.id)
  from profiles p
  left join clubs c on c.id = p.club_id
  join reservations r on r.player_id = p.id
  where p.tenant_id = current_tenant_id()
    and not (p.superadmin
             and p.home_tenant_id is not null
             and p.tenant_id <> p.home_tenant_id)
    and r.cancelled_at is null
    and extract(year from r.date)::int = p_year
    and extract(month from r.date)::int = p_month
    and r.date <= (now() at time zone 'Europe/Prague')::date
  group by p.id, p.display_name, coalesce(c.name, nullif(p.club, ''), '')
  order by count(r.id) desc, p.display_name;
end;
$$;
