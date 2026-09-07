import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/material.dart';

import '../../../domain/palette.dart';

/// Reusable club/rental color picker: a grid of the 12 [ClubColors] swatches
/// (rendered with each color's dark background, since that's the more
/// saturated/legible variant for a small swatch) plus a leading "none"
/// option.
///
/// The selected swatch is marked TWICE over: a check mark inside it, drawn
/// in that color's own foreground so it reads on every swatch, and a ring
/// around it separated by a gap. A single ring in the theme's primary was
/// invisible on the blue-ish swatches (and it ate into the color, because a
/// border is painted inside the box).
///
/// The row ends with one more swatch — a colour wheel — for a colour that is
/// not in the palette at all. It opens the wheel picker and reports the
/// chosen colour packed as [packCustomColor]; the swatch then shows that
/// colour, shaded the same way the schedule will render it.
///
/// [noneValue] is the index reported for the "none" option and used to
/// detect it as selected (e.g. -1 "žádná" for a club, -2 "výchozí" for a
/// rental). [noneLabel] is its caption.
class ColorPickerGrid extends StatelessWidget {
  const ColorPickerGrid({
    super.key,
    required this.selected,
    required this.onChanged,
    this.noneValue = -1,
    this.noneLabel = 'Žádná',
  });

  final int selected;
  final ValueChanged<int> onChanged;
  final int noneValue;
  final String noneLabel;

  /// Opens the wheel on the colour already chosen — a hand-picked one as it
  /// was picked, otherwise the selected palette entry, so the wheel starts
  /// where the user left off instead of on an unrelated colour.
  Future<void> _pickCustom(BuildContext context) async {
    final start = isCustomColor(selected)
        ? unpackCustomColor(selected)
        : ClubColors.of(selected, Brightness.dark)?.$1 ??
            Theme.of(context).colorScheme.primary;
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
        'Kalendář z ní udělá světlou i tmavou variantu, aby text zůstal '
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
    final custom = isCustomColor(selected);
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _Swatch(
          selected: selected == noneValue,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          onColor: Theme.of(context).colorScheme.onSurfaceVariant,
          tooltip: noneLabel,
          onTap: () => onChanged(noneValue),
          child: const Icon(Icons.block, size: 18),
        ),
        for (var i = 0; i < ClubColors.count; i++)
          _Swatch(
            selected: selected == i,
            color: ClubColors.of(i, Brightness.dark)!.$1,
            onColor: ClubColors.of(i, Brightness.dark)!.$2,
            tooltip: ClubColors.names[i],
            onTap: () => onChanged(i),
          ),
        _Swatch(
          selected: custom,
          color: custom
              ? customTint(selected, Brightness.dark).$1
              : Colors.transparent,
          onColor: custom
              ? customTint(selected, Brightness.dark).$2
              : Theme.of(context).colorScheme.onSurface,
          tooltip: 'Vlastní barva',
          onTap: () => _pickCustom(context),
          // Unselected it is the wheel itself, so it reads as "any colour"
          // rather than as a thirteenth preset.
          child: custom ? null : const _WheelDot(),
        ),
      ],
    );
  }
}

/// The colour wheel in swatch size: what the picker behind it looks like.
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

  /// The color's own foreground — what the check mark is drawn in, so it
  /// stays legible on a dark navy swatch as well as on a pale grey one.
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
          // 44 is the comfortable tap target; the ring sits on its edge and
          // the padding keeps it clear of the color itself.
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
              // Hairline, so a pale swatch keeps an edge against the card.
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
