-- 0048 — Klubovna → Kontakty: a phone number on the profile, and each
-- player's choice whether their e-mail and phone show to the other players
-- of the alley. Spec: docs/superpowers/specs/2026-09-25-klubovna-kontakty-design.md
-- 0047 is deployed: everything here is additive and safe to run twice.

-- ------------------------------------------------- profiles: contact
alter table profiles add column if not exists phone text;
alter table profiles add column if not exists show_email boolean not null default true;
alter table profiles add column if not exists show_phone boolean not null default true;
alter table profiles drop constraint if exists profiles_phone_check;
alter table profiles add constraint profiles_phone_check
  check (phone is null or phone ~ '^\+[1-9][0-9]{7,14}$');
comment on column profiles.phone is
  'The player''s phone in international form (E.164, +<digits>, profiles_phone_check); null = none. The app normalises what the player types (lib/domain/phone.dart).';
comment on column profiles.show_email is
  'Whether contacts() hands this player''s e-mail to the other players of the alley (0048). On by default, for existing players too.';
comment on column profiles.show_phone is
  'Whether contacts() hands this player''s phone to the other players of the alley (0048). On by default, for existing players too.';

-- Own row only: profiles_update_own limits every update to id = auth.uid().
grant update (phone, show_email, show_phone) on profiles to authenticated;

-- ------------------------------------------------- register_profile
-- 0022's register_profile plus p_phone. The old four-argument signature is
-- dropped, not overloaded: a call without p_phone (the 1.2.x app, and
-- create_tenant_and_register, which passes four positional arguments) then
-- resolves to this one through the default. Both resolve at call time —
-- PL/pgSQL records no dependency, so the drop does not cascade.
drop function if exists register_profile(text, uuid, uuid, text);

create or replace function register_profile(
  p_display_name text,
  p_tenant_id uuid,
  p_club_id uuid default null,
  p_nick text default '',
  p_phone text default null)
returns profiles language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_profile profiles;
  v_tenant tenants;
  v_first boolean;
  v_phone constant text := nullif(trim(coalesce(p_phone, '')), '');
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
  if v_phone is not null and v_phone !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'invalid_phone';
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
      and not placeholder
  ) into v_first;
  if v_tenant.founder_email is not null then
    v_first := v_first
      and lower(coalesce(auth.email(), '')) = lower(v_tenant.founder_email);
  end if;

  insert into profiles
    (id, tenant_id, display_name, club_id, nick, email, phone,
     role, status, approved_at)
  values (
    v_uid,
    p_tenant_id,
    trim(p_display_name),
    p_club_id,
    trim(coalesce(p_nick, '')),
    coalesce(auth.email(), ''),
    v_phone,
    case when v_first then 'admin' else 'player' end,
    case when v_first then 'approved' else 'pending' end,
    case when v_first then now() end
  )
  returning * into v_profile;

  return v_profile;
end;
$$;

-- The dropped function was callable by everyone (its ACL was the default,
-- PUBLIC); the new one gets the same through Postgres' own default plus
-- 0017's default privileges. Spelled out for the app and the service.
grant execute on function register_profile(text, uuid, uuid, text, text)
  to authenticated, service_role;

-- ------------------------------------------------------- contacts()
-- Klubovna → Kontakty. The alley's registered players — approved, not the
-- kiosk, not a hand-made placeholder (0022), not a superadmin who is only
-- visiting (the players view's rule) — with the e-mail and phone each of
-- them chose to show; a hidden one is null here, so it never leaves the
-- database. profiles RLS shows a player their own row only, hence security
-- definer. Callers: an approved member of the alley, not the kiosk (a
-- visiting superadmin is one — current_tenant_id() is where they are).
create or replace function contacts()
returns table (id uuid, display_name text, nick text, club_id uuid,
               club_name text, club_color integer, email text, phone text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_approved() or is_kiosk() then
    raise exception 'not_allowed';
  end if;
  return query
    select p.id, p.display_name, p.nick, p.club_id, c.name,
           coalesce(c.color, -1),
           case when p.show_email then nullif(p.email, '') end,
           case when p.show_phone then p.phone end
      from profiles p
      left join clubs c on c.id = p.club_id
     where p.tenant_id = current_tenant_id()
       and p.status = 'approved'
       and p.role <> 'kiosk'
       and not p.placeholder
       and not (p.superadmin
                and p.home_tenant_id is not null
                and p.tenant_id <> p.home_tenant_id)
     order by p.display_name;
end;
$$;

revoke all on function contacts() from public, anon;
grant execute on function contacts() to authenticated;
