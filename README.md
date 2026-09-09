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
- `tool/import_matches.py` — import zápasů ze svazového rozpisu (plochý
  seznam, jeden řádek = jeden zápas: Kuželna, Datum, Čas, Soutěž, Kolo,
  Domácí, Hosté; `.xls` i `.xlsx`, bez závislostí). Domácí zápasy jsou řádky
  s naší kuželnou, venkovní zápasy našich týmů ostatní řádky. Rozpis se
  během sezóny mění, proto nástroj **porovnává a mění jen rozdíly**: zápas
  má klíč `rozpis:<soutěž>:<kolo>:<domácí> – <hosté>` bez data, takže
  přeložený zápas je úprava téhož řádku (a hráčům se přepíše tatáž událost
  v Google kalendáři), nový se vloží, zrušený se smaže. Čeho se nikdy
  nedotkne: zápasu zadaného ručně v appce (bez klíče), zápasu z rozpisu,
  který správce v appce upravil (`hand_edited`, v Zápasech „upraveno ručně“
  — přepíše ho jen `--force`), a toho, kdo které týmy sleduje; sledovaný
  tým, který v rozpise chybí, zápis zastaví (`--allow-missing-teams`).

  ```bash
  python3 tool/import_matches.py ~/Downloads/rozpis.xls            # náhled
  python3 tool/import_matches.py ~/Downloads/rozpis.xls --apply    # zápis do produkce
  ```

  První příkaz vypíše, co v souboru našel, uloží SQL do
  `build/import_matches.sql` a ukáže **náhled** — jeden dotaz do databáze
  (produkce, s `--local` lokální stack), který vypíše každý plánovaný krok:
  `rekey` / `rename` (staré klíče z mřížkového sešitu 2026/27 a
  přejmenovaní soupeři), `update` (s tím, co se mění), `insert`, `delete`,
  `skip` (ručně upravené) a sledované týmy, které v rozpise nejsou. Druhý
  ukáže totéž a po napsaném „ano“ (`--yes` to přeskočí) zapíše jako jednu
  transakci správce kuželny (RLS, zrušené rezervace a upozornění jako v
  appce) — transakce si tentýž plán spočítá znovu a provede ho. Kuželnu
  vybereš `--tenant` jménem nebo `--tenant-id` uuid. Délka zápasu je pevná
  podle soutěže (KP2 90 min, KP1 150 min, dorost 90 min, jinak — divize a
  ligy — `--duration`, výchozí 180 min); `--length "KP1 Sever=210"` přebije
  jednu soutěž ručně.
