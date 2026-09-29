/// Klubovna → Nástěnka's admin "Kdo si to zobrazil" (0051): a read count
/// plus the Czech-sorted names of everyone who has not opened it yet.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart' show friendlyDbError;
import '../../../data/providers.dart';
import '../../../domain/collation.dart';
import '../../../domain/messages.dart';
import '../../../domain/models.dart';

/// Opens the seen sheet of [notice].
Future<void> showNoticeSeenSheet(
  BuildContext context, {
  required Message notice,
}) =>
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => _SeenSheet(notice: notice),
    );

class _SeenSheet extends ConsumerWidget {
  const _SeenSheet({required this.notice});

  final Message notice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The notice's recipient rows (one per player it went to) — the admin
    // may read them all; see messageParticipantsProvider. Until they are
    // in, a spinner (or why they are not): „Zobrazilo 0 z 0“ would say the
    // notice reached nobody.
    final value = ref.watch(messageParticipantsProvider(notice.id));
    final loaded = value.value;
    if (loaded == null) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            heightFactor: 1,
            child: value.hasError
                ? Text(friendlyDbError(value.error!), textAlign: TextAlign.center)
                : const CircularProgressIndicator(),
          ),
        ),
      );
    }
    final rows = loaded;
    final players = ref.watch(playersProvider).value ?? const [];
    final names = {for (final p in players) p.id: p.displayName};
    final seen = rows.where((r) => r.readAt != null).length;
    // Known names only; an id the roster lacks is left out.
    final unseen = [
      for (final r in rows)
        if (r.readAt == null) ?names[r.userId],
    ]..sort(compareCzech);
    // Scrolls: „12 z 40“ leaves 28 names, and at a large text size or in
    // landscape they are taller than the sheet (at most 9/16 of the
    // screen, which keeps the scrim above it to tap away).
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              seenLabel(seen, rows.length),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (unseen.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('Ještě nezobrazili:'),
              const SizedBox(height: 4),
              Text(unseen.join(', ')),
            ],
          ],
        ),
      ),
    );
  }
}
