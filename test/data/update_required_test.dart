import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';

/// The force-update decision (0025): block only when BOTH numbers are known
/// and this build is older — an unreachable backend or a platform without
/// package info must never lock anyone out.
void main() {
  Future<ProviderContainer> container({int? minBuild, int? build}) async {
    final c = ProviderContainer(overrides: [
      minBuildProvider.overrideWith((ref) => Stream.value(minBuild)),
      appBuildProvider.overrideWith((ref) async => build),
    ]);
    addTearDown(c.dispose);
    c.listen(updateRequiredProvider, (_, _) {});
    await c.read(minBuildProvider.future);
    await c.read(appBuildProvider.future);
    return c;
  }

  test('older build than min_build → update required', () async {
    final c = await container(minBuild: 5, build: 3);
    expect(c.read(updateRequiredProvider), isTrue);
  });

  test('equal or newer build → not required', () async {
    expect((await container(minBuild: 5, build: 5)).read(updateRequiredProvider),
        isFalse);
    expect((await container(minBuild: 5, build: 9)).read(updateRequiredProvider),
        isFalse);
  });

  test('unknown min_build or unknown build → fail open', () async {
    expect((await container(minBuild: null, build: 3))
        .read(updateRequiredProvider), isFalse);
    expect((await container(minBuild: 5, build: null))
        .read(updateRequiredProvider), isFalse);
  });
}
