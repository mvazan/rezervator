import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Pins the messages calls (0051) at the HTTP layer: the RPC names and
/// parameter names must match the SQL exactly — PostgREST finds a function
/// by them.
void main() {
  late List<http.Request> requests;

  /// What each RPC answers in these tests (PostgREST's JSON for the SQL
  /// return value).
  const answers = {
    'message_send': '"m-new"',
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

  /// The single POST to `rpc/[name]`; returns its JSON body.
  Map<String, dynamic> rpcCall(String name) {
    final call =
        requests.singleWhere((r) => r.url.path == '/rest/v1/rpc/$name');
    expect(call.method, 'POST');
    return jsonDecode(call.body) as Map<String, dynamic>;
  }

  test('messageSend sends every field, block audience', () async {
    final id = await Api.messageSend(
      kind: MessageKind.message,
      audience: MessageAudience.block,
      onDate: Day(2026, 10, 2),
      blockId: 'b1',
      body: 'Přijďte dřív.',
    );
    expect(rpcCall('message_send'), {
      'p_kind': 'message',
      'p_audience': 'block',
      'p_on_date': '2026-10-02',
      'p_block_id': 'b1',
      'p_title': null,
      'p_body': 'Přijďte dřív.',
      'p_expires_at': null,
      'p_notify': true,
    });
    expect(id, 'm-new');
  });

  test('messageSend for a notice sends title and expiresAt', () async {
    await Api.messageSend(
      kind: MessageKind.notice,
      audience: MessageAudience.all,
      title: 'Nové dráhy',
      body: 'Od pondělí.',
      expiresAt: DateTime.utc(2026, 10, 20),
      notify: false,
    );
    final body = rpcCall('message_send');
    expect(body['p_kind'], 'notice');
    expect(body['p_audience'], 'all');
    expect(body['p_title'], 'Nové dráhy');
    expect(body['p_expires_at'], '2026-10-20T00:00:00.000Z');
    expect(body['p_notify'], false);
  });

  test('a local expiresAt goes out as UTC, not as a zone-less time', () async {
    // Midnight in Prague (CEST, UTC+2) — a zone-less ISO string would be
    // read by Postgres as midnight UTC, two hours late.
    await Api.messageSend(
      kind: MessageKind.notice,
      audience: MessageAudience.all,
      title: 'Nové dráhy',
      body: 'Od pondělí.',
      expiresAt: DateTime(2026, 10, 20),
    );
    final sent = rpcCall('message_send')['p_expires_at'] as String;
    expect(sent, endsWith('Z'));
    expect(DateTime.parse(sent).isAtSameMomentAs(DateTime(2026, 10, 20)), isTrue);
  });

  test('messageUpdate sends the full state, including null expiresAt', () async {
    await Api.messageUpdate('n1', title: 'Nové dráhy', body: 'Upraveno.', expiresAt: null);
    expect(rpcCall('message_update'), {
      'p_id': 'n1',
      'p_title': 'Nové dráhy',
      'p_body': 'Upraveno.',
      'p_expires_at': null,
    });
  });

  test('messageDelete sends the id', () async {
    await Api.messageDelete('m1');
    expect(rpcCall('message_delete'), {'p_id': 'm1'});
  });

  // setReaction/setReply/markMessagesRead read `currentUserId`, and this
  // MockClient has no session — their optimistic patch is covered in
  // test/data/optimistic_test.dart and the JSON they send here:
  test('reactionToJson maps the enum to the CHECK values', () {
    expect(reactionToJson(Reaction.up), 'up');
    expect(reactionToJson(Reaction.down), 'down');
    expect(reactionToJson(null), isNull);
  });
}
