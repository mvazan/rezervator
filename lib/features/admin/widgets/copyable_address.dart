/// An address, readable and copyable: selectable text so it can be read
/// aloud or picked apart on the web, one button for the clipboard. The
/// kiosk's and the public overview's.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/ui.dart';

class CopyableAddress extends StatelessWidget {
  const CopyableAddress({super.key, required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              url,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          IconButton(
            tooltip: 'Kopírovat adresu',
            icon: const Icon(Icons.copy_outlined),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: url));
              if (context.mounted) snack(context, 'Adresa zkopírována.');
            },
          ),
        ],
      ),
    );
  }
}
