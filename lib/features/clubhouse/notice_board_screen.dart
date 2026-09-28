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

class NoticeBoardScreen extends ConsumerStatefulWidget {
  const NoticeBoardScreen({super.key, this.markRead = Api.markMessagesRead});

  /// Marks the listed notices read — injected like
  /// `MyTrainingsScreen.cancelReservation`, so widget tests never reach
  /// `Supabase.instance`.
  final Future<void> Function(List<String> ids) markRead;

  @override
  ConsumerState<NoticeBoardScreen> createState() => _NoticeBoardScreenState();
}

class _NoticeBoardScreenState extends ConsumerState<NoticeBoardScreen> {
  /// Opening the board marks what it lists read — once per open, on the
  /// first complete snapshot.
  bool _markedRead = false;

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
      if (!_markedRead) {
        _markedRead = true;
        _markActiveRead(data);
      }
      body = _NoticeList(data: data, isAdmin: isAdmin);
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

  /// Marks the active notices I have an unread row for — after the frame,
  /// since it writes to a stream this build watches.
  void _markActiveRead(_Data data) {
    final now = ref.read(nowProvider).value ?? DateTime.now();
    // Only rows that exist and are unread: a notice posted before I
    // joined has no row for me, and there is nothing to mark.
    final unread = [
      for (final n in splitNotices(data.notices, now).active)
        if (data.mine[n.id] case final row? when row.readAt == null) n.id,
    ];
    if (unread.isEmpty) return;
    // Bookkeeping, not an action the player took — a failure is retried
    // on the next open, no snack.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => widget.markRead(unread).catchError((_) {}),
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

class _NoticeList extends ConsumerWidget {
  const _NoticeList({required this.data, required this.isAdmin});

  final _Data data;
  final bool isAdmin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(nowProvider).value ?? DateTime.now();
    final split = splitNotices(data.notices, now);
    if (split.active.isEmpty && split.expired.isEmpty) {
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
          isAdmin: isAdmin,
        );
    return ListView(
      // Room for the admin's FAB below the last card.
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        for (final n in split.active) tile(n),
        if (split.expired.isNotEmpty)
          ExpansionTile(
            title: Text('Starší (${split.expired.length})'),
            children: [for (final n in split.expired) tile(n)],
          ),
      ],
    );
  }
}

/// Bodies longer than this (or with more than three lines) start cut to
/// three lines with a „Více“ toggle.
const _cutAfter = 160;

/// One notice: title, body (cut to three lines with „Více“ when long),
/// footer; for the admin also the seen count and the ⋮ actions.
class _NoticeCard extends ConsumerStatefulWidget {
  const _NoticeCard({
    super.key,
    required this.notice,
    required this.now,
    required this.isAdmin,
  });

  final Message notice;
  final DateTime now;
  final bool isAdmin;

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
    final footer = [noticeFooter(notice, widget.now), ?seen].join(' · ');
    // More than three lines means at least three line breaks.
    final long = notice.body.length > _cutAfter ||
        '\n'.allMatches(notice.body).length >= 3;
    final cut = long && !_expanded;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: ListTile(
        title: Text(notice.title ?? ''),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              notice.body,
              maxLines: cut ? 3 : null,
              overflow: cut ? TextOverflow.ellipsis : null,
            ),
            if (long)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  child: Text(_expanded ? 'Méně' : 'Více'),
                ),
              ),
            const SizedBox(height: 4),
            Text(footer, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        isThreeLine: true,
        trailing: isAdmin
            ? PopupMenuButton<String>(
                onSelected: (a) => _act(context, a),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Upravit')),
                  PopupMenuItem(
                    value: 'seen',
                    child: Text('Kdo si to zobrazil'),
                  ),
                  PopupMenuItem(value: 'unpost', child: Text('Sejmout')),
                  PopupMenuItem(value: 'delete', child: Text('Smazat')),
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
      case 'unpost':
        final ok = await confirmDialog(
          context,
          title: 'Sejmout oznam?',
          message: 'Oznam přestane platit hned.',
        );
        if (!ok || !context.mounted) return;
        // „Sejmout“ = expire now, title and body as they were.
        await tryAction(
          context,
          () => Api.messageUpdate(
            notice.id,
            title: notice.title ?? '',
            body: notice.body,
            expiresAt: DateTime.now(),
          ),
          success: 'Oznam sejmut.',
          errorText: friendlyDbError,
        );
      case 'delete':
        await confirmDelete(
          context,
          title: 'Smazat oznam?',
          message: 'Tohle nejde vrátit zpět.',
          action: () => Api.messageDelete(notice.id),
          success: 'Oznam smazán.',
        );
    }
  }
}
