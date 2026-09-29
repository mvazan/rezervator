/// One message in Klubovna → Zprávy (0051): header, context chip, body,
/// then either the received side (👍/👎 + a reply field, and everyone
/// else's reactions) or the sent side (a tally that expands into names).
/// Shared by `MessagesScreen` and `MessageDetailScreen`; pure — the caller
/// hands in the rows and the writes.
library;

import 'package:flutter/material.dart';

import '../../../domain/messages.dart';
import '../../../domain/models.dart';
import 'server_limit.dart';

class MessageTile extends StatefulWidget {
  const MessageTile({
    super.key,
    required this.message,
    required this.recipients,
    required this.names,
    required this.meId,
    required this.authorName,
    required this.authorIsAdmin,
    required this.block,
    required this.onReact,
    required this.onReply,
    required this.onDelete,
    this.initiallyExpanded = false,
  });

  final Message message;

  /// Every recipient row of [message] the caller can read — mine included
  /// when I received it (my chips and reply read from there).
  final List<MessageRecipient> recipients;

  /// Roster names by profile id, for the reaction line.
  final Map<String, String> names;

  /// The signed-in player; null before the profile loads.
  final String? meId;

  /// The sender's name for the header („Od služby (Bára)“).
  final String authorName;

  /// Whether the sender was an admin — „Od správce“ rather than „Od služby“.
  final bool authorIsAdmin;

  /// The block the message is about, for the context chip's time; null
  /// when it has none or the block is gone.
  final TimeBlock? block;

  /// Sets (or, with null, clears) my reaction. Null when I did not receive
  /// this message (it is mine) — the tile then shows the sent side.
  final void Function(Reaction? reaction)? onReact;

  /// Saves my short reply; null exactly when [onReact] is.
  final void Function(String reply)? onReply;

  /// Null when I may not delete it (not mine).
  final VoidCallback? onDelete;

  /// Whether a sent message starts with its per-person list open — the
  /// detail screen's, where a „Reakce na tvou zprávu“ push lands. Read
  /// once: a tap still toggles it.
  final bool initiallyExpanded;

  @override
  State<MessageTile> createState() => _MessageTileState();
}

class _MessageTileState extends State<MessageTile> {
  /// Starts with the reply I already sent, so the field shows what the
  /// others see in the reaction line — and follows it ([didUpdateWidget]).
  late final _reply = TextEditingController(text: _myRow?.reply ?? '');
  final _replyFocus = FocusNode();
  late bool _expanded = widget.initiallyExpanded;

  @override
  void dispose() {
    _reply.dispose();
    _replyFocus.dispose();
    super.dispose();
  }

  /// My row changed its reply (the live snapshot after a cached one, my
  /// reply from another device, a rolled-back write): the field shows the
  /// new one — unless I am typing, or hold an unsent draft (the field no
  /// longer shows the old reply). Else a stale reply would be resent.
  @override
  void didUpdateWidget(MessageTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final was = _rowIn(oldWidget)?.reply ?? '';
    final now = _myRow?.reply ?? '';
    if (was != now && !_replyFocus.hasFocus && _reply.text == was) {
      _reply.text = now;
    }
  }

  MessageRecipient? get _myRow => _rowIn(widget);

  static MessageRecipient? _rowIn(MessageTile tile) {
    final id = tile.meId;
    if (id == null) return null;
    for (final r in tile.recipients) {
      if (r.userId == id) return r;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final small = Theme.of(context).textTheme.bodySmall;
    final header = headerLabel(
      m,
      authorName: widget.authorName,
      authorIsAdmin: widget.authorIsAdmin,
      meId: widget.meId,
    );
    final chip = contextLabel(m, widget.block);
    final onReact = widget.onReact;
    final mine = m.authorId != null && m.authorId == widget.meId;

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    header,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                if (widget.onDelete != null)
                  PopupMenuButton<String>(
                    onSelected: (_) => widget.onDelete!(),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'delete', child: Text('Smazat')),
                    ],
                  ),
              ],
            ),
            if (chip != null) ...[
              const SizedBox(height: 2),
              Chip(
                label: Text(chip, style: const TextStyle(fontSize: 12)),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
            const SizedBox(height: 6),
            Text(m.body),
            const SizedBox(height: 8),
            if (onReact != null) ...[
              _receivedRow(onReact),
              if (widget.recipients.isNotEmpty)
                Text(
                  reactionLine(widget.recipients, widget.names, widget.meId),
                  style: small,
                ),
            ] else if (mine) ...[
              // A button of full tap height that says whether its list is
              // open — its own node, not merged into the card's.
              Semantics(
                container: true,
                button: true,
                expanded: _expanded,
                child: InkWell(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: kMinInteractiveDimension,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            tallyLabel(tally(widget.recipients)),
                            style: small,
                          ),
                        ),
                        ExcludeSemantics(
                          child: Icon(
                            _expanded ? Icons.expand_less : Icons.expand_more,
                            size: 18,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_expanded)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    reactionLine(widget.recipients, widget.names, widget.meId),
                    style: small,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// 👍 / 👎 — the spec's two toggle chips: named by their emoji, with a
  /// selected state a screen reader announces; tapping my current reaction
  /// clears it — and the „Krátká odpověď…“ field, saved on submit.
  Widget _receivedRow(void Function(Reaction? reaction) onReact) {
    final current = _myRow?.reaction;
    Widget chip(Reaction reaction, String label) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilterChip(
            label: Text(label),
            selected: current == reaction,
            onSelected: (_) =>
                onReact(current == reaction ? null : reaction),
          ),
        );
    return Row(
      children: [
        chip(Reaction.up, '👍'),
        chip(Reaction.down, '👎'),
        Expanded(
          child: TextField(
            controller: _reply,
            focusNode: _replyFocus,
            decoration: withServerLimit(
              context,
              const InputDecoration(hintText: 'Krátká odpověď…'),
              _reply.text,
              replyMax,
            ),
            maxLength: replyMax,
            onChanged: (_) => setState(() {}),
            // Over the limit (code points) the server's CHECK would refuse
            // it: the field is marked instead, and nothing is sent.
            onSubmitted: (text) {
              if (!overLimit(text, replyMax)) widget.onReply?.call(text);
            },
          ),
        ),
      ],
    );
  }
}
