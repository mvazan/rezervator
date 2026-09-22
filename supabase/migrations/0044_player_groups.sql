-- 0044: skupiny hráčů. Rodina nebo dvojice si rezervuje a ruší tréninky
-- navzájem. Skupinu zakládají hráči sami: pozvánka + souhlas (skupina dává
-- ostatním právo rušit MOJE rezervace, takže souhlasí ten, o koho jde).
-- Jedna skupina na hráče. Správce jen vidí a může někoho odebrat.
-- Rezervace za člena má stejná pravidla jako za sebe; limit se počítá
-- tomu, PRO KOHO je.

create table player_groups (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
comment on table player_groups is
  'A group of players who may book and cancel trainings for each other (0044). Server-only: the app reads player_group_members.';
alter table player_groups enable row level security;
revoke all on player_groups from anon, authenticated;

create table player_group_members (
  group_id uuid not null references player_groups(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  tenant_id uuid not null references tenants(id) on delete cascade,
  status text not null check (status in ('invited', 'member')),
  invited_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
comment on table player_group_members is
  'Membership and pending invites of player_groups (0044). tenant_id is denormalised so the admin policy never has to read player_groups (no policy cycle). Written only through the group_* RPCs.';
create unique index player_group_one_membership
  on player_group_members (user_id) where status = 'member';

-- The caller's own group (null outside one). Security definer: the policy
-- below reads the very table it guards.
create or replace function my_group_id() returns uuid
language sql stable security definer set search_path = public as $$
  select group_id from player_group_members
   where user_id = auth.uid() and status = 'member'
$$;
revoke all on function my_group_id() from public, anon;
grant execute on function my_group_id() to authenticated;

alter table player_group_members enable row level security;
create policy player_group_members_select on player_group_members
  for select using (
    user_id = auth.uid()
    or group_id = my_group_id()
    or (is_admin() and tenant_id = current_tenant_id())
  );
revoke insert, update, delete on player_group_members from authenticated;
revoke all on player_group_members from anon;

alter publication supabase_realtime add table player_group_members;

create trigger notify_player_group_members
  after insert or update on player_group_members
  for each row execute function notify_webhook();

create or replace function same_group(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
      from player_group_members x
      join player_group_members y on y.group_id = x.group_id
     where x.user_id = a and x.status = 'member'
       and y.user_id = b and y.status = 'member')
$$;
revoke all on function same_group(uuid, uuid) from public, anon, authenticated;

-- Removes one member; the group dies with its last member (its pending
-- invites cascade with it).
create or replace function _group_drop_member(p_group uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from player_group_members
   where group_id = p_group and user_id = p_user and status = 'member';
  if not exists (select 1 from player_group_members
                 where group_id = p_group and status = 'member') then
    delete from player_groups where id = p_group;
  end if;
end;
$$;
revoke all on function _group_drop_member(uuid, uuid) from public, anon, authenticated;

create or replace function group_invite(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_caller profiles;
  v_group uuid;
  v_status text;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  select * into v_caller from profiles where id = v_uid;
  if not found or v_caller.status <> 'approved' or v_caller.role = 'kiosk' then
    raise exception 'not_allowed';
  end if;
  if p_user = v_uid or not exists (
    select 1 from profiles
     where id = p_user and tenant_id = v_caller.tenant_id
       and status = 'approved' and role <> 'kiosk' and not placeholder
  ) then
    raise exception 'unknown_player';
  end if;

  select group_id into v_group from player_group_members
   where user_id = v_uid and status = 'member';
  if v_group is null then
    insert into player_groups (tenant_id, created_by)
      values (v_caller.tenant_id, v_uid) returning id into v_group;
    insert into player_group_members (group_id, user_id, tenant_id, status)
      values (v_group, v_uid, v_caller.tenant_id, 'member');
  end if;

  select status into v_status from player_group_members
   where group_id = v_group and user_id = p_user;
  if v_status = 'member' then
    raise exception 'already_member';
  elsif v_status = 'invited' then
    raise exception 'already_invited';
  end if;
  insert into player_group_members (group_id, user_id, tenant_id, status, invited_by)
    values (v_group, p_user, v_caller.tenant_id, 'invited', v_uid);
end;
$$;

create or replace function group_accept(p_group uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  update player_group_members set status = 'member'
   where group_id = p_group and user_id = auth.uid() and status = 'invited';
  if not found then
    raise exception 'unknown_invite';
  end if;
exception when unique_violation then
  raise exception 'already_in_group';
end;
$$;

create or replace function group_decline(p_group uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  delete from player_group_members
   where group_id = p_group and user_id = auth.uid() and status = 'invited';
  if not found then
    raise exception 'unknown_invite';
  end if;
end;
$$;

create or replace function group_leave()
returns void language plpgsql security definer set search_path = public as $$
declare
  v_group uuid := my_group_id();
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if v_group is not null then
    perform _group_drop_member(v_group, auth.uid());
  end if;
end;
$$;

create or replace function group_cancel_invite(p_group uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if my_group_id() is distinct from p_group then
    raise exception 'not_allowed';
  end if;
  delete from player_group_members
   where group_id = p_group and user_id = p_user and status = 'invited';
  if not found then
    raise exception 'unknown_invite';
  end if;
end;
$$;

create or replace function group_remove_member(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_group uuid;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if not exists (select 1 from profiles
                 where id = p_user and tenant_id = current_tenant_id()) then
    raise exception 'not_allowed';
  end if;
  select group_id into v_group from player_group_members
   where user_id = p_user and status = 'member';
  if v_group is not null then
    perform _group_drop_member(v_group, p_user);
  end if;
end;
$$;

revoke all on function group_invite(uuid) from public, anon;
revoke all on function group_accept(uuid) from public, anon;
revoke all on function group_decline(uuid) from public, anon;
revoke all on function group_leave() from public, anon;
revoke all on function group_cancel_invite(uuid, uuid) from public, anon;
revoke all on function group_remove_member(uuid) from public, anon;
grant execute on function group_invite(uuid) to authenticated;
grant execute on function group_accept(uuid) to authenticated;
grant execute on function group_decline(uuid) to authenticated;
grant execute on function group_leave() to authenticated;
grant execute on function group_cancel_invite(uuid, uuid) to authenticated;
grant execute on function group_remove_member(uuid) to authenticated;

-- Reservations: who cancelled (for "Petr ti zrušil trénink"), and 'group'
-- as a way in and out.
alter table reservations
  add column cancelled_by uuid references profiles(id) on delete set null;
alter table reservations drop constraint reservations_created_via_check;
alter table reservations add constraint reservations_created_via_check
  check (created_via in ('app', 'kiosk', 'admin', 'group'));
alter table reservations drop constraint reservations_cancelled_via_check;
alter table reservations add constraint reservations_cancelled_via_check
  check (cancelled_via in ('app', 'one_click', 'admin', 'group'));

-- create_reservation: a group booking (member for member, under the
-- member's own rules and cap), and the honest error when that cap is hit.
create or replace function public.create_reservation(p_player_id uuid, p_date date, p_block_id uuid, p_lane smallint) returns public.reservations
    language plpgsql security definer
    set search_path to 'public'
    as $$
declare
  v_uid uuid := auth.uid();
  v_caller profiles;
  v_settings schedule_settings;
  v_block time_blocks;
  v_status text;
  v_via text;
  v_today date := (now() at time zone 'Europe/Prague')::date;
  v_now time := (now() at time zone 'Europe/Prague')::time;
  v_active_count int;
  v_res reservations;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  select * into v_caller from profiles where id = v_uid;
  if not found then
    raise exception 'no_profile';
  end if;

  if v_caller.role = 'admin' and v_caller.status = 'approved' then
    v_via := case when p_player_id = v_uid then 'app' else 'admin' end;
  elsif v_caller.role = 'kiosk' then
    v_via := 'kiosk';
  elsif v_caller.status = 'approved' and p_player_id = v_uid then
    v_via := 'app';
  elsif v_caller.status = 'approved' and v_caller.role = 'player'
        and same_group(v_uid, p_player_id) then
    v_via := 'group';
  else
    raise exception 'not_allowed';
  end if;

  if not exists (
    select 1 from profiles
    where id = p_player_id and status = 'approved' and role <> 'kiosk'
      and tenant_id = v_caller.tenant_id
  ) then
    raise exception 'player_not_approved';
  end if;

  select * into v_settings from schedule_settings
  where tenant_id = v_caller.tenant_id;
  select * into v_block from time_blocks
  where id = p_block_id and tenant_id = v_caller.tenant_id;
  if not found then
    raise exception 'unknown_block';
  end if;
  if p_lane < 1 or p_lane > v_settings.lane_count then
    raise exception 'invalid_lane';
  end if;

  v_status := block_day_status(v_caller.tenant_id, p_date, p_block_id);
  if v_status is distinct from 'open' then
    raise exception '%', coalesce(v_status, 'unknown_block');
  end if;

  if v_caller.role <> 'admin' then
    if p_date < v_today then
      raise exception 'date_past';
    end if;
    if p_date = v_today and v_block.starts_at <= v_now then
      raise exception 'date_past';
    end if;
    if p_date > v_today + v_settings.booking_horizon_days then
      raise exception 'beyond_horizon';
    end if;
    select count(*) into v_active_count
    from reservations
    where player_id = p_player_id and cancelled_at is null and date >= v_today;
    if v_active_count >= v_settings.max_active_reservations then
      -- "Máš už…" would be a lie about a member's cap.
      raise exception '%',
        case when v_via = 'group' then 'member_at_limit' else 'limit_reached' end;
    end if;
  end if;

  if exists (
    select 1 from priority_slots s
    join priority_slot_types t on t.id = s.type_id
    where s.date = p_date
      and s.tenant_id = v_caller.tenant_id
      and not s.is_away
      and (t.lanes is null or p_lane = any (t.lanes))
      and s.starts_at < v_block.ends_at
      and s.ends_at > v_block.starts_at
  ) then
    raise exception 'blocked_by_priority';
  end if;

  if exists (
    select 1 from rental_occurrences(v_caller.tenant_id, p_date) o
    where p_lane = any (o.lanes)
      and o.starts_at < v_block.ends_at and o.ends_at > v_block.starts_at
  ) then
    raise exception 'blocked_by_rental';
  end if;

  begin
    insert into reservations
      (tenant_id, player_id, date, block_id, lane, created_via, created_by)
    values
      (v_caller.tenant_id, p_player_id, p_date, p_block_id, p_lane, v_via, v_uid)
    returning * into v_res;
  exception when unique_violation then
    raise exception 'slot_taken';
  end;

  return v_res;
end;
$$;

-- cancel_reservation: a group member may cancel another member's
-- reservation, under the same too_late rule as the owner, and the row
-- remembers who actually cancelled it.
create or replace function public.cancel_reservation(p_id uuid, p_note text default ''::text, p_notify boolean default true) returns void
    language plpgsql security definer
    set search_path to 'public'
    as $$
declare
  v_uid uuid := auth.uid();
  v_caller profiles;
  v_res reservations;
  v_block time_blocks;
  v_via text;
  v_now timestamptz := now();
  v_starts timestamptz;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  select * into v_caller from profiles where id = v_uid;
  if not found then
    raise exception 'no_profile';
  end if;

  select * into v_res from reservations where id = p_id;
  if not found then
    raise exception 'not_found';
  end if;
  if v_res.cancelled_at is not null then
    return;  -- already cancelled, idempotent
  end if;

  if v_caller.role = 'admin' and v_caller.status = 'approved'
     and v_res.tenant_id = v_caller.tenant_id then
    v_via := 'admin';
  elsif v_caller.status = 'approved'
        and (v_res.player_id = v_uid
             or (v_caller.role = 'player' and same_group(v_uid, v_res.player_id))) then
    select * into v_block from time_blocks where id = v_res.block_id;
    v_starts := (v_res.date + v_block.starts_at) at time zone 'Europe/Prague';
    if v_now >= v_starts then
      raise exception 'too_late';
    end if;
    v_via := case when v_res.player_id = v_uid then 'app' else 'group' end;
  else
    raise exception 'not_allowed';
  end if;

  update reservations
  set cancelled_at = v_now, cancelled_via = v_via, cancelled_by = v_uid,
      cancel_note = trim(coalesce(p_note, '')),
      notify_player = coalesce(p_notify, true),
      notify_message = null
  where id = p_id;
end;
$$;
