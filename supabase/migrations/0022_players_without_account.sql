-- 0022 — players without an account: the admin creates the profile by hand.
--
-- Pensioners who never sign in still train: the admin books them from the
-- calendar dialog and they pick themselves on the kiosk — both already go
-- through the players view and create_reservation(p_player_id). Such a
-- profile has no auth user, so profiles.id stops referencing auth.users.
-- Real profiles are still minted only by register_profile from auth.uid();
-- deleting an auth user no longer cascades to its profile (it already failed
-- for anyone with a reservation — reservations.player_id is NO ACTION).
-- `placeholder` marks the hand-made rows: always an approved plain player
-- (bookable at once, and the notify function mails admins about PENDING
-- inserts only), never admin or kiosk (set_role: placeholder_no_account),
-- never a tenant's founding member (register_profile ignores them). When
-- the person later registers, the admin merges the two: the reservation
-- history moves to the account (profiles.id = auth.uid() is how the app and
-- RLS identify a person, so the account row is the one that survives), the
-- account takes the chosen name/nick/club and becomes approved, and the
-- placeholder row is deleted.

alter table profiles drop constraint profiles_id_fkey;

alter table profiles
  add column placeholder boolean not null default false,
  add constraint profiles_placeholder_check check (
    not placeholder
    or (role = 'player' and status = 'approved' and not superadmin));

comment on column profiles.placeholder is
  'Hand-made profile without an auth user (hráč bez účtu): approved player, bookable, never signs in; merge_placeholder_player folds it into a real account.';

-- ---------------------------------------------------------------------------
-- players view: `create or replace` may append a trailing column, so the
-- object and its ACL survive; the 0020 revokes are repeated regardless.
-- ---------------------------------------------------------------------------

create or replace view players as
  select p.id, p.display_name, p.nick,
         p.club_id, coalesce(c.color, -1) as club_color,
         p.placeholder
  from profiles p
  left join clubs c on c.id = p.club_id
  where p.status = 'approved' and p.role <> 'kiosk'
    and p.tenant_id = current_tenant_id()
    and not (p.superadmin
             and p.home_tenant_id is not null
             and p.tenant_id <> p.home_tenant_id);
revoke insert, update, delete, truncate, references, trigger, maintain
  on players from authenticated;
revoke all on players from anon;
grant select on players to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- RPCs (admin only). EXECUTE comes from the 0017 default privileges, like
-- every other app RPC.
-- ---------------------------------------------------------------------------

-- p_id null: insert an approved placeholder of the caller's tenant; else
-- edit one. Name/nick/club validation mirrors register_profile.
create or replace function save_placeholder_player(
  p_id uuid, p_display_name text, p_nick text, p_club_id uuid)
returns profiles
language plpgsql security definer set search_path = public
as $$
declare
  v_tenant uuid := current_tenant_id();
  v_profile profiles;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if trim(coalesce(p_display_name, '')) = '' then
    raise exception 'empty_display_name';
  end if;
  if char_length(trim(coalesce(p_nick, ''))) > 14 then
    raise exception 'nick_too_long';
  end if;
  if p_club_id is not null and not exists (
    select 1 from clubs where id = p_club_id and tenant_id = v_tenant
  ) then
    raise exception 'unknown_club';
  end if;

  if p_id is null then
    insert into profiles
      (id, tenant_id, display_name, email, role, status, nick, club_id,
       placeholder, approved_by, approved_at)
    values
      (gen_random_uuid(), v_tenant, trim(p_display_name), '', 'player',
       'approved', trim(coalesce(p_nick, '')), p_club_id, true,
       auth.uid(), now())
    returning * into v_profile;
  else
    update profiles
    set display_name = trim(p_display_name),
        nick = trim(coalesce(p_nick, '')),
        club_id = p_club_id
    where id = p_id and tenant_id = v_tenant and placeholder
    returning * into v_profile;
    if not found then
      raise exception 'unknown_player';
    end if;
  end if;
  return v_profile;
end;
$$;

-- A placeholder with reservations is history (Docházka): merge it into an
-- account instead of deleting it.
create or replace function delete_placeholder_player(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if not exists (
    select 1 from profiles
    where id = p_id and tenant_id = current_tenant_id() and placeholder
  ) then
    raise exception 'unknown_player';
  end if;
  if exists (select 1 from reservations where player_id = p_id) then
    raise exception 'player_has_history';
  end if;
  delete from profiles where id = p_id;
end;
$$;

-- The person behind a placeholder registered: p_target_id is their account
-- (pending or already approved). The placeholder's reservations move to
-- the account, the account takes the fields the admin chose in the merge
-- dialog and is approved, the placeholder row goes.
create or replace function merge_placeholder_player(
  p_placeholder_id uuid, p_target_id uuid,
  p_display_name text, p_nick text, p_club_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_tenant uuid := current_tenant_id();
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  -- Lock both rows: a concurrent create_reservation for the placeholder
  -- waits here instead of slipping in between the repoint and the delete.
  perform 1 from profiles
  where id = p_placeholder_id and tenant_id = v_tenant and placeholder
  for update;
  if not found then
    raise exception 'invalid_merge';
  end if;
  perform 1 from profiles
  where id = p_target_id and tenant_id = v_tenant
    and not placeholder and role <> 'kiosk'
  for update;
  if not found then
    raise exception 'invalid_merge';
  end if;
  if trim(coalesce(p_display_name, '')) = '' then
    raise exception 'empty_display_name';
  end if;
  if char_length(trim(coalesce(p_nick, ''))) > 14 then
    raise exception 'nick_too_long';
  end if;
  if p_club_id is not null and not exists (
    select 1 from clubs where id = p_club_id and tenant_id = v_tenant
  ) then
    raise exception 'unknown_club';
  end if;

  -- History moves to the account. player_id is the only column that can
  -- reference a placeholder: created_by / approved_by are written from
  -- auth.uid(), which a placeholder never is (profiles_placeholder_check
  -- keeps it a plain player). Anything else pointing at the row makes the
  -- NO ACTION FKs abort the delete below.
  update reservations set player_id = p_target_id
  where player_id = p_placeholder_id;

  update profiles
  set display_name = trim(p_display_name),
      nick = trim(coalesce(p_nick, '')),
      club_id = p_club_id,
      status = 'approved',
      approved_by = coalesce(approved_by, auth.uid()),
      approved_at = coalesce(approved_at, now())
  where id = p_target_id;

  delete from profiles where id = p_placeholder_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Guards on the existing RPCs (bodies otherwise unchanged from 0015/0019)
-- ---------------------------------------------------------------------------

-- A hand-made profile cannot sign in: neither admin nor kiosk.
create or replace function set_role(p_user_id uuid, p_role text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if p_role not in ('player', 'admin', 'kiosk') then
    raise exception 'invalid_role';
  end if;
  if p_user_id = auth.uid() and p_role <> 'admin' then
    raise exception 'cannot_demote_self';
  end if;
  if exists (
    select 1 from profiles
    where id = p_user_id and tenant_id = current_tenant_id() and placeholder
  ) then
    raise exception 'placeholder_no_account';
  end if;

  update profiles
  set role = p_role,
      status = case when p_role = 'kiosk' then 'approved' else status end
  where id = p_user_id and tenant_id = current_tenant_id();
end;
$$;

-- Hand-made rows never found a tenant: the first REAL registrant is still
-- the approved admin even if the alley already has placeholders.
create or replace function register_profile(
  p_display_name text, p_tenant_id uuid,
  p_club_id uuid default null, p_nick text default '')
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
      and not placeholder
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
