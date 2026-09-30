import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/duties.dart';
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

  testWidgets(
    'resetTenantScopedProviders re-creates the league match and player-line '
    'families (0055)',
    (tester) async {
      final builds = <String, int>{};
      Stream<T> counted<T>(String name, T value) {
        builds[name] = (builds[name] ?? 0) + 1;
        return Stream.value(value);
      }

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            leagueMatchesProvider.overrideWith(
              (ref, slug) => counted('league', const <LeagueMatch>[]),
            ),
            leaguePlayerResultsProvider.overrideWith(
              (ref, id) => counted('lines', const <MatchPlayerResult>[]),
            ),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                ref.watch(leagueMatchesProvider('liga-x'));
                ref.watch(leaguePlayerResultsProvider('lg1'));
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
      expect(builds, {'league': 1, 'lines': 1});

      await tester.tap(find.text('Přepnout kuželnu'));
      await tester.pump();

      expect(builds, {'league': 2, 'lines': 2});
    },
  );

  testWidgets(
    'resetTenantScopedProviders re-creates the duty streams, the seasons and '
    'my duty (0050)',
    (tester) async {
      final builds = <String, int>{};
      void count(String name) => builds[name] = (builds[name] ?? 0) + 1;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dutyPeriodsProvider.overrideWith((ref) {
              count('periods');
              return Stream.value(const <DutyPeriod>[]);
            }),
            dutyAssignmentsProvider.overrideWith((ref) {
              count('assignments');
              return Stream.value(const <DutyAssignment>[]);
            }),
            dutySeasonsProvider.overrideWith((ref) async {
              count('seasons');
              return const <DutySeason>[];
            }),
            myDutyProvider.overrideWith((ref) {
              count('myDuty');
              return MyDuty.none;
            }),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                ref.watch(dutyPeriodsProvider);
                ref.watch(dutyAssignmentsProvider);
                ref.watch(dutySeasonsProvider);
                ref.watch(myDutyProvider);
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
      expect(builds,
          {'periods': 1, 'assignments': 1, 'seasons': 1, 'myDuty': 1});

      await tester.tap(find.text('Přepnout kuželnu'));
      await tester.pump();

      expect(builds,
          {'periods': 2, 'assignments': 2, 'seasons': 2, 'myDuty': 2});
    },
  );

  testWidgets(
    'resetTenantScopedProviders re-creates the messages streams (0051)',
    (tester) async {
      final builds = <String, int>{};
      void count(String name) => builds[name] = (builds[name] ?? 0) + 1;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            messagesProvider.overrideWith((ref) {
              count('messages');
              return Stream.value(const <Message>[]);
            }),
            myMessageRecipientsProvider.overrideWith((ref) {
              count('recipients');
              return Stream.value(const <MessageRecipient>[]);
            }),
            messageParticipantsProvider('m1').overrideWith((ref) {
              count('participants');
              return Stream.value(const <MessageRecipient>[]);
            }),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                ref.watch(messagesProvider);
                ref.watch(myMessageRecipientsProvider);
                ref.watch(messageParticipantsProvider('m1'));
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
      expect(builds, {'messages': 1, 'recipients': 1, 'participants': 1});

      await tester.tap(find.text('Přepnout kuželnu'));
      await tester.pump();

      expect(builds, {'messages': 2, 'recipients': 2, 'participants': 2});
    },
  );

  testWidgets('resetTenantScopedProviders re-fetches the Kontakty list (0048)',
      (tester) async {
    var fetches = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          contactsProvider.overrideWith((ref) async {
            fetches++;
            return const <Contact>[];
          }),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              ref.watch(contactsProvider);
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
    expect(fetches, 1);

    await tester.tap(find.text('Přepnout kuželnu'));
    await tester.pump();

    expect(fetches, 2);
  });
}
