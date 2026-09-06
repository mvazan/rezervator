-- 0029 — two profile choices for the new Moje tréninky view.
--
-- followed_teams: the teams whose matches the player wants to SEE in the
-- app's upcoming list. Display only — the Google Calendar sync keeps its own
-- choice on google_calendar_links.match_teams and is not touched here; a
-- player manages the two lists separately.
--
-- default_view: which view the app opens at launch — the calendar (today's
-- behaviour, hence the default) or the upcoming list. A tap in the app
-- changes the view for that run only; this is what the next launch reads.

alter table profiles
  add column followed_teams text[] not null default '{}'
    check (coalesce(array_length(followed_teams, 1), 0) <= 20),
  add column default_view text not null default 'calendar'
    check (default_view in ('calendar', 'trainings'));

comment on column profiles.followed_teams is
  'Teams whose matches the player sees in Moje tréninky (names as in priority_slots.home_team/away_team). Display only; the calendar sync has its own list on google_calendar_links.';
comment on column profiles.default_view is
  'View the app opens at launch: calendar | trainings.';

-- Own row only (profiles_update_own); the whole-row UPDATE stays revoked
-- (0001/0017) and these columns join display_name, fcm_token and own_color.
grant update (followed_teams, default_view) on profiles to authenticated;
