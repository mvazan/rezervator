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
- [`docs/superpowers/specs/2026-07-07-rezervator-design.md`](docs/superpowers/specs/2026-07-07-rezervator-design.md) —
  návrh appky (funkce, datový model, fáze vývoje).
