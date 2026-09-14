/// The frame every picker sheet in Můj profil wears: a title, the list, and
/// a foot with Zrušit and Uložit that does NOT scroll away.
///
/// It also settles what closing means. These sheets used to save whatever
/// was ticked the moment they closed — tap the scrim, swipe down, press
/// back, it all committed — and people did not trust it: nothing said the
/// choice had landed, so they went looking for a button that was not there.
/// A sheet with a Uložit button answers that, but only if the button is the
/// ONLY way in: a surface offering to save implies that leaving it does
/// not, and that is the convention everywhere else (a Material dialog, the
/// label picker in Gmail, a settings multi-select). So: nothing is saved
/// until Uložit.
///
/// Which puts the weight on the other side — an accidental dismissal must
/// not quietly eat the ticks. The scrim and the back gesture both go
/// through [PopScope], so those ask first once something has been changed.
/// The downward SWIPE cannot: `BottomSheet` pops the route itself, out of
/// reach of any guard inside it. Rather than leave one silent way to lose
/// the edits, these sheets are opened with `enableDrag: false` — the scrim,
/// the back gesture and Zrušit all remain, and all of them say so.
library;

import 'package:flutter/material.dart';

import '../../../core/ui.dart';

class PickerSheetFrame extends StatelessWidget {
  const PickerSheetFrame({
    super.key,
    required this.title,
    required this.hints,
    required this.dirty,
    required this.child,
  });

  final String title;

  /// The lines under the title saying what the ticks do — one Text each,
  /// so a sheet with two of them keeps its spacing.
  final List<String> hints;

  /// Whether anything has been changed since the sheet opened — decides
  /// whether a dismissal is worth a question.
  final bool dirty;

  /// The list of rows. It gets whatever height is left over and scrolls;
  /// the foot below it does not move.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final discard = await confirmDialog(
          context,
          title: 'Zahodit změny?',
          message: 'Výběr zatím není uložený.',
          confirmLabel: 'Zahodit',
          cancelLabel: 'Zpět',
        );
        if (discard && context.mounted) Navigator.of(context).pop(false);
      },
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(title, style: theme.textTheme.titleMedium),
            ),
            for (final (i, line) in hints.indexed)
              Padding(
                padding: EdgeInsets.fromLTRB(
                    16, 0, 16, i == hints.length - 1 ? 8 : 4),
                child: Text(line),
              ),
            Flexible(child: child),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    // Explicit — no second question about it.
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Zrušit'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('Uložit'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
