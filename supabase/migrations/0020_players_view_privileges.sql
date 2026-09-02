-- 0020 — the players view is read-only again, and default table privileges
-- for authenticated are exactly select/insert/update/delete.
--
-- 0019 dropped and recreated the players view; the recreated object picked
-- up the default privileges (ALL for authenticated — the hosted defaults
-- grant everything, and 0017 only added to them) and 0019 re-granted
-- SELECT without revoking the rest. Harmless in practice (the view joins,
-- so it is not updatable), wrong on paper and not what 0017 promised.
-- Revoke again, and reset the defaults so every future table gets the
-- same arwd shape on hosted and local backends alike.

revoke insert, update, delete, truncate, references, trigger, maintain
  on players from authenticated;

alter default privileges for role postgres in schema public
  revoke all on tables from authenticated;
alter default privileges for role postgres in schema public
  grant select, insert, update, delete on tables to authenticated;
