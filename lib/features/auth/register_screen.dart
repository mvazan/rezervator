import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../core/widgets/auth_background.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';

/// First sign-in: pick the alley (kuželna), a display name and optionally a
/// club. The alley's first approved-less registrant becomes its admin;
/// everyone else waits for that admin's approval.
class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _name = TextEditingController();
  final _club = TextEditingController();
  String? _tenantId;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _club.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      snack(context, 'Vyplň své jméno.');
      return;
    }
    final tenantId = _tenantId;
    if (tenantId == null) {
      snack(context, 'Vyber kuželnu.');
      return;
    }
    setState(() => _saving = true);
    await tryAction(
      context,
      () => Api.registerProfile(name, _club.text.trim(), tenantId),
    );
    // AuthGate re-routes automatically via the profile stream.
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final tenants = ref.watch(tenantsProvider).value ?? const <Tenant>[];
    // With exactly one alley (the common case) preselect it silently.
    if (_tenantId == null && tenants.length == 1) {
      _tenantId = tenants.single.id;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Vítej v Rezervátoru'),
        actions: [
          TextButton(onPressed: Api.signOut, child: const Text('Odhlásit')),
        ],
      ),
      body: AuthBackground(
        child: AuthCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Ještě tě neznáme. Napiš své jméno — pod ním tě uvidí '
                'ostatní v rozvrhu i na kiosku.',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 24),
              DropdownButtonFormField<String>(
                initialValue: _tenantId,
                decoration: const InputDecoration(
                  labelText: 'Kuželna',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final tenant in tenants)
                    DropdownMenuItem(
                        value: tenant.id, child: Text(tenant.name)),
                ],
                onChanged: (id) => setState(() => _tenantId = id),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Jméno a příjmení',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _club,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Oddíl / klub (nepovinné)',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _register(),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _saving ? null : _register,
                child: Text(_saving ? 'Ukládám…' : 'Zaregistrovat se'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
