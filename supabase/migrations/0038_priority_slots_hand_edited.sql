-- 0038 — priority_slots.hand_edited: the import only overwrites what it
-- wrote.
--
-- Matches come from two places. The federation's schedule arrives as a
-- file and tool/import_matches.py writes it into priority_slots, each row
-- keyed by import_key; the admin also enters matches by hand in the app
-- (a friendly, a cup tie), and those rows carry no import_key. The
-- import never reads or writes a row without a key — that has always been
-- the line between "the schedule's" and "the admin's".
--
-- What that line did not cover: a scheduled match the admin CORRECTED in
-- the app — the federation phoned a new time, the file is the old one. A
-- re-import that trusts the file blindly would revert the correction, and
-- nothing in the row said it had been touched. This column is that memory:
-- a BEFORE UPDATE trigger sets it whenever an imported row's match columns
-- change outside an import run, and the import skips flagged rows (listing
-- them) unless told to overwrite with --force, which also clears the flag.
--
-- The import announces itself with set_config('import.run', 'on', true) at
-- the top of its transaction, so its own updates never flag. A no-op
-- update (same values) never flags either — the trigger compares the
-- match columns, not the fact of an UPDATE. The app never writes the
-- column; it only shows it ("upraveno ručně" in Správa → Zápasy).

alter table priority_slots
  add column hand_edited boolean not null default false;

comment on column priority_slots.hand_edited is
  'Imported match (import_key set) whose match columns changed outside an '
  'import run (session setting import.run <> ''on''). The next import '
  'leaves the row alone unless forced. Set by priority_slots_hand_edit.';

create or replace function priority_slots_mark_hand_edit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.import_key is not null
     and current_setting('import.run', true) is distinct from 'on'
     and (old.date, old.starts_at, old.ends_at, old.home_team, old.away_team,
          old.prep_minutes, old.description, old.is_away)
         is distinct from
         (new.date, new.starts_at, new.ends_at, new.home_team, new.away_team,
          new.prep_minutes, new.description, new.is_away) then
    new.hand_edited := true;
  end if;
  return new;
end;
$$;

create trigger priority_slots_hand_edit
  before update on priority_slots
  for each row execute function priority_slots_mark_hand_edit();
