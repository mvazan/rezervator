# Rezervátor — optimistické zápisy vlastního nastavení

*Stav k 2026-09-22, verze 1.2.7+11, migrace 0001–0043.*

## Proč

Appka po Android hlásila, že přidaná připomínka „se neaktualizuje hned" —
ukázala se, až po chvíli, nebo vůbec ne dokud uživatel appku
nepřepnul na pozadí a zpět. Vyšetřování (živý test proti Supabase
realtime kanálu) ukázalo dvě věci:

- Za normálních okolností doručí realtime změnu do ~0,5 s. Slabá wifi to
  jen natáhne.
- Appka ale nemá žádnou pojistku pro socket, který vypadá živě, ale
  přestane doručovat (žádná chyba, žádné uzavření) — jediné, co ho probudí,
  je návrat appky z pozadí (`LiveRefresh`, `auth_gate.dart`). Dokud
  uživatel sedí v appce, nic ho neprobudí.

Časovač, který by streamy pravidelně nutil znovu se přihlásit, by první
problém (slabá síť) neřešil vůbec a druhý (zaseknutý socket) jen změnil
z „nikdy" na „do pár minut" — a navíc by pravidelně zatěžoval všech ~15
živých streamů appky bez ohledu na to, jestli je něco rozbité.

**Řešení místo toho:** vlastní změna (appka ví přesně, co právě uložila)
se v UI objeví okamžitě, nezávisle na tom, v jakém stavu je socket. Server
zápis potvrdí, nebo appka spadne zpátky na poslední známý stav a ukáže
chybu — přesně jako dnes.

## Rozhodnutí

**Jednou v datové vrstvě, ne na každé obrazovce zvlášť.** Kdyby si to
řešil každý sheet/karta po svém, kód by se kopíroval a karta pod otevřeným
sheetem (souhrn připomínek) by o optimistické změně nevěděla, dokud
sheet sám neuloží — blikala by stará hodnota.

**Optimismus jen pro nekritické, výhradně vlastní zápisy.** Kde server
rozhoduje o kolizi, limitu nebo maže něčí jiné rezervace, optimismus nedává
smysl — tam zůstává současné chování (počkat na odpověď, chybu ukázat
hned). Mimo rozsah: rezervace, výjimky dnů, bloky rozvrhu, nastavení
rozvrhu (lane_count/training_weekdays/…), role a oddíly hráčů, druhý
kalendář (`setSecondaryCalendar` — vytváří/maže celý Google kalendář),
veřejný přehled (slug běžně narazí na `slug_taken`), a `setNick` — ten
totiž slouží dvěma pánům (`profile_screen.dart` voláním pro sebe, admin
z Hráčů pro kohokoli jiného) a bez rozdělení funkce na dvě by optimistická
oprava nevěděla, jestli má patchnout `myProfileProvider`, nebo řádek v
`profilesProvider`. Nestojí to za komplikaci — zůstává beze změny.

**V rozsahu** (11 zápisů, všechny už dnes výhradně vlastní):
`setNotifyBefore`, `setOwnColor`, `setFollowedTeams`, `setDefaultView`
(`profiles`), `setKioskDark`, `setKioskFitDay` (`schedule_settings` —
tenantové, ne uživatelské, ale nekonfliktní admin přepínač),
`setCalendarReminders`, `setTrainingColor`, `setCalendarTeams`,
`setTeamColors` (Google kalendář, přes edge funkci `calendar-manage`),
`setMatchException` (RPC `set_match_exception`).

**Úspěch nesmaže optimistickou hodnotu hned.** Kdyby zmizela okamžitě,
`withOptimisticOverlay` by na okamžik znovu vydal poslední *staré*
skutečné řádky (ještě neaktualizované) a stará hodnota by bliklo zpátky,
než dorazí ozvěna. Proto se patch po úspěchu jen označí jako **potvrzený**
a zůstává aktivní; teprve PRVNÍ další skutečné doručení ho zahodí a
definitivně platí to, co poslal server (Google kalendář připomínky např.
setřídí a odstraní duplicity). Aby ozvěna nečekala na náhodu, potvrzení
zápisu navíc vyžádá **cílené obnovení** — přesně ten jeden dotčený stream
se hned znovu přihlásí (čerstvý REST fetch), stejně jako to dnes dělá
[LiveRefresh] po návratu appky z pozadí, jen mířené na jeden klíč místo
všech streamů najednou. Řeší to i zaseknutý socket, který popsání
motivace výše zmiňuje: zápis, který appka sama potvrdí, cílené obnovení
spustí bez ohledu na to, v jakém stavu byl.

**Neúspěch spadne zpátky na poslední známý stav.** Chyba jde dál přesně
jako dnes — `tryAction` ji odchytí a ukáže `friendlyDbError`. Žádná
obrazovka se kvůli tomu nemění.

## Mechanismus

Nový soubor `lib/data/optimistic.dart`, používaný z `lib/data/cache.dart`
(čtecí strana) a `lib/data/providers.dart` (zápisová strana, `class Api`).
`cachedRows`'s vlastní tělo (replay z cache, live stream, retry po chybě,
probuzení appky) se přejmenovalo na privátní `_cachedRowsCore` beze změny
uvnitř — veřejná `cachedRows` ho jen obaluje a `_untilWake`/`_sleepOrWake`
navíc poslouchají [refreshRequests] vedle [LiveRefresh].

**Stav** (`lib/data/optimistic.dart`):

```dart
/// Jeden probíhající (nebo právě potvrzený) zápis pro jeden klíč. [apply]
/// přemění, co by cachedRows jinak vydal, na to, co tenhle zápis očekává
/// — volá se znovu na KAŽDÉ skutečné doručení, dokud zápis neskončí, aby
/// nesouvisející změna (např. admin schválí jiného hráče a přepíše celý
/// profil) tu optimistickou nezahodila.
///
/// [confirmed] rozlišuje „ještě čekám na odpověď serveru" od „server
/// potvrdil, čekám na ozvěnu přes realtime, abych patch mohl zahodit" —
/// než ozvěna dorazí, patch musí zůstat.
class _Pending {
  _Pending(this.apply);
  final List<Map<String, dynamic>> Function(List<Map<String, dynamic>> rows)
      apply;
  bool confirmed = false;
}

final _pending = <String, _Pending>{};

/// „Pro tenhle klíč se něco změnilo" — withOptimisticOverlay na to reaguje
/// okamžitým přemapováním posledních známých řádků, BEZ nového připojení
/// k live streamu.
final _changed = StreamController<String>.broadcast();

/// „Tenhle klíč má právě potvrzený zápis — přihlas se znovu, ať přijde
/// ozvěna co nejdřív, i kdyby byl socket zaseknutý." Stejný efekt jako
/// LiveRefresh, ale mířený jen na jeden stream.
final _refresh = StreamController<String>.broadcast();
```

**Veřejné funkce:**

- `applyPending(uid, name, rows)` — `rows`, jak by je viděl volající, když
  se na klíč právě vztahuje probíhající nebo potvrzený zápis, jinak beze
  změny.
- `pendingChanges(uid, name)` / `refreshRequests(uid, name)` — `Stream<void>`
  filtrované na jeden klíč.
- `settlePending(uid, name)` — odstraní patch, jen pokud je `confirmed`
  (nepotvrzený patch nesouvisející doručení nesmí zahodit).
- `optimisticWrite(uid, name, apply, write)`:
  1. uloží `_Pending(apply)`, pošle `_changed`,
  2. `await write()`,
  3. **úspěch** a entry je stále ta samá (`identical`, viz níž): označí
     `confirmed = true`, pošle `_refresh`,
  4. **chyba** a entry je stále ta samá: smaže ji, pošle `_changed`,
     `rethrow`,
  5. pokud entry mezitím převzal novější zápis na stejný klíč (druhé rychlé
     přidání připomínky dřív, než první doběhne), krok 3/4 na `_pending`
     nesáhne — jen `rethrow` při chybě jde volajícímu dál i tak. Vidí se
     vždy patch z POSLEDNÍHO volání.
- `withOptimisticOverlay(uid, name, raw)` — obaluje `raw` (výstup
  `_cachedRowsCore`): každé doručení nejdřív zavolá `settlePending`, pak
  uloží poslední řádky a vydá je přes `applyPending`; navíc poslouchá
  `pendingChanges` a při každé události přemapuje POSLEDNÍ známé řádky
  znovu, bez zásahu do `raw`.
- `patchRow(keyColumn, keyValue, fields)` — patch jednoho řádku podle
  klíčového sloupce (tvar sdílený `profiles`, `google_calendar_links`,
  `schedule_settings`).
- `upsertOrDeleteRows({matchKey, upserts, deletes})` — částečný
  upsert-nebo-smazání podle klíče vypočteného z řádku (tvar sdílený
  `team_colors`, `match_exceptions`).

**`lib/data/cache.dart`:**

```dart
const cacheKeyProfile = 'profile';
const cacheKeyCalendarLink = 'calendar_link';
const cacheKeyCalendarTeams = 'calendar_teams';
const cacheKeyTeamColors = 'team_colors';
const cacheKeyMatchExceptions = 'match_exceptions';
const cacheKeySettings = 'settings';

Stream<List<Map<String, dynamic>>> cachedRows(
  String uid,
  String name,
  Stream<List<Map<String, dynamic>>> Function() live,
) =>
    withOptimisticOverlay(uid, name, _cachedRowsCore(uid, name, live));
```

`_untilWake` dostal `uid`/`name` a vedle `LiveRefresh.stream` poslouchá i
`refreshRequests(uid, name)` — stejné `onWake(); stop();`. `_sleepOrWake`
(čekání na backoff) dostal `uid`/`name` stejně a poslouchá `refreshRequests`
vedle `LiveRefresh.stream` — jinak by potvrzený zápis, který přijde
zrovna ve chvíli, kdy je stream v backoffu po výpadku, čekal až na
vypršení časovače (5–30 s).

## 11 zápisů — přesná transformace

Každý `Api.setXxx` volá `optimisticWrite(uid, key, apply, write)`, kde
`write` je přesně to, co dělal dřív.

| Funkce | Klíč | `apply` |
|---|---|---|
| `setNotifyBefore(minutes)` | `cacheKeyProfile` | `patchRow('id', uid, {'notify_before_minutes': minutes})` |
| `setOwnColor(color)` | `cacheKeyProfile` | `patchRow('id', uid, {'own_color': color})` |
| `setFollowedTeams(teams)` | `cacheKeyProfile` | `patchRow('id', uid, {'followed_teams': teams})` |
| `setDefaultView(view)` | `cacheKeyProfile` | `patchRow('id', uid, {'default_view': view.name})` |
| `setKioskDark(dark, {tenantId})` | `cacheKeySettings` | `patchRow('tenant_id', tenantId, {'kiosk_dark': dark})` |
| `setKioskFitDay(fit, {tenantId})` | `cacheKeySettings` | `patchRow('tenant_id', tenantId, {'kiosk_fit_day': fit})` |
| `setCalendarReminders(minutes, {calendar})` | `cacheKeyCalendarLink` | `patchRow('user_id', uid, {field: minutes})`, `field` = `'reminder_minutes_secondary'` pro `CalendarSlot.secondary`, jinak `'reminder_minutes'` |
| `setTrainingColor(colorId)` | `cacheKeyCalendarLink` | `patchRow('user_id', uid, {'training_color_id': colorId})` |
| `setCalendarTeams(teams)` | `cacheKeyCalendarTeams` | `(_) => [for t: {...t.toJson(), 'user_id': uid}]` — úplná náhrada, jako `set_calendar_teams_for` |
| `setTeamColors(colors)` | `cacheKeyTeamColors` | `upsertOrDeleteRows`, klíč `team`: `color_id == null` → delete, jinak upsert `{user_id, team, color_id}` — jako `set_team_colors_for` |
| `setMatchException(matchId, shown)` | `cacheKeyMatchExceptions` | `upsertOrDeleteRows`, klíč `match_id`: `shown == null` → delete, jinak upsert `{user_id, match_id, shown}` — jako `set_match_exception` |

`uid` je pro `profiles`/`calendar_link`/`calendar_teams`/`team_colors`/
`match_exceptions` vždy `currentUserId!` — výhradně vlastní zápisy, viz
výše.

**Výjimka: kioskové přepínače.** `setKioskDark`/`setKioskFitDay` nikdy
neodkazovaly na `currentUserId` — jen na `tenantId` (parametr). Existující
test appky (žádná auth session, `settingsProvider` overridnutý napřímo)
to potvrdil pádem `Bad state: No element`, když se `currentUserId!`
vynutilo bezpodmínečně. Obě funkce proto zápis nejdřív připraví jako
prostou funkci a `optimisticWrite` zavolají, jen když `currentUserId`
skutečně existuje — jinak zapíšou přímo jako dřív:

```dart
static Future<void> setKioskDark(bool kioskDark, {required String tenantId}) {
  Future<void> write() => _db.from('schedule_settings')
      .update({'kiosk_dark': kioskDark}).eq('tenant_id', tenantId);
  final uid = currentUserId;
  if (uid == null) return write();
  return optimisticWrite(uid, cacheKeySettings,
      patchRow('tenant_id', tenantId, {'kiosk_dark': kioskDark}), write);
}
```

Přihlášený admin `currentUserId` má vždy (obrazovka je za `AdminScaffold`
gatem) — fallback větev je čistě pro testovací/degenerovaný stav bez
session.

`setCalendarReminders`/`setTrainingColor`/`setCalendarTeams`/
`setTeamColors` chodí přes edge funkci `calendar-manage`, samotné
`_db.functions.invoke(...)` volání se nemění — jen se obalí.

**UI se nemění vůbec.** `reminders_sheet.dart`, `profile_screen.dart`,
`calendar_link_card.dart` volají `Api.setXxx` a `tryAction` přesně jako
dnes.

## Chybové stavy a hrany

- **Zápis selže:** `optimisticWrite`'s krok 4 smaže patch (pokud ho
  mezitím nepřevzal novější), `withOptimisticOverlay` se vrátí k
  poslednímu skutečnému stavu, chyba jde dál, `tryAction` ukáže
  `friendlyDbError`.
- **Dva rychlé zápisy na stejný klíč** (přidání dvou připomínek za sebou,
  dřív než první doběhne): druhé volání čte `minutesOf(ref)`, který už
  ukazuje optimistickou hodnotu PRVNÍHO — jeho `apply` proto popisuje
  kompletní cílový stav, ne jen „přidej jednu". Dokončení staršího zápisu
  (úspěch i chyba) na `_pending` sáhne jen tehdy, když je pořád jeho.
- **Potvrzený zápis přijde zrovna, když je stream v backoffu** (po
  výpadku spojení): `_sleepOrWake` poslouchá `refreshRequests` vedle
  `LiveRefresh`, takže se hned přihlásí znovu — nečeká na 5–30s časovač.
- **Provider se mezitím zruší** (`ref.invalidate`, autoDispose): nová
  instance `cachedRows`/`withOptimisticOverlay` čte `_pending` znovu podle
  klíče — pokud zápis pořád běží, nová instance ho uvidí taky.
- **Testy sdílející stejné (uid, name):** `_pending`/`_changed`/`_refresh`
  jsou modulové globály (stejně jako `RowCache`'s SharedPreferences klíče)
  — testy proto používají různé `name` řetězce na test, stejná konvence,
  jakou dodržuje `test/data/cache_test.dart`.

## Testy

**`test/data/optimistic_test.dart`** (11 testů, čisté jednotky):
patch je vidět okamžitě; přežije nesouvisející doručení během zápisu; po
úspěchu drží, dokud nepřijde další doručení (pak zmizí a `refreshRequests`
vyšle); po chybě zmizí a `rethrow`; dva zápisy na stejný klíč — dokončení
staršího nezhodí patch novějšího; signály nevyšlou nic pro jiný klíč;
`patchRow`/`upsertOrDeleteRows` (nahrazení bez duplikátu, přidání,
smazání, nedotčené řádky). Dvě klíčová místa falzifikována
(`settlePending` bez podmínky na `confirmed`; `optimisticWrite`'s chybová
větev bez `identical` kontroly) — oba pády potvrzeny a vráceny zpět.

**`test/data/cache_test.dart`** (5 nových testů, integrace s
`cachedRows`): okamžitá viditelnost bez doručení z `live()`; potvrzený
zápis cíleně znovu přihlásí PRÁVĚ tenhle stream (jiný klíč netknutý);
neúspěch vrátí poslední skutečný stav; potvrzený zápis uprostřed backoffu
probudí okamžitě, ne až za 5 s (falzifikováno — bez `refreshRequests` v
`_sleepOrWake` test padá). Existujících 8 testů beze změny, celý soubor
zelený.

**Žádný widget test se měnit nemusel.** `ProfileScreen`, `CalendarLinkCard`
i `KioskSettingsScreen` berou `setXxx` jako injektovaný parametr s
výchozí hodnotou `Api.setXxx` (nebo, u kiosku, volají `Api.setKioskDark`
napřímo proti mockovanému HTTP klientovi bez auth session — to je přesně
test, který objevil výjimku výše) — `flutter test` po celé změně zůstal
zelený beze změny v `test/features/`.

## Changelog

`lib/features/profile/changelog_data.dart`, nejnovější web-only dávka:
„Změny v profilu a u kalendáře (připomínky, barvy, týmy, výchozí pohled)
se ukážou hned po uložení — i na pomalé síti."

## Mimo rozsah

- Časovač ticha / periodické obnovení `cachedRows` bez ohledu na
  optimismus — případné budoucí řešení pro zápisy OD JINÝCH lidí (cizí
  rezervace, zápas přidaný administrátorem…), na které tahle změna
  nedosáhne. Zatím bez důkazu, že je potřeba.
- `setNick` (dvojí použití — self i admin za jiného).
- Cokoliv, kde server rozhoduje o kolizi/limitu/mazání cizích dat
  (rezervace, výjimky dnů, bloky, nastavení rozvrhu, role, oddíly, druhý
  kalendář, veřejný přehled).
