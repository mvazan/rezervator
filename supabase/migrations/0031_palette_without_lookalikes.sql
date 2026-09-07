-- 0031 — the palette drops the three colours that only looked like their
-- neighbours.
--
-- Measured as CIEDE2000 over the swatches the picker actually shows (the dark
-- backgrounds), three entries sat under ΔE 10 from another entry, which is
-- close enough that two circles side by side read as the same colour:
-- Indigo ~ Modrá (5.6), Oranžová ~ Červená (7.8), Limetka ~ Zelená (9.5).
-- They go; the nine that stay are at least ΔE 10.3 apart. Nothing is lost for
-- the user — 0030 made every colour hand-pickable, so orange is still one tap
-- away, it just is not one of the presets any more.
--
-- Rows keep the colour they have. A dropped index becomes that exact colour
-- as a hand-picked one (measured to shift ΔE 3.8-7.2, against 5.6-9.5 for
-- snapping it onto the nearest surviving preset), and the survivors shift
-- down into the gaps. One CASE per table so every row is mapped from its
-- original value, never twice.

create or replace function palette_0031_remap(v integer) returns integer
  language sql immutable as $$
  select case v
    when 3 then 16777216 | x'7C2D12'::integer   -- Oranžová, now hand-picked
    when 8 then 16777216 | x'365314'::integer   -- Limetka
    when 9 then 16777216 | x'312E81'::integer   -- Indigo
    when 4 then 3   -- Fialová
    when 5 then 4   -- Tyrkys
    when 6 then 5   -- Růžová
    when 7 then 6   -- Žlutá
    when 10 then 7  -- Hnědá
    when 11 then 8  -- Šedá
    else v          -- 0-2 keep their place, -1/-2 are not palette entries
  end $$;

update profiles set own_color = palette_0031_remap(own_color)
where own_color between 3 and 11;
update clubs set color = palette_0031_remap(color) where color between 3 and 11;
update rentals set color = palette_0031_remap(color) where color between 3 and 11;
update priority_slot_types set color = palette_0031_remap(color)
where color between 3 and 11;

drop function palette_0031_remap(integer);

alter table profiles
  drop constraint profiles_own_color_check,
  add constraint profiles_own_color_check check (
    own_color between -1 and 8 or own_color between 16777216 and 33554431);

alter table clubs
  drop constraint clubs_color_check,
  add constraint clubs_color_check check (
    color between -1 and 8 or color between 16777216 and 33554431);

alter table rentals
  drop constraint rentals_color_check,
  add constraint rentals_color_check check (
    color between -2 and 8 or color between 16777216 and 33554431);

alter table priority_slot_types
  drop constraint priority_slot_types_color_check,
  add constraint priority_slot_types_color_check check (
    color between -1 and 8 or color between 16777216 and 33554431);
