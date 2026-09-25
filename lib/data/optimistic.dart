/// Optimistická vrstva nad [cachedRows] (`lib/data/cache.dart`): appka ví,
/// co právě zapsala, a nemusí čekat, až se to vrátí přes realtime. Klíč je
/// stejný pár (uid, name) jako u cachedRows a RowCache — viz konstanty
/// cacheKey* v cache.dart, sdílené mezi čtecí stranou (cachedRows) a
/// zápisovou (Api.setXxx v providers.dart).
///
/// Bez tohohle appka po uložení jen čeká na ozvěnu z realtime kanálu — za
/// normálních okolností pár set milisekund, ale na slabé síti nebo se
/// socketem, který se tváří živě a nic nedoručuje (žádná chyba, žádné
/// uzavření — jediné, co ho dnes probudí, je návrat appky z pozadí,
/// LiveRefresh), to vypadá, že se uložená změna vůbec nestala.
library;

import 'dart:async';

/// Jeden probíhající (nebo právě potvrzený) zápis pro jeden klíč. [apply]
/// přemění, co by [cachedRows] jinak vydal, na to, co tenhle zápis
/// očekává — volá se znovu na KAŽDÉ skutečné doručení, dokud zápis
/// neskončí, aby nesouvisející změna (např. admin schválí jiného hráče a
/// přepíše celý profil) tu optimistickou nezahodila.
///
/// [confirmed] rozlišuje „ještě čekám na odpověď serveru" od „server
/// potvrdil, čekám na ozvěnu přes realtime, abych patch mohl zahodit" — než
/// ozvěna dorazí, patch musí zůstat (jinak by na okamžik bliklo staré,
/// ještě neaktualizované doručení, které mezitím dorazilo).
class _Pending {
  _Pending(this.apply);
  final List<Map<String, dynamic>> Function(List<Map<String, dynamic>> rows)
      apply;
  bool confirmed = false;
}

/// Every write on a key that has not yet settled, oldest first. Each keeps
/// its own [_Pending.confirmed], so writes that overlap on one key (two
/// switches in the profile, reminders and the training colour) succeed,
/// fail and settle each on their own.
final _pending = <String, List<_Pending>>{};

/// „Pro tenhle klíč se něco změnilo" — [withOptimisticOverlay] na to
/// reaguje okamžitým přemapováním posledních známých řádků, BEZ nového
/// připojení k live streamu.
final _changed = StreamController<String>.broadcast();

/// „Tenhle klíč má právě potvrzený zápis — přihlas se znovu, ať přijde
/// ozvěna co nejdřív, i kdyby byl socket zaseknutý." Stejný efekt jako
/// [LiveRefresh], ale mířený jen na jeden stream, ne na všechny.
final _refresh = StreamController<String>.broadcast();

String _key(String uid, String name) => '$uid.$name';

/// [rows], jak by je viděl volající, když se na klíč (uid, name) právě
/// vztahuje probíhající nebo potvrzený optimistický zápis — jinak beze
/// změny.
List<Map<String, dynamic>> applyPending(
    String uid, String name, List<Map<String, dynamic>> rows) {
  var out = rows;
  for (final entry in _pending[_key(uid, name)] ?? const <_Pending>[]) {
    out = entry.apply(out);
  }
  return out;
}

/// Poslouchá se v [withOptimisticOverlay]: „přemapuj znovu, pro tenhle
/// klíč se něco stalo" (nový zápis začal, byl potvrzen, nebo skončil).
Stream<void> pendingChanges(String uid, String name) =>
    _changed.stream.where((k) => k == _key(uid, name));

/// Poslouchá se v `cachedRows`'s `_untilWake`: „tenhle klíč právě potvrdil
/// zápis — přihlas se znovu hned, nečekej na backoff."
Stream<void> refreshRequests(String uid, String name) =>
    _refresh.stream.where((k) => k == _key(uid, name));

/// Odstraní potvrzené patche pro (uid, name) — voláno z
/// [withOptimisticOverlay] při KAŽDÉM skutečném doručení, aby po potvrzení
/// první další ozvěna (server ji mohl protřídit/odduplikovat) definitivně
/// převzala pravdu. Zápisy, které ještě čekají na odpověď (`!confirmed`),
/// zůstávají — nesouvisející doručení je nesmí zahodit.
///
/// Jen potvrzené ZE ZAČÁTKU fronty, po první nepotvrzený: potvrzený novější
/// zápis za ním musí zůstat. Server ukládá zápisy v pořadí odeslání, ale
/// odpovědi (calendar-manage po přepsání událostí v Googlu) chodí v
/// libovolném; kdyby novější zmizel dřív, starší by nad ozvěnou, která už
/// má novější hodnotu, na obrazovku vrátil tu svou (smazanou připomínku).
void settlePending(String uid, String name) {
  final key = _key(uid, name);
  final entries = _pending[key];
  if (entries == null) return;
  while (entries.isNotEmpty && entries.first.confirmed) {
    entries.removeAt(0);
  }
  if (entries.isEmpty) _pending.remove(key);
}

/// Spustí [write] na pozadí; UI vidí efekt [apply] OKAMŽITĚ, ne až po
/// odpovědi serveru. Uspěje-li [write], patch zůstává (viz [settlePending])
/// a cílené [refreshRequests] donutí dotčený stream přihlásit se znovu, i
/// kdyby byl zaseknutý — první další doručení pak ukáže přesně to, co
/// server uložil (Google kalendář připomínky např. setřídí a odstraní
/// duplicity). Selže-li, patch mizí hned a chyba jde dál — volající
/// (`tryAction`) ji odchytí jako dnes.
///
/// Zápisy na STEJNÝ klíč, které se překrývají (rychlé přidání dvou
/// připomínek, dva přepínače v profilu za sebou, připomínky a barva
/// tréninků), stojí v pořadí za sebou a appka vidí všechny: každý patch se
/// aplikuje nad ten předchozí, novější tedy u stejného pole vyhrává, jak to
/// skončí i na serveru. Každý zápis posílá na server jen svá pole. (Dřív
/// novější patch starší nahradil a starší změna jiného pole na okamžik
/// zmizela, než dorazila její ozvěna.) Každý zápis si svůj výsledek řeší
/// sám: úspěch ho označí za potvrzený a vyžádá ozvěnu, chyba odstraní jen
/// jeho patch a jde jeho volajícímu dál — ostatní zápisy na klíči tím
/// nejsou dotčené, ať skončí v jakémkoli pořadí.
Future<void> optimisticWrite(
  String uid,
  String name,
  List<Map<String, dynamic>> Function(List<Map<String, dynamic>> rows) apply,
  Future<void> Function() write,
) async {
  final key = _key(uid, name);
  final entry = _Pending(apply);
  (_pending[key] ??= []).add(entry);
  _changed.add(key);
  try {
    await write();
    entry.confirmed = true;
    _refresh.add(key);
  } catch (_) {
    final entries = _pending[key];
    if (entries != null) {
      entries.remove(entry);
      if (entries.isEmpty) _pending.remove(key);
    }
    _changed.add(key);
    rethrow;
  }
}

/// Obaluje [raw] (výstup `cachedRows`'s core generátoru, beze změny) tak,
/// že každé doručení — replay z cache i každé živé — projde [applyPending].
/// Navíc reaguje na [pendingChanges]: nové/potvrzené/skončené optimistické
/// psaní přemapuje POSLEDNÍ známé řádky okamžitě, bez zásahu do `raw`
/// (žádné nové připojení, žádná síť).
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
        settlePending(uid, name);
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
