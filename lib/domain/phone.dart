/// A player's phone number (0048): what they type at registration or in
/// Můj profil, stored the one way the database accepts —
/// international E.164, `+<digits>` (`profiles_phone_check`) — and shown
/// back readable. Pure Dart, unit-tested.
library;

/// The database's own rule (`profiles_phone_check`, `register_profile`):
/// a plus, a non-zero first digit, 8 to 15 digits in all.
final e164Pattern = RegExp(r'^\+[1-9][0-9]{7,14}$');

/// What the app says to a phone it cannot read — inline in the forms, and
/// for the server's own `invalid_phone` (friendlyDbError).
const invalidPhoneMessage =
    'Telefon nemá správný tvar — třeba +420 777 123 456.';

/// [input] in E.164, or null when it cannot be one. Spaces, dashes, dots
/// and brackets go; a leading `00` becomes `+`; a bare nine-digit number is
/// Czech and gets `+420`. An empty [input] is null too — the caller decides
/// whether that means "no phone" (it does, in both forms).
String? normalizePhone(String input) {
  var s = input.replaceAll(RegExp(r'[\s\-.()]'), '');
  if (s.startsWith('00')) {
    s = '+${s.substring(2)}';
  } else if (RegExp(r'^[0-9]{9}$').hasMatch(s)) {
    s = '+420$s';
  }
  return e164Pattern.hasMatch(s) ? s : null;
}

/// [e164] for reading: a Czech number grouped `+420 777 123 456`, any
/// other exactly as stored.
String formatPhone(String e164) {
  final m = RegExp(r'^\+420([0-9]{3})([0-9]{3})([0-9]{3})$').firstMatch(e164);
  return m == null ? e164 : '+420 ${m[1]} ${m[2]} ${m[3]}';
}

/// A WhatsApp chat with [e164]: `https://wa.me/<digits without the plus>`.
Uri whatsappUri(String e164) =>
    Uri.parse('https://wa.me/${e164.replaceAll('+', '')}');
