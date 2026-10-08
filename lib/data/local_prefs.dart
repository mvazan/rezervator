/// On-device UI preferences that persist across app restarts — appearance
/// choices and remembered views, device-local like the rest of this file's
/// future siblings (nothing here belongs to a team or lives in Supabase).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/text_size.dart';
import '../core/theme_choice.dart';
import '../domain/models.dart' show MatchLayout, parseMatchLayout;

const _themeChoiceKey = 'theme_choice';
const _textSizeKey = 'text_size';
const _matchLayoutPortraitKey = 'match_layout_portrait';
const _matchLayoutLandscapeKey = 'match_layout_landscape';
const _dutyClubFilterKey = 'duty_club_filter';
const _venueCompetitionKey = 'venue_competition_filter';

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

/// How the match detail draws a match, by the way the device is held
/// (Můj profil → Detail zápasu): [MatchLayout.full] (the duel cards,
/// scrolling), [MatchLayout.compact] or [MatchLayout.table] (fitted to the
/// screen), or [MatchLayout.zapis] — the score sheet: upright in place of
/// the duels, sideways full screen the moment the phone turns (closed when
/// it turns back).
///
/// Device-local (a phone and a tablet are held differently), persisted by
/// name — see [MatchLayout].
typedef MatchLayoutPrefs = ({MatchLayout portrait, MatchLayout landscape});

const defaultMatchLayoutPrefs = (
  portrait: MatchLayout.full,
  landscape: MatchLayout.full,
);

/// Persisted names → prefs; anything unknown is [MatchLayout.full].
MatchLayoutPrefs parseMatchLayoutPrefs(String? portrait, String? landscape) => (
  portrait: parseMatchLayout(portrait),
  landscape: parseMatchLayout(landscape),
);

final matchLayoutPrefsProvider =
    NotifierProvider<MatchLayoutPrefsNotifier, MatchLayoutPrefs>(
      MatchLayoutPrefsNotifier.new,
    );

class MatchLayoutPrefsNotifier extends Notifier<MatchLayoutPrefs> {
  @override
  MatchLayoutPrefs build() {
    _load();
    return defaultMatchLayoutPrefs;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return; // disposed while awaiting — nothing to set
      state = parseMatchLayoutPrefs(
        prefs.getString(_matchLayoutPortraitKey),
        prefs.getString(_matchLayoutLandscapeKey),
      );
    } catch (_) {
      // Best effort only — see ThemeChoiceNotifier._load.
    }
  }

  /// Sets the layout for one orientation now and remembers it.
  Future<void> set({MatchLayout? portrait, MatchLayout? landscape}) async {
    state = (
      portrait: portrait ?? state.portrait,
      landscape: landscape ?? state.landscape,
    );
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_matchLayoutPortraitKey, state.portrait.name);
      await prefs.setString(_matchLayoutLandscapeKey, state.landscape.name);
    } catch (_) {
      // Best effort only — the in-memory choice still applies this session.
    }
  }
}

/// The club chip picked last in Správa → Služby's assign sheet, so an admin
/// assigning several duties in a row keeps the same club: a club id, `''`
/// for „Bez oddílu“, null for „Všichni“. Device-local.
final dutyClubFilterProvider =
    NotifierProvider<DutyClubFilterNotifier, String?>(
        DutyClubFilterNotifier.new);

class DutyClubFilterNotifier extends Notifier<String?> {
  @override
  String? build() {
    _load();
    return null;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      state = prefs.getString(_dutyClubFilterKey);
    } catch (_) {
      // Best effort only — the default (everybody) applies.
    }
  }

  Future<void> set(String? club) async {
    state = club;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (club == null) {
        await prefs.remove(_dutyClubFilterKey);
      } else {
        await prefs.setString(_dutyClubFilterKey, club);
      }
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// Výsledky: by team or by competition (0055)
// ---------------------------------------------------------------------------

const _resultsModeKey = 'results_mode';
const _resultsCompetitionKey = 'results_competition';

/// How Výsledky lists the matches: [teams] = our teams' matches (chips: Vše
/// and a team), [competitions] = one whole competition by round, foreign
/// matches included.
///
/// Persisted by name — do not rename a value.
enum ResultsMode { teams, competitions }

ResultsMode parseResultsMode(String? name) => ResultsMode.values
    .firstWhere((m) => m.name == name, orElse: () => ResultsMode.teams);

/// The mode picked last, remembered on the device. Defaults to [ResultsMode.teams].
final resultsModeProvider =
    NotifierProvider<ResultsModeNotifier, ResultsMode>(ResultsModeNotifier.new);

class ResultsModeNotifier extends Notifier<ResultsMode> {
  @override
  ResultsMode build() {
    _load();
    return ResultsMode.teams;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      state = parseResultsMode(prefs.getString(_resultsModeKey));
    } catch (_) {
      // Best effort only, like the match detail's view.
    }
  }

  Future<void> set(ResultsMode mode) async {
    state = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_resultsModeKey, mode.name);
    } catch (_) {}
  }
}

/// The competition (its slug) picked last in [ResultsMode.competitions];
/// null until one was picked — the screen then takes the first.
final resultsCompetitionProvider =
    NotifierProvider<ResultsCompetitionNotifier, String?>(
        ResultsCompetitionNotifier.new);

class ResultsCompetitionNotifier extends Notifier<String?> {
  @override
  String? build() {
    _load();
    return null;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      state = prefs.getString(_resultsCompetitionKey);
    } catch (_) {}
  }

  Future<void> set(String slug) async {
    state = slug;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_resultsCompetitionKey, slug);
    } catch (_) {}
  }
}

/// A [ResultsModeNotifier] that starts from a value already read — see
/// [loadPersistedResultsView].
class _PreloadedResultsMode extends ResultsModeNotifier {
  _PreloadedResultsMode(this._initial);
  final ResultsMode _initial;
  @override
  ResultsMode build() => _initial;
}

/// A [ResultsCompetitionNotifier] that starts from a value already read —
/// see [loadPersistedResultsView].
class _PreloadedResultsCompetition extends ResultsCompetitionNotifier {
  _PreloadedResultsCompetition(this._initial);
  final String? _initial;
  @override
  String? build() => _initial;
}

/// Reads the saved Výsledky mode and competition once, before `runApp`, the
/// way [loadPersistedAppearance] does. Without it the screen's first frame
/// is the teams view and the saved one arrives a frame later — the list
/// latches (scroll, poke of live matches) would run for the wrong list.
Future<List<Override>> loadPersistedResultsView() async {
  var mode = ResultsMode.teams;
  String? competition;
  try {
    final prefs = await SharedPreferences.getInstance();
    mode = parseResultsMode(prefs.getString(_resultsModeKey));
    competition = prefs.getString(_resultsCompetitionKey);
  } catch (_) {
    // Best effort only — see _load above.
  }
  return [
    resultsModeProvider.overrideWith(() => _PreloadedResultsMode(mode)),
    resultsCompetitionProvider
        .overrideWith(() => _PreloadedResultsCompetition(competition)),
  ];
}

/// The competition chip picked last in Klubovna → Kuželny (its name), null
/// for „Vše“. Device-local.
final venueCompetitionFilterProvider =
    NotifierProvider<VenueCompetitionFilterNotifier, String?>(
        VenueCompetitionFilterNotifier.new);

class VenueCompetitionFilterNotifier extends Notifier<String?> {
  @override
  String? build() {
    _load();
    return null;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      state = prefs.getString(_venueCompetitionKey);
    } catch (_) {
      // Best effort only — the default (all alleys) applies.
    }
  }

  Future<void> set(String? competition) async {
    state = competition;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (competition == null) {
        await prefs.remove(_venueCompetitionKey);
      } else {
        await prefs.setString(_venueCompetitionKey, competition);
      }
    } catch (_) {}
  }
}
