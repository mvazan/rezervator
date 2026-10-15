/// Small form pieces the admin dialogs repeat: a label/value tile that opens
/// a picker, the lane chips, a rental's note, and the colour dot lists show
/// beside a name.
library;

import 'package:flutter/material.dart';

import '../../../domain/palette.dart';

/// A rental's note, on several lines: the calendar shows it under the
/// renter and the time line by line — which lanes play which match, say —
/// so Enter starts a new line rather than saving.
class RentalNoteField extends StatelessWidget {
  const RentalNoteField({super.key, required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    minLines: 2,
    maxLines: 6,
    keyboardType: TextInputType.multiline,
    textInputAction: TextInputAction.newline,
    decoration: const InputDecoration(
      labelText: 'Poznámka',
      helperText: 'V kalendáři pod časem, řádek po řádku.',
      alignLabelWithHint: true,
    ),
  );
}

/// "Datum · čt 23. 4." style tile: [label] left, [value] right, tap opens
/// the picker.
class PickerTile extends StatelessWidget {
  const PickerTile({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      trailing: Text(value),
      onTap: onTap,
    );
  }
}

/// One FilterChip per lane; [onChanged] gets the new selection.
class LaneChips extends StatelessWidget {
  const LaneChips({
    super.key,
    required this.laneCount,
    required this.selected,
    required this.onChanged,
  });

  final int laneCount;
  final Set<int> selected;
  final ValueChanged<Set<int>> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      children: [
        for (var lane = 1; lane <= laneCount; lane++)
          FilterChip(
            label: Text('Dráha $lane'),
            selected: selected.contains(lane),
            onSelected: (on) {
              final next = {...selected};
              if (on) {
                next.add(lane);
              } else {
                next.remove(lane);
              }
              onChanged(next);
            },
          ),
      ],
    );
  }
}

/// 24 px circle in the palette colour of [colorIndex] (the dark variant —
/// the more saturated, legible one for a small dot); [fallback] for "no
/// colour" (defaults to the neutral surface tint).
class ColorDot extends StatelessWidget {
  const ColorDot({super.key, required this.colorIndex, this.fallback});

  final int colorIndex;
  final Color? fallback;

  @override
  Widget build(BuildContext context) {
    final color = ClubColors.of(colorIndex, Brightness.dark)?.$1 ??
        fallback ??
        Theme.of(context).colorScheme.surfaceContainerHighest;
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
