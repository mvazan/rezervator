/// Signál „appka se probudila" pro živé streamy.
///
/// Supabase při přechodu do pozadí realtime socket VĚDOMĚ odpojí a po
/// návratu ho spojí znovu (supabase_flutter, _processLifecycle). Data na
/// obrazovce jsou do té doby stará a stream čeká na svůj backoff — tenhle
/// tick ho nechá přihlásit se hned. Pomáhá i na socket, který se tváří
/// živý, ale nic nedoručuje (half-open spojení po uspání telefonu).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

class LiveRefresh {
  LiveRefresh._();

  static final _controller = StreamController<void>.broadcast();
  static DateTime? _last;

  /// Poslouchá [cachedRows]; každý tick znamená „přihlas se znovu".
  static Stream<void> get stream => _controller.stream;

  /// Volá se při návratu appky do popředí. Škrcené na jeden tick za dvě
  /// sekundy — přepínání mezi appkami jinak resumy chrlí.
  static void request() {
    final now = DateTime.now();
    if (_last != null && now.difference(_last!) < const Duration(seconds: 2)) {
      return;
    }
    _last = now;
    if (!_controller.isClosed) _controller.add(null);
  }

  /// Testy běží v jednom procesu — bez tohohle by škrcení přeneslo stav
  /// z předchozího testu.
  @visibleForTesting
  static void resetThrottle() => _last = null;
}
