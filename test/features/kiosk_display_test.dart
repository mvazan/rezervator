import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/features/kiosk/kiosk_display.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

/// Stands in for the wake-lock plugin: records what it was asked, in order.
class _WakelockRecorder extends WakelockPlusPlatformInterface {
  final log = <String>[];

  /// Thrown by the next request — a platform without a wake lock.
  Object? refuseWith;

  @override
  Future<void> toggle({required bool enable}) async {
    if (refuseWith != null) throw refuseWith!;
    log.add(enable ? 'wake on' : 'wake off');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // One recorder for the whole file: the plugin keeps the platform instance
  // it first saw, so a fresh one per test would go unheard.
  final wakelock = _WakelockRecorder();
  WakelockPlusPlatformInterface.instance = wakelock;
  late List<String> bars;

  setUp(() {
    wakelock.log.clear();
    wakelock.refuseWith = null;
    bars = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method.startsWith('SystemChrome.setEnabledSystemUI')) {
            bars.add('${call.method} ${call.arguments}');
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('hold keeps the screen on and hides both system bars', () async {
    await const KioskDisplay().hold();

    expect(wakelock.log, ['wake on']);
    expect(bars, [
      'SystemChrome.setEnabledSystemUIMode SystemUiMode.immersiveSticky',
    ]);
  });

  test('release lets the screen sleep and shows both bars again', () async {
    await const KioskDisplay().release();

    expect(wakelock.log, ['wake off']);
    expect(bars, [
      'SystemChrome.setEnabledSystemUIOverlays '
          '[SystemUiOverlay.top, SystemUiOverlay.bottom]',
    ]);
  });

  test('a display without a wake lock still gets its bars hidden', () async {
    wakelock.refuseWith = PlatformException(code: 'unsupported');

    await const KioskDisplay().hold();

    expect(wakelock.log, isEmpty);
    expect(bars, hasLength(1));
  });
}
