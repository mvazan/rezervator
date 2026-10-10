/// One match's score sheet full screen, read live from the same streams as
/// the match detail: the kiosk's „Zápis“ (a modal, `showKioskZapis`) and the
/// app's landscape Zápis (Můj profil → Detail zápasu → Na šířku: Zápis — the
/// match detail opens it on a turn of the phone). Display only — no ⟳
/// refresh (the server's poll keeps live matches fresh), no video, no link
/// out.
///
/// A match whose players are not on the site yet has no sheet to draw — the
/// sheet would be a grid of dashes — so it says so and shows the score it
/// has.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers.dart';
import '../../../domain/models.dart';
import '../../../domain/results.dart';
import 'legacy_score_sheet.dart';

class ZapisPage extends ConsumerWidget {
  const ZapisPage({
    super.key,
    required this.slot,
    this.closeButton = false,
    this.competitionSlug,
    this.withRegnums = false,
    this.backButton = false,
  });

  final PrioritySlot slot;

  /// The × — the kiosk only when its modal covers the whole screen.
  final bool closeButton;

  /// Set for a foreign match (0055): its result and players are read from
  /// the competition's league matches, not from the alley's own.
  final String? competitionSlug;

  /// Look up the players' registration numbers for the sheet (regnum-lookup:
  /// any signed-in account that can open the match, the kiosk's too). Off
  /// where nothing is signed in to ask with.
  final bool withRegnums;

  /// The corner button is ← „Zpět“ instead of × „Zavřít“: the app's
  /// sideways Zápis stands in for the match detail, so it goes back to
  /// where the match was opened from. Either one pops the route.
  final bool backButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slug = competitionSlug;
    final MatchResult? result;
    final AsyncValue<List<MatchPlayerResult>> lineup;
    if (slug == null) {
      result = ref.watch(
        matchResultsProvider.select((r) => r.value?[slot.id]),
      );
      lineup = ref.watch(matchPlayerResultsProvider(slot.id));
    } else {
      result = ref.watch(
        leagueMatchesProvider(slug).select(
          (l) => l.value?.where((m) => m.id == slot.id).firstOrNull?.result,
        ),
      );
      lineup = ref.watch(leaguePlayerResultsProvider(slot.id));
    }
    if (!lineup.hasValue && !lineup.hasError) {
      return const Center(child: CircularProgressIndicator());
    }
    var players = lineup.value ?? const <MatchPlayerResult>[];
    if (players.isEmpty) {
      return _NoSheet(
        slot: slot,
        result: result,
        closeButton: closeButton || backButton,
        backButton: backButton,
      );
    }
    if (withRegnums) {
      final regnums =
          ref
              .watch(
                matchRegnumsProvider((
                  matchId: slot.id,
                  league: slug != null,
                  lineup: players.length,
                )),
              )
              .value ??
          const <String, String>{};
      players = [for (final p in players) p.withRegnum(regnums[p.playerSlug])];
    }
    return LegacyScoreSheetPage(
      slot: slot,
      result: result,
      players: players,
      showCloseButton: closeButton || backButton,
      backButton: backButton,
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
    required this.backButton,
  });

  final PrioritySlot slot;
  final MatchResult? result;
  final bool closeButton;
  final bool backButton;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final score = hasScoreData(result)
        ? pointsLabel(result!.homePoints, result!.awayPoints)
        : null;
    return Scaffold(
      body: Stack(
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
              child: SafeArea(
                child: IconButton.filledTonal(
                  icon: Icon(backButton ? Icons.arrow_back : Icons.close),
                  tooltip: backButton ? 'Zpět' : 'Zavřít',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
