/// Klubovna → Zprávy (0051): messages to and from me, chronological by the
/// day they are about, older collapsed. Not a chat — see the design spec.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/messages.dart';
import '../../domain/models.dart';
import 'widgets/message_composers.dart';
import 'widgets/message_tile.dart';

/// [Api.setReaction]'s shape: sets or (null) clears my 👍/👎.
typedef MessageReact = Future<void> Function(
    String messageId, Reaction? reaction);

/// [Api.setReply]'s shape: saves (blank clears) my short reply.
typedef MessageReply = Future<void> Function(String messageId, String text);

class MessagesScreen extends ConsumerStatefulWidget {
  const MessagesScreen({
    super.key,
    this.markRead = Api.markMessagesRead,
    this.react = Api.setReaction,
    this.reply = Api.setReply,
  });

  /// The three own-row writes, injected like
  /// `MyTrainingsScreen.cancelReservation` so widget tests never reach
  /// `Supabase.instance`.
  final Future<void> Function(List<String> ids) markRead;
  final MessageReact react;
  final MessageReply reply;

  @override
  ConsumerState<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends ConsumerState<MessagesScreen> {
  /// The messages this visit has already asked to mark read — checked on
  /// every complete snapshot (the cache replays first, and a message can
  /// arrive while the screen is open), each id sent once per visit; see
  /// `NoticeBoardScreen`.
  final _requested = <String>{};

  @override
  Widget build(BuildContext context) {
    final value = _watchData(ref);
    Widget body;
    if (value.hasError) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(friendlyDbError(value.error!), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _refresh,
                child: const Text('Zkusit znovu'),
              ),
            ],
          ),
        ),
      );
    } else if (!value.hasValue) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      final data = value.value!;
      _markReceivedRead(data);
      body = data.messages.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Zatím žádné zprávy.', textAlign: TextAlign.center),
              ),
            )
          : _MessageList(data: data, react: widget.react, reply: widget.reply);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Zprávy')),
      body: body,
      // Its own Consumer: a change of role or duty rebuilds the buttons,
      // not the list.
      floatingActionButton: Consumer(builder: (context, ref, _) {
        final isAdmin = ref.watch(
            myProfileProvider.select((p) => p.value?.isAdmin ?? false));
        final onDuty = ref.watch(myDutyProvider.select((d) => d.onDuty));
        // Side by side when they fit, else stacked (large text, WCAG
        // 1.4.4). The slot is as wide as the Scaffold and endFloat keeps a
        // margin on the right, so the Wrap stops a margin short of the
        // left edge too.
        return LayoutBuilder(builder: (context, constraints) {
          final maxWidth = constraints.maxWidth -
              2 * kFloatingActionButtonMargin -
              MediaQuery.paddingOf(context).horizontal;
          return ConstrainedBox(
            constraints: BoxConstraints(maxWidth: math.max(0, maxWidth)),
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 12,
              children: [
                // The staff composer: the admin, or the duty today — the
                // server's `message_send` gate for a day or a block.
                if (isAdmin || onDuty)
                  FloatingActionButton.extended(
                    heroTag: 'staff-compose',
                    onPressed: () => showStaffComposer(context, ref),
                    icon: const Icon(Icons.campaign_outlined),
                    label: const Text('Napsat hráčům'),
                  ),
                FloatingActionButton.extended(
                  heroTag: 'player-compose',
                  onPressed: () => showPlayerComposer(context, ref),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Napsat'),
                ),
              ],
            ),
          );
        });
      }),
    );
  }

  /// Marks the messages I received, have an unread row for and have not
  /// asked about yet — after the frame, since it writes to a stream this
  /// build watches. A message I sent has no row of mine.
  void _markReceivedRead(_Data data) {
    final unread = [
      for (final m in data.messages)
        if (!_requested.contains(m.id))
          if (data.mine[m.id] case final row? when row.readAt == null) m.id,
    ];
    if (unread.isEmpty) return;
    _requested.addAll(unread);
    final markRead = widget.markRead;
    // Bookkeeping, not an action the player took — no snack, and a failure
    // is retried on the next open, not now (optimisticWrite re-emits the
    // unread rows on failure; retrying from that rebuild would loop while
    // offline).
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => markRead(unread).catchError((_) {}),
    );
  }

  void _refresh() {
    ref.invalidate(messagesProvider);
    ref.invalidate(myMessageRecipientsProvider);
    ref.invalidate(playersProvider);
    ref.invalidate(timeBlocksProvider);
  }
}

/// What the list renders from: the messages (notices live on Nástěnka), my
/// own recipient row per message id (absent for one I sent), roster names
/// and blocks by id. The „Od správce“ vs „Od služby“ label comes from
/// [Message.authorIsAdmin] (the `author_role` snapshot) — players cannot
/// read other profiles, so nothing here watches `profilesProvider`.
typedef _Data = ({
  List<Message> messages,
  Map<String, MessageRecipient> mine,
  Map<String, String> names,
  Map<String, TimeBlock> blocks,
  String? meId,
});

/// [_Data] as one [AsyncValue]: the first error, else loading until every
/// stream has a value — so read marking never runs on half a snapshot.
AsyncValue<_Data> _watchData(WidgetRef ref) {
  final messages = ref.watch(messagesProvider);
  final mine = ref.watch(myMessageRecipientsProvider);
  final players = ref.watch(playersProvider);
  final blocks = ref.watch(timeBlocksProvider);
  final meId = ref.watch(myProfileProvider.select((p) => p.value?.id));
  for (final v in <AsyncValue<Object?>>[messages, mine, players, blocks]) {
    if (v.hasError && !v.hasValue) {
      return AsyncValue.error(v.error!, v.stackTrace ?? StackTrace.current);
    }
  }
  if (!messages.hasValue ||
      !mine.hasValue ||
      !players.hasValue ||
      !blocks.hasValue) {
    return const AsyncValue.loading();
  }
  return AsyncValue.data((
    messages: [
      for (final m in messages.value!)
        if (m.kind == MessageKind.message) m,
    ],
    mine: {for (final r in mine.value!) r.messageId: r},
    names: {for (final p in players.value!) p.id: p.displayName},
    blocks: {for (final b in blocks.value!) b.id: b},
    meId: meId,
  ));
}

class _MessageList extends ConsumerStatefulWidget {
  const _MessageList({
    required this.data,
    required this.react,
    required this.reply,
  });

  final _Data data;
  final MessageReact react;
  final MessageReply reply;

  @override
  ConsumerState<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends ConsumerState<_MessageList> {
  bool _olderOpen = false;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final today = ref.watch(
      nowProvider.select((n) => Day.fromDateTime(n.value ?? DateTime.now())),
    );
    final split = splitMessages(data.messages, today);
    Widget tile(Message m) => LiveMessageTile(
          key: ValueKey(m.id),
          message: m,
          myRow: data.mine[m.id],
          names: data.names,
          block: m.blockId == null ? null : data.blocks[m.blockId],
          meId: data.meId,
          react: widget.react,
          reply: widget.reply,
        );
    return ListView(
      // Room for the composer FABs below the last card.
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        for (final m in split.open) tile(m),
        if (split.older.isNotEmpty)
          ListTile(
            title: Text('Starší (${split.older.length})'),
            trailing: Icon(_olderOpen ? Icons.expand_less : Icons.expand_more),
            onTap: () => setState(() => _olderOpen = !_olderOpen),
          ),
        // The older tiles as the list's own children, not an
        // ExpansionTile's Column: the list builds only what scrolls into
        // view, and every tile holds a realtime channel (its participants).
        if (_olderOpen)
          for (final m in split.older) tile(m),
      ],
    );
  }
}

/// A [MessageTile] fed from the streams, for this list and
/// `MessageDetailScreen`: the message's participant rows (its own realtime
/// channel — [messageParticipantsProvider] is autoDispose, held only while
/// the tile is built) with [myRow] standing in for mine, and the injected
/// writes wrapped in a snack on failure.
class LiveMessageTile extends ConsumerWidget {
  const LiveMessageTile({
    super.key,
    required this.message,
    required this.myRow,
    required this.names,
    required this.block,
    required this.meId,
    required this.react,
    required this.reply,
    this.onDeleted,
    this.expanded = false,
  });

  final Message message;

  /// My own row from [myMessageRecipientsProvider] — the one my chips and
  /// the badges read; null for a message I sent.
  final MessageRecipient? myRow;
  final Map<String, String> names;
  final TimeBlock? block;
  final String? meId;
  final MessageReact react;
  final MessageReply reply;

  /// Called after a confirmed, successful delete — the detail screen pops.
  final VoidCallback? onDeleted;

  /// [MessageTile.initiallyExpanded]: true on the detail screen.
  final bool expanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = message;
    final mine = m.authorId != null && m.authorId == meId;
    final own = myRow;
    final others = ref.watch(messageParticipantsProvider(m.id)).value;
    // Everyone else's rows, and mine from my own stream: both are patched
    // by the same optimistic write, and mine is there before the
    // participants' snapshot is.
    final recipients = [
      for (final r in others ?? const <MessageRecipient>[])
        if (r.userId != meId) r,
      ?own,
    ];
    return MessageTile(
      message: m,
      recipients: recipients,
      names: names,
      meId: meId,
      authorName: mine ? (names[meId] ?? '') : (names[m.authorId] ?? '?'),
      authorIsAdmin: m.authorIsAdmin,
      block: block,
      // The optimistic write already rolled the row back on failure;
      // tryAction adds the snack (friendlyDbError text).
      onReact: mine
          ? null
          : (r) => tryAction(context, () => react(m.id, r),
              errorText: friendlyDbError),
      onReply: mine
          ? null
          : (text) => tryAction(context, () => reply(m.id, text),
              errorText: friendlyDbError),
      onDelete: mine ? () => _delete(context) : null,
      initiallyExpanded: expanded,
    );
  }

  Future<void> _delete(BuildContext context) async {
    final deleted = await confirmDelete(
      context,
      title: 'Smazat zprávu?',
      message: 'Zmizí i všem příjemcům.',
      action: () => Api.messageDelete(message.id),
      success: 'Zpráva smazána.',
    );
    if (deleted) onDeleted?.call();
  }
}
