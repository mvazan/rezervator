import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/offline_gate.dart';

void main() {
  final t0 = DateTime(2026, 9, 8, 18, 0);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

  group('offlineDecision', () {
    test('a connected socket is never offline, and forgets any outage', () {
      final d = offlineDecision(
        reachable: true,
        now: at(100),
        wokeAt: t0,
        disconnectedSince: at(10),
      );
      expect(d.offline, isFalse);
      expect(d.disconnectedSince, isNull);
    });

    test('the first tick of an outage only starts the clock', () {
      final d = offlineDecision(
        reachable: false,
        now: at(100),
        wokeAt: t0,
        disconnectedSince: null,
      );
      expect(d.offline, isFalse, reason: 'it may just be reconnecting');
      expect(d.disconnectedSince, at(100));
    });

    test('a socket that stays down past the grace is offline', () {
      final d = offlineDecision(
        reachable: false,
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
        reachable: false,
        now: at(300),
        wokeAt: t0, // stale on purpose
        disconnectedSince: null,
      );
      expect(since.offline, isFalse);

      // Supabase finishes dialling a second later.
      final back = offlineDecision(
        reachable: true,
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
        reachable: false,
        now: at(600),
        wokeAt: t0,
        disconnectedSince: null,
      );
      expect(since.offline, isFalse);
      since = offlineDecision(
        reachable: false,
        now: at(603),
        wokeAt: t0,
        disconnectedSince: since.disconnectedSince,
      );
      expect(since.offline, isFalse, reason: 'still inside the grace');
      final back = offlineDecision(
        reachable: true,
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
        reachable: false,
        now: woke.add(const Duration(seconds: 1)),
        wokeAt: woke,
        disconnectedSince: at(10), // down for ages
      );
      expect(d.offline, isFalse, reason: 'the resume restarts the grace');

      final later = offlineDecision(
        reachable: false,
        now: woke.add(offlineGrace),
        wokeAt: woke,
        disconnectedSince: at(10),
      );
      expect(later.offline, isTrue);
    });
    test('a launch with a working network says nothing while the socket is '
        'still being dialled', () {
      // The reported bug. The socket is not up yet — supabase opens it only
      // once the first stream subscribes — but the probe got an answer, so
      // the network is fine and the app is merely connecting.
      var d = offlineDecision(
        reachable: true,
        now: at(3),
        wokeAt: t0,
        disconnectedSince: null,
      );
      expect(d.offline, isFalse);

      d = offlineDecision(
        reachable: true,
        now: at(60),
        wokeAt: t0,
        disconnectedSince: null,
      );
      expect(d.offline, isFalse, reason: 'however long the socket takes');
      expect(d.disconnectedSince, isNull);
    });

    test('a launch with no network at all does say offline', () {
      // The other half of the same rule, and the reason the banner still
      // earns its place: nothing answers, so this is not "connecting", it is
      // offline — and the player deserves to be told.
      var d = offlineDecision(
        reachable: false,
        now: at(3),
        wokeAt: t0,
        disconnectedSince: null,
      );
      expect(d.offline, isFalse, reason: 'one failed probe only starts the clock');

      d = offlineDecision(
        reachable: false,
        now: at(3 + offlineGrace.inSeconds),
        wokeAt: t0,
        disconnectedSince: d.disconnectedSince,
      );
      expect(d.offline, isTrue);
    });
  });
}
