-- 0006 — self-service registration: a new alley (kuželna) can be founded
-- right from the register screen (no more superadmin SQL insert), the club
-- is picked from the alley's actual club list instead of free text, and the
-- board nick can be set at sign-up.

-- ---------------------------------------------------------------------------
-- 1) clubs of an alley for the pre-profile register screen. RLS would hide
--    them (the caller has no profile yet, so current_tenant_id() is null),
--    hence security definer. Exposes names only — the same level as the
--    tenants (id, name) grant.
-- ---------------------------------------------------------------------------
create function registration_clubs(p_tenant_id uuid)
returns table (id uuid, name text)
language sql stable security definer set search_path = public
as $$
  select c.id, c.name from clubs c
  where auth.uid() is not null and c.tenant_id = p_tenant_id
  order by c.name;
$$;

-- ---------------------------------------------------------------------------
-- 2) register_profile: club by id (validated against the picked alley) and
--    nick at sign-up. Old signature must go first (PostgREST overload trap).
-- ---------------------------------------------------------------------------
drop function register_profile(text, text, uuid);

create function register_profile(
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
  v_club clubs;
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

  if p_club_id is not null then
    select * into v_club from clubs
    where id = p_club_id and tenant_id = p_tenant_id;
    if not found then
      raise exception 'unknown_club';
    end if;
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
    (id, tenant_id, display_name, club, club_id, nick, email,
     role, status, approved_at)
  values (
    v_uid,
    p_tenant_id,
    trim(p_display_name),
    coalesce(v_club.name, ''),
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

-- ---------------------------------------------------------------------------
-- 3) founding a new alley from the register screen: creates the tenant with
--    the caller as founder_email and registers them in one transaction — the
--    founder branch of register_profile then makes them the approved admin.
--    The seed trigger (0005) gives the new tenant its settings row and the
--    built-in Zápas type.
-- ---------------------------------------------------------------------------
create function create_tenant_and_register(
  p_tenant_name text,
  p_display_name text,
  p_nick text default ''
)
returns profiles
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_profile profiles;
  v_tenant_id uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  -- An existing profile means the caller already belongs to an alley; bail
  -- out before creating a tenant nobody would live in.
  select * into v_profile from profiles where id = v_uid;
  if found then
    return v_profile;
  end if;

  if trim(p_tenant_name) = '' then
    raise exception 'empty_tenant_name';
  end if;

  begin
    insert into tenants (name, founder_email)
    values (trim(p_tenant_name), nullif(lower(coalesce(auth.email(), '')), ''))
    returning id into v_tenant_id;
  exception when unique_violation then
    raise exception 'tenant_exists';
  end;

  return register_profile(p_display_name, v_tenant_id, null, p_nick);
end;
$$;
