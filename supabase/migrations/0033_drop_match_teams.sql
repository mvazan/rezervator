-- 0033 — match_teams and set_calendar_match_teams_for are dead weight.
--
-- 0032 already moved match_calendar_followers and my_future_matches onto
-- calendar_teams; this task (3) moved calendar-manage's team-following
-- action (now `teams`, was `match_teams`) onto set_calendar_teams_for too.
-- Nothing in the schema or the edge functions reads either the column or
-- the function any more, so — append-only history rule aside — this is a
-- genuine DROP, not a rename: match_teams' shape (team names only, no
-- calendar/colour) can no longer represent what a followed team is.
--
-- Residual risk, accepted (see the task 3 report): the shipped Flutter app
-- (pre-Task-4) still reads `match_teams` off the google_calendar_links
-- realtime stream (CalendarLink.matchTeams). That read degrades
-- gracefully — the JSON key is simply absent, and
-- `json['match_teams'] as List? ?? const []` resolves to an empty list, no
-- crash — so the "Zápasy v kalendáři" summary shows "Žádný tým" until the
-- app is updated. The WRITE side (calendar-manage's `match_teams` action)
-- already stopped working the moment this task's edge functions deployed,
-- independently of this migration: the action itself was replaced by
-- `teams`, which speaks a different payload shape the old app never sends.

drop function set_calendar_match_teams_for(uuid, text[]);

alter table google_calendar_links drop column match_teams;
