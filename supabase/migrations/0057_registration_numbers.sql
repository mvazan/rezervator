-- 0057 — registration numbers (registrační číslo) from the ČKA member
-- register, https://evidence.kuzelky.cz.
--
-- player_regnums: what the register answered for one name, so a number is
-- looked up once and never again (the `regnum-lookup` edge function fills it,
-- with the service role). Keyed by the folded name and the folded club the
-- question was asked with — two people of one name live in two clubs. Global,
-- not per alley: it holds only what the register publishes (a name, a club, a
-- number). `none` / `ambiguous` are retried by the function after a week.
-- No policy and no grant for the app: only the function reads and writes it.
--
-- profiles.regnum: the player's own number, shown in Můj profil and in
-- Klubovna → Kontakty. Written only by the function (no update grant), so the
-- app cannot set a number the register did not give.

create table if not exists player_regnums (
  name_key text not null,
  club_key text not null default '',
  regnum text check (regnum is null or regnum ~ '^[0-9]{1,8}$'),
  status text not null check (status in ('found', 'none', 'ambiguous')),
  looked_up_at timestamptz not null default now(),
  primary key (name_key, club_key),
  check ((status = 'found') = (regnum is not null))
);

alter table player_regnums enable row level security;
-- service_role first: pg_dump writes GRANTs in ACL order (see 0051).
revoke all on player_regnums from anon, authenticated;
grant all on player_regnums to service_role;

alter table profiles add column if not exists regnum text;
alter table profiles drop constraint if exists profiles_regnum_check;
alter table profiles add constraint profiles_regnum_check
  check (regnum is null or regnum ~ '^[0-9]{1,8}$');
comment on column profiles.regnum is
  'Registration number from the ČKA register (evidence.kuzelky.cz), looked up by name and club by the regnum-lookup function (0057); null until found. Not updatable by the app.';

-- ------------------------------------------------- contacts()
-- 0048's contacts() plus the number. The return type changes, so the function
-- is dropped and created again.
drop function if exists contacts();
create function contacts()
returns table (id uuid, display_name text, nick text, club_id uuid,
               club_name text, club_color integer, email text, phone text,
               regnum text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_approved() or is_kiosk() then
    raise exception 'not_allowed';
  end if;
  return query
    select p.id, p.display_name, p.nick, p.club_id, c.name,
           coalesce(c.color, -1),
           case when p.show_email then nullif(p.email, '') end,
           case when p.show_phone then p.phone end,
           p.regnum
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
