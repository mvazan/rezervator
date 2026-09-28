/// The deep-link target for a push tap or an e-mail „Odpovědět v aplikaci“
/// link (0051): one expanded [LiveMessageTile]. A spinner until the data
/// has loaded; a missing id counts as gone only once it has stayed missing
/// for [_goneAfter] — see [_MessageDetailScreenState._goneTimer].
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import 'messages_screen.dart';

/// How long an id may stay absent from the loaded messages before the
/// screen reports it gone.
const _goneAfter = Duration(seconds: 5);

class MessageDetailScreen extends ConsumerStatefulWidget {
  const MessageDetailScreen(
    this.id, {
    super.key,
    this.react = Api.setReaction,
    this.reply = Api.setReply,
  });

  /// The `messages.id` the link carried.
  final String id;

  /// The own-row writes, injected like [MessagesScreen]'s.
  final MessageReact react;
  final MessageReply reply;

  @override
  ConsumerState<MessageDetailScreen> createState() =>
      _MessageDetailScreenState();
}

class _MessageDetailScreenState extends ConsumerState<MessageDetailScreen> {
  /// Runs while the id is missing from a loaded snapshot; cancelled when it
  /// shows up. Not the first snapshot alone: cachedRows replays the cache
  /// first, and the message a push was sent for is usually newer than it —
  /// it arrives a moment later with the live snapshot.
  Timer? _goneTimer;

  /// Reported gone (or deleted here) — the pop happens once: build() runs
  /// again while the route animates away, and a second pop would eat the
  /// caller's route.
  bool _gone = false;

  @override
  void dispose() {
    _goneTimer?.cancel();
    super.dispose();
  }

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
        return scaffold(_error(v.error!));
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
      _goneTimer ??= Timer(_goneAfter, _reportGone);
      return scaffold(const Center(child: CircularProgressIndicator()));
    }
    _goneTimer?.cancel();
    _goneTimer = null;
    return scaffold(
      ListView(
        children: [
          LiveMessageTile(
            message: m,
            myRow: mine.value!.where((r) => r.messageId == id).firstOrNull,
            names: {for (final p in players.value!) p.id: p.displayName},
            block: m.blockId == null
                ? null
                : blocks.value!.where((b) => b.id == m.blockId).firstOrNull,
            meId: meId,
            react: widget.react,
            reply: widget.reply,
            onDeleted: _leave,
          ),
        ],
      ),
    );
  }

  /// The id stayed missing: snack on the root messenger (it outlives this
  /// route), then back to wherever the link opened from.
  void _reportGone() {
    if (!mounted || _gone) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Zpráva už neexistuje.')),
    );
    _leave();
  }

  /// Leaves the screen once — after [_reportGone], or after the message
  /// was deleted here (its own „Zpráva smazána.“ snack already shows).
  void _leave() {
    if (!mounted) return;
    _goneTimer?.cancel();
    setState(() => _gone = true);
    Navigator.of(context).maybePop();
  }

  Widget _error(Object error) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(friendlyDbError(error), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () {
                  ref.invalidate(messagesProvider);
                  ref.invalidate(myMessageRecipientsProvider);
                  ref.invalidate(playersProvider);
                  ref.invalidate(timeBlocksProvider);
                },
                child: const Text('Zkusit znovu'),
              ),
            ],
          ),
        ),
      );
}
