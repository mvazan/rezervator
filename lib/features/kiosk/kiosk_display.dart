/// Keeps a kiosk display lit and bare while the shell is on it. Left alone,
/// a shared screen sleeps and shows its system bars like any Android device;
/// the kiosk wants neither — the screen stays on (a wake lock:
/// FLAG_KEEP_SCREEN_ON in the Android app, the browser's Screen Wake Lock on
/// the web) and, in the Android app, the status and navigation bars go away
/// (immersive sticky; a swipe from an edge peeks them — a browser has no
/// bars of its own to hide). Best effort: a platform or browser without one
/// of the two keeps going without it.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/web/kiosk_low_res.dart';

class KioskDisplay {
  const KioskDisplay();

  /// The admin's „Nižší rozlišení“ (0065): the web kiosk draws at
  /// devicePixelRatio 1 and reloads when the choice changes; nothing in
  /// the app (see core/web/kiosk_low_res.dart).
  void lowRes(bool on) => setKioskLowRes(on);

  /// The kiosk is leaving (a sign-out, a role change) or a plain session is
  /// starting: the stored choice goes, so the browser does not stay at
  /// ratio 1 for whoever uses it next. No reload.
  void forgetLowRes() => forgetKioskLowRes();

  /// On entering the kiosk: screen on, bars hidden.
  Future<void> hold() => _each([
    WakelockPlus.enable,
    if (!kIsWeb)
      () => SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
  ]);

  /// On leaving it (the kiosk account signs out): the platform's defaults
  /// again — the screen may sleep, both bars shown.
  Future<void> release() => _each([
    WakelockPlus.disable,
    if (!kIsWeb)
      () => SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      ),
  ]);

  /// Runs the steps in order; one the platform refuses (no wake lock there,
  /// no plugin under a test) does not stop the next.
  static Future<void> _each(List<Future<void> Function()> steps) async {
    for (final step in steps) {
      try {
        await step();
      } on PlatformException {
        // Best effort — see the library doc.
      } on MissingPluginException {
        // Same.
      }
    }
  }
}

/// The shell's handle on the display; tests put a recorder here.
final kioskDisplayProvider = Provider<KioskDisplay>(
  (ref) => const KioskDisplay(),
);
