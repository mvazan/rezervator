/// The kiosk's „Zápis“: one match's score sheet, full screen, read live from
/// the same streams as the app's match detail. Display only — no ⟳ refresh
/// (the server's poll keeps live matches fresh), no video, no link out of
/// the kiosk. A tap anywhere counts as touching the kiosk (the shell's idle
/// timer is outside this route), and the idle reset pops it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../domain/models.dart';
import '../clubhouse/widgets/legacy_score_sheet.dart';

class KioskZapisPage extends ConsumerWidget {
  const KioskZapisPage({super.key, required this.slot});

  final PrioritySlot slot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(
      matchResultsProvider.select((r) => r.value?[slot.id]),
    );
    final lineup = ref.watch(matchPlayerResultsProvider(slot.id));
    if (!lineup.hasValue && !lineup.hasError) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return LegacyScoreSheetPage(
      slot: slot,
      result: result,
      players: lineup.value ?? const [],
    );
  }
}
