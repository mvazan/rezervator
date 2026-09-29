import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Pins the canteen-duty calls (0050) at the HTTP layer: the RPC names and
/// parameter names must match the SQL exactly — PostgREST finds a function
/// by them — and the two day-edit writes that used to go straight to the
/// tables now go through the RPCs the duty may call too.
void main() {
  late List<http.Request> requests;

  /// What each RPC answers in these tests (PostgREST's JSON for the SQL
  /// return value).
  const answers = {
    'duty_generate': '{"created":3,"skipped":1}',
    'duty_period_save': '"p-new"',
    'duty_periods_delete_unassigned': '4',
    'add_special_block': '"sb1"',
  };

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final mock = MockClient((request) async {
      requests.add(request);
      final name = request.url.pathSegments.last;
      final body = request.url.path.contains('/rpc/')
          ? answers[name] ?? 'null'
          : '[]';
      return http.Response(
        body,
        200,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    });
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test-anon-key',
      httpClient: mock,
      authOptions: const FlutterAuthClientOptions(
        detectSessionInUri: false,
        localStorage: EmptyLocalStorage(),
      ),
    );
  });

  setUp(() => requests = []);

  /// The single request that went out, checked to be a POST to `rpc/[name]`;
  /// returns its JSON body.
  Map<String, dynamic> rpcCall(String name) {
    expect(requests, hasLength(1));
    final call = requests.single;
    expect(call.method, 'POST');
    expect(call.url.path, '/rest/v1/rpc/$name');
    return jsonDecode(call.body) as Map<String, dynamic>;
  }

  test('dutyGenerate sends the range and returns created/skipped', () async {
    final result = await Api.dutyGenerate(
      from: Day(2026, 10, 6),
      days: 7,
      until: Day(2027, 6, 30),
    );
    expect(rpcCall('duty_generate'), {
      'p_from': '2026-10-06',
      'p_days': 7,
      'p_until': '2027-06-30',
    });
    expect(result.created, 3);
    expect(result.skipped, 1);
  });

  test('dutyPeriodSave inserts with a null id and returns the id', () async {
    final id = await Api.dutyPeriodSave(
      startsOn: Day(2026, 10, 5),
      endsOn: Day(2026, 10, 11),
      note: 'Vánoce',
    );
    expect(rpcCall('duty_period_save'), {
      'p_id': null,
      'p_starts_on': '2026-10-05',
      'p_ends_on': '2026-10-11',
      'p_note': 'Vánoce',
    });
    expect(id, 'p-new');
  });

  test('dutyPeriodSave edits by id', () async {
    await Api.dutyPeriodSave(
      id: 'p1',
      startsOn: Day(2026, 10, 5),
      endsOn: Day(2026, 10, 12),
    );
    expect(rpcCall('duty_period_save'), {
      'p_id': 'p1',
      'p_starts_on': '2026-10-05',
      'p_ends_on': '2026-10-12',
      'p_note': '',
    });
  });

  test('dutyPeriodDelete', () async {
    await Api.dutyPeriodDelete('p1');
    expect(rpcCall('duty_period_delete'), {'p_id': 'p1'});
  });

  test('dutyPeriodsDeleteUnassigned returns how many went', () async {
    final n = await Api.dutyPeriodsDeleteUnassigned(Day(2026, 9, 27));
    expect(rpcCall('duty_periods_delete_unassigned'), {'p_from': '2026-09-27'});
    expect(n, 4);
  });

  test('dutySetAssignees replaces the whole set', () async {
    await Api.dutySetAssignees('p1', const ['u1', 'u2']);
    expect(rpcCall('duty_set_assignees'), {
      'p_period': 'p1',
      'p_users': ['u1', 'u2'],
    });
  });

  test('dutySeasonStart and dutySeasonDelete', () async {
    await Api.dutySeasonStart(Day(2026, 9, 1), '2026/27');
    expect(rpcCall('duty_season_start'), {
      'p_started_on': '2026-09-01',
      'p_name': '2026/27',
    });

    requests.clear();
    await Api.dutySeasonDelete(Day(2026, 9, 1));
    expect(rpcCall('duty_season_delete'), {'p_started_on': '2026-09-01'});
  });

  test(
    'setDutyReminder writes both columns of the alley\'s settings row',
    () async {
      await Api.setDutyReminder(true, 2, tenantId: 't1');
      expect(requests, hasLength(1));
      final patch = requests.single;
      expect(patch.method, 'PATCH');
      expect(patch.url.path, '/rest/v1/schedule_settings');
      expect(patch.url.queryParameters['tenant_id'], 'eq.t1');
      expect(jsonDecode(patch.body), {
        'duty_reminder_enabled': true,
        'duty_reminder_days': 2,
      });
    },
  );

  test(
    'addSpecialBlock goes through add_special_block, never the table',
    () async {
      final id = await Api.addSpecialBlock(
        const HourMinute(17, 30),
        const HourMinute(18, 30),
      );
      expect(rpcCall('add_special_block'), {
        'p_starts_at': '17:30:00',
        'p_ends_at': '18:30:00',
      });
      expect(id, 'sb1');
    },
  );

  test(
    'deleteDayOverride goes through delete_day_override, never the table',
    () async {
      await Api.deleteDayOverride(Day(2026, 10, 6));
      expect(rpcCall('delete_day_override'), {'p_date': '2026-10-06'});
    },
  );
}
