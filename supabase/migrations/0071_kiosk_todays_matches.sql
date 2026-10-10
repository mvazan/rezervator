-- 0071 — today's matches in the kiosk's status bar (Správa → Kiosk →
-- Obrazovka kiosku → Dnešní zápasy v záhlaví): on by default, as the kiosk
-- has always shown them beside the clock; off = the bar leaves them out and
-- says what it says on a day without a match. The kiosk applies it itself
-- from the settings row it already reads.
--
-- public_week needs nothing: since 0068 it hands out an allow-list of its
-- six settings, so this column never reaches anon.
--
-- Re-runnable on purpose, like 0064 and 0065.

alter table schedule_settings
  add column if not exists kiosk_todays_matches boolean not null default true;
