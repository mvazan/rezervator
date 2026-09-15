-- 0042 — barva rezervací přechází na Google paletu (klientská změna).
--
-- „Barva mých rezervací" dosud brala paletu appky (ClubColors, 0-8);
-- Google kalendář má svých jedenáct (Levandulová, Šalvějová, …). Hráč tak
-- vybíral modrou dvěma různými slovníky. Nový picker nabízí tu Google
-- jedenáctku plus vlastní kolečko, a KAŽDÝ výběr ukládá jako RGB
-- (0x1000000|rgb) — stejně jako custom. Tím odpadá kolize s barvou oddílu:
-- own_color je pak jen -1 (podle oddílu) nebo zabalené RGB, a na tabuli ho
-- clubTint kreslí přes customTint, čitelně ve světlém i tmavém tématu.
--
-- Tady jen srovnáme, co už v profilech je: paletový index 0-8 převedeme na
-- jeho vlastní odstín jako custom, aby ho nový picker ukázal jako vybranou
-- barvu (kolečko), ne jako nic. Bez převodu by hráč viděl barevnou dlaždici,
-- ale prázdný výběr — jeho stará barva v nové paletě není.
--
-- CHECK ZŮSTÁVÁ povolený (own_color between -1 and 11 or custom): appka
-- 1.2.6 v telefonech pořád píše paletový index a nesmí dostat chybu. Nová
-- appka žádný index 0-8 nezapíše; clubTint stejně obojí nakreslí správně,
-- takže je to přechodně neškodné.

-- Reprezentativní odstín každé staré palety = její sytá varianta (světlý
-- popředek z ClubColors._p), zabalená jako custom. Hue přežije, customTint
-- z něj odvodí obě varianty tak jako u kterékoli ručně vybrané barvy.
update profiles set own_color = 16777216 + case own_color
    when 0 then x'1E3A8A'::int  -- Modrá
    when 1 then x'166534'::int  -- Zelená
    when 2 then x'991B1B'::int  -- Červená
    when 3 then x'5B21B6'::int  -- Fialová
    when 4 then x'115E59'::int  -- Tyrkys
    when 5 then x'9D174D'::int  -- Růžová
    when 6 then x'854D0E'::int  -- Žlutá
    when 7 then x'44403C'::int  -- Hnědá
    when 8 then x'334155'::int  -- Šedá
  end
where own_color between 0 and 8;

comment on column profiles.own_color is
  'The player''s own reservations in their own view (0024): -1 = the club colour, 0x1000000|rgb a hand-picked or Google-palette colour. Palette indices 0-11 are legacy — the 1.2.6 app still writes them and clubTint still renders them, but the current app writes only -1 or a packed RGB (0042).';
