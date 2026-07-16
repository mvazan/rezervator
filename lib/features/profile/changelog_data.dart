// Release-notes data — pure Dart (no Flutter import) so CI tooling
// (tool/whatsnew.dart) can read it without a Flutter runtime. The UI that
// renders these lives in changelog.dart.

/// User-facing release notes, newest first — shown by tapping the version
/// line in Můj profil. Kept by hand: add an entry with every release
/// (versions match the git tags).
class Release {
  const Release(this.version, this.date, this.changes);

  final String version;
  final String date;
  final List<String> changes;
}

const appChangelog = <Release>[
  Release('1.1.0', '15. 7. 2026', [
    'Nové kuželny nyní čekají na schválení správcem aplikace, než se '
        'mohou začít používat.',
  ]),
  Release('1.0.1', '14. 7. 2026', [
    'V Můj profil přibyl přehled verzí a novinek — klepni na číslo verze dole.',
    'Drobná vylepšení stability a hlášení chyb pro rychlejší opravy.',
  ]),
  Release('1.0.0', '14. 7. 2026', [
    'První verze: rezervace tréninků na kuželně, kalendářový rozvrh (den i '
        'týden), kioskový režim a správa kuželny.',
  ]),
];
