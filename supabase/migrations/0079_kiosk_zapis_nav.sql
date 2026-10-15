-- 0079 — paging through the kiosk's Zápis (Správa → Kiosk → Obrazovka
-- kiosku → Listování v zápisu): on by default. The Zápis then has a bar of
-- its own — ‹ › to the previous and the next match with a score, a tap on
-- either team for that team's matches, and a × — instead of the bare sheet.
-- The kiosk applies it itself from the settings row it already reads.
--
-- public_week needs nothing: since 0068 it hands out an allow-list of its
-- six settings, so this column never reaches anon.
--
-- Re-runnable on purpose, like 0064 and 0065.

alter table schedule_settings
  add column if not exists kiosk_zapis_nav boolean not null default true;
