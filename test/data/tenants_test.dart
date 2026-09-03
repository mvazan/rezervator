import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/config.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';

void main() {
  test('registrableTenants hides the Play-review Demo alley and sorts by name',
      () {
    const demo = Tenant(id: AppConfig.demoTenantId, name: 'Demo');
    const vracov = Tenant(id: 't2', name: 'Kuželna Vracov');
    const first = Tenant(id: 't1', name: 'Kuželna č. 1');
    expect(registrableTenants([vracov, demo, first]), [first, vracov]);
  });

  test('registrableTenants leaves a lone real alley alone — the register '
      'screen preselects it', () {
    const only = Tenant(id: 't1', name: 'Kuželna č. 1');
    const demo = Tenant(id: AppConfig.demoTenantId, name: 'Demo');
    expect(registrableTenants([demo, only]), [only]);
  });
}
