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
  /// others see in the reaction line.
  late final _reply = TextEditingController(text: _myRow?.reply ?? '');
  late bool _expanded = widget.initiallyExpanded;

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  MessageRecipient? get _myRow {
    final id = widget.meId;
    if (id == null) return null;
    for (final r in widget.recipients) {
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
              InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Text(tallyLabel(tally(widget.recipients)), style: small),
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

  /// 👍 / 👎 (a toggle: tapping my current reaction clears it) and the
  /// „Krátká odpověď…“ field, saved on submit.
  Widget _receivedRow(void Function(Reaction? reaction) onReact) {
    final current = _myRow?.reaction;
    return Row(
      children: [
        IconButton(
          icon: Icon(
            current == Reaction.up ? Icons.thumb_up : Icons.thumb_up_outlined,
          ),
          onPressed: () =>
              onReact(current == Reaction.up ? null : Reaction.up),
        ),
        IconButton(
          icon: Icon(
            current == Reaction.down
                ? Icons.thumb_down
                : Icons.thumb_down_outlined,
          ),
          onPressed: () =>
              onReact(current == Reaction.down ? null : Reaction.down),
        ),
        Expanded(
          child: TextField(
            controller: _reply,
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
