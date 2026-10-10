/// A short text for the kiosk the admin types in a dialog (Správa →
/// Kiosk): one or a few lines, at most [showKioskTextDialog]'s
/// `maxLength` characters — the column's check. „Uložit“ pops the trimmed
/// text and stays off while it is blank; „Zrušit“ pops null.
library;

import 'package:flutter/material.dart';

/// Asks for the text, starting from [initial]. With [defaultText] a
/// „Výchozí text“ button puts that back into the field.
Future<String?> showKioskTextDialog(
  BuildContext context, {
  required String title,
  required String label,
  String? initial,
  int maxLength = 200,
  String? defaultText,
}) => showDialog<String>(
  context: context,
  builder: (_) => _KioskTextDialog(
    title: title,
    label: label,
    initial: initial ?? '',
    maxLength: maxLength,
    defaultText: defaultText,
  ),
);

class _KioskTextDialog extends StatefulWidget {
  const _KioskTextDialog({
    required this.title,
    required this.label,
    required this.initial,
    required this.maxLength,
    required this.defaultText,
  });

  final String title;
  final String label;
  final String initial;
  final int maxLength;
  final String? defaultText;

  @override
  State<_KioskTextDialog> createState() => _KioskTextDialogState();
}

class _KioskTextDialogState extends State<_KioskTextDialog> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// The default back in the field, the cursor after it.
  void _useDefault(String text) => setState(
    () => _text.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final text = _text.text.trim();
    final defaultText = widget.defaultText;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _text,
              autofocus: true,
              maxLength: widget.maxLength,
              minLines: 1,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: widget.label,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (defaultText != null)
              TextButton.icon(
                // Already the default: nothing to put back.
                onPressed: _text.text == defaultText
                    ? null
                    : () => _useDefault(defaultText),
                icon: const Icon(Icons.restore),
                label: const Text('Výchozí text'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: text.isEmpty ? null : () => Navigator.pop(context, text),
          child: const Text('Uložit'),
        ),
      ],
    );
  }
}
