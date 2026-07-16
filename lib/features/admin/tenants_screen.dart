import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import 'widgets/admin_body.dart';

/// SUPERADMIN only (0014): the kuželny hub. Pending kuželny get approved
/// (or rejected — deleted whole) here, and the superadmin can switch their
/// own membership into any kuželna to inspect its data and boards with full
/// admin rights; switching back works the same way.
class TenantsScreen extends ConsumerWidget {
  const TenantsScreen({super.key});

  Future<void> _approve(
      BuildContext context, WidgetRef ref, AdminTenant t) async {
    final ok = await tryAction(
      context,
      () => Api.approveTenant(t.id),
      success: 'Kuželna „${t.name}" schválena.',
      errorText: friendlyDbError,
    );
    if (ok) {
      ref.invalidate(adminTenantsProvider);
      ref.invalidate(tenantsProvider);
    }
  }

  Future<void> _reject(
      BuildContext context, WidgetRef ref, AdminTenant t) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Zamítnout kuželnu?',
      message: 'Kuželna „${t.name}" bude smazána včetně zakladatele '
          '(${t.founderEmail}). Zakladatel se pak může zaregistrovat znovu.',
      confirmLabel: 'Zamítnout a smazat',
    );
    if (!confirmed || !context.mounted) return;
    final ok = await tryAction(
      context,
      () => Api.rejectTenant(t.id),
      success: 'Kuželna zamítnuta a smazána.',
      errorText: friendlyDbError,
    );
    if (ok) ref.invalidate(adminTenantsProvider);
  }

  Future<void> _switch(
      BuildContext context, WidgetRef ref, AdminTenant t) async {
    final ok = await tryAction(
      context,
      () => Api.switchTenant(t.id),
      success: 'Přepnuto do „${t.name}".',
      errorText: friendlyDbError,
    );
    if (!ok || !context.mounted) return;
    // Every stream fetched its rows under the OLD kuželna — re-create them
    // and drop back to the root so the whole app re-reads as the new one.
    resetTenantScopedProviders(ref);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(myProfileProvider).value;
    if (me?.isSuperadmin != true) {
      return Scaffold(
        appBar: AppBar(title: const Text('Kuželny')),
        body: const Center(child: Text('Jen pro správce aplikace.')),
      );
    }

    final tenants = ref.watch(adminTenantsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Kuželny')),
      body: AdminBody(
        child: tenants.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text(friendlyDbError(e))),
          data: (rows) {
            final pending = [for (final t in rows) if (t.pending) t];
            final approved = [for (final t in rows) if (!t.pending) t];
            return ListView(
              children: [
                if (pending.isNotEmpty) ...[
                  const _SectionLabel('Čekají na schválení'),
                  for (final t in pending)
                    _TenantTile(
                      tenant: t,
                      isCurrent: t.id == me!.tenantId,
                      onApprove: () => _approve(context, ref, t),
                      onReject: () => _reject(context, ref, t),
                      onSwitch: () => _switch(context, ref, t),
                    ),
                ],
                _SectionLabel('Aktivní (${approved.length})'),
                for (final t in approved)
                  _TenantTile(
                    tenant: t,
                    isCurrent: t.id == me!.tenantId,
                    onSwitch: () => _switch(context, ref, t),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );
}

/// One kuželna row: name (+ "aktuální" chip for the one the superadmin is
/// currently in), founder + member count, and the actions — approve/reject
/// for pending, switch for everything else.
class _TenantTile extends StatelessWidget {
  const _TenantTile({
    required this.tenant,
    required this.isCurrent,
    required this.onSwitch,
    this.onApprove,
    this.onReject,
  });

  final AdminTenant tenant;
  final bool isCurrent;
  final VoidCallback onSwitch;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        title: Row(
          children: [
            Flexible(
              child: Text(tenant.name, overflow: TextOverflow.ellipsis),
            ),
            if (isCurrent) ...[
              const SizedBox(width: 8),
              Chip(
                label: const Text('aktuální'),
                visualDensity: VisualDensity.compact,
                labelStyle: TextStyle(
                  fontSize: 11,
                  color: scheme.onPrimaryContainer,
                ),
                backgroundColor: scheme.primaryContainer,
                side: BorderSide.none,
              ),
            ],
          ],
        ),
        subtitle: Text([
          if (tenant.founderEmail.isNotEmpty) tenant.founderEmail,
          '${tenant.memberCount} členů',
        ].join(' · ')),
        trailing: tenant.pending
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Zamítnout a smazat',
                    onPressed: onReject,
                  ),
                  FilledButton(
                    onPressed: onApprove,
                    child: const Text('Schválit'),
                  ),
                ],
              )
            : isCurrent
                ? null
                : TextButton(
                    onPressed: onSwitch,
                    child: const Text('Přepnout se'),
                  ),
        // A pending kuželna is switchable too — inspecting it before the
        // approval is the point; tap the row itself.
        onTap: tenant.pending && !isCurrent ? onSwitch : null,
      ),
    );
  }
}
