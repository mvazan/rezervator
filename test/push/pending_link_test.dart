import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rezervator/push/pending_link.dart';

void main() {
  group('pendingLinkFromData', () {
    test('a message push maps to a message link', () {
      expect(
        pendingLinkFromData(const {'kind': 'message', 'message_id': 'm1'}),
        const PendingLink(kind: PendingLinkKind.message, id: 'm1'),
      );
    });

    test('a notice push maps to a notice link', () {
      expect(
        pendingLinkFromData(const {'kind': 'notice', 'message_id': 'n1'}),
        const PendingLink(kind: PendingLinkKind.notice, id: 'n1'),
      );
    });

    test('a reaction push maps to a message link too (it deep-links to the same message)', () {
      expect(
        pendingLinkFromData(const {'kind': 'message_reaction', 'message_id': 'm1'}),
        const PendingLink(kind: PendingLinkKind.message, id: 'm1'),
      );
    });

    test('a freed-spot push carries the day and the cell', () {
      expect(
        pendingLinkFromData(const {
          'kind': 'freed_spot',
          'date': '2026-10-08',
          'block_id': 'b1',
          'lane': '2',
          'tenant_id': 't1',
        }),
        const PendingLink(
          kind: PendingLinkKind.freedSpot,
          tenantId: 't1',
          date: '2026-10-08',
          blockId: 'b1',
          lane: 2,
        ),
      );
    });

    test('an older freed-spot push opens the day alone; a bad day nothing', () {
      expect(
        pendingLinkFromData(const {'kind': 'freed_spot', 'date': '2026-10-08'}),
        const PendingLink(kind: PendingLinkKind.freedSpot, date: '2026-10-08'),
      );
      // A block without a usable lane is no cell.
      expect(
        pendingLinkFromData(const {
          'kind': 'freed_spot',
          'date': '2026-10-08',
          'block_id': 'b1',
          'lane': 'x',
        }),
        const PendingLink(kind: PendingLinkKind.freedSpot, date: '2026-10-08'),
      );
      expect(pendingLinkFromData(const {'kind': 'freed_spot'}), isNull);
      expect(
        pendingLinkFromData(const {'kind': 'freed_spot', 'date': 'zítra'}),
        isNull,
      );
    });

    test('the approval pushes map to their lists, with no message id', () {
      expect(
        pendingLinkFromData(const {'kind': 'pending_player', 'tenant_id': 't1'}),
        const PendingLink(kind: PendingLinkKind.pendingPlayer, tenantId: 't1'),
      );
      expect(
        pendingLinkFromData(const {'kind': 'pending_tenant'}),
        const PendingLink(kind: PendingLinkKind.pendingTenant),
      );
      // A malformed alley is no alley, never a throw.
      expect(
        pendingLinkFromData(const {'kind': 'pending_player', 'tenant_id': 7}),
        const PendingLink(kind: PendingLinkKind.pendingPlayer),
      );
    });

    test('an unrelated push kind maps to nothing', () {
      expect(pendingLinkFromData(const {'kind': 'duty_reminder'}), isNull);
    });

    test('missing message_id maps to nothing even for a known kind', () {
      expect(pendingLinkFromData(const {'kind': 'message'}), isNull);
    });

    test('the alley the push was sent for rides along', () {
      expect(
        pendingLinkFromData(
            const {'kind': 'message', 'message_id': 'm1', 'tenant_id': 't1'}),
        const PendingLink(kind: PendingLinkKind.message, id: 'm1', tenantId: 't1'),
      );
    });

    test('a malformed payload maps to nothing (or no alley), never throws', () {
      expect(pendingLinkFromData(const {'kind': 'message', 'message_id': 7}), isNull);
      expect(
        pendingLinkFromData(
            const {'kind': 'notice', 'message_id': 'n1', 'tenant_id': 7}),
        const PendingLink(kind: PendingLinkKind.notice, id: 'n1'),
      );
    });
  });

  // Push.init runs before any ProviderScope: a cold-start tap waits in
  // PendingLinkSource's one slot, a warm one goes through its stream.
  group('PendingLinkSource', () {
    const a = PendingLink(kind: PendingLinkKind.message, id: 'a');
    const b = PendingLink(kind: PendingLinkKind.notice, id: 'b');
    tearDown(PendingLinkSource.clearInitial);

    test('a link published before any notifier is taken by the first one, '
        'once', () {
      PendingLinkSource.publish(a);
      final first = ProviderContainer();
      addTearDown(first.dispose);
      expect(first.read(pendingLinkProvider), a);
      final second = ProviderContainer();
      addTearDown(second.dispose);
      expect(second.read(pendingLinkProvider), isNull);
    });

    test('a link published while a notifier listens becomes its state', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final sub = container.listen(pendingLinkProvider, (_, _) {});
      addTearDown(sub.close);
      expect(container.read(pendingLinkProvider), isNull);
      PendingLinkSource.publish(b);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(pendingLinkProvider), b);
      // Delivered, not also kept for a later cold start.
      expect(PendingLinkSource.takeInitial(), isNull);
    });

    test('clearInitial empties the cold-start slot (sign-out)', () {
      PendingLinkSource.publish(a);
      PendingLinkSource.clearInitial();
      expect(PendingLinkSource.takeInitial(), isNull);
    });
  });

  group('PendingLinkNotifier', () {
    test('set then clear round-trips through the provider', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(pendingLinkProvider), isNull);
      container.read(pendingLinkProvider.notifier).set(
          const PendingLink(kind: PendingLinkKind.message, id: 'm1'));
      expect(container.read(pendingLinkProvider),
          const PendingLink(kind: PendingLinkKind.message, id: 'm1'));
      container.read(pendingLinkProvider.notifier).clear();
      expect(container.read(pendingLinkProvider), isNull);
    });
  });

  group('DeepLinkSeed', () {
    // go_router keys a GoRoute's page by its PATTERN (/zpravy/:id), so a
    // move from /zpravy/A to /zpravy/B in the same tab (a second e-mail
    // link, browser back/forward) keeps the same seed State: initState
    // does not run again, so the seed must react in didUpdateWidget.
    Future<(GoRouter, List<PendingLink?>)> pump(WidgetTester tester) async {
      PendingLink seed(GoRouterState s, PendingLinkKind kind) =>
          PendingLink(kind: kind, id: s.pathParameters['id']!);
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, _) => const Text('home')),
          GoRoute(
            path: '/zpravy/:id',
            builder: (_, s) => DeepLinkSeed(
              link: seed(s, PendingLinkKind.message),
              child: Text('seed ${s.pathParameters['id']}'),
            ),
          ),
          GoRoute(
            path: '/nastenka/:id',
            builder: (_, s) => DeepLinkSeed(
              link: seed(s, PendingLinkKind.notice),
              child: Text('seed ${s.pathParameters['id']}'),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final seen = <PendingLink?>[];
      container.listen(pendingLinkProvider, (_, next) => seen.add(next));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ));
      return (router, seen);
    }

    for (final (path, kind) in [
      ('/zpravy', PendingLinkKind.message),
      ('/nastenka', PendingLinkKind.notice),
    ]) {
      testWidgets('$path/A then $path/B seeds both links', (tester) async {
        final (router, seen) = await pump(tester);
        router.go('$path/A');
        await tester.pumpAndSettle();
        expect(find.text('seed A'), findsOneWidget);
        router.go('$path/B');
        await tester.pumpAndSettle();
        expect(find.text('seed B'), findsOneWidget);
        expect(seen, [
          PendingLink(kind: kind, id: 'A'),
          PendingLink(kind: kind, id: 'B'),
        ]);
      });
    }

    testWidgets('a rebuild with the same link does not seed it again',
        (tester) async {
      final (router, seen) = await pump(tester);
      router.go('/zpravy/A');
      await tester.pumpAndSettle();
      // HomeShell opens the link and clears it ...
      final container = ProviderScope.containerOf(
          tester.element(find.text('seed A')));
      container.read(pendingLinkProvider.notifier).clear();
      // ... and a query-only change of the same location (e.g. a tracking
      // parameter) rebuilds the page with an equal, non-identical link:
      // didUpdateWidget runs and must not reopen it. (router.refresh()
      // would not do: an equal match list keeps the cached pages, so the
      // builder never runs and the guard is never reached.)
      router.go('/zpravy/A?utm=mail');
      await tester.pumpAndSettle();
      expect(find.text('seed A'), findsOneWidget);
      expect(seen, [
        const PendingLink(kind: PendingLinkKind.message, id: 'A'),
        null,
      ]);
    });
  });
}
