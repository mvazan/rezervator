import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../core/widgets/auth_background.dart';
import '../../data/providers.dart';
import '../../domain/limits.dart';
import '../../domain/models.dart';
import '../../domain/phone.dart';

/// Sentinel dropdown value for "found a brand-new alley".
const _newTenant = '+new';

/// First sign-in: pick an existing alley (kuželna) — or found a new one —
/// plus a display name, optional board nick and phone and, for an existing
/// alley, a club from its actual club list. A new alley's founder becomes
/// its admin right away; everyone else waits for the admin's approval.
class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({
    super.key,
    this.registerProfile = Api.registerProfile,
    this.createTenantAndRegister = Api.createTenantAndRegister,
  });

  /// Injectable for widget tests (the Api ones need a live Supabase client).
  final Future<void> Function(String displayName, String tenantId,
      {String? clubId, String nick, String? phone}) registerProfile;
  final Future<void> Function(String tenantName, String displayName,
      {String nick, String? phone}) createTenantAndRegister;

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _tenantName = TextEditingController();
  final _name = TextEditingController();
  final _nick = TextEditingController();
  final _phone = TextEditingController();
  String? _phoneError;
  String? _tenantId;
  String? _clubId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Alleys loaded before this screen opened: the future won't report
    // again, so preselect from the current value; ref.listen in build
    // covers the list arriving later.
    _tenantId = _lonePreselect(ref.read(tenantsProvider).value);
  }

  @override
  void dispose() {
    _tenantName.dispose();
    _name.dispose();
    _nick.dispose();
    _phone.dispose();
    super.dispose();
  }

  /// With exactly one alley (the common case) preselect it silently: its id
  /// — or null when there isn't exactly one, or the user has picked already.
  String? _lonePreselect(List<Tenant>? tenants) =>
      _tenantId == null && tenants != null && tenants.length == 1
          ? tenants.single.id
          : null;

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
    if (tenantId == _newTenant && _tenantName.text.trim().isEmpty) {
      snack(context, 'Napiš název nové kuželny.');
      return;
    }
    final typedPhone = _phone.text.trim();
    final phone = typedPhone.isEmpty ? null : normalizePhone(typedPhone);
    if (typedPhone.isNotEmpty && phone == null) {
      setState(() => _phoneError = invalidPhoneMessage);
      return;
    }
    setState(() => _saving = true);
    await tryAction(
      context,
      () async {
        if (tenantId == _newTenant) {
          await widget.createTenantAndRegister(_tenantName.text.trim(), name,
              nick: _nick.text.trim(), phone: phone);
        } else {
          await widget.registerProfile(name, tenantId,
              clubId: _clubId, nick: _nick.text.trim(), phone: phone);
        }
      },
      errorText: friendlyDbError,
    );
    // AuthGate re-routes automatically via the profile stream.
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(tenantsProvider, (_, next) {
      final id = _lonePreselect(next.value);
      if (id != null) setState(() => _tenantId = id);
    });
    final tenants = ref.watch(tenantsProvider).value ?? const <Tenant>[];
    final foundingNew = _tenantId == _newTenant;
    final clubs = !foundingNew && _tenantId != null
        ? ref.watch(registrationClubsProvider(_tenantId!)).value ??
            const <Club>[]
        : const <Club>[];

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
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Kuželna',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final tenant in tenants)
                    DropdownMenuItem(
                        value: tenant.id, child: Text(tenant.name)),
                  const DropdownMenuItem(
                      value: _newTenant, child: Text('➕ Založit novou kuželnu')),
                ],
                onChanged: (id) => setState(() {
                  _tenantId = id;
                  _clubId = null; // clubs belong to the picked alley
                }),
              ),
              if (foundingNew) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _tenantName,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Název nové kuželny',
                    helperText: 'Staneš se jejím správcem.',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
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
                controller: _nick,
                maxLength: Limits.nickLength,
                decoration: const InputDecoration(
                  labelText: 'Přezdívka na tabuli (nepovinné)',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: 'Telefon (nepovinné)',
                  // show_phone starts on (0048): say so where the number is
                  // given, not only on the Kontakty page it lands on.
                  helperText: 'Uvidí ho ostatní hráči kuželny v Kontaktech. '
                      'Skrýt ho můžeš v Můj profil.',
                  helperMaxLines: 2,
                  border: const OutlineInputBorder(),
                  errorText: _phoneError,
                ),
                onChanged: (_) {
                  if (_phoneError != null) setState(() => _phoneError = null);
                },
              ),
              if (clubs.isNotEmpty) ...[
                const SizedBox(height: 16),
                DropdownButtonFormField<String?>(
                  initialValue: _clubId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Oddíl / klub',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(
                        value: null, child: Text('Bez oddílu')),
                    for (final club in clubs)
                      DropdownMenuItem(
                          value: club.id, child: Text(club.name)),
                  ],
                  onChanged: (id) => setState(() => _clubId = id),
                ),
              ],
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
