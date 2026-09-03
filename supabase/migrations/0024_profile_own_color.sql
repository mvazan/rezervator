-- 0024 — a player may pick their own colour for their own reservations.
--
-- The board is read by club colour (0003) and since the own-tint fix the
-- caller's bookings follow it too. A player who wants their own cells to
-- stand out picks a palette colour in Můj profil; -1 (the default) means
-- "podle oddílu". Only that player's own view uses it — everyone else keeps
-- seeing the club colour, and the kiosk board never reads it.

alter table profiles
  add column own_color smallint not null default -1
    check (own_color between -1 and 11);

comment on column profiles.own_color is
  'Palette index 0–11 the player chose for their own reservations in their own view; -1 = the club colour.';

-- Own row only (profiles_update_own); the whole-row UPDATE stays revoked
-- (0001/0017) and this column joins display_name and fcm_token.
grant update (own_color) on profiles to authenticated;
