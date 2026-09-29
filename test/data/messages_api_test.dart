import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/data/cache.dart';
import 'package:rezervator/data/optimistic.dart';
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

  /// What a table GET answers (else no rows): the messages snapshot holds
  /// one message, `kept`.
  const tableAnswers = {
    'messages': '[{"id": "kept", "kind": "message", "audience": "admins", '
        '"author_id": null, "author_role": "player", "on_date": null, '
        '"block_id": null, "title": null, "body": "x", "expires_at": null, '
        '"notify": true, "created_at": "2026-10-01T00:00:00Z", '
        '"updated_at": "2026-10-01T00:00:00Z"}]',
  };

  /// The status every PATCH gets — a test sets 403 to see a write refused.
  var patchStatus = 200;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final mock = MockClient((request) async {
      requests.add(request);
      final name = request.url.pathSegments.last;
      if (request.method == 'PATCH' && patchStatus != 200) {
        return http.Response(
          '{"code": "42501", "message": "permission denied"}',
          patchStatus,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }
      final body = request.url.path.contains('/rpc/')
          ? answers[name] ?? 'null'
          : tableAnswers[name] ?? '[]';
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

  setUp(() {
    requests = [];
    patchStatus = 200;
  });

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

  test('reactionToJson maps the enum to the CHECK values', () {
    expect(reactionToJson(Reaction.up), 'up');
    expect(reactionToJson(Reaction.down), 'down');
    expect(reactionToJson(null), isNull);
  });

  // Last in the file: the session stays for the rest of the isolate.
  group('signed in', () {
    const uid = '11111111-1111-1111-1111-111111111111';

    setUpAll(() async {
      String b64(Map<String, Object> json) =>
          base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
      final exp = DateTime.now().add(const Duration(hours: 1));
      final jwt = '${b64({'alg': 'HS256', 'typ': 'JWT'})}.'
          '${b64({'sub': uid, 'role': 'authenticated', 'exp': exp.millisecondsSinceEpoch ~/ 1000})}'
          '.sig';
      await Supabase.instance.client.auth.recoverSession(jsonEncode({
        'access_token': jwt,
        'token_type': 'bearer',
        'expires_in': 3600,
        'refresh_token': 'r',
        'user': {'id': uid, 'aud': 'authenticated', 'created_at': '2026-01-01'},
      }));
      expect(currentUserId, uid);
    });

    /// The first GET on `/rest/v1/[table]` once [provider]'s stream has
    /// fetched its snapshot — PostgREST caps an unfiltered one at max rows.
    Future<http.Request> snapshotFetch(
        ProviderListenable<Object?> provider, String table) async {
      final container = ProviderContainer();
      final sub = container.listen(provider, (_, _) {});
      try {
        for (var i = 0; i < 100; i++) {
          final hit = requests.where(
              (r) => r.method == 'GET' && r.url.path == '/rest/v1/$table');
          if (hit.isNotEmpty) return hit.first;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        fail('no snapshot fetch of $table');
      } finally {
        sub.close();
        container.dispose();
      }
    }


    test('each messages snapshot drops the participant caches of the '
        'messages it no longer lists', () async {
      final prefs = await SharedPreferences.getInstance();
      final gone = 'cache.$uid.${cacheKeyMessageParticipants('gone')}';
      final kept = 'cache.$uid.${cacheKeyMessageParticipants('kept')}';
      await prefs.setString(gone, '[]');
      await prefs.setString(kept, '[]');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final sub = container.listen(messagesProvider, (_, _) {});
      addTearDown(sub.close);
      for (var i = 0; i < 100 && prefs.containsKey(gone); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect([for (final m in container.read(messagesProvider).value!) m.id],
          ['kept']);
      expect(prefs.containsKey(gone), isFalse);
      expect(prefs.containsKey(kept), isTrue);
    });

    test('my recipient rows: only mine, never every row I may read', () async {
      final get = await snapshotFetch(myMessageRecipientsProvider, 'message_recipients');
      expect(get.url.queryParameters['user_id'], 'eq.$uid');
      expect(get.url.queryParameters.containsKey('message_id'), isFalse);
    });

    test("one message's participants: that message's rows only", () async {
      final get = await snapshotFetch(
          messageParticipantsProvider('m1'), 'message_recipients');
      expect(get.url.queryParameters['message_id'], 'eq.m1');
      expect(get.url.queryParameters.containsKey('user_id'), isFalse);
    });

    /// My row on m1 as both overlays see it after [write] succeeded (the
    /// confirmed patch stays until the stream's next delivery).
    Future<List<Map<String, dynamic>>> overlays(Future<void> Function() write) async {
      await write();
      final row = {'message_id': 'm1', 'user_id': uid, 'reaction': null, 'reply': null};
      final other = {'message_id': 'm1', 'user_id': 'petr', 'reaction': 'down', 'reply': null};
      return [
        applyPending(uid, cacheKeyMessageRecipients, [row]).single,
        ...applyPending(uid, cacheKeyMessageParticipants('m1'), [other, row]),
      ];
    }

    test('setReaction patches my row, in my rows and in the reaction line', () async {
      final seen = await overlays(() => Api.setReaction('m1', Reaction.up));
      final patch = requests.singleWhere((r) => r.method == 'PATCH');
      expect(patch.url.path, '/rest/v1/message_recipients');
      expect(patch.url.queryParameters['message_id'], 'eq.m1');
      expect(patch.url.queryParameters['user_id'], 'eq.$uid');
      expect(jsonDecode(patch.body), {'reaction': 'up'});
      expect([for (final r in seen) r['reaction']], ['up', 'down', 'up']);
    });

    test('setReply trims, and patches both overlays too', () async {
      final seen = await overlays(() => Api.setReply('m1', '  nestihnu '));
      final patch = requests.singleWhere((r) => r.method == 'PATCH');
      expect(jsonDecode(patch.body), {'reply': 'nestihnu'});
      expect([for (final r in seen) r['reply']], ['nestihnu', null, 'nestihnu']);
    });
  });
}
