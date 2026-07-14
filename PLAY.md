# Rezervátor — vydání do Google Play

Stejný postup jako u Termínátoru: **push tagu `v*` → `release.yml`** postaví
podepsané APK + AAB, vydá je na stránce **Releases** a nahraje AAB na
**internal testing** track Google Play jako koncept.

```
git tag v1.1.0 → release.yml → podepsané APK+AAB → GitHub Releases
                                              └→ AAB → Play internal (draft)
```

Podpisový klíč (`upload-keystore.jks`) i `key.properties` jsou **gitignored** —
repozitář je veřejný, nikdy je necommituj. CI si je obnoví ze secretů.

---

## Jednorázové nastavení

### 1. Podpisový klíč (už vytvořen)

`android/app/upload-keystore.jks`, alias `rezervator`, platnost 10000 dní.
**Zálohuj ho** (klíč + heslo) na bezpečné místo — každá aktualizace v Play
musí být podepsaná tímtéž klíčem; při ztrátě se aplikace musí odinstalovat a
nainstalovat znovu. Base64 pro secret:

```bash
base64 -i android/app/upload-keystore.jks | pbcopy
```

### 2. Účet Google Play Console

Vývojářský účet už existuje (Termínátor). Vytvoř novou aplikaci:

- Play Console → **Vytvořit aplikaci** → název „Rezervátor", čeština, App.
- **Package name je pevný: `cz.kuzelky.rezervator`** (nastaví se prvním
  nahráním AAB, pak už nejde změnit).
- Projdi úvodní dotazník (obsah, cílová skupina, ochrana soukromí…). Než se
  dá vydávat i na internal testing, Play chce vyplněné povinné sekce
  (App content, Store listing s ikonou + popisem, kategorie).

### 3. Servisní účet pro automatické nahrávání

Můžeš **znovu použít `play-uploader` z Termínátoru** — stačí mu dát přístup
k nové aplikaci:

- Play Console → **Users and permissions** → pozvi e-mail servisního účtu
  (`…@….iam.gserviceaccount.com`) → u aplikace Rezervátor přiděl oprávnění
  **„Release apps to testing tracks"** (a „View app information").
- Pokud servisní účet nemáš: Google Cloud Console → IAM → Service Accounts →
  vytvoř `play-uploader`, stáhni **JSON klíč**; v Play Console → Setup → API
  access propoj projekt a účet povol.

### 4. GitHub Actions secrets

Repo → Settings → Secrets and variables → Actions. `SUPABASE_URL`,
`SUPABASE_ANON_KEY` a `FIREBASE_*` už existují (používá je `deploy-web.yml`).
Doplň:

| Secret | Hodnota |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | výstup příkazu `base64` z kroku 1 |
| `ANDROID_KEYSTORE_PASSWORD` | heslo ke keystore |
| `ANDROID_KEY_ALIAS` | `rezervator` |
| `ANDROID_KEY_PASSWORD` | heslo ke klíči (stejné jako storePassword) |
| `PLAY_SERVICE_ACCOUNT_JSON` | celý obsah JSON klíče servisního účtu |

### 5. První nahrání AAB udělej ručně

Play API (a tím i `release.yml`) umí novou aplikaci publikovat **až po prvním
ručním nahrání**. Postav AAB lokálně a nahraj ho v Play Console:

```bash
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
flutter build appbundle --release \
  --dart-define=SUPABASE_URL=https://wgwijvcnslkesyqgaeul.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=sb_publishable_ukPH3XYgzuyQNvxNYF_KJQ_BY1pUu7f
# → build/app/outputs/bundle/release/app-release.aab
```

Play Console → Rezervátor → **Testing → Internal testing** → Create release →
nahraj `app-release.aab`. Při prvním nahrání Play nabídne **Play App Signing**
— přijmi (Google si drží finální podpisový klíč, náš `upload-keystore.jks`
zůstává jen uploadovací; to je doporučený režim). Přidej testery
(seznam e-mailů / Google skupina), vydej.

## Každé další vydání

```bash
# 1. zvyš verzi v pubspec.yaml, např. 1.1.0+2  (číslo za + = versionCode MUSÍ růst)
git commit -am "Bump version to 1.1.0"

# 2. anotovaný tag; tělo zprávy = text „Co je nového" pro Play
git tag -a v1.1.0 -m "v1.1.0" -m "- Oprava přesunů rezervací
- Rychlejší kalendář"
git push origin main v1.1.0
```

Za pár minut je na stránce **Releases** podepsané `rezervator-v1.1.0.apk`
(sdílej odkaz) a v Play na internal tracku čeká **koncept** — v Play Console
ho zkontroluj a vydej testerům.

> Google Play recenze / demo přístup: viz interní poznámky (u Termínátoru
> běží přes vyhrazený demo účet + `DEMO_PASSWORD`). Pokud bude Rezervátor
> potřebovat totéž, doplníme demo bypass a `DEMO_PASSWORD` secret zvlášť.
