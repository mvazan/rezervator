import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/text_size.dart';
import 'package:rezervator/core/theme_choice.dart';
import 'package:rezervator/data/local_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('themeChoiceProvider', () {
    test('a saved choice loads on startup', () async {
      SharedPreferences.setMockInitialValues(
          {'theme_choice': 'darkContrast'});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
          container.read(themeChoiceProvider), ThemeChoice.system); // default
      await Future<void>.delayed(Duration.zero); // async _load completes
      expect(container.read(themeChoiceProvider), ThemeChoice.darkContrast);
    });

    test('set updates state and persists the name', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(themeChoiceProvider.notifier)
          .set(ThemeChoice.lightContrast);
      expect(container.read(themeChoiceProvider), ThemeChoice.lightContrast);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('theme_choice'), 'lightContrast');
    });
  });

  group('textSizeProvider', () {
    test('a saved size loads on startup', () async {
      SharedPreferences.setMockInitialValues({'text_size': 'large'});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(textSizeProvider), TextSizeChoice.normal);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(textSizeProvider), TextSizeChoice.large);
    });

    test('set updates state and persists the name', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(textSizeProvider.notifier)
          .set(TextSizeChoice.largest);
      expect(container.read(textSizeProvider), TextSizeChoice.largest);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('text_size'), 'largest');
    });
  });

  group('loadPersistedAppearance', () {
    test('seeds both providers with the persisted values synchronously — '
        'no _load gap, so no default-appearance flash on the first frame',
        () async {
      SharedPreferences.setMockInitialValues(
          {'theme_choice': 'darkContrast', 'text_size': 'largest'});
      final overrides = await loadPersistedAppearance();
      final container = ProviderContainer(overrides: overrides);
      addTearDown(container.dispose);

      // Read immediately, with no `await Future.delayed` gap: unlike the
      // plain providers above, these must already be correct.
      expect(container.read(themeChoiceProvider), ThemeChoice.darkContrast);
      expect(container.read(textSizeProvider), TextSizeChoice.largest);
    });

    test('falls back to the defaults when nothing was saved yet', () async {
      SharedPreferences.setMockInitialValues({});
      final overrides = await loadPersistedAppearance();
      final container = ProviderContainer(overrides: overrides);
      addTearDown(container.dispose);

      expect(container.read(themeChoiceProvider), ThemeChoice.system);
      expect(container.read(textSizeProvider), TextSizeChoice.normal);
    });

    test('a preloaded provider still persists a later set()', () async {
      SharedPreferences.setMockInitialValues({'theme_choice': 'dark'});
      final overrides = await loadPersistedAppearance();
      final container = ProviderContainer(overrides: overrides);
      addTearDown(container.dispose);

      await container
          .read(themeChoiceProvider.notifier)
          .set(ThemeChoice.lightContrast);
      expect(container.read(themeChoiceProvider), ThemeChoice.lightContrast);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('theme_choice'), 'lightContrast');
    });
  });
}
