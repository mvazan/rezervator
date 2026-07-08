import 'package:flutter/material.dart';

import '../../core/ui.dart';
import '../../core/widgets/auth_background.dart';
import '../../data/providers.dart';

/// First sign-in: pick a display name (and optionally a club). The very
/// first user becomes an auto-approved admin; everyone else waits for
/// admin approval.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _name = TextEditingController();
  final _club = TextEditingController();
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
    setState(() => _saving = true);
    await tryAction(
      context,
      () => Api.registerProfile(name, _club.text.trim()),
    );
    // AuthGate re-routes automatically via the profile stream.
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
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
