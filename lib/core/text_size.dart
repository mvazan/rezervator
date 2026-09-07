/// Text size chosen in Settings.
///
/// The app already respects the system's Android text scale (Flutter does
/// that on its own); this is an EXTRA multiplier for people who want bigger
/// text just in this app.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Three steps. The multipliers mirror Android's own system steps (large =
/// 115%, largest = 130%), so the result feels familiar.
///
/// These names are persisted (SharedPreferences, see data/local_prefs.dart)
/// — do not rename a value, or every user with that choice saved silently
/// falls back to [TextSizeChoice.normal] via [parseTextSizeChoice]'s
/// fallback.
enum TextSizeChoice { normal, large, largest }

double textSizeFactor(TextSizeChoice choice) => switch (choice) {
      TextSizeChoice.normal => 1.0,
      TextSizeChoice.large => 1.15,
      TextSizeChoice.largest => 1.3,
    };

/// Persisted name → choice; anything unknown falls back to normal size.
TextSizeChoice parseTextSizeChoice(String? name) => TextSizeChoice.values
    .firstWhere((c) => c.name == name, orElse: () => TextSizeChoice.normal);

/// The system scale multiplied by the Settings choice, capped at twice the
/// design size: WCAG 1.4.4 wants text scalable to 200%, and Android 14 caps
/// there too. Without the cap, the system maximum and "largest" would
/// multiply out to 260% and break layouts.
class AppTextScaler extends TextScaler {
  const AppTextScaler(this.system, this.choice);

  /// The scale from the phone's own settings.
  final TextScaler system;
  final TextSizeChoice choice;

  static const _maxOfDesignSize = 2.0;

  @override
  double scale(double fontSize) => math.min(
      system.scale(fontSize) * textSizeFactor(choice),
      fontSize * _maxOfDesignSize);

  @override
  double get textScaleFactor => scale(14) / 14;

  // Without these, MediaQuery's textScaler aspect always compares unequal
  // (TextScaler has no meaningful default ==), so every Text rebuilds on
  // any MediaQuery change at all — keyboard, rotation, window resize —
  // not just a real text-size change.
  @override
  bool operator ==(Object other) =>
      other is AppTextScaler &&
      other.system == system &&
      other.choice == choice;

  @override
  int get hashCode => Object.hash(system, choice);
}
