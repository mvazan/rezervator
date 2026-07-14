import 'package:flutter/material.dart';

import 'changelog_data.dart';

// Release-notes data (Release, appChangelog) lives in changelog_data.dart
// so CI tooling can read it without Flutter; re-exported for existing
// call sites that import this file.
export 'changelog_data.dart';

/// Bottom sheet with the release history.
void showChangelog(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Text('Co je nového',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          for (final release in appChangelog) ...[
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: Text(
                'verze ${release.version} · ${release.date}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            for (final change in release.changes)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 2),
                child: Text('• $change'),
              ),
          ],
        ],
      ),
    ),
  );
}
