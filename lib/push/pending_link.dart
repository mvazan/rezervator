/// What a push tap (or an e-mail deep link, or a foreground local
/// notification) should open once the app is signed in and ready (0051):
/// a message, or a notice. `Push.init()` runs before any `ProviderScope`
/// exists, so it cannot write into a Riverpod provider directly — it
/// publishes onto [PendingLinkSource], a plain broadcast stream, which
/// [PendingLinkNotifier] subscribes to from inside the widget tree.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which screen a [PendingLink] opens.
enum PendingLinkKind { message, notice }

/// One deep link waiting to be opened: the kind and the `messages.id`.
class PendingLink {
  const PendingLink({required this.kind, required this.id});

  final PendingLinkKind kind;

  /// The `messages.id` the push or the e-mail link carried.
  final String id;

  @override
  bool operator ==(Object other) =>
      other is PendingLink && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'PendingLink($kind, $id)';
}

/// A push `data` payload -> what to open, or null for a push this app
/// doesn't deep-link (duty/booking/reservation pushes stay OS-open-only).
PendingLink? pendingLinkFromData(Map<String, dynamic> data) {
  final id = data['message_id'] as String?;
  if (id == null) return null;
  return switch (data['kind']) {
    'message' ||
    'message_reaction' =>
      PendingLink(kind: PendingLinkKind.message, id: id),
    'notice' => PendingLink(kind: PendingLinkKind.notice, id: id),
    _ => null,
  };
}

/// The link waiting to be opened, or null. `HomeShell` consumes it and
/// clears it; [PendingLinkSource] (push taps) and the `/zpravy/:id`,
/// `/nastenka/:id` routes set it.
class PendingLinkNotifier extends Notifier<PendingLink?> {
  /// [initial] lets a test (or an override) start with a link already
  /// pending — the same state a cold start leaves behind.
  PendingLinkNotifier({this.initial});

  final PendingLink? initial;

  StreamSubscription<PendingLink>? _sub;

  @override
  PendingLink? build() {
    _sub = PendingLinkSource.links.listen((link) => state = link);
    ref.onDispose(() => _sub?.cancel());
    return initial ?? PendingLinkSource.takeInitial();
  }

  /// Makes [link] the pending one (replacing any earlier, unopened one).
  void set(PendingLink link) => state = link;

  /// Nothing pending — called once the link has been opened.
  void clear() => state = null;
}

/// See [PendingLinkNotifier].
final pendingLinkProvider =
    NotifierProvider<PendingLinkNotifier, PendingLink?>(
        () => PendingLinkNotifier());

/// The plain (non-Riverpod) sink `Push` publishes onto — a broadcast
/// stream plus a one-slot "initial" value for a cold start, since the
/// very first push tap (an OS-delivered `getInitialMessage()`) can arrive
/// before [PendingLinkNotifier] has ever been built.
class PendingLinkSource {
  PendingLinkSource._();

  static final _controller = StreamController<PendingLink>.broadcast();
  static PendingLink? _initial;

  /// Every link published while a [PendingLinkNotifier] listens.
  static Stream<PendingLink> get links => _controller.stream;

  /// Hands [link] to the running [PendingLinkNotifier], or — none built
  /// yet — keeps it for [takeInitial].
  static void publish(PendingLink link) {
    if (!_controller.hasListener) _initial = link;
    _controller.add(link);
  }

  /// Consumes the cold-start link, if any — called once from
  /// [PendingLinkNotifier.build].
  static PendingLink? takeInitial() {
    final link = _initial;
    _initial = null;
    return link;
  }
}
