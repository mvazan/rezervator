import 'package:flutter/material.dart';

import '../../../domain/palette.dart';

/// Google's fixed event colours (`colorId` 1–11) plus "bez barvy" (the event
/// inherits its calendar's own colour), as a picker: the same swatch shape
/// as `ColorPickerGrid` (44dp target, ring + check mark on the selected
/// one), but a fixed list — Google takes no other RGB for an event (see
/// docs/superpowers/specs/2026-09-07-secondary-calendar-design.md), so there
/// is no colour wheel here.
class EventColorPicker extends StatelessWidget {
  const EventColorPicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  /// The chosen Google `colorId` (1–11), or null for "bez barvy".
  final int? selected;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final (id, name, color) in googleEventColors)
          _Swatch(
            selected: selected == id,
            color: color,
            onColor: _legibleOn(color),
            tooltip: name,
            onTap: () => onChanged(id),
          ),
        _Swatch(
          selected: selected == null,
          color: scheme.surfaceContainerHighest,
          onColor: scheme.onSurfaceVariant,
          tooltip: 'Bez barvy',
          onTap: () => onChanged(null),
          child: const Icon(Icons.block, size: 18),
        ),
      ],
    );
  }
}

/// Black or white check mark, whichever reads on [color] — Google's eleven
/// are fixed RGB values, not the light/dark tint PAIRS `ClubColors` derives
/// per brightness, so legibility is picked by luminance instead.
Color _legibleOn(Color color) =>
    color.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;

/// One swatch, matching `ColorPickerGrid`'s private `_Swatch` look exactly
/// (44dp target, ring + check mark on the selected one). Duplicated rather
/// than shared — that one is private to color_picker.dart, and this
/// picker's list is fixed rather than a palette index — but kept in sync by
/// eye; touch both if the look ever changes.
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

/// One entry of [googleEventColors] for [colorId], or null when it is null
/// or not one of the eleven (an id from a future build this one doesn't
/// know yet, say).
(int, String, Color)? _entryOf(int? colorId) {
  if (colorId == null) return null;
  for (final e in googleEventColors) {
    if (e.$1 == colorId) return e;
  }
  return null;
}

/// Czech label for a Google event colorId, or "Bez barvy" for null/unknown.
String eventColorName(int? colorId) => _entryOf(colorId)?.$2 ?? 'Bez barvy';

/// Opens [EventColorPicker] in a bottom sheet titled [title]; resolves to
/// the tapped colour (null included, for "bez barvy"), or [current]
/// unchanged when the sheet is dismissed without a tap — mirroring
/// `ColorPickerGrid`'s wheel dialog, which likewise only calls back on an
/// explicit confirm/pick.
Future<int?> pickEventColor(
  BuildContext context, {
  required int? current,
  String title = 'Barva',
}) async {
  final picked = await showModalBottomSheet<_ColorPick>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(sheetContext).textTheme.titleMedium),
            const SizedBox(height: 12),
            EventColorPicker(
              selected: current,
              onChanged: (id) => Navigator.pop(sheetContext, _ColorPick(id)),
            ),
          ],
        ),
      ),
    ),
  );
  return picked == null ? current : picked.colorId;
}

/// Wraps the picked colorId (which is itself nullable, for "bez barvy") so
/// [pickEventColor] can tell "the sheet was dismissed" (no [_ColorPick] at
/// all) apart from "bez barvy was tapped" (a [_ColorPick] carrying null).
class _ColorPick {
  const _ColorPick(this.colorId);
  final int? colorId;
}

/// The small round colour indicator: a plain preview when [onTap] is null
/// (the calendar card's "Barva tréninků" row, where the whole `ListTile` is
/// already the tap target), or the tappable "terčík barvy" next to a ticked
/// team in the calendar-teams sheet when [onTap] is given.
class EventColorDot extends StatelessWidget {
  const EventColorDot({
    super.key,
    required this.colorId,
    this.onTap,
    this.size = 32,
  });

  final int? colorId;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entry = _entryOf(colorId);
    final dot = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: entry?.$3 ?? scheme.surfaceContainerHighest,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: entry == null
          ? Icon(Icons.block, size: size * 0.45, color: scheme.onSurfaceVariant)
          : null,
    );
    if (onTap == null) return dot;
    return Tooltip(
      message: entry?.$2 ?? 'Bez barvy',
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: dot,
      ),
    );
  }
}
