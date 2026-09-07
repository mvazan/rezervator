# Druhý kalendář a barvy zápasů — návrh

**Cíl:** hráč může mít v Googlu dva kalendáře Rezervátoru a u každého sledovaného
týmu si řekne, do kterého jeho zápasy patří a jakou mají mít barvu. Kdo druhý
kalendář nechce, má všechno v jednom — jen si i tam může vybrat barvu.

## Co Google dovolí (změřeno, ne odhad)

Aplikace jezdí na scope `calendar.app.created`. Kód si k tomu už drží ověření
proti produkčnímu API (`_shared/google_calendar.ts:190-196`, 2026-08-10): celá
větev `calendarList` vrací **401** i pro kalendář, který appka sama založila —
takže **barvu ani výchozí připomínky kalendáře nastavit nejde**. Událost je
jediné místo, kudy obojí projde. Proto:

- **barva je na události** (`colorId`), ne na kalendáři;
- **připomínky jsou na události** (`reminders.overrides`) — tak to appka dělá
  už dnes, jen je zatím jeden seznam pro všechno.

Barva události není libovolné RGB: Google dovolí **jedenáct svých barev**
(`colorId` 1–11). Kolečko z Můj profil se sem tedy nehodí a výběr barvy pro tým
ukáže právě těchto jedenáct:

| id | Google | česky v appce | hex |
|---|---|---|---|
| 1 | Lavender | Levandulová | #7986CB |
| 2 | Sage | Šalvějová | #33B679 |
| 3 | Grape | Švestková | #8E24AA |
| 4 | Flamingo | Lososová | #E67C73 |
| 5 | Banana | Banánová | #F6BF26 |
| 6 | Tangerine | Mandarinková | #F4511E |
| 7 | Peacock | Paví | #039BE5 |
| 8 | Graphite | Grafitová | #616161 |
| 9 | Blueberry | Borůvková | #3F51B5 |
| 10 | Basil | Bazalková | #0B8043 |
| 11 | Tomato | Rajčatová | #D50000 |

Dvanáctá možnost je „bez barvy" — událost pak vezme barvu kalendáře, jak je to
dnes.

## Jak to vypadá

**Můj profil → propojení s kalendářem** dostane přepínač **Druhý kalendář**.
Vypnutý (výchozí) je všechno jako dnes. Zapnutý založí v Googlu druhý kalendář
„Rezervátor 2" a odemkne dvě věci: vlastní připomínky pro druhý kalendář a u
každého týmu volbu, kam patří.

**Zápasy v kalendáři** přestane být seznam zaškrtávátek a stane se z něj seznam
řádků. Nezaškrtnutý tým je jeden řádek s prázdným čtverečkem. Zaškrtnutý ukáže
navíc:

- **barvu** — kolečko, které otevře oněch jedenáct Google barev plus „bez barvy";
- **kalendář** — dvojice `Hlavní | Druhý`, ale jen když je druhý kalendář zapnutý.

Příklad ze zadání: Veverky B zaškrtnuté, hlavní kalendář; Veverky A a C
zaškrtnuté, druhý kalendář, který má prázdné připomínky.

**Tréninky** jdou vždy do hlavního kalendáře. Mají svou vlastní barvu, kterou si
hráč nastaví v kartě kalendáře — a to i když druhý kalendář nepoužívá.

## Data

Pole `google_calendar_links.match_teams` na tohle nestačí, tým už není jen
jméno. Nahradí ho tabulka:

```sql
create table calendar_teams (
  user_id  uuid    references profiles(id) on delete cascade,
  team     text    not null,
  calendar text    not null default 'primary'
             check (calendar in ('primary', 'secondary')),
  color_id smallint check (color_id between 1 and 11),  -- null = bez barvy
  primary key (user_id, team)
);
```

Migrace přesype dnešní `match_teams` do řádků (`calendar = 'primary'`,
`color_id = null`), takže se nikomu nic nezmění.

`google_calendar_links` přibude:

- `secondary_enabled boolean not null default false`
- `reminder_minutes_secondary integer[] not null default '{}'` — stejné meze
  jako u hlavního
- `training_color_id smallint` — barva tréninků, `null` = bez barvy

`google_calendar_tokens` přibude `google_calendar_id_secondary text` — druhý
kalendář v Googlu, `null` dokud ho hráč nezapne.

## Jak se to zapíše do Googlu

`my_future_matches` bude vracet u každého zápasu navíc `calendar` a `color_id`;
`match_calendar_followers` zůstane, jen se čte z nové tabulky. Job v `notify`
pak zápas zapíše do toho kalendáře, který u týmu stojí — a **smaže ho z toho
druhého**. Id události je odvozené z (hráč, zápas), takže je v obou kalendářích
stejné a přesun týmu jinam se udělá sám: zapiš do cílového, smaž z druhého.

Vypnutí druhého kalendáře vrátí jeho týmy na hlavní a kalendář v Googlu smaže
i s událostmi — stejně, jako to dnes dělá odpojení.

## Co se bude testovat

- SQL: tabulka je jen pro svého hráče, `calendar`/`color_id` drží meze, migrace
  převede pole na řádky, `my_future_matches` vrací kalendář i barvu.
- Deno: `colorId` v těle události, zápis do správného kalendáře a smazání z
  druhého.
- Flutter: řádek týmu (zaškrtnutí, barva, kalendář), přepínač druhého kalendáře,
  dvoje připomínky, a že bez druhého kalendáře se volba kalendáře vůbec neukáže.
