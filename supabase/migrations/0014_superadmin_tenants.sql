-- 0014 — superadmin + tenant approval (mirrors Termínátor's teams flow).
--
-- New kuželny founded from the register screen start as 'pending': the
-- founder waits on a holding screen until the SUPERADMIN (the app owner,
-- identified by login e-mail below) approves them in Správa → Kuželny.
-- The superadmin can also switch their own membership into any kuželna
-- (support/inspection — full admin view of its data and boards) via
-- switch_tenant.

-- ---------------------------------------------------------------------------
-- 1) tenants.status: existing tenants stay approved, new ones wait.
-- ---------------------------------------------------------------------------
alter table tenants
  add column status text not null default 'pending'
    check (status in ('pending', 'approved')),
  add column approved_at timestamptz;

update tenants set status = 'approved', approved_at = now();

-- The registration dropdown filters on it and the founder's waiting screen
-- polls it; founder_email stays RPC-only (never granted).
grant select (status) on tenants to authenticated;

-- ---------------------------------------------------------------------------
-- 2) profiles.superadmin — the app owner.
-- ---------------------------------------------------------------------------
alter table profiles add column superadmin boolean not null default false;

update profiles set superadmin = true
where id = (
  select id from auth.users where lower(email) = 'milos.vazan@gmail.com'
);

create or replace function is_superadmin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select superadmin from profiles where id = auth.uid()), false);
$$;

-- ---------------------------------------------------------------------------
-- 3) Superadmin RPCs. founder_email is exposed ONLY through the guarded
--    list function.
-- ---------------------------------------------------------------------------
create function admin_list_tenants()
returns table (
  id uuid,
  name text,
  status text,
  founder_email text,
  created_at timestamptz,
  approved_at timestamptz,
  member_count bigint
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not is_superadmin() then
    raise exception 'not_allowed';
  end if;
  return query
  select t.id, t.name, t.status, t.founder_email, t.created_at,
         t.approved_at, count(p.id)
  from tenants t
  left join profiles p on p.tenant_id = t.id
  group by t.id
  order by (t.status = 'pending') desc, t.created_at desc;
end;
$$;

create function approve_tenant(p_tenant_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not is_superadmin() then
    raise exception 'not_allowed';
  end if;
  update tenants
  set status = 'approved', approved_at = now()
  where id = p_tenant_id;
  if not found then
    raise exception 'unknown_tenant';
  end if;
end;
$$;

-- Rejecting a PENDING kuželna deletes it whole: the seeded defaults, any
-- rows its founder managed to create, the founder profile(s) — the founder
-- lands back on the register screen (their auth user survives). Approved
-- tenants are never deletable this way.
create function reject_tenant(p_tenant_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_status text;
begin
  if not is_superadmin() then
    raise exception 'not_allowed';
  end if;
  select status into v_status from tenants where id = p_tenant_id;
  if not found then
    raise exception 'unknown_tenant';
  end if;
  if v_status <> 'pending' then
    raise exception 'not_pending';
  end if;

  delete from reservations where tenant_id = p_tenant_id;
  delete from priority_slots where tenant_id = p_tenant_id;
  delete from rentals where tenant_id = p_tenant_id;
  delete from day_overrides where tenant_id = p_tenant_id;
  delete from time_blocks where tenant_id = p_tenant_id;
  delete from priority_slot_types where tenant_id = p_tenant_id;
  delete from clubs where tenant_id = p_tenant_id;
  delete from profiles where tenant_id = p_tenant_id;
  delete from schedule_settings where tenant_id = p_tenant_id;
  delete from tenants where id = p_tenant_id;
end;
$$;

-- The superadmin "moves in": every existing stream/RLS predicate follows
-- profiles.tenant_id, so after re-subscribing the whole app shows the
-- chosen kuželna. Pending tenants are switchable too — inspecting one
-- before approving it is the point.
create function switch_tenant(p_tenant_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not is_superadmin() then
    raise exception 'not_allowed';
  end if;
  if not exists (select 1 from tenants where id = p_tenant_id) then
    raise exception 'unknown_tenant';
  end if;
  update profiles set tenant_id = p_tenant_id where id = auth.uid();
end;
$$;

revoke all on function admin_list_tenants() from public, anon;
revoke all on function approve_tenant(uuid) from public, anon;
revoke all on function reject_tenant(uuid) from public, anon;
revoke all on function switch_tenant(uuid) from public, anon;

-- ---------------------------------------------------------------------------
-- 4) Tell the superadmin about new pending kuželny (notify EF handles the
--    'tenants' table; the webhook function ships the whole row).
-- ---------------------------------------------------------------------------
create trigger notify_tenants
  after insert on tenants
  for each row execute function notify_webhook();
