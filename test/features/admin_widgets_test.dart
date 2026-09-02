import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/widgets/admin_scaffold.dart';
import 'package:rezervator/features/admin/widgets/form_dialog.dart';
import 'package:rezervator/features/admin/widgets/form_fields.dart';

void main() {
  const admin = Profile(
    id: 'a',
    displayName: 'Správce',
    email: 'a@example.com',
    role: Role.admin,
    status: ProfileStatus.approved,
  );
  const player = Profile(
    id: 'p',
    displayName: 'Hráč',
    email: 'p@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
  );

  Widget app(Widget home, {Profile? me}) => ProviderScope(
        overrides: [
          myProfileProvider.overrideWith((ref) => Stream.value(me)),
        ],
        child: MaterialApp(home: home),
      );

  group('AdminScaffold', () {
    // Two tests, not one: a second pumpWidget does not swap ProviderScope
    // overrides.
    testWidgets('refuses a player', (tester) async {
      await tester.pumpWidget(app(
        const AdminScaffold(title: 'Oddíly', body: Text('OBSAH')),
        me: player,
      ));
      await tester.pumpAndSettle();
      expect(find.text('Jen pro správce.'), findsOneWidget);
      expect(find.text('OBSAH'), findsNothing);
    });

    testWidgets('renders title and body for an admin', (tester) async {
      await tester.pumpWidget(app(
        const AdminScaffold(title: 'Oddíly', body: Text('OBSAH')),
        me: admin,
      ));
      await tester.pumpAndSettle();
      expect(find.text('Oddíly'), findsOneWidget);
      expect(find.text('OBSAH'), findsOneWidget);
    });

    testWidgets('superadminOnly refuses a regular admin', (tester) async {
      await tester.pumpWidget(app(
        const AdminScaffold(
            title: 'Kuželny', body: Text('OBSAH'), superadminOnly: true),
        me: admin,
      ));
      await tester.pumpAndSettle();
      expect(find.text('Jen pro správce aplikace.'), findsOneWidget);
    });
  });

  group('AsyncBody', () {
    testWidgets('loading, error with retry, data', (tester) async {
      var retried = 0;
      Widget body(AsyncValue<int> v) => MaterialApp(
            home: Scaffold(
              body: AsyncBody<int>(
                value: v,
                onRetry: () => retried++,
                builder: (n) => Text('DATA $n'),
              ),
            ),
          );
      await tester.pumpWidget(body(const AsyncLoading()));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pumpWidget(
          body(AsyncError(Exception('slot_taken'), StackTrace.empty)));
      expect(find.text('Termín je už obsazený.'), findsOneWidget);
      await tester.tap(find.text('Zkusit znovu'));
      expect(retried, 1);

      await tester.pumpWidget(body(const AsyncData(7)));
      expect(find.text('DATA 7'), findsOneWidget);
    });
  });

  group('FormDialog', () {
    testWidgets('stays open when onSave returns null, pops with the result '
        'otherwise', (tester) async {
      var attempts = 0;
      String? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showDialog<String>(
                  context: context,
                  builder: (_) => FormDialog<String>(
                    title: 'Přidat oddíl',
                    children: const [Text('POLE')],
                    onSave: () async {
                      attempts++;
                      return attempts == 1 ? null : 'hotovo';
                    },
                  ),
                );
              },
              child: const Text('OTEVŘÍT'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('OTEVŘÍT'));
      await tester.pumpAndSettle();
      expect(find.text('Přidat oddíl'), findsOneWidget);
      expect(find.text('POLE'), findsOneWidget);

      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();
      expect(find.text('Přidat oddíl'), findsOneWidget); // still open
      expect(find.text('Uložit'), findsOneWidget); // re-enabled label

      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();
      expect(find.text('Přidat oddíl'), findsNothing);
      expect(result, 'hotovo');
    });
  });

  group('FormDialog saveEnabled', () {
    testWidgets('false disables Uložit without touching onSave',
        (tester) async {
      var saves = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FormDialog<bool>(
            title: 'Generátor',
            saveEnabled: false,
            onSave: () async {
              saves++;
              return true;
            },
            children: const [Text('POLE')],
          ),
        ),
      ));
      final button = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Uložit'));
      expect(button.onPressed, isNull);
      await tester.tap(find.text('Uložit'), warnIfMissed: false);
      await tester.pump();
      expect(saves, 0);
    });
  });

  group('form fields', () {
    testWidgets('LaneChips reports the toggled selection', (tester) async {
      Set<int>? got;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LaneChips(
              laneCount: 3, selected: const {1}, onChanged: (s) => got = s),
        ),
      ));
      await tester.tap(find.text('Dráha 3'));
      expect(got, {1, 3});
      await tester.tap(find.text('Dráha 1'));
      expect(got, <int>{});
    });

    testWidgets('PickerTile shows label and value and taps through',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PickerTile(
              label: 'Datum', value: 'čt 23. 4.', onTap: () => taps++),
        ),
      ));
      expect(find.text('Datum'), findsOneWidget);
      expect(find.text('čt 23. 4.'), findsOneWidget);
      await tester.tap(find.text('Datum'));
      expect(taps, 1);
    });

    testWidgets('ColorDot renders', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: ColorDot(colorIndex: 2)),
      ));
      expect(find.byType(ColorDot), findsOneWidget);
    });
  });

  group('confirmDelete', () {
    testWidgets('runs the action only after confirmation', (tester) async {
      var ran = 0;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => confirmDelete(
                context,
                title: 'Smazat oddíl?',
                message: 'Opravdu?',
                action: () async => ran++,
                success: 'Smazáno.',
              ),
              child: const Text('SMAZAT'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('SMAZAT'));
      await tester.pumpAndSettle();
      expect(find.text('Smazat oddíl?'), findsOneWidget);
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();
      expect(ran, 0);

      await tester.tap(find.text('SMAZAT'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ano'));
      await tester.pumpAndSettle();
      expect(ran, 1);
      expect(find.text('Smazáno.'), findsOneWidget);
    });
  });
}
