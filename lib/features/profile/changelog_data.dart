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
  const Release(this.version, this.date, this.changes, {this.store});

  /// The app version that carries these changes, or null while they are
  /// live on the web only. Null entries are the newest ones, so they sit at
  /// the top; the app hides them (an installed build does not have them).
  final String? version;

  /// When the change went live: on the web the day it was deployed, for a
  /// versioned entry the release day.
  final String date;

  final List<String> changes;

  /// Shorter bullets for Google Play's 500-character "What's new", written
  /// with the entry and reviewed in its PR. Needed only when [changes] do
  /// not fit whole — the automatic condensation would drop bullets from the
  /// end. The app always shows the full [changes].
  final List<String>? store;
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
  Release(null, '15. 10. 2026', [
    'Kiosk, záhlaví: každý údaj má nahoře nadpis a pod ním hodnotu, všechny '
        'v jedné řadě — hodiny s datem, počasí (nadpis napíše správce, třeba '
        '„Dnes v Brně“), svátek, nově služba na kantýně („Dnes má službu“ '
        'místo řádku pod hodinami) a nástěnka. Ve Správě → Kiosk → Záhlaví '
        'každému zvolíš, jestli je vlevo, nebo vpravo, a pořadí; dnešní '
        'zápasy jsou uprostřed, domácí nad venkovními.',
    'Kiosk: panely jsou dva, vlevo i vpravo od tabule. Ve Správě → Kiosk → '
        'Panely správce každému modulu (služba na kantýně, nástěnka, zápasy, '
        'Jak začít, Hráči týdne) určí panel, podíl na výšce a pořadí; každý '
        'panel má svou šířku a může začínat rozbalený. Volby seznamu zápasů '
        'mají svou sekci Zápasy.',
    'Kiosk: modul „Hráči týdne“ — nejlepší výkony našich hráčů za minulý '
        'týden v kategoriích muži a ženy na 120 a 100 hodů. Ťuknutí otevře '
        'celý týden podle kategorií, soutěží nebo oddílů, doma i venku, a '
        'z řádku zápis zápasu. Pohlaví hráčů je z registru ČKA.',
    'Kiosk: modul „Jak začít“ — jak si na kiosku zarezervovat trénink a kde '
        'je Rezervátor dál: aplikace pro Android (QR kód do Google Play) a web '
        'rezervator.online. Ťuknutí ukáže celý text s velkým QR kódem.',
    'Kiosk: hlavní tlačítko „Rezervace tréninku“ je větší a výraznější. Po '
        'výběru hráče záhlaví ukáže jeho přezdívku (bez rámečku) a postranní '
        'panely ustoupí tabuli.',
    'Kiosk, výběr hráče: správce zvolí, zda začíná písmeny, oddíly (dlaždice '
        'v barvě oddílu, hráči bez oddílu pod „Ostatní“), nebo obojím. '
        'Upozornění při rezervaci je širší a má méně řádků.',
    'Kiosk, hraný zápas v panelu: ťuk na „⟳ před … min“ obnoví výsledky; '
        'ikona se po ťuknutí točí, dokud nová data nedorazí.',
    'Kalendář a kiosk: zápas v rozvrhu má nahoře pohár a vedle něj čas, '
        'pod volným řádkem domácí, „x“ a hosty pod sebou.',
    'Zápasy dne (ťuk na záhlaví dne): pod zápasem čas a kuželna, kde se '
        'hraje, pod tím soutěž a kolo. Výsledek vpravo je větší a výraznější '
        'a kuželky stojí hned pod ním, dvojtečky pod sebou; pohár i výsledek '
        'jsou na výšku uprostřed zápasu.',
    'Kiosk: řádky drah na tabuli jsou jméno a pár pixelů kolem — nižší, '
        'takže se vejde víc hodin, a při celém dni na obrazovce mají větší '
        'písmo.',
    'Kalendář po dnech: čas bloku je začátek, pomlčka a konec pod sebou — '
        'v každém řádku stejně, i při větším písmu.',
    'Kiosk: seznam zápasů při posunu tabule neskáče — ukáže jen zápasy dnů, '
        'které na tabuli přibyly, a posune se jen o tolik, aby byly vidět.',
    'Výsledky, Soutěže: „Krajský přebor“ je na štítku zkrácený na KP.',
    'Výsledky, Oddíly: místo štítku pro každé družstvo nejdřív oddíl, pak '
        'jeho družstva písmenem (A, B, C…) nebo celý oddíl.',
    'Pronájmy: poznámka má víc řádků a kalendář ji ukáže pod nájemcem '
        'a časem, řádek po řádku (třeba které dráhy hrají který zápas). '
        'V seznamu termínů je pod časem a drahami.',
    'Kiosk, zápis zápasu: listování mezi odehranými zápasy — šipkami (v '
        'liště nad zápisem, nebo po stranách) i přejetím prstem; ťuk na '
        'družstvo ukáže jeho zápasy. Správce volí ve Správa → Kiosk → '
        'Listování v zápisu.',
    'Napište nám: v Klubovně je formulář pro zprávu autorovi aplikace — co '
        'v Rezervátoru chybí nebo nefunguje. Jméno a e-mail jsou předvyplněné '
        'a dají se smazat. Na webu jde formulář otevřít i bez přihlášení.',
    'Kiosk: modul „Napište nám“ — QR kód formuláře na webu, zprávu napíšeš '
        'v mobilu, ne na obrazovce kiosku. Ťuknutí ukáže velký kód. Správce '
        'ho umístí ve Správa → Kiosk → Panely.',
    'Oddíly mají přezdívku: správce ji zadá ve Správě → Oddíly a aplikace '
        'ji ukáže místo celého názvu — z „TJ Sokol Brno IV B“ je „Sokol IV '
        'B“ v rozvrhu, zápasech, výsledcích, na kiosku, v připomínkách i '
        'v Google kalendáři.',
    'Nástěnka: nejnovější oznam je nahoře — v aplikaci i na kiosku, také '
        'mezi sbalenými „Starší“. Naplánované oznamy zůstávají seřazené '
        'podle toho, kdy se zobrazí.',
    'Nástěnka v aplikaci: oznamy, které byly při otevření nepřečtené, mají '
        'štítek „Nové“ a barevný proužek vlevo — do odchodu z nástěnky; '
        'příště už jsou přečtené a bez označení.',
    'Kiosk: čerstvý oznam (vyvěšený před méně než 3 dny, počet dní nastaví '
        'správce) má štítek NOVÉ a barevný proužek, nebo zůstane na obrazovce '
        'dvakrát déle — volí správce ve Správě → Kiosk → Nástěnka, „Čerstvé '
        'oznamy“. Nově vyvěšený oznam kiosk ukáže hned.',
  ], store: [
    'Kiosk: přehlednější záhlaví, dva panely (Hráči týdne, Jak začít '
        'a Napište nám s QR).',
    'Kiosk: větší „Rezervace tréninku“, výběr podle oddílů, ⟳ obnoví '
        'výsledky, listování v zápisu, nižší řádky drah.',
    'Rozvrh a zápasy dne: pohár s časem, kuželna, soutěž a kolo.',
    'Kalendář: čas bloku pod sebou, poznámka pronájmu v pruhu.',
    'Výsledky: filtr podle oddílu, pak družstva.',
    'Klubovna: Napište nám — zpráva autorovi.',
    'Oddíly: přezdívka místo celého názvu.',
    'Nástěnka: nejnovější nahoře, nové se štítkem.',
  ]),
  Release(null, '14. 10. 2026', [
    'Kiosk, výběr hráče: písmena stojí v rovnoměrných řádcích (lichý zbytek '
        'dole) a „Ch“ má jako v abecedě vlastní dlaždici za H. Dotyky ve '
        'výběru se počítají jako aktivita, takže kdo se dlouho hledá, toho '
        'kiosk nevrátí na tabuli.',
    'Kiosk: upozornění v záhlaví i při rezervaci mají větší písmo (jako '
        'nápověda „Vyber první písmeno…“) a správce si jeho velikost nastaví. '
        'Přehled zápasů dne je širší, šířku také nastaví správce.',
  ]),
  Release(null, '12. 10. 2026', [
    'Kiosk: upozornění v záhlaví i upozornění při rezervaci mohou mít až '
        '300 znaků (dosud 200).',
  ]),
  Release(null, '11. 10. 2026', [
    'Kiosk: pás služby v kalendáři říká, co jména znamenají — „… má '
        'službu (12.–18. 10.)“.',
  ]),
  Release('2.0.8', '11. 10. 2026', [
    'Web: když máte Rezervátor otevřený ve více záložkách, přihlášení '
        'v jedné se zase přenese i do ostatních.',
    'Kiosk: zápis zápasu ukazuje i registrační čísla hráčů.',
    'Ikony v textu (⛔ blokace, 🏆 zápas, 🔒 pronájem, 👍/👎/💬 u zpráv a '
        'další) se kreslí z obrázků jako 🏠 — na webu vypadají všude stejně.',
    'Kiosk: volné místo v kalendáři značí stejné ＋ jako v kalendáři appky.',
    'Kiosk: displej nezhasne — v aplikaci pro Android i na webu, kde to '
        'prohlížeč umí — a aplikace pro Android schová systémové lišty.',
    'Aplikace pro Android: kiosk účet se přihlásí přes „Přihlásit kiosk“ '
        'dole na přihlašovací obrazovce (na webu má kiosk svou adresu).',
    'Správa → Kiosk: nová sekce Optimalizace výkonu pro slabší displej — '
        'vypnutí opakujících se animací (dýchající tlačítko panelu, pulzující '
        'ikona živého přenosu) a nižší rozlišení vykreslování na webu. Minulé '
        'dny na tabuli se kreslí levněji, vypadají stejně.',
    'Kiosk: zápas, který má na webu ČKA video na YouTube, si kdokoli pustí '
        'tlačítkem ▶ — živě i ze záznamu, i v zápasech dne na tabuli — '
        'v plovoucím okně vedle tabule. '
        'Okno jde posouvat, zvětšit na celou obrazovku, sbalit nebo křížkem '
        'zavřít; po konci videa se zavře samo. Správa → Kiosk → Stream '
        'zápasu: hraný zápas se může otevřít sám, oken může být víc '
        'najednou; správce může stream i celý vypnout.',
    'Kiosk: vedle hodin může být dnešní počasí (teplota, předpověď, '
        'deštník při šanci na srážky) a kdo má svátek — Správa → Kiosk → '
        'Stavový řádek; místo pro počasí je kuželna nebo vyhledaná obec.',
    'Kiosk: výběr jména radí, které písmeno vybrat — první písmeno '
        'přezdívky, nebo křestního jména, když přezdívka není.',
    'Kalendář a kiosk: zápas v rozvrhu píše pohár, domácí, pomlčku a hosty '
        'pod sebe — dlouhý název týmu se zalomí do více řádků, nerozdělí se '
        'v půlce. Velikost písma pásů na tabuli kiosku nastaví správce.',
    'Kiosk: správce může v záhlaví vedle hodin vyvěsit upozornění s ikonou '
        'výstrahy (Správa → Kiosk → Obrazovka kiosku); dokud visí, zbytek '
        'záhlaví ustoupí.',
    'Kiosk: správce může dnešní zápasy v záhlaví skrýt (Správa → Kiosk → '
        'Stavový řádek).',
    'Kiosk: ve výběru jména upozornění, že se tam z tréninku odhlásit nedá '
        '(text nastaví správce ve Správě → Kiosk).',
    'Kiosk: nadpis oznamu v záhlaví se při střídání plynule prolne na svém '
        'místě, neposkočí.',
    'Kiosk: kdo slouží na kantýně — v záhlaví (ťuk ukáže plán), jako pás '
        'v kalendáři (nad datem, pod ním nebo dole) nebo karta v panelu; '
        'zapíná správce ve Správě → Kiosk → Služby na kantýně.',
  ], store: [
    'Kiosk: video zápasu živě i ze záznamu; počasí, svátek a upozornění v '
        'záhlaví; dnešní zápasy v záhlaví jdou skrýt.',
    'Kiosk: kdo slouží na kantýně.',
    'Kiosk: registrační čísla v zápisu, ＋ jako v appce, rada a upozornění '
        've výběru jména.',
    'Kiosk v aplikaci: displej nezhasne, lišty se schovají; přihlášení '
        'tlačítkem „Přihlásit kiosk“.',
    'Správa → Kiosk: Optimalizace výkonu pro slabší displej.',
    'Zápas v rozvrhu: domácí, pomlčka a hosté pod sebou.',
    'Emoji v textu z obrázků — všude stejně.',
  ]),
  Release('2.0.7', '9. 10. 2026', [
    'Notifikace o rezervaci, kterou za vás udělal kiosk, spoluhráč ze '
        'skupiny nebo služba, otevře kalendář přímo na tom dni a termín na '
        'chvíli zvýrazní. Když už je rezervace zrušená, aplikace to řekne. '
        'V e-mailu o takové rezervaci je odkaz na zrušení jedním kliknutím.',
  ]),
  Release('2.0.6', '9. 10. 2026', [
    'Detail zápasu: v Mém profilu si vyberete, jak se zápas vykreslí na '
        'výšku a na šířku — karty soubojů pod sebou, kompaktně nebo jako '
        'tabulka tak, aby se celý zápas vešel na obrazovku. Na šířku je '
        'výchozí zápis, který po otočení telefonu naskočí na celou '
        'obrazovku. Přepínač Souboje | Zápis odpadá; stáří výsledků a '
        'odkaz na web ČKA jsou ve skóre nahoře.',
    'Kiosk: vedle rozvrhu je panel s nástěnkou a zápasy — hraný zápas '
        'běží živě, odehrané otevřou zápis. Co panel ukazuje, volí správce '
        've Správě → Kiosk; nastavení je v blocích s popisem a čísla '
        '(doba nečinnosti, šířka panelu, střídání…) se píšou rovnou.',
    'Nástěnka: oznam jde naplánovat — zobrazí se a upozorní až od zadaného '
        'času; správce ho může skrýt z kiosku.',
  ], store: [
    'Detail zápasu: v Mém profilu si vyberete, jak se souboje vykreslí na '
        'výšku a na šířku (karty, kompaktně, tabulka; na šířku výchozí zápis '
        'na celou obrazovku po otočení telefonu).',
    'Kiosk: panel s nástěnkou a zápasy vedle rozvrhu, hraný zápas živě.',
    'Nástěnka: oznam jde naplánovat na zadaný čas.',
  ]),
  Release('2.0.5', '7. 10. 2026', [
    'Registrační čísla hráčů se zase načítají — evidence ČKA změnila web '
        'a od 3. 10. se nenačetlo žádné. „Doplnit reg. č.“ v profilu '
        'ukazuje u kandidátů věkovou kategorii.',
    'Výsledky: tlačítko ⟳ a tažení dolů fungují i po skončení zápasu '
        '(do 14 dní) — opravený výsledek nebo doplněná dráha z webu ČKA se '
        'tak do appky dostanou.',
    'Výsledky: pod seznamem zápasů je patička „Konec sezóny“.',
  ], store: [
    'Registrační čísla hráčů se zase načítají.',
    'Výsledky: ⟳ a tažení dolů i po skončení zápasu (do 14 dní).',
  ]),
  Release('2.0.4', '6. 10. 2026', [
    'Skupiny: po přijetí pozvánky hned vidíš ostatní členy a můžeš rezervovat '
        'i za ně — dřív to šlo až po restartu appky.',
    'Upozornění „Uvolnilo se místo“ po klepnutí otevře kalendář na tom dni '
        'a místo orámuje. Když ho mezitím někdo vzal, appka to řekne a '
        'napíše, kolik míst ten den ještě zbývá.',
    'Hledání po slovech: „Veverky A“ ve Výjimkách najde jen tým Veverky A. '
        'Stejně funguje hledání v Kuželnách, Kontaktech a při výběru hráče '
        '(slova v libovolném pořadí, „novák jan“, „jan k“). Hledá se od '
        'začátku slova.',
    'Řádek s dny v kalendáři jde posouvat do stran: přepne týden a nechá '
        'stejný den v týdnu.',
    'Výsledky: pod seznamem zápasů je odkaz na Termínátora, naši appku '
        'na turnaje.',
  ], store: [
    'Skupiny: po přijetí pozvánky hned vidíš členy skupiny.',
    '„Uvolnilo se místo“ otevře kalendář na daném místě.',
    'Hledání po slovech („Veverky A“) ve Výjimkách, Kuželnách a Kontaktech.',
    'Dny v kalendáři jde posouvat: přepnou týden.',
  ]),
  Release('2.0.3', '2. 10. 2026', [
    'Výsledky zápasu: remíza v souboji se píše nulou. Potažení dolů obnoví '
        'výsledky stejně jako tlačítko ⟳ vpravo nahoře.',
    'Nástěnka: správce vidí i seznam těch, kdo si oznam zobrazili. '
        '„Více“ se ukáže jen u textu, který se opravdu nevejde.',
    'Kuželny: filtr podle soutěže, výběr si appka pamatuje.',
    'Správce může zadat registrační číslo hráče ručně (Správa → Hráči → ⋮ → '
        'Reg. č.…).',
  ], store: [
    'Výsledky: remíza souboje nulou, tažení dolů jako ⟳.',
    'Nástěnka: seznam, kdo si oznam zobrazil.',
    'Kuželny: filtr podle soutěže.',
    'Správce zadá registrační číslo ručně.',
  ]),
  Release('2.0.2', '2. 10. 2026', [
    'Horní pruh kalendáře s týdnem jde posouvat do stran — doleva na další '
        'týden, doprava na předchozí.',
    'Klepnutí na pruh zápasu v kalendáři otevře výsledky zápasu.',
    'Registrační čísla: appka rozliší jmenovce podle klubu a věku. Když '
        'v profilu číslo chybí, tlačítko „Doplnit reg. č.“ nabídne lidi '
        'z registru ČKA a ty se poznáš. V Zápisu mají čísla svoji buňku '
        'i za běhu zápasu; v Kontaktech je číslo bez popisku.',
    'Výsledky: potažením dolů se data načtou znovu, i na prázdné obrazovce. '
        'Totéž jde na plánu služeb.',
    'Souboje: u vítěze je tučně i číslo v závorce a remíza se píše dvojtečkou '
        '(v rozbalené tabulce dráhy nulou). Jméno týmu a skóre stojí '
        'na jedné řádce.',
    '„Navigovat“ na kuželnu nabídne mapové aplikace v telefonu '
        '(Google Maps, Mapy.cz, Waze…), ne jen Google Maps.',
    'Poslední řádky dlouhých obrazovek (Můj profil, Kontakty, Kuželny, '
        'Výsledky, Správa) už nezakrývá systémová navigační lišta.',
    'Správce může upravit jméno hráče (Správa → Hráči → ⋮ → Jméno…).',
  ], store: [
    'Pruh s týdnem v kalendáři jde posouvat do stran.',
    'Klepnutí na pruh zápasu otevře výsledky.',
    'Registrační čísla: rozlišení jmenovců a „Doplnit reg. č.“ v profilu.',
    'Výsledky a služby: potažením dolů se data načtou znovu.',
    '„Navigovat“ nabídne mapové aplikace v telefonu.',
    'Lišta telefonu už nezakrývá konec obrazovek.',
    'Správce může upravit jméno hráče.',
  ]),
  Release('2.0.1', '1. 10. 2026', [
    'Zvoneček u volných míst ve dni hlídá uvolněné termíny — celý den, '
        'nebo jen bloky, které si vybereš.',
    'Zápas, kde družstvo nenastoupilo v plném počtu: Souboje ukážou hráče '
        '„bez soupeře“ s jeho výkonem a Zápis dopočítá hráči dva dílčí body '
        'a bod za souboj, které web ČKA nechává prázdné.',
    'Registrační čísla hráčů z registru ČKA jsou ve Zápisu, v profilu '
        'a v kontaktech.',
    'Klubovnu si můžeš nastavit jako obrazovku, na které se appka otevře.',
    'Přidělení služby na kantýně: dá se filtrovat podle klubu a appka si '
        'pamatuje naposledy zvolený klub.',
    'Na počítači (web): posun touchpadem i tažením myší a tlačítko Zpět '
        'v prohlížeči zavře otevřenou obrazovku místo opuštění stránky.',
  ], store: [
    'Zvoneček u volných míst ve dni hlídá uvolněné termíny.',
    'Souboje „bez soupeře“ a dopočtené body, když družstvo nenastoupilo '
        'v plném počtu.',
    'Registrační čísla hráčů z registru ČKA.',
    'Klubovnu lze nastavit jako úvodní obrazovku.',
    'Přidělení služby: filtr podle klubu.',
  ]),
  Release('2.0.0', '30. 9. 2026', [
    'Zápasy a výsledky se nově stahují z výsledkového servisu ČKA — '
        'správce je zapne v Správa → Oddíly.',
    'Nový tab Klubovna: výsledky zápasů našich týmů (i živě, s videem a '
        'výkony hráčů) a kuželny soupeřů s adresou, telefonem a navigací.',
    'Výsledky: přepínač Oddíly / Soutěže. Soutěže ukáže celou soutěž, ve '
        'které hrají naše oddíly, po kolách (podle dat konání) — včetně '
        'zápasů ostatních družstev, s detailem a zápisem hráčů.',
    'Detail zápasu má zápis jako na kuzelky.com — ikonou vpravo nahoře ho '
        'otevřeš přes celou obrazovku, na výšku i na šířku.',
    'Detail zápasu: nový pohled Souboje — velká čísla, kdo vyhrál který '
        'souboj a dráhu. Původní zápis je o ťuk vedle.',
    'Klubovna → Kontakty: e-mail a telefon hráčů kuželny (s tlačítkem pro '
        'WhatsApp). Svůj e-mail i telefon můžeš skrýt v Můj profil.',
    'Služby na kantýně: správce plánuje služby v Správa → Služby, všichni '
        'je vidí v Klubovna → Služby. Kdo má službu, může po dobu služby '
        'rezervovat a rušit tréninky ostatním a upravovat bloky '
        'v jednotlivých dnech.',
    'Nástěnka a zprávy: Klubovna → Nástěnka jsou oznámení od správce, '
        'Klubovna → Zprávy je psaní se správci, se službou na kantýně nebo '
        'hráčům v bloku či dni — s 👍/👎 a krátkou odpovědí.',
    'Upozornění, že se registroval nový hráč nebo vznikla nová kuželna, '
        'po ťuknutí otevře rovnou schvalování (i odkaz v e-mailu).',
  ], store: [
    'Zápasy a výsledky z výsledkového servisu ČKA; Klubovna s výsledky '
        'týmů (i živě) a kuželnami soupeřů.',
    'Výsledky: Oddíly / Soutěže — celá soutěž po kolech i se zápasy '
        'ostatních družstev.',
    'Detail zápasu: Souboje a zápis jako na kuzelky.com.',
    'Služby na kantýně: kdo má službu, rezervuje a ruší tréninky '
        'ostatním.',
    'Nástěnka a Zprávy (správci, služba, hráči; 👍/👎).',
    'Kontakty hráčů s WhatsAppem.',
  ]),
  Release('1.2.8', '22. 9. 2026', [
    'Ve správě appky se tlačítko pro přidání (oddíl, hráč, pronájem…) už '
        'nemůže zakrýt poslední položku v seznamu.',
    'Ťuknutí na cizí rezervaci teď ukáže celé jméno hráče — přezdívka '
        'na rozvrhu ne vždy stačí poznat, kdo je kdo.',
    'Veřejný přehled: správce ho zapne v Správa → Veřejný přehled a kuželna '
        'dostane vlastní adresu, kde kdokoli uvidí rozvrh bez přihlášení — '
        'jen obsazenost, bez jmen.',
    'Změny v profilu a u kalendáře (připomínky, barvy, týmy, výchozí '
        'pohled) se ukážou hned po uložení — i na pomalé síti.',
    'Výjimky: seznam při zaškrtávání už neposkakuje — tvoje výjimky jsou '
        'shrnuté v jednom řádku nahoře a v rozpisu je označí ikonka. '
        'Odehrané zápasy mezi výjimkami nejsou.',
    'Skupiny: rodina nebo dvojice si může rezervovat a rušit tréninky '
        'navzájem — založíš ji v Můj profil.',
  ], store: [
    'Skupiny: rodina nebo dvojice si může rezervovat a rušit tréninky '
        'navzájem — založíš ji v Můj profil.',
    'Veřejný přehled: kuželna může mít vlastní adresu s rozvrhem bez '
        'přihlášení — jen obsazenost, bez jmen.',
    'Ťuknutí na cizí rezervaci ukáže celé jméno hráče.',
    'Výjimky: seznam při zaškrtávání už neposkakuje, tvoje výjimky jsou '
        'shrnuté nahoře.',
    'Změny v profilu a u kalendáře se ukážou hned po uložení, i na pomalé '
        'síti.',
    'Tlačítko pro přidání ve správě už nezakryje poslední položku seznamu.',
  ]),
  Release('1.2.7', '15. 9. 2026', [
    'Po spuštění už neprobleskne „Offline" jen proto, že se appka teprve '
        'připojuje — když síť opravdu chybí, banner se ukáže dál.',
    'Nepravidelný pronájem: jeden nájemce, víc termínů — každý s vlastním '
        'časem a drahami. Pronájmy jsou nově rozdělené na pravidelné a '
        'nepravidelné.',
    'Barva mých rezervací teď nabízí stejnou paletu jako Google kalendář '
        '(sytě, jako tam), plus vlastní barvu z kolečka.',
    'Ťuknutím na zápasy v hlavičce dne se otevře jejich úplný přehled — '
        'dlouhé názvy už nejsou oříznuté.',
  ]),
  Release('1.2.6', '14. 9. 2026', [
    'Připomínky v profilu: ozveme se ti pár hodin nebo den před tréninkem '
        'i zápasem — do mobilu, bez appky e-mailem.',
    'Výjimky v Moje týmy: jednotlivý zápas přidáš do přehledu, nebo ho '
        'z něj skryješ.',
    'Týmy nastavíš na jednom místě: u každého zaškrtneš Přehled, Kalendář '
        'a barvu.',
    'S druhým kalendářem tým podržíš a vybereš, kam jeho zápasy patří.',
    'Výběr v panelu se uloží až tlačítkem Uložit.',
    'Otočení telefonu nechá zvolený týden na pokoji.',
    'Správce vidí u hráčů e-mail.',
  ]),
  Release('1.2.5', '10. 9. 2026', [
    'Na kiosku vybíráš jméno z mřížky v barvách oddílů a vede v ní '
        'přezdívka.',
    'V rezervačním dialogu se jména vejdou i s klávesnicí a okno při psaní '
        'neskáče.',
    'Vyčerpaný limit rezervací je vidět rovnou — i správci, než rezervaci '
        'hráči vytvoří.',
    'Schválení hráče se projeví hned, bez obnovení.',
    'Hlášky z dialogu se ukazují nad ním, ne pod klávesnicí.',
    'Uložení dialogu už neshodí appku.',
    'Zápasy z rozpisu jsou označené a ruční úpravy import nepřepíše.',
  ]),
  Release('1.2.4', '8. 9. 2026', [
    'Můj přehled je první tab, kalendář druhý.',
    'Oba pohledy mají stejnou hlavičku — ikony profilu a správy '
        'při přepnutí tabu neposkočí.',
  ]),
  Release('1.2.3', '8. 9. 2026', [
    'Po přepnutí zpátky do appky už neprobleskne hláška „Offline" — '
        'ukáže se, až když spojení opravdu vypadne.',
    'Při zvětšeném písmu sedí časy na svých řádcích a jméno v rezervaci '
        'se neláme v půlce slova.',
  ]),
  Release('1.2.2', '8. 9. 2026', [
    'Moje tréninky se jmenují Můj přehled — jsou v něm i zápasy tvých týmů.',
    'Barvu týmu vybereš jednou v profilu a platí všude: obarví zápas '
        'v přehledu i událost v Google kalendáři. Tréninky mají svou.',
    'Druhý kalendář „Rezervátor 2": u každého týmu řekneš, kam jeho zápasy '
        'patří, a každý kalendář má vlastní připomínky.',
    'Vzhled a velikost písma v profilu: světlý, tmavý, kontrastní, '
        'písmo až 130 %.',
    'Vlastní barva rezervací z kolečka, a paleta bez tří barev, které vedle '
        'sebe nešly rozeznat.',
  ]),
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
