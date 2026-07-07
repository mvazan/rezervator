# Rezervátor — Setup (jednorázově, ~15 minut klikání)

Aplikace je hotová, chybí jí jen vlastní backend účet a pár kliknutí v
Supabase. Kroky 1–4 rozjedou rezervace tréninků v aplikaci (mobil i desktop).
Krok 5 nasadí webovou verzi na GitHub Pages. Krok 6 zapne e-mailové
notifikace. Krok 7 shrnuje, co v této fázi ještě záměrně nefunguje.

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
6. **Push notifikace zatím nejsou aktivní** — potřebují `FIREBASE_SERVICE_ACCOUNT`,
   který se nastavuje až ve Fázi 5. Do té doby chodí všem uživatelům e-mail,
   takže nikomu žádná notifikace neujde — jen bez FCM push zvonění na mobilu.

## 7. Co zatím nefunguje

Tohle je Fáze 0–3 — kostra appky, přihlášení, statický rozvrh a notifikace
e-mailem. Záměrně chybí:

- **Kiosek** (dotykový režim pro tablet na kuželně) — Fáze 4.
- **Reporty** (docházka, statistiky) — Fáze 5.
- **Push notifikace** (FCM) — aktivují se ve Fázi 5 spolu s `FIREBASE_SERVICE_ACCOUNT`;
  do té doby e-mail (Fáze 3) pokrývá všechny stejné události.
