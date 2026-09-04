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

1. Propoj lokální Supabase CLI s projektem a aplikuj všechny migrace:
   ```bash
   supabase link --project-ref <tvůj-project-ref>
   supabase db push
   ```
   Založí to všechny tabulky, RPC funkce, triggery i RLS politiky. Nic
   v `supabase/migrations/` se needituje — konfigurace projektu jde do
   Vaultu (další krok).
2. Dashboard → **SQL Editor** → vlož a spusť (obě hodnoty si poznamenej,
   `webhook_secret` bude potřeba znovu v kroku 6):
   ```sql
   select vault.create_secret(
     'https://<tvůj-project-ref>.supabase.co/functions/v1/notify',
     'notify_url');
   select vault.create_secret('<openssl rand -hex 24>', 'webhook_secret');
   ```
   Databázový trigger `notify_webhook` si obě hodnoty čte odtud; bez nich
   zápisy fungují, jen se neposílají notifikace (a v Postgres logu je
   warning).
3. Časové bloky, počet drah a tréninkové dny nastavíš po prvním přihlášení
   přímo v appce (Správa → Rozvrh).

## 3. Auth (magic linky)

Dashboard → **Authentication → URL Configuration** → **Redirect URLs** →
přidej všechny adresy, ze kterých se bude přihlašovat:

```
cz.kuzelky.rezervator://login-callback
https://rezervator.online/
http://localhost:**
```

- První řádek je deep link pro mobilní appku (Android/iOS).
- Druhý řádek je produkční web (krok 5). Bez vlastní domény je to
  `https://<tvůj-github-username>.github.io/rezervator/`.
- Třetí řádek je pro lokální vývoj webové verze (`flutter run -d chrome`);
  používáme dvě hvězdičky, protože Supabase glob `*` nepřekračuje lomítko,
  takže by nenašel shodu s koncovým lomítkem, které appka posílá.
- V **Authentication → URL Configuration** ještě nastav **Site URL** na
  produkční adresu `https://rezervator.online/` — je to záložní cíl, kam
  Supabase přesměruje, pokud odkaz z e-mailu neodpovídá žádnému vzoru výše.

Magic-link e-mail je defaultně zapnutý, ale vestavěné odesílání Supabase je
silně rate-limitované a jen anglicky. Doporučuje se vlastní **SMTP** (např.
Gmail): v Google účtu zapni dvoufázové ověření, vytvoř App Password
(<https://myaccount.google.com/apppasswords>), pak v Supabase →
**Authentication → SMTP** nastav host `smtp.gmail.com`, port `587`,
uživatele = tvůj Gmail, heslo = app password, jméno odesílatele
`Rezervátor`. Gmail dovolí ~500 mailů/den, což na kuželnu bohatě stačí.
S vlastním SMTP aktivním si můžeš zároveň počeštit šablony e-mailů
(**Authentication → Email Templates**).

Tohle všechno (Site URL, redirect URLs, SMTP i česká šablona magic-link
e-mailu ze `supabase/templates/`) je zapsané v `supabase/config.toml` —
místo klikání to lze nahrát jedním příkazem; heslo k SMTP se bere
z prostředí a do repa nepatří:

```bash
SMTP_PASS=<app-password> supabase config push
```

## 4. První spuštění

```bash
flutter run \
  --dart-define=SUPABASE_URL=https://TVUJREF.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=eyJ...
```

Registrace funguje po kuželnách: nový hráč si v registračním formuláři
vybere svou kuželnu ze seznamu **schválených** kuželen (a případně oddíl),
nebo založí **novou kuželnu** — stane se jejím správcem, používat ji ale jde
až po schválení správcem aplikace (viz níže). Všichni další členové kuželny
se registrují jako hráči se stavem „čeká na schválení" a schvaluje je
správce kuželny přímo v appce (ikona skupiny → Hráči → Schválit).

**Správce aplikace (superadmin)** schvaluje nové kuželny a může se do
kterékoli přepnout (Správa → Kuželny). Na čerstvém backendu vznikne úplně
první kuželna takhle: zaregistruj se, v registraci zvol **novou kuželnu**
(appka tě pak drží na čekací obrazovce) a v SQL Editoru jednorázově nastav
sebe jako správce aplikace a tu první kuželnu schval:

```sql
update profiles set superadmin = true where email = '<tvůj-e-mail>';
update tenants set status = 'approved', approved_at = now()
where status = 'pending';
```

Každou další kuželnu už schválíš v appce. Proměnné `FIREBASE_*` v
`lib/config.dart` jsou volitelné (push notifikace, krok 8.2) a `SENTRY_DSN`
také (hlášení chyb, krok 9) — bez nich appka běží normálně.

## 5. Web na GitHub Pages

1. Založ na GitHubu repozitář `rezervator` (veřejný nebo soukromý, oboje
   funguje s GitHub Pages přes Actions) a nahraj do něj tento projekt:
   ```bash
   git remote add origin https://github.com/<tvůj-github-username>/rezervator.git
   git push -u origin main
   ```
2. V repozitáři **Settings → Secrets and variables → Actions** přidej
   repository secrets:
   - `SUPABASE_URL`
   - `SUPABASE_ANON_KEY`
   - volitelně `SENTRY_DSN` (krok 9) a `FIREBASE_*` (krok 8.2); prázdné
     hodnoty jsou v pořádku — příslušná funkce zůstane vypnutá.
3. **Settings → Pages → Source** přepni na **GitHub Actions**.
4. Přiložený workflow [`.github/workflows/deploy-web.yml`](.github/workflows/deploy-web.yml)
   se spustí automaticky při každém pushi do `main` (i ručně přes
   **Actions → Deploy web → Run workflow**), postaví `flutter build web
   --release` s base-href `/` a nasadí výsledek na
   [`https://rezervator.online/`](https://rezervator.online/).

### Vlastní doména

Web běží na vlastní doméně `rezervator.online`, ne na
`<uživatel>.github.io/rezervator/`. Proto je base-href `/` (na github.io
by musel být `/rezervator/`, jinak se nenačte nic). U registrátora domény
míří na GitHub Pages čtyři A záznamy (`185.199.108.153`, `.109.153`,
`.110.153`, `.111.153`) na kořen domény a v **Settings → Pages → Custom
domain** je vyplněná adresa; po vydání certifikátu je zapnuté **Enforce
HTTPS**. Stará adresa `github.io/rezervator/` se na novou přesměrovává
sama.

Nezapomeň tuhle finální adresu doplnit do Auth redirect URLs v kroku 3.

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
   (`<tvůj-project-ref>` je stejná hodnota jako v kroku 2 — pokud už je
   projekt propojený, tenhle krok přeskoč.)
3. Nastav secrets pro Edge Functions:
   ```bash
   supabase secrets set \
     WEBHOOK_SECRET=<hodnota-z-kroku-2> \
     RESEND_API_KEY=<klíč-z-Resend> \
     CANCEL_TOKEN_SECRET=$(openssl rand -hex 24)
   ```
   **`WEBHOOK_SECRET` musí být přesně stejná hodnota**, kterou jsi uložil/a
   do Vaultu jako `webhook_secret` v kroku 2 (Databázové schéma) — jinak
   databázový trigger (`notify_webhook`) bude volat funkci `notify` se
   špatným hlavičkovým tokenem a ta ho odmítne (401). `CANCEL_TOKEN_SECRET` je
   nový, nezávislý řetězec — používá se jen k podepisování odkazů na zrušení
   rezervace v e-mailech (bez něj funkce `cancel` odpovídá 500 a `notify`
   neposílá kioskové e-maily).
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
2. Na tabletu otevři **`https://rezervator.online/#/kiosk-login`**
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
   Žádný `google-services.json` není potřeba — Firebase se na Androidu
   inicializuje z těchhle čtyř hodnot v Dartu (`lib/push/push.dart`),
   Gradle plugin `google-services` projekt nepoužívá.
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

### 8.4 Google kalendář (volitelné — tréninky hráče v jeho kalendáři)

Hráč si v **Můj profil → Google kalendář** jednou propojí svůj Google účet a
appka mu založí vlastní kalendář „Rezervátor“, do kterého sama zapisuje jeho
rezervace (rezervace = událost; přesun ji přeplánuje, zrušení ji smaže).
Používá úzký scope `calendar.app.created` — appka smí sahat jen na kalendář,
který sama vytvořila, nikdy na ostatní kalendáře ani události. Bez
následujícího nastavení appka kartu prostě neukáže; nic jiného se nemění.

Vše se kliká ve **stejném Google Cloud projektu jako Firebase**
(`rezervator-mvazan` — Firebase projekt *je* GCP projekt, vyber ho v přepínači
projektů v konzoli).

1. **APIs & Services → Library** → zapni **Google Calendar API**.

2. **OAuth consent screen** — stránka „Rezervátor chce přístup k tvému
   kalendáři, povolit?“, kterou hráč uvidí po klepnutí na *Propojit s Google
   kalendářem*. Bez ní Google přihlášení odmítne. Jednorázově, zdarma. Najdeš
   ji pod **APIs & Services → OAuth consent screen** (novější konzole říká
   **Google Auth Platform** a dělí ji na *Branding*, *Audience* a *Data
   access*).

   - **User type: External** (*Internal* je jen pro Google Workspace domény;
     hráči mají soukromé Gmaily).
   - **Branding**: název `Rezervátor`; support e-mail i developer contact
     může být tvoje adresa.
   - **Privacy policy link**: veřejná adresa
     `https://rezervator.online/privacy.html` (sekce o kalendáři je tam už
     napsaná).
   - **Scopes** (*Data access*) → *Add or remove scopes* → zaškrtni `openid`
     a `email`, pak do pole **manually add scopes** vlož
     `https://www.googleapis.com/auth/calendar.app.created` (v seznamu
     obvykle chybí). Zdůvodnění, kdyby se ptali: *aplikace zakládá a spravuje
     jeden vlastní vedlejší kalendář se zrcadlem uživatelových rezervací
     tréninků; nikdy nečte ani nemění kalendáře či události, které
     nevytvořila.*
   - **Test users**: dokud je consent screen v režimu *Testing*, mohou se
     přihlásit jen zde vyjmenované adresy (max 100). Přidej **Google účty**
     hráčů (nemusí být totožné s e-mailem, kterým se hlásí do Rezervátoru) a
     svůj vlastní.

3. **APIs & Services → Credentials → Create credentials → OAuth client ID →
   Web application.** Authorized redirect URI (byte po bytu):
   `https://wgwijvcnslkesyqgaeul.supabase.co/functions/v1/calendar-oauth-callback`
   Zkopíruj **client ID** a **client secret**.

4. Předej klienta oběma stranám:
   ```bash
   supabase secrets set GOOGLE_CLIENT_ID=... GOOGLE_CLIENT_SECRET=...
   ```
   Funkce `calendar-oauth-callback` a `calendar-manage` nasazuje
   `deploy-backend.yml` při merge (ručně: `supabase functions deploy
   calendar-oauth-callback --no-verify-jwt` a `supabase functions deploy
   calendar-manage`). Do appky jde jen **client ID** — GitHub secret
   `GOOGLE_CLIENT_ID` (čtou ho `release.yml` i `deploy-web.yml`) a u lokálních
   buildů `--dart-define=GOOGLE_CLIENT_ID=...`. **Client secret nikdy nesmí
   do appky.**

5. Migrace 0023 zapíná rozšíření `pg_cron` (minutový tik, který spouští
   synchronizaci). Kdyby `create extension pg_cron` na hostovaném projektu
   selhalo, zapni ho v dashboardu (**Database → Extensions → pg_cron**) a
   migraci pusť znovu.

> **Na stavu publikování záleží.** Dokud je consent screen v režimu
> *Testing*, Google zahazuje refresh tokeny po **7 dnech** — synchronizace by
> potichu umřela každý týden a všichni by se museli propojit znovu (appka to
> pozná: karta přejde do stavu „odpojil se“ a hráč dostane push/e-mail).
> Jakmile je funkce ověřená v praxi, přepni consent screen na **In
> production** tlačítkem *Publish app* (jen v Cloud Console; s Play tracky to
> nesouvisí a appku to nikde nezveřejňuje). `calendar.app.created` je úzký
> scope a plné ověření se u něj často promíjí; kdyby Google review přece
> chtěl a nestálo to za to, zůstane Testing a týdenní re-link.

## 9. Sentry (volitelné hlášení chyb)

Založ projekt na <https://sentry.io> (platforma Flutter), zkopíruj jeho
**DSN** a předej ho jako `--dart-define=SENTRY_DSN=…` (lokálně) a jako
repository secret `SENTRY_DSN` (web i release build ho zapečou). Bez DSN je
Sentry vypnuté. Jeden projekt stačí pro web i Android — rozlišuje je tag
`environment` (`web` / `app`); přechodné síťové chyby se nehlásí.

## 10. Lokální vývoj, testy a schéma

- `flutter analyze && flutter test` — analyzér + unit/widget testy; CI je
  spouští na každý push i PR (`.github/workflows/ci.yml`).
- `supabase start` postaví celý backend lokálně v Dockeru (migrace se
  aplikují samy, `supabase db reset` ho postaví znovu od nuly). Smoke-test
  izolace kuželen:
  ```bash
  psql postgresql://postgres:postgres@127.0.0.1:54322/postgres \
    -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql
  ```
- Po přidání migrace spusť `tool/schema_snapshot.sh` (obnoví
  `supabase/schema.sql`, CI ho porovnává s čerstvou stavbou) a doplň
  [`docs/SCHEMA.md`](docs/SCHEMA.md).
- Edge funkce: `deno test supabase/functions` a `deno check --import-map
  supabase/functions/import_map.json supabase/functions/notify/index.ts
  supabase/functions/cancel/index.ts`; bez lokálního Dena přes Docker:
  `docker run --rm -v "$PWD/supabase/functions:/w" -w /w denoland/deno:latest test`.
- Vydání do Google Play (verze, changelog, recenzní účet) popisuje
  [`PLAY.md`](PLAY.md); CI/CD a nasazení backendu [`CICD.md`](CICD.md).

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
