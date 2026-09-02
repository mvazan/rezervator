-- 0019 — drop the legacy profiles.club text.
--
-- 0003 introduced clubs + profiles.club_id and kept the free-text column
-- "as history"; register_profile (0006) still copied the club's name into
-- it and nothing ever updated it afterwards (set_player_club moves club_id
-- only), so it went stale on the first reassignment. The client stopped
-- reading it in 1.1.1 (clubNameOf); the players view and the attendance
-- report now use the clubs table alone.

-- players view: `create or replace` cannot drop a column.
drop view players;
create view players as
  select p.id, p.display_name, p.nick,
         p.club_id, coalesce(c.color, -1) as club_color
  from profiles p
  left join clubs c on c.id = p.club_id
  where p.status = 'approved' and p.role <> 'kiosk'
    and p.tenant_id = current_tenant_id()
    and not (p.superadmin
             and p.home_tenant_id is not null
             and p.tenant_id <> p.home_tenant_id);
revoke all on players from anon;
grant select on players to authenticated, service_role;

-- monthly_attendance: same body as 0015 without the text fallback.
create or replace function monthly_attendance(p_year int, p_month int)
returns table (player_id uuid, display_name text, club text, attended bigint)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;

  return query
  select p.id, p.display_name, coalesce(c.name, ''), count(r.id)
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
  group by p.id, p.display_name, coalesce(c.name, '')
  order by count(r.id) desc, p.display_name;
end;
$$;

-- register_profile: same body as 0006 without the club text.
create or replace function register_profile(
  p_display_name text,
  p_tenant_id uuid,
  p_club_id uuid default null,
  p_nick text default ''
)
returns profiles
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_profile profiles;
  v_tenant tenants;
  v_first boolean;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select * into v_profile from profiles where id = v_uid;
  if found then
    return v_profile;
  end if;

  if trim(p_display_name) = '' then
    raise exception 'empty_display_name';
  end if;
  if char_length(trim(coalesce(p_nick, ''))) > 14 then
    raise exception 'nick_too_long';
  end if;

  select * into v_tenant from tenants where id = p_tenant_id;
  if not found then
    raise exception 'unknown_tenant';
  end if;

  if p_club_id is not null and not exists (
    select 1 from clubs where id = p_club_id and tenant_id = p_tenant_id
  ) then
    raise exception 'unknown_club';
  end if;

  -- Serialize concurrent registrations into the same tenant so exactly one
  -- founder can win the race.
  perform pg_advisory_xact_lock(
    hashtext('register_profile'), hashtext(p_tenant_id::text));

  select not exists (
    select 1 from profiles
    where tenant_id = p_tenant_id and status = 'approved'
  ) into v_first;
  if v_tenant.founder_email is not null then
    v_first := v_first
      and lower(coalesce(auth.email(), '')) = lower(v_tenant.founder_email);
  end if;

  insert into profiles
    (id, tenant_id, display_name, club_id, nick, email,
     role, status, approved_at)
  values (
    v_uid,
    p_tenant_id,
    trim(p_display_name),
    p_club_id,
    trim(coalesce(p_nick, '')),
    coalesce(auth.email(), ''),
    case when v_first then 'admin' else 'player' end,
    case when v_first then 'approved' else 'pending' end,
    case when v_first then now() end
  )
  returning * into v_profile;

  return v_profile;
end;
$$;

-- Drops the 0001 column grant with it.
alter table profiles drop column club;
