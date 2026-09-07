-- 0035 — calendar_teams: joins Realtime, loses its write grant.
--
-- Two review findings against 0032:
--
-- 1. calendar_teams was never added to the supabase_realtime publication.
--    `supabase db dump` does not emit publications, so neither the schema
--    snapshot nor a plain migration read catches a missing one —
--    myCalendarTeamsProvider (lib/data/providers.dart) `.stream()`s the
--    table regardless, so with no publication membership no change event
--    EVER arrives: tick a team, close the sheet, reopen — the tick is gone
--    until the app restarts. google_calendar_links (0023) already got this
--    right; calendar_teams did not.
--
-- 2. 0017's `alter default privileges ... grant select, insert, update,
--    delete on tables to authenticated` reaches every table created after
--    it, calendar_teams (0032) included — combined with the table's own
--    `for all` policy, a client can write calendar_teams directly. Nothing
--    in the app does (Api.setCalendarTeams posts to the calendar-manage
--    edge function), so this is pure exposure: a direct write bypasses the
--    edge function's ≤20-item cap, the 80-char name cap, AND — worse — the
--    match_teams mirror that lives only in set_calendar_teams_for (0033),
--    desyncing exactly what that migration exists to protect. The table
--    stays readable straight from the client (that part of 0032's design —
--    no RPC round trip just to show a tick — is unaffected); only the
--    WRITE path narrows to the one that already goes through the server.

alter publication supabase_realtime add table calendar_teams;

drop policy calendar_teams_own on calendar_teams;
create policy calendar_teams_own on calendar_teams
  for select using (user_id = auth.uid());
comment on table calendar_teams is
  'One row per player+followed team (0032, replaces google_calendar_links.match_teams): which of the two calendars its matches go to and which Google event colourId they get. Read-only to the client (0035) — every write goes through calendar-manage (set_calendar_teams_for), which also keeps match_teams mirrored for the 1.2.1 app.';

revoke insert, update, delete on calendar_teams from authenticated;
