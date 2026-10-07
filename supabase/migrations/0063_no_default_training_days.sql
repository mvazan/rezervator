-- 0063 — a new kuželna starts with no training days.
--
-- schedule_settings.training_weekdays defaulted to Monday, Tuesday and
-- Thursday (0001, the first alley's own days), so every alley created since
-- started with those three days open for booking before its admin had said
-- anything. A new alley now starts with none: the admin ticks its own days in
-- Správa → Rozvrh. Existing alleys keep what they have.

alter table schedule_settings alter column training_weekdays set default '{}';
