/// Small shared UI helpers: Czech date labels, snackbars, dialogs, external
/// launches.
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/models.dart';

const weekdaysShort = ['po', 'út', 'st', 'čt', 'pá', 'so', 'ne'];
const _weekdaysFull = [
  'pondělí',
  'úterý',
  'středa',
  'čtvrtek',
  'pátek',
  'sobota',
  'neděle',
];

/// Czech month names, 1-indexed (index 0 unused so `monthsFull[month]` works
/// directly with a 1–12 month number).
const monthsFull = [
  '',
  'leden',
  'únor',
  'březen',
  'duben',
  'květen',
  'červen',
  'červenec',
  'srpen',
  'září',
  'říjen',
  'listopad',
  'prosinec',
];

/// "čt 23.4."
String dayLabel(Day d) =>
    '${weekdaysShort[d.weekday - 1]} ${d.day}.${d.month}.';

/// "čtvrtek 23. 4."
String dayFull(Day d) =>
    '${_weekdaysFull[d.weekday - 1]} ${d.day}. ${d.month}.';

/// Full Czech weekday name for an ISO weekday (1 = pondělí … 7 = neděle).
String weekdayFull(int weekday) => _weekdaysFull[weekday - 1];

Day today() => Day.fromDateTime(DateTime.now());

/// Two-letter avatar initials for [displayName]: first letter of the first
/// two words, uppercased. A single-word name uses its first two characters;
/// an empty name falls back to '?'.
String initialsOf(String displayName) {
  final words =
      displayName.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  if (words.isEmpty) return '?';
  if (words.length == 1) {
    final word = words.first;
    return word.length >= 2
        ? word.substring(0, 2).toUpperCase()
        : word.toUpperCase();
  }
  return (words.first.substring(0, 1) + words.elementAt(1).substring(0, 1))
      .toUpperCase();
}

void snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

/// Maps the schema's `raise exception` codes to Czech user copy.
String friendlyDbError(Object error) {
  final raw = '$error';
  const messages = {
    'slot_taken': 'Termín je už obsazený.',
    'limit_reached': 'Máš už maximální počet rezervací.',
    'beyond_horizon': 'Tak daleko dopředu zatím rezervovat nejde.',
    'date_past': 'Tenhle termín už je v minulosti.',
    'day_closed': 'V tento den je zavřeno.',
    'blocked_by_match': 'V tomhle čase se hraje zápas.',
    'blocked_by_rental': 'Dráha je v tomhle čase pronajatá.',
    'too_late': 'Trénink už začal — rezervaci může zrušit jen správce.',
    'unknown_block': 'Tenhle blok už neplatí — mrkni na aktuální rozvrh.',
    'invalid_block': 'Tenhle blok už neplatí — mrkni na aktuální rozvrh.',
    'invalid_lane': 'Tahle dráha neexistuje.',
    'player_not_approved': 'Hráč ještě není schválený.',
    'not_allowed': 'Na tohle nemáš oprávnění.',
    'cannot_demote_self': 'Sám sebe správcovství nezbavíš.',
    'nick_too_long': 'Zkratka je moc dlouhá (max 14 znaků).',
  };
  for (final entry in messages.entries) {
    if (raw.contains(entry.key)) return entry.value;
  }
  return 'Něco se nepovedlo. ($error)';
}

/// Runs [action]; on failure shows the error as a snackbar.
/// Returns true when the action succeeded.
Future<bool> tryAction(
  BuildContext context,
  Future<void> Function() action, {
  String? success,
  String Function(Object)? errorText,
}) async {
  try {
    await action();
    if (success != null && context.mounted) snack(context, success);
    return true;
  } catch (e) {
    if (context.mounted) {
      snack(context, errorText != null ? errorText(e) : 'Nepovedlo se: $e');
    }
    return false;
  }
}

/// Standard confirm dialog; resolves to true when [confirmLabel] was tapped.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Ano',
  String cancelLabel = 'Zrušit',
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// Single-field text prompt; resolves to the trimmed input, or null on cancel.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String? hint,
  String? initial,
  String confirmLabel = 'Uložit',
  TextInputType? keyboardType,
  String? suffixText,
}) async {
  final controller = TextEditingController(text: initial);
  try {
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: keyboardType,
          decoration: InputDecoration(hintText: hint, suffixText: suffixText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Zrušit'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result;
  } finally {
    controller.dispose();
  }
}

/// Shows the platform time picker forced to 24h display, returning a
/// [HourMinute] (or null on cancel).
Future<HourMinute?> pickTime(
  BuildContext context, {
  HourMinute? initial,
}) async {
  final now = TimeOfDay.now();
  final picked = await showTimePicker(
    context: context,
    initialTime: initial == null
        ? now
        : TimeOfDay(hour: initial.hour, minute: initial.minute),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
      child: child!,
    ),
  );
  if (picked == null) return null;
  return HourMinute(picked.hour, picked.minute);
}

void launchEmail(String address) =>
    _launchExternal(Uri.parse('mailto:$address'));

void launchPhone(String number) =>
    _launchExternal(Uri.parse('tel:${number.replaceAll(' ', '')}'));

void launchWeb(String url) =>
    _launchExternal(Uri.parse(url.contains('://') ? url : 'https://$url'));

void _launchExternal(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);
