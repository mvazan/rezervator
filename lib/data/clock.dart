/// One wall clock for the UI. Everything time-dependent — inPast/beyond-
/// horizon slot states, the kiosk's clock and status line, "next training"
/// — watches [nowProvider], so all of it flips at the same minute and no
/// widget runs a timer of its own.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Pure core of [nowProvider]: the current time immediately, then a fresh
/// value whenever the minute changes. Polls [clock] every [poll] through
/// Stream.periodic (forwarded with yield*), so the timer dies the moment the
/// provider is disposed and widget tests leak nothing.
Stream<DateTime> minuteClock({
  required DateTime Function() clock,
  Duration poll = const Duration(seconds: 15),
}) async* {
  var last = clock();
  yield last;
  yield* Stream.periodic(poll, (_) => clock()).expand((t) {
    if (t.year == last.year &&
        t.month == last.month &&
        t.day == last.day &&
        t.hour == last.hour &&
        t.minute == last.minute) {
      return const <DateTime>[];
    }
    last = t;
    return [t];
  });
}

/// The app's clock, minute granularity. Read it as
/// `ref.watch(nowProvider).value ?? DateTime.now()` — the fallback only
/// matters for the first frame before the stream's synchronous-ish first
/// value lands.
final nowProvider = StreamProvider<DateTime>(
  (ref) => minuteClock(clock: DateTime.now),
);
