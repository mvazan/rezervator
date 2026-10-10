/// Routes above the kiosk (0066): the name picker, a notice, the Zápis, a
/// booking confirm. While one is open the stream's player must not take
/// touches — on the web a dialog drawn over the iframe would be
/// see-through to YouTube where they overlap. Whoever pushes a route calls
/// [KioskModals.enter] before and [KioskModals.leave] after; the window
/// watches the count.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

class KioskModals extends Notifier<int> {
  @override
  int build() => 0;

  void enter() => state = state + 1;

  void leave() => state = state - 1;

  /// Runs [show] — a route above the kiosk — counted in and out.
  Future<T> around<T>(Future<T> Function() show) async {
    enter();
    try {
      return await show();
    } finally {
      leave();
    }
  }
}

/// How many routes sit above the kiosk right now.
final kioskModalsProvider = NotifierProvider<KioskModals, int>(
  KioskModals.new,
);
