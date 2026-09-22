import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/groups.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/profile/widgets/my_group_card.dart';

void main() {
  const roster = [
    PlayerName(id: 'me', displayName: 'Já Hráč'),
    PlayerName(id: 'jana', displayName: 'Jana Nová'),
    PlayerName(id: 'petr', displayName: 'Petr Starý'),
    PlayerName(id: 'deda', displayName: 'Děda', hasAccount: false),
  ];

  final calls = <String>[];

  Widget app(MyGroup group) => ProviderScope(
        overrides: [
          myGroupProvider.overrideWithValue(group),
          playersProvider.overrideWith((ref) async => roster),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MyGroupCard(
                meId: 'me',
                invite: (id) async => calls.add('invite:$id'),
                accept: (g) async => calls.add('accept:$g'),
                decline: (g) async => calls.add('decline:$g'),
                leave: () async => calls.add('leave'),
                cancelInvite: (g, u) async => calls.add('cancel:$g:$u'),
              ),
            ),
          ),
        ),
      );

  setUp(calls.clear);

  testWidgets('without a group it explains itself and invites', (tester) async {
    await tester.pumpWidget(app(MyGroup.none));
    await tester.pumpAndSettle();

    expect(find.text('Moje skupina'), findsOneWidget);
    expect(
        find.text('Rezervujte a rušte tréninky za sebe navzájem — třeba '
            'rodina nebo dvojice.'),
        findsOneWidget);

    await tester.tap(find.text('Pozvat do skupiny…'));
    await tester.pumpAndSettle();
    // No me, no player without an account.
    expect(find.text('Já Hráč'), findsNothing);
    expect(find.text('Děda'), findsNothing);
    await tester.enterText(find.byType(TextField), 'jan');
    await tester.pumpAndSettle();
    expect(find.text('Petr Starý'), findsNothing);
    await tester.tap(find.text('Jana Nová'));
    await tester.pumpAndSettle();
    expect(calls, ['invite:jana']);
  });

  testWidgets('an invite for me is answered on the card', (tester) async {
    await tester.pumpWidget(app(const MyGroup(
      invitesForMe: [GroupInvite(groupId: 'g2', invitedBy: 'petr')],
    )));
    await tester.pumpAndSettle();

    expect(find.text('Petr Starý tě zve do skupiny'), findsOneWidget);
    await tester.tap(find.text('Přijmout'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Odmítnout'));
    await tester.pumpAndSettle();
    expect(calls, ['accept:g2', 'decline:g2']);
  });

  testWidgets('in a group: members, pending invites to withdraw, leave',
      (tester) async {
    await tester.pumpWidget(app(const MyGroup(
      groupId: 'g1',
      memberIds: ['me', 'jana'],
      invitedIds: ['petr'],
    )));
    await tester.pumpAndSettle();

    expect(find.text('Jana Nová'), findsOneWidget);
    expect(find.text('Petr Starý'), findsOneWidget);
    expect(find.text('pozván(a)'), findsOneWidget);

    await tester.tap(find.byTooltip('Stáhnout pozvánku'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Opustit skupinu'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Opustit'));
    await tester.pumpAndSettle();
    expect(calls, ['cancel:g1:petr', 'leave']);
  });

  testWidgets('a failed accept says why in Czech', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        myGroupProvider.overrideWithValue(const MyGroup(
          invitesForMe: [GroupInvite(groupId: 'g2', invitedBy: 'petr')],
        )),
        playersProvider.overrideWith((ref) async => roster),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: MyGroupCard(
            meId: 'me',
            accept: (_) async => throw Exception('already_in_group'),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Přijmout'));
    await tester.pumpAndSettle();
    expect(find.text('Už jsi v jiné skupině — nejdřív z ní odejdi.'),
        findsOneWidget);
  });
}
