# Barva týmu na jednom místě — plán

**Cíl:** barva týmu je jedna, nastavuje se v profilu u Mých týmů a platí všude —
pohár v Můj přehled i událost v Google kalendáři. Zůstává z Googlových
jedenácti, aby do kalendáře sedla bez překladu.

**Dnešní stav:** barva žije v `calendar_teams.color_id`, tedy jen pro toho, kdo
má propojený kalendář, a u jiného seznamu týmů (`calendar_teams`) než jaký
kreslí přehled (`profiles.followed_teams`). Seznamy zůstanou oddělené —
společná je jen barva.

## Global Constraints

- Barva = Google `colorId` 1–11 nebo `null` (bez barvy). Vlastní RGB API nebere.
- Seznamy týmů se nespojují: `followed_teams` řídí přehled, `calendar_teams`
  kalendář. Nová tabulka drží jen barvu, nezávisle na obou.
- Czech UI copy, English code and comments; `compareCzech` řazení.
- `flutter analyze` čistý, `flutter test` zelený (524); `deno check` pěti funkcí,
  `deno test` zelený; lokální `supabase db reset` + tenancy suite končí `ROLLBACK`.
- Migrace append-only, další volné číslo **0036**; pak `tool/schema_snapshot.sh`
  a `docs/SCHEMA.md`.
- Commit per task s `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

---

## Task 1 — Migrace 0036: barva k týmu, ne ke kalendáři

**Files:** create `supabase/migrations/0036_team_colors.sql`; modify
`supabase/tests/tenancy_rls.sql`, `docs/SCHEMA.md`; regenerate `supabase/schema.sql`.

```sql
create table team_colors (
  user_id  uuid not null references profiles(id) on delete cascade,
  team     text not null,
  color_id smallint not null check (color_id between 1 and 11),
  primary key (user_id, team)
);
```

- RLS: čte i píše jen vlastník (`user_id = auth.uid()`), jako `profiles`
  vlastní sloupce — barva je preference, ne routing, a appka ji střílí přímo.
  Přidat do publikace `supabase_realtime` (test z 0035 to hlídá).
- Přesyp: `insert into team_colors select user_id, team, color_id from
  calendar_teams where color_id is not null;` pak `alter table calendar_teams
  drop column color_id;`.
- `my_future_matches` bere `color_id` z `team_colors` (left join přes
  `t.user_id = p_user and t.team = <tým, který hráč sleduje>`), ne z
  `calendar_teams`.
- `set_calendar_teams_for` přestane brát a vracet `color_id` — jen `{team, calendar}`.
- Nová RPC `set_team_colors_for(p_user uuid, p_colors jsonb) returns jsonb`
  (server-only, jako ostatní kalendářní RPC): validuje ≤ 40 položek a barvu
  1–11 nebo null (null = řádek smazat), vrátí předchozí stav.

**SQL testy:** vlastník čte i píše svůj řádek, cizí ne; `color_id = 12` a `0`
skončí `check_violation`; `my_future_matches` vrátí barvu z `team_colors`;
`set_team_colors_for` vrátí předchozí stav a null barvu smaže. Notice
`OK: a team colour is the player's own, one per team, whatever the calendar does`.

---

## Task 2 — Edge funkce: barva se přebarví hned

**Files:** modify `supabase/functions/calendar-manage/index.ts`,
`supabase/functions/_shared/google_calendar.ts` (+ jeho test).

- `TeamChoice` ztrácí `color_id`; `validateTeamChoices` taky.
- Nový validátor `validateTeamColors(raw)` → `{team, color_id}[]`, stejné meze
  jako u týmů (trim, prázdné pryč, ≤ 80 znaků, `isEventColorId` nebo null).
- Akce `team_colors` s `[{team, color_id}]`: uloží přes `set_team_colors_for`
  a přepíše budoucí zápasy, aby se barva projevila hned (stejný tvar jako
  `training_color`). Chyby a `deferred` stejně jako jinde.
- `writeFutureMatches` čte barvu z řádku `my_future_matches` — beze změny kódu,
  jen se mění, odkud ji SQL bere.

---

## Task 3 — Dart a obrazovky

**Files:** modify `lib/domain/models.dart`, `lib/data/providers.dart`,
`lib/features/profile/widgets/my_teams_card.dart`,
`lib/features/profile/widgets/team_picker_sheet.dart`,
`lib/features/profile/widgets/calendar_teams_sheet.dart`,
`lib/features/schedule/my_trainings_screen.dart`; testy tamtéž.

- `CalendarTeam` ztrácí `colorId` (zůstává `team` + `calendar`).
- `myTeamColorsProvider` — stream `team_colors` vlastního hráče jako
  `Map<String, int>`; `Api.setTeamColors(Map<String, int?>)` přes akci `team_colors`.
- **Moje týmy**: sheet dostane u zaškrtnutého týmu terčík barvy (`EventColorPicker`,
  stejný jako u kalendáře). Ukládá se při zavření okna, jedním voláním — jako
  týmy samotné.
- **Zápasy v kalendáři**: terčík zůstane a edituje tutéž sdílenou barvu; pod
  ním věta, že barva platí i v přehledu.
- **Můj přehled**: pohár u zápasu se obarví barvou týmu (`googleEventColors`),
  bez barvy zůstane jako dnes. U derby (oba týmy sledované) vyhraje domácí.

---

## Task 4 — Changelog

Nový webový záznam: přejmenování na Můj přehled a barvy týmů na jednom místě.
