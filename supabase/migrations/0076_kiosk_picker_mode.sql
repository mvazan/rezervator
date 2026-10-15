-- 0076 — how the kiosk's name picker starts (Správa → Kiosk → Obrazovka
-- kiosku → Výběr hráče):
--
--   letters  the first letters of the board names, as before (the default)
--   clubs    the alley's clubs as tiles in their colour, then the club's
--            names (letters within the club when it has too many); the
--            players without a club under „Ostatní“
--   both     the club tiles and, under them, the first letters
--
-- Re-runnable on purpose, like 0064 and 0065. public_week is an allow-list
-- since 0069, so the column never reaches anon.

alter table schedule_settings
  add column if not exists kiosk_picker_mode text not null default 'letters'
    constraint schedule_settings_kiosk_picker_mode_check
    check (kiosk_picker_mode in ('letters', 'clubs', 'both'));
