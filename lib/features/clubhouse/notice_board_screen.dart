/// Klubovna → Nástěnka (0051): the admin's notices, read-only for every
/// player, with history and an optional expiry. Only the admin posts —
/// Klubovna → Zprávy is where the duty and players message each other.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/messages.dart';
import '../../domain/models.dart';
import 'widgets/notice_form.dart';
import 'widgets/notice_seen_sheet.dart';

/// [Api.messageUpdate]'s shape: the write behind the card's „Sejmout“.
typedef NoticeUpdate = Future<void> Function(
  String id, {
  required String title,
  required String body,
  DateTime? expiresAt,
});

class NoticeBoardScreen extends ConsumerStatefulWidget {
  const NoticeBoardScreen({
    super.key,
    this.markRead = Api.markMessagesRead,
    this.updateNotice = Api.messageUpdate,
    this.deleteNotice = Api.messageDelete,
    this.setOnKiosk = Api.messageSetKiosk,
  });

  /// Marks the listed notices read — injected like
  /// `MyTrainingsScreen.cancelReservation`, so widget tests never reach
  /// `Supabase.instance`.
  final Future<void> Function(List<String> ids) markRead;

  /// „Sejmout“'s write, injected for the same reason.
  final NoticeUpdate updateNotice;

  /// „Smazat“'s write ([Api.messageDelete]), injected for the same reason.
  final Future<void> Function(String id) deleteNotice;

  /// „Skrýt na kiosku“ / „Zobrazit na kiosku“ ([Api.messageSetKiosk]).
  final Future<void> Function(String id, bool show) setOnKiosk;

  @override
  ConsumerState<NoticeBoardScreen> createState() => _NoticeBoardScreenState();
}

class _NoticeBoardScreenState extends ConsumerState<NoticeBoardScreen> {
  /// The notices this visit has already asked to mark read. Checked on
  /// EVERY complete snapshot, not just the first: cachedRows replays the
  /// cache (or the pre-resume state) first, so the notice a push opened
  /// the board for often arrives a moment later — and one posted while the
  /// board is open is listed too. Each id is still sent once per visit.
  final _requested = <String>{};

  @override
  Widget build(BuildContext context) {
    final isAdmin =
        ref.watch(myProfileProvider.select((p) => p.value?.isAdmin)) ?? false;
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
      _markActiveRead(data);
      body = _NoticeList(
        data: data,
        isAdmin: isAdmin,
        updateNotice: widget.updateNotice,
        deleteNotice: widget.deleteNotice,
        setOnKiosk: widget.setOnKiosk,
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Nástěnka')),
      body: body,
      floatingActionButton: isAdmin
          ? FloatingActionButton.extended(
              onPressed: () => showNoticeForm(context),
              icon: const Icon(Icons.add),
              label: const Text('Nový oznam'),
            )
          : null,
    );
  }

  /// Marks the active notices I have an unread row for and have not asked
  /// about yet — after the frame, since it writes to a stream this build
  /// watches.
  void _markActiveRead(_Data data) {
    final now = ref.read(nowProvider).value ?? DateTime.now();
    // Only rows that exist and are unread: a notice posted before I
    // joined has no row for me, and there is nothing to mark.
    final unread = [
      for (final n in splitNotices(data.notices, now).active)
        if (!_requested.contains(n.id))
          if (data.mine[n.id] case final row? when row.readAt == null) n.id,
    ];
    if (unread.isEmpty) return;
    _requested.addAll(unread);
    final markRead = widget.markRead;
    // Bookkeeping, not an action the player took — no snack, and a failure
    // is retried on the next open, not now: optimisticWrite re-emits the
    // unread rows when a write fails, so retrying from that rebuild would
    // loop for as long as the phone is offline.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => markRead(unread).catchError((_) {}),
    );
  }

  void _refresh() {
    ref.invalidate(messagesProvider);
    ref.invalidate(myMessageRecipientsProvider);
  }
}

/// What the board renders from: the notices, and my own recipient row per
/// notice id (read state; absent for a notice posted before I joined).
typedef _Data = ({
  List<Message> notices,
  Map<String, MessageRecipient> mine,
});

/// [_Data] as one [AsyncValue]: the first error, else loading until both
/// streams have a value — so read marking never runs on half a snapshot.
AsyncValue<_Data> _watchData(WidgetRef ref) {
  final messages = ref.watch(messagesProvider);
  final mine = ref.watch(myMessageRecipientsProvider);
  for (final v in <AsyncValue<Object?>>[messages, mine]) {
    if (v.hasError && !v.hasValue) {
      return AsyncValue.error(v.error!, v.stackTrace ?? StackTrace.current);
    }
  }
  if (!messages.hasValue || !mine.hasValue) return const AsyncValue.loading();
  return AsyncValue.data((
    notices: [
      for (final m in messages.value!)
        if (m.kind == MessageKind.notice) m,
    ],
    mine: {for (final r in mine.value!) r.messageId: r},
  ));
}

class _NoticeList extends ConsumerStatefulWidget {
  const _NoticeList({
    required this.data,
    required this.isAdmin,
    required this.updateNotice,
    required this.deleteNotice,
    required this.setOnKiosk,
  });

  final _Data data;
  final bool isAdmin;
  final NoticeUpdate updateNotice;
  final Future<void> Function(String id) deleteNotice;
  final Future<void> Function(String id, bool show) setOnKiosk;

  @override
  ConsumerState<_NoticeList> createState() => _NoticeListState();
}

class _NoticeListState extends ConsumerState<_NoticeList> {
  bool _olderOpen = false;

  @override
  Widget build(BuildContext context) {
    final now = ref.watch(nowProvider).value ?? DateTime.now();
    final split = splitNotices(widget.data.notices, now);
    // Notices posted ahead of time are the admin's until they show.
    final scheduled = widget.isAdmin ? split.scheduled : const <Message>[];
    if (split.active.isEmpty && split.expired.isEmpty && scheduled.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Na nástěnce zatím nic není.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    Widget tile(Message n) => _NoticeCard(
          key: ValueKey(n.id),
          notice: n,
          now: now,
          isAdmin: widget.isAdmin,
          updateNotice: widget.updateNotice,
          deleteNotice: widget.deleteNotice,
          setOnKiosk: widget.setOnKiosk,
        );
    return ListView(
      // Room for the admin's FAB below the last card.
      padding: padWithSystemInset(context, const EdgeInsets.only(bottom: 88)),
      children: [
        if (scheduled.isNotEmpty) ...[
          ListTile(
            dense: true,
            leading: const Icon(Icons.schedule),
            title: Text('Naplánované (${scheduled.length})'),
          ),
          for (final n in scheduled) tile(n),
          const Divider(),
        ],
        for (final n in split.active) tile(n),
        if (split.expired.isNotEmpty)
          ListTile(
            title: Text('Starší (${split.expired.length})'),
            trailing: Icon(_olderOpen ? Icons.expand_less : Icons.expand_more),
            onTap: () => setState(() => _olderOpen = !_olderOpen),
          ),
        // The older cards as the list's own children, not an
        // ExpansionTile's Column: the list builds only what scrolls into
        // view, and for the admin every card holds a realtime channel (its
        // seen count) — notices are never pruned.
        if (_olderOpen)
          for (final n in split.expired) tile(n),
      ],
    );
  }
}

/// Bodies longer than this many lines start cut with a „Více“ toggle.
const _cutLines = 3;

/// One notice: title, body (cut to three lines with „Více“ when long),
/// footer; for the admin also the seen count and the ⋮ actions.
class _NoticeCard extends ConsumerStatefulWidget {
  const _NoticeCard({
    super.key,
    required this.notice,
    required this.now,
    required this.isAdmin,
    required this.updateNotice,
    required this.deleteNotice,
    required this.setOnKiosk,
  });

  final Message notice;
  final DateTime now;
  final bool isAdmin;
  final NoticeUpdate updateNotice;
  final Future<void> Function(String id) deleteNotice;
  final Future<void> Function(String id, bool show) setOnKiosk;

  @override
  ConsumerState<_NoticeCard> createState() => _NoticeCardState();
}

class _NoticeCardState extends ConsumerState<_NoticeCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final notice = widget.notice;
    final isAdmin = widget.isAdmin;
    // The notice's recipient rows — the admin's „Zobrazilo 12 z 40“. Only
    // watched for the admin: a player may read just their own row.
    final rows =
        isAdmin ? ref.watch(messageParticipantsProvider(notice.id)).value : null;
    final seen = rows == null
        ? null
        : seenLabel(rows.where((r) => r.readAt != null).length, rows.length);
    final footer = [
      noticeFooter(notice, widget.now),
      ?seen,
      if (isAdmin && !notice.showOnKiosk) 'skrytý na kiosku',
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: ListTile(
        title: Text(notice.title ?? ''),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // „Více“ only when the body really is longer than three lines
            // at this width: on a wide screen a long text may fit, and a
            // toggle that changes nothing is noise.
            LayoutBuilder(
              builder: (context, box) {
                final style = DefaultTextStyle.of(context).style;
                final painter = TextPainter(
                  text: TextSpan(text: notice.body, style: style),
                  textDirection: Directionality.of(context),
                  textScaler: MediaQuery.textScalerOf(context),
                  maxLines: _cutLines,
                )..layout(maxWidth: box.maxWidth);
                final long = painter.didExceedMaxLines;
                painter.dispose();
                final cut = long && !_expanded;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      notice.body,
                      maxLines: cut ? _cutLines : null,
                      overflow: cut ? TextOverflow.ellipsis : null,
                    ),
                    if (long)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () =>
                              setState(() => _expanded = !_expanded),
                          child: Text(_expanded ? 'Méně' : 'Více'),
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 4),
            Text(footer, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        isThreeLine: true,
        trailing: isAdmin
            ? PopupMenuButton<String>(
                onSelected: (a) => _act(context, a),
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('Upravit')),
                  const PopupMenuItem(
                    value: 'seen',
                    child: Text('Kdo si to zobrazil'),
                  ),
                  // „Sejmout“ = expire now: an expired notice would only
                  // get a later expiry. The board's own clock and rule
                  // (splitNotices) decide what is active.
                  if (notice.expiresAt == null ||
                      notice.expiresAt!.isAfter(widget.now))
                    const PopupMenuItem(
                      value: 'unpost',
                      child: Text('Sejmout'),
                    ),
                  PopupMenuItem(
                    value: 'kiosk',
                    child: Text(notice.showOnKiosk
                        ? 'Skrýt na kiosku'
                        : 'Zobrazit na kiosku'),
                  ),
                  const PopupMenuItem(value: 'delete', child: Text('Smazat')),
                ],
              )
            : null,
      ),
    );
  }

  Future<void> _act(BuildContext context, String action) async {
    final notice = widget.notice;
    switch (action) {
      case 'edit':
        await showNoticeForm(context, existing: notice);
      case 'seen':
        await showNoticeSeenSheet(context, notice: notice);
      case 'kiosk':
        await tryActionOnPage(
          context,
          () => widget.setOnKiosk(notice.id, !notice.showOnKiosk),
          success: notice.showOnKiosk
              ? 'Oznam se na kiosku nezobrazuje.'
              : 'Oznam se zobrazí na kiosku.',
          errorText: friendlyDbError,
        );
      case 'unpost':
        final ok = await confirmDialog(
          context,
          title: 'Sejmout oznam?',
          message: 'Oznam přestane platit hned.',
        );
        if (!ok || !context.mounted) return;
        // „Sejmout“ = expire now, title and body as they are NOW: another
        // admin may have edited the notice while the dialog was open, and
        // message_update writes the full state — the text the menu opened
        // with would revert that edit. „Now“ is the board's own clock, not
        // DateTime.now(): nowProvider ticks once a minute and polls every
        // 15 s, so it runs up to ~75 s behind, and a wall-clock expiry
        // would leave the echoed notice active (here and on the badge)
        // until its next tick. Never later than what the list compares
        // against, so the card moves under „Starší“ at once.
        final now = ref.read(nowProvider).value ?? DateTime.now();
        final current = ref
                .read(messagesProvider)
                .value
                ?.where((m) => m.id == notice.id)
                .firstOrNull ??
            notice;
        // On the page's messenger: the echo can move the card under the
        // collapsed „Starší“ before the call returns.
        await tryActionOnPage(
          context,
          () => widget.updateNotice(
            current.id,
            title: current.title ?? '',
            body: current.body,
            expiresAt: now,
          ),
          success: 'Oznam sejmut.',
          errorText: friendlyDbError,
        );
      case 'delete':
        final ok = await confirmDialog(
          context,
          title: 'Smazat oznam?',
          message: 'Tohle nejde vrátit zpět.',
        );
        if (!ok || !context.mounted) return;
        // The echo can remove the card before the call returns.
        await tryActionOnPage(
          context,
          () => widget.deleteNotice(notice.id),
          success: 'Oznam smazán.',
          errorText: friendlyDbError,
        );
    }
  }
}
