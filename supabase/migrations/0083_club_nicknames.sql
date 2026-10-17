-- 0083 — nicknames for the other clubs (Správa → Oddíly → Ostatní oddíly):
-- the clubs whose teams come to play, or that ours visit, have no clubs row
-- of ours, yet the admin wants their names short too — „TJ Sokol Husovice
-- E“ reads „Husovice E“. A row here is such a club's name, as it starts its
-- teams' names (on the federation's site), and the nickname the app shows
-- instead, exactly like clubs.nickname (0080) does for the alley's own
-- clubs. Display only: the stored team names stay.
--
-- The admin writes through set_club_nickname (null or blank = remove);
-- every signed-in member of the alley (and its kiosk) reads the table.

create table if not exists club_nicknames (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  name text not null,
  nickname text not null,
  created_at timestamptz not null default now(),
  constraint club_nicknames_name_check
    check (name = btrim(name) and char_length(name) between 1 and 80),
  constraint club_nicknames_nickname_check
    check (nickname = btrim(nickname) and char_length(nickname) between 1 and 30),
  constraint club_nicknames_tenant_name_key unique (tenant_id, name)
);
comment on table club_nicknames is
  'Nicknames for clubs that are not the alley''s own (0083): name = the club''s name as it starts its teams'' names, nickname = what the app shows instead (as clubs.nickname, 0080). Display only. Written only through set_club_nickname.';

alter table club_nicknames enable row level security;
drop policy if exists club_nicknames_select on club_nicknames;
create policy club_nicknames_select on club_nicknames
  for select using (tenant_id = current_tenant_id() and is_approved_or_kiosk());

revoke all on club_nicknames from anon, authenticated;
grant all on club_nicknames to service_role;
grant select on club_nicknames to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime'
                    and schemaname = 'public'
                    and tablename = 'club_nicknames') then
    alter publication supabase_realtime add table club_nicknames;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- set_club_nickname: the admin's one write
-- ---------------------------------------------------------------------------
-- [p_name]'s nickname; null or blank removes it. An own club's names (its
-- name or its name on the federation's site) are refused: that club has
-- its nickname on its own row (0080).
create or replace function set_club_nickname(p_name text, p_nickname text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_tenant uuid := current_tenant_id();
  v_name text := btrim(coalesce(p_name, ''));
  v_nick text := nullif(btrim(coalesce(p_nickname, '')), '');
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if v_name = '' then
    raise exception 'empty_name';
  end if;
  if char_length(v_name) > 80 then
    raise exception 'club_name_too_long';
  end if;
  if char_length(v_nick) > 30 then
    raise exception 'club_nickname_too_long';
  end if;
  if exists (select 1 from clubs c
              where c.tenant_id = v_tenant
                and v_name in (btrim(c.name), btrim(c.site_name))) then
    raise exception 'own_club';
  end if;
  if v_nick is null then
    delete from club_nicknames where tenant_id = v_tenant and name = v_name;
  else
    insert into club_nicknames (tenant_id, name, nickname)
    values (v_tenant, v_name, v_nick)
    on conflict (tenant_id, name) do update set nickname = excluded.nickname;
  end if;
end;
$$;
revoke all on function set_club_nickname(text, text) from public, anon;
grant execute on function set_club_nickname(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- team_shown: the other clubs' nicknames too
-- ---------------------------------------------------------------------------
-- As 0080, with club_nicknames' names as prefixes beside the own clubs'
-- names and site names. The longest matching prefix wins; on a tie the own
-- club's (set_club_nickname refuses those names, but a club renamed later
-- could meet one). Keep in step with NameDisplay (lib/domain/models.dart).
create or replace function team_shown(p_tenant uuid, p_team text)
returns text
language sql stable set search_path = public
as $$
  select coalesce((
    select p.nickname || substr(p_team, char_length(p.prefix) + 1)
      from (
        select btrim(c.nickname) as nickname, x.prefix, 0 as rank, c.id::text as tie
          from clubs c
          cross join lateral (values (btrim(c.site_name)), (btrim(c.name))) x(prefix)
         where c.tenant_id = p_tenant
           and c.nickname is not null
        union all
        select n.nickname, n.name, 1, n.name
          from club_nicknames n
         where n.tenant_id = p_tenant
      ) p
     where p.prefix <> ''
       and (p_team = p.prefix
            or left(p_team, char_length(p.prefix) + 1) = p.prefix || ' ')
     order by char_length(p.prefix) desc, p.rank, p.tie
     limit 1), p_team);
$$;
revoke all on function team_shown(uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- A nickname of another club retitles the calendar events already out there
-- ---------------------------------------------------------------------------
-- As clubs_enqueue_calendar (0080): every future match one of the club's
-- teams plays goes back to the queue for whoever has it in the calendar.
create or replace function club_nicknames_enqueue_calendar()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_tenant uuid;
  v_prefixes text[];
begin
  if tg_op = 'INSERT' then
    v_tenant := new.tenant_id;
    v_prefixes := array[new.name];
  elsif tg_op = 'UPDATE' then
    if (old.name, old.nickname) is not distinct from (new.name, new.nickname) then
      return null;
    end if;
    v_tenant := new.tenant_id;
    v_prefixes := array[old.name, new.name];
  else
    v_tenant := old.tenant_id;
    v_prefixes := array[old.name];
  end if;
  perform enqueue_match_calendar_sync(f.user_id, s.id)
     from priority_slots s
     join priority_slot_types y on y.id = s.type_id and y.is_match
     cross join lateral (
       select u from match_calendar_followers(s.tenant_id, s.home_team,
                                              s.away_team) u
       union
       select e.user_id from match_exceptions e where e.match_id = s.id
     ) f(user_id)
    where s.tenant_id = v_tenant
      and s.parent_id is null
      and s.date >= (now() at time zone 'Europe/Prague')::date
      and exists (
        select 1
          from unnest(v_prefixes) x(prefix)
          cross join unnest(array[s.home_team, s.away_team]) t(team)
         where t.team = x.prefix
            or left(t.team, char_length(x.prefix) + 1) = x.prefix || ' ');
  return null;
end;
$$;
revoke all on function club_nicknames_enqueue_calendar() from public, anon, authenticated;

create or replace trigger club_nicknames_enqueue_calendar
  after insert or update or delete on club_nicknames
  for each row execute function club_nicknames_enqueue_calendar();
