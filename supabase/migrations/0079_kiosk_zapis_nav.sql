-- 0079 — paging through the kiosk's Zápis (Správa → Kiosk → Obrazovka
-- kiosku → Listování v zápisu):
--
--   off    the bare sheet, as before
--   bar    a bar above the sheet: ‹ › to the previous and the next match
--          with a score, the two teams (a tap lists that team's matches),
--          the day and a × (the default)
--   sides  no bar: ‹ › beside the Zápis (floating over it at full screen,
--          a tap on the sheet hides and shows them and the ×), a tap on a
--          team's name in the sheet lists its matches
--
-- A swipe across the sheet pages like the arrows, in either mode. The
-- kiosk applies it itself from the settings row it already reads.
--
-- Re-runnable on purpose, like 0064 and 0065. public_week is an allow-list
-- since 0069, so the column never reaches anon.

alter table schedule_settings
  add column if not exists kiosk_zapis_nav text not null default 'bar'
    constraint schedule_settings_kiosk_zapis_nav_check
    check (kiosk_zapis_nav in ('off', 'bar', 'sides'));
