import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'changelog_data.dart';

// Release-notes data (Release, appChangelog) lives in changelog_data.dart
// so CI tooling can read it without Flutter; re-exported for existing
// call sites that import this file.
export 'changelog_data.dart';

/// Bottom sheet with the release history. [web] decides how it reads: the
/// web is deployed continuously, so it lists batches by the day they went
/// live (the newest may be in no app version yet), while the app lists
/// versions, which is what its user actually has installed.
void showChangelog(BuildContext context, {bool web = kIsWeb}) {
  final entries = changelogFor(web: web);
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
          if (web) ...[
            const SizedBox(height: 4),
            Text(
              'Web se aktualizuje průběžně, mobilní appka po verzích.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 8),
          for (final release in entries) ...[
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: Text(
                changelogHeading(release, web: web),
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
