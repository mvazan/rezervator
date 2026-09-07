-- 0037 — team_colors: loses its write grant, and set_team_colors_for stops
-- depending on the caller to de-dupe.
--
-- Two review findings against 0036:
--
-- 1. team_colors' own policy (`using`/`with check`, no `for` clause) is FOR
--    ALL, and 0017's `alter default privileges ... grant select, insert,
--    update, delete on tables to authenticated` reaches every table created
--    after it, team_colors included — so, unlike the RLS-and-full-grants
--    the 0036 header comment argues for, a client CAN write the table
--    directly. Nothing does: Api.setTeamColors posts to calendar-manage
--    (set_team_colors_for) precisely so a colour change repaints the
--    affected future Google Calendar events in the same request — a direct
--    write would store a colour Google never learns about, breaking the
--    "one colour, both places" invariant this table exists for, with no
--    per-user row cap either. calendar_teams lost the same grant for the
--    same reason (0035); this does to team_colors what that one did there.
--
-- 2. set_team_colors_for's `insert ... on conflict (user_id, team) do
--    update` fails outright ("cannot affect row a second time") if the SAME
--    team appears twice in one payload — safe today only because
--    validateTeamColors (calendar-manage's caller) already de-dupes before
--    the RPC ever sees the array. Redefined here so the statement itself
--    collapses a repeated team name (first occurrence, by original array
--    position, wins — the same tie-break validateTeamColors uses) instead
--    of trusting the caller forever.

drop policy team_colors_own on team_colors;
create policy team_colors_own on team_colors
  for select using (user_id = auth.uid());
comment on table team_colors is
  'One row per player+team the player has coloured (0036) — independent of both team lists (profiles.followed_teams, calendar_teams): the single colour shown for that team in Můj přehled and in the Google Calendar event alike. No row = no colour; a linked calendar is not required. Read-only to the client (0037) — every write goes through calendar-manage (set_team_colors_for), which also repaints the affected future Google Calendar events in the same request.';

revoke insert, update, delete on team_colors from authenticated;

-- set_team_colors_for (0036), redefined only for the in-statement de-dupe
-- below — same signature, same contract (partial upsert/delete, returns
-- the previous state of only the named teams), same bounds.
create or replace function set_team_colors_for(p_user uuid, p_colors jsonb)
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

  -- Collapses a repeated team name itself (distinct on, ordered by each
  -- element's original array position via WITH ORDINALITY) instead of
  -- trusting the caller — a second occurrence for the same team used to
  -- make ON CONFLICT raise "cannot affect row a second time".
  insert into team_colors (user_id, team, color_id)
  select p_user, x.team, x.color_id
    from (
      select distinct on (trim(y.team))
             trim(y.team) as team, y.color_id
        from jsonb_array_elements(v_colors) with ordinality as e(elem, ord)
        cross join lateral jsonb_to_record(e.elem) as y(team text, color_id smallint)
        order by trim(y.team), e.ord
    ) x
    where x.color_id is not null
  on conflict (user_id, team) do update set color_id = excluded.color_id;

  return v_previous;
end;
$$;
revoke all on function set_team_colors_for(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function set_team_colors_for(uuid, jsonb) to service_role;
