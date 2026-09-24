import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';

/// A superadmin's kuželna switch: every tenant-scoped stream must be
/// re-created, or the new alley shows the old one's rows until a restart.
void main() {
  testWidgets(
    'resetTenantScopedProviders re-creates the teams, ČKA sync, results and '
    'venues streams',
    (tester) async {
      final builds = <String, int>{};
      Stream<T> counted<T>(String name, T value) {
        builds[name] = (builds[name] ?? 0) + 1;
        return Stream.value(value);
      }

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            clubsProvider.overrideWith(
              (ref) => counted('clubs', const <Club>[]),
            ),
            teamsProvider.overrideWith(
              (ref) => counted('teams', const <Team>[]),
            ),
            federationSyncProvider.overrideWith(
              (ref) => counted('federationSync', FederationSync.none),
            ),
            matchResultsProvider.overrideWith(
              (ref) => counted('matchResults', const <String, MatchResult>{}),
            ),
            venuesProvider.overrideWith(
              (ref) => counted('venues', const <Venue>[]),
            ),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                ref.watch(clubsProvider);
                ref.watch(teamsProvider);
                ref.watch(federationSyncProvider);
                ref.watch(matchResultsProvider);
                ref.watch(venuesProvider);
                return TextButton(
                  onPressed: () => resetTenantScopedProviders(ref),
                  child: const Text('Přepnout kuželnu'),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();
      expect(builds, {
        'clubs': 1,
        'teams': 1,
        'federationSync': 1,
        'matchResults': 1,
        'venues': 1,
      });

      await tester.tap(find.text('Přepnout kuželnu'));
      await tester.pump();

      expect(builds, {
        'clubs': 2,
        'teams': 2,
        'federationSync': 2,
        'matchResults': 2,
        'venues': 2,
      });
    },
  );
}
