-- 0075 — two sizes for the kiosk (Správa → Kiosk → Obrazovka kiosku):
--
--   kiosk_warning_font_size  the text of both red notices, the warning in
--                            the status bar (0068) and the note in the name
--                            picker (0070) — one style for both. 22 px by
--                            default: the size of the picker's own hint
--                            („Vyber první písmeno…“), which the note used
--                            to sit under at a smaller 18.
--   kiosk_day_matches_width  the width of the day's matches dialog a tap on
--                            a board day header opens. The app keeps 340;
--                            the kiosk starts wider, a wall display has
--                            the room.
--
-- Re-runnable on purpose, like 0064 and 0065. public_week is an allow-list
-- since 0069, so neither column reaches anon.

alter table schedule_settings
  add column if not exists kiosk_warning_font_size smallint not null default 22
    constraint schedule_settings_kiosk_warning_font_size_check
    check (kiosk_warning_font_size between 14 and 40);

alter table schedule_settings
  add column if not exists kiosk_day_matches_width smallint not null default 560
    constraint schedule_settings_kiosk_day_matches_width_check
    check (kiosk_day_matches_width between 340 and 1200);
