/// The kiosk's „Zápis“: one match's score sheet, read live from the same
/// streams as the app's match detail, shown in a modal (see
/// [showKioskZapis]). Display only — no ⟳ refresh (the server's poll keeps
/// live matches fresh), no video, no link out of the kiosk. A tap anywhere
/// counts as touching the kiosk (the shell's idle timer is outside this
/// route), and the idle reset closes it.
///
/// A match whose players are not on the site yet has no sheet to draw —
/// the sheet would be a grid of dashes — so it says so and shows the score
/// it has.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/results.dart';
import '../clubhouse/widgets/legacy_score_sheet.dart';

/// Opens [slot]'s Zápis in a modal covering [percent] of the screen, fading
/// in (no slide); a tap outside closes it. At 100 % there is no outside, so
/// a close button appears. [onTouch] is the shell's „somebody touched the
/// kiosk“.
Future<void> showKioskZapis(
  BuildContext context, {
  required PrioritySlot slot,
  required Brightness brightness,
  required int percent,
  required VoidCallback onTouch,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Zavřít',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 250),
    transitionBuilder: (context, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    ),
    pageBuilder: (context, _, _) {
      final size = MediaQuery.sizeOf(context);
      final full = percent >= 100;
      return Listener(
        onPointerDown: (_) => onTouch(),
        behavior: HitTestBehavior.translucent,
        child: Theme(
          data: buildTheme(brightness),
          child: Center(
            child: SizedBox(
              width: size.width * percent / 100,
              height: size.height * percent / 100,
              child: Material(
                clipBehavior: Clip.antiAlias,
                borderRadius: BorderRadius.circular(full ? 0 : 16),
                elevation: 8,
                child: KioskZapisPage(slot: slot, closeButton: full),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class KioskZapisPage extends ConsumerWidget {
  const KioskZapisPage({
    super.key,
    required this.slot,
    this.closeButton = false,
  });

  final PrioritySlot slot;

  /// The × — only when the modal covers the whole screen.
  final bool closeButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(
      matchResultsProvider.select((r) => r.value?[slot.id]),
    );
    final lineup = ref.watch(matchPlayerResultsProvider(slot.id));
    if (!lineup.hasValue && !lineup.hasError) {
      return const Center(child: CircularProgressIndicator());
    }
    final players = lineup.value ?? const <MatchPlayerResult>[];
    if (players.isEmpty) {
      return _NoSheet(slot: slot, result: result, closeButton: closeButton);
    }
    return LegacyScoreSheetPage(
      slot: slot,
      result: result,
      players: players,
      showCloseButton: closeButton,
    );
  }
}

/// What a match without players shows instead of a sheet: its teams, the
/// score the site has, and why there is no more.
class _NoSheet extends StatelessWidget {
  const _NoSheet({
    required this.slot,
    required this.result,
    required this.closeButton,
  });

  final PrioritySlot slot;
  final MatchResult? result;
  final bool closeButton;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final score = hasScoreData(result)
        ? pointsLabel(result!.homePoints, result!.awayPoints)
        : null;
    return Stack(
      children: [
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  slot.title,
                  textAlign: TextAlign.center,
                  style: text.headlineSmall,
                ),
                if (score != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    score,
                    style: text.displayMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: scheme.primary,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                Text(
                  'Zápis zápasu zatím není k dispozici.',
                  style: text.titleMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Jména hráčů a jejich hody se objeví, až je zveřejní na '
                  'webu svazu.',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (closeButton)
          Positioned(
            top: 8,
            left: 8,
            child: IconButton.filledTonal(
              icon: const Icon(Icons.close),
              tooltip: 'Zavřít',
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
      ],
    );
  }
}
