/// On-device UI preferences that persist across app restarts — appearance
/// choices, device-local like the rest of this file's future siblings
/// (nothing here belongs to a team or lives in Supabase).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
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
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return; // disposed while awaiting — nothing to set
      state = parseThemeChoice(prefs.getString(_themeChoiceKey));
    } catch (_) {
      // Best effort only (like data/cache.dart) — e.g. web with storage
      // blocked. The default already returned by build() still applies.
    }
  }

  Future<void> set(ThemeChoice choice) async {
    state = choice;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_themeChoiceKey, choice.name);
    } catch (_) {
      // Best effort only — the in-memory choice still applies this session.
    }
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
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return; // disposed while awaiting — nothing to set
      state = parseTextSizeChoice(prefs.getString(_textSizeKey));
    } catch (_) {
      // Best effort only (like data/cache.dart) — e.g. web with storage
      // blocked. The default already returned by build() still applies.
    }
  }

  Future<void> set(TextSizeChoice choice) async {
    state = choice;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_textSizeKey, choice.name);
    } catch (_) {
      // Best effort only — the in-memory choice still applies this session.
    }
  }
}

/// A [ThemeChoiceNotifier] that skips its own [_load] and starts directly
/// from a value the caller already read — see [loadPersistedAppearance].
class _PreloadedThemeChoice extends ThemeChoiceNotifier {
  _PreloadedThemeChoice(this._initial);
  final ThemeChoice _initial;
  @override
  ThemeChoice build() => _initial;
}

/// A [TextSizeNotifier] that skips its own [_load] and starts directly from
/// a value the caller already read — see [loadPersistedAppearance].
class _PreloadedTextSize extends TextSizeNotifier {
  _PreloadedTextSize(this._initial);
  final TextSizeChoice _initial;
  @override
  TextSizeChoice build() => _initial;
}

/// Reads both persisted appearance keys once, before `runApp` — see
/// main.dart's `_bootstrap`. Without this, [themeChoiceProvider] and
/// [textSizeProvider] each start from their hard-coded default and only
/// catch up once their own async [ThemeChoiceNotifier._load] /
/// [TextSizeNotifier._load] resolves a frame or two later, so a dark-theme
/// user's very first frame flashes light. Returns `ProviderScope` overrides
/// that seed both providers with the real choice synchronously instead.
/// Best-effort like the rest of this file: any failure here just falls back
/// to the same defaults `_load` would also fall back to.
Future<List<Override>> loadPersistedAppearance() async {
  var themeChoice = ThemeChoice.system;
  var textSize = TextSizeChoice.normal;
  try {
    final prefs = await SharedPreferences.getInstance();
    themeChoice = parseThemeChoice(prefs.getString(_themeChoiceKey));
    textSize = parseTextSizeChoice(prefs.getString(_textSizeKey));
  } catch (_) {
    // Best effort only — see _load above.
  }
  return [
    themeChoiceProvider
        .overrideWith(() => _PreloadedThemeChoice(themeChoice)),
    textSizeProvider.overrideWith(() => _PreloadedTextSize(textSize)),
  ];
}
