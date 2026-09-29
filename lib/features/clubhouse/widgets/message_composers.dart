/// The two ways to start a message (0051): a player writing to the admins
/// or today's duty, and the admin/duty writing to a day or a block of
/// players. Both end in Api.messageSend; both show the spec's error texts
/// on refusal.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../../../core/ui.dart';
import '../../../data/clock.dart';
import '../../../data/providers.dart';
import '../../../data/week_schedule.dart' show weekScheduleProvider;
import '../../../domain/collation.dart';
import '../../../domain/duties.dart' show dutyDayLabel;
import '../../../domain/messages.dart'
    show
        dayRecipientIds,
        dutyRecipientIds,
        messageBodyMax,
        overLimit,
        recipientPreviewLabel;
import '../../../domain/models.dart';
import '../../../domain/schedule.dart';
import 'server_limit.dart';

/// `ref.read` or `ref.watch` — [_dutyReachable] serves a one-off check
/// and a live sheet with the same rule.
typedef _Get = T Function<T>(ProviderListenable<T> provider);

/// The roster's ids with an account — `message_send`'s member rule (the
/// `players` view) minus the players without an account; null while the
/// roster has not loaded (then nobody is filtered out).
Set<String>? _members(_Get get) {
  final players = get(playersProvider).value;
  if (players == null) return null;
  return {
    for (final p in players)
      if (p.hasAccount) p.id,
  };
}

/// Whether „Službě“ has anyone to reach today: someone other than me, with
/// an account, is assigned to the period covering today — the set
/// `message_send` computes, so an empty one would only earn
/// `nobody_on_duty`.
bool _dutyReachable(_Get get) {
  final me = get(myProfileProvider).value;
  if (me == null) return false;
  final today = Day.fromDateTime(get(nowProvider).value ?? DateTime.now());
  return dutyRecipientIds(
    get(dutyPeriodsProvider).value ?? const [],
    get(dutyAssignmentsProvider).value ?? const [],
    me.id,
    today,
    members: _members(get),
  ).isNotEmpty;
}

/// [_dutyReachable] read once, for an entry point deciding whether to
/// offer „Napsat službě…“ (Task 9's cancel dialog). The player composer
/// itself watches the same rule live.
///
/// Reads [myProfileProvider], [nowProvider], [dutyPeriodsProvider],
/// [dutyAssignmentsProvider] and [playersProvider] — a widget test calling
/// it overrides all five, the roster giving the duty an account (else
/// nobody is reachable once it loads).
bool dutyReachableToday(WidgetRef ref) => _dutyReachable(ref.read);

/// The player composer — Klubovna → Zprávy's „Napsat“, and the training's
/// „Napsat správci…“ / „Napsat službě…“ (Task 9) with [date]/[block] as the
/// context (`on_date`/`block_id`, display only) and [preselect] as the
/// audience. A [MessageAudience.duty] preselect falls back to Správci while
/// nobody else serves today. The sheet sends itself ([_sendFromSheet]):
/// nothing waits on [context] once it is open. It watches its own
/// providers — [ref] only keeps the entry points' call shape, as for
/// [showStaffComposer]: those of [dutyReachableToday] ([myProfileProvider],
/// [nowProvider], [dutyPeriodsProvider], [dutyAssignmentsProvider],
/// [playersProvider]), which a widget test opening it overrides; [send] is
/// the RPC (see [MessageSend]).
Future<void> showPlayerComposer(
  BuildContext context,
  WidgetRef ref, {
  Day? date,
  TimeBlock? block,
  MessageAudience? preselect,
  MessageSend? send,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _PlayerComposerSheet(
    initial: preselect ?? MessageAudience.admins,
    trainingLabel: date == null
        ? null
        : block == null
        ? 'K tréninku ${dutyDayLabel(date)}'
        : 'K tréninku ${dutyDayLabel(date)} · ${block.label}',
    date: date,
    blockId: block?.id,
    send: send ?? Api.messageSend,
  ),
);

/// [Api.messageSend]'s shape — both composers' `send` replaces the RPC, so
/// widget tests never reach `Supabase.instance`.
typedef MessageSend =
    Future<String> Function({
      required MessageKind kind,
      required MessageAudience audience,
      Day? onDate,
      String? blockId,
      String? title,
      required String body,
      DateTime? expiresAt,
      bool notify,
    });

/// „Odeslat“ of both sheets, run with the SHEET's [context] — never the
/// caller's: Zprávy's FABs step aside while the keyboard is up, and a
/// message handed back to a FAB that was gone meanwhile was never sent.
/// Success closes the sheet and the page says „Zpráva odeslána.“; a
/// refusal shows over the sheet ([snack]) and keeps the text for another
/// try. The page's messenger is taken first: the sheet may be swiped away
/// while the call runs, and its outcome must still be told — which
/// [tryAction], silent once its context is gone, would not do. Says whether
/// it went through: the sheet then stays „sending“ (no second „Odeslat“
/// while it slides away); after a refusal it is free for another try.
Future<bool> _sendFromSheet(
  BuildContext context,
  Future<void> Function() send, {
  required String Function(Object error) errorText,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  void onPage(String text) {
    if (messenger != null && messenger.mounted) {
      messenger.showSnackBar(SnackBar(content: Text(text)));
    }
  }

  try {
    await send();
  } catch (e) {
    if (context.mounted) {
      snack(context, errorText(e));
    } else {
      onPage(errorText(e));
    }
    return false;
  }
  if (context.mounted) closeDialog(context);
  onPage('Zpráva odeslána.');
  return true;
}

/// The staff composer — Zprávy's „Napsat hráčům“ (the admin, or the duty on
/// today or later), and the calendar's „Napsat hráčům dne…“ / „Napsat
/// hráčům bloku…“ (Task 9) with [date]/[blockId] prefilled. The date
/// defaults to today; the duty cannot pick a past day. Every target shows
/// who would get it („Dostane 2 hráči: …“), and an empty one cannot be
/// sent. The sheet sends itself, as in [showPlayerComposer]. It watches its
/// own providers, [ref] as there — [myProfileProvider], [myDutyProvider],
/// [nowProvider], [weekScheduleProvider], [weekReservationsProvider] and
/// [playersProvider], which a widget test opening it overrides; [send] is
/// the RPC (see [MessageSend]).
Future<void> showStaffComposer(
  BuildContext context,
  WidgetRef ref, {
  Day? date,
  String? blockId,
  MessageSend? send,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _StaffComposerSheet(
    initialDate: date,
    initialBlockId: blockId,
    send: send ?? Api.messageSend,
  ),
);

/// The staff composer's refusal text: `no_recipients` and `date_past` read
/// differently here than in the shared map (spec: Errors and edge cases),
/// and a `not_allowed` sent [asDuty] means the duty has ended.
@visibleForTesting
String staffSendErrorText(
  Object error, {
  required bool toBlock,
  required bool asDuty,
}) {
  final raw = '$error';
  if (raw.contains('no_recipients')) {
    return toBlock
        ? 'V tomto bloku nikdo nemá rezervaci.'
        : 'V tento den nikdo nemá rezervaci.';
  }
  if (raw.contains('date_past')) return 'Minulým dnům už nejde psát.';
  return friendlyDbError(error, wasOnDuty: asDuty);
}

/// The player composer's refusal text: `no_recipients` to „Správci“ means
/// the writer is the alley's only admin — the shared „Nikdo nemá
/// rezervaci.“ speaks of reservations (spec: Copy decisions). Every other
/// code keeps the shared text; `nobody_on_duty` („Dnes nikdo neslouží —
/// napiš správci.“) among them, since a player composer is never offered
/// for being on duty.
@visibleForTesting
String playerSendErrorText(
  Object error, {
  required MessageAudience audience,
}) {
  if (audience == MessageAudience.admins &&
      '$error'.contains('no_recipients')) {
    return 'Jiného správce tu nemáš.';
  }
  return friendlyDbError(error);
}

class _PlayerComposerSheet extends ConsumerStatefulWidget {
  const _PlayerComposerSheet({
    required this.initial,
    required this.trainingLabel,
    required this.date,
    required this.blockId,
    required this.send,
  });

  /// The audience picked when the sheet opens.
  final MessageAudience initial;

  /// „K tréninku po 5. 10. · 16:00–17:00“ when opened from a training.
  final String? trainingLabel;

  /// The training's day and block, sent as `on_date`/`block_id`.
  final Day? date;
  final String? blockId;
  final MessageSend send;

  @override
  ConsumerState<_PlayerComposerSheet> createState() =>
      _PlayerComposerSheetState();
}

class _PlayerComposerSheetState extends ConsumerState<_PlayerComposerSheet> {
  /// The player's choice; [build] shows Správci instead while „Službě“ is
  /// off — the streams may land after the sheet opens, and a duty may end
  /// while it is open.
  late MessageAudience _audience = widget.initial;
  final _body = TextEditingController();

  /// A send is under way: „Odeslat“ waits, so one tap is one message.
  /// [_send] checks it too — the button is disabled only from the next
  /// frame, and a double tap in a janky frame lands twice before that.
  bool _sending = false;

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  Future<void> _send(MessageAudience audience, String text) async {
    if (_sending) return;
    setState(() => _sending = true);
    final sent = await _sendFromSheet(
      context,
      () => widget.send(
        kind: MessageKind.message,
        audience: audience,
        onDate: widget.date,
        blockId: widget.blockId,
        body: text,
      ),
      errorText: (e) => playerSendErrorText(e, audience: audience),
    );
    if (!sent && mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final dutyEnabled = _dutyReachable(ref.watch);
    final audience = _audience == MessageAudience.duty && !dutyEnabled
        ? MessageAudience.admins
        : _audience;
    final text = _body.text.trim();
    return _SheetFrame(
      children: [
        Text('Napsat', style: Theme.of(context).textTheme.titleMedium),
        if (widget.trainingLabel case final label?)
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        RadioGroup<MessageAudience>(
          groupValue: audience,
          onChanged: (v) => setState(() => _audience = v ?? _audience),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const RadioListTile<MessageAudience>(
                title: Text('Správci'),
                value: MessageAudience.admins,
              ),
              RadioListTile<MessageAudience>(
                title: const Text('Službě'),
                subtitle: dutyEnabled
                    ? null
                    : const Text('Dnes nikdo neslouží'),
                value: MessageAudience.duty,
                enabled: dutyEnabled,
              ),
            ],
          ),
        ),
        _BodyField(controller: _body, onChanged: () => setState(() {})),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: text.isEmpty || overLimit(text, messageBodyMax) || _sending
                ? null
                : () => _send(audience, text),
            child: const Text('Odeslat'),
          ),
        ),
      ],
    );
  }
}

/// The message text of both composers: up to 500 code points
/// (`message_send`'s `body_too_long`, see [withServerLimit]); [onChanged]
/// rebuilds the sheet, whose „Odeslat“ reads the controller.
class _BodyField extends StatelessWidget {
  const _BodyField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    maxLength: messageBodyMax,
    minLines: 1,
    maxLines: 3,
    textCapitalization: TextCapitalization.sentences,
    decoration: withServerLimit(
      context,
      const InputDecoration(hintText: 'Text zprávy'),
      controller.text,
      messageBodyMax,
    ),
    onChanged: (_) => onChanged(),
  );
}

/// Both composers' sheet: padded, lifted above the keyboard, scrolling when
/// a day's blocks and the keyboard leave too little room. The keyboard's
/// inset pads OUTSIDE the scroll view (as in duty_assign_sheet.dart): the
/// viewport then ends where the keyboard starts, so a focused field is
/// scrolled into the part the player can see — a viewport reaching under
/// the keyboard would reveal the caret, and „Odeslat“, behind it.
class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    ),
  );
}

/// The Monday of [d]'s week. `WeekNavigation.mondayOf` (week_board.dart)
/// is a mixin method bound to a screen's weekOffset, hence this copy.
Day _mondayOf(Day d) => d.addDays(1 - d.weekday);

class _StaffComposerSheet extends ConsumerStatefulWidget {
  const _StaffComposerSheet({
    required this.initialDate,
    required this.initialBlockId,
    required this.send,
  });

  /// Null = today.
  final Day? initialDate;

  /// Null = „Celý den“.
  final String? initialBlockId;
  final MessageSend send;

  @override
  ConsumerState<_StaffComposerSheet> createState() =>
      _StaffComposerSheetState();
}

class _StaffComposerSheetState extends ConsumerState<_StaffComposerSheet> {
  /// The day the player picked in „Změnit“, once they did.
  Day? _picked;

  /// The day the message is about: the picked one, else the one the sheet
  /// was opened on, else where writing starts — today, or for a duty who is
  /// not serving today the first day of their next period (the days they
  /// may write about are those of their own periods). Read afresh, not
  /// once: the clock and the duty may land after the sheet opens.
  Day get _date =>
      _picked ?? widget.initialDate ?? _defaultDate(ref.read);

  static Day _defaultDate(_Get get) {
    final today = _today(get);
    final isAdmin = get(myProfileProvider).value?.isAdmin ?? false;
    return isAdmin ? today : get(myDutyProvider).firstDayFrom(today) ?? today;
  }

  /// Null = „Celý den“.
  late String? _blockId = widget.initialBlockId;
  final _body = TextEditingController();

  /// Offered for having a duty period (and not the admin): once true, it
  /// stays — a duty ending while the sheet is open (midnight, an
  /// unassignment) must still read the server's `not_allowed` as
  /// [dutyEndedMessage] (spec: the duty writing at 23:59). Latched in
  /// [build], not read once: the streams may land after the sheet opens.
  /// [myDutyProvider] is `none` until the profile loads, so a true here has
  /// a known role.
  bool _offeredAsDuty = false;

  /// A send is under way: „Odeslat“ waits, so one tap is one message (one
  /// push to every booked player). [_send] checks it too — the button is
  /// disabled only from the next frame, and a double tap in a janky frame
  /// lands twice before that.
  bool _sending = false;

  static Day _today(_Get get) =>
      Day.fromDateTime(get(nowProvider).value ?? DateTime.now());

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  /// The admin may write about any day; the duty about the days of their
  /// own periods from today on (the server's `duty_edit_gate`, the block
  /// edits' gate) — every other day is greyed out.
  Future<void> _pickDate() async {
    final isAdmin = ref.read(myProfileProvider).value?.isAdmin ?? false;
    final duty = ref.read(myDutyProvider);
    final today = _today(ref.read);
    final picked = await pickDay(
      context,
      initial: _date,
      first: isAdmin ? _date.addDays(-365) : today,
      last: isAdmin ? _date.addDays(365) : duty.lastDay ?? today,
      selectable: isAdmin ? null : duty.coversDay,
    );
    if (picked != null && mounted) {
      setState(() {
        _picked = picked;
        _blockId = null;
      });
    }
  }

  /// Sends to the day ([blockId] null) or one of its blocks.
  Future<void> _send(String? blockId, String text) async {
    if (_sending) return;
    final date = _date;
    final asDuty = _offeredAsDuty;
    setState(() => _sending = true);
    final sent = await _sendFromSheet(
      context,
      () => widget.send(
        kind: MessageKind.message,
        audience: blockId == null ? MessageAudience.day : MessageAudience.block,
        onDate: date,
        blockId: blockId,
        body: text,
      ),
      errorText: (e) =>
          staffSendErrorText(e, toBlock: blockId != null, asDuty: asDuty),
    );
    if (!sent && mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(myProfileProvider).value;
    final isAdmin = me?.isAdmin ?? false;
    // A duty writes on the strength of a period of their own — serving
    // today or not (`duty_edit_gate`).
    final hasDutyPeriod =
        ref.watch(myDutyProvider).mine.isNotEmpty && !isAdmin;
    _offeredAsDuty = _offeredAsDuty || hasDutyPeriod;
    // The default day follows the clock once it lands.
    ref.watch(nowProvider);
    final monday = _mondayOf(_date);
    final week = ref.watch(weekScheduleProvider(monday)).value;
    final loadedReservations = ref.watch(weekReservationsProvider(monday)).value;
    final reservations = loadedReservations ?? const <Reservation>[];
    final players = ref.watch(playersProvider).value;
    // Until the week's reservations and the roster are in, nobody's count
    // is known: no „Nikdo nemá rezervaci“ (nor a disabled target) for what
    // is only loading, and nothing to send.
    final known = loadedReservations != null && players != null;
    final names = {for (final p in players ?? const []) p.id: p.displayName};
    final members = players == null
        ? null
        : {
            for (final p in players)
              if (p.hasAccount) p.id,
          };
    // The week runs Monday..Sunday. No blocks on a closed day, nor from
    // the placeholder grid (its ids are not the server's).
    final dayBlocks = week != null && week.blocksFromDb
        ? switch (week.week.days[_date.weekday - 1]) {
            OpenDay(:final blocks) => blocks,
            ClosedDay() => const <TimeBlock>[],
          }
        : const <TimeBlock>[];
    // A prefilled block this day does not (yet) list reads as „Celý den“.
    final blockId = dayBlocks.any((b) => b.id == _blockId) ? _blockId : null;

    // Who `message_send` would pick: the author left out, players without
    // an account too; Czech-sorted.
    List<String> recipients(String? blockId) => [
      for (final id in dayRecipientIds(
        reservations,
        date: _date,
        blockId: blockId,
        meId: me?.id,
        members: members,
      ))
        ?names[id],
    ]..sort(compareCzech);

    // „Dostane 2 hráči: …“ under each target once known; a target nobody
    // would get is disabled (spec: 0 → disabled, „Nikdo nemá rezervaci“).
    Widget? preview(String? blockId) =>
        known ? Text(recipientPreviewLabel(recipients(blockId))) : null;
    bool pickable(String? blockId) =>
        !known || recipients(blockId).isNotEmpty;

    final text = _body.text.trim();
    // Not before the day's blocks are known: a prefilled block would
    // otherwise go out as „Celý den“.
    final canSend =
        known &&
        week != null &&
        text.isNotEmpty &&
        !overLimit(text, messageBodyMax) &&
        recipients(blockId).isNotEmpty;
    return _SheetFrame(
      children: [
        Text('Napsat hráčům', style: Theme.of(context).textTheme.titleMedium),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('${_date.day}. ${_date.month}. ${_date.year}'),
          trailing: TextButton(
            onPressed: _pickDate,
            child: const Text('Změnit'),
          ),
        ),
        RadioGroup<String?>(
          groupValue: blockId,
          onChanged: (v) => setState(() => _blockId = v),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<String?>(
                title: const Text('Celý den'),
                subtitle: preview(null),
                value: null,
                enabled: pickable(null),
              ),
              for (final b in dayBlocks)
                RadioListTile<String?>(
                  title: Text(b.label),
                  subtitle: preview(b.id),
                  value: b.id,
                  enabled: pickable(b.id),
                ),
            ],
          ),
        ),
        _BodyField(controller: _body, onChanged: () => setState(() {})),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: canSend && !_sending
                ? () => _send(blockId, text)
                : null,
            child: const Text('Odeslat'),
          ),
        ),
      ],
    );
  }
}
