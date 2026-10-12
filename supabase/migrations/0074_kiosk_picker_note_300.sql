-- 0074 — the kiosk's two notices, the warning in the status bar (0068) and
-- the note in the name picker (0070), may run to 300 characters, up from
-- 200: room to say where, why and until when. Each check is replaced in
-- place; every text already saved is at most 200 characters, so it holds.
--
-- Re-runnable on purpose, like 0064 and 0065.

alter table schedule_settings
  drop constraint if exists schedule_settings_kiosk_warning_check;
alter table schedule_settings
  add constraint schedule_settings_kiosk_warning_check
    check (kiosk_warning is null
           or char_length(btrim(kiosk_warning)) between 1 and 300);

alter table schedule_settings
  drop constraint if exists schedule_settings_kiosk_picker_note_check;
alter table schedule_settings
  add constraint schedule_settings_kiosk_picker_note_check
    check (kiosk_picker_note is null
           or char_length(btrim(kiosk_picker_note)) between 1 and 300);
