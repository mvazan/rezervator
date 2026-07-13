import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import 'widgets/admin_body.dart';

/// Admin: kiosk-specific settings (today just the board theme; future kiosk
/// options land here rather than in the schedule settings).
class KioskSettingsScreen extends ConsumerWidget {
  const KioskSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    if (profile?.isAdmin != true) {
      return Scaffold(
        appBar: AppBar(title: const Text('Kiosk')),
        body: const Center(child: Text('Jen pro správce.')),
      );
    }

    final settings = ref.watch(settingsProvider).value;

    return Scaffold(
      appBar: AppBar(title: const Text('Kiosk')),
      body: AdminBody(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Kiosk: tmavý režim'),
              subtitle: const Text('Vypnuto = kiosková obrazovka světlá.'),
              value: settings?.kioskDark ?? true,
              onChanged: settings == null
                  ? null
                  : (value) => tryAction(
                      context,
                      () =>
                          Api.setKioskDark(value, tenantId: settings.tenantId),
                      errorText: friendlyDbError,
                    ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Kiosk: celý den na obrazovku'),
              subtitle: const Text(
                'Zapnuto = celý rozvrh dne se vejde na obrazovku bez '
                'posouvání. Vypnuto = sloty mají pohodlnou velikost a tabule '
                'se posouvá (po nečinnosti se sama vrátí na aktuální čas).',
              ),
              value: settings?.kioskFitDay ?? true,
              onChanged: settings == null
                  ? null
                  : (value) => tryAction(
                      context,
                      () => Api.setKioskFitDay(value,
                          tenantId: settings.tenantId),
                      errorText: friendlyDbError,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
