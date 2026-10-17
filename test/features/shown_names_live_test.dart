import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/schedule.dart';
import 'package:rezervator/features/schedule/widgets/gap_rows.dart';

/// A name drawn with the clubs' nicknames follows them: one that arrives
/// later — the other clubs' (0083) on a first start, or one the admin just
/// set — redraws it, not only the next rebuild for some other reason.
void main() {
  testWidgets('the calendar\'s match banner takes an opponent\'s nickname '
      'that arrives after it was drawn', (tester) async {
    final nicknames = StreamController<List<ClubNickname>>();
    // Not awaited: a provider gone with the tree never takes the done event.
    addTearDown(() => unawaited(nicknames.close()));
    final match = PrioritySlot(
      id: 'm',
      date: Day(2026, 10, 17),
      startsAt: const HourMinute(10, 0),
      endsAt: const HourMinute(13, 0),
      type: PrioritySlot.fallbackMatchType,
      homeTeam: 'Termínátor B',
      awayTeam: 'Viktoria Zlín',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          clubsProvider.overrideWith((ref) => Stream.value(const [])),
          clubNicknamesProvider.overrideWith((ref) => nicknames.stream),
        ],
        child: MaterialApp(
          home: Scaffold(body: GapEventBanner(event: OffBlockPriority(match))),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Termínátor B – Viktoria Zlín'), findsOneWidget);

    nicknames.add(const [
      ClubNickname(id: 'n', name: 'Viktoria Zlín', nickname: 'Zlín'),
    ]);
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Termínátor B – Zlín'), findsOneWidget);
  });
}
