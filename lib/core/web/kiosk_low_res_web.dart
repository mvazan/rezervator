import 'package:web/web.dart' as web;

/// Read by web/index.html before Flutter starts — keep the two in step.
const _key = 'rezervator.kiosk.lowRes';

/// Stores [on] and reloads when the page started with the other choice.
void setKioskLowRes(bool on) {
  try {
    final storage = web.window.localStorage;
    if ((storage.getItem(_key) == '1') == on) return;
    if (on) {
      storage.setItem(_key, '1');
    } else {
      storage.removeItem(_key);
    }
    web.window.location.reload();
  } catch (_) {
    // No storage (a private window): the kiosk keeps the ratio it has.
  }
}
