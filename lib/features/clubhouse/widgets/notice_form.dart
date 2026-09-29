/// Klubovna → Nástěnka's admin form (0051): Nadpis, Text, Platí do (+14
/// days by default) with a "Do odvolání" switch, "Poslat upozornění" (new
/// notices only). showNoticeForm(existing: null) creates; with [existing]
/// it edits (the notify switch is hidden — message_update never resends).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/clock.dart';
import '../../../data/providers.dart';
import '../../../domain/messages.dart'
    show noticeBodyMax, noticeTitleMax, overLimit;
import '../../../domain/models.dart';
import '../../admin/widgets/form_dialog.dart';
import 'server_limit.dart';

/// What the form sends: the new notice, or [existing]'s new text and
/// expiry ([notify] is ignored on an edit — message_update never resends).
typedef NoticeDraft = ({
  String title,
  String body,
  DateTime? expiresAt,
  bool notify,
});

/// Opens the notice form; true once a notice was posted or saved. [write]
/// replaces the RPC (Api.messageSend / Api.messageUpdate), so widget tests
/// never reach `Supabase.instance`.
Future<bool> showNoticeForm(
  BuildContext context, {
  Message? existing,
  Future<void> Function(NoticeDraft draft)? write,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => _NoticeForm(existing: existing, write: write),
  );
  return result ?? false;
}

/// The form's own write: a new notice ([Api.messageSend], kind notice to
/// everyone) or [existing]'s full new state ([Api.messageUpdate]).
@visibleForTesting
Future<void> noticeApiWrite(Message? existing, NoticeDraft d) =>
    existing == null
    ? Api.messageSend(
        kind: MessageKind.notice,
        audience: MessageAudience.all,
        title: d.title,
        body: d.body,
        expiresAt: d.expiresAt,
        notify: d.notify,
      )
    : Api.messageUpdate(
        existing.id,
        title: d.title,
        body: d.body,
        expiresAt: d.expiresAt,
      );

/// „Platí do 16. 10.“ means through that day: the notice expires at its
/// last second, local time, not at the midnight that starts it.
DateTime _endOfDay(Day d) => DateTime(d.year, d.month, d.day, 23, 59, 59);

class _NoticeForm extends ConsumerStatefulWidget {
  const _NoticeForm({this.existing, this.write});

  final Message? existing;
  final Future<void> Function(NoticeDraft draft)? write;

  @override
  ConsumerState<_NoticeForm> createState() => _NoticeFormState();
}

class _NoticeFormState extends ConsumerState<_NoticeForm> {
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  late final _body = TextEditingController(text: widget.existing?.body ?? '');

  // +14 days from the app clock (nowProvider), so tests pin the default.
  late DateTime _expiresAt = widget.existing?.expiresAt?.toLocal() ??
      _endOfDay(Day.fromDateTime(
        (ref.read(nowProvider).value ?? DateTime.now())
            .add(const Duration(days: 14)),
      ));
  late bool _forever =
      widget.existing != null && widget.existing!.expiresAt == null;
  bool _notify = true;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _pickExpiry() async {
    final picked = await pickDay(
      context,
      initial: Day.fromDateTime(_expiresAt),
      first: today(),
      last: today().addDays(365),
    );
    if (picked != null) setState(() => _expiresAt = _endOfDay(picked));
  }

  /// FormDialog's onSave: true closes the form (through `closeDialog`),
  /// null keeps it open — [tryAction] already showed the error.
  Future<bool?> _save() async {
    final existing = widget.existing;
    final NoticeDraft draft = (
      title: _title.text.trim(),
      body: _body.text.trim(),
      expiresAt: _forever ? null : _expiresAt,
      notify: _notify,
    );
    final write = widget.write ?? (d) => noticeApiWrite(existing, d);
    final ok = await tryAction(
      context,
      () => write(draft),
      success: existing == null ? 'Oznam vyvěšen.' : 'Oznam uložen.',
      errorText: friendlyDbError,
    );
    return ok ? true : null;
  }

  @override
  Widget build(BuildContext context) {
    final until = _forever
        ? 'do odvolání'
        : '${_expiresAt.day}. ${_expiresAt.month}. ${_expiresAt.year}';
    // FormDialog, not a hand-rolled AlertDialog: while „Ukládám…“ runs the
    // fields (and „Změnit“) go quiet, and the form closes its OWN route —
    // a date picker opened mid-save, or a „Zrušit“ that already closed it,
    // must not catch the save's pop (Sentry REZERVATOR-4/5/6, closeDialog).
    return FormDialog<bool>(
      title: widget.existing == null ? 'Nový oznam' : 'Upravit oznam',
      onSave: _save,
      // Over the server's limit (code points, see withServerLimit) the
      // save could only earn title_too_long / body_too_long.
      saveEnabled: !overLimit(_title.text, noticeTitleMax) &&
          !overLimit(_body.text, noticeBodyMax),
      children: [
        // The form's width (400, less on a narrow phone): AlertDialog sizes
        // its content to the widest child.
        const SizedBox(width: 400),
        TextField(
          controller: _title,
          decoration: withServerLimit(
            context,
            const InputDecoration(labelText: 'Nadpis'),
            _title.text,
            noticeTitleMax,
          ),
          maxLength: noticeTitleMax,
          onChanged: (_) => setState(() {}),
        ),
        TextField(
          controller: _body,
          decoration: withServerLimit(
            context,
            const InputDecoration(labelText: 'Text'),
            _body.text,
            noticeBodyMax,
          ),
          maxLength: noticeBodyMax,
          maxLines: 5,
          minLines: 1,
          onChanged: (_) => setState(() {}),
        ),
        Row(
          children: [
            Expanded(child: Text('Platí do: $until')),
            if (!_forever)
              TextButton(
                onPressed: _pickExpiry,
                child: const Text('Změnit'),
              ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Do odvolání'),
          value: _forever,
          onChanged: (v) => setState(() => _forever = v),
        ),
        if (widget.existing == null)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Poslat upozornění'),
            value: _notify,
            onChanged: (v) => setState(() => _notify = v),
          ),
      ],
    );
  }
}
