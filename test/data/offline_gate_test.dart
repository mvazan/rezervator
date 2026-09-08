import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/offline_gate.dart';

void main() {
  final t0 = DateTime(2026, 9, 8, 18, 0);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

  group('offlineDecision', () {
    test('a connected socket is never offline, and forgets any outage', () {
      final d = offlineDecision(
        connected: true,
        now: at(100),
        wokeAt: t0,
        disconnectedSince: at(10),
      );
      expect(d.offline, isFalse);
      expect(d.disconnectedSince, isNull);
    });

    test('the first tick of an outage only starts the clock', () {
      final d = offlineDecision(
        connected: false,
        now: at(100),
        wokeAt: t0,
        disconnectedSince: null,
      );
      expect(d.offline, isFalse, reason: 'it may just be reconnecting');
      expect(d.disconnectedSince, at(100));
    });

    test('a socket that stays down past the grace is offline', () {
      final d = offlineDecision(
        connected: false,
        now: at(100 + offlineGrace.inSeconds),
        wokeAt: t0,
        disconnectedSince: at(100),
      );
      expect(d.offline, isTrue);
      expect(d.disconnectedSince, at(100), reason: 'the outage keeps its start');
    });

    test('a resume does not report offline while the socket redials — even '
        'when the tick lands before the wake was recorded', () {
      // The poll and the wake event race. This is the tick that used to win
      // the race and flash the banner: the app just came back, the socket is
      // still down, and wokeAt is not yet updated.
      var since = offlineDecision(
        connected: false,
        now: at(300),
        wokeAt: t0, // stale on purpose
        disconnectedSince: null,
      );
      expect(since.offline, isFalse);

      // Supabase finishes dialling a second later.
      final back = offlineDecision(
        connected: true,
        now: at(301),
        wokeAt: t0,
        disconnectedSince: since.disconnectedSince,
      );
      expect(back.offline, isFalse);
      expect(back.disconnectedSince, isNull);
    });

    test('a quick app switch reports no wake at all, and still no banner', () {
      // LiveRefresh throttles to one signal per two seconds, so a fast
      // minimise/restore emits nothing: wokeAt stays old and only the
      // persistence rule protects the banner.
      var since = offlineDecision(
        connected: false, now: at(600), wokeAt: t0, disconnectedSince: null);
      expect(since.offline, isFalse);
      since = offlineDecision(
        connected: false,
        now: at(603),
        wokeAt: t0,
        disconnectedSince: since.disconnectedSince,
      );
      expect(since.offline, isFalse, reason: 'still inside the grace');
      final back = offlineDecision(
        connected: true,
        now: at(604),
        wokeAt: t0,
        disconnectedSince: since.disconnectedSince,
      );
      expect(back.offline, isFalse);
    });

    test('a socket already down before the app was minimised gets the same '
        'fair chance after the resume', () {
      final woke = at(1000);
      final d = offlineDecision(
        connected: false,
        now: woke.add(const Duration(seconds: 1)),
        wokeAt: woke,
        disconnectedSince: at(10), // down for ages
      );
      expect(d.offline, isFalse, reason: 'the resume restarts the grace');

      final later = offlineDecision(
        connected: false,
        now: woke.add(offlineGrace),
        wokeAt: woke,
        disconnectedSince: at(10),
      );
      expect(later.offline, isTrue);
    });
  });
}
