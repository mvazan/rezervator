import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

    test('an unrelated push kind maps to nothing', () {
      expect(pendingLinkFromData(const {'kind': 'duty_reminder'}), isNull);
    });

    test('missing message_id maps to nothing even for a known kind', () {
      expect(pendingLinkFromData(const {'kind': 'message'}), isNull);
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
}
