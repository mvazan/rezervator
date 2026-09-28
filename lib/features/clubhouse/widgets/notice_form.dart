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
import '../../../domain/models.dart';

/// Opens the notice form; true once a notice was posted or saved.
Future<bool> showNoticeForm(BuildContext context, {Message? existing}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => _NoticeForm(existing: existing),
  );
  return result ?? false;
}

/// „Platí do 16. 10.“ means through that day: the notice expires at its
/// last second, local time, not at the midnight that starts it.
DateTime _endOfDay(Day d) => DateTime(d.year, d.month, d.day, 23, 59, 59);

class _NoticeForm extends ConsumerStatefulWidget {
  const _NoticeForm({this.existing});

  final Message? existing;

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
  bool _saving = false;

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

  Future<void> _save() async {
    setState(() => _saving = true);
    final title = _title.text.trim();
    final body = _body.text.trim();
    final expiresAt = _forever ? null : _expiresAt;
    final existing = widget.existing;
    final ok = await tryAction(
      context,
      () => existing == null
          ? Api.messageSend(
              kind: MessageKind.notice,
              audience: MessageAudience.all,
              title: title,
              body: body,
              expiresAt: expiresAt,
              notify: _notify,
            )
          : Api.messageUpdate(
              existing.id,
              title: title,
              body: body,
              expiresAt: expiresAt,
            ),
      success: existing == null ? 'Oznam vyvěšen.' : 'Oznam uložen.',
      errorText: friendlyDbError,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final until = _forever
        ? 'do odvolání'
        : '${_expiresAt.day}. ${_expiresAt.month}. ${_expiresAt.year}';
    return AlertDialog(
      title: Text(widget.existing == null ? 'Nový oznam' : 'Upravit oznam'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _title,
                decoration: const InputDecoration(labelText: 'Nadpis'),
                maxLength: 80,
              ),
              TextField(
                controller: _body,
                decoration: const InputDecoration(labelText: 'Text'),
                maxLength: 2000,
                maxLines: 5,
                minLines: 1,
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
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Ukládám…' : 'Uložit'),
        ),
      ],
    );
  }
}
