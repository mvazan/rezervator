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

  /// Saves my short reply and answers whether the write went through
  /// (false: it failed, and the caller already said why); null exactly
  /// when [onReact] is.
  final Future<bool> Function(String reply)? onReply;

  /// Null when I may not delete it (not mine).
  final VoidCallback? onDelete;

  /// Whether a sent message starts with its per-person list open — the
  /// detail screen's, where a „Reakce na tvou zprávu“ push lands. Read
  /// once: a tap still toggles it.
  final bool initiallyExpanded;

  @override
  State<MessageTile> createState() => _MessageTileState();
}

class _MessageTileState extends State<MessageTile>
    with AutomaticKeepAliveClientMixin {
  /// The reply the field last took from my row, or what the newest of my
  /// writes that went through saved (the server stores them in the order
  /// sent). Text that differs from it is the player's typed draft, which
  /// my row never overwrites. Initialised on first read: [wantKeepAlive]
  /// is asked in `super.initState()`.
  late String _synced = _myRow?.reply ?? '';

  /// Starts with the reply I already sent, so the field shows what the
  /// others see in the reaction line — and follows it ([didUpdateWidget]).
  late final TextEditingController _reply =
      TextEditingController(text: _synced);
  final _replyFocus = FocusNode();
  late bool _expanded = widget.initiallyExpanded;

  /// My reply writes still out. Meanwhile my row's changes are mostly my
  /// own writes being applied or undone, so none is followed.
  int _pending = 0;

  /// Counts my submits: only the latest one's outcome touches the field.
  int _submits = 0;

  /// The newest submit that went through: an older one's success, come
  /// after it, does not move [_synced] back.
  int _saved = 0;

  /// Whether the field holds the text of my latest submit, which failed:
  /// kept for another try whatever [_synced] is — a reply skipped while I
  /// was in the field, or one an earlier write saved meanwhile, may equal
  /// it. Ends on the next edit, or when a latest submit goes through.
  bool _kept = false;

  /// Whether the field holds a draft: a failed reply kept, or text that
  /// differs from [_synced] — trimmed, as a write would store it: only
  /// whitespace is no draft.
  bool get _draft => _kept || _reply.text.trim() != _synced;

  /// A list drops a tile scrolled past its cache extent, and after „done“
  /// the field no longer holds it: a new tile would start from my row,
  /// losing the draft and taking the rollback of my write out for a
  /// reply to follow. So the tile keeps itself while either matters
  /// (updated in [_submit] and on typing).
  @override
  bool get wantKeepAlive => _pending > 0 || _draft;

  @override
  void initState() {
    super.initState();
    _replyFocus.addListener(_followRowAfterFocus);
  }

  /// A change of my row that came while the field was focused was skipped
  /// ([didUpdateWidget]); once I leave it, and nothing of mine is typed or
  /// out, the field catches up instead of showing (and resending) a stale
  /// reply.
  void _followRowAfterFocus() {
    if (_replyFocus.hasFocus || _pending > 0 || _draft) return;
    final now = _myRow?.reply ?? '';
    if (now == _synced) return;
    setState(() {
      _reply.text = now;
      _synced = now;
    });
  }

  @override
  void dispose() {
    _replyFocus.removeListener(_followRowAfterFocus);
    _reply.dispose();
    _replyFocus.dispose();
    super.dispose();
  }

  /// My row changed its reply (the live snapshot after a cached one, my
  /// reply from another device, cleared elsewhere): the field shows the
  /// new one when it is free to — not focused, no write of mine out, and
  /// no draft in it ([_draft]). Else a stale reply would be resent, or
  /// what the player typed lost: the rollback of a failed write reaches
  /// the tile after the failure, and must not wipe the text kept for
  /// another try (the snack says why).
  @override
  void didUpdateWidget(MessageTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final now = _myRow?.reply ?? '';
    if ((_rowIn(oldWidget)?.reply ?? '') == now) return;
    if (_replyFocus.hasFocus || _pending > 0 || _draft) return;
    _reply.text = now;
    _synced = now;
  }

  /// Sends [text]. What a submit that went through saved (trimmed, as the
  /// write stores it) is [_synced], unless a newer one already went
  /// through. Only the latest submit touches the field: its failure keeps
  /// the text there ([_kept]) while the field still shows it; its success
  /// shows what was saved, unless the player is back in the field or
  /// typed something else.
  Future<void> _submit(String text) async {
    final onReply = widget.onReply;
    if (onReply == null || overLimit(text, replyMax)) return;
    final submit = ++_submits;
    _pending++;
    updateKeepAlive();
    final bool ok;
    try {
      ok = await onReply(text);
    } finally {
      _pending--;
    }
    if (!mounted) return;
    final saved = text.trim();
    if (ok && submit > _saved) {
      _saved = submit;
      _synced = saved;
    }
    if (submit == _submits) {
      if (ok) {
        _kept = false;
        if (!_replyFocus.hasFocus && _reply.text == text && text != saved) {
          _reply.text = saved;
        }
      } else if (_reply.text == text) {
        _kept = true;
      }
    }
    updateKeepAlive();
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
    super.build(context); // keeps the tile alive ([wantKeepAlive])
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
                    reactionLine(widget.recipients, widget.names, widget.meId,
                        namesForNone: true),
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
            onChanged: (_) {
              _kept = false; // edited: a draft only where it differs
              updateKeepAlive(); // a draft now, or none any more
              setState(() {});
            },
            // Over the limit (code points) the server's CHECK would refuse
            // it: the field is marked instead, and nothing is sent.
            onSubmitted: _submit,
          ),
        ),
      ],
    );
  }
}
