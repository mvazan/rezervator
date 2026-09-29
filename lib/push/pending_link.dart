/// What a push tap (or an e-mail deep link, or a foreground local
/// notification) should open once the app is signed in and ready (0051):
/// a message, a notice, or — for an admin — the registrations waiting for
/// approval (a new player, a new kuželna for the superadmin). `Push.init()` runs before any `ProviderScope`
/// exists, so it cannot write into a Riverpod provider directly — it
/// publishes onto [PendingLinkSource], a plain broadcast stream, which
/// [PendingLinkNotifier] subscribes to from inside the widget tree.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which screen a [PendingLink] opens.
enum PendingLinkKind { message, notice, pendingPlayer, pendingTenant }

/// One deep link waiting to be opened: the kind and the `messages.id`,
/// and — from a push — the alley it was sent for.
class PendingLink {
  const PendingLink({required this.kind, this.id = '', this.tenantId});

  final PendingLinkKind kind;

  /// The `messages.id` the push or the e-mail link carried; empty for the
  /// approval links, which point at a list, not at one row.
  final String id;

  /// The push's `tenant_id`: the alley whose member it was sent to. Null
  /// for an e-mail link (`/zpravy/:id` carries no alley) — then any alley
  /// may open it, and RLS decides what shows.
  final String? tenantId;

  @override
  bool operator ==(Object other) =>
      other is PendingLink &&
      other.kind == kind &&
      other.id == id &&
      other.tenantId == tenantId;

  @override
  int get hashCode => Object.hash(kind, id, tenantId);

  @override
  String toString() => 'PendingLink($kind, $id, $tenantId)';
}

/// A push `data` payload -> what to open, or null for a push this app
/// doesn't deep-link (duty/booking/reservation pushes stay OS-open-only).
/// A malformed payload (a non-string id) opens nothing rather than
/// throwing inside the push handler.
PendingLink? pendingLinkFromData(Map<String, dynamic> data) {
  final tenant = data['tenant_id'];
  final tenantId = tenant is String ? tenant : null;
  // The approval pushes carry no message: they open a list.
  switch (data['kind']) {
    case 'pending_player':
      return PendingLink(kind: PendingLinkKind.pendingPlayer, tenantId: tenantId);
    case 'pending_tenant':
      return const PendingLink(kind: PendingLinkKind.pendingTenant);
  }
  final id = data['message_id'];
  if (id is! String) return null;
  return switch (data['kind']) {
    'message' || 'message_reaction' => PendingLink(
        kind: PendingLinkKind.message, id: id, tenantId: tenantId),
    'notice' =>
      PendingLink(kind: PendingLinkKind.notice, id: id, tenantId: tenantId),
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

/// Seeds [pendingLinkProvider] from a /zpravy/:id, /nastenka/:id,
/// /sprava/hraci or /sprava/kuzelny route,
/// then renders [child] (the ordinary `AuthGate`) — HomeShell picks the
/// link up once signed in (0051). A plain visit to `/zpravy` or
/// `/nastenka` (no id) skips this and goes straight to `AuthGate`.
class DeepLinkSeed extends ConsumerStatefulWidget {
  const DeepLinkSeed({super.key, required this.link, required this.child});

  final PendingLink link;
  final Widget child;

  @override
  ConsumerState<DeepLinkSeed> createState() => _DeepLinkSeedState();
}

class _DeepLinkSeedState extends ConsumerState<DeepLinkSeed> {
  @override
  void initState() {
    super.initState();
    _seed();
  }

  // go_router keys a GoRoute's page by its pattern (/zpravy/:id), so a
  // move from /zpravy/A to /zpravy/B in the same tab (a second e-mail
  // link, browser back/forward) keeps this State: initState does not run
  // again. An equal link (a query-only change of the same location, which
  // rebuilds the page) must not reopen a link HomeShell already cleared.
  @override
  void didUpdateWidget(DeepLinkSeed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.link != oldWidget.link) _seed();
  }

  /// Sets [DeepLinkSeed.link] once the frame is done: Riverpod allows no
  /// provider write in initState.
  void _seed() {
    final link = widget.link;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(pendingLinkProvider.notifier).set(link);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

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

  /// Forgets the cold-start link — on sign-out, so a tap meant for the
  /// account that left never opens for the next one.
  static void clearInitial() => _initial = null;
}
