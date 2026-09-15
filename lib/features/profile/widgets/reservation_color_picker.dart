import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/material.dart';

import '../../../domain/palette.dart';

/// The picker for "Barva mých rezervací": the same eleven colours the Google
/// calendar offers, plus "Podle oddílu" and a colour wheel.
///
/// Every non-none pick is stored as a packed RGB (`0x1000000 | rgb`), a Google
/// preset and a wheel colour alike — so the value never lands in the club
/// palette's 0-8 range and `clubTint` renders it straight through
/// `customTint`, legible in either theme (Google's raw RGBs are tuned for
/// Google's white grid and read poorly on a dark board). A Google swatch is
/// therefore just a preset hue; it shows as selected when the stored RGB
/// equals it exactly. The board's own rendering does not change.
class ReservationColorPicker extends StatelessWidget {
  const ReservationColorPicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  /// -1 = "Podle oddílu", otherwise a packed RGB (`isCustomColor`).
  final int selected;
  final ValueChanged<int> onChanged;

  /// The packed value a Google preset stores.
  static int _packed((int, String, Color) e) => packCustomColor(e.$3);

  Future<void> _pickCustom(BuildContext context) async {
    final start = isCustomColor(selected)
        ? unpackCustomColor(selected)
        : Theme.of(context).colorScheme.primary;
    var picked = start;
    final ok = await ColorPicker(
      color: start,
      onColorChanged: (c) => picked = c,
      pickersEnabled: const {
        ColorPickerType.primary: false,
        ColorPickerType.accent: false,
        ColorPickerType.wheel: true,
      },
      enableShadesSelection: false,
      wheelDiameter: 220,
      heading: const Text('Vlastní barva'),
      subheading: const Text(
        'Tabule z ní udělá světlou i tmavou variantu, aby text zůstal '
        'čitelný.',
      ),
      showColorCode: true,
      colorCodeHasColor: true,
    ).showPickerDialog(context, constraints: const BoxConstraints(
      minHeight: 480,
      minWidth: 300,
      maxWidth: 320,
    ));
    if (ok) onChanged(packCustomColor(picked));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final b = scheme.brightness;
    // A packed pick that is not one of the eleven presets belongs to the
    // wheel — a migrated old-palette colour, or a genuinely hand-picked one.
    final isPreset =
        isCustomColor(selected) && googleEventColors.any((e) => _packed(e) == selected);
    final isWheel = isCustomColor(selected) && !isPreset;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _Swatch(
          selected: selected == -1,
          color: scheme.surfaceContainerHighest,
          onColor: scheme.onSurfaceVariant,
          tooltip: 'Podle oddílu',
          onTap: () => onChanged(-1),
          child: const Icon(Icons.block, size: 18),
        ),
        for (final e in googleEventColors)
          // Shown the way the board will render it — customTint of the same
          // hue — not the raw Google RGB, so the swatch and the cell match.
          _Swatch(
            selected: selected == _packed(e),
            color: customTint(_packed(e), b).$1,
            onColor: customTint(_packed(e), b).$2,
            tooltip: e.$2,
            onTap: () => onChanged(_packed(e)),
          ),
        _Swatch(
          selected: isWheel,
          color: isWheel ? customTint(selected, b).$1 : Colors.transparent,
          onColor: isWheel ? customTint(selected, b).$2 : scheme.onSurface,
          tooltip: 'Vlastní barva',
          onTap: () => _pickCustom(context),
          child: isWheel ? null : const _WheelDot(),
        ),
      ],
    );
  }
}

/// One 44dp swatch: a ring and a check on the selected one. Matches
/// `EventColorPicker`/`ColorPickerGrid`'s swatch by eye — those are private
/// to their own files; touch all three if the look ever changes.
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.selected,
    required this.color,
    required this.onColor,
    required this.tooltip,
    required this.onTap,
    this.child,
  });

  final bool selected;
  final Color color;
  final Color onColor;
  final String tooltip;
  final VoidCallback onTap;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? scheme.onSurface : Colors.transparent,
              width: 2,
            ),
          ),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: selected
                ? Icon(Icons.check, size: 20, color: onColor)
                : child,
          ),
        ),
      ),
    );
  }
}

/// The colour wheel in swatch size — what the picker behind it looks like.
class _WheelDot extends StatelessWidget {
  const _WheelDot();

  @override
  Widget build(BuildContext context) => Container(
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: SweepGradient(
            colors: [
              Color(0xFFFF0000),
              Color(0xFFFFFF00),
              Color(0xFF00FF00),
              Color(0xFF00FFFF),
              Color(0xFF0000FF),
              Color(0xFFFF00FF),
              Color(0xFFFF0000),
            ],
          ),
        ),
      );
}
