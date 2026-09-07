-- 0030 — colours stop being just a palette index: any colour goes.
--
-- Until now a colour was a smallint: -2/-1 for the "none"/"default" cases and
-- 0–11 for a palette entry. A hand-picked colour does not fit that, so the
-- four colour columns widen to integer and take one more shape: a 24-bit RGB
-- value packed above the palette range as 0x1000000 | rgb (16777216–33554431).
-- Everything below stays exactly what it was, so every existing row is still
-- valid and the client reads the old values unchanged.
--
-- Dart mirrors this in domain/palette.dart (isCustomColor / packCustom /
-- unpackCustom); it derives the four rendered variants (dark and light
-- background plus its text) from the packed colour the same way the palette's
-- own entries are shaded, so a hand-picked colour stays readable in both
-- themes.

alter table profiles
  drop constraint profiles_own_color_check,
  alter column own_color type integer,
  add constraint profiles_own_color_check check (
    own_color between -1 and 11 or own_color between 16777216 and 33554431);

-- The players view reads clubs.color, so it has to step aside for the type
-- change and come back exactly as it was (0022 shaped it, 0020 set the ACL).
drop view players;

alter table clubs
  drop constraint clubs_color_check,
  alter column color type integer,
  add constraint clubs_color_check check (
    color between -1 and 11 or color between 16777216 and 33554431);

create view players as
  select p.id, p.display_name, p.nick, p.club_id,
         coalesce(c.color, -1) as club_color, p.placeholder
  from profiles p left join clubs c on c.id = p.club_id
  where p.status = 'approved' and p.role <> 'kiosk'
    and p.tenant_id = current_tenant_id()
    and not (p.superadmin and p.home_tenant_id is not null
             and p.tenant_id <> p.home_tenant_id);
revoke insert, update, delete, truncate, references, trigger, maintain
  on players from authenticated;
revoke all on players from anon;
grant select on players to authenticated, service_role;

alter table rentals
  drop constraint rentals_color_check,
  alter column color type integer,
  add constraint rentals_color_check check (
    color between -2 and 11 or color between 16777216 and 33554431);

alter table priority_slot_types
  drop constraint priority_slot_types_color_check,
  alter column color type integer,
  add constraint priority_slot_types_color_check check (
    color between -1 and 11 or color between 16777216 and 33554431);

comment on column profiles.own_color is
  'The player''s own reservations in their own view: -1 = the club colour, 0-11 a palette entry, 0x1000000|rgb a hand-picked colour.';
comment on column clubs.color is
  'Club colour: -1 = none, 0-11 a palette entry, 0x1000000|rgb a hand-picked colour.';
comment on column rentals.color is
  'Rental colour: -2 = the rental default, 0-11 a palette entry, 0x1000000|rgb a hand-picked colour.';
comment on column priority_slot_types.color is
  'Slot type colour: -1 = none, 0-11 a palette entry, 0x1000000|rgb a hand-picked colour.';

-- The RPC took a smallint, which would now reject a packed colour. A changed
-- parameter type is a new signature, so the old one has to go or PostgREST
-- would have two overloads to choose between.
drop function upsert_club(uuid, text, smallint);

-- Same body as before, only p_color widened.
create function upsert_club(p_id uuid, p_name text, p_color integer)
  returns clubs language plpgsql security definer set search_path = public as $$
declare v clubs;
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  if trim(coalesce(p_name,'')) = '' then raise exception 'empty_name'; end if;
  if p_id is null then
    insert into clubs (tenant_id, name, color)
    values (current_tenant_id(), trim(p_name), p_color) returning * into v;
  else
    update clubs set name = trim(p_name), color = p_color
    where id = p_id and tenant_id = current_tenant_id() returning * into v;
  end if;
  return v;
end; $$;
