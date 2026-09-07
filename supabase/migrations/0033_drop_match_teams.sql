-- 0033 — set_calendar_match_teams_for odchází, match_teams ještě zůstává.
--
-- 0032 přesunulo match_calendar_followers i my_future_matches na
-- calendar_teams a task 3 na set_calendar_teams_for přepsal i akci
-- calendar-manage. Starou RPC tedy nikdo nevolá — jde pryč. Její tvar
-- (jen jména týmů) už stejně neumí říct, do kterého kalendáře a s jakou
-- barvou tým patří.
--
-- Sloupec match_teams je jiný případ: čte ho appka, která je právě
-- venku (1.2.1, CalendarLink.matchTeams). Kdyby zmizel, hráč by v ní u
-- propojení kalendáře viděl „Žádný tým" — ne chybu, ale nepravdu o
-- vlastním nastavení, a to je horší než hláška. Zůstane proto jako
-- zrcadlo: set_calendar_teams_for do něj jména dopisuje, takže stará
-- appka čte pravdu (zapsat ji už neumí — akce match_teams neexistuje,
-- to je čitelné selhání). Dropnout ho může migrace, až bude venku
-- vydání s novou obrazovkou.

drop function set_calendar_match_teams_for(uuid, text[]);

comment on column google_calendar_links.match_teams is
  'DEPRECATED (0033): a read-only mirror of calendar_teams.team for app builds up to 1.2.1. calendar_teams is the truth; drop this once a build with the new screen is out.';

-- Same body as 0032, plus the mirror write.
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
           'team', team, 'calendar', calendar, 'color_id', color_id)
           order by team), '[]'::jsonb)
    into v_previous
    from calendar_teams where user_id = p_user;

  delete from calendar_teams where user_id = p_user;
  insert into calendar_teams (user_id, team, calendar, color_id)
  select p_user, trim(x.team), coalesce(x.calendar, 'primary'), x.color_id
    from jsonb_to_recordset(v_teams) as x(team text, calendar text, color_id smallint);

  -- The mirror the older app reads; see the note at the top.
  update google_calendar_links
     set match_teams = coalesce(
           (select array_agg(team order by team)
              from calendar_teams where user_id = p_user), '{}'),
         updated_at = now()
   where user_id = p_user;

  return v_previous;
end;
$$;
