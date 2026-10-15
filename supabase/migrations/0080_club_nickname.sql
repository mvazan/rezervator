-- 0080 — a club's nickname (Správa → Oddíly → oddíl → Přezdívka): the short
-- name the app shows instead of the club's — and instead of the start of
-- its teams' names, the club's name on the federation's site (site_name, or
-- the club's own name when it is not linked): „TJ Sokol Brno IV B“ reads
-- „Sokol IV B“. null = the full name. Display only: the stored team names
-- stay, since matches, follows, colours and calendars are keyed by them.
--
-- The admin writes it straight into the row (clubs_write, 0005); 1–30
-- characters, not blank. Re-runnable on purpose, like 0064 and 0065.

alter table clubs
  add column if not exists nickname text
    constraint clubs_nickname_check
    check (nickname is null or char_length(btrim(nickname)) between 1 and 30);
