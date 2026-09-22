/// Správa → Veřejný přehled (0043): the admin publishes the alley's week
/// board at its own address — occupancy only, no names — or takes it down.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/kiosk_url.dart';
import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/public_week.dart';
import '../../domain/slug.dart';
import '../auth/update_screen.dart' show UpdateScreen;
import 'widgets/admin_scaffold.dart';
import 'widgets/copyable_address.dart';

class PublicOverviewScreen extends ConsumerStatefulWidget {
  const PublicOverviewScreen({super.key, this.save = Api.setPublicOverview});

  /// Injectable so a widget test can drive Uložit without the backend.
  final Future<void> Function(String slug, bool enabled) save;

  @override
  ConsumerState<PublicOverviewScreen> createState() =>
      _PublicOverviewScreenState();
}

class _PublicOverviewScreenState extends ConsumerState<PublicOverviewScreen> {
  final _slug = TextEditingController();
  bool _enabled = false;

  /// The form is filled from the server once; after that it is the admin's
  /// until Uložit (a reload after saving must not undo their typing).
  bool _seeded = false;

  @override
  void dispose() {
    _slug.dispose();
    super.dispose();
  }

  /// Where the app runs (the web build knows) — on Android the public web
  /// app, as for the kiosk address.
  Uri get _appUrl => kIsWeb ? Uri.base : Uri.parse(UpdateScreen.webUrl);

  void _seed(PublicOverview o) {
    if (_seeded) return;
    _seeded = true;
    _slug.text = o.slug ?? suggestSlug(o.tenantName);
    _enabled = o.enabled;
  }

  Future<void> _save() async {
    final ok = await tryAction(
      context,
      () => widget.save(_slug.text.trim().toLowerCase(), _enabled),
      success: 'Uloženo.',
      errorText: friendlyDbError,
    );
    if (ok && mounted) ref.invalidate(publicOverviewProvider);
  }

  @override
  Widget build(BuildContext context) {
    return AdminScaffold(
      title: 'Veřejný přehled',
      body: AsyncBody(
        value: ref.watch(publicOverviewProvider),
        onRetry: () => ref.invalidate(publicOverviewProvider),
        builder: (o) {
          _seed(o);
          final slug = o.slug;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Rozvrh kuželny na vlastní adrese — pro kohokoli, bez '
                'přihlášení. Ukazuje jen obsazenost: jména hráčů ani nájemců '
                'na něm nejsou, zápasy ano.',
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Zveřejnit přehled'),
                value: _enabled,
                onChanged: (value) => setState(() => _enabled = value),
              ),
              TextField(
                controller: _slug,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Adresa',
                  prefixText: '…/prehled/',
                  helperText: '3–40 znaků: malá písmena, číslice a pomlčky.',
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _save,
                  child: const Text('Uložit'),
                ),
              ),
              if (o.enabled && slug != null) ...[
                const SizedBox(height: 24),
                Text('Odkaz na přehled',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                CopyableAddress(url: publicUrlFrom(_appUrl, slug)),
              ],
            ],
          );
        },
      ),
    );
  }
}
