// Release-notes data — pure Dart (no Flutter import) so CI tooling
// (tool/whatsnew.dart) can read it without a Flutter runtime. The UI that
// renders these lives in changelog.dart.
//
// The two platforms ship differently and the notes say so: the WEB is
// deployed on every merge to main, so a change is live there the same day,
// while the ANDROID app gets it in the next release. An entry therefore
// starts life dated but without a version ("už na webu") and is stamped
// with the version when a release carries it — see PLAY.md.

/// One dated batch of user-facing changes, newest first — shown by tapping
/// the version line in Můj profil.
class Release {
  const Release(this.version, this.date, this.changes);

  /// The app version that carries these changes, or null while they are
  /// live on the web only. Null entries are the newest ones, so they sit at
  /// the top; the app hides them (an installed build does not have them).
  final String? version;

  /// When the change went live: on the web the day it was deployed, for a
  /// versioned entry the release day.
  final String date;

  final List<String> changes;
}

/// What to show: the web lists everything, the app only what a release
/// carries.
List<Release> changelogFor({required bool web}) => [
      for (final r in appChangelog)
        if (web || r.version != null) r,
    ];

/// Heading of one batch. The app leads with the version (that is what its
/// user has); the web leads with the date, because it has no versions —
/// only a stream of deploys.
String changelogHeading(Release r, {required bool web}) {
  if (!web) return 'verze ${r.version} · ${r.date}';
  return r.version == null
      ? '${r.date} · zatím jen na webu'
      : '${r.date} · verze ${r.version}';
}

const appChangelog = <Release>[
  Release('1.2.1', '6. 9. 2026', [
    'Kioskový účet se spravuje v Správa → Kiosk, ne mezi hráči — a je u něj '
        'vidět přihlašovací jméno.',
    'Když se heslo kiosku ztratí, jde odtamtud nastavit nové.',
    'Nový pohled Moje tréninky: co mě čeká — moje rezervace a zápasy mých '
        'týmů, po dnech. Na telefonu taby dole, na webu lišta vlevo.',
    'Na profilu je nová karta Moje týmy: vyber týmy, jejichž zápasy chceš '
        'vidět. Výběr pro Google kalendář zůstává u propojení kalendáře.',
    'Na profilu si nastavíš, jaký pohled se ti otevře po spuštění (kalendář, '
        'nebo Moje tréninky).',
    'Zápasy vybraných týmů se zapisují do Google Kalendáře — týmy si vybereš '
        'v Můj profil u propojení s kalendářem.',
    'Vybraná barva v paletě je konečně poznat (fajfka místo neviditelného '
        'kroužku).',
    'Web má vlastní adresu: rezervator.online.',
  ]),
  Release('1.2.0', '3. 9. 2026', [
    'Hráči bez e-mailu: správce je přidá a rezervuje jim, na kiosku si '
        'vyberou své jméno. Účet jde později sloučit.',
    'Propojení s Google Kalendářem — rezervace se zapisují samy, '
        'i s připomínkami.',
    'Rezervace mají barvu oddílu, vlastní si vybereš v profilu.',
    'Pronájmy zvládnou jednorázové výjimky v týdenní sérii.',
    'Zápasy chronologicky, odehrané schované dole.',
    'Rezervace za jiného hráče: hledání podle jména i přezdívky.',
  ]),
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
