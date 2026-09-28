/// The deep-link target for a push tap or an e-mail „Odpovědět v aplikaci“
/// link (0051): one expanded [LiveMessageTile], marked read on open. A
/// spinner until the data has loaded; a missing id counts as gone only
/// once the server says so — see [_MessageDetailScreenState._checkGone].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import 'messages_screen.dart';

class MessageDetailScreen extends ConsumerStatefulWidget {
  const MessageDetailScreen(
    this.id, {
    super.key,
    this.markRead = Api.markMessagesRead,
    this.react = Api.setReaction,
    this.reply = Api.setReply,
    this.messageExists = Api.messageExists,
  });

  /// The `messages.id` the link carried.
  final String id;

  /// The own-row writes, injected like [MessagesScreen]'s.
  final Future<void> Function(List<String> ids) markRead;
  final MessageReact react;
  final MessageReply reply;

  /// Asks the server whether [id] still exists (RLS-scoped); throws when
  /// offline. Asked only when a loaded snapshot lacks the id.
  final Future<bool> Function(String id) messageExists;

  @override
  ConsumerState<MessageDetailScreen> createState() =>
      _MessageDetailScreenState();
}

class _MessageDetailScreenState extends ConsumerState<MessageDetailScreen> {
  /// The snapshot the server was last asked about. A loaded snapshot
  /// without the id proves nothing by itself: cachedRows replays the cache
  /// first, the message a push was sent for is usually newer than it, and
  /// the live snapshot may take long (a cold start on a poor network) or
  /// never come (offline — cachedRows swallows the live error once the
  /// cache is out). So each such snapshot asks the server once.
  List<Message>? _askedAbout;

  /// A question is out; snapshots arriving meanwhile wait for its answer.
  bool _asking = false;

  /// The server could not be asked (offline): the error body with „Zkusit
  /// znovu“ instead of claiming the message is gone.
  Object? _checkError;

  /// Reported gone (or deleted here) — the pop happens once: build() runs
  /// again while the route animates away, and a second pop would eat the
  /// caller's route.
  bool _gone = false;

  /// Asked [MessageDetailScreen.markRead] already — once per visit.
  bool _markRequested = false;

  @override
  Widget build(BuildContext context) {
    Widget scaffold(Widget body) => Scaffold(
          appBar: AppBar(title: const Text('Zpráva')),
          body: body,
        );
    if (_gone) return scaffold(const SizedBox.shrink());

    final id = widget.id;
    final messages = ref.watch(messagesProvider);
    final mine = ref.watch(myMessageRecipientsProvider);
    final players = ref.watch(playersProvider);
    final blocks = ref.watch(timeBlocksProvider);
    final meId = ref.watch(myProfileProvider.select((p) => p.value?.id));

    for (final v in <AsyncValue<Object?>>[messages, mine, players, blocks]) {
      if (v.hasError && !v.hasValue) {
        return scaffold(_error(v.error!, _retryStreams));
      }
    }
    if (!messages.hasValue ||
        !mine.hasValue ||
        !players.hasValue ||
        !blocks.hasValue) {
      return scaffold(const Center(child: CircularProgressIndicator()));
    }
    final m = messages.value!.where((m) => m.id == id).firstOrNull;
    if (m == null) {
      final snapshot = messages.value!;
      final checkError = _checkError;
      if (checkError != null && identical(snapshot, _askedAbout)) {
        return scaffold(_error(checkError, _retryCheck));
      }
      _checkGone(snapshot);
      return scaffold(const Center(child: CircularProgressIndicator()));
    }
    _checkError = null; // the stream caught up after all
    final myRow = mine.value!.where((r) => r.messageId == id).firstOrNull;
    _markRead(myRow);
    return scaffold(
      ListView(
        children: [
          LiveMessageTile(
            message: m,
            myRow: myRow,
            names: {for (final p in players.value!) p.id: p.displayName},
            block: m.blockId == null
                ? null
                : blocks.value!.where((b) => b.id == m.blockId).firstOrNull,
            meId: meId,
            react: widget.react,
            reply: widget.reply,
            onDeleted: _leave,
            // A „Reakce na tvou zprávu“ push lands on my own message: the
            // reply that sent it shows without a tap on the tally.
            expanded: true,
          ),
        ],
      ),
    );
  }

  /// Marks the shown message read when I received it and my row is still
  /// unread: every push tap and e-mail link lands here, not on the list,
  /// so the Zprávy badge and the Klubovna dot would otherwise stay up. Once
  /// per visit, after the frame (it writes to a stream this build
  /// watches); bookkeeping, so no snack, and a failure waits for the next
  /// open — as `MessagesScreen._markReceivedRead`. No row: I sent it.
  void _markRead(MessageRecipient? myRow) {
    if (_markRequested || myRow == null || myRow.readAt != null) return;
    _markRequested = true;
    final markRead = widget.markRead;
    final ids = [widget.id];
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => markRead(ids).catchError((_) {}),
    );
  }

  /// [snapshot] has loaded without the id: asks the server, once per
  /// snapshot and one question at a time. Gone → [_reportGone]. Still
  /// there → keep spinning until the stream catches up; the rebuild asks
  /// again only about a newer snapshot that still lacks it (deleted in
  /// between). Unreachable → [_checkError], until a newer snapshot or
  /// „Zkusit znovu“ asks again.
  void _checkGone(List<Message> snapshot) {
    if (_asking || identical(snapshot, _askedAbout)) return;
    _askedAbout = snapshot;
    _asking = true;
    _checkError = null;
    widget.messageExists(widget.id).then((exists) {
      _asking = false;
      if (!mounted || _gone) return;
      if (exists) {
        setState(() {}); // a snapshot that came in meanwhile gets its turn
      } else {
        _reportGone();
      }
    }, onError: (Object e) {
      _asking = false;
      if (!mounted || _gone) return;
      setState(() => _checkError = e);
    });
  }

  void _retryCheck() => setState(() {
        _checkError = null;
        _askedAbout = null;
      });

  void _retryStreams() {
    ref.invalidate(messagesProvider);
    ref.invalidate(myMessageRecipientsProvider);
    ref.invalidate(playersProvider);
    ref.invalidate(timeBlocksProvider);
  }

  /// The server has no such message (deleted, pruned, never mine): snack
  /// on the root messenger (it outlives this route), then back to
  /// wherever the link opened from.
  void _reportGone() {
    if (!mounted || _gone) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Zpráva už neexistuje.')),
    );
    _leave();
  }

  /// Leaves the screen once — after [_reportGone], or after the message
  /// was deleted here (its own „Zpráva smazána.“ snack already shows).
  ///
  /// Removes THIS route, not whatever is on top (see `closeDialog`): a
  /// menu or dialog still open above it is this screen's own (⋮, „Smazat
  /// zprávu?“) and goes with it; a page above it is not — a second push
  /// tap's detail — so this route is taken out from under that page.
  void _leave() {
    if (!mounted || _gone) return;
    setState(() => _gone = true);
    final route = ModalRoute.of(context);
    final nav = route?.navigator;
    if (route == null || nav == null || !route.isActive) return;
    nav.popUntil((r) => r == route || r is! PopupRoute);
    if (!route.isCurrent) {
      nav.removeRoute(route);
    } else if (!route.isFirst) {
      nav.pop();
    }
  }

  Widget _error(Object error, VoidCallback onRetry) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(friendlyDbError(error), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: onRetry,
                child: const Text('Zkusit znovu'),
              ),
            ],
          ),
        ),
      );
}
