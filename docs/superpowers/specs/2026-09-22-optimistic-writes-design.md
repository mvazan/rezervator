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

**V rozsahu** (8 zápisů, všechny už dnes výhradně vlastní):
`setNotifyBefore`, `setOwnColor`, `setFollowedTeams`, `setDefaultView`
(`profiles`), `setCalendarReminders`, `setTrainingColor`,
`setCalendarTeams`, `setTeamColors` (Google kalendář, přes edge funkci
`calendar-manage`), plus `setMatchException` (RPC `set_match_exception`)
a kioskové přepínače `setKioskDark`/`setKioskFitDay` (`schedule_settings`
— tenantové, ne uživatelské, ale nekonfliktní admin přepínač).

**Úspěch přemaže optimistickou hodnotu skutečnou.** Google kalendář
připomínky server třídí a odstraňuje duplicity — po uložení se zobrazí,
co server opravdu uložil, ne co appka poslala.

**Neúspěch spadne zpátky na poslední známý stav.** Chyba jde dál přesně
jako dnes — `tryAction` ji odchytí a ukáže `friendlyDbError`. Žádná
obrazovka se kvůli tomu nemění.

## Mechanismus

Nový soubor `lib/data/optimistic.dart`, používaný jen z `lib/data/cache.dart`
(čtecí strana) a `lib/data/providers.dart` (zápisová strana, `class Api`).
`cachedRows` samotné (replay z cache, live stream, retry po chybě, probuzení
appky) se nemění ani o řádek — dostává jen obálku navíc kolem svého výstupu.

```dart
// lib/data/optimistic.dart
/// Optimistická vrstva nad [cachedRows] (`lib/data/cache.dart`): appka ví,
/// co právě zapsala, a nemusí čekat, až se to vrátí přes realtime. Klíč je
/// stejný pár (uid, name) jako u cachedRows a RowCache — viz konstanty
/// cacheKey* níže, sdílené mezi čtecí stranou (cachedRows) a zápisovou
/// (Api.setXxx).
library;

import 'dart:async';

/// Jeden probíhající zápis pro jeden klíč. [apply] přemění, co by
/// [cachedRows] jinak vydal, na to, co tenhle zápis očekává — volá se
/// znovu na KAŽDÉ skutečné doručení, dokud zápis neskončí, aby nesouvisející
/// změna (např. admin schválí jiného hráče a přepíše celý profil) tu
/// optimistickou nezahodila.
class _Pending {
  _Pending(this.apply);
  final List<Map<String, dynamic>> Function(List<Map<String, dynamic>> rows)
      apply;
}

final _pending = <String, _Pending>{};

/// Globální signál „pro tenhle klíč se něco změnilo" — [withOptimisticOverlay]
/// na něj reaguje okamžitým přemapováním posledních známých řádků, BEZ
/// nového připojení k live streamu (na rozdíl od LiveRefresh, který stream
/// nutí se odpojit a znovu přihlásit).
final _changed = StreamController<String>.broadcast();

String _key(String uid, String name) => '$uid.$name';

/// [rows], jak by je viděl volající, když se na klíč (uid, name) právě
/// vztahuje probíhající optimistický zápis — jinak beze změny.
List<Map<String, dynamic>> applyPending(
        String uid, String name, List<Map<String, dynamic>> rows) =>
    _pending[_key(uid, name)]?.apply(rows) ?? rows;

/// Poslouchá se v [withOptimisticOverlay]: „přemapuj znovu, pro tenhle
/// klíč se něco stalo" (nový zápis začal, nebo předchozí skončil).
Stream<void> pendingChanges(String uid, String name) =>
    _changed.stream.where((k) => k == _key(uid, name));

/// Spustí [write] na pozadí; UI vidí efekt [apply] OKAMŽITĚ, ne až po
/// odpovědi serveru. Když [write] uspěje, patch zmizí a další skutečné
/// doručení (stream běžel dál po celou dobu) ukáže přesně to, co server
/// uložil. Když selže, patch zmizí stejně tak a chyba jde dál — volající
/// (`tryAction`) ji odchytí jako dnes.
///
/// Druhý zápis na STEJNÝ klíč dřív, než první doběhne (rychlé přidání dvou
/// připomínek za sebou), přebírá viditelnost: patch vidí appka vždycky ten
/// z posledního volání. Dokončení staršího volání proto smaže `_pending`
/// jen tehdy, když mezitím nepřevzalo novější — jinak by na okamžik
/// shodilo ještě neuloženou novější změnu. Chyba staršího volání jde
/// jeho volajícímu dál bez ohledu na to.
Future<void> optimisticWrite(
  String uid,
  String name,
  List<Map<String, dynamic>> Function(List<Map<String, dynamic>> rows) apply,
  Future<void> Function() write,
) async {
  final key = _key(uid, name);
  final entry = _Pending(apply);
  _pending[key] = entry;
  _changed.add(key);
  try {
    await write();
  } finally {
    if (identical(_pending[key], entry)) {
      _pending.remove(key);
      _changed.add(key);
    }
  }
}

/// Obaluje [raw] (výstup [cachedRows]'s core generátoru, beze změny) tak,
/// že každé doručení — replay z cache i každé živé — projde [applyPending].
/// Navíc reaguje na [pendingChanges]: nové/skončené optimistické psaní
/// přemapuje POSLEDNÍ známé řádky okamžitě, bez zásahu do `raw` (žádné
/// nové připojení, žádná síť).
Stream<List<Map<String, dynamic>>> withOptimisticOverlay(
  String uid,
  String name,
  Stream<List<Map<String, dynamic>>> raw,
) {
  final out = StreamController<List<Map<String, dynamic>>>();
  StreamSubscription<List<Map<String, dynamic>>>? rawSub;
  StreamSubscription<void>? changeSub;
  var last = <Map<String, dynamic>>[];
  var hasLast = false;

  void emit() {
    if (hasLast && !out.isClosed) out.add(applyPending(uid, name, last));
  }

  out.onListen = () {
    rawSub = raw.listen(
      (rows) {
        last = rows;
        hasLast = true;
        emit();
      },
      onError: (Object e, StackTrace st) {
        if (!out.isClosed) out.addError(e, st);
      },
      onDone: out.close,
    );
    changeSub = pendingChanges(uid, name).listen((_) => emit());
  };
  out.onCancel = () async {
    await changeSub?.cancel();
    await rawSub?.cancel();
  };
  return out.stream;
}

/// Patch jednoho řádku podle klíčového sloupce — tvar, který sdílí profil,
/// google_calendar_links a schedule_settings (jeden řádek na vlastníka,
/// nezávisle upravitelná pole).
List<Map<String, dynamic>> Function(List<Map<String, dynamic>> rows) patchRow(
  String keyColumn,
  Object keyValue,
  Map<String, dynamic> fields,
) =>
    (rows) => [
          for (final r in rows)
            if (r[keyColumn] == keyValue) {...r, ...fields} else r,
        ];

/// Částečný upsert-nebo-smazání podle klíče vypočteného z řádku — tvar,
/// který sdílí setTeamColors (klíč = team) a setMatchException (klíč =
/// match_id): [upserts] řádek pro daný klíč přidá/nahradí, [deletes] ho
/// smaže, všechno ostatní zůstává beze změny.
List<Map<String, dynamic>> Function(List<Map<String, dynamic>> rows)
    upsertOrDeleteRows({
  required String Function(Map<String, dynamic> row) matchKey,
  required Map<String, Map<String, dynamic>> upserts,
  required Set<String> deletes,
}) =>
        (rows) => [
              for (final r in rows)
                if (!deletes.contains(matchKey(r)) &&
                    !upserts.containsKey(matchKey(r)))
                  r,
              ...upserts.values,
            ];
```

`lib/data/cache.dart`: `cachedRows`'s tělo se přejmenuje na privátní
`_cachedRowsCore` (beze změny) a veřejná `cachedRows` ho jen obalí:

```dart
Stream<List<Map<String, dynamic>>> cachedRows(
  String uid,
  String name,
  Stream<List<Map<String, dynamic>>> Function() live,
) =>
    withOptimisticOverlay(uid, name, _cachedRowsCore(uid, name, live));
```

Sdílené klíče (stejný string na čtecí i zápisové straně — dřív existoval
jen na jedné, teď musí sedět na obou, proto konstanty místo řetězců
napsaných dvakrát) v `lib/data/cache.dart`:

```dart
const cacheKeyProfile = 'profile';
const cacheKeyCalendarLink = 'calendar_link';
const cacheKeyCalendarTeams = 'calendar_teams';
const cacheKeyTeamColors = 'team_colors';
const cacheKeyMatchExceptions = 'match_exceptions';
const cacheKeySettings = 'settings';
```

`lib/data/providers.dart` — existující `cachedRows(uid, 'profile', …)` a
podobná volání v `myProfileProvider`, `myCalendarLinkProvider`,
`myCalendarTeamsProvider`, `myTeamColorsProvider`,
`myMatchExceptionsProvider`, `settingsProvider` přejdou na tyto konstanty
(mechanická záměna řetězce za konstantu, žádná jiná změna).

## Osm zápisů — přesná transformace

Každý dnešní `Api.setXxx` dostane misto přímého `.update()`/`.invoke()`/
`.rpc()` volání obálku `optimisticWrite(uid, key, apply, write)`, kde
`write` je přesně to, co dělal dnes.

| Funkce | Klíč | `apply` |
|---|---|---|
| `setNotifyBefore(minutes)` | `cacheKeyProfile` | `patchRow('id', uid, {'notify_before_minutes': minutes})` |
| `setOwnColor(color)` | `cacheKeyProfile` | `patchRow('id', uid, {'own_color': color})` |
| `setFollowedTeams(teams)` | `cacheKeyProfile` | `patchRow('id', uid, {'followed_teams': teams})` |
| `setDefaultView(view)` | `cacheKeyProfile` | `patchRow('id', uid, {'default_view': view.name})` |
| `setKioskDark(dark, {tenantId})` | `cacheKeySettings` | `patchRow('tenant_id', tenantId, {'kiosk_dark': dark})` |
| `setKioskFitDay(fit, {tenantId})` | `cacheKeySettings` | `patchRow('tenant_id', tenantId, {'kiosk_fit_day': fit})` |
| `setCalendarReminders(minutes, {calendar})` | `cacheKeyCalendarLink` | `patchRow('user_id', uid, {field: minutes})`, kde `field` je `'reminder_minutes_secondary'` pro `CalendarSlot.secondary`, jinak `'reminder_minutes'` |
| `setTrainingColor(colorId)` | `cacheKeyCalendarLink` | `patchRow('user_id', uid, {'training_color_id': colorId})` |
| `setCalendarTeams(teams)` | `cacheKeyCalendarTeams` | `(_) => [for (t in teams) {...t.toJson(), 'user_id': uid}]` — úplná náhrada, server (`set_calendar_teams_for`) taky maže vše a vkládá znovu |
| `setTeamColors(colors)` | `cacheKeyTeamColors` | `upsertOrDeleteRows` — `upserts` pro `color_id != null` (`{'user_id': uid, 'team': t, 'color_id': c}`), `deletes` pro `color_id == null`, klíč `team` |
| `setMatchException(matchId, shown)` | `cacheKeyMatchExceptions` | `shown == null` → `upsertOrDeleteRows(deletes: {matchId})`; jinak `upsertOrDeleteRows(upserts: {matchId: {'user_id': uid, 'match_id': matchId, 'shown': shown}})`, klíč `match_id` |

`uid` je všude `currentUserId!` (výhradně vlastní zápisy, viz výše).
`setCalendarReminders`/`setTrainingColor`/`setCalendarTeams`/
`setTeamColors` chodí přes edge funkci `calendar-manage`, samotné
`_db.functions.invoke(...)` volání se nemění — jen se obalí.

**UI se nemění vůbec.** `reminders_sheet.dart`, `profile_screen.dart`,
`calendar_link_card.dart` volají `Api.setXxx` a `tryAction` přesně jako
dnes — chybová hláška, úspěšná hláška, žádný nový parametr. Optimismus je
neviditelný detail datové vrstvy.

## Chybové stavy a hrany

- **Zápis selže:** `optimisticWrite`'s `finally` smaže patch (pokud ho
  mezitím nepřevzal novější — viz níž), `withOptimisticOverlay` se vrátí
  k poslednímu skutečnému stavu, chyba jde dál, `tryAction` ukáže
  `friendlyDbError`.
- **Dva rychlé zápisy na stejný klíč (přidání dvou připomínek za sebou,
  dřív než první doběhne):** druhé volání čte `minutesOf(ref)`, který už
  ukazuje optimistickou hodnotu PRVNÍHO — takže samo o sobě počítá se
  správným základem a jeho `apply` popisuje kompletní cílový stav (ne jen
  „přidej jednu"). Když starší zápis doběhne (ať uspěje, nebo ne), `_pending`
  smaže JEN pokud je pořád jeho — jinak nechá novější patch být. Zpráva o
  chybě staršího zápisu jde dál i tak (jeho vlastnímu volajícímu), ale
  zobrazený seznam zůstává u novější (ještě neuzavřené) verze.
- **Provider se mezitím zruší** (`ref.invalidate`, autoDispose): nová
  instance `cachedRows`/`withOptimisticOverlay` čte `_pending` znovu podle
  klíče — pokud zápis pořád běží, nová instance ho uvidí taky.
- **Testy sdílející stejné (uid, name):** `_pending`/`_changed` jsou
  modulové globály (stejně jako `RowCache`'s SharedPreferences klíče) —
  testy proto používají různé `name` řetězce na test, stejná konvence,
  jakou už `test/data/cache_test.dart` dodržuje.

## Testy

**`test/data/optimistic_test.dart`** (nový soubor, čisté jednotky bez
`cachedRows`):
- `applyPending` beze zápisu vrací `rows` beze změny.
- `optimisticWrite` zavolá `apply` ihned (patch je vidět přes
  `applyPending` dřív, než `write` doběhne).
- Po úspěchu `applyPending` vrací zase `rows` beze změny (patch zmizel).
- Po chybě `applyPending` taky vrací `rows` beze změny A chyba proletí
  ven z `optimisticWrite`'s Future.
- Dva zápisy na stejný klíč: druhý přebírá viditelnost; doběhnutí PRVNÍHO
  (úspěch i chyba) nesmaže patch druhého, dokud ten taky nedoběhne.
- `pendingChanges` vyšle událost při začátku i konci zápisu, a nevyšle nic
  pro jiný klíč.
- `patchRow`: nahradí pole na řádku s odpovídajícím klíčem, ostatní řádky
  nechá beze změny, žádný odpovídající řádek → beze změny.
- `upsertOrDeleteRows`: upsert existujícího řádku ho nahradí (nezdvojí),
  upsert neexistujícího přidá, delete odstraní, nedotčené řádky zůstanou.

**`test/data/cache_test.dart`** (integrace s `cachedRows`, vzor podle
existujícího „probuzení obnoví i stream, který se tváří zdravě"):
- Bez jakéhokoliv doručení z `live()` `optimisticWrite` na klíč streamu
  hned přepíše to, co `cachedRows` vydává.
- Skutečné doručení PO zápisu (nesouvisející změna od serveru) se
  přemapuje skrz patch dál, dokud zápis neskončí — patch nezmizí sám.
- Po dokončení zápisu (fake `write` dokončí Future) další skutečné
  doručení ukáže přesně to, co přišlo (patch je pryč).

**Žádný existující widget test se měnit nemusí.** `ProfileScreen` i
`CalendarLinkCard` berou `setNotifyBefore`/`setReminders`/… jako
injektovaný parametr s výchozí hodnotou `Api.setXxx` — testy si vždycky
injektují vlastní falešnou funkci (a v případě kalendářových připomínek
si samy ručně pushují novou hodnotu do svého `StreamController`, viz
„the reminders sheet composes…" test). Skutečná `Api.setXxx` (to, co se
mění) se tak v žádném widget testu vůbec nevolá — nová optimistická
vrstva je za injekčním švem, který testy dnes obchází. Ověřit až po
implementaci: `flutter test test/features/` beze změny zůstává celé
zelené.

## Mimo rozsah

- Časovač ticha / periodické obnovení `cachedRows` bez ohledu na
  optimismus — případné budoucí řešení pro zápisy OD JINÝCH lidí (cizí
  rezervace, zápas přidaný administrátorem…), na které tahle změna
  nedosáhne. Zatím bez důkazu, že je potřeba.
- `setNick` (dvojí použití — self i admin za jiného).
- Cokoliv, kde server rozhoduje o kolizi/limitu/mazání cizích dat
  (rezervace, výjimky dnů, bloky, nastavení rozvrhu, role, oddíly, druhý
  kalendář, veřejný přehled).
