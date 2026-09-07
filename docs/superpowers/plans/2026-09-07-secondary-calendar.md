# Druhý kalendář a barvy zápasů — plán

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Cíl:** dva kalendáře Rezervátoru v Googlu, u každého sledovaného týmu volba
kalendáře a barvy události; tréninky vždy do hlavního, s vlastní barvou.

**Návrh:** `docs/superpowers/specs/2026-09-07-secondary-calendar-design.md`

## Global Constraints

- Barva události = Google `colorId` 1–11 nebo `null` („bez barvy"). Vlastní RGB
  API nedovolí a `calendarList` je pod scope `calendar.app.created` 401, takže
  barva ani připomínky nikdy nejdou na kalendář, jen na událost.
- Tréninky jdou vždy do hlavního kalendáře.
- Czech UI copy, English code and comments; seznamy `compareCzech` nebo chronologicky.
- `flutter analyze` čistý, `flutter test` zelený (492 dnes). `deno check` +
  `deno test supabase/functions` zelené. Lokální `supabase db reset` (nikdy
  `--linked`) + `psql … -f supabase/tests/tenancy_rls.sql` končí `ROLLBACK`.
- Migrace append-only, další volné číslo **0032**; po ní `tool/schema_snapshot.sh`
  a `docs/SCHEMA.md`.
- Commit per task s `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Jedna větev `secondary-calendar`, jedno PR (uživatel merguje).

---

## Task 1 — Migrace 0032: tabulka týmů, druhý kalendář, barvy

**Files:** create `supabase/migrations/0032_secondary_calendar.sql`; modify
`supabase/tests/tenancy_rls.sql`, `docs/SCHEMA.md`; regenerate `supabase/schema.sql`.

Tabulka (RLS: hráč čte a píše jen své řádky; server přes service_role):

```sql
create table calendar_teams (
  user_id  uuid not null references profiles(id) on delete cascade,
  team     text not null,
  calendar text not null default 'primary'
    check (calendar in ('primary', 'secondary')),
  color_id smallint check (color_id between 1 and 11),
  primary key (user_id, team)
);
```

Sloupce navíc:

```sql
alter table google_calendar_links
  add column secondary_enabled boolean not null default false,
  add column reminder_minutes_secondary integer[] not null default '{}'
    check (coalesce(array_length(reminder_minutes_secondary, 1), 0) <= 5
           and 0 <= all (reminder_minutes_secondary)
           and 40320 >= all (reminder_minutes_secondary)),
  add column training_color_id smallint check (training_color_id between 1 and 11);

alter table google_calendar_tokens add column google_calendar_id_secondary text;
```

Přesyp dnešních polí do řádků (nikomu se nic nemění), pak `match_teams` zůstane
jako mrtvý sloupec **do doby, než přestane být čtený** — dropne ho až Task 3,
aby migrace a kód nemusely přistát ve stejnou vteřinu:

```sql
insert into calendar_teams (user_id, team)
select user_id, unnest(match_teams) from google_calendar_links
on conflict do nothing;
```

Funkce (stejná těla, jen čtou z nové tabulky):

- `match_calendar_followers(p_tenant, p_home, p_away)` — join `calendar_teams t
  on t.user_id = l.user_id and t.team in (p_home, p_away)` místo `l.match_teams &&`.
- `my_future_matches(p_user)` — vrací navíc `calendar text` a `color_id smallint`
  z `calendar_teams`; při shodě obou týmů (derby) vyhraje řádek s `team = home_team`.
- `set_calendar_teams_for(p_user uuid, p_teams jsonb) returns jsonb` — nahradí
  `set_calendar_match_teams_for`: ověří ≤ 20 položek, `calendar` v mezích,
  `color_id` v 1–11 nebo null, vrátí **předchozí** stav jako jsonb pole
  `[{team, calendar, color_id}]`, pak řádky přepíše (delete + insert v jedné
  transakci). Stará funkce se dropne až v Tasku 3.
- `set_calendar_reminders_for(p_user, p_minutes, p_calendar text default 'primary')`
  — píše do `reminder_minutes` nebo `reminder_minutes_secondary`.

**SQL testy** (v `tenancy_rls.sql` před závěrečné `reset role; rollback;`):
hráč vidí a mění jen své řádky; cizí řádek se nezmění; `calendar = 'třetí'` a
`color_id = 12` skončí `check_violation`; `set_calendar_teams_for` vrátí
předchozí stav a uloží nový; `my_future_matches` vrátí kalendář i barvu;
`match_calendar_followers` najde hráče přes novou tabulku. Notice:
`OK: calendar_teams routes matches per team, inside the checks`.

**Verify:** `supabase db reset`; suite končí `ROLLBACK`; `\d calendar_teams`.

---

## Task 2 — `_shared/google_calendar.ts`: barva a druhý kalendář

**Files:** modify `supabase/functions/_shared/google_calendar.ts`,
`supabase/functions/_shared/google_calendar_test.ts`.

- `EventBody` dostane `colorId?: string` — Google chce string „1".."11".
- `reservationEventBody(row, reminderMinutes, colorId?)` a
  `matchEventBody(row, reminderMinutes, colorId?)` ho nastaví, jen když není null.
- `MatchRow` dostane `calendar: "primary" | "secondary"` a `color_id: number | null`.
- `createSecondaryCalendar(accessToken, summary)` — parametr místo konstanty
  `CALENDAR_SUMMARY`, aby šlo založit „Rezervátor 2".
- `writeFutureMatches(db, userId, accessToken, calendars)` — `calendars` je
  `{primary: string; secondary: string | null}`; každý řádek jde do svého
  kalendáře a **smaže se z druhého** (přesun týmu je pak samospád).
- `writeFutureReservations` bere navíc `colorId`.

**Testy** (Deno, čisté funkce): `colorId` v těle jen když je zadané; tělo bez
barvy je bajt po bajtu jako dnes; `matchEventBody` s barvou.

---

## Task 3 — `notify` a `calendar-manage`

**Files:** modify `supabase/functions/notify/index.ts`,
`supabase/functions/calendar-manage/index.ts`; migrace
`supabase/migrations/0033_drop_match_teams.sql` (dropne `match_teams` a
`set_calendar_match_teams_for`, které už nikdo nečte).

- `calendarLink(userId)` vrací i `secondaryCalendarId` a obě sady připomínek.
- `jobCalendarSync` u zápasu: `my_future_matches` už nese `calendar` a `color_id`
  → zapiš do cílového kalendáře s barvou, smaž ze druhého. U rezervace: hlavní
  kalendář, `training_color_id`.
- `calendar-manage` akce:
  - `secondary` s `{enabled: bool}` — zapnutí založí kalendář „Rezervátor 2",
    uloží jeho id a přepíše budoucí zápasy; vypnutí smaže kalendář v Googlu,
    vrátí týmy na `primary` a přepíše je do hlavního.
  - `teams` s `[{team, calendar, color_id}]` — uloží přes
    `set_calendar_teams_for`, z vráceného předchozího stavu smaže události
    odebraných týmů a srovná zbytek.
  - `reminders` dostane `calendar` („primary" | „secondary").

**Verify:** `deno check` všech funkcí, `deno test supabase/functions`.

---

## Task 4 — Doména a data (Flutter)

**Files:** modify `lib/domain/models.dart`, `lib/data/providers.dart`; tests
`test/domain/calendar_link_test.dart`.

- `enum CalendarSlot { primary, secondary }` — jména = hodnoty v DB.
- `class CalendarTeam { final String team; final CalendarSlot calendar; final int? colorId; }`
  s `fromJson`/`toJson`.
- `CalendarLink` dostane `secondaryEnabled`, `reminderMinutesSecondary`,
  `trainingColorId`, a `teams` jako `List<CalendarTeam>` místo `matchTeams`.
- `googleEventColors` — 11 barev jako `(int id, String name, Color color)`,
  česká jména z návrhu; `null` = bez barvy.
- `Api.setCalendarTeams(List<CalendarTeam>)`, `Api.setSecondaryCalendar(bool)`,
  `Api.setCalendarReminders(List<int>, {CalendarSlot calendar})`,
  `Api.setTrainingColor(int?)`.
- `myCalendarTeamsProvider` — stream `calendar_teams` vlastního hráče.

---

## Task 5 — Karta kalendáře a seznam týmů (Flutter)

**Files:** modify `lib/features/profile/widgets/calendar_link_card.dart`; create
`lib/features/profile/widgets/calendar_teams_sheet.dart`,
`lib/features/profile/widgets/event_color_picker.dart`; tests
`test/features/profile_screen_test.dart`, `test/features/calendar_teams_sheet_test.dart`.

- `EventColorPicker` — jedenáct Google barev + „bez barvy", stejný tvar terčíku
  jako `ColorPickerGrid`, ale pevný seznam (RGB sem nepatří, viz návrh).
- `calendar_teams_sheet.dart` — řádek na tým: `Checkbox`, jméno, a když je
  zaškrtnutý, terčík barvy a (jen při zapnutém druhém kalendáři) `SegmentedButton`
  `Hlavní | Druhý`. Seznam řazený `compareCzech`, tým mimo rozvrh zůstane vidět,
  když ho hráč sleduje (jako dnes).
- Karta kalendáře: `SwitchListTile` „Druhý kalendář" s podtitulkem, řádek
  připomínek se při zapnutí zdvojí („Připomínky hlavního" / „Připomínky druhého"),
  a přibude řádek „Barva tréninků".
- Injektované Api volání jako u `setOwnColor` (mock HTTP klient neumí
  `functions.invoke`).

---

## Task 6 — Changelog

**Files:** modify `lib/features/profile/changelog_data.dart` — nový webový
záznam (`Release(null, '<d. m. 2026>', [...])`) o druhém kalendáři a barvách.
