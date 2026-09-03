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
- `tool/import_matches.py` — jednorázový import zápasů z krajského sešitu
  „Obsazenost kuželen“ (xlsx): domácí zápasy z řádku naší kuželny, venkovní
  zápasy našich týmů z ostatních řádků; jména klubů bere ze skrytého listu
  „Utkání – vše“ (kalendář je pro místo zkracuje: „SVeverky“ místo „SKK
  Veverky“ apod.). Vypíše přehled a vygeneruje SQL, které běží jako správce
  kuželny (zrušené rezervace jako v appce, úklid před zápasem 30 min);
  opakované spuštění nic neduplikuje.

  ```bash
  python3 tool/import_matches.py ~/Downloads/Obsazenost-kuzelen-2026-27.xlsx
  python3 tool/import_matches.py ~/Downloads/Obsazenost-kuzelen-2026-27.xlsx --apply
  ```

  První příkaz jen vypíše, co by se naimportovalo, a uloží SQL do
  `build/import_matches.sql`. Druhý zapisuje do **produkce**: nejdřív ukáže,
  do které kuželny a pod kterým správcem se zapíše, kolik zápasů už tam je a
  kolik živých rezervací může zrušit, a čeká na napsané „ano“ (`--yes` to
  přeskočí, `--local` míří na lokální stack). Kuželnu vybereš `--tenant`
  jménem nebo `--tenant-id` uuid. Délka zápasu je pevná podle soutěže
  (KP2 90 min, KP1 150 min, jinak — divize a ligy — `--duration`, výchozí
  180 min); `--length "KP1 Sever=210"` přebije jednu soutěž ručně. Oprava
  už naimportovaného kola (jiná délka, jiná data) jde přes `--replace`: ve
  stejné transakci smaže všechny dřív naimportované zápasy té kuželny
  (`import_key like 'xlsx:%'`) a zapíše je znovu.
