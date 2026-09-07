/// On-device UI preferences that persist across app restarts — appearance
/// choices, device-local like the rest of this file's future siblings
/// (nothing here belongs to a team or lives in Supabase).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/text_size.dart';
import '../core/theme_choice.dart';

const _themeChoiceKey = 'theme_choice';
const _textSizeKey = 'text_size';

/// The appearance chosen in Settings. Device-local: it's about how the
/// screen looks, not about the team.
final themeChoiceProvider = NotifierProvider<ThemeChoiceNotifier, ThemeChoice>(
    ThemeChoiceNotifier.new);

class ThemeChoiceNotifier extends Notifier<ThemeChoice> {
  @override
  ThemeChoice build() {
    _load();
    return ThemeChoice.system;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = parseThemeChoice(prefs.getString(_themeChoiceKey));
  }

  Future<void> set(ThemeChoice choice) async {
    state = choice;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeChoiceKey, choice.name);
  }
}

/// Text size chosen in Settings — an extra multiplier on top of the phone's
/// own system scale (see core/text_size.dart).
final textSizeProvider =
    NotifierProvider<TextSizeNotifier, TextSizeChoice>(TextSizeNotifier.new);

class TextSizeNotifier extends Notifier<TextSizeChoice> {
  @override
  TextSizeChoice build() {
    _load();
    return TextSizeChoice.normal;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = parseTextSizeChoice(prefs.getString(_textSizeKey));
  }

  Future<void> set(TextSizeChoice choice) async {
    state = choice;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_textSizeKey, choice.name);
  }
}
