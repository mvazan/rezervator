import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../core/ui.dart';

/// Blocking screen shown while this build is older than the backend's
/// `app_config.min_build` (0025) — the force-update lever for breaking
/// releases. The auth gate swaps the whole app for it, so an outdated build
/// stops calling the server the moment the bump arrives.
class UpdateScreen extends StatelessWidget {
  const UpdateScreen({super.key});

  /// Play listing — where the update lives.
  static const playUrl =
      'https://play.google.com/store/apps/details?id=cz.kuzelky.rezervator';

  /// The web is deployed automatically; a reload fetches the current build.
  static const webUrl = 'https://mvazan.github.io/rezervator/';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🆕', style: TextStyle(fontSize: 48)),
              const SizedBox(height: 16),
              Text('Je potřeba aktualizace',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                kIsWeb
                    ? 'Tahle verze aplikace už nestačí na novější server.\n'
                        'Načti stránku znovu a jedeme dál.'
                    : 'Tahle verze aplikace už nestačí na novější server.\n'
                        'Aktualizuj v Google Play a jedeme dál.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: Icon(kIsWeb ? Icons.refresh : Icons.system_update),
                label: Text(kIsWeb ? 'Znovu načíst' : 'Otevřít Google Play'),
                onPressed: () => launchWeb(kIsWeb ? webUrl : playUrl),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
