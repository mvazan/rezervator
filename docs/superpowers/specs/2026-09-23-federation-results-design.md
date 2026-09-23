# Rezervátor — zápasy a výsledky z výsledkového servisu ČKA

*Stav k 2026-09-23, verze 1.2.8+12, migrace 0001–0044.*

## Proč

Zápasy dnes přicházejí z xlsx rozpisu přes `tool/import_matches.py` —
ručně, z příkazové řádky, a jen termíny. ČKA spustila
<https://vysledky.kuzelky.cz/>: rozpis, výsledky po hráčích a drahách,
odkaz na video. Chceme rozpis odtud brát sami a pravidelně, výsledky
ukládat u nás (do budoucna statistiky) a mít je v appce na jednom místě.

## Co web nabízí

Next.js, stránky se renderují na serveru a v HTML nesou čistý JSON (RSC
payload ve `self.__next_f.push([1,"…"])`). Nic se nemusí vyčítat
z tabulek.

- `/detail-souteze/<soutěž>?round=N` — kolo soutěže: `rounds` (seznam
  kol), `currentRound.matches[]` a `standings` (tabulka se `teamSlug`,
  `teamName`).
- `/detail-zapasu/<slug>` — `match`: `id` (stabilní, přeložení zápasu mění
  datum, ne id), `date`, `time`, `round`, `status`, `matchType`
  (`TEAMS_OF_6` / `TEAMS_OF_4`), `discipline` (`T100` / `T120`),
  `videoUrl`, `homeTeam`/`awayTeam` (`id`, `name`, `slug`), `competition`,
  `venue` (`slug`, `name`, `city`) a `results[]` po stranách:
  `teamPoints`, `totalPerformance`, `totalFull`, `totalSpare`,
  `totalErrors`, `totalSetPoints`, `playerResults[]` (pozice, hráč s `id`
  a `slug`, součty, `laneResults[]` po drahách) a `substitutions[]`.
- Stavy zápasu: `SCHEDULED → PREPARATION → IN_PROGRESS → FINISHED`, jinak
  `FORFEIT`. Během zápasu se dráhy plní průběžně.
- `/detail-kuzelny/<slug>` — kluby působící v kuželně (odkazy
  `/detail-klubu/<slug>`); `sitemap.xml` → `sitemap/competitions.xml` a
  `sitemap/matches-<sezóna>.xml` (slugy všech zápasů sezóny).
- Žádné cache hlavičky, žádné veřejné API (`/api/` robots zakazuje). Jedna
  kontrola = jeden GET HTML, 150–300 kB.

Formát soutěže je v datech — divize a ligy `T120` × 6, KP1 `T100` × 6,
KP2 `T100` × 4. Nikde se nezadává ručně.

## Rozhodnutí

- **Scraper nahradí xlsx import.** Běží v edge funkci `notify` na
  stávajícím job enginu (`notification_jobs`, minutový pg_cron tick).
  Žádná nová infrastruktura. Python nástroj se maže.
- **Čí zápasy:** všech týmů klubů, které hrají doma na naší kuželně
  (dnes TJ Sokol Brno IV, TJ Sokol Husovice, KS Devítka Brno, SKK Veverky
  Brno → 13 týmů v 6 soutěžích), doma i venku. Týmy jsou nová tabulka
  navázaná na oddíly (`clubs`).
- **Vždy update na místě, nikdy smazat a nahrát znovu.** Identita zápasu je
  id na webu (`import_key = cka:<id>`), takže uuid řádku, události
  v Google kalendáři, výjimky i výsledky přečkají přeložení. Stávající
  `rozpis:` řádky se při prvním syncu překlíčují.
- **Výsledky normalizovaně** (řádek na hráče a zápas), ne jsonb — kvůli
  budoucím statistikám. Jen rozpis po drahách je jsonb.
- **Zpětně se doplní** výsledky všech už odehraných zápasů sezóny.
- **Živé skóre:** na pozadí každých 15 min. K tomu obnovení na vyžádání
  (otevření detailu, tlačítko, stažení seznamu) s bránou 5 minut na
  serveru — vzor z Termínátora (`scrapeTtl` + ruční sync).
- **Nastavení v Správa → Oddíly** (ne nová položka „Svaz").
- **V appce nový 3. tab „Klubovna"** (mřížka karet: Výsledky, Kuželny; dřív navržený tab „Zápasy" je karta Výsledky), chronologicky, otevřený na dnešku;
  detail zápasu s výkony hráčů; video a skóre i v dialogu zápasů dne.
- **Dva PR:** A = backend + Správa (data tečou, vidět v Správa → Zápasy),
  B = tab Zápasy + detail + dialog dne.

## Datový model — migrace `0045_federation.sql`

### `teams`

| sloupec | |
|---|---|
| `id uuid` PK, `tenant_id` | |
| `name text` | **Klíč, který appka už používá** v `priority_slots.home_team/away_team`, `profiles.followed_teams`, `calendar_teams`, `team_colors`. Při založení se vezme stávající název z rozpisu, pokud se normalizovaně shoduje s webem, jinak název z webu. Správce ho může upravit. |
| `club_id uuid → clubs` null | Automaticky podle názvu klubu, správce může změnit. `on delete set null`. |
| `site_team_id int`, `site_slug text`, `site_name text` | Tým na webu (`tj-sokol-brno-iv-b-muzi`). |
| `competition_slug text`, `competition_name text` | Soutěž aktuální sezóny. |
| `active bool default true` | Vypnutý tým se nesynchronizuje. |

Unique `(tenant_id, name)` a `(tenant_id, site_slug)`. RLS: select
schválení a kiosk tenantu; zápis jen RPC pro správce (`update_team` —
název, oddíl, aktivita; mazat netřeba — vypnutý tým se nesynchronizuje). Přejmenování týmu **nepřepisuje**
stávající zápasy ani výběry hráčů; nový název se projeví od další
synchronizace (správce to vidí v nápovědě dialogu).

### `federation_sync`

PK `tenant_id`; `venue_slug text`, `enabled bool default false`,
`last_run_at`, `last_success_at`, `last_error text`, `last_report jsonb`.
Select správce; zápis RPC `set_federation_sync(venue_slug, enabled)`
(správce); ostatní sloupce jen server.

### `priority_slots` — nové sloupce

`video_url text`, `competition text`, `round smallint`, `site_slug text`
(odkaz „Na webu ČKA"), `site_match_id int`, `venue text`, `venue_slug text` (kuželna z detailu
zápasu — jakmile je známá, rozhoduje o doma/venku a doplní se do popisu).
Trigger `hand_edited` (0038)
se nemění: nové sloupce v jeho porovnání nejsou, sync je smí přepsat
vždy. Veřejný přehled (0043) je vydává dál (veřejná data svazu); hlídač
klíčů v `tenancy_rls.sql` se rozšíří.

### `match_results`

PK `match_id → priority_slots(id) on delete cascade`, `tenant_id`,
`status` (`scheduled | preparation | in_progress | finished | forfeit`),
`match_type`, `discipline`, a pro obě strany (`home_*`, `away_*`):
`points numeric`, `total int`, `fulls int`, `spares int`, `errors int`,
`set_points numeric`; `fetched_at timestamptz`. Select schválení a kiosk;
zápis jen server. V `supabase_realtime`.

### `match_player_results`

`id`, `match_id → priority_slots cascade`, `tenant_id`, `side` (`home |
away`), `position smallint`, `player_name`, `player_site_id int`,
`player_slug`, `fulls`, `spares`, `errors`, `total`, `set_points numeric`,
`team_points numeric`, `lanes jsonb` (`[{lane, fulls, spares, errors,
total, setPoints}]`). Střídání web zatím nevyplňuje (tvar neznáme) —
neukládá se. (`full` je v Postgresu rezervované slovo.) Při každém
stažení se hráči zápasu nahradí celí (delete + insert v jedné transakci —
tady to nevadí, nic na ně neodkazuje). RLS jako `match_results`,
v `supabase_realtime`.

### Serverové funkce (security definer, jen `service_role`)

- `apply_federation_matches(p_tenant, p_competition, p_matches jsonb)` —
  jedna transakce se `set_config('import.run','on',true)`; `created_by` je
  první schválený správce tenantu, `tenant_id` se píše výslovně. (Security
  definer funkce si roli přepnout nesmí; triggery `priority_conflicts`,
  `match_uklid_sync` a producenti kalendáře berou tenant z řádku, takže
  běží stejně jako při uložení v appce.) Pro každý zápas: existuje
  `cka:<id>` → update (zápasové sloupce jen bez `hand_edited`, jinak do
  reportu; `video_url`, `competition`, `round`, `site_*` vždy); jinak
  `legacy_id` (řádek `rozpis:` spárovaný v edge funkci) → překlíčování
  a update; jinak insert. Délka podle formátu: T100 × 4 90 min, T100 × 6
  150 min, T120 × 6 180 min; domácí zápas má úklid 30 min. Pak smaže
  **budoucí** `cka:` zápasy té soutěže, které na webu už nejsou; odehrané
  nikdy. Vrací report `{inserted, updated, rekeyed, deleted,
  skipped_hand_edited[]}`.
- `apply_federation_result(p_tenant, p_site_match_id, p_result jsonb)` —
  upsert `match_results`, nahrazení `match_player_results`, `video_url`,
  a pokud detail zná kuželnu, oprava doma/venku (`is_away`, popis).
- `enqueue_federation_jobs()` — noční producent (pg_cron
  `federation-nightly`, `0 1 * * *` UTC = 3:00): pro každý zapnutý tenant
  a každou soutěž jeho aktivních týmů job `federation_competition`
  (rozestup 1 min).

### RPC pro appku

- `set_federation_sync(p_venue_slug, p_enabled)`,
  `request_federation_discovery()`, `request_federation_sync()` — správce.
  Poslední dvě zařadí job se zpožděním 0 a hned zavolají
  `trigger_notification_jobs()`.
- `refresh_match(p_match_id) returns text` — kdokoli schválený v tenantu.
  Když je zápas živý (`preparation`, `in_progress`, nebo `scheduled`
  v okně T−1 h až T+6 h) a `fetched_at` je starší než 5 minut, zařadí
  `federation_match` se zpožděním 0, hned spustí tick a vrátí `queued`;
  jinak `fresh` nebo `not_live`. Brána je na serveru, klient ji neobejde.

## Edge funkce

### `_shared/federation.ts` — čistý parser (testy na uložených stránkách)

- `rscText(html)` — spojí řetězce ze `self.__next_f.push`.
- `valueAfter(text, key)` — hodnota za `"key":` jako JSON (vyvážené
  závorky, ohled na řetězce).
- `parseCompetition(html)`, `parseMatch(html)`, `parseVenueClubs(html)`,
  `parseSitemapLocs(xml)`, `matchFormat(matchType, discipline)`,
  `nextCheckpoint(status, start, now)`, `normalizeTeam(name)`,
  `pairLegacy(matches, legacyRows)`.
- Chybí-li očekávaný klíč (web změnil strukturu) → výjimka; nic se
  nepřepíše.

### Joby (`_shared/federation_jobs.ts`, volá je `notify`)

- `federation_discover {tenant_id}` — stránka kuželny → kluby; sitemapa
  zápasů sezóny → soutěže, kde kluby hrají; stránka každé soutěže
  (tabulka) → týmy. Upsert `teams` (nové aktivní, stávajícím obnoví
  soutěž a web-údaje, název a oddíl nechá). Řeší i novou sezónu.
- `federation_competition {tenant_id, competition_slug}` — všechna kola
  (`?round=1` dá seznam, pak ostatní postupně, ~24 GET). Zápasy, kde hraje
  aktivní tým tenantu, spáruje se `rozpis:` řádky a pošle do
  `apply_federation_matches`. Založí `federation_match` pro zápasy do
  48 h a pro každý odehraný zápas bez hotového výsledku (**zpětné
  doplnění** — první běh stáhne celou dosavadní sezónu). Zapíše
  `federation_sync.last_*`.
- `federation_match {tenant_id, site_match_id, slug}` — detail zápasu →
  `apply_federation_result`, pak se sám přeplánuje:

  | stav | další kontrola |
  |---|---|
  | `SCHEDULED`, víc než 24 h před | T−24 h |
  | `SCHEDULED`, 24 h – 1 h před | T−1 h |
  | `SCHEDULED`, T−1 h až T+6 h | +15 min (live stream se objeví) |
  | `PREPARATION`, `IN_PROGRESS` (do T+12 h) | +15 min |
  | `FINISHED`, `FORFEIT` | T+24 h, pak T+3 d, pak konec |
  | cokoli jiného po oknu | T+24 h, po T+3 d konec |

- Tick zpracuje federační joby zvlášť od kalendářových (vlastní dotaz a
  limity — 1 soutěž, 1 discovery a 10 zápasů za tick, souběžně 3), aby
  zpětné doplnění nevyhladovělo kalendář. Job si před prací „pronajme“
  `run_at` o 10 min dopředu (podmíněný update), takže dva překrývající
  se ticky ho nezpracují dvakrát. Chyba → backoff `2^attempts` min, max 5
  pokusů, text do `federation_sync.last_error`.
- `User-Agent: Rezervator (+https://rezervator.online)`, timeout 15 s.

**Zátěž:** noc ~150 GET; zápasový den 20–40 GET na zápas; sezóna řádově
10⁴ GET. Tick je jedna invokace edge funkce bez ohledu na počet jobů —
daleko pod limity (Free 500 000 invokací/měsíc). Stažení stránky ČKA je
příchozí provoz, do egressu se nepočítá.

## Appka — PR A (Správa)

- Modely `Team`, `FederationSync` (`MatchResult`, `MatchPlayerResult` a
  nová pole `PrioritySlot` přijdou s PR B, kde se čtou).
- `teamsProvider`, `federationSyncProvider` (živé řádky jako ostatní),
  API pro RPC výše, reset při přepnutí tenantu. `ourTeamsProvider` bere
  aktivní týmy z `teams`; prázdná tabulka → dnešní odvození ze zápasů.
- **Správa → Oddíly:** nahoře karta „Výsledkový servis ČKA“ — kuželna
  (slug, předvyplněno `tj-sokol-brno-iv`), přepínač, „Načíst týmy
  z webu“, „Synchronizovat teď“, poslední běh a chyba. Pod každým oddílem
  jeho týmy (název, soutěž, přepínač aktivity, úprava názvu a oddílu),
  týmy bez oddílu v sekci „Nezařazené týmy“.
- Správa → Zápasy: `cka:` zápasy mají podtitul „ze svazu“.
- Novinka ve web-only dávce changelogu.

## Appka — PR B (tab Klubovna: Výsledky, Kuželny)

Obrazovka níže je karta **Výsledky** v tabu Klubovna (viz Kuželny), ne
samostatný tab.

- `HomeView.clubhouse` (třetí; `default_view` v DB zůstává
  calendar/trainings). Třetí destinace v railu i spodní liště.
- Seznam: čipy „Moje“ (sledované týmy, výchozí pokud nějaké jsou), každý
  aktivní tým, „Vše“. Po dnech chronologicky od začátku sezóny, otevře se
  na prvním nadcházejícím zápase. Řádek: trofej v barvě týmu, „Domácí –
  Hosté“, „so 27. 9. · 10:00 · Jihomoravská divize, 5. kolo · doma“;
  vpravo `6 : 2` a kolky `2555 : 2480`, živý „• probíhá“, budoucí „–“;
  ▶ při videu. Stažení dolů obnoví živé zápasy.
- Detail: týmy, body, setové body, Plné/Dorážka/Chyby/Výkon, hráči po
  pozicích s rozkladem po drahách, „Video“, „Na webu ČKA“, ⟳ a „Výsledky
  z webu: před N min“. Otevření živého zápasu zavolá `refresh_match`.
- Dialog zápasů dne: skóre, ikona videa, ťuknutí otevře detail.

## Kuželny (backend v PR A, UI v PR B)

Hráči chtějí mít po ruce kuželny, kde naše týmy hrají — kontakt, adresu a
technické informace. Stránka `/detail-kuzelny/<slug>` je nese jako HTML
(sekce `<h2>`/`<h3>` a dvojice `<dt>`/`<dd>`), ne jako čistý JSON:
adresa (odkaz na mapy.com se souřadnicemi `x` = délka, `y` = šířka),
telefon (`tel:`), e-mail (`mailto:`), uvedeno do provozu, rekonstrukce,
zázemí pro diváky a hráče, dráhy, kuželky, stavěč, kolaudace, kluby. „–“
znamená prázdnou hodnotu.

- **Tabulka `venues`** (tenant, `slug` unique v tenantu): `name`,
  `address`, `phone`, `email`, `lat`, `lng`, `sections jsonb`
  (`[{title, items: [{label, value}]}]` — technické údaje obecně, bez
  sloupce na každé pole, appka je vykreslí tak, jak jsou), `clubs text[]`,
  `fetched_at`. Select schválení a kiosk tenantu, zápis jen server.
- **Které kuželny:** naše (`federation_sync.venue_slug`) a každá, kterou
  sync zná z detailu zápasu (`priority_slots.venue_slug`).
- **Kdy:** job `federation_venue {tenant_id, slug}` — hned, když detail
  zápasu přinese kuželnu, kterou ještě nemáme; noční producent obnoví
  kuželny starší než 7 dní. Nejvýš 3 za tick.
- **UI (PR B):** třetí tab **Klubovna** — mřížka karet jako Správa
  kuželny, pro všechny přihlášené. Karty: **Výsledky** (dřívější návrh tabu
  Zápasy) a **Kuželny** (seznam abecedně s hledáním; detail s tlačítky
  Zavolat / Napsat e-mail / Navigovat a sekcemi technických údajů). Detail
  venkovního zápasu odkáže na svou kuželnu. Další karty budou přibývat.

## Nasazení

Nejdřív funkce (`notify` musí znát nové druhy jobů — stará verze neznámé
joby maže), pak migrace. Pak v Správa → Oddíly zapnout kuželnu, „Načíst
týmy“, zkontrolovat názvy, „Synchronizovat teď“ a ověřit report
(překlíčované `rozpis:` řádky, žádné duplicity v Google kalendáři).

## Mimo rozsah

- Dorost Husovic na webu zatím není — jeho `rozpis:` řádky zůstávají,
  sync je nemaže, upravují se ručně.
- Statistiky hráčů (data na ně jsou připravená).
- Střídání hráčů v zápase.
- Přejmenování týmu napříč výběry hráčů (`followed_teams` atd.).
