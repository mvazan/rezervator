import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/widgets/merge_players_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Pins the merge dialog: which fields get a chooser, what the defaults
/// are, and what merge_placeholder_player receives.
void main() {
  const clubs = [
    Club(id: 'c1', name: 'Sokol', colorIndex: 1),
    Club(id: 'c2', name: 'Veverky', colorIndex: 2),
  ];
  const placeholder = Profile(
    id: 'ph1',
    displayName: 'Bohumil Kroupa',
    email: '',
    role: Role.player,
    status: ProfileStatus.approved,
    nick: 'Bohouš',
    clubId: 'c1',
    hasAccount: false,
  );
  const pendingTarget = Profile(
    id: 'u1',
    displayName: 'B. Kroupa',
    email: 'b@example.com',
    role: Role.player,
    status: ProfileStatus.pending,
  );

  late List<http.Request> requests;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final mock = MockClient((request) async {
      requests.add(request);
      return http.Response('{}', 200,
          headers: {'content-type': 'application/json'}, request: request);
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

  Future<void> open(
    WidgetTester tester,
    MergePlayersDialog dialog, {
    void Function(bool?)? onResult,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                final result = await showDialog<bool>(
                    context: context, builder: (_) => dialog);
                onResult?.call(result);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Sloučit hráče'), findsOneWidget);
  }

  Iterable<http.Request> rpc(String name) => requests.where(
      (r) => r.method == 'POST' && r.url.path.endsWith('/rpc/$name'));

  Map<String, dynamic> bodyOf(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  final radios = find.byWidgetPredicate((w) => w is RadioListTile);

  String? clubValue(WidgetTester tester) => tester
      .widget<DropdownButtonFormField<String?>>(
          find.byType(DropdownButtonFormField<String?>))
      .initialValue;

  testWidgets('choosers only for differing filled fields; the nick and club '
      'fall through to the one side that has them', (tester) async {
    await open(
        tester,
        const MergePlayersDialog(
            placeholder: placeholder, target: pendingTarget, clubs: clubs));

    final intro = find.textContaining('převezme rezervace');
    expect(intro, findsOneWidget);
    final introText = tester.widget<Text>(intro).data!;
    expect(introText, contains('b@example.com'));
    expect(introText, contains('„Bohumil Kroupa“'));
    expect(introText, contains('a bude schválen'));

    // Name: both filled and different → a chooser with both values, the
    // account's name in the field.
    expect(radios, findsNWidgets(2));
    expect(find.text('z účtu'), findsOneWidget);
    expect(find.text('od hráče bez účtu'), findsOneWidget);
    expect(find.text('Bohumil Kroupa'), findsOneWidget); // radio title only
    expect(find.widgetWithText(TextField, 'B. Kroupa'), findsOneWidget);

    // Nick: only the placeholder has one → no chooser, its nick prefilled.
    expect(find.widgetWithText(TextField, 'Bohouš'), findsOneWidget);

    // Club: only the placeholder has one → the dropdown starts on it.
    expect(clubValue(tester), 'c1');
  });

  testWidgets('picking the placeholder name then Sloučit posts the merge and '
      'pops true', (tester) async {
    bool? result;
    await open(
        tester,
        const MergePlayersDialog(
            placeholder: placeholder, target: pendingTarget, clubs: clubs),
        onResult: (r) => result = r);

    await tester.tap(find.text('Bohumil Kroupa'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Bohumil Kroupa'), findsOneWidget);

    await tester.tap(find.text('Sloučit'));
    await tester.pumpAndSettle();

    final body = bodyOf(rpc('merge_placeholder_player').single);
    expect(body, {
      'p_placeholder_id': 'ph1',
      'p_target_id': 'u1',
      'p_display_name': 'Bohumil Kroupa',
      'p_nick': 'Bohouš',
      'p_club_id': 'c1',
    });
    expect(result, isTrue);
    expect(find.text('Sloučit hráče'), findsNothing);
    expect(find.text('Hráči sloučeni.'), findsOneWidget);
  });

  testWidgets('a manual edit after a radio pick wins', (tester) async {
    await open(
        tester,
        const MergePlayersDialog(
            placeholder: placeholder, target: pendingTarget, clubs: clubs));

    await tester.tap(find.text('Bohumil Kroupa'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Bohumil Kroupa'), 'Bohumil Kroupa st.');
    await tester.tap(find.text('Sloučit'));
    await tester.pumpAndSettle();

    final body = bodyOf(rpc('merge_placeholder_player').single);
    expect(body['p_display_name'], 'Bohumil Kroupa st.');
  });

  testWidgets('an emptied name is refused — no request', (tester) async {
    await open(
        tester,
        const MergePlayersDialog(
            placeholder: placeholder, target: pendingTarget, clubs: clubs));

    await tester.enterText(find.widgetWithText(TextField, 'B. Kroupa'), '');
    await tester.tap(find.text('Sloučit'));
    await tester.pumpAndSettle();

    expect(find.text('Vyplň jméno hráče.'), findsOneWidget);
    expect(requests, isEmpty);
    expect(find.text('Sloučit hráče'), findsOneWidget);
  });

  testWidgets('an approved target is not "a bude schválen"; nick and club '
      'choosers appear when both sides differ and a pick switches the field',
      (tester) async {
    const approvedTarget = Profile(
      id: 'u2',
      displayName: 'Bohumil Kroupa',
      email: 'bk@example.com',
      role: Role.player,
      status: ProfileStatus.approved,
      nick: 'BK',
      clubId: 'c2',
    );
    await open(
        tester,
        const MergePlayersDialog(
            placeholder: placeholder, target: approvedTarget, clubs: clubs));

    final introText =
        tester.widget<Text>(find.textContaining('převezme rezervace')).data!;
    expect(introText, isNot(contains('a bude schválen')));

    // Same name → no name chooser; nick and club differ → two choosers.
    expect(radios, findsNWidgets(4));
    expect(find.text('BK'), findsOneWidget); // radio title only
    expect(find.text('Bohouš'), findsNWidgets(2)); // radio title + field
    expect(clubValue(tester), 'c2'); // the account's club by default

    await tester.tap(find.text('BK'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'BK'), findsOneWidget);

    // The club radio titles are club names; the dropdown lists them too, so
    // tap the radio row itself (below the dialog's scroll fold).
    final clubRadio = find.ancestor(
        of: find.text('od hráče bez účtu').last, matching: radios);
    await tester.ensureVisible(clubRadio);
    await tester.pumpAndSettle();
    await tester.tap(clubRadio);
    await tester.pumpAndSettle();
    expect(clubValue(tester), 'c1');

    await tester.tap(find.text('Sloučit'));
    await tester.pumpAndSettle();
    final body = bodyOf(rpc('merge_placeholder_player').single);
    expect(body['p_target_id'], 'u2');
    expect(body['p_display_name'], 'Bohumil Kroupa');
    expect(body['p_nick'], 'BK');
    expect(body['p_club_id'], 'c1');
  });

  testWidgets('a target without an e-mail is named by its display name',
      (tester) async {
    const nameless = Profile(
      id: 'u3',
      displayName: 'Bořek Kroupa',
      email: '',
      role: Role.player,
      status: ProfileStatus.pending,
    );
    await open(
        tester,
        const MergePlayersDialog(
            placeholder: placeholder, target: nameless, clubs: clubs));
    final introText =
        tester.widget<Text>(find.textContaining('převezme rezervace')).data!;
    expect(introText, startsWith('Účet Bořek Kroupa převezme'));
  });
}
