import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/text_size.dart';
import 'package:rezervator/core/theme_choice.dart';
import 'package:rezervator/data/local_prefs.dart';
import 'package:rezervator/features/profile/widgets/appearance_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The "Vzhled" card's two rows (Motiv, Velikost písma), each a
/// title/current-choice `ListTile` that opens a `SimpleDialog` of
/// `RadioListTile`s — see `lib/features/profile/widgets/appearance_card.dart`.
void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  Widget app() => const ProviderScope(
        child: MaterialApp(home: Scaffold(body: AppearanceCard())),
      );

  group('Motiv row', () {
    testWidgets('shows the card title and "Podle systému" by default', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.text('Vzhled'), findsOneWidget);
      expect(find.text('Motiv'), findsOneWidget);
      expect(find.text('Podle systému'), findsOneWidget);
    });

    testWidgets('opening the dialog lists every theme option and marks the '
        'current one selected', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Motiv'));
      await tester.pumpAndSettle();

      expect(find.text('Podle systému'), findsWidgets); // row + dialog option
      expect(find.text('Světlý'), findsOneWidget);
      expect(find.text('Tmavý'), findsOneWidget);
      expect(find.text('Světlý — vysoký kontrast'), findsOneWidget);
      expect(find.text('Tmavý — vysoký kontrast'), findsOneWidget);

      final group = tester.widget<RadioGroup<ThemeChoice>>(
        find.byType(RadioGroup<ThemeChoice>),
      );
      expect(group.groupValue, ThemeChoice.system);
    });

    testWidgets('picking "Tmavý" updates the provider and the subtitle', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: AppearanceCard())),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Motiv'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tmavý'));
      await tester.pumpAndSettle();

      expect(container.read(themeChoiceProvider), ThemeChoice.dark);
      expect(find.text('Tmavý'), findsOneWidget);
      expect(find.text('Podle systému'), findsNothing);
    });
  });

  group('Velikost písma row', () {
    testWidgets('shows the normal label by default', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.text('Velikost písma'), findsOneWidget);
      expect(find.text('Normální — jako v telefonu'), findsOneWidget);
    });

    testWidgets('opening the dialog lists every size option and marks the '
        'current one selected', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Velikost písma'));
      await tester.pumpAndSettle();

      expect(find.text('Normální — jako v telefonu'), findsWidgets);
      expect(find.text('Větší (115 %)'), findsOneWidget);
      expect(find.text('Největší (130 %)'), findsOneWidget);

      final group = tester.widget<RadioGroup<TextSizeChoice>>(
        find.byType(RadioGroup<TextSizeChoice>),
      );
      expect(group.groupValue, TextSizeChoice.normal);
    });

    testWidgets('picking "Největší (130 %)" updates the provider and the '
        'subtitle', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: AppearanceCard())),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Velikost písma'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Největší (130 %)'));
      await tester.pumpAndSettle();

      expect(container.read(textSizeProvider), TextSizeChoice.largest);
      expect(find.text('Největší (130 %)'), findsOneWidget);
      expect(find.text('Normální — jako v telefonu'), findsNothing);
    });
  });
}
