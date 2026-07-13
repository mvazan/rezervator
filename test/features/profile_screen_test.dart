import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/profile/profile_screen.dart';

void main() {
  const me = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    club: 'TJ Sokol',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
    nick: 'Já H.',
  );

  Widget app(Profile profile) {
    return ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(profile)),
      ],
      child: const MaterialApp(home: ProfileScreen()),
    );
  }

  testWidgets('shows display name, club, current nick and the edit '
      'affordance', (tester) async {
    await tester.pumpWidget(app(me));
    await tester.pumpAndSettle();

    expect(find.text('Můj profil'), findsOneWidget);
    expect(find.text('Já Hráč'), findsOneWidget);
    expect(find.text('TJ Sokol'), findsOneWidget);
    expect(find.text('Já H.'), findsOneWidget);
    expect(find.text('Upravit'), findsOneWidget);
  });

  testWidgets('shows "nenastavena" when nick is empty', (tester) async {
    await tester.pumpWidget(app(const Profile(
      id: 'me',
      displayName: 'Já Hráč',
      club: '',
      email: 'me@example.com',
      role: Role.player,
      status: ProfileStatus.approved,
    )));
    await tester.pumpAndSettle();

    expect(find.text('nenastavena'), findsOneWidget);
  });

  testWidgets('tapping Upravit opens the prompt prefilled with the current '
      'nick', (tester) async {
    await tester.pumpWidget(app(me));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Upravit'));
    await tester.pumpAndSettle();

    expect(find.text('Přezdívka na tabuli'), findsWidgets);
    expect(find.text('Uložit'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Já H.'), findsOneWidget);
  });

  testWidgets('shows a logout action', (tester) async {
    await tester.pumpWidget(app(me));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.logout), findsOneWidget);
    expect(find.text('Odhlásit se'), findsOneWidget);
  });

  testWidgets('tapping logout asks for confirmation before signing out', (
    tester,
  ) async {
    await tester.pumpWidget(app(me));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Odhlásit se'));
    await tester.pumpAndSettle();

    // The confirm dialog appears; nothing is signed out until confirmed.
    expect(find.text('Opravdu se chceš odhlásit?'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Odhlásit se'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Zrušit'), findsOneWidget);
  });

  testWidgets('confirmed logout pops the screen back to the root route '
      '(the pushed screen must not linger above the login gate)',
      (tester) async {
    var signedOut = false;

    await tester.pumpWidget(ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(me)),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ProfileScreen(
                      signOut: () async => signedOut = true,
                    ),
                  ),
                ),
                child: const Text('Otevřít profil'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Otevřít profil'));
    await tester.pumpAndSettle();
    expect(find.text('Můj profil'), findsOneWidget);

    await tester.tap(find.text('Odhlásit se'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Odhlásit se'));
    await tester.pumpAndSettle();

    expect(signedOut, isTrue);
    // Back on the root route — no stranded profile screen with a spinner.
    expect(find.text('Můj profil'), findsNothing);
    expect(find.text('Otevřít profil'), findsOneWidget);
  });
}
