-- 0003 — clubs + colors: a `clubs` table, per-player club link, per-club
-- palette color, per-rental color override, and a kiosk dark/light flag.
-- Atomic: the players-view rebuild and the data migration must land together.
begin;

create table clubs (
  id uuid primary key default gen_random_uuid(),
  name text unique not null,
  color smallint not null default -1 check (color between -1 and 11),
  created_at timestamptz not null default now()
);

alter table profiles add column club_id uuid references clubs (id) on delete set null;

alter table rentals add column color smallint not null default -2
  check (color between -2 and 11);

alter table schedule_settings add column kiosk_dark boolean not null default true;

-- Data-migrate distinct non-empty profiles.club → clubs (round-robin palette),
-- link players by name match. `distinct` guarantees unique names, so no
-- on-conflict handling is needed.
insert into clubs (name, color)
  select c.club, (row_number() over (order by c.club) - 1)::int % 12
  from (select distinct club from profiles where trim(club) <> '') c;
update profiles p set club_id = c.id from clubs c where c.name = p.club;

-- Rebuild the players view to expose club_id + club_color. Reproduces the
-- live 0002 column list (id, display_name, club, nick) verbatim and appends
-- the two new columns.
drop view players;
create view players as
  select p.id, p.display_name, p.club, p.nick,
         p.club_id, coalesce(c.color, -1) as club_color
  from profiles p left join clubs c on c.id = p.club_id
  where p.status = 'approved' and p.role <> 'kiosk';
revoke all on players from anon;
grant select on players to authenticated;

create or replace function set_player_club(p_user_id uuid, p_club_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  update profiles set club_id = p_club_id where id = p_user_id;
end; $$;

create or replace function upsert_club(p_id uuid, p_name text, p_color smallint)
returns clubs language plpgsql security definer set search_path = public as $$
declare v clubs;
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  if trim(coalesce(p_name,'')) = '' then raise exception 'empty_name'; end if;
  if p_id is null then
    insert into clubs (name, color) values (trim(p_name), p_color) returning * into v;
  else
    update clubs set name = trim(p_name), color = p_color where id = p_id returning * into v;
  end if;
  return v;
end; $$;

create or replace function delete_club(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  delete from clubs where id = p_id;  -- profiles.club_id set null via FK
end; $$;

alter table clubs enable row level security;
create policy clubs_select on clubs for select using (is_approved_or_kiosk());
create policy clubs_write on clubs for all using (is_admin()) with check (is_admin());
-- (clubs writes normally go via RPCs; policy covers direct admin reads/writes.)

alter publication supabase_realtime add table clubs;
commit;
