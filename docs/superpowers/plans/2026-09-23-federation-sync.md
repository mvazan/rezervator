# Federation sync (PR A: backend + Správa) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Matches and results of our alley's teams flow from https://vysledky.kuzelky.cz into Supabase on a schedule (plus on demand), replacing the xlsx importer; the admin configures it in Správa → Oddíly.

**Architecture:** A pure Deno parser (`_shared/federation.ts`) turns the site's server-rendered HTML (embedded RSC JSON) into typed matches/results. Job handlers (`_shared/federation_jobs.ts`) run inside the existing `notify` edge function on the existing `notification_jobs` queue + minutely pg_cron tick; all writes go through security-definer SQL functions in migration `0045_federation.sql`. The Flutter app gets `teams` / `federation_sync` streams and an admin card.

**Tech Stack:** Supabase (Postgres 15, pg_cron, pg_net, RLS), Deno edge functions (TypeScript, `jsr:@std/assert@1`), Flutter + Riverpod 3.

**Spec:** `docs/superpowers/specs/2026-09-23-federation-results-design.md` (Czech). PR B (tab Zápasy, detail, dialog) is a separate plan after this merges.

## Global Constraints

- Repo root: `/Users/mvazan/Home/rezervator`, branch `federation-sync`. One commit per task (more is fine), never push.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- UI copy is Czech, code/comments English. Default to no comments; one short line only when the WHY is non-obvious.
- Site base URL `https://vysledky.kuzelky.cz`; `User-Agent: Rezervator (+https://rezervator.online)`; request timeout 15 s.
- Match identity: `priority_slots.import_key = 'cka:<site match id>'`. Always update in place, never delete + re-insert. Past matches are never deleted.
- Durations: T100 × 4 players = 90 min, T100 × 6 = 150 min, T120 × 6 = 180 min, anything else 180 min. Home match prep (úklid) = 30 min; away = 0.
- Description format: `<competition> · <round>. kolo`, away match with known venue: `<competition> · <round>. kolo · <venue name>`.
- Checkpoints for a match job (T = start in Europe/Prague):
  SCHEDULED: before T−24h → T−24h; before T−1h → T−1h; before T+6h → now+15min.
  PREPARATION / IN_PROGRESS: before T+12h → now+15min.
  FINISHED / FORFEIT: nothing extra.
  Then for every status: before T+24h → T+24h; before T+72h → T+72h; else stop (null).
- On-demand refresh gate: 5 minutes, server-side (`refresh_match`).
- Per tick: at most 1 `federation_discover`, 1 `federation_competition`, 10 `federation_match` jobs; match jobs 3 at a time. Lease = push `run_at` 10 min ahead with a conditional update. Failure backoff `2^attempts` minutes, drop after 5 attempts.
- Nightly cron `federation-nightly` at `0 1 * * *` (UTC).
- Supabase migrations: new tables `revoke all … from anon` and `revoke insert, update, delete … from authenticated` (0017 default privileges would otherwise grant them), `grant all … to service_role`. Server functions: `revoke all on function … from public, anon, authenticated; grant execute … to service_role`. App RPCs: `revoke all … from public, anon; grant execute … to authenticated`.
- Postgres reserved word: never name a column `full` — player/team columns are `fulls`, `spares`, `errors`, `total`.
- Local checks: `flutter analyze` → `No issues found!`; `flutter test` green; `deno test --allow-read supabase/functions` green; `deno check --import-map supabase/functions/import_map.json supabase/functions/notify/index.ts` clean; migrations: `supabase db reset` then `psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -X -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql`; snapshot `tool/schema_snapshot.sh` and commit `supabase/schema.sql`.
- Lists sorted with `compareCzech` (alphabetical) or chronologically — never newest-first.

## File structure

| File | Responsibility |
|---|---|
| `supabase/functions/_shared/federation.ts` (new) | Pure parsing + domain helpers (no IO). |
| `supabase/functions/_shared/federation_test.ts` (new) | Parser tests on saved pages. |
| `supabase/functions/_shared/fixtures/federation/*` (new) | Saved site pages (HTML/XML). |
| `supabase/migrations/0045_federation.sql` (new) | Tables, columns, server functions, RPCs, cron. |
| `supabase/tests/tenancy_rls.sql` | New assertions for 0045 + public_week key guard. |
| `supabase/schema.sql`, `docs/SCHEMA.md` | Snapshot + docs. |
| `supabase/functions/_shared/federation_jobs.ts` (new) | Pure planners + job IO + tick processing. |
| `supabase/functions/_shared/federation_jobs_test.ts` (new) | Planner/outcome tests. |
| `supabase/functions/notify/index.ts` | Dispatch federation jobs from the CRON tick. |
| `.github/workflows/ci.yml` | `deno test --allow-read`. |
| `lib/domain/models.dart`, `lib/data/cache.dart`, `lib/data/providers.dart` | `Team`, `FederationSync`, streams, API, `ourTeamsProvider`. |
| `lib/features/admin/clubs_screen.dart`, `lib/features/admin/widgets/federation_card.dart` (new), `lib/features/admin/widgets/team_dialog.dart` (new) | Správa → Oddíly UI. |
| `lib/features/admin/matches_screen.dart`, `lib/core/ui.dart`, `lib/features/profile/changelog_data.dart` | Subtitle, error texts, changelog. |
| `tool/import_matches.py` (delete), `README.md` | Old importer out. |

---

### Task 1: Parser `_shared/federation.ts` + fixtures

**Files:**
- Create: `supabase/functions/_shared/federation.ts`
- Create: `supabase/functions/_shared/federation_test.ts`
- Create: `supabase/functions/_shared/fixtures/federation/` — copy these 8 files from `/private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/fx/` (saved 2026-09-23 07:43): `competition_round_finished.html` (Jihomoravská divize ?round=1, 7 FINISHED, T120 × 6), `competition_round_video.html` (2. KLM A ?round=2, has a `videoUrl`), `competition_current_teams_of_4.html` (KP2 sever A, TEAMS_OF_4, has `standings`, one PREPARATION), `match_finished.html` (Divize AS kolo 1 Rudná A – Vršovice A, FINISHED 7 : 1, players with lanes), `match_scheduled.html` (1. KLM kolo 1 Odry – Sadská, SCHEDULED, venue TJ Odry), `venue.html` (kuželna tj-sokol-brno-iv), `sitemap_index.xml`, `sitemap_competitions.xml`.
- Modify: `.github/workflows/ci.yml` — the line `deno test supabase/functions` becomes `deno test --allow-read supabase/functions`.

**Interfaces — Produces** (exact exports, used by Task 3):

```ts
export type MatchStatus = "SCHEDULED" | "PREPARATION" | "IN_PROGRESS" | "FINISHED" | "FORFEIT";
export type SiteTeam = { id: number; name: string; slug: string };
export type SiteMatch = {
  id: number; slug: string; date: string; time: string | null; round: number;
  status: MatchStatus; matchType: string; discipline: string; videoUrl: string | null;
  homeTeam: SiteTeam; awayTeam: SiteTeam; competition: { slug: string; name: string };
};
export type SiteLane = { lane: number; fulls: number | null; spares: number | null; errors: number | null; total: number | null; setPoints: number | null };
export type SitePlayer = {
  position: number; name: string; siteId: number | null; slug: string | null;
  fulls: number | null; spares: number | null; errors: number | null; total: number | null;
  setPoints: number | null; teamPoints: number | null; lanes: SiteLane[];
};
export type SiteSide = {
  points: number | null; total: number | null; fulls: number | null; spares: number | null;
  errors: number | null; setPoints: number | null; players: SitePlayer[];
};
export type SiteMatchDetail = SiteMatch & {
  venue: { slug: string; name: string } | null; home: SiteSide | null; away: SiteSide | null;
};
export type SiteStanding = { teamSlug: string; teamName: string };
export type SiteCompetition = {
  name: string; roundIds: number[]; currentRound: number; matches: SiteMatch[]; standings: SiteStanding[];
};
export type VenueClub = { slug: string; name: string };
export type LegacyRow = { id: string; import_key: string; date: string; home_team: string; away_team: string };
export type PairCandidate = { siteId: number; date: string; round: number; home: string; away: string };

export const HOME_PREP_MINUTES = 30;
export function rscText(html: string): string;
export function valueAfter(text: string, marker: string): unknown;   // marker = literal text right before the value, e.g. '"rounds":'
export function parseCompetition(html: string): SiteCompetition;
export function parseMatch(html: string): SiteMatchDetail;
export function parseVenueClubs(html: string): VenueClub[];
export function parseSitemapLocs(xml: string): string[];
export function competitionSlugsForClubs(matchLocs: string[], clubSlugs: string[]): string[];
export function teamBelongsToClub(teamSlug: string, clubSlug: string): boolean;
export function matchFormat(matchType: string, discipline: string): { players: number; throws: number; durationMin: number };
export function endTime(start: string, minutes: number): string;          // "HH:MM", capped at "23:59"
export function normalizeTeam(name: string): string;
export function pairLegacy(candidates: PairCandidate[], legacy: LegacyRow[]): Map<number, string>;
export function nextCheckpoint(status: MatchStatus, start: Date, now: Date): Date | null;
export function resultPayload(d: SiteMatchDetail): Record<string, unknown>;
```

Background on the pages (verified 2026-09-23): each `self.__next_f.push([1,"…"])` script carries a JSON string literal; concatenated they form the RSC text in which data objects appear verbatim, e.g. `{"data":{"title":"Divize AS","competitionSeasons":[…],"currentSeasonId":20,"rounds":[{"id":"1","name":"1. kolo"},…],"currentRound":{"id":"2","name":"2. kolo","matches":[…]},"attachments":[],"standings":{"total":[{"position":1,"teamSlug":"…","teamName":"…",…}],…}}}` and `{"match":{"id":4859,"slug":"…","date":"2026-09-16","time":"17:30","round":1,"status":"FINISHED","matchType":"TEAMS_OF_6","discipline":"T100","videoUrl":null,"penaltiesPublic":[],"homeTeam":{"id":265,"name":"TJ Sokol Rudná A","slug":"tj-sokol-rudna-a-muzi","club":{…}},"awayTeam":{…},"competition":{"id":46,"slug":"divize-as-2026-2027","name":"Divize AS",…},"results":[{"isHome":true,"teamPoints":7,"totalPerformance":2555,"totalFull":1809,"totalSpare":746,"totalErrors":44,"totalSetPoints":8.5,"playerResults":[{"position":1,"teamPoints":1,"setPoints":1,"totalFull":297,"totalSpare":110,"totalErrors":9,"totalPerformance":407,"player":{"id":2395,"firstName":"Lucie","lastName":"Mičanová","slug":"lucie-micanova"},"laneResults":[{"laneNumber":1,"full":156,"spare":57,"errors":5,"total":213,"setPoints":0},…]},…],"substitutions":[]},{"isHome":false,…}],"venue":{"id":200,"name":"TJ Odry","slug":"tj-odry",…},"referee":null},…}`. A scheduled match has `results` with `null` totals and player entries without `player` and with empty `laneResults`. Strings like `"$undefined"` are RSC placeholders — treat as absent. The venue page lists clubs as `<a … href="/detail-klubu/tj-sokol-husovice"><img alt="TJ Sokol Husovice" …/><span class="text-sm font-bold">TJ Sokol Husovice</span></a>`.

- [ ] **Step 1: Copy fixtures, write the failing tests**

```bash
mkdir -p supabase/functions/_shared/fixtures/federation
cp /private/tmp/claude-501/-Users-mvazan-Home/f84a2aec-e721-4071-a80d-56057b8d0e94/scratchpad/fx/* supabase/functions/_shared/fixtures/federation/
```

`supabase/functions/_shared/federation_test.ts`:

```ts
import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  competitionSlugsForClubs, endTime, matchFormat, nextCheckpoint, normalizeTeam,
  pairLegacy, parseCompetition, parseMatch, parseSitemapLocs, parseVenueClubs,
  resultPayload, rscText, teamBelongsToClub, valueAfter,
} from "./federation.ts";

const fixture = (name: string) =>
  Deno.readTextFileSync(new URL(`./fixtures/federation/${name}`, import.meta.url));

Deno.test("rscText joins the flight chunks into readable JSON text", () => {
  const html = `<script>self.__next_f.push([1,"a:{\\"x\\":1}"])</script>` +
    `<script>self.__next_f.push([1,"\\n\\"y\\":\\"č\\""])</script>`;
  assertEquals(rscText(html), 'a:{"x":1}\n"y":"č"');
});

Deno.test("valueAfter reads a balanced value, braces inside strings included", () => {
  const text = 'noise "k":{"a":"}{","b":[1,{"c":2}]} tail';
  assertEquals(valueAfter(text, '"k":'), { a: "}{", b: [1, { c: 2 }] });
  assertEquals(valueAfter('"n":42,', '"n":'), 42);
  assertThrows(() => valueAfter("nothing here", '"k":'));
});

Deno.test("a competition round page: rounds, matches, formats", () => {
  const c = parseCompetition(fixture("competition_round_finished.html"));
  assertEquals(c.currentRound, 1);
  assert(c.roundIds.length >= 20);
  assertEquals(c.roundIds[0], 1);
  assertEquals(c.matches.length, 7);
  assert(c.matches.every((m) => m.status === "FINISHED" && m.round === 1));
  assert(c.matches.every((m) => m.matchType === "TEAMS_OF_6" && m.discipline === "T120"));
  assertEquals(c.name, c.matches[0].competition.name);
  const m = c.matches[0];
  assert(m.id > 0 && m.slug.startsWith("jihomoravska-divize-2026-2027-kolo-1-"));
  assert(/^\d{4}-\d{2}-\d{2}$/.test(m.date) && /^\d{2}:\d{2}$/.test(m.time!));
});

Deno.test("video links and four-player teams come through", () => {
  const v = parseCompetition(fixture("competition_round_video.html"));
  assert(v.matches.some((m) => m.videoUrl?.startsWith("https://www.youtube.com/")));
  const k = parseCompetition(fixture("competition_current_teams_of_4.html"));
  assert(k.matches.every((m) => m.matchType === "TEAMS_OF_4"));
  assert(k.standings.length > 0);
  assert(k.standings.some((s) => s.teamSlug === "tj-sokol-husovice-e-muzi"));
});

Deno.test("a finished match: venue, totals, players with lanes", () => {
  const d = parseMatch(fixture("match_finished.html"));
  assertEquals(d.id, 4859);
  assertEquals(d.status, "FINISHED");
  assertEquals(d.homeTeam.name, "TJ Sokol Rudná A");
  assertEquals(d.home!.points, 7);
  assertEquals(d.home!.total, 2555);
  assertEquals(d.home!.fulls, 1809);
  assertEquals(d.home!.setPoints, 8.5);
  assertEquals(d.home!.players.length, 6);
  const p = d.home!.players[0];
  assertEquals(p.name, "Lucie Mičanová");
  assertEquals(p.siteId, 2395);
  assertEquals(p.total, 407);
  assertEquals(p.lanes[0], { lane: 1, fulls: 156, spares: 57, errors: 5, total: 213, setPoints: 0 });
  assert(d.away!.players.length === 6);
  assert(d.venue !== null && d.venue.slug.length > 0);
});

Deno.test("a scheduled match has no players and no totals", () => {
  const d = parseMatch(fixture("match_scheduled.html"));
  assertEquals(d.status, "SCHEDULED");
  assertEquals(d.venue, { slug: "tj-odry", name: "TJ Odry" });
  assertEquals(d.home!.total, null);
  assertEquals(d.home!.players, []);
});

Deno.test("parsers refuse a page without the data", () => {
  assertThrows(() => parseCompetition("<html></html>"));
  assertThrows(() => parseMatch("<html></html>"));
});

Deno.test("venue clubs and sitemaps", () => {
  const clubs = parseVenueClubs(fixture("venue.html"));
  assertEquals(clubs.map((c) => c.slug).sort(), [
    "ks-devitka-brno", "skk-veverky-brno", "tj-sokol-brno-iv", "tj-sokol-husovice",
  ]);
  assertEquals(clubs.find((c) => c.slug === "tj-sokol-husovice")!.name, "TJ Sokol Husovice");
  const index = parseSitemapLocs(fixture("sitemap_index.xml"));
  assert(index.some((u) => /\/sitemap\/matches-\d+\.xml$/.test(u)));
  const comps = parseSitemapLocs(fixture("sitemap_competitions.xml"));
  assert(comps.includes("https://vysledky.kuzelky.cz/detail-souteze/jihomoravska-divize-2026-2027"));
});

Deno.test("competitions where the clubs play, from match slugs", () => {
  const locs = [
    "https://vysledky.kuzelky.cz/detail-zapasu/jihomoravska-divize-2026-2027-kolo-1-tj-sokol-brno-iv-muzi-kc-zlin-b-muzi",
    "https://vysledky.kuzelky.cz/detail-zapasu/divize-as-2026-2027-kolo-2-tj-sokol-rudna-a-muzi-kk-kosmonosy-c-muzi",
    "https://vysledky.kuzelky.cz/detail-zapasu/krajsky-prebor-2-tridy-sever-a-2026-2027-kolo-3-tj-sokol-husovice-e-muzi-kk-slovan-rosice-d-muzi",
  ];
  assertEquals(competitionSlugsForClubs(locs, ["tj-sokol-brno-iv", "tj-sokol-husovice"]), [
    "jihomoravska-divize-2026-2027", "krajsky-prebor-2-tridy-sever-a-2026-2027",
  ]);
});

Deno.test("a team belongs to the club whose slug it extends by one squad letter", () => {
  assert(teamBelongsToClub("tj-sokol-brno-iv-muzi", "tj-sokol-brno-iv"));
  assert(teamBelongsToClub("tj-sokol-brno-iv-b-muzi", "tj-sokol-brno-iv"));
  assert(!teamBelongsToClub("tj-sokol-brno-iv-b-muzi", "tj-sokol-brno"));
  assert(!teamBelongsToClub("kk-slovan-rosice-d-muzi", "tj-sokol-brno-iv"));
});

Deno.test("format and duration", () => {
  assertEquals(matchFormat("TEAMS_OF_4", "T100"), { players: 4, throws: 100, durationMin: 90 });
  assertEquals(matchFormat("TEAMS_OF_6", "T100"), { players: 6, throws: 100, durationMin: 150 });
  assertEquals(matchFormat("TEAMS_OF_6", "T120"), { players: 6, throws: 120, durationMin: 180 });
  assertEquals(matchFormat("SOMETHING", "X").durationMin, 180);
  assertEquals(endTime("17:30", 150), "20:00");
  assertEquals(endTime("22:00", 180), "23:59");
});

Deno.test("team names compare without case, accents and the A suffix", () => {
  assertEquals(normalizeTeam("TJ Sokol Husovice A"), normalizeTeam("tj sokol  husovice"));
  assertEquals(normalizeTeam("KS Devítka Brno B"), "ks devitka brno b");
  assert(normalizeTeam("TJ Sokol Brno IV B") !== normalizeTeam("TJ Sokol Brno IV"));
});

Deno.test("legacy rozpis rows pair by round and teams, then by date and teams", () => {
  const legacy = [
    { id: "L1", import_key: "rozpis:Jihomoravská divize:5:TJ Sokol Brno IV A – KC Zlín B", date: "2026-10-10", home_team: "TJ Sokol Brno IV A", away_team: "KC Zlín B" },
    { id: "L2", import_key: "rozpis:KP2:3:SKK Veverky Brno B – KK Orel Telnice B", date: "2026-10-03", home_team: "SKK Veverky Brno B", away_team: "KK Orel Telnice B" },
    { id: "L3", import_key: "rozpis:X:1:A – B", date: "2026-09-01", home_team: "A", away_team: "B" },
  ];
  const pairs = pairLegacy([
    // postponed: other date, same round + teams
    { siteId: 1, date: "2026-10-17", round: 5, home: "TJ Sokol Brno IV", away: "KC Zlín B" },
    // other round in the key, same date + teams
    { siteId: 2, date: "2026-10-03", round: 4, home: "SKK Veverky Brno B", away: "KK Orel Telnice B" },
    { siteId: 3, date: "2026-11-01", round: 9, home: "Nobody", away: "Else" },
  ], legacy);
  assertEquals(pairs.get(1), "L1");
  assertEquals(pairs.get(2), "L2");
  assertEquals(pairs.has(3), false);
});

Deno.test("a legacy row pairs at most once", () => {
  const legacy = [{ id: "L1", import_key: "rozpis:X:1:A – B", date: "2026-09-01", home_team: "A", away_team: "B" }];
  const pairs = pairLegacy([
    { siteId: 1, date: "2026-09-01", round: 1, home: "A", away: "B" },
    { siteId: 2, date: "2026-09-01", round: 1, home: "A", away: "B" },
  ], legacy);
  assertEquals([...pairs.values()], ["L1"]);
});

Deno.test("checkpoints follow the table in the spec", () => {
  const T = new Date("2026-10-10T08:00:00Z");
  const at = (h: number) => new Date(T.getTime() + h * 3600e3);
  const min = (d: Date, m: number) => new Date(d.getTime() + m * 60e3);
  assertEquals(nextCheckpoint("SCHEDULED", T, at(-48)), at(-24));
  assertEquals(nextCheckpoint("SCHEDULED", T, at(-5)), at(-1));
  assertEquals(nextCheckpoint("SCHEDULED", T, at(-0.5)), min(at(-0.5), 15));
  assertEquals(nextCheckpoint("SCHEDULED", T, at(7)), at(24));
  assertEquals(nextCheckpoint("IN_PROGRESS", T, at(2)), min(at(2), 15));
  assertEquals(nextCheckpoint("PREPARATION", T, at(13)), at(24));
  assertEquals(nextCheckpoint("FINISHED", T, at(3)), at(24));
  assertEquals(nextCheckpoint("FINISHED", T, at(25)), at(72));
  assertEquals(nextCheckpoint("FORFEIT", T, at(80)), null);
});

Deno.test("resultPayload is what apply_federation_result reads", () => {
  const p = resultPayload(parseMatch(fixture("match_finished.html")));
  assertEquals(p.status, "finished");
  assertEquals(p.match_type, "TEAMS_OF_6");
  assertEquals(p.discipline, "T100");
  assertEquals(p.home_prep, 30);
  assertEquals((p.home as Record<string, unknown>).points, 7);
  const players = p.players as Record<string, unknown>[];
  assertEquals(players.length, 12);
  assertEquals(players[0].side, "home");
  assertEquals(players[0].player_name, "Lucie Mičanová");
  assertEquals(players[0].fulls, 297);
  assertEquals((players[0].lanes as unknown[]).length, 2);
  assert(players.some((x) => x.side === "away"));
});
```

- [ ] **Step 2: Run to see it fail**

Run: `deno test --allow-read supabase/functions/_shared/federation_test.ts`
Expected: FAIL — module `./federation.ts` not found.

- [ ] **Step 3: Implement `supabase/functions/_shared/federation.ts`**

```ts
// Parser for https://vysledky.kuzelky.cz — pages are server-rendered Next.js
// and carry their data as JSON inside the RSC flight chunks. No IO here.

export type MatchStatus = "SCHEDULED" | "PREPARATION" | "IN_PROGRESS" | "FINISHED" | "FORFEIT";
export type SiteTeam = { id: number; name: string; slug: string };
export type SiteMatch = {
  id: number; slug: string; date: string; time: string | null; round: number;
  status: MatchStatus; matchType: string; discipline: string; videoUrl: string | null;
  homeTeam: SiteTeam; awayTeam: SiteTeam; competition: { slug: string; name: string };
};
export type SiteLane = { lane: number; fulls: number | null; spares: number | null; errors: number | null; total: number | null; setPoints: number | null };
export type SitePlayer = {
  position: number; name: string; siteId: number | null; slug: string | null;
  fulls: number | null; spares: number | null; errors: number | null; total: number | null;
  setPoints: number | null; teamPoints: number | null; lanes: SiteLane[];
};
export type SiteSide = {
  points: number | null; total: number | null; fulls: number | null; spares: number | null;
  errors: number | null; setPoints: number | null; players: SitePlayer[];
};
export type SiteMatchDetail = SiteMatch & {
  venue: { slug: string; name: string } | null; home: SiteSide | null; away: SiteSide | null;
};
export type SiteStanding = { teamSlug: string; teamName: string };
export type SiteCompetition = {
  name: string; roundIds: number[]; currentRound: number; matches: SiteMatch[]; standings: SiteStanding[];
};
export type VenueClub = { slug: string; name: string };
export type LegacyRow = { id: string; import_key: string; date: string; home_team: string; away_team: string };
export type PairCandidate = { siteId: number; date: string; round: number; home: string; away: string };

export const HOME_PREP_MINUTES = 30;
const STATUSES = new Set(["SCHEDULED", "PREPARATION", "IN_PROGRESS", "FINISHED", "FORFEIT"]);

type Json = Record<string, unknown>;

export function rscText(html: string): string {
  const chunks = html.matchAll(/self\.__next_f\.push\(\[1,("(?:[^"\\]|\\.)*")\]\)/g);
  return [...chunks].map((m) => JSON.parse(m[1]) as string).join("");
}

export function valueAfter(text: string, marker: string): unknown {
  const at = text.indexOf(marker);
  if (at < 0) throw new Error(`missing ${marker}`);
  return readValue(text, at + marker.length);
}

function readValue(text: string, start: number): unknown {
  const open = text[start];
  if (open !== "{" && open !== "[") {
    const m = /^(-?\d+(?:\.\d+)?|null|true|false|"(?:[^"\\]|\\.)*")/.exec(text.slice(start));
    if (!m) throw new Error(`unreadable value at ${start}`);
    return JSON.parse(m[1]);
  }
  let depth = 0;
  let inString = false;
  for (let i = start; i < text.length; i++) {
    const ch = text[i];
    if (inString) {
      if (ch === "\\") i++;
      else if (ch === '"') inString = false;
    } else if (ch === '"') inString = true;
    else if (ch === "{" || ch === "[") depth++;
    else if (ch === "}" || ch === "]") {
      depth--;
      if (depth === 0) return JSON.parse(text.slice(start, i + 1));
    }
  }
  throw new Error(`unterminated value at ${start}`);
}

const num = (v: unknown): number | null => (typeof v === "number" ? v : null);
const str = (v: unknown): string | null =>
  typeof v === "string" && !v.startsWith("$") ? v : null;

function team(v: unknown): SiteTeam {
  const t = v as Json;
  if (typeof t?.id !== "number" || typeof t.slug !== "string") throw new Error("bad team");
  return { id: t.id, name: String(t.name), slug: t.slug };
}

function siteMatch(v: unknown): SiteMatch {
  const m = v as Json;
  const status = String(m.status);
  if (typeof m.id !== "number" || !STATUSES.has(status)) throw new Error("bad match");
  const c = m.competition as Json;
  return {
    id: m.id, slug: String(m.slug), date: String(m.date), time: str(m.time),
    round: Number(m.round), status: status as MatchStatus,
    matchType: String(m.matchType ?? ""), discipline: String(m.discipline ?? ""),
    videoUrl: str(m.videoUrl), homeTeam: team(m.homeTeam), awayTeam: team(m.awayTeam),
    competition: { slug: String(c?.slug ?? ""), name: String(c?.name ?? "") },
  };
}

export function parseCompetition(html: string): SiteCompetition {
  const text = rscText(html);
  const at = text.indexOf('{"data":{"title":');
  if (at < 0) throw new Error("competition data missing");
  const data = (readValue(text, at) as Json).data as Json;
  const rounds = data.rounds as Json[];
  const current = data.currentRound as Json;
  if (!Array.isArray(rounds) || !current || !Array.isArray(current.matches)) {
    throw new Error("competition rounds missing");
  }
  const standings = ((data.standings as Json | undefined)?.total ?? []) as Json[];
  return {
    name: String(data.title),
    roundIds: rounds.map((r) => Number(r.id)),
    currentRound: Number(current.id),
    matches: current.matches.map(siteMatch),
    standings: standings
      .filter((s) => typeof s.teamSlug === "string")
      .map((s) => ({ teamSlug: String(s.teamSlug), teamName: String(s.teamName) })),
  };
}

function side(v: Json | undefined): SiteSide | null {
  if (!v) return null;
  const players = ((v.playerResults ?? []) as Json[])
    .filter((p) => p.player && typeof p.player === "object")
    .map((p): SitePlayer => {
      const who = p.player as Json;
      return {
        position: Number(p.position),
        name: `${who.firstName ?? ""} ${who.lastName ?? ""}`.trim(),
        siteId: num(who.id), slug: str(who.slug),
        fulls: num(p.totalFull), spares: num(p.totalSpare), errors: num(p.totalErrors),
        total: num(p.totalPerformance), setPoints: num(p.setPoints), teamPoints: num(p.teamPoints),
        lanes: ((p.laneResults ?? []) as Json[]).map((l) => ({
          lane: Number(l.laneNumber), fulls: num(l.full), spares: num(l.spare),
          errors: num(l.errors), total: num(l.total), setPoints: num(l.setPoints),
        })),
      };
    });
  return {
    points: num(v.teamPoints), total: num(v.totalPerformance), fulls: num(v.totalFull),
    spares: num(v.totalSpare), errors: num(v.totalErrors), setPoints: num(v.totalSetPoints),
    players,
  };
}

export function parseMatch(html: string): SiteMatchDetail {
  const text = rscText(html);
  const at = text.indexOf('"match":{"id":');
  if (at < 0) throw new Error("match data missing");
  const raw = readValue(text, at + '"match":'.length) as Json;
  const results = (raw.results ?? []) as Json[];
  const venue = raw.venue as Json | null | undefined;
  return {
    ...siteMatch(raw),
    venue: venue && typeof venue.slug === "string"
      ? { slug: venue.slug, name: String(venue.name) }
      : null,
    home: side(results.find((r) => r.isHome === true)),
    away: side(results.find((r) => r.isHome === false)),
  };
}

export function parseVenueClubs(html: string): VenueClub[] {
  const seen = new Map<string, string>();
  for (const m of html.matchAll(/href="\/detail-klubu\/([a-z0-9-]+)"[^>]*>([\s\S]*?)<\/a>/g)) {
    if (seen.has(m[1])) continue;
    const spans = [...m[2].matchAll(/<span[^>]*>([^<]*)<\/span>/g)];
    const name = spans.length ? decodeEntities(spans[spans.length - 1][1]).trim() : m[1];
    seen.set(m[1], name || m[1]);
  }
  return [...seen].map(([slug, name]) => ({ slug, name }));
}

const decodeEntities = (s: string) =>
  s.replaceAll("&amp;", "&").replaceAll("&quot;", '"').replaceAll("&#x27;", "'")
    .replaceAll("&lt;", "<").replaceAll("&gt;", ">");

export function parseSitemapLocs(xml: string): string[] {
  return [...xml.matchAll(/<loc>\s*([^<\s]+)\s*<\/loc>/g)].map((m) => m[1]);
}

export function competitionSlugsForClubs(matchLocs: string[], clubSlugs: string[]): string[] {
  const found = new Set<string>();
  for (const loc of matchLocs) {
    const m = /\/detail-zapasu\/(.+?)-kolo-\d+-(.+)$/.exec(loc);
    if (!m) continue;
    const teams = `-${m[2]}`;
    if (clubSlugs.some((c) => teams.includes(`-${c}-`))) found.add(m[1]);
  }
  return [...found].sort();
}

export function teamBelongsToClub(teamSlug: string, clubSlug: string): boolean {
  if (!teamSlug.startsWith(`${clubSlug}-`)) return false;
  return /^([a-z]-)?[a-z]+$/.test(teamSlug.slice(clubSlug.length + 1));
}

export function matchFormat(matchType: string, discipline: string) {
  const players = matchType === "TEAMS_OF_4" ? 4 : 6;
  const throws = discipline === "T120" ? 120 : 100;
  const durationMin = matchType === "TEAMS_OF_4" && discipline === "T100"
    ? 90
    : matchType === "TEAMS_OF_6" && discipline === "T100"
    ? 150
    : 180;
  return { players, throws, durationMin };
}

export function endTime(start: string, minutes: number): string {
  const [h, m] = start.split(":").map(Number);
  const total = Math.min(h * 60 + m + minutes, 23 * 60 + 59);
  return `${String(Math.floor(total / 60)).padStart(2, "0")}:${String(total % 60).padStart(2, "0")}`;
}

export function normalizeTeam(name: string): string {
  return name.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase()
    .replace(/[^a-z0-9]+/g, " ").trim().replace(/ a$/, "");
}

export function pairLegacy(candidates: PairCandidate[], legacy: LegacyRow[]): Map<number, string> {
  const free = new Map(legacy.map((l) => [l.id, l]));
  const pairs = new Map<number, string>();
  const keyed = (l: LegacyRow) => /^rozpis:.*:(\d+):(.*) – (.*)$/.exec(l.import_key);
  const same = (a: string, b: string) => normalizeTeam(a) === normalizeTeam(b);
  const rules: ((c: PairCandidate, l: LegacyRow) => boolean)[] = [
    (c, l) => {
      const k = keyed(l);
      return !!k && Number(k[1]) === c.round && same(k[2], c.home) && same(k[3], c.away);
    },
    (c, l) => l.date === c.date && same(l.home_team, c.home) && same(l.away_team, c.away),
  ];
  for (const rule of rules) {
    for (const c of candidates) {
      if (pairs.has(c.siteId)) continue;
      const hits = [...free.values()].filter((l) => rule(c, l));
      if (hits.length !== 1) continue;
      pairs.set(c.siteId, hits[0].id);
      free.delete(hits[0].id);
    }
  }
  return pairs;
}

export function nextCheckpoint(status: MatchStatus, start: Date, now: Date): Date | null {
  const t = start.getTime();
  const n = now.getTime();
  const h = 3600e3;
  const soon = new Date(n + 15 * 60e3);
  if (status === "SCHEDULED") {
    if (n < t - 24 * h) return new Date(t - 24 * h);
    if (n < t - h) return new Date(t - h);
    if (n < t + 6 * h) return soon;
  }
  if ((status === "PREPARATION" || status === "IN_PROGRESS") && n < t + 12 * h) return soon;
  if (n < t + 24 * h) return new Date(t + 24 * h);
  if (n < t + 72 * h) return new Date(t + 72 * h);
  return null;
}

const sideTotals = (s: SiteSide | null) =>
  s && {
    points: s.points, total: s.total, fulls: s.fulls, spares: s.spares,
    errors: s.errors, set_points: s.setPoints,
  };

export function resultPayload(d: SiteMatchDetail): Record<string, unknown> {
  const players = (["home", "away"] as const).flatMap((key) =>
    (d[key]?.players ?? []).map((p) => ({
      side: key, position: p.position, player_name: p.name,
      player_site_id: p.siteId, player_slug: p.slug,
      fulls: p.fulls, spares: p.spares, errors: p.errors, total: p.total,
      set_points: p.setPoints, team_points: p.teamPoints,
      lanes: p.lanes.map((l) => ({
        lane: l.lane, fulls: l.fulls, spares: l.spares, errors: l.errors,
        total: l.total, setPoints: l.setPoints,
      })),
    }))
  );
  return {
    status: d.status.toLowerCase(), match_type: d.matchType, discipline: d.discipline,
    video_url: d.videoUrl, venue: d.venue, home_prep: HOME_PREP_MINUTES,
    home: sideTotals(d.home), away: sideTotals(d.away), players,
  };
}
```

If a fixture assertion fails because the real page differs from the shapes above (e.g. `"{\"data\":{\"title\":"` is not where the competition object starts), adapt the parser to the fixture — the fixtures are the truth — and keep the test's intent.

- [ ] **Step 4: Run tests**

Run: `deno test --allow-read supabase/functions/_shared/federation_test.ts` → all pass. Then `deno test --allow-read supabase/functions` → all pass. Then `deno lint supabase/functions/_shared/federation.ts supabase/functions/_shared/federation_test.ts` → clean (if the repo has no lint config, skip lint).

- [ ] **Step 5: CI flag + commit**

Edit `.github/workflows/ci.yml`: `deno test supabase/functions` → `deno test --allow-read supabase/functions`.

```bash
git add supabase/functions/_shared/federation.ts supabase/functions/_shared/federation_test.ts supabase/functions/_shared/fixtures/federation .github/workflows/ci.yml
git commit -m "feat(federation): parser for vysledky.kuzelky.cz pages

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Migration `0045_federation.sql` + RLS tests + snapshot

**Files:**
- Create: `supabase/migrations/0045_federation.sql`
- Modify: `supabase/tests/tenancy_rls.sql` (public_week priority_slots key guard around line 3148, new 0045 section before the final `reset role; rollback;`)
- Regenerate: `supabase/schema.sql` via `tool/schema_snapshot.sh`
- Modify: `docs/SCHEMA.md` (table rows for the 4 new tables + new priority_slots columns; a `## Výsledkový servis ČKA (0045)` section replacing `## Import rozpisu (tool/import_matches.py, 0038)` — keep the `hand_edited` explanation, say the sync is the importer now)

**Interfaces — Produces** (used by Tasks 3–5):
- Tables `teams`, `federation_sync`, `match_results`, `match_player_results`; `priority_slots` columns `video_url text, competition text, round smallint, site_slug text, site_match_id integer, venue text, venue_slug text`.
- Server (service_role): `apply_federation_matches(p_tenant uuid, p_competition_slug text, p_matches jsonb) returns jsonb`, `apply_federation_result(p_tenant uuid, p_site_match_id integer, p_result jsonb) returns void`, `upsert_federation_teams(p_tenant uuid, p_teams jsonb) returns integer`, `record_federation_run(p_tenant uuid, p_key text, p_report jsonb, p_error text) returns void`, `enqueue_federation_match(p_tenant uuid, p_site_match_id integer, p_slug text, p_run_at timestamptz) returns void`, `enqueue_federation_jobs() returns void`.
- App RPCs (authenticated): `set_federation_sync(p_venue_slug text, p_enabled boolean)`, `request_federation_discovery()`, `request_federation_sync()`, `update_team(p_id uuid, p_name text, p_club_id uuid, p_active boolean)`, `refresh_match(p_match_id uuid) returns text` (`queued` | `fresh` | `not_live`).
- Error codes raised: `not_allowed`, `invalid_slug`, `federation_not_configured`, `federation_disabled`, `empty_name`, `team_name_taken`, `federation_tenant_not_ready`.
- `p_matches` element keys (built by Task 3): `site_match_id, site_slug, date ("YYYY-MM-DD"), starts_at ("HH:MM"), ends_at, home, away, home_is_ours (bool), prep (int), competition, round, video_url (nullable), legacy_id (uuid|null)`.
- `p_result` keys (Task 1 `resultPayload`): `status` (lowercase), `match_type, discipline, video_url, venue {slug,name}|null, home_prep, home {points,total,fulls,spares,errors,set_points}|null, away {…}|null, players [{side, position, player_name, player_site_id, player_slug, fulls, spares, errors, total, set_points, team_points, lanes}]`.
- `p_teams` element keys: `site_slug, site_team_id (int|null), site_name, competition_slug, competition_name, name, club_id (uuid|null)`.

- [ ] **Step 1: Write the migration**

`supabase/migrations/0045_federation.sql`:

```sql
-- 0045 — výsledkový servis ČKA (vysledky.kuzelky.cz): týmy kuželny,
-- nastavení synchronizace, výsledky zápasů. Zápisy dělá jen server (edge
-- funkce notify přes service_role) těmito security-definer funkcemi; appka
-- čte tabulky a volá několik RPC. Spec:
-- docs/superpowers/specs/2026-09-23-federation-results-design.md

-- ---------------------------------------------------------------- teams
create table teams (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 80),
  club_id uuid references clubs(id) on delete set null,
  site_team_id integer,
  site_slug text not null,
  site_name text not null default '',
  competition_slug text not null default '',
  competition_name text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, name),
  unique (tenant_id, site_slug)
);
comment on column teams.name is
  'The name the app keys by (priority_slots.home_team/away_team, followed_teams, calendar_teams, team_colors). Set at discovery, editable by the admin.';
alter table teams enable row level security;
create policy teams_select on teams for select
  using (tenant_id = current_tenant_id() and is_approved_or_kiosk());
revoke all on teams from anon;
revoke insert, update, delete on teams from authenticated;
grant all on teams to service_role;
alter publication supabase_realtime add table teams;

-- ------------------------------------------------------ federation_sync
create table federation_sync (
  tenant_id uuid primary key references tenants(id) on delete cascade,
  venue_slug text not null default ''
    check (venue_slug ~ '^([a-z0-9]+(-[a-z0-9]+)*)?$'),
  enabled boolean not null default false,
  last_run_at timestamptz,
  last_success_at timestamptz,
  last_error text,
  last_report jsonb not null default '{}'::jsonb
);
alter table federation_sync enable row level security;
create policy federation_sync_select on federation_sync for select
  using (tenant_id = current_tenant_id() and is_admin());
revoke all on federation_sync from anon;
revoke insert, update, delete on federation_sync from authenticated;
grant all on federation_sync to service_role;
alter publication supabase_realtime add table federation_sync;

-- ------------------------------------------------ priority_slots columns
-- Federation-only columns: the sync may always rewrite them, so the
-- hand_edited trigger (0038) does not compare them.
alter table priority_slots
  add column video_url text,
  add column competition text,
  add column round smallint,
  add column site_slug text,
  add column site_match_id integer,
  add column venue text,
  add column venue_slug text;

-- ------------------------------------------------------- match results
create table match_results (
  match_id uuid primary key references priority_slots(id) on delete cascade,
  tenant_id uuid not null references tenants(id) on delete cascade,
  status text not null
    check (status in ('scheduled', 'preparation', 'in_progress', 'finished', 'forfeit')),
  match_type text not null default '',
  discipline text not null default '',
  home_points numeric, away_points numeric,
  home_total integer, away_total integer,
  home_fulls integer, away_fulls integer,
  home_spares integer, away_spares integer,
  home_errors integer, away_errors integer,
  home_set_points numeric, away_set_points numeric,
  fetched_at timestamptz not null default now()
);
create table match_player_results (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references priority_slots(id) on delete cascade,
  tenant_id uuid not null references tenants(id) on delete cascade,
  side text not null check (side in ('home', 'away')),
  position smallint not null,
  player_name text not null,
  player_site_id integer,
  player_slug text,
  fulls integer, spares integer, errors integer, total integer,
  set_points numeric, team_points numeric,
  lanes jsonb not null default '[]'::jsonb,
  unique (match_id, side, position)
);
create index match_player_results_player_idx
  on match_player_results (tenant_id, player_site_id);

alter table match_results enable row level security;
alter table match_player_results enable row level security;
create policy match_results_select on match_results for select
  using (tenant_id = current_tenant_id() and is_approved_or_kiosk());
create policy match_player_results_select on match_player_results for select
  using (tenant_id = current_tenant_id() and is_approved_or_kiosk());
revoke all on match_results, match_player_results from anon;
revoke insert, update, delete on match_results, match_player_results from authenticated;
grant all on match_results, match_player_results to service_role;
alter publication supabase_realtime add table match_results, match_player_results;

-- ------------------------------------------------------------- helpers
create or replace function federation_description(
  p_competition text, p_round integer, p_is_away boolean, p_venue text)
returns text language sql immutable as $$
  select concat_ws(' · ', nullif(p_competition, ''), p_round || '. kolo',
    case when p_is_away and coalesce(p_venue, '') <> '' then p_venue end)
$$;

-- One competition's matches as the site lists them → priority_slots.
-- import.run keeps the 0038 hand-edit trigger quiet; writes happen only
-- when something differs (every UPDATE enqueues calendar jobs).
create or replace function apply_federation_matches(
  p_tenant uuid, p_competition_slug text, p_matches jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_admin uuid;
  v_type uuid;
  v_venue text;
  m jsonb;
  v_key text;
  v_row priority_slots;
  v_found boolean;
  v_is_away boolean;
  v_prep smallint;
  v_desc text;
  v_seen integer[] := '{}';
  v_ins integer := 0;
  v_upd integer := 0;
  v_rekey integer := 0;
  v_del integer := 0;
  v_skipped jsonb := '[]'::jsonb;
begin
  perform set_config('import.run', 'on', true);
  select id into v_admin from profiles
   where tenant_id = p_tenant and role = 'admin' and status = 'approved' and not placeholder
   order by created_at limit 1;
  select id into v_type from priority_slot_types
   where tenant_id = p_tenant and is_match and builtin;
  if v_admin is null or v_type is null then
    raise exception 'federation_tenant_not_ready';
  end if;
  select venue_slug into v_venue from federation_sync where tenant_id = p_tenant;

  for m in select * from jsonb_array_elements(p_matches) loop
    v_key := 'cka:' || (m->>'site_match_id');
    v_seen := v_seen || (m->>'site_match_id')::integer;
    select * into v_row from priority_slots
     where tenant_id = p_tenant and import_key = v_key;
    v_found := found;
    if not v_found and m->>'legacy_id' is not null then
      select * into v_row from priority_slots
       where tenant_id = p_tenant and id = (m->>'legacy_id')::uuid
         and import_key like 'rozpis:%';
      v_found := found;
      if v_found then
        update priority_slots set import_key = v_key where id = v_row.id;
        v_rekey := v_rekey + 1;
      end if;
    end if;

    if not v_found then
      v_is_away := not (m->>'home_is_ours')::boolean;
      insert into priority_slots
        (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
         prep_minutes, description, is_away, created_by, import_key,
         video_url, competition, round, site_slug, site_match_id)
      values
        (p_tenant, (m->>'date')::date, (m->>'starts_at')::time, (m->>'ends_at')::time,
         v_type, m->>'home', m->>'away',
         case when v_is_away then 0 else (m->>'prep')::smallint end,
         federation_description(m->>'competition', (m->>'round')::integer, v_is_away, null),
         v_is_away, v_admin, v_key,
         m->>'video_url', m->>'competition', (m->>'round')::smallint,
         m->>'site_slug', (m->>'site_match_id')::integer);
      v_ins := v_ins + 1;
      continue;
    end if;

    update priority_slots
       set video_url = m->>'video_url', competition = m->>'competition',
           round = (m->>'round')::smallint, site_slug = m->>'site_slug',
           site_match_id = (m->>'site_match_id')::integer
     where id = v_row.id
       and (video_url, competition, round, site_slug, site_match_id)
           is distinct from
           (m->>'video_url', m->>'competition', (m->>'round')::smallint,
            m->>'site_slug', (m->>'site_match_id')::integer);

    -- Once a detail fetch told us the venue, it decides home/away.
    v_is_away := case when v_row.venue_slug is not null
                      then v_row.venue_slug is distinct from v_venue
                      else not (m->>'home_is_ours')::boolean end;
    v_prep := case when v_is_away then 0 else (m->>'prep')::smallint end;
    v_desc := federation_description(m->>'competition', (m->>'round')::integer,
                                     v_is_away, v_row.venue);
    if (v_row.date, v_row.starts_at, v_row.ends_at, v_row.home_team, v_row.away_team,
        v_row.prep_minutes, v_row.description, v_row.is_away)
       is distinct from
       ((m->>'date')::date, (m->>'starts_at')::time, (m->>'ends_at')::time,
        m->>'home', m->>'away', v_prep, v_desc, v_is_away) then
      if v_row.hand_edited then
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
          'id', v_row.id, 'date', v_row.date,
          'title', v_row.home_team || ' – ' || v_row.away_team));
      else
        update priority_slots
           set date = (m->>'date')::date, starts_at = (m->>'starts_at')::time,
               ends_at = (m->>'ends_at')::time, home_team = m->>'home',
               away_team = m->>'away', prep_minutes = v_prep,
               description = v_desc, is_away = v_is_away
         where id = v_row.id;
        v_upd := v_upd + 1;
      end if;
    end if;
  end loop;

  -- A future match the site no longer lists (a team withdrew). Played
  -- matches stay whatever the site says later.
  with gone as (
    delete from priority_slots p
     where p.tenant_id = p_tenant and p.parent_id is null
       and p.import_key like 'cka:%'
       and p.site_slug like p_competition_slug || '-kolo-%'
       and p.date >= (now() at time zone 'Europe/Prague')::date
       and not p.hand_edited
       and not (p.site_match_id = any (v_seen))
    returning 1)
  select count(*) into v_del from gone;

  return jsonb_build_object('inserted', v_ins, 'updated', v_upd, 'rekeyed', v_rekey,
    'deleted', v_del, 'skipped_hand_edited', v_skipped);
end;
$$;

create or replace function apply_federation_result(
  p_tenant uuid, p_site_match_id integer, p_result jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_row priority_slots;
  v_venue text;
  v_is_away boolean;
  v_prep smallint;
  v_desc text;
  v_home jsonb := p_result->'home';
  v_away jsonb := p_result->'away';
begin
  select * into v_row from priority_slots
   where tenant_id = p_tenant and import_key = 'cka:' || p_site_match_id;
  if not found then
    return;
  end if;
  perform set_config('import.run', 'on', true);
  select venue_slug into v_venue from federation_sync where tenant_id = p_tenant;

  if jsonb_typeof(p_result->'venue') = 'object' then
    update priority_slots
       set venue = p_result#>>'{venue,name}', venue_slug = p_result#>>'{venue,slug}'
     where id = v_row.id
       and (venue, venue_slug) is distinct from
           (p_result#>>'{venue,name}', p_result#>>'{venue,slug}');
    v_is_away := (p_result#>>'{venue,slug}') is distinct from v_venue;
    v_prep := case when v_is_away then 0 else (p_result->>'home_prep')::smallint end;
    v_desc := federation_description(v_row.competition, v_row.round, v_is_away,
                                     p_result#>>'{venue,name}');
    if not v_row.hand_edited
       and (v_row.is_away, v_row.prep_minutes, v_row.description)
           is distinct from (v_is_away, v_prep, v_desc) then
      update priority_slots
         set is_away = v_is_away, prep_minutes = v_prep, description = v_desc
       where id = v_row.id;
    end if;
  end if;

  update priority_slots set video_url = p_result->>'video_url'
   where id = v_row.id and video_url is distinct from p_result->>'video_url';

  insert into match_results as r
    (match_id, tenant_id, status, match_type, discipline,
     home_points, away_points, home_total, away_total, home_fulls, away_fulls,
     home_spares, away_spares, home_errors, away_errors,
     home_set_points, away_set_points, fetched_at)
  values
    (v_row.id, p_tenant, p_result->>'status',
     coalesce(p_result->>'match_type', ''), coalesce(p_result->>'discipline', ''),
     (v_home->>'points')::numeric, (v_away->>'points')::numeric,
     (v_home->>'total')::integer, (v_away->>'total')::integer,
     (v_home->>'fulls')::integer, (v_away->>'fulls')::integer,
     (v_home->>'spares')::integer, (v_away->>'spares')::integer,
     (v_home->>'errors')::integer, (v_away->>'errors')::integer,
     (v_home->>'set_points')::numeric, (v_away->>'set_points')::numeric, now())
  on conflict (match_id) do update set
    status = excluded.status, match_type = excluded.match_type,
    discipline = excluded.discipline,
    home_points = excluded.home_points, away_points = excluded.away_points,
    home_total = excluded.home_total, away_total = excluded.away_total,
    home_fulls = excluded.home_fulls, away_fulls = excluded.away_fulls,
    home_spares = excluded.home_spares, away_spares = excluded.away_spares,
    home_errors = excluded.home_errors, away_errors = excluded.away_errors,
    home_set_points = excluded.home_set_points,
    away_set_points = excluded.away_set_points,
    fetched_at = now();

  delete from match_player_results where match_id = v_row.id;
  insert into match_player_results
    (match_id, tenant_id, side, position, player_name, player_site_id, player_slug,
     fulls, spares, errors, total, set_points, team_points, lanes)
  select v_row.id, p_tenant, p->>'side', (p->>'position')::smallint, p->>'player_name',
         (p->>'player_site_id')::integer, p->>'player_slug',
         (p->>'fulls')::integer, (p->>'spares')::integer, (p->>'errors')::integer,
         (p->>'total')::integer, (p->>'set_points')::numeric,
         (p->>'team_points')::numeric, coalesce(p->'lanes', '[]'::jsonb)
    from jsonb_array_elements(coalesce(p_result->'players', '[]'::jsonb)) p;
end;
$$;

-- Discovery: new teams arrive active; an existing team keeps its name,
-- club and switch — only the site's facts are refreshed.
create or replace function upsert_federation_teams(p_tenant uuid, p_teams jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  t jsonb;
  v_name text;
  v_new integer := 0;
begin
  for t in select * from jsonb_array_elements(p_teams) loop
    update teams
       set site_team_id = (t->>'site_team_id')::integer, site_name = t->>'site_name',
           competition_slug = t->>'competition_slug',
           competition_name = t->>'competition_name'
     where tenant_id = p_tenant and site_slug = t->>'site_slug';
    if found then
      continue;
    end if;
    v_name := t->>'name';
    if exists (select 1 from teams where tenant_id = p_tenant and name = v_name) then
      v_name := v_name || ' (' || (t->>'competition_name') || ')';
    end if;
    insert into teams (tenant_id, name, club_id, site_team_id, site_slug, site_name,
                       competition_slug, competition_name)
    values (p_tenant, v_name, (t->>'club_id')::uuid, (t->>'site_team_id')::integer,
            t->>'site_slug', t->>'site_name', t->>'competition_slug',
            t->>'competition_name');
    v_new := v_new + 1;
  end loop;
  return v_new;
end;
$$;

create or replace function record_federation_run(
  p_tenant uuid, p_key text, p_report jsonb, p_error text)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into federation_sync (tenant_id) values (p_tenant) on conflict do nothing;
  update federation_sync
     set last_run_at = now(),
         last_success_at = case when p_error is null then now() else last_success_at end,
         last_error = p_error,
         last_report = case when p_error is null
           then last_report || jsonb_build_object(p_key,
                  coalesce(p_report, '{}'::jsonb) || jsonb_build_object('at', now()))
           else last_report end
   where tenant_id = p_tenant;
end;
$$;

-- An earlier run_at wins: the nightly pass must not push back a
-- checkpoint the job already set (T−24 h, T−1 h …).
create or replace function enqueue_federation_match(
  p_tenant uuid, p_site_match_id integer, p_slug text, p_run_at timestamptz)
returns void language sql security definer set search_path = public as $$
  insert into notification_jobs (kind, dedupe_key, payload, run_at)
  values ('federation_match', 'federation_match:' || p_tenant || ':' || p_site_match_id,
          jsonb_build_object('tenant_id', p_tenant, 'site_match_id', p_site_match_id,
                             'slug', p_slug),
          p_run_at)
  on conflict (dedupe_key) do update
    set run_at = least(notification_jobs.run_at, excluded.run_at),
        payload = excluded.payload;
$$;

create or replace function enqueue_federation_jobs()
returns void language plpgsql security definer set search_path = public as $$
declare
  r record;
  i integer := 0;
begin
  for r in
    select distinct t.tenant_id, t.competition_slug
      from teams t
      join federation_sync s on s.tenant_id = t.tenant_id
     where s.enabled and s.venue_slug <> '' and t.active and t.competition_slug <> ''
     order by 1, 2
  loop
    perform enqueue_notification('federation_competition',
      'federation_competition:' || r.tenant_id || ':' || r.competition_slug,
      jsonb_build_object('tenant_id', r.tenant_id, 'competition_slug', r.competition_slug),
      make_interval(mins => i));
    i := i + 1;
  end loop;
end;
$$;

revoke all on function federation_description(text, integer, boolean, text) from public, anon, authenticated;
revoke all on function apply_federation_matches(uuid, text, jsonb) from public, anon, authenticated;
revoke all on function apply_federation_result(uuid, integer, jsonb) from public, anon, authenticated;
revoke all on function upsert_federation_teams(uuid, jsonb) from public, anon, authenticated;
revoke all on function record_federation_run(uuid, text, jsonb, text) from public, anon, authenticated;
revoke all on function enqueue_federation_match(uuid, integer, text, timestamptz) from public, anon, authenticated;
revoke all on function enqueue_federation_jobs() from public, anon, authenticated;
grant execute on function apply_federation_matches(uuid, text, jsonb) to service_role;
grant execute on function apply_federation_result(uuid, integer, jsonb) to service_role;
grant execute on function upsert_federation_teams(uuid, jsonb) to service_role;
grant execute on function record_federation_run(uuid, text, jsonb, text) to service_role;
grant execute on function enqueue_federation_match(uuid, integer, text, timestamptz) to service_role;

-- ---------------------------------------------------------------- RPCs
create or replace function set_federation_sync(p_venue_slug text, p_enabled boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_slug text := lower(trim(coalesce(p_venue_slug, '')));
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then
    raise exception 'invalid_slug';
  end if;
  insert into federation_sync (tenant_id, venue_slug, enabled)
  values (current_tenant_id(), v_slug, p_enabled)
  on conflict (tenant_id) do update
    set venue_slug = excluded.venue_slug, enabled = excluded.enabled;
end;
$$;

create or replace function request_federation_discovery()
returns void language plpgsql security definer set search_path = public as $$
declare
  v_tenant uuid := current_tenant_id();
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if not exists (select 1 from federation_sync
                  where tenant_id = v_tenant and venue_slug <> '') then
    raise exception 'federation_not_configured';
  end if;
  perform enqueue_notification('federation_discover', 'federation_discover:' || v_tenant,
    jsonb_build_object('tenant_id', v_tenant), interval '0');
  perform trigger_notification_jobs();
end;
$$;

create or replace function request_federation_sync()
returns void language plpgsql security definer set search_path = public as $$
declare
  v_tenant uuid := current_tenant_id();
  r record;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if not exists (select 1 from federation_sync
                  where tenant_id = v_tenant and enabled and venue_slug <> '') then
    raise exception 'federation_disabled';
  end if;
  for r in select distinct competition_slug from teams
            where tenant_id = v_tenant and active and competition_slug <> '' loop
    perform enqueue_notification('federation_competition',
      'federation_competition:' || v_tenant || ':' || r.competition_slug,
      jsonb_build_object('tenant_id', v_tenant, 'competition_slug', r.competition_slug),
      interval '0');
  end loop;
  perform trigger_notification_jobs();
end;
$$;

create or replace function update_team(
  p_id uuid, p_name text, p_club_id uuid, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if trim(coalesce(p_name, '')) = '' then
    raise exception 'empty_name';
  end if;
  if p_club_id is not null and not exists (
      select 1 from clubs where id = p_club_id and tenant_id = current_tenant_id()) then
    raise exception 'not_allowed';
  end if;
  begin
    update teams set name = trim(p_name), club_id = p_club_id, active = p_active
     where id = p_id and tenant_id = current_tenant_id();
  exception when unique_violation then
    raise exception 'team_name_taken';
  end;
  if not found then
    raise exception 'not_allowed';
  end if;
end;
$$;

-- On-demand refresh of a live match, gated here so no client can hammer
-- the site: at most one fetch per match per 5 minutes.
create or replace function refresh_match(p_match_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_slot priority_slots;
  v_status text;
  v_fetched timestamptz;
  v_start timestamptz;
begin
  if not is_approved_or_kiosk() then
    raise exception 'not_allowed';
  end if;
  select * into v_slot from priority_slots
   where id = p_match_id and tenant_id = current_tenant_id();
  if not found or v_slot.site_match_id is null then
    return 'not_live';
  end if;
  select status, fetched_at into v_status, v_fetched
    from match_results where match_id = p_match_id;
  v_status := coalesce(v_status, 'scheduled');
  v_start := (v_slot.date + v_slot.starts_at) at time zone 'Europe/Prague';
  if not ((v_status in ('preparation', 'in_progress') and now() < v_start + interval '12 hours')
          or (v_status = 'scheduled'
              and now() between v_start - interval '1 hour' and v_start + interval '6 hours')) then
    return 'not_live';
  end if;
  if v_fetched is not null and v_fetched > now() - interval '5 minutes' then
    return 'fresh';
  end if;
  perform enqueue_federation_match(v_slot.tenant_id, v_slot.site_match_id,
                                   v_slot.site_slug, now());
  perform trigger_notification_jobs();
  return 'queued';
end;
$$;

revoke all on function set_federation_sync(text, boolean) from public, anon;
revoke all on function request_federation_discovery() from public, anon;
revoke all on function request_federation_sync() from public, anon;
revoke all on function update_team(uuid, text, uuid, boolean) from public, anon;
revoke all on function refresh_match(uuid) from public, anon;
grant execute on function set_federation_sync(text, boolean) to authenticated;
grant execute on function request_federation_discovery() to authenticated;
grant execute on function request_federation_sync() to authenticated;
grant execute on function update_team(uuid, text, uuid, boolean) to authenticated;
grant execute on function refresh_match(uuid) to authenticated;

-- ---------------------------------------------------------------- cron
do $$
begin
  if exists (select 1 from cron.job where jobname = 'federation-nightly') then
    perform cron.unschedule('federation-nightly');
  end if;
  perform cron.schedule('federation-nightly', '0 1 * * *',
    'select public.enqueue_federation_jobs()');
end $$;
```

- [ ] **Step 2: Apply locally**

Run: `supabase db reset` (from repo root; the local stack is running — `supabase start` first if not).
Expected: completes without error. If `enqueue_notification` / `trigger_notification_jobs` / `is_approved_or_kiosk` / `current_tenant_id` differ in signature, read `supabase/schema.sql` and adapt.

- [ ] **Step 3: Extend `supabase/tests/tenancy_rls.sql`**

(a) In the public_week key guard (`v_keys := array(select jsonb_object_keys(v->'priority_slots'->0) order by 1);` ≈ line 3148), add the seven new column names to the expected sorted array (`competition`, `round`, `site_match_id`, `site_slug`, `venue`, `venue_slug`, `video_url`) in alphabetical position — the federation's data is public.

(b) Before the final `reset role;\nrollback;` add a `-- 0045 výsledkový servis ČKA ---` section. Use tenant A (`00000000-0000-0000-0000-00000000000a`, admin `10000000-0000-0000-0000-000000000001`) and tenant B (`…0002`, admin `…0002`). As superuser (no role set) seed and call server functions; switch roles with the same `set local role authenticated; set local request.jwt.claims = '{"sub":"…","role":"authenticated"}';` / `reset role;` pattern the file uses. Assertions (each a `do $$ … $$` raising `FAIL: …`, ending with one `raise notice 'OK: …'`):

1. `insert into federation_sync (tenant_id, venue_slug, enabled) values (A, 'tj-sokol-brno-iv', true);` then `select apply_federation_matches(A, 'jihomoravska-divize-2026-2027', <2 matches>)` where match 1 = site id 101, `home_is_ours` true, date today+10 (`(now() at time zone 'Europe/Prague')::date + 10`), 17:00–20:00, prep 30, competition 'Jihomoravská divize', round 5, `site_slug 'jihomoravska-divize-2026-2027-kolo-5-x-y'`; match 2 = site id 102, `home_is_ours` false. Assert: 2 rows with import_key `cka:101`/`cka:102`; 101 `is_away=false, prep_minutes=30, description='Jihomoravská divize · 5. kolo'`, created_by = the admin; 102 `is_away=true, prep_minutes=0`; report `inserted = 2`.
2. Same call again → report `updated = 0, inserted = 0` (idempotent), and `video_url` change alone (`'https://youtu.be/x'` on 101) updates that column without counting in `updated`.
3. Rekey: insert a legacy row `import_key 'rozpis:JmD:6:A – B'` (use the builtin match type of A and the admin as created_by, date today+20), call apply with site id 103 carrying `legacy_id` = that row's id → the row's id is unchanged, `import_key = 'cka:103'`, report `rekeyed = 1`.
4. Hand-edited: `update priority_slots set hand_edited = true where import_key = 'cka:101'`; apply with 101 at a new time → row keeps the old time, report `skipped_hand_edited` has 1 element.
5. Delete-future: apply with only 101 and 103 → 102 (future, not hand-edited) is deleted, `deleted = 1`; a past `cka:` row of the same competition (insert one directly with date today−3, import_key `cka:104`, site_slug `jihomoravska-divize-2026-2027-kolo-1-x-y`) survives.
6. `apply_federation_result(A, 103, '{"status":"finished","match_type":"TEAMS_OF_6","discipline":"T120","video_url":null,"venue":{"slug":"jinde","name":"Kuželna Jinde"},"home_prep":30,"home":{"points":6,"total":3200,"fulls":2100,"spares":1100,"errors":10,"set_points":15},"away":{"points":2,"total":3100,"fulls":2050,"spares":1050,"errors":14,"set_points":9},"players":[{"side":"home","position":1,"player_name":"Jan Novák","player_site_id":7,"player_slug":"jan-novak","fulls":350,"spares":190,"errors":1,"total":540,"set_points":3,"team_points":1,"lanes":[{"lane":1,"fulls":90,"spares":45,"errors":0,"total":135,"setPoints":1}]}]}')` → one `match_results` row (`home_points 6`, `status 'finished'`), one player row; the slot (not hand-edited) became `is_away = true`, `prep_minutes = 0`, `venue_slug = 'jinde'`, description ends with `· Kuželna Jinde`. Calling it again leaves exactly one player row.
7. RLS: as A's admin, `select count(*) from match_results` = 1 and `from teams` works; as B's admin both are 0; as A's admin a direct `insert into match_results …` fails (`insufficient_privilege`) — wrap in `begin … exception when insufficient_privilege then null; end`.
8. Teams: as superuser `select upsert_federation_teams(A, '[{"site_slug":"tj-sokol-brno-iv-muzi","site_team_id":1,"site_name":"TJ Sokol Brno IV","competition_slug":"jihomoravska-divize-2026-2027","competition_name":"Jihomoravská divize","name":"TJ Sokol Brno IV","club_id":null}]')` returns 1; second call with `site_name` 'X' returns 0 and keeps name. As A's admin `update_team(id, 'Brno IV A', null, false)` works; as B's admin it raises `not_allowed`; a duplicate name raises `team_name_taken` (seed a second team first); `''` raises `empty_name`. Finish with `update_team(id, 'Brno IV A', null, true)` so the team is active again for item 9.
9. `set_federation_sync('Bad Slug', true)` raises `invalid_slug`; as a non-admin player it raises `not_allowed`. `request_federation_sync()` as A's admin enqueues one `federation_competition` job for the seeded team's competition (`select count(*) from notification_jobs where kind = 'federation_competition'` = 1 — run as superuser after `reset role`).
10. `refresh_match`: for the future 101 slot (10 days out, no result) → `'not_live'`; set a slot's date/time to now−30 min Prague (update 103's date/starts_at via superuser, `update match_results set status='in_progress', fetched_at = now() - interval '10 minutes'`) → `'queued'` and a `federation_match` job for 103 exists; `update match_results set fetched_at = now()` → `'fresh'`.
11. `select 1 from cron.job where jobname = 'federation-nightly' and schedule = '0 1 * * *'` exists; `enqueue_federation_jobs()` enqueues exactly one `federation_competition` job per distinct active competition of enabled tenants.
12. anon: `has_table_privilege('anon', 'public.match_results', 'select')` is false; `has_function_privilege('authenticated', 'public.apply_federation_matches(uuid, text, jsonb)', 'execute')` is false.

- [ ] **Step 4: Run the suite**

Run: `psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -X -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql`
Expected: every `NOTICE: OK: …` including the new ones, exit 0. Fix the migration (not the assertions) when a behaviour differs from the spec.

- [ ] **Step 5: Snapshot + docs + commit**

Run: `tool/schema_snapshot.sh` → `supabase/schema.sql regenerated`. Update `docs/SCHEMA.md` (rows in the tables list for `teams`, `federation_sync`, `match_results`, `match_player_results`, the new `priority_slots` columns; replace the "Import rozpisu" section with "Výsledkový servis ČKA (0045)" describing identity `cka:<id>`, update-in-place, rekeying of `rozpis:` rows, hand_edited skip, delete-only-future, job kinds and the nightly cron, `refresh_match` 5-min gate).

```bash
git add supabase/migrations/0045_federation.sql supabase/tests/tenancy_rls.sql supabase/schema.sql docs/SCHEMA.md
git commit -m "feat(federation): 0045 teams, sync settings, match results + server functions

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Job handlers in the `notify` tick

**Files:**
- Create: `supabase/functions/_shared/federation_jobs.ts`
- Create: `supabase/functions/_shared/federation_jobs_test.ts`
- Modify: `supabase/functions/notify/index.ts` (`processJobs` ≈ line 394 and the CRON branch ≈ line 554)

**Interfaces:**
- Consumes (Task 1): everything exported from `./federation.ts`; `pragueEpoch(sqlDate, sqlTime): number` (seconds) from `./cancel_token.ts`.
- Consumes (Task 2): RPCs `apply_federation_matches`, `apply_federation_result`, `upsert_federation_teams`, `record_federation_run`, `enqueue_federation_match`; tables `teams`, `federation_sync`, `priority_slots`, `clubs`, `notification_jobs`, `match_results`.
- Produces: `processFederationJobs(db, get, now?)` and `siteFetcher()` for notify.

The module must NOT import `@supabase/supabase-js` (CI runs `deno test` without the import map); use a local structural `Db` type.

- [ ] **Step 1: Failing tests** — `supabase/functions/_shared/federation_jobs_test.ts`:

```ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import type { SiteMatch } from "./federation.ts";
import { jobOutcome, matchJobsFor, planCompetition, planTeams } from "./federation_jobs.ts";

const match = (over: Partial<SiteMatch> & { id: number }): SiteMatch => ({
  slug: `jihomoravska-divize-2026-2027-kolo-1-m${over.id}`, date: "2026-10-10", time: "10:00",
  round: 1, status: "SCHEDULED", matchType: "TEAMS_OF_6", discipline: "T120", videoUrl: null,
  homeTeam: { id: 1, name: "TJ Sokol Brno IV", slug: "tj-sokol-brno-iv-muzi" },
  awayTeam: { id: 2, name: "KC Zlín B", slug: "kc-zlin-b-muzi" },
  competition: { slug: "jihomoravska-divize-2026-2027", name: "Jihomoravská divize" },
  ...over,
});
const teams = [
  { site_slug: "tj-sokol-brno-iv-muzi", name: "TJ Sokol Brno IV A", active: true },
  { site_slug: "tj-sokol-husovice-muzi", name: "TJ Sokol Husovice", active: false },
];

Deno.test("planCompetition keeps our active teams' matches, once, with app names", () => {
  const { rows, skipped } = planCompetition({
    matches: [
      match({ id: 1 }),
      match({ id: 1 }),
      match({ id: 2, homeTeam: { id: 3, name: "KK X", slug: "kk-x-muzi" } }),
      match({ id: 3, homeTeam: { id: 3, name: "KK X", slug: "kk-x-muzi" },
              awayTeam: { id: 4, name: "TJ Sokol Husovice", slug: "tj-sokol-husovice-muzi" } }),
      match({ id: 4, time: null }),
    ],
    teams,
    legacy: [],
  });
  assertEquals(rows.map((r) => r.site_match_id), [1]);
  assertEquals(skipped.length, 1);
  assertEquals(rows[0], {
    site_match_id: 1, site_slug: "jihomoravska-divize-2026-2027-kolo-1-m1",
    date: "2026-10-10", starts_at: "10:00", ends_at: "13:00",
    home: "TJ Sokol Brno IV A", away: "KC Zlín B", home_is_ours: true, prep: 30,
    competition: "Jihomoravská divize", round: 1, video_url: null, legacy_id: null,
  });
});

Deno.test("an away match of ours: home is not ours; inactive teams still count as ours for home", () => {
  const { rows } = planCompetition({
    matches: [match({ id: 5,
      homeTeam: { id: 4, name: "TJ Sokol Husovice", slug: "tj-sokol-husovice-muzi" },
      awayTeam: { id: 1, name: "TJ Sokol Brno IV", slug: "tj-sokol-brno-iv-muzi" } }),
      match({ id: 6, homeTeam: { id: 9, name: "KK Y", slug: "kk-y-muzi" },
        awayTeam: { id: 1, name: "TJ Sokol Brno IV", slug: "tj-sokol-brno-iv-muzi" } })],
    teams, legacy: [],
  });
  assertEquals(rows.find((r) => r.site_match_id === 5)!.home_is_ours, true);
  assertEquals(rows.find((r) => r.site_match_id === 6)!.home_is_ours, false);
});

Deno.test("planCompetition pairs legacy rows", () => {
  const { rows } = planCompetition({
    matches: [match({ id: 1, round: 5, date: "2026-10-17" })],
    teams,
    legacy: [{ id: "L1", import_key: "rozpis:JmD:5:TJ Sokol Brno IV A – KC Zlín B",
      date: "2026-10-10", home_team: "TJ Sokol Brno IV A", away_team: "KC Zlín B" }],
  });
  assertEquals(rows[0].legacy_id, "L1");
});

Deno.test("matchJobsFor: live, backfill and the next 48 hours", () => {
  const now = new Date("2026-10-10T06:00:00Z"); // 08:00 Prague
  const jobs = matchJobsFor({
    matches: [
      match({ id: 1, status: "IN_PROGRESS", date: "2026-10-10", time: "07:00" }),
      match({ id: 2, status: "FINISHED", date: "2026-09-20" }),
      match({ id: 3, status: "FINISHED", date: "2026-09-21" }),
      match({ id: 4, status: "SCHEDULED", date: "2026-10-11", time: "10:00" }),
      match({ id: 5, status: "SCHEDULED", date: "2026-10-20" }),
      match({ id: 6, status: "SCHEDULED", date: "2026-10-11", time: "10:00" }),
    ],
    statusById: new Map([[1, "scheduled"], [2, "finished"], [3, null], [4, null], [5, null]]),
    now,
  });
  assertEquals(jobs.map((j) => j.site_match_id).sort(), [1, 3, 4]);
  assertEquals(jobs.find((j) => j.site_match_id === 1)!.run_at, now);
  assertEquals(jobs.find((j) => j.site_match_id === 4)!.run_at, new Date("2026-10-10T08:00:00Z"));
});

Deno.test("planTeams: teams of venue clubs, names reused, clubs matched", () => {
  const teamsOut = planTeams({
    clubs: [{ slug: "tj-sokol-brno-iv", name: "TJ Sokol Brno IV" },
      { slug: "tj-sokol-husovice", name: "TJ Sokol Husovice" }],
    competitions: [{
      slug: "jihomoravska-divize-2026-2027",
      competition: { name: "Jihomoravská divize", roundIds: [1], currentRound: 1,
        matches: [match({ id: 1 })],
        standings: [
          { teamSlug: "tj-sokol-brno-iv-muzi", teamName: "TJ Sokol Brno IV" },
          { teamSlug: "tj-sokol-husovice-b-muzi", teamName: "TJ Sokol Husovice B" },
          { teamSlug: "kc-zlin-b-muzi", teamName: "KC Zlín B" },
        ] },
    }],
    existingNames: ["TJ Sokol Brno IV A", "KC Zlín B"],
    ourClubs: [{ id: "c1", name: "Sokol Brno IV" }, { id: "c2", name: "Veverky" }],
  });
  assertEquals(teamsOut, [
    { site_slug: "tj-sokol-brno-iv-muzi", site_team_id: 1, site_name: "TJ Sokol Brno IV",
      competition_slug: "jihomoravska-divize-2026-2027", competition_name: "Jihomoravská divize",
      name: "TJ Sokol Brno IV A", club_id: "c1" },
    { site_slug: "tj-sokol-husovice-b-muzi", site_team_id: null, site_name: "TJ Sokol Husovice B",
      competition_slug: "jihomoravska-divize-2026-2027", competition_name: "Jihomoravská divize",
      name: "TJ Sokol Husovice B", club_id: null },
  ]);
});

Deno.test("jobOutcome: rearm, stop, back off, give up", () => {
  const now = new Date("2026-10-10T06:00:00Z");
  const next = new Date("2026-10-10T07:00:00Z");
  assertEquals(jobOutcome({ next }, 2, now), { action: "rearm", run_at: next, attempts: 0 });
  assertEquals(jobOutcome({ next: null }, 0, now), { action: "delete" });
  assertEquals(jobOutcome({ error: "x" }, 2, now),
    { action: "rearm", run_at: new Date(now.getTime() + 4 * 60e3), attempts: 3 });
  assertEquals(jobOutcome({ error: "x" }, 5, now), { action: "delete" });
  assert(true);
});
```

Run: `deno test --allow-read supabase/functions/_shared/federation_jobs_test.ts` → FAIL (module missing).

- [ ] **Step 2: Implement `supabase/functions/_shared/federation_jobs.ts`**

```ts
// Federation jobs on the notification_jobs queue (0045). Pure planners
// first (tested), then the IO the notify tick runs.
import { pragueEpoch } from "./cancel_token.ts";
import {
  competitionSlugsForClubs, endTime, HOME_PREP_MINUTES, type LegacyRow, matchFormat,
  nextCheckpoint, normalizeTeam, pairLegacy, parseCompetition, parseMatch,
  parseSitemapLocs, parseVenueClubs, resultPayload, type SiteCompetition,
  type SiteMatch, teamBelongsToClub, type VenueClub,
} from "./federation.ts";

export const SITE = "https://vysledky.kuzelky.cz";
export type Fetcher = (path: string) => Promise<string>;
// deno-lint-ignore no-explicit-any
export type Db = any;

export type TeamRow = { site_slug: string; name: string; active: boolean };
export type SlotRow = {
  site_match_id: number; site_slug: string; date: string; starts_at: string; ends_at: string;
  home: string; away: string; home_is_ours: boolean; prep: number; competition: string;
  round: number; video_url: string | null; legacy_id: string | null;
};
export type TeamUpsert = {
  site_slug: string; site_team_id: number | null; site_name: string;
  competition_slug: string; competition_name: string; name: string; club_id: string | null;
};
export type Outcome =
  | { action: "delete" }
  | { action: "rearm"; run_at: Date; attempts: number };

const MAX_ATTEMPTS = 5;
const LEASE_MS = 10 * 60e3;
const LIMITS: [string, number][] = [
  ["federation_discover", 1],
  ["federation_competition", 1],
  ["federation_match", 10],
];
const MATCH_CONCURRENCY = 3;

const startOf = (m: { date: string; time: string | null }) =>
  new Date(pragueEpoch(m.date, m.time ?? "12:00") * 1000);

export function planCompetition(args: {
  matches: SiteMatch[]; teams: TeamRow[]; legacy: LegacyRow[];
}): { rows: SlotRow[]; skipped: string[] } {
  const ours = new Set(args.teams.map((t) => t.site_slug));
  const active = new Set(args.teams.filter((t) => t.active).map((t) => t.site_slug));
  const nameOf = new Map(args.teams.map((t) => [t.site_slug, t.name]));
  const unique = [...new Map(args.matches.map((m) => [m.id, m])).values()];
  const rows: SlotRow[] = [];
  const skipped: string[] = [];
  for (const m of unique) {
    if (!active.has(m.homeTeam.slug) && !active.has(m.awayTeam.slug)) continue;
    if (!m.time) {
      skipped.push(`${m.homeTeam.name} – ${m.awayTeam.name} (${m.date}): bez času`);
      continue;
    }
    rows.push({
      site_match_id: m.id, site_slug: m.slug, date: m.date, starts_at: m.time,
      ends_at: endTime(m.time, matchFormat(m.matchType, m.discipline).durationMin),
      home: nameOf.get(m.homeTeam.slug) ?? m.homeTeam.name,
      away: nameOf.get(m.awayTeam.slug) ?? m.awayTeam.name,
      home_is_ours: ours.has(m.homeTeam.slug), prep: HOME_PREP_MINUTES,
      competition: m.competition.name, round: m.round, video_url: m.videoUrl, legacy_id: null,
    });
  }
  const pairs = pairLegacy(
    rows.map((r) => ({ siteId: r.site_match_id, date: r.date, round: r.round, home: r.home, away: r.away })),
    args.legacy,
  );
  for (const r of rows) r.legacy_id = pairs.get(r.site_match_id) ?? null;
  return { rows, skipped };
}

export function matchJobsFor(args: {
  matches: SiteMatch[]; statusById: Map<number, string | null>; now: Date;
}): { site_match_id: number; slug: string; run_at: Date }[] {
  const n = args.now.getTime();
  const jobs = [];
  for (const m of new Map(args.matches.map((x) => [x.id, x])).values()) {
    if (!args.statusById.has(m.id)) continue;
    const stored = args.statusById.get(m.id);
    const start = startOf(m).getTime();
    let runAt: Date | null = null;
    if (m.status === "PREPARATION" || m.status === "IN_PROGRESS") runAt = args.now;
    else if ((m.status === "FINISHED" || m.status === "FORFEIT") &&
      stored !== "finished" && stored !== "forfeit") runAt = args.now;
    else if (m.status === "SCHEDULED" && start - n <= 48 * 3600e3 && start + 6 * 3600e3 > n) {
      runAt = nextCheckpoint("SCHEDULED", new Date(start), args.now);
    }
    if (runAt) jobs.push({ site_match_id: m.id, slug: m.slug, run_at: runAt });
  }
  return jobs;
}

export function planTeams(args: {
  clubs: VenueClub[];
  competitions: { slug: string; competition: SiteCompetition }[];
  existingNames: string[];
  ourClubs: { id: string; name: string }[];
}): TeamUpsert[] {
  const out = new Map<string, TeamUpsert>();
  for (const { slug, competition } of args.competitions) {
    const ids = new Map<string, number>();
    for (const m of competition.matches) {
      ids.set(m.homeTeam.slug, m.homeTeam.id);
      ids.set(m.awayTeam.slug, m.awayTeam.id);
    }
    for (const s of competition.standings) {
      const club = args.clubs.find((c) => teamBelongsToClub(s.teamSlug, c.slug));
      if (!club || out.has(s.teamSlug)) continue;
      out.set(s.teamSlug, {
        site_slug: s.teamSlug, site_team_id: ids.get(s.teamSlug) ?? null, site_name: s.teamName,
        competition_slug: slug, competition_name: competition.name,
        name: args.existingNames.find((n) => normalizeTeam(n) === normalizeTeam(s.teamName)) ??
          s.teamName,
        club_id: clubIdFor(club, args.ourClubs),
      });
    }
  }
  return [...out.values()];
}

function clubIdFor(club: VenueClub, ours: { id: string; name: string }[]): string | null {
  const web = normalizeTeam(club.name);
  const exact = ours.find((c) => normalizeTeam(c.name) === web);
  if (exact) return exact.id;
  const partial = ours.filter((c) => {
    const n = normalizeTeam(c.name);
    return n.length > 0 && (` ${web} `).includes(` ${n} `);
  });
  return partial.length === 1 ? partial[0].id : null;
}

export function jobOutcome(
  result: { next: Date | null } | { error: string }, attempts: number, now: Date,
): Outcome {
  if ("next" in result) {
    return result.next ? { action: "rearm", run_at: result.next, attempts: 0 } : { action: "delete" };
  }
  if (attempts >= MAX_ATTEMPTS) return { action: "delete" };
  return { action: "rearm", run_at: new Date(now.getTime() + 2 ** attempts * 60e3), attempts: attempts + 1 };
}

// ------------------------------------------------------------------- IO

export function siteFetcher(): Fetcher {
  return async (path) => {
    const res = await fetch(SITE + path, {
      headers: { "User-Agent": "Rezervator (+https://rezervator.online)" },
      signal: AbortSignal.timeout(15_000),
    });
    if (!res.ok) throw new Error(`GET ${path}: HTTP ${res.status}`);
    return await res.text();
  };
}

function must<T>(res: { data: T; error: { message: string } | null }): T {
  if (res.error) throw new Error(res.error.message);
  return res.data;
}

export async function runDiscover(db: Db, get: Fetcher, tenantId: string) {
  const sync = must(await db.from("federation_sync").select("venue_slug")
    .eq("tenant_id", tenantId).maybeSingle()) as { venue_slug: string } | null;
  if (!sync?.venue_slug) throw new Error("kuželna není nastavená");
  const clubs = parseVenueClubs(await get(`/detail-kuzelny/${sync.venue_slug}`));
  if (clubs.length === 0) throw new Error("na stránce kuželny nejsou žádné kluby");
  const seasons = parseSitemapLocs(await get("/sitemap.xml"))
    .map((u) => /\/sitemap\/matches-(\d+)\.xml$/.exec(u)?.[1])
    .filter((s): s is string => !!s)
    .map(Number).sort((a, b) => b - a);
  if (seasons.length === 0) throw new Error("sitemapa zápasů chybí");
  const locs = parseSitemapLocs(await get(`/sitemap/matches-${seasons[0]}.xml`));
  const competitions = [];
  for (const slug of competitionSlugsForClubs(locs, clubs.map((c) => c.slug))) {
    competitions.push({ slug, competition: parseCompetition(await get(`/detail-souteze/${slug}`)) });
  }
  const slots = must(await db.from("priority_slots").select("home_team, away_team")
    .eq("tenant_id", tenantId).not("import_key", "is", null)) as
    { home_team: string; away_team: string }[];
  const ourClubs = must(await db.from("clubs").select("id, name").eq("tenant_id", tenantId));
  const teams = planTeams({
    clubs, competitions, ourClubs,
    existingNames: [...new Set(slots.flatMap((s) => [s.home_team, s.away_team]))],
  });
  const created = must(await db.rpc("upsert_federation_teams", { p_tenant: tenantId, p_teams: teams }));
  return { teams: teams.length, created };
}

export async function runCompetition(db: Db, get: Fetcher, tenantId: string, slug: string, now: Date) {
  const teams = must(await db.from("teams").select("site_slug, name, active")
    .eq("tenant_id", tenantId)) as TeamRow[];
  const first = parseCompetition(await get(`/detail-souteze/${slug}?round=1`));
  const pages = [first];
  for (const id of first.roundIds) {
    if (id !== first.currentRound) {
      pages.push(parseCompetition(await get(`/detail-souteze/${slug}?round=${id}`)));
    }
  }
  const matches = pages.flatMap((p) => p.matches);
  const legacy = must(await db.from("priority_slots")
    .select("id, import_key, date, home_team, away_team")
    .eq("tenant_id", tenantId).like("import_key", "rozpis:%")) as LegacyRow[];
  const { rows, skipped } = planCompetition({ matches, teams, legacy });
  const report = must(await db.rpc("apply_federation_matches",
    { p_tenant: tenantId, p_competition_slug: slug, p_matches: rows })) as Record<string, unknown>;
  const stored = must(await db.from("priority_slots")
    .select("site_match_id, match_results(status)")
    .eq("tenant_id", tenantId).like("site_slug", `${slug}-kolo-%`)) as
    { site_match_id: number; match_results: { status: string } | { status: string }[] | null }[];
  const statusById = new Map(stored.map((s) => {
    const r = Array.isArray(s.match_results) ? s.match_results[0] : s.match_results;
    return [s.site_match_id, r?.status ?? null] as [number, string | null];
  }));
  const jobs = matchJobsFor({ matches, statusById, now });
  for (const j of jobs) {
    must(await db.rpc("enqueue_federation_match", {
      p_tenant: tenantId, p_site_match_id: j.site_match_id, p_slug: j.slug,
      p_run_at: j.run_at.toISOString(),
    }));
  }
  return { ...report, skipped_no_time: skipped, match_jobs: jobs.length };
}

export async function runMatch(
  db: Db, get: Fetcher, tenantId: string, siteMatchId: number, slug: string, now: Date,
): Promise<Date | null> {
  const d = parseMatch(await get(`/detail-zapasu/${slug}`));
  must(await db.rpc("apply_federation_result",
    { p_tenant: tenantId, p_site_match_id: siteMatchId, p_result: resultPayload(d) }));
  return nextCheckpoint(d.status, startOf(d), now);
}

type Job = { id: number; payload: Record<string, unknown>; attempts: number; run_at: string };

async function runJob(db: Db, get: Fetcher, kind: string, job: Job, now: Date): Promise<Date | null> {
  const tenant = String(job.payload.tenant_id);
  if (kind === "federation_discover") {
    const report = await runDiscover(db, get, tenant);
    must(await db.rpc("record_federation_run",
      { p_tenant: tenant, p_key: "discover", p_report: report, p_error: null }));
    return null;
  }
  if (kind === "federation_competition") {
    const slug = String(job.payload.competition_slug);
    const report = await runCompetition(db, get, tenant, slug, now);
    must(await db.rpc("record_federation_run",
      { p_tenant: tenant, p_key: `competition:${slug}`, p_report: report, p_error: null }));
    return null;
  }
  return await runMatch(db, get, tenant, Number(job.payload.site_match_id),
    String(job.payload.slug), now);
}

export async function processFederationJobs(db: Db, get: Fetcher, now = new Date()) {
  for (const [kind, limit] of LIMITS) {
    const due = must(await db.from("notification_jobs").select("id, payload, attempts, run_at")
      .eq("kind", kind).lte("run_at", now.toISOString()).order("run_at").limit(limit)) as Job[];
    const leased: Job[] = [];
    for (const job of due) {
      const { data } = await db.from("notification_jobs")
        .update({ run_at: new Date(now.getTime() + LEASE_MS).toISOString() })
        .eq("id", job.id).eq("run_at", job.run_at).select("id");
      if (data?.length) leased.push(job);
    }
    for (let i = 0; i < leased.length; i += MATCH_CONCURRENCY) {
      await Promise.all(leased.slice(i, i + MATCH_CONCURRENCY).map(async (job) => {
        let outcome: Outcome;
        try {
          outcome = jobOutcome({ next: await runJob(db, get, kind, job, now) }, job.attempts, now);
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          console.error(`job ${kind}/${job.id} failed:`, message);
          outcome = jobOutcome({ error: message }, job.attempts, now);
          await db.rpc("record_federation_run", {
            p_tenant: String(job.payload.tenant_id), p_key: kind, p_report: null,
            p_error: `${kind}: ${message}`,
          });
        }
        if (outcome.action === "delete") {
          await db.from("notification_jobs").delete().eq("id", job.id);
        } else {
          await db.from("notification_jobs")
            .update({ run_at: outcome.run_at.toISOString(), attempts: outcome.attempts })
            .eq("id", job.id);
        }
      }));
    }
  }
}
```

Run: `deno test --allow-read supabase/functions/_shared/federation_jobs_test.ts` → PASS. If the matchJobsFor time expectations are off by the Prague offset, recompute: `2026-10-11 10:00` Prague = `08:00Z`, T−24h = `2026-10-10T08:00Z`.

- [ ] **Step 3: Wire into `supabase/functions/notify/index.ts`**

1. Import: `import { processFederationJobs, siteFetcher } from "../_shared/federation_jobs.ts";`
2. In `processJobs()` the jobs query gets `.not("kind", "like", "federation_%")` before `.limit(100)`, so federation jobs are neither treated as unknown (deleted) nor able to crowd calendar jobs out of the 100.
3. In the CRON branch, after `await sendDueReminders();`:

```ts
    try {
      await processFederationJobs(supabase, siteFetcher());
    } catch (error) {
      console.error("federation jobs failed:", error);
    }
```

Update the file's header comment list (≈ line 20) with one line: `CRON notification_jobs -> federation_* jobs (0045): vysledky.kuzelky.cz sync`.

- [ ] **Step 4: Verify**

Run: `deno check --import-map supabase/functions/import_map.json supabase/functions/notify/index.ts` → clean.
Run: `deno test --allow-read supabase/functions` → all pass.

- [ ] **Step 5: Local end-to-end smoke (live site, read-only)**

With the local stack up and migrations applied: create a throwaway tenant row set via `psql` only if tenant A-like data exists locally; otherwise write a scratch Deno script in the session scratchpad (NOT in the repo) that calls `runCompetition` with a fake `db` object recording the `rpc`/`from` calls and `siteFetcher()` against the live site for `krajsky-prebor-2-tridy-sever-a-2026-2027`, with `teams = [{ site_slug: "tj-sokol-brno-iv-b-muzi", name: "TJ Sokol Brno IV B", active: true }]`, and print the `apply_federation_matches` payload: expect ~14 rows (all rounds), each with `ends_at` 90 min after `starts_at`. Report the output in the task report. Skip the step (say so) if the network is unavailable.

- [ ] **Step 6: Commit**

```bash
git add supabase/functions/_shared/federation_jobs.ts supabase/functions/_shared/federation_jobs_test.ts supabase/functions/notify/index.ts
git commit -m "feat(federation): discovery, competition and match jobs on the notify tick

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Flutter data layer — `Team`, `FederationSync`, streams, API, `ourTeamsProvider`

**Files:**
- Modify: `lib/domain/models.dart` (after `Club`, ≈ line 241)
- Modify: `lib/data/cache.dart` (keys ≈ line 19)
- Modify: `lib/data/providers.dart` (providers near `clubsProvider` ≈ line 208; `ourTeamsProvider` ≈ line 368; `Api` near `upsertClub` ≈ line 519; `resetTenantScopedProviders` ≈ line 1464)
- Test: `test/domain/team_test.dart` (new), `test/data/our_teams_test.dart` (extend)

**Interfaces — Produces** (Task 5):

```dart
class Team { final String id, name; final String? clubId; final String siteSlug, siteName, competitionSlug, competitionName; final bool active; factory Team.fromJson(Map<String, dynamic>); }
class FederationSync { final String venueSlug; final bool enabled; final DateTime? lastRunAt, lastSuccessAt; final String? lastError; static const none; bool get configured; factory FederationSync.fromJson(Map<String, dynamic>); }
final teamsProvider = StreamProvider<List<Team>>(...);             // sorted compareCzech by name
final federationSyncProvider = StreamProvider<FederationSync>(...); // FederationSync.none when no row
Api.setFederationSync({required String venueSlug, required bool enabled}) → Future<void>
Api.requestFederationDiscovery() → Future<void>
Api.requestFederationSync() → Future<void>
Api.updateTeam({required String id, required String name, String? clubId, required bool active}) → Future<void>
```

- [ ] **Step 1: Failing tests**

`test/domain/team_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';

void main() {
  test('Team.fromJson reads every column', () {
    final t = Team.fromJson({
      'id': 't1', 'name': 'TJ Sokol Brno IV A', 'club_id': 'c1',
      'site_slug': 'tj-sokol-brno-iv-muzi', 'site_name': 'TJ Sokol Brno IV',
      'competition_slug': 'jihomoravska-divize-2026-2027',
      'competition_name': 'Jihomoravská divize', 'active': false,
    });
    expect(t.name, 'TJ Sokol Brno IV A');
    expect(t.clubId, 'c1');
    expect(t.competitionName, 'Jihomoravská divize');
    expect(t.active, isFalse);
  });

  test('FederationSync.fromJson and none', () {
    expect(FederationSync.none.configured, isFalse);
    final s = FederationSync.fromJson({
      'venue_slug': 'tj-sokol-brno-iv', 'enabled': true,
      'last_run_at': '2026-09-23T01:00:00+00:00', 'last_success_at': null,
      'last_error': 'competition: HTTP 500',
    });
    expect(s.configured, isTrue);
    expect(s.enabled, isTrue);
    expect(s.lastRunAt, DateTime.utc(2026, 9, 23, 1));
    expect(s.lastSuccessAt, isNull);
    expect(s.lastError, 'competition: HTTP 500');
  });
}
```

In `test/data/our_teams_test.dart` add (following the file's existing container setup — read it first and reuse its helpers for overriding `prioritySlotsProvider`):
- with `teamsProvider` overridden to `[active 'KS Devítka Brno A', inactive 'SKK Veverky Brno C']` and slots giving `['TJ Sokol Husovice (dorost)', 'SKK Veverky Brno C']`, `ourTeamsProvider` is `['KS Devítka Brno A', 'TJ Sokol Husovice (dorost)']` (union, inactive removed, Czech order);
- with `teamsProvider` empty the existing behaviour is unchanged (existing tests keep passing; add the `teamsProvider` override to their container if needed).

Run: `flutter test test/domain/team_test.dart test/data/our_teams_test.dart` → FAIL (undefined `Team`).

- [ ] **Step 2: Models** — append after `clubNameOf` in `lib/domain/models.dart`:

```dart
/// One of the alley's teams on the federation's results site (0045). [name]
/// is the string the app keys matches, follows and colours by.
class Team {
  const Team({
    required this.id,
    required this.name,
    this.clubId,
    this.siteSlug = '',
    this.siteName = '',
    this.competitionSlug = '',
    this.competitionName = '',
    this.active = true,
  });

  final String id;
  final String name;
  final String? clubId;
  final String siteSlug;
  final String siteName;
  final String competitionSlug;
  final String competitionName;
  final bool active;

  factory Team.fromJson(Map<String, dynamic> json) => Team(
        id: json['id'] as String,
        name: json['name'] as String,
        clubId: json['club_id'] as String?,
        siteSlug: json['site_slug'] as String? ?? '',
        siteName: json['site_name'] as String? ?? '',
        competitionSlug: json['competition_slug'] as String? ?? '',
        competitionName: json['competition_name'] as String? ?? '',
        active: json['active'] as bool? ?? true,
      );
}

/// Správa → Oddíly: the alley on vysledky.kuzelky.cz and how the last
/// synchronisation went (0045). Admin-only rows.
class FederationSync {
  const FederationSync({
    this.venueSlug = '',
    this.enabled = false,
    this.lastRunAt,
    this.lastSuccessAt,
    this.lastError,
  });

  static const none = FederationSync();

  final String venueSlug;
  final bool enabled;
  final DateTime? lastRunAt;
  final DateTime? lastSuccessAt;
  final String? lastError;

  bool get configured => venueSlug.isNotEmpty;

  static DateTime? _time(Object? v) =>
      v == null ? null : DateTime.parse(v as String);

  factory FederationSync.fromJson(Map<String, dynamic> json) => FederationSync(
        venueSlug: json['venue_slug'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? false,
        lastRunAt: _time(json['last_run_at']),
        lastSuccessAt: _time(json['last_success_at']),
        lastError: json['last_error'] as String?,
      );
}
```

- [ ] **Step 3: Cache keys, providers, API**

`lib/data/cache.dart`: add `const cacheKeyTeams = 'teams';` and `const cacheKeyFederationSync = 'federation_sync';` next to `cacheKeyGroups`.

`lib/data/providers.dart`, after `clubsProvider`:

```dart
final teamsProvider = StreamProvider<List<Team>>((ref) {
  final uid = ref.watch(_authUidProvider);
  if (uid == null) return Stream.value(const []);
  return cachedRows(uid, cacheKeyTeams,
          () => _db.from('teams').stream(primaryKey: ['id']))
      .map((rows) => rows.map(Team.fromJson).toList()
        ..sort((a, b) => compareCzech(a.name, b.name)));
});

final federationSyncProvider = StreamProvider<FederationSync>((ref) {
  final uid = ref.watch(_authUidProvider);
  if (uid == null) return Stream.value(FederationSync.none);
  return cachedRows(uid, cacheKeyFederationSync,
          () => _db.from('federation_sync').stream(primaryKey: ['tenant_id']))
      .map((rows) =>
          rows.isEmpty ? FederationSync.none : FederationSync.fromJson(rows.first));
});
```

`ourTeamsProvider`: keep its current body as the "derived" list, then return the union with the active teams minus inactive ones:

```dart
final ourTeamsProvider = Provider<List<String>>((ref) {
  final teams = ref.watch(teamsProvider).value ?? const <Team>[];
  final inactive = {for (final t in teams) if (!t.active) t.name};
  final derived = <String>[/* the existing derivation, unchanged */];
  return {
    for (final t in teams) if (t.active) t.name,
    for (final name in derived) if (!inactive.contains(name)) name,
  }.toList()
    ..sort(compareCzech);
});
```

(Adapt the existing body into `derived` without changing its logic; keep its doc comment and add one line: active `teams` (0045) first, the schedule-derived names keep squads the site does not list yet, e.g. dorost.)

`class Api`, after `deleteClub`:

```dart
  static Future<void> setFederationSync({
    required String venueSlug,
    required bool enabled,
  }) =>
      _db.rpc('set_federation_sync',
          params: {'p_venue_slug': venueSlug, 'p_enabled': enabled});

  static Future<void> requestFederationDiscovery() =>
      _db.rpc('request_federation_discovery');

  static Future<void> requestFederationSync() =>
      _db.rpc('request_federation_sync');

  static Future<void> updateTeam({
    required String id,
    required String name,
    String? clubId,
    required bool active,
  }) =>
      _db.rpc('update_team', params: {
        'p_id': id,
        'p_name': name,
        'p_club_id': clubId,
        'p_active': active,
      });
```

(Match the exact style `upsertClub` uses for its return — if it awaits, await here too.)

`resetTenantScopedProviders`: add `ref.invalidate(teamsProvider);` and `ref.invalidate(federationSyncProvider);`.

- [ ] **Step 4: Verify** — `flutter test test/domain/team_test.dart test/data/our_teams_test.dart` → PASS; `flutter analyze` → `No issues found!`; `flutter test` → all green.

- [ ] **Step 5: Commit**

```bash
git add lib/domain/models.dart lib/data/cache.dart lib/data/providers.dart test/domain/team_test.dart test/data/our_teams_test.dart
git commit -m "feat(federation): teams and sync settings in the app's data layer

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Správa → Oddíly — ČKA card and teams under clubs

**Files:**
- Create: `lib/features/admin/widgets/federation_card.dart`
- Create: `lib/features/admin/widgets/team_dialog.dart`
- Modify: `lib/features/admin/clubs_screen.dart`
- Modify: `lib/features/admin/matches_screen.dart` (subtitle ≈ line 39)
- Modify: `lib/core/ui.dart` (`friendlyDbError` map ≈ line 109–127)
- Modify: `lib/features/profile/changelog_data.dart` (new top entry)
- Test: `test/features/clubs_screen_test.dart` (extend), `test/features/matches_screen_test.dart` (extend)

**Interfaces:**
- Consumes (Task 4): `teamsProvider`, `federationSyncProvider`, `clubsProvider`, `Api.setFederationSync/requestFederationDiscovery/requestFederationSync/updateTeam`, `Team`, `FederationSync`.

UI spec (Czech copy verbatim):
- `ClubsScreen` gains injectable callbacks (defaults = Api): `saveFederation(String venueSlug, bool enabled)`, `discoverTeams()`, `syncNow()`, `updateTeam(Team team, {required String name, String? clubId, required bool active})` — same injection style as `PublicOverviewScreen.save`.
- Body is always a `ListView`: first `FederationCard`, then per club its existing `ListTile` (unchanged: `ColorDot`, edit, delete) followed by its teams (clubId == club.id) as indented `_TeamTile`s, then — if any team has no known club — a `Padding` header `Text('Nezařazené týmy', style: titleSmall)` and those teams. When there are no clubs, show `Text('Zatím žádné oddíly.')` under the card (the existing test expects that text; keep it, drop its `Center`). FAB unchanged.
- `_TeamTile`: `ListTile(contentPadding: EdgeInsets.only(left: 56, right: 16), dense: true, title: Text(team.name), subtitle: Text(team.competitionName.isEmpty ? 'bez soutěže' : team.competitionName), trailing: Switch(value: team.active, onChanged: (v) => update(active: v)), onTap: open TeamDialog)`. Inactive name rendered with `onSurfaceVariant` colour.
- `TeamDialog(team, clubs)` returns `(String name, String? clubId, bool active)?`: `AlertDialog(title: Text('Tým'))`, a `TextField` labelled `Název v appce` prefilled with `team.name`, helper text `Podle názvu se řídí výběr týmů hráčů. Změna platí od další synchronizace.`, `DropdownButtonFormField<String?>` labelled `Oddíl` with first item `null` → `Bez oddílu` and one per club (`compareCzech` order), `SwitchListTile(title: Text('Stahovat zápasy'))`, a line `Na webu: ${team.siteName} · ${team.competitionName}` in bodySmall; actions `Zrušit` / `Uložit` (Uložit disabled while the trimmed name is empty).
- `FederationCard` (ConsumerStatefulWidget, callbacks passed in): `Card` with title `Výsledkový servis ČKA`, one line `Zápasy a výsledky týmů, které hrají na této kuželně, se stahují z vysledky.kuzelky.cz.`; `TextField` labelled `Kuželna na webu` with `prefixText: 'detail-kuzelny/'`, seeded once from `federationSyncProvider` (`venueSlug`, or `tj-sokol-brno-iv` when empty), like `PublicOverviewScreen` seeds its form; `SwitchListTile(title: Text('Stahovat automaticky'))`; buttons in a `Wrap`: `FilledButton('Uložit')` → `saveFederation(slug.trim(), enabled)` via `tryAction(success: 'Uloženo.', errorText: friendlyDbError)`; `OutlinedButton('Načíst týmy z webu')` → `discoverTeams()` (success `Týmy se načítají — za chvíli se objeví níže.`); `OutlinedButton('Synchronizovat teď')` → `syncNow()` (success `Synchronizace spuštěna.`). The two outlined buttons are disabled until the saved row is `configured`; `Synchronizovat teď` also needs `enabled`. Status line: `Poslední synchronizace: ${dayLabel} ${HH:MM}` from `lastSuccessAt` (local time; reuse the date formatting helpers in `core/ui.dart`) or `Zatím neproběhla`; when `lastError != null` a second line `Chyba: $lastError` in `colorScheme.error`.
- `matches_screen.dart` subtitle: `slot.importKey!.startsWith('cka:') ? 'ze svazu' : 'z rozpisu'`, keeping the ` · upraveno ručně` suffix logic.
- `friendlyDbError` additions: `'invalid_slug': 'Adresa kuželny smí mít jen malá písmena bez diakritiky, číslice a pomlčky.'`, `'federation_not_configured': 'Nejdřív ulož kuželnu z výsledkového servisu.'`, `'federation_disabled': 'Zapni nejdřív automatické stahování.'`, `'team_name_taken': 'Tým s tímto názvem už existuje.'`, `'empty_name': 'Název nesmí být prázdný.'`.
- Changelog: insert at the top of `appChangelog` `Release(null, '23. 9. 2026', ['Zápasy a výsledky se nově stahují z výsledkového servisu ČKA — správce je zapne v Správa → Oddíly.'])`.

- [ ] **Step 1: Failing widget tests** — extend `test/features/clubs_screen_test.dart`; the `app()` helper gains overrides `teamsProvider.overrideWith((ref) => Stream.value(teams))` and `federationSyncProvider.overrideWith((ref) => Stream.value(sync))` and passes recording fakes to `ClubsScreen(saveFederation: …, discoverTeams: …, syncNow: …, updateTeam: …)`. Tests:
  1. teams render under their club; a team with `clubId: null` appears after a `Nezařazené týmy` header; existing 3 tests still pass (adjust `find.byType(ListTile)` in the empty-state test to `findsNothing` only for club rows — e.g. assert `find.byType(ColorDot)` is nothing).
  2. with `FederationSync.none` the slug field shows `tj-sokol-brno-iv` and `Načíst týmy z webu` is disabled (`tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Načíst týmy z webu')).onPressed == null`).
  3. typing `ks-devitka-brno`, turning the switch on and tapping `Uložit` calls `saveFederation('ks-devitka-brno', true)`.
  4. with `FederationSync(venueSlug: 'tj-sokol-brno-iv', enabled: true, lastError: 'boom')` both outlined buttons are enabled, tapping them calls the fakes, and `Chyba: boom` is shown.
  5. toggling a team's `Switch` calls `updateTeam(team, name: team.name, clubId: team.clubId, active: false)`.
  6. tapping a team opens `Tým`; changing the name to `Brno IV A`, choosing `Bez oddílu` and `Uložit` calls `updateTeam(team, name: 'Brno IV A', clubId: null, active: true)`.
  In `test/features/matches_screen_test.dart` add: a slot with `importKey: 'cka:12'` shows `ze svazu`, one with `importKey: 'rozpis:X:1:A – B'` still shows `z rozpisu`.

Run: `flutter test test/features/clubs_screen_test.dart test/features/matches_screen_test.dart` → FAIL.

- [ ] **Step 2: Implement** the widgets and screen changes per the UI spec above. Keep `ClubsScreen` a `ConsumerWidget`; `FederationCard` owns the text controller. Use `tryAction` for every call (as `_addOrEdit` does).

- [ ] **Step 3: Verify** — the two test files PASS; `flutter analyze` → `No issues found!`; `flutter test` → all green (the `store_notes_test` "reminder" test about the 1.2.8 entry is a known, accepted failure — nothing else may fail).

- [ ] **Step 4: See it** — start the web preview (`.claude/launch.json` of the repo, if present; otherwise `flutter run -d web-server --web-port 8080` via the preview tool) signed in as a local admin, open Správa → Oddíly, screenshot the card. If no local admin session is feasible, say so in the report.

- [ ] **Step 5: Commit**

```bash
git add lib/features/admin lib/core/ui.dart lib/features/profile/changelog_data.dart test/features/clubs_screen_test.dart test/features/matches_screen_test.dart
git commit -m "feat(federation): ČKA sync card and teams in Správa → Oddíly

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Retire the xlsx importer

**Files:**
- Delete: `tool/import_matches.py`
- Modify: `README.md` (the importer section, ≈ lines 34–70)
- Modify: `lib/domain/models.dart` (`PrioritySlot.importKey` doc comment mentions `tool/import_matches.py`)
- Modify: any other reference found by `grep -rn "import_matches" --exclude-dir=build --exclude-dir=.dart_tool .` except `docs/superpowers/` history and migration comments (migrations are immutable).

- [ ] **Step 1:** `git rm tool/import_matches.py`
- [ ] **Step 2:** Replace the README importer section with a short Czech section `## Zápasy ze svazu` : zápasy a výsledky týmů kuželny se stahují z vysledky.kuzelky.cz (edge funkce `notify`, joby `federation_*`, noční cron `federation-nightly`, migrace 0045); nastavení v Správa → Oddíly; ruční úprava zápasu se při synchronizaci nepřepíše (`hand_edited`); zápas bez `import_key` je správcův vlastní. Mention that dorost matches not on the site stay as they are and are edited by hand.
- [ ] **Step 3:** Update the `importKey` doc comment: `Set when the row came from the federation (cka:<site id>, 0045) or the old xlsx import (rozpis:…); null = the admin entered the match by hand and no sync will ever touch it.`
- [ ] **Step 4:** `grep -rn "import_matches" --exclude-dir=build --exclude-dir=.dart_tool --exclude-dir=superpowers --exclude-dir=migrations .` → no hits. `flutter analyze` → clean.
- [ ] **Step 5: Commit**

```bash
git add -A tool README.md lib/domain/models.dart
git commit -m "chore: retire the xlsx match importer

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Deployment notes (not part of the tasks — for the PR description)

1. Merge → `deploy-backend.yml` runs `supabase db push` and then deploys the functions. The minute in between (old `notify`, which logs and drops unknown job kinds, against 0045) is harmless: federation jobs only come from the admin RPCs or the 01:00 UTC nightly cron, both only for a tenant with the sync enabled. So: wait until the workflow has deployed `notify`, only then enable the sync.
2. Správa → Oddíly: Uložit `tj-sokol-brno-iv` + zapnout, „Načíst týmy z webu“, zkontrolovat názvy/oddíly, „Synchronizovat teď“.
3. Check `federation_sync.last_report` with the SQL snippet in `docs/SCHEMA.md` (Výsledkový servis ČKA → "After the first run"): per competition `rekeyed` vs `inserted`, any `error`, and every `legacy_unpaired` entry (an old `rozpis:` row the sync did not take over — resolve by hand). Confirm followers got no duplicate Google Calendar events and played matches stayed in their calendars.
4. Deactivating a team stops its sync; its future matches disappear on the next sync of its competition only while another active team keeps that competition synced — otherwise they stay.
