/// The admin screens' shared frame: the role gate, the AppBar and the
/// width-limited body in one place, plus [AsyncBody] for the
/// loading/error/data shape every provider-backed list had been hand-
/// rolling (or worse, hiding behind `.value ?? []`).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import 'admin_body.dart';

/// Scaffold of an admin screen. Non-admins (or, with [superadminOnly],
/// non-superadmins) get the title bar and a one-line refusal instead of
/// [body]; the profile stream keeps the gate live.
class AdminScaffold extends ConsumerWidget {
  const AdminScaffold({
    super.key,
    required this.title,
    required this.body,
    this.floatingActionButton,
    this.actions = const [],
    this.superadminOnly = false,
  });

  final String title;
  final Widget body;
  final Widget? floatingActionButton;
  final List<Widget> actions;

  /// Superadmin-only screens (kuželny approval) refuse regular admins too.
  final bool superadminOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(myProfileProvider).value;
    final allowed =
        superadminOnly ? me?.isSuperadmin == true : me?.isAdmin == true;
    if (!allowed) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: Center(
          child: Text(
            superadminOnly ? 'Jen pro správce aplikace.' : 'Jen pro správce.',
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      body: AdminBody(child: body),
      floatingActionButton: floatingActionButton,
    );
  }
}

/// Renders an [AsyncValue]: a spinner while loading, the friendly error
/// (with an optional retry) on failure, [builder] with the data otherwise —
/// so an RLS or network error never masquerades as an empty list.
class AsyncBody<T> extends StatelessWidget {
  const AsyncBody({
    super.key,
    required this.value,
    required this.builder,
    this.onRetry,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return value.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(friendlyDbError(e), textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 8),
              FilledButton(
                onPressed: onRetry,
                child: const Text('Zkusit znovu'),
              ),
            ],
          ],
        ),
      ),
      data: builder,
    );
  }
}
