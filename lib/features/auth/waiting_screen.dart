import 'package:flutter/material.dart';

import '../../core/widgets/auth_background.dart';
import '../../data/providers.dart';

/// Shown while the profile is pending. Any approved member's one tap flips
/// the profile stream and AuthGate lets the user in automatically.
class WaitingScreen extends StatelessWidget {
  const WaitingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AuthBackground(
        child: AuthCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🕰️', style: TextStyle(fontSize: 48)),
              const SizedBox(height: 16),
              Text(
                'Čekáš na schválení',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              const Text(
                'Správci přišlo upozornění, že ses zaregistroval(a).\n'
                'Jakmile tě schválí, pustíme tě dál — obrazovka se přepne sama.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: Api.signOut,
                child: const Text('Odhlásit se'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
