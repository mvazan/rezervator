-- 0056 — Klubovna joins the views the app can open at launch.
--
-- default_view was calendar | trainings (0029); the home shell has three
-- views since Klubovna became a tab, and the profile may now pick any of
-- them. Widening a CHECK needs no data change: every stored value stays valid.

alter table profiles
  drop constraint profiles_default_view_check,
  add constraint profiles_default_view_check
    check (default_view in ('calendar', 'trainings', 'clubhouse'));

comment on column profiles.default_view is
  'View the app opens at launch: calendar | trainings | clubhouse.';
