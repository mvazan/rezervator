# Rezervátor

Rezervační systém tréninků na kuželně: hráči si přes appku nebo web
rezervují dráhu na volný časový blok, správce vidí kdo přijde, kdo
nepřišel, a měsíční docházku si stáhne jako CSV.

## Dva režimy

- **App/web** — každý hráč se přihlásí vlastním účtem (magic-link
  e-mail), vidí týdenní rozvrh, rezervuje si a ruší svoje tréninky a
  dostává e-mail (volitelně i push) o schválení, zrušení nebo potvrzení
  rezervace.
- **Kiosek** — sdílený dotykový tablet zavěšený přímo na kuželně: kdokoliv
  schválený si najde svoje jméno a rezervuje bez přihlašování vlastním
  účtem. Kiosek nikdy nic neruší a nikomu jinému nic neukazuje — jen
  vlastní rozvrh a tlačítko „Rezervovat".

## Stack

[Flutter](https://flutter.dev) (Android, iOS, web) + [Supabase](https://supabase.com)
(Postgres, Auth, Realtime, Edge Functions) na straně backendu. E-maily přes
[Resend](https://resend.com), volitelný push přes Firebase Cloud Messaging.

## Setup a dokumentace

- [`SETUP.md`](SETUP.md) — jednorázové nastavení vlastního backendu
  (~15 minut klikání v Supabase) a nasazení webu na GitHub Pages.
- [`docs/SCHEMA.md`](docs/SCHEMA.md) — efektivní schéma databáze: tabulky,
  RLS, RPC, kaskády, edge funkce (aktualizuje se s každou migrací).
- [`CICD.md`](CICD.md) — CI, nasazení backendu a webu, migrace;
  [`PLAY.md`](PLAY.md) — vydání na Google Play.
- [`docs/superpowers/specs/2026-07-07-rezervator-design.md`](docs/superpowers/specs/2026-07-07-rezervator-design.md) —
  návrh appky (funkce, datový model, fáze vývoje).
## Zápasy ze svazu

Zápasy a výsledky týmů kuželny se stahují z
[vysledky.kuzelky.cz](https://vysledky.kuzelky.cz) (edge funkce `notify`,
joby `federation_*`, noční cron `federation-nightly`, migrace `0045`
a `0047`). Nastavení je ve Správa → Oddíly: poprvé průvodce ve třech
krocích (kuželna, oddíly a týmy — chybějící oddíly založí —, zapnutí
stahování), potom „Přenačíst týmy z webu", ruční „Synchronizovat teď",
řádek s průběhem synchronizace a výsledek posledního načtení týmů (nové
týmy a oddíly, nebo „žádná změna"). Ruční úprava zápasu v appce se při
synchronizaci nepřepíše (`hand_edited`); zápas bez `import_key` je čistě
správcův — svaz o něm neví a nikdy ho nezmění. Zápasy dorostu, které svaz
na webu zatím nevede, zůstávají jako dřív — správce je zadává a upravuje
ručně.
