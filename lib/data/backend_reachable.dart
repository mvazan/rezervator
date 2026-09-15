/// Ptaní se backendu, jestli tam vůbec je.
///
/// Socket sám o sobě na otázku „jsme offline?" neodpovídá. Řekne jen, že
/// spojení nestojí — a to je po spuštění úplně normální stav, protože
/// supabase socket otevírá teprve ve chvíli, kdy se přihlásí první stream.
/// Jeden HTTP dotaz ten rozdíl rozsekne: když backend odpoví, síť vede a
/// appka se jen připojuje; když dotaz spadne na síťové chybě, je opravdu
/// offline.
library;

import 'package:http/http.dart' as http;

import '../config.dart';

/// Kolik sondě dáme, než ji prohlásíme za neúspěšnou. Kratší než tik pollu
/// (3 s) být nemusí — asyncMap mezitím zdroj pozastaví, takže se tiky
/// nehromadí.
const probeTimeout = Duration(seconds: 4);

/// Jak často se ptát, dokud se rozhodujeme, a jak často, když už banner
/// svítí. Po vyvěšení banneru stačí mnohem míň: návrat sítě ohlásí i sám
/// socket, který se zkouší připojit pořád dokola. Sonda je pak jen pojistka.
const probeWhileDeciding = Duration(seconds: 3);
const probeWhileOffline = Duration(seconds: 15);

/// Whether the backend answered at all.
///
/// The predicate is deliberately about the NETWORK PATH, not about the
/// answer: a 401 (rotated key) or a 404 (moved endpoint) still proves the
/// request got there and back, and reporting "Offline" for either would be a
/// lie. Only a refused connection, a DNS failure or a timeout means offline
/// — and a 5xx, where the path works but the backend does not, which leaves
/// the app just as unable to load data.
Future<bool> backendReachable({http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    final res = await c
        .get(
          Uri.parse('${AppConfig.supabaseUrl}/auth/v1/health'),
          headers: const {'apikey': AppConfig.supabaseAnonKey},
        )
        .timeout(probeTimeout);
    return res.statusCode < 500;
  } catch (_) {
    // SocketException, ClientException, TimeoutException — všechno stejná
    // zpráva: nedoletělo to.
    return false;
  } finally {
    if (client == null) c.close();
  }
}

/// Je čas na další sondu? Čistá funkce, ať jde kadence otestovat bez čekání.
bool probeDue({
  required DateTime now,
  required DateTime? lastProbe,
  required bool offline,
}) {
  if (lastProbe == null) return true;
  return now.difference(lastProbe) >=
      (offline ? probeWhileOffline : probeWhileDeciding);
}
