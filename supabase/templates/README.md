# Auth e-mail šablony

České šablony přihlašovacích e-mailů. Aplikují se přes `supabase config push`
(sekce `[auth.email.template.*]` v `../config.toml`).

- `magic_link.html` — přihlašovací („magic link") e-mail. Obsahuje **jak
  klikací odkaz** (`{{ .ConfirmationURL }}`) **tak číselný kód** (`{{ .Token }}`).
  Kód je nutný: některé e-mailové aplikace (Seznam) při otevření odkazu zahodí
  parametr `?code=`, takže se přihlášení přes odkaz nedokončí — přihlašovací
  obrazovka proto nabízí „Zadat kód z e-mailu".

Změnu nasadíš:

```bash
SMTP_PASS=<gmail-app-password> supabase config push
```
