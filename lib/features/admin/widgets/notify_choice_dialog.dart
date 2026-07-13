import 'package:flutter/material.dart';

/// The admin's per-change notification choice (phase 3): send the standard
/// wording, send a custom message, or stay silent (e.g. mid-way through a
/// multi-step reshuffle — only the final change should ping the players).
class NotifyChoice {
  const NotifyChoice({required this.notify, this.message});

  final bool notify;

  /// Custom message replacing the standard wording (null = standard). On a
  /// silent choice it still carries the entered text — a cancel note is
  /// worth keeping for the attendance audit even when nobody is pinged.
  final String? message;
}

/// Modal choice shown before an action that changes someone else's
/// reservation. Returns null when dismissed — the caller must treat that as
/// "abort the whole action", never as "proceed silently".
Future<NotifyChoice?> showNotifyChoiceDialog(
  BuildContext context, {
  required String title,
  required String summary,
  String messageLabel = 'Vlastní zpráva (nepovinná)',
  String sendLabel = 'Odeslat',
  String silentLabel = 'Neposílat',
}) =>
    showDialog<NotifyChoice>(
      context: context,
      builder: (_) => _NotifyChoiceDialog(
        title: title,
        summary: summary,
        messageLabel: messageLabel,
        sendLabel: sendLabel,
        silentLabel: silentLabel,
      ),
    );

class _NotifyChoiceDialog extends StatefulWidget {
  const _NotifyChoiceDialog({
    required this.title,
    required this.summary,
    required this.messageLabel,
    required this.sendLabel,
    required this.silentLabel,
  });

  final String title;
  final String summary;
  final String messageLabel;
  final String sendLabel;
  final String silentLabel;

  @override
  State<_NotifyChoiceDialog> createState() => _NotifyChoiceDialogState();
}

class _NotifyChoiceDialogState extends State<_NotifyChoiceDialog> {
  // Owned by the State so it outlives the route's exit animation (a
  // whenComplete dispose on the show future fires while the closing dialog
  // still renders the field).
  final _message = TextEditingController();

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  NotifyChoice _choice(bool notify) {
    final message = _message.text.trim();
    return NotifyChoice(
      notify: notify,
      message: message.isEmpty ? null : message,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.summary),
            const SizedBox(height: 12),
            TextField(
              controller: _message,
              decoration: InputDecoration(labelText: widget.messageLabel),
              maxLength: 200,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Zpět'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_choice(false)),
          child: Text(widget.silentLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_choice(true)),
          child: Text(widget.sendLabel),
        ),
      ],
    );
  }
}
