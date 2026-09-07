-- 0036 — barva týmu patří týmu, ne kalendáři.
--
-- color_id dosud bydlelo na calendar_teams, takže ho měl jen hráč s
-- propojeným kalendářem, a navíc u jiného seznamu týmů (calendar_teams —
-- kalendář), než jaký kreslí Můj přehled (profiles.followed_teams). Barva je
-- ale hráčova preference k týmu samotnému, nezávislá na obou seznamech —
-- proto vlastní tabulka, klíčovaná (user_id, team) stejně jako
-- calendar_teams, ale bez vazby na kalendář a bez nutnosti propojeného účtu.
--
-- RLS je jako u profiles.own_color: barva je preference, appka ji píše
-- přímo (plné grants + RLS, žádný server round trip) — na rozdíl od
-- calendar_teams, kde zápis spouští Google práci a proto smí jen server
-- (0035). set_team_colors_for níže přesto existuje: volá ji calendar-manage
-- při ukládání barvy z kalendářové obrazovky, aby rovnou přepsala budoucí
-- Google události (stejný důvod jako u set_training_color_for, 0034).

create table team_colors (
  user_id  uuid not null references profiles(id) on delete cascade,
  team     text not null,
  color_id smallint not null check (color_id between 1 and 11),
  primary key (user_id, team)
);
comment on table team_colors is
  'One row per player+team the player has coloured (0036) — independent of both team lists (profiles.followed_teams, calendar_teams): the single colour shown for that team in Můj přehled and in the Google Calendar event alike. No row = no colour; a linked calendar is not required.';
comment on column team_colors.color_id is
  'Google Calendar event colorId (1-11) — the same eleven calendar_teams.color_id used before 0036 moved it here.';

-- Vlastní řádek, obě strany — appka tabulku streamuje a píše přímo, žádný
-- routing přes server (na rozdíl od calendar_teams, 0035).
alter table team_colors enable row level security;
create policy team_colors_own on team_colors
  using (user_id = auth.uid()) with check (user_id = auth.uid());

alter publication supabase_realtime add table team_colors;

-- Přesyp existujících barev, než calendar_teams o sloupec přijde. calendar_teams
-- má PK (user_id, team), takže tu nemůže dojít ke konfliktu.
insert into team_colors (user_id, team, color_id)
select user_id, team, color_id from calendar_teams where color_id is not null;

alter table calendar_teams drop column color_id;
comment on table calendar_teams is
  'One row per player+followed team (0032, replaces google_calendar_links.match_teams): which of the two calendars its matches go to. Read-only to the client (0035) — every write goes through calendar-manage (set_calendar_teams_for), which also keeps match_teams mirrored for the 1.2.1 app. Colour moved to team_colors (0036) — independent of this table now.';

-- ---------------------------------------------------------------------------
-- my_future_matches: barvu bere z team_colors, ne z calendar_teams, pro
-- stejný tým, který lateral join výš už vyřešil (derby: domácí tým vyhrává,
-- beze změny). Návratový tvar (sloupce/typy) je stejný jako v 0032, proto
-- create or replace — zachová si granty (revoke/grant níže je jen pro
-- jistotu, kdyby se někdy rozjely jinak).
-- ---------------------------------------------------------------------------
create or replace function my_future_matches(p_user uuid)
returns table (
  match_id uuid, date date, starts_at time, ends_at time,
  home_team text, away_team text, is_away boolean, description text,
  alley_name text, calendar text, color_id smallint)
language sql stable security definer set search_path = public
as $$
  select s.id, s.date, s.starts_at, s.ends_at,
         s.home_team, s.away_team, s.is_away, s.description, t.name,
         c.calendar, tc.color_id
    from priority_slots s
    join priority_slot_types y on y.id = s.type_id and y.is_match
    join tenants t on t.id = s.tenant_id
    join profiles p on p.id = p_user and p.tenant_id = s.tenant_id
    join google_calendar_links l on l.user_id = p_user
    join lateral (
      select ct.team, ct.calendar
        from calendar_teams ct
        where ct.user_id = p_user and ct.team in (s.home_team, s.away_team)
        order by (ct.team = s.home_team) desc
        limit 1
    ) c on true
    left join team_colors tc on tc.user_id = p_user and tc.team = c.team
    where s.parent_id is null
      and s.date >= (now() at time zone 'Europe/Prague')::date
    order by s.date, s.starts_at;
$$;
revoke all on function my_future_matches(uuid) from public, anon, authenticated;
grant execute on function my_future_matches(uuid) to service_role;

-- set_calendar_teams_for: barva ven. calendar_teams už sloupec color_id
-- nemá, takže i kdyby volající jsonb pole poslal, jsonb_to_recordset ho
-- potichu zahodí (neznámý klíč v objektu, ne chyba). Kontrakt teď:
-- [{team, calendar}] dovnitř i ven — Task 2 na to přepíše calendar-manage.
-- Tělo je jinak 0033 beze změny (barva pryč z obou jsonb_build_object) —
-- včetně zápisu do match_teams, zrcadla pro appku 1.2.1, které by create or
-- replace tiše smazalo, kdyby vycházelo jen z 0032.
create or replace function set_calendar_teams_for(p_user uuid, p_teams jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_teams jsonb := coalesce(p_teams, '[]'::jsonb);
  v_previous jsonb;
begin
  if jsonb_typeof(v_teams) <> 'array' then
    raise exception 'bad_teams';
  end if;
  if jsonb_array_length(v_teams) > 20 then
    raise exception 'bad_teams';
  end if;
  if not exists (select 1 from google_calendar_links where user_id = p_user) then
    raise exception 'unknown_link';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'team', team, 'calendar', calendar)
           order by team), '[]'::jsonb)
    into v_previous
    from calendar_teams where user_id = p_user;

  delete from calendar_teams where user_id = p_user;
  insert into calendar_teams (user_id, team, calendar)
  select p_user, trim(x.team), coalesce(x.calendar, 'primary')
    from jsonb_to_recordset(v_teams) as x(team text, calendar text);

  -- The mirror the older (1.2.1) app reads; see 0033.
  update google_calendar_links
     set match_teams = coalesce(
           (select array_agg(team order by team)
              from calendar_teams where user_id = p_user), '{}'),
         updated_at = now()
   where user_id = p_user;

  return v_previous;
end;
$$;

-- set_team_colors_for: nová RPC, server-only jako ostatní kalendářní RPC —
-- volá ji jen calendar-manage (Task 2), aby po uložení barvy hned přepsala
-- budoucí zápasy v Google kalendáři. Na rozdíl od set_calendar_teams_for
-- NENÍ to full-replace: mění/maže jen řádky pro týmy uvedené v p_colors,
-- ostatní barvy hráče nechává být (barva žije nezávisle na tom, co je zrovna
-- v calendar_teams). color_id null u položky smaže ten řádek. Meze bere z
-- tabulkových CHECK (check_violation), jako set_calendar_teams_for bere
-- svoje z calendar_teams — jen počet položek (≤ 40) hlídá tady, protože to
-- žádný CHECK spočítat neumí. Vrací PŘEDCHOZÍ stav pouze pro týmy, které
-- volání zmiňuje (tým bez předchozí barvy v návratu chybí).
create function set_team_colors_for(p_user uuid, p_colors jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_colors jsonb := coalesce(p_colors, '[]'::jsonb);
  v_previous jsonb;
begin
  if jsonb_typeof(v_colors) <> 'array' then
    raise exception 'bad_colors';
  end if;
  if jsonb_array_length(v_colors) > 40 then
    raise exception 'bad_colors';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('team', tc.team, 'color_id', tc.color_id)
           order by tc.team), '[]'::jsonb)
    into v_previous
    from team_colors tc
    where tc.user_id = p_user
      and tc.team in (
        select trim(y.team) from jsonb_to_recordset(v_colors) as y(team text, color_id smallint)
      );

  delete from team_colors
    where user_id = p_user
      and team in (
        select trim(y.team) from jsonb_to_recordset(v_colors) as y(team text, color_id smallint)
          where y.color_id is null
      );

  insert into team_colors (user_id, team, color_id)
  select p_user, trim(y.team), y.color_id
    from jsonb_to_recordset(v_colors) as y(team text, color_id smallint)
    where y.color_id is not null
  on conflict (user_id, team) do update set color_id = excluded.color_id;

  return v_previous;
end;
$$;
revoke all on function set_team_colors_for(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function set_team_colors_for(uuid, jsonb) to service_role;
