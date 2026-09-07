/// The app's appearance, chosen in Settings.
library;

import 'package:flutter/material.dart';

/// Five choices. [system] keeps today's behaviour (normal contrast, light or
/// dark following the OS). [light]/[dark] force a brightness at normal
/// contrast; [lightContrast]/[darkContrast] force the same brightness at
/// Material's own maximum contrast level. Contrast is its own axis here —
/// unlike Termínátor, where light/dark are always high-contrast.
///
/// These names are persisted (SharedPreferences, see data/local_prefs.dart)
/// — do not rename a value, or every user with that choice saved silently
/// falls back to [ThemeChoice.system] via [parseThemeChoice]'s fallback.
enum ThemeChoice { system, light, dark, lightContrast, darkContrast }

/// Persisted name → choice; anything unknown falls back to [ThemeChoice.system].
ThemeChoice parseThemeChoice(String? name) => ThemeChoice.values
    .firstWhere((c) => c.name == name, orElse: () => ThemeChoice.system);

/// How a choice maps onto MaterialApp: the [ThemeMode] plus the
/// contrastLevel that [buildTheme] passes on to `ColorScheme.fromSeed`.
({ThemeMode mode, double contrastLevel}) themePlanFor(ThemeChoice choice) =>
    switch (choice) {
      ThemeChoice.system => (mode: ThemeMode.system, contrastLevel: 0.0),
      ThemeChoice.light => (mode: ThemeMode.light, contrastLevel: 0.0),
      ThemeChoice.dark => (mode: ThemeMode.dark, contrastLevel: 0.0),
      ThemeChoice.lightContrast => (mode: ThemeMode.light, contrastLevel: 1.0),
      ThemeChoice.darkContrast => (mode: ThemeMode.dark, contrastLevel: 1.0),
    };
