import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/live_refresh.dart';
import 'package:rezervator/data/providers.dart' show groupRowsStream;
import 'package:rezervator/domain/groups.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Player B accepts player A's invite (0044). RLS shows B the other members
/// only once B is a member — but their rows did not change, so realtime
/// never sends them: B's stream saw just its own row turn 'member' and B
/// could book for nobody until the app restarted. The stream must read the
/// group afresh when B joins.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LiveRefresh.resetThrottle();
  });

  const a = 'user-a';
  const b = 'user-b';
  Map<String, dynamic> row(String user, String status, {String g = 'g1'}) => {
    'group_id': g,
    'user_id': user,
    'status': status,
    'invited_by': user == a ? null : a,
  };

  late List<StreamController<List<Map<String, dynamic>>>> controllers;
  Stream<List<Map<String, dynamic>>> live() {
    final c = StreamController<List<Map<String, dynamic>>>();
    controllers.add(c);
    return c.stream;
  }

  setUp(() => controllers = []);

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  test('joining a group reads it afresh, so the other members show up', () async {
    final emissions = <List<GroupRow>>[];
    final sub = groupRowsStream(b, live).listen(emissions.add);
    await settle();

    // What RLS lets the invitee read: the invite and nothing else.
    controllers.last.add([row(b, 'invited')]);
    await settle();
    expect(myGroupOf(emissions.last, b).invitesForMe, hasLength(1));

    // B accepts: realtime brings B's own row, now a member — and only it.
    controllers.last.add([row(b, 'member')]);
    await settle();
    expect(controllers, hasLength(2), reason: 'joined = subscribe afresh');

    // The fresh read sees what B may see now: the whole group.
    controllers.last.add([row(a, 'member'), row(b, 'member')]);
    await settle();
    expect(myGroupOf(emissions.last, b).matesOf(b), {a});

    // Nothing more to read afresh while the group stays the same.
    controllers.last.add([row(a, 'member'), row(b, 'member')]);
    await settle();
    expect(controllers, hasLength(2));

    unawaited(sub.cancel());
    for (final c in controllers) {
      await c.close();
    }
  });

  test('a member on start, leaving, or an invite: no extra read', () async {
    final sub = groupRowsStream(a, live).listen((_) {});
    await settle();

    // Already in the group when the stream starts: that first read is full.
    controllers.last.add([row(a, 'member'), row(b, 'invited')]);
    await settle();
    controllers.last.add([row(a, 'member'), row(b, 'member')]);
    await settle();
    // Leaving: the own row is gone.
    controllers.last.add([row(b, 'member')]);
    await settle();
    // Invited elsewhere: not a member of anything yet.
    controllers.last.add([row(a, 'invited', g: 'g2')]);
    await settle();
    expect(controllers, hasLength(1));

    unawaited(sub.cancel());
    for (final c in controllers) {
      await c.close();
    }
  });

  test('moving to another group reads that one afresh too', () async {
    final sub = groupRowsStream(b, live).listen((_) {});
    await settle();
    controllers.last.add([row(a, 'member'), row(b, 'member')]);
    await settle();
    // Left g1, then accepted an invite into g2.
    controllers.last.add([row(b, 'member', g: 'g2')]);
    await settle();
    expect(controllers, hasLength(2));

    unawaited(sub.cancel());
    for (final c in controllers) {
      await c.close();
    }
  });
}
