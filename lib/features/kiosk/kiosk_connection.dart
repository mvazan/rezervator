/// Whether the kiosk is still connected — a tablet on the wall that lost
/// its network keeps showing the last board it had, and nobody would know
/// it is stale. The realtime socket is what keeps the board live, so its
/// state is the check: polled every few seconds, and only a loss that
/// lasts (a reconnect takes a moment) counts.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// How often the socket is asked, and how long it may be down before the
/// kiosk says so.
const _poll = Duration(seconds: 5);
const _grace = Duration(seconds: 15);

/// Whether the realtime socket is open right now. A test overrides it;
/// without Supabase (a test that does not) the kiosk counts as connected.
final kioskSocketOpenProvider = Provider<bool Function()>(
  (ref) => () {
    try {
      return Supabase.instance.client.realtime.isConnected;
    } catch (_) {
      return true;
    }
  },
);

/// Since when the kiosk has been without a connection (past the grace
/// period); null while connected.
final kioskOfflineSinceProvider = StreamProvider<DateTime?>((ref) {
  final open = ref.watch(kioskSocketOpenProvider);
  final controller = StreamController<DateTime?>();
  // Counted in polls, not read off the wall clock: the polls are what
  // ticks (and what a test's fake clock drives).
  var downPolls = 0;
  DateTime? downSince;
  DateTime? reported;
  var first = true;
  void check() {
    if (open()) {
      downPolls = 0;
      downSince = null;
    } else {
      downPolls++;
      downSince ??= DateTime.now();
    }
    final now = downPolls * _poll.inSeconds >= _grace.inSeconds
        ? downSince
        : null;
    if (first || now != reported) {
      first = false;
      reported = now;
      controller.add(now);
    }
  }

  final timer = Timer.periodic(_poll, (_) => check());
  check();
  ref.onDispose(() {
    timer.cancel();
    controller.close();
  });
  return controller.stream;
});

/// The strip the kiosk shows while it is without a connection.
class KioskOfflineBanner extends ConsumerWidget {
  const KioskOfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final since = ref.watch(kioskOfflineSinceProvider).value;
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      child: since == null
          ? const SizedBox(width: double.infinity)
          : Container(
              width: double.infinity,
              color: scheme.errorContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    Icons.cloud_off,
                    size: 18,
                    color: scheme.onErrorContainer,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Kiosk je bez spojení od ${since.hour}:'
                      '${since.minute.toString().padLeft(2, '0')} — rozvrh '
                      'a výsledky nemusí být aktuální.',
                      style: TextStyle(
                        color: scheme.onErrorContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
