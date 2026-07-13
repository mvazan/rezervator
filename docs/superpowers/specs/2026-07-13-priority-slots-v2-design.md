# Prioritné sloty v2 — zjednodušenie modelu, menu, ovládania a notifikácie

Schválené v konverzácii 2026-07-13 (4 rozhodnutia potvrdené používateľom).

## Cieľový model (slovami používateľa)

Admin si navolí tréningové sloty (týždenná šablóna). Tie sa dajú
override-núť = vytvorenie **prioritizovaného slotu** — dva druhy:
**tréningový** (bookovateľný, dnešný „jednodenný blok") a **blokujúci**
(zápas, úklid, vlastné typy — predvytvárateľné šablóny). Vstavané typy:
**Zápas** a **Úklid před zápasem**. Zápasy = samostatná kategória v menu;
blokácie sa presúvajú do Výjimek dnů. Editácia v kalendári: **click =
edit** (ceruzka v rohu tréningového slotu; blokujúci pás klik kamkoľvek),
**hold = drag & drop** (posun len na prázdne miesto, v rámci dňa, snap
15 min). Zmena času / zrušenie rezervácie hráča → adminovi vyskočí dialóg:
1) potvrdiť štandardnú notifikáciu („termín přesunut z X na Y"),
2) vlastná správa, 3) neodoslať (pri viacnásobnom presúvaní; poslednú
zmenu má admin odoslať).

## Čo sa tým MAŽE (odpoveď na „dá sa to zjednodušiť?")

- `prep_minutes`/`blockingStart` prep-extended okná — úklid je odteraz
  samostatný blokujúci slot prepojený so zápasom (`parent_id`, cascade
  delete). Zmizne najzáludnejší kus domény aj serverových predikátov.
- Dva pojmy (jednodenný blok vs. blokácia) → jedna rodina „prioritný
  slot" v UI.
- Väčšina potvrdzovacích dialógov — D&D na prázdno nemá kolízie.
- Obrazovka „Zápasy a blokace" — nahradia ju „Zápasy" + sekcia Blokace
  vo Výjimkách dnů (aj so správou typov).

## Fázy (každá = PR + nasadenie)

### Fáza 1 — model + menu (migrácia 0009)
- Builtin typ „Úklid před zápasem" (blokujúci, celá kuželna); seed pre
  existujúce tenanty + rozšírenie `seed_tenant_defaults`.
- `priority_slots.parent_id uuid references priority_slots on delete
  cascade` — úklid prepojený so zápasom; migrácia existujúcich
  `prep_minutes > 0` na úklid sloty.
- Server: `create_reservation`, `move_reservation`, cancel triggery —
  kolízne predikáty BEZ prep-extension (každý slot blokuje len svoje
  okno).
- Doména: preč `blockingStart`, `isPrep`, `calendarStart` (== startsAt),
  prep pásy v rendereroch (úklid je normálny pás so svojím typom).
- Dialóg zápasu: pole „příprava (min)" spravuje prepojený úklid slot
  (vytvorí/posunie/zmaže). `prep_minutes` v DB ostáva len ako uložená
  dĺžka pre dialóg.
- Menu: „Zápasy" (len zápasy); Výjimky dnů = zavřené dny + jednodenní
  změny + Blokace (+ typy blokácií). admin_screen preusporiadať.

### Fáza 2 — kalendárové ovládanie
- Click na ceruzku tréningového slotu / kamkoľvek na blokujúci pás =
  edit dialóg (dnešný long-press zaniká).
- Hold (LongPress) = drag & drop presun slotu v rámci dňa, snap 15 min,
  drop povolený len na prázdne miesto (žiadne kolízie ⇒ žiadne warningy);
  presun zápasu ťahá úklid so sebou.
- Tap do prázdna (admin) = nový slot ostáva.

### Fáza 3 — notifikačný dialóg
- RPC `move_reservation`/`move_day_reservations`/cancel cesty dostanú
  `p_notify` + `p_message`; notify EF rozšírená o typ „zmena termínu"
  („termín přesunut z X na Y" / vlastný text).
- Admin dialóg pri každej akcii meniacej cudzie rezervácie: Odoslať /
  Vlastná správa / Neodoslať (default Odoslať; pri hromadnom presune si
  admin poslednú zmenu odošle sám — zodpovednosť admina).

## Rozhodnutia používateľa
- Click-to-edit: ceruzka v rohu (dráhy ostávajú rezerváciám).
- D&D: len v rámci dňa.
- Úklid: auto pri zápase cez pole „příprava".
- Poradie: 1 → 2 → 3.
