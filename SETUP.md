# Rezervátor — Setup (jednorázově, ~15 minut klikání)

Aplikace je hotová, chybí jí jen vlastní backend účet a pár kliknutí v
Supabase. Kroky 1–4 rozjedou rezervace tréninků v aplikaci (mobil i desktop).
Krok 5 nasadí webovou verzi na GitHub Pages. Krok 6 zapne e-mailové
notifikace. Krok 7 rozjede kioskový tablet na kuželně. Krok 8 doplní
docházkový report, volitelný push a keep-alive workflow — poslední kousky
skládačky.

## 1. Supabase projekt (zdarma, bez kreditní karty)

1. Registrace na <https://supabase.com> → **New project** (region: **Central
   EU**, aby data zůstala v Evropě a odezva byla nízká).
2. V **Project Settings → API** si poznamenej:
   - **Project URL** → tvůj `SUPABASE_URL`
   - **anon / publishable key** → tvůj `SUPABASE_ANON_KEY`
   - **Project Reference ID** (najdeš i v URL projektu, tvar `abcdefghijkl`)
     — bude se hodit hned v dalším kroku.

## 2. Databázové schéma

1. Otevři [`supabase/migrations/0001_schema.sql`](supabase/migrations/0001_schema.sql)
   a **než ho spustíš**, uprav dvě placeholder hodnoty úplně na konci
   souboru (funkce `notify_webhook`):
   - `<PROJECT_REF>` → nahraď svým project ref (viz krok 1) — použije se pro
     URL Edge Function `notify`, i když tu funkci nasadíme až ve Fázi 3.
   - `<WEBHOOK_SECRET>` → nahraď náhodným řetězcem, který si vygeneruješ:
     ```bash
     openssl rand -hex 24
     ```
     **Tento secret si někam poznamenej** — bude potřeba znovu ve
     Fázi 3, až se bude nasazovat notifikační Edge Function a bude se
     nastavovat jako `WEBHOOK_SECRET` přes `supabase secrets set`. Bez shody
     obou hodnot notifikace v budoucnu nebudou fungovat (ale na Fázi 0 to
     nemá žádný vliv).
2. Dashboard → **SQL Editor** → vlož **celý** upravený obsah souboru a
   **Run**. Založí to všechny tabulky, RPC funkce, triggery i RLS politiky.
3. Nasej výchozí časové bloky tréninků. Uprav si časy podle reálného
   rozvrhu kuželny a spusť v SQL Editoru:
   ```sql
   insert into time_blocks (starts_at, ends_at, position) values
     ('16:00', '17:00', 0), ('17:00', '18:00', 1), ('18:00', '19:00', 2),
     ('19:00', '20:00', 3), ('20:00', '21:00', 4), ('21:00', '22:00', 5);
   ```
   (Blok můžeš kdykoliv později deaktivovat nebo přidat další — administrace
   rozvrhu přijde v jedné z dalších fází, zatím jde jen o počáteční data.)

## 3. Auth (magic linky)

Dashboard → **Authentication → URL Configuration** → **Redirect URLs** →
přidej všechny adresy, ze kterých se bude přihlašovat:

```
cz.kuzelky.rezervator://login-callback
https://<tvůj-github-username>.github.io/rezervator/
http://localhost:**
```

- První řádek je deep link pro mobilní appku (Android/iOS).
- Druhý řádek je produkční web na GitHub Pages (krok 5) — uprav
  `<tvůj-github-username>` na skutečné jméno účtu/organizace.
- Třetí řádek je pro lokální vývoj webové verze (`flutter run -d chrome`);
  používáme dvě hvězdičky, protože Supabase glob `*` nepřekračuje lomítko,
  takže by nenašel shodu s koncovým lomítkem, které appka posílá.
- V **Authentication → URL Configuration** ještě nastav **Site URL** na
  produkční adresu `https://<tvůj-github-username>.github.io/rezervator/` —
  je to záložní cíl, kam Supabase přesměruje, pokud odkaz z e-mailu
  neodpovídá žádnému vzoru výše.

Magic-link e-mail je defaultně zapnutý, ale vestavěné odesílání Supabase je
silně rate-limitované a jen anglicky. Doporučuje se vlastní **SMTP** (např.
Gmail): v Google účtu zapni dvoufázové ověření, vytvoř App Password
(<https://myaccount.google.com/apppasswords>), pak v Supabase →
**Authentication → SMTP** nastav host `smtp.gmail.com`, port `587`,
uživatele = tvůj Gmail, heslo = app password, jméno odesílatele
`Rezervátor`. Gmail dovolí ~500 mailů/den, což na kuželnu bohatě stačí.
S vlastním SMTP aktivním si můžeš zároveň počeštit šablony e-mailů
(**Authentication → Email Templates**).

## 4. První spuštění

```bash
flutter run \
  --dart-define=SUPABASE_URL=https://TVUJREF.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=eyJ...
```

**První člověk, který se přihlásí, se automaticky stane administrátorem** —
žádný pozvánkový kód není potřeba (na rozdíl od Termínátoru). Všichni další
uživatelé se zaregistrují jako hráči se stavem „čeká na schválení" a čekají
na schválení od administrátora — ten je schvaluje přímo v appce (ikona
skupiny → Hráči → Schválit).

Aplikace zatím používá i proměnné `FIREBASE_API_KEY`, `FIREBASE_APP_ID`,
`FIREBASE_SENDER_ID` a `FIREBASE_PROJECT_ID` v `lib/config.dart` — ty jsou
**zatím nepotřebné** (týkají se push notifikací, které přijdou až ve
Fázi 5). Klidně je teď ignoruj, appka běží i bez nich.

## 5. Web na GitHub Pages

1. Založ na GitHubu repozitář `rezervator` (veřejný nebo soukromý, oboje
   funguje s GitHub Pages přes Actions) a nahraj do něj tento projekt:
   ```bash
   git remote add origin https://github.com/<tvůj-github-username>/rezervator.git
   git push -u origin main
   ```
2. V repozitáři **Settings → Secrets and variables → Actions** přidej dva
   repository secrets:
   - `SUPABASE_URL`
   - `SUPABASE_ANON_KEY`
3. **Settings → Pages → Source** přepni na **GitHub Actions**.
4. Přiložený workflow [`.github/workflows/deploy-web.yml`](.github/workflows/deploy-web.yml)
   se spustí automaticky při každém pushi do `main` (i ručně přes
   **Actions → Deploy web → Run workflow**), postaví `flutter build web
   --release` s adresou `/rezervator/` jako base-href a nasadí výsledek na
   `https://<tvůj-github-username>.github.io/rezervator/`.

Nezapomeň tuhle finální adresu doplnit do Auth redirect URLs v kroku 3, pokud
jsi ji tam ještě nezadal/a s reálným uživatelským jménem.

## 6. Notifikace (Fáze 3)

Od téhle fáze appka posílá e-maily: nový hráč čekající na schválení (admini),
zrušení tréninku administrátorem (hráč) a potvrzení rezervace z kiosku
(hráč, s odkazem na zrušení jedním kliknutím — kiosek samotný přijde až ve
Fázi 4). Push notifikace zatím spí, viz poznámka na konci.

1. **Resend** (e-mail): registrace na <https://resend.com> → **API Keys** →
   vytvoř nový klíč. Free tier stačí na začátek: **100 e-mailů/den, 3 000/
   měsíc**. Odesílat se zatím bude z defaultní adresy `onboarding@resend.dev`
   (funguje bez ověřování domény) — vlastní doménu (`RESEND_FROM`, např.
   `Rezervátor <rezervace@tvoje-domena.cz>`) lze dodat kdykoliv později, není
   to blokující.
2. Propoj lokální Supabase CLI s projektem (jen jednou):
   ```bash
   supabase link --project-ref <tvůj-project-ref>
   ```
   (`<tvůj-project-ref>` je stejná hodnota, kterou jsi použil/a v kroku 2 za
   `<PROJECT_REF>`.)
3. Nastav secrets pro Edge Functions:
   ```bash
   supabase secrets set \
     WEBHOOK_SECRET=<hodnota-z-kroku-2> \
     RESEND_API_KEY=<klíč-z-Resend> \
     CANCEL_TOKEN_SECRET=$(openssl rand -hex 24)
   ```
   **`WEBHOOK_SECRET` musí být přesně stejná hodnota**, kterou jsi vložil/a
   za `<WEBHOOK_SECRET>` do `0001_schema.sql` v kroku 2 (Databázové schéma) —
   jinak databázový trigger (`notify_webhook`) bude volat funkci `notify` se
   špatným hlavičkovým tokenem a ta ho odmítne (401). `CANCEL_TOKEN_SECRET` je
   nový, nezávislý řetězec — používá se jen k podepisování odkazů na zrušení
   rezervace v e-mailech.
4. Nasaď obě funkce:
   ```bash
   supabase functions deploy notify --no-verify-jwt
   supabase functions deploy cancel --no-verify-jwt
   ```
   `--no-verify-jwt` je nutné u obou: `notify` volá databázový trigger (ten
   žádný JWT nemá a nemůže) a je místo toho chráněný hlavičkou
   `x-webhook-secret`; `cancel` otevírají lidé přímo z e-mailu (taky bez
   JWT) a je chráněný podepsaným HMAC tokenem v odkazu.
5. **Test hned teď** (bez kiosku — ten přijde ve Fázi 4, takže plný test
   „rezervace z kiosku → e-mail se zrušovacím odkazem" počká do té doby):
   - Zaregistruj v appce nového hráče (jiný účet/e-mail) → admini by měli
     do pár vteřin dostat e-mail **„Nový hráč čeká na schválení"**.
   - Jako admin zruš existující nadcházející rezervaci hráče, který **nemá
     appku nainstalovanou** (aby bylo jasné, že jde o e-mail, ne push) →
     hráči by měl přijít e-mail **„Trénink zrušen"**.
   - Pokud e-mail nedorazí, zkontroluj **Edge Functions → notify → Logs**
     v Supabase dashboardu a ověř shodu `WEBHOOK_SECRET` z kroku 3 výše.
6. **Push notifikace** — nastavení viz Fáze 8. Bez něj chodí všem e-mail;
   s ním dostanou uživatelé s nainstalovanou Android appkou push, ostatní
   (web, kiosek) dál e-mail.

## 7. Kiosek (Fáze 4)

Od téhle fáze appka umí i sdílený dotykový tablet zavěšený na kuželně: kdokoliv
schválený si na něm najde svoje jméno a rezervuje si termín bez přihlašování
vlastním účtem. Kiosek nikdy nic neruší (na to slouží appka na mobilu) a nikdy
neukazuje seznam hráčů ani rozvrh správy — jen svůj vlastní rozvrh a tlačítko
„Rezervovat".

### 7.1 Kioskový účet

1. Supabase dashboard → **Authentication → Users → Add user** → e-mail ve
   tvaru `kiosk@tvoje-domena.cz` (nemusí být skutečná schránka — kiosek se
   nikdy nesnaží nic odeslat ani přijmout přes e-mail) + silné heslo
   (kiosek si ho pamatuje jen v prohlížeči na tabletu, nikdo jiný ho
   nezadává). Zaškrtni **Auto Confirm User**, aby se e-mail nemusel ověřovat
   klikem z pošty, která ani neexistuje.
2. Na tabletu otevři **`https://<tvůj-github-username>.github.io/rezervator/#/kiosk-login`**
   — všimni si `#` před `/kiosk-login`: appka běží jako Flutter web bez
   `usePathUrlStrategy()`, takže routing jede přes hash a tahle podoba adresy
   je jediná, která na GitHub Pages (statický hosting bez server-side
   rewrite pravidel) skutečně zafunguje. Adresa bez `#` by po refresh/přímém
   vstupu skončila 404 dřív, než se appka vůbec stihne načíst.
3. Přihlas se e-mailem a heslem z kroku 1 (samostatný formulář — kiosek
   nepoužívá magic linky jako běžní hráči, protože jde o sdílené zařízení
   bez vlastní schránky). Appka po přihlášení nikoho nezná (žádný profil
   ještě neexistuje), takže se ukáže běžný registrační formulář — vyplň
   jméno **„Kiosk"** (na displeji samotného tabletu ho nikdo neuvidí a
   nikde jinde v appce se veřejně nezobrazí — pohled na hráče v appce i na
   kiosku kioskové účty schválně vynechává) a potvrď **Zaregistrovat se**.
4. V appce (na mobilu/desktopu, přihlášený jako admin) otevři **Správa →
   Hráči**. Nový účet „Kiosk" se objeví buď mezi **Čekají na schválení**,
   nebo (je-li to úplně první účet, který kdy appku vůbec viděl) rovnou mezi
   schválenými s odznakem „admin" — v obou případech ho **neschvaluj ručně**,
   přeskoč rovnou na další krok: změna role na kiosk schválení obstará sama.
5. U řádku „Kiosk" klikni na nabídku (⋮) → **Nastavit jako kiosk** →
   potvrdit. Tím se účtu zároveň nastaví `status = schváleno`, i kdyby
   předtím čekal na schválení — žádný samostatný krok navíc není potřeba.
6. Tablet by se měl přepnout sám — profilový stream je živý a změna role
   obrazovku přepne do pár vteřin. Kdyby se nepřepnul (výpadek realtime
   spojení), jednoduchý F5/reload pomůže. Místo registračního formuláře se
   teď zobrazí fullscreen kioskový rozvrh bez navigace a bez tlačítka
   odhlásit.

### 7.2 Fully Kiosk Browser (uzamčení tabletu)

Appka na tabletu poběží spolehlivě celý den bez dohledu jedině v prohlížeči
uzamčeném do kiosk režimu — jinak stačí systémové gesto zpět/domů a někdo
omylem přepne na plochu nebo jinou appku.

1. Na tabletu (Android) nainstaluj **Fully Kiosk Browser** z Play Store
   (zdarma s reklamou, nebo placená Plus licence bez ní — na jeden tablet
   v klubovně stačí i free verze).
2. **Settings → Web Content Settings → Start URL** nastav přesně na adresu
   z kroku 7.1.2 výše (s `#/kiosk-login`) — po každém restartu appky/tabletu
   se tak znovu naběhne rovnou na přihlašovací obrazovku, případně (je-li
   session v localStorage prohlížeče pořád platná) appka sama přeskočí
   rovnou do kioskového rozvrhu.
3. **Settings → Other Settings → Enable Kiosk Mode** (blokuje tlačítko
   Home/Recent Apps a stavovou lištu) a **Set as Device Launcher**
   (nahradí domovskou obrazovku tabletu appkou Fully Kiosk, takže restart
   tabletu naběhne rovnou do kiosku, ne na plochu).
4. **Settings → Device Management → Keep Screen On** zapni, ať se displej
   sám nezhasne uprostřed dne — appka má vlastní 60s reset výběru hráče při
   nečinnosti, ale to nic nepomůže, když je celá obrazovka černá.
5. **Settings → Other Settings → Auto Reload / Restart Browser** nastav
   na jednou denně v noci (např. 4:00) — kiosek pak každé ráno naběhne s
   čerstvou session a čerstvě načtenými daty, i kdyby přes noc vypadlo
   Wi-Fi nebo appka zůstala „zaseknutá" na starém stavu.
6. Volitelně **Settings → Motion Detection → Screen Saver** vypni (kiosek
   má vlastní logiku pro nečinnost, systémový spořič displeje navíc by jen
   plodil zbytečné dotyky navíc při probouzení).

Hotovo — kiosek je teď samostatné zařízení, které kdokoliv schválený použije
jedním dotykem bez hesla, bez appky v mobilu a bez dohledu obsluhy.

## 8. Reporty, push notifikace a keep-alive (Fáze 5)

### 8.1 Docházka (report a export)

Admin najde měsíční přehled docházky v **Správa kuželny → Docházka**:
šipky (chevrony) vlevo/vpravo od názvu měsíce přepínají mezi měsíci a
tlačítko **Export CSV** stáhne aktuálně zobrazený měsíc jako soubor
`dochazka-RRRR-MM.csv` (jméno, klub, počet tréninků) — hodí se pro
tabulku mimo appku (Excel/Sheets) nebo archivaci.

**Zpětné označení „nepřišel"**: pokud hráč na trénink nedorazil, admin v
appce klikne na jeho obsazenou buňku v rozvrhu (i zpětně, u proběhlého
tréninku) a zvolí zrušení rezervace s poznámkou — napíše `nepřišel` (je to
jen našeptávaný text v poli, ne pevná hodnota, takže jde napsat i jiný
důvod). Rezervace se zruší a do měsíční docházky se už nezapočítá, takže
report odpovídá skutečné účasti, ne jen tomu, kdo si trénink rezervoval.

### 8.2 Push notifikace (FCM) — volitelné

Appka od začátku (Fáze 0) umí číst 4 `FIREBASE_*` dart-defines (viz krok 4
výše), ale bez dalšího nastavení zůstávají push notifikace vypnuté a
appka běží normálně dál jen s e-mailem (Fáze 3). Zapnutí push je volitelné
a vyžaduje dvě samostatné věci — klientskou konfiguraci (Firebase projekt)
a serverovou (`FIREBASE_SERVICE_ACCOUNT`):

1. Založ **Firebase projekt** na <https://console.firebase.google.com> →
   **Add project** (Google Analytics není potřeba, klidně vypni).
2. V projektu přidej **Android app** s package name `cz.kuzelky.rezervator`
   (najdeš v `android/app/build.gradle.kts` jako `applicationId`, kdyby se
   měnil) a z **Project settings → General** si poznamenej čtyři hodnoty:
   - **Web API Key** → `FIREBASE_API_KEY`
   - **App ID** (Android app, tvar `1:123...:android:abc...`) → `FIREBASE_APP_ID`
   - **Project number** → `FIREBASE_SENDER_ID`
   - **Project ID** → `FIREBASE_PROJECT_ID`
3. Tyhle čtyři hodnoty doplň jako `--dart-define` do **všech lokálních
   buildů** (stejný vzor jako `flutter run` v kroku 4 — jen s dalšími
   čtyřmi `--dart-define` navíc), a zároveň je přidej jako **repository
   secrets** do GitHubu (stejné místo jako
   `SUPABASE_URL`/`SUPABASE_ANON_KEY` v kroku 5, bodu 2: **Settings →
   Secrets and variables → Actions**) — workflow
   [`deploy-web.yml`](.github/workflows/deploy-web.yml) je od téhle fáze
   předává do web buildu automaticky. Necháš-li je nevyplněné, web build
   proběhne úplně stejně jako dřív, jen bez push (na webu push stejně
   nefunguje — týká se jen Android/iOS buildů).
3b. **Nutné pro Android push:** ve Firebase u té Android app stáhni
   **`google-services.json`** a ulož ho do `android/app/google-services.json`
   (soubor je v `.gitignore`, protože obsahuje klíče — vzor viz
   `android/app/google-services.json.example`). Bez něj se **nativní**
   `FirebaseApp[DEFAULT]` na Androidu neinicializuje (v logu
   „Default FirebaseApp failed to initialize because no default options were
   found") a `firebase_messaging` nikdy nevydá token — samotné
   `--dart-define` hodnoty z bodu 2 na to nestačí, protože jde o
   Dart-side inicializaci. Gradle plugin `com.google.gms.google-services`
   je už v projektu zapojený, takže stačí ten soubor doplnit a APK
   přestavět.
4. Server-side: nastav Supabase secret `FIREBASE_SERVICE_ACCOUNT` (JSON
   service-account klíč z **Firebase → Project settings → Service accounts
   → Generate new private key**, vlož **celý obsah** staženého souboru jako
   jednořádkovou hodnotu):
   ```bash
   supabase secrets set FIREBASE_SERVICE_ACCOUNT='<obsah staženého JSON souboru>'
   ```
   Tenhle secret aktivuje odesílání přes FCM v Edge Function `notify` —
   bez něj (nebo dokud ho nenastavíš) `notify` posílá jen e-mail, přesně
   jako ve Fázi 3, takže appka funguje i bez tohoto kroku a nikomu nic
   neujde.

### 8.3 Keep-alive (Supabase free tier usíná po 7 dnech nečinnosti)

Supabase projekt na free tieru se po ~7 dnech bez API aktivity sám
pozastaví. Přiložený workflow
[`.github/workflows/keepalive.yml`](.github/workflows/keepalive.yml) mu
v tom brání — dvakrát týdně (pondělí a čtvrtek 6:00 UTC) zavolá lehký
GET dotaz na tabulku `time_blocks`. Používá stejné dva repository secrets
jako `deploy-web.yml` (`SUPABASE_URL` a `SUPABASE_ANON_KEY`, viz krok 5,
bod 2) — pokud jsi je tam už přidal/a, keepalive workflow není potřeba nijak
dál zapínat, GitHub Actions ho spustí sám podle rozvrhu (`cron`) hned po
pushnutí do `main`. Chceš-li ho vyzkoušet hned teď, běž do **Actions →
Supabase keep-alive → Run workflow** (ruční spuštění přes
`workflow_dispatch`).

## Hotovo

Fáze 0–5 jsou nasazené: rezervace tréninků (appka i web), auth s
magic linky, e-mailové i (volitelně) push notifikace, kiosek na
tabletu, měsíční docházka s CSV exportem a keep-alive, co drží
Supabase projekt vzhůru. Appka je připravená k běžnému provozu.

## Nová kuželna (multitenancia, od migrace 0005; self-service od 0006)

Novou kuželnu založí provozovatel sám přímo v registraci: přihlásí se
magic linkem a v poli „Kuželna" vybere „➕ Založit novou kuželnu". Stane se
jejím správcem (RPC `create_tenant_and_register` nastaví `founder_email` na
jeho e-mail a rovnou ho schválí). Řádek `schedule_settings` a vestavěný typ
„Zápas" se založí automaticky (trigger `tenant_seed_defaults`).

Ruční SQL cesta (Supabase SQL editor) dál funguje, hodí se pro založení
předem — pak se provozovatel registruje běžně výběrem své kuželny:

```sql
insert into tenants (name, founder_email)
values ('Kuželna Vracov', 'provozovatel@example.com');
```
- Kiosk pro novou kuželnu: založ auth účet s heslem, přihlas tablet přes
  `/kiosk-login`, účet se zaregistruje do své kuželny a admin mu dá roli
  kiosk (Hráči → Nastavit jako kiosk).
- Data kuželen jsou úplně oddělená (RLS filtruje přes `current_tenant_id()`);
  jeden uživatel patří právě do jedné kuželny.
