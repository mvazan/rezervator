# Rezervátor — skupiny hráčů (rezervace navzájem)

*Stav k 2026-09-22, verze 1.2.7+11, migrace 0001–0043.*

## Proč

Rodina nebo dvojice, která chodí trénovat spolu, dnes nemá jak rezervovat
jeden za druhého. Hráč rezervuje a ruší jen sám za sebe; za jiného umí
jen správce (bez limitů) a kiosk. Chceme **skupinu**: každý její člen smí
rezervovat a rušit tréninky za kteréhokoli jiného člena.

## Rozhodnutí

- **Všichni navzájem.** Žádný vedoucí — každý člen smí za každého.
- **Self-service se souhlasem.** Skupinu zakládají hráči sami v Můj
  profil, bez správce. Pozvaný musí pozvánku přijmout: skupina dává
  ostatním právo rušit jeho rezervace, takže souhlasí ten, o jehož
  rezervace jde, ne správce. Odejít jde kdykoli.
- **Správce jen dohlíží.** V Správa → Hráči vidí u hráče jeho skupinu a
  může ho z ní odebrat. Jinak do skupin nezasahuje.
- **Jedna skupina na hráče.** Pozvánek může mít víc, přijmout jen jednu.
- **Stejná pravidla jako pro sebe.** Horizont, žádná minulost, limit
  aktivních rezervací se počítá tomu, **pro koho** rezervace je. Rušit jde
  jen před začátkem tréninku. Správcovy výjimky z limitů se na skupinu
  nevztahují.
- **Skupina nemá název** — je to seznam členů.

## Datový model — migrace `0044_player_groups.sql`

```sql
create table player_groups (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  created_by uuid not null references profiles(id),
  created_at timestamptz not null default now()
);

create table player_group_members (
  group_id uuid not null references player_groups(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  status text not null check (status in ('invited', 'member')),
  invited_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
-- Jedna skupina na hráče: přijatý člen smí být jen v jedné.
create unique index player_group_one_membership
  on player_group_members (user_id) where status = 'member';
```

**Viditelnost (RLS, select only):** hráč vidí řádky `player_group_members`
skupiny, ve které je členem (`status = 'member'`), a vlastní pozvánky
(`user_id = auth.uid()`). `player_groups` stejně: skupina, kde je členem,
nebo kam má pozvánku. Správce vidí všechny skupiny své kuželny. Žádné
DML pro `authenticated` — všechno přes RPC. `anon` nic. Obě tabulky do
`supabase_realtime`.

**Pomocník:** `same_group(a uuid, b uuid) returns boolean` — oba jsou
`member` téže skupiny. Interní (`revoke … from public, anon,
authenticated`).

## RPC

Všechny `security definer`, volatelné z `authenticated`, `anon` odebrán.

| Funkce | Kdo | Co dělá / chyby |
|---|---|---|
| `group_invite(p_user)` | schválený hráč (ne kiosk) | Když volající ve skupině není, založí ji a sebe vloží jako `member`. Pak vloží pozvánku `invited` pro `p_user`. `not_allowed` (volající neschválený/kiosk), `unknown_player` (cizí kuželna, neschválený, kiosk, hráč bez účtu), `already_member` (už je v této skupině), `already_invited`. |
| `group_accept(p_group)` | pozvaný | `invited` → `member`. `unknown_invite`, `already_in_group` (je členem jiné — nejdřív odejít). |
| `group_decline(p_group)` | pozvaný | Smaže pozvánku. `unknown_invite`. |
| `group_leave()` | člen | Smaže vlastní členství. Když ve skupině nezůstane žádný `member`, skupina zanikne i s pozvánkami. |
| `group_cancel_invite(p_group, p_user)` | člen téže skupiny | Stáhne čekající pozvánku. |
| `group_remove_member(p_user)` | správce vlastní kuželny | Odebere hráče ze skupiny (stejný úklid jako `group_leave`). `not_allowed`. |

**`create_reservation`** (create or replace, tělo 0005+): nová větev před
`else raise 'not_allowed'` —

```sql
elsif v_caller.status = 'approved' and v_caller.role = 'player'
      and same_group(v_uid, p_player_id) then
  v_via := 'group';
```

Následné kontroly (minulost, horizont, limit počítaný pro `p_player_id`)
už platí pro každého kromě správce, beze změny. Jediný rozdíl: pro
`v_via = 'group'` se místo `limit_reached` hlásí `member_limit_reached`
(„Člen skupiny už má maximální počet rezervací." — `limit_reached` říká
„Máš…", což by tu byla nepravda).

**`cancel_reservation`**: nová větev vedle „vlastní rezervace" —
`same_group(v_uid, v_res.player_id)` se stejnou kontrolou `too_late` a
`v_via := 'group'`.

**Check constrainty:** `reservations_created_via_check` a
`reservations_cancelled_via_check` += `'group'`.

## Notifikace (`supabase/functions/notify/index.ts`)

Stejnou cestou jako dnes kiosk (push s appkou, jinak e-mail):

- `player_group_members` INSERT `invited` → pozvanému: „Petr tě zve do
  skupiny — přijmi ji v Můj profil." (`kind: group_invite`).
- `player_group_members` UPDATE `invited → member` → ostatním členům:
  „Jana je teď ve skupině." (`kind: group_joined`).
- `reservations` INSERT `created_via = 'group'` → hráči, pro kterého je:
  „Petr ti zarezervoval trénink: čt 24. 9. · 17:30 · dráha 2." Bez odkazu
  na zrušení jedním klikem (ten má kiosk kvůli podvrhu; skupina je
  domluvená, rušit jde v appce).
- `reservations` UPDATE na zrušení s `cancelled_via = 'group'` →
  hráči: „Petr ti zrušil trénink: …"

Jméno „Petr" = `display_name` z `created_by` (INSERT) resp. volajícího;
pro zrušení se volající ukládá do nového sloupce
`reservations.cancelled_by uuid` (nastavuje `cancel_reservation`).

Webhook na nové tabulce `player_group_members`: stejný
`notify_webhook` trigger jako na `reservations`/`profiles`.

## Appka

### Data

- `myGroupProvider` (`cachedRows`, klíč `cacheKeyGroup`) → stream
  `player_group_members` (RLS dá jen moje řádky) → model `MyGroup`
  (`groupId?`, `members: List<String>` ids, `invited: List<String>`
  ids, `myInvites: List<(groupId, invitedBy)>`).
- `Api.groupInvite/Accept/Decline/Leave/CancelInvite/RemoveMember`.
- `friendlyDbError` += `already_member`, `already_invited`,
  `unknown_invite`, `already_in_group` („Už jsi v jiné skupině — nejdřív
  z ní odejdi."), `member_limit_reached`.

### Můj profil — karta „Moje skupina"

Vždy viditelná (to je, jak se o funkci hráči dozví):

- **Bez skupiny:** věta „Rezervujte a rušte tréninky za sebe navzájem —
  třeba rodina nebo dvojice." + tlačítko **Pozvat do skupiny…** (výběr
  ze schválených hráčů kuželny, hledání jako v dialogu správce, bez
  kiosků a hráčů bez účtu, bez těch, kdo už jsou v mé skupině).
- **Čekající pozvánka pro mě:** „Petr tě zve do skupiny" +
  **Přijmout / Odmítnout** (nad ostatním obsahem karty).
- **Ve skupině:** členové (jména), čekající pozvánky s ✕ (stáhnout),
  **Pozvat…**, **Opustit skupinu** (s potvrzením).

### Rozvrh

- **Rezervace:** hráč ve skupině (≥ 1 další člen) dostane v dialogu
  „Rezervovat termín?" volbu **Pro koho** — „Já" (výchozí) a členové.
  Bez skupiny beze změny.
- **Cizí rezervace člena:** ťuk otevře potvrzení zrušení („Zrušit
  rezervaci — Jana?"), dokud trénink nezačal; dnes by ukázal jen jméno.
  Ostatní rezervace beze změny.
- `WeekView`/`ScheduleActions` dostanou množinu `groupMateIds`;
  `SlotTile` ji použije při rozhodnutí „dá se zrušit".

### Správa → Hráči

U hráče ve skupině podtitul „Skupina: Jana, Petr" a v menu **Odebrat ze
skupiny**.

## Changelog

„Skupiny: rodina nebo dvojice si může rezervovat a rušit tréninky
navzájem — založíš ji v Můj profil."

## Testy

**SQL (`supabase/tests/tenancy_rls.sql`):** pozvánka → přijetí →
`same_group`; člen rezervuje za člena (`created_via = 'group'`), limit se
počítá cíli a hlásí `member_limit_reached`; člen ruší rezervaci člena
před začátkem, po začátku `too_late`; nečlen/pozvaný-nepřijatý
`not_allowed`; druhé přijetí `already_in_group`; odchod posledního
skupinu smaže; správce odebere člena, cizí správce ne; cizí kuželna
`unknown_player`; hráč bez účtu a kiosk nepozvatelní; RLS — hráč nevidí
cizí skupiny, vidí vlastní pozvánku; privilegia (žádné DML, `anon` nic,
`same_group` interní); tabulky v `supabase_realtime`. Každý blok
falzifikovat.

**Dart:** karta Moje skupina (tři stavy, akce volají správná RPC, chyby
česky); dialog rezervace s volbou Pro koho (jen se skupinou, výchozí
„Já", zvolený člen jde do `createReservation`); ťuk na rezervaci člena
nabídne zrušení; Správa → Hráči odebrání.

**Notify (deno test):** texty a příjemci čtyř událostí.

## Mimo rozsah

- Hráči bez účtu ve skupině (nemá kdo přijmout pozvánku).
- Víc skupin na hráče, název skupiny.
- Kiosk (dál rezervuje za kohokoli, beze změny).
- Posouvání rezervací (`move_reservation`) — jen správce, beze změny.
