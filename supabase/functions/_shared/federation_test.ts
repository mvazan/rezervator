import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  competitionSlugsForClubs, endTime, matchFormat, nextCheckpoint, normalizeTeam,
  pairLegacy, parseCompetition, parseMatch, parseSitemapLocs, parseVenue, parseVenueClubs,
  resultPayload, rscText, sameTeamForPairing, teamBelongsToClub, valueAfter,
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
  assertEquals(k.matches.map((m) => m.status).sort(), ["FINISHED", "FINISHED", "PREPARATION", "SCHEDULED"]);
  assert(k.standings.length > 0);
  assert(k.standings.some((s) => s.teamSlug === "tj-sokol-husovice-e-muzi"));
});

Deno.test("team placeholders: a missing name falls back to the slug, a missing slug is refused", () => {
  const page = (home: Record<string, unknown>) => {
    const m = {
      id: 1, slug: "x-kolo-1-a-b", date: "2026-10-10", time: "10:00", round: 1,
      status: "SCHEDULED", matchType: "TEAMS_OF_6", discipline: "T120", videoUrl: "$undefined",
      homeTeam: home, awayTeam: { id: 2, name: "KK B", slug: "kk-b-muzi" },
      competition: { slug: "x", name: "X" },
    };
    const data = { data: { title: "X", rounds: [{ id: 1 }], currentRound: { id: 1, matches: [m] } } };
    return `<script>self.__next_f.push([1,${JSON.stringify(`5:${JSON.stringify(data)}`)}])</script>`;
  };
  const c = parseCompetition(page({ id: 1, name: "$undefined", slug: "kk-a-muzi" }));
  assertEquals(c.matches[0].homeTeam, { id: 1, name: "kk-a-muzi", slug: "kk-a-muzi" });
  assertThrows(() => parseCompetition(page({ id: 1, name: "KK A", slug: "$L7" })));
});

Deno.test("match placeholders: a missing slug or date is refused, other texts fall back to empty", () => {
  const page = (over: Record<string, unknown>, title: unknown = "X") => {
    const m = {
      id: 1, slug: "x-kolo-1-a-b", date: "2026-10-10", time: "10:00", round: 1,
      status: "SCHEDULED", matchType: "TEAMS_OF_6", discipline: "T120", videoUrl: "$undefined",
      homeTeam: { id: 1, name: "KK A", slug: "kk-a-muzi" },
      awayTeam: { id: 2, name: "KK B", slug: "kk-b-muzi" },
      competition: { slug: "x", name: "X" },
      ...over,
    };
    const data = { data: { title, rounds: [{ id: 1 }], currentRound: { id: 1, matches: [m] } } };
    return `<script>self.__next_f.push([1,${JSON.stringify(`5:${JSON.stringify(data)}`)}])</script>`;
  };
  assertThrows(() => parseCompetition(page({ slug: "$undefined" })), Error, "bad match");
  assertThrows(() => parseCompetition(page({ date: "$undefined" })), Error, "bad match");
  const c = parseCompetition(page({
    matchType: "$undefined", discipline: "$undefined",
    competition: { slug: "$undefined", name: "$undefined" },
  }, "$undefined"));
  assertEquals(c.name, "");
  assertEquals(c.matches[0].matchType, "");
  assertEquals(c.matches[0].discipline, "");
  assertEquals(c.matches[0].competition, { slug: "", name: "" });
});

Deno.test("a competition page whose rounds do not list the current round is refused", () => {
  const page = (rounds: { id: number }[]) => {
    const m = {
      id: 1, slug: "x-kolo-1-a-b", date: "2026-10-10", time: "10:00", round: 1,
      status: "SCHEDULED", matchType: "TEAMS_OF_6", discipline: "T120", videoUrl: "$undefined",
      homeTeam: { id: 1, name: "KK A", slug: "kk-a-muzi" },
      awayTeam: { id: 2, name: "KK B", slug: "kk-b-muzi" },
      competition: { slug: "x", name: "X" },
    };
    const data = { data: { title: "X", rounds, currentRound: { id: 1, matches: [m] } } };
    return `<script>self.__next_f.push([1,${JSON.stringify(`5:${JSON.stringify(data)}`)}])</script>`;
  };
  assertEquals(parseCompetition(page([{ id: 1 }, { id: 2 }])).roundIds, [1, 2]);
  assertThrows(() => parseCompetition(page([])), Error, "competition rounds missing");
  assertThrows(() => parseCompetition(page([{ id: 2 }])), Error, "competition rounds missing");
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

/** One side of a match detail page's `results`. */
const matchSide = (isHome: boolean) => ({
  isHome, teamPoints: isHome ? 6 : 2, totalPerformance: 3460, totalFull: 2300,
  totalSpare: 1160, totalErrors: 12, totalSetPoints: 14,
  playerResults: [{
    position: 1, teamPoints: 1, setPoints: 3, totalFull: 390, totalSpare: 190,
    totalErrors: 2, totalPerformance: 580,
    player: { id: 7, firstName: "Jan", lastName: "Novák", slug: "jan-novak" },
    laneResults: [{ laneNumber: 1, full: 98, spare: 47, errors: 0, total: 145, setPoints: 1 }],
  }],
  substitutions: [],
});

/** A match detail page as the site renders it (RSC flight chunk). */
function matchPage(over: Record<string, unknown> = {}): string {
  const m = {
    id: 1, slug: "x-kolo-1-a-b", date: "2026-10-10", time: "10:00", round: 1,
    status: "FINISHED", matchType: "TEAMS_OF_6", discipline: "T120", videoUrl: null,
    homeTeam: { id: 1, name: "KK A", slug: "kk-a-muzi" },
    awayTeam: { id: 2, name: "KK B", slug: "kk-b-muzi" },
    competition: { slug: "x", name: "X" },
    results: [matchSide(true), matchSide(false)],
    venue: { slug: "kk-a", name: "KK A" },
    ...over,
  };
  return `<script>self.__next_f.push([1,${JSON.stringify(`5:${JSON.stringify({ match: m })}`)}])</script>`;
}

Deno.test("parseMatch refuses a page whose results changed shape, so nothing gets overwritten", () => {
  const d = parseMatch(matchPage());
  assertEquals(d.home!.total, 3460);
  assertEquals(d.away!.players.length, 1);
  const home = matchSide(true);
  const away = matchSide(false);
  assertThrows(() => parseMatch(matchPage({ results: undefined })));
  assertThrows(() => parseMatch(matchPage({ results: null })));
  assertThrows(() => parseMatch(matchPage({
    results: [{ ...home, playerResults: undefined, players: home.playerResults }, away],
  })));
  assertThrows(() => parseMatch(matchPage({ results: [{ ...home, isHome: undefined, home: true }, away] })));
});

Deno.test("a forfeit with no results parses to no sides", () => {
  const d = parseMatch(matchPage({ status: "FORFEIT", results: [] }));
  assertEquals(d.status, "FORFEIT");
  assertEquals(d.home, null);
  assertEquals(d.away, null);
  const p = resultPayload(d);
  assertEquals(p.status, "forfeit");
  assertEquals(p.players, []);
});

Deno.test("live statuses reach apply_federation_result in the lower case its CHECK allows", () => {
  for (const [status, stored] of [["PREPARATION", "preparation"], ["IN_PROGRESS", "in_progress"]]) {
    const d = parseMatch(matchPage({ status }));
    assertEquals(d.status, status);
    const p = resultPayload(d);
    assertEquals(p.status, stored);
    assertEquals((p.players as unknown[]).length, 2);
  }
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

Deno.test("venue page: home venue with full technical info", () => {
  const v = parseVenue(fixture("venue.html"), "tj-sokol-brno-iv");
  assertEquals(v.slug, "tj-sokol-brno-iv");
  assertEquals(v.name, "TJ Sokol Brno IV");
  assertEquals(v.address, "Štolcova 551/8, 61800 Brno");
  assertEquals(v.phone, "736435492");
  assertEquals(v.email, "kuzelkybrnoiv@email.cz");
  assert(v.lat !== null && Math.abs(v.lat - 49.1891783) < 1e-6);
  assert(v.lng !== null && Math.abs(v.lng - 16.6354503) < 1e-6);
  assert(v.sections.some((s) =>
    s.items.some((i) => i.label === "Dráhy" && i.value === "4") &&
    s.items.some((i) => i.label === "Stavěč kuželek" && i.value === "Pro-Tec K800")
  ));
  assert(v.sections.every((s) =>
    s.items.every((i) => !["Adresa", "Telefon", "E-mail"].includes(i.label))
  ));
  assertEquals(v.clubs.sort(), [
    "KS Devítka Brno", "SKK Veverky Brno", "TJ Sokol Brno IV", "TJ Sokol Husovice",
  ]);
});

Deno.test("venue page: away venue with missing technical fields dropped", () => {
  const v = parseVenue(fixture("venue_away.html"), "tj-odry");
  const tech = v.sections.find((s) => s.items.some((i) => i.label === "Dráhy"));
  assert(tech);
  assert(!tech!.items.some((i) => i.label === "Kuželky"));
  assert(!tech!.items.some((i) => i.label === "Stavěč kuželek"));
  const guests = v.sections.find((s) => s.items.some((i) => i.label === "Samostatné WC"));
  assertEquals(guests!.items.find((i) => i.label === "Samostatné WC")!.value, "ne");
  assertEquals(v.clubs, ["TJ Odry"]);
});

Deno.test("parseVenue refuses a page without the data", () => {
  assertThrows(() => parseVenue("<html></html>", "x"));
});

Deno.test("venue lat/lng come only from the mapy.com link, not a stray x=/y= elsewhere in the dd", () => {
  const html = [
    "<h1>Detail kuželny<!-- -->: <!-- -->Test Venue</h1>",
    '<h2 class="text-base uppercase mb-5">Základní informace</h2>',
    "<dl>",
    "<dt>Adresa:</dt>",
    '<dd class="flex &x=1&y=2"><span>Foo 1, Bar</span>',
    '<a href="https://mapy.com/zakladni?source=coor&amp;x=16.6354503&amp;y=49.1891783&amp;z=17">Zobrazit na mapě</a></dd>',
    "</dl>",
    '<h2 class="text-base uppercase mb-5">Kluby působící v kuželně</h2>',
    '<div><a href="/detail-klubu/test-club"><span>Test Club</span></a></div>',
  ].join("");
  const v = parseVenue(html, "test-venue");
  assert(v.lng !== null && Math.abs(v.lng - 16.6354503) < 1e-6);
  assert(v.lat !== null && Math.abs(v.lat - 49.1891783) < 1e-6);
});

Deno.test("venue lat/lng are null when the Adresa dd has no mapy.com link", () => {
  const html = [
    "<h1>Detail kuželny<!-- -->: <!-- -->Test Venue</h1>",
    '<h2 class="text-base uppercase mb-5">Základní informace</h2>',
    "<dl><dt>Adresa:</dt><dd><span>Foo 1, Bar</span></dd></dl>",
  ].join("");
  const v = parseVenue(html, "test-venue");
  assertEquals(v.lat, null);
  assertEquals(v.lng, null);
});

Deno.test("venue section values decode nbsp and numeric HTML entities, not just named ones", () => {
  const html = [
    "<h1>Detail kuželny<!-- -->: <!-- -->Test Venue</h1>",
    '<h2 class="text-base uppercase mb-5">Základní informace</h2>',
    "<dl><dt>Poznámka:</dt><dd>&#65;&#x42;&nbsp;test</dd></dl>",
  ].join("");
  const v = parseVenue(html, "test-venue");
  assertEquals(v.sections[0].items[0], { label: "Poznámka", value: "AB test" });
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
  // The site de-duplicates a slug with a numeric suffix.
  assert(teamBelongsToClub("tj-nova-vcelnice-a-muzi-2", "tj-nova-vcelnice"));
  assert(!teamBelongsToClub("tj-nova-vcelnice-a-muzi-2", "tj-nova"));
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
    { id: "L1", import_key: "rozpis:Jihomoravská divize:5:TJ Sokol Brno IV A – KC Zlín B", date: "2026-10-10", starts_at: "17:00:00", home_team: "TJ Sokol Brno IV A", away_team: "KC Zlín B" },
    { id: "L2", import_key: "rozpis:KP2:3:SKK Veverky Brno B – KK Orel Telnice B", date: "2026-10-03", starts_at: "17:00:00", home_team: "SKK Veverky Brno B", away_team: "KK Orel Telnice B" },
    { id: "L3", import_key: "rozpis:X:1:A – B", date: "2026-09-01", starts_at: "17:00:00", home_team: "A", away_team: "B" },
  ];
  const pairs = pairLegacy([
    // postponed: other date, same round + teams
    { siteId: 1, date: "2026-10-17", startsAt: "10:00", round: 5, home: "TJ Sokol Brno IV", away: "KC Zlín B" },
    // other round in the key, same date + teams
    { siteId: 2, date: "2026-10-03", startsAt: "10:00", round: 4, home: "SKK Veverky Brno B", away: "KK Orel Telnice B" },
    { siteId: 3, date: "2026-11-01", startsAt: "10:00", round: 9, home: "Nobody", away: "Else" },
  ], legacy);
  assertEquals(pairs.get(1), "L1");
  assertEquals(pairs.get(2), "L2");
  assertEquals(pairs.has(3), false);
});

Deno.test("a renamed opponent pairs by date, start and one team in common — unambiguous only", () => {
  const legacy = [
    { id: "L1", import_key: "rozpis:JmD:5:TJ Sokol Brno IV A – KK Starý", date: "2026-10-10", starts_at: "17:00:00", home_team: "TJ Sokol Brno IV A", away_team: "KK Starý" },
    { id: "L2", import_key: "rozpis:JmD:6:KK Jiný – TJ Sokol Brno IV A", date: "2026-10-17", starts_at: "10:00:00", home_team: "KK Jiný", away_team: "TJ Sokol Brno IV A" },
    { id: "L3", import_key: "rozpis:JmD:7:KK Třetí – KK Čtvrtý", date: "2026-10-24", starts_at: "09:00:00", home_team: "KK Třetí", away_team: "KK Čtvrtý" },
  ];
  const pairs = pairLegacy([
    // opponent renamed, round moved: only the third rule sees it
    { siteId: 1, date: "2026-10-10", startsAt: "17:00", round: 9, home: "TJ Sokol Brno IV", away: "KK Nový" },
    // same date and teams in common, other start: no pair
    { siteId: 2, date: "2026-10-17", startsAt: "11:00", round: 6, home: "KK Přejmenovaný", away: "TJ Sokol Brno IV A" },
    // two candidates share a team with L3 at its slot: ambiguous, no pair
    { siteId: 3, date: "2026-10-24", startsAt: "09:00", round: 7, home: "KK Třetí", away: "KK X" },
    { siteId: 4, date: "2026-10-24", startsAt: "09:00", round: 7, home: "KK Y", away: "KK Čtvrtý" },
  ], legacy);
  assertEquals([...pairs], [[1, "L1"]]);
});

Deno.test("a legacy row pairs at most once", () => {
  const legacy = [{ id: "L1", import_key: "rozpis:X:1:A – B", date: "2026-09-01", starts_at: "17:00:00", home_team: "A", away_team: "B" }];
  const pairs = pairLegacy([
    { siteId: 1, date: "2026-09-01", startsAt: "10:00", round: 1, home: "A", away: "B" },
    { siteId: 2, date: "2026-09-01", startsAt: "10:00", round: 1, home: "A", away: "B" },
  ], legacy);
  assertEquals([...pairs.values()], ["L1"]);
});

Deno.test("pairing reads abbreviated club names as the site's full ones, team letter and digits exact", () => {
  // "MS" is the initials of "Moravská Slavia" (the site spells it Slávia too).
  assert(sameTeamForPairing("KK MS Brno B", "KK Moravská Slavia Brno B"));
  assert(sameTeamForPairing("KK Moravská Slávia Brno E", "KK MS Brno E"));
  // "n.L." is one-letter abbreviations of "nad Lipou".
  assert(sameTeamForPairing("TJ Slovan Kamenice n.L.", "TJ Slovan Kamenice nad Lipou"));
  assert(sameTeamForPairing("TJ Sokol Brno IV A", "TJ Sokol Brno IV"));
  // Another squad of the same club is another team.
  assert(!sameTeamForPairing("KK MS Brno B", "KK MS Brno C"));
  assert(!sameTeamForPairing("KK MS Brno B", "KK Moravská Slavia Brno C"));
  assert(!sameTeamForPairing("KK MS Brno B", "KK Moravská Slavia Brno"));
  assert(!sameTeamForPairing("TJ Sokol Brno IV", "TJ Sokol Brno IV B"));
  // Letters that are not initials of a run, and digits, never stretch.
  assert(!sameTeamForPairing("SK Brno Žabovřesky", "SKK Brno Žabovřesky"));
  assert(!sameTeamForPairing("SKK Brno Žabovřesky", "SK Brno Žabovřesky"));
  assert(!sameTeamForPairing("KK MS Brno B", "KK Moravská Brno B"));
  assert(!sameTeamForPairing("KK Brno 2 B", "KK Brno 3 B"));
  assert(!sameTeamForPairing("TJ Sokol Brno I", "TJ Sokol Brno IV"));
});

/** The three rehearsal misses (TJ Sokol Brno IV's first sync) and the return
 * leg that paired: legacy rows as the old importer stored them. */
const rehearsalLegacy = [
  { id: "44ac482c-1798-442e-95a3-c3a13e0564a1", import_key: "rozpis:JM divize:8:TJ Sokol Brno IV – KK MS Brno B", date: "2026-10-30", starts_at: "18:00:00", home_team: "TJ Sokol Brno IV", away_team: "KK MS Brno B" },
  { id: "868a0938-131a-4858-ab68-c15c86a33e35", import_key: "rozpis:JM divize:14:TJ Sokol Brno IV – KK MS Brno C", date: "2026-12-11", starts_at: "18:00:00", home_team: "TJ Sokol Brno IV", away_team: "KK MS Brno C" },
  { id: "3806e9a4-56b4-4898-8492-90dc12679ce2", import_key: "rozpis:KP1 Sever:3:KK MS Brno E – KS Devítka Brno A", date: "2026-09-30", starts_at: "18:00:00", home_team: "KK MS Brno E", away_team: "KS Devítka Brno A" },
  { id: "f75c83bd-94df-4b6c-9a50-b42c25b03aaa", import_key: "rozpis:KP1 Sever:23:KS Devítka Brno A – KK MS Brno E", date: "2027-04-14", starts_at: "18:30:00", home_team: "KS Devítka Brno A", away_team: "KK MS Brno E" },
];

Deno.test("the rehearsal misses pair: the site's full club name, a new round, a match moved a month", () => {
  const divize = pairLegacy([
    // Same round, the site's start is half an hour later.
    { siteId: 2297, date: "2026-10-30", startsAt: "18:30", round: 8, home: "TJ Sokol Brno IV", away: "KK Moravská Slavia Brno B" },
    // Same date, the site numbers the round 15, the rozpis 14.
    { siteId: 2344, date: "2026-12-11", startsAt: "18:30", round: 15, home: "TJ Sokol Brno IV", away: "KK Moravská Slavia Brno C" },
  ], rehearsalLegacy);
  assertEquals(divize.get(2297), "44ac482c-1798-442e-95a3-c3a13e0564a1");
  assertEquals(divize.get(2344), "868a0938-131a-4858-ab68-c15c86a33e35");
  const kp1 = pairLegacy([
    // Moved from 30.9 (round 3) to 30.10 (round 4): no date, round or start in common.
    { siteId: 4017, date: "2026-10-30", startsAt: "18:00", round: 4, home: "KK Moravská Slávia Brno E", away: "KS Devítka Brno A" },
    // The return leg: the same two teams the other way round.
    { siteId: 4083, date: "2027-04-14", startsAt: "18:30", round: 15, home: "KS Devítka Brno A", away: "KK Moravská Slávia Brno E" },
  ], rehearsalLegacy);
  assertEquals(kp1.get(4017), "3806e9a4-56b4-4898-8492-90dc12679ce2");
  assertEquals(kp1.get(4083), "f75c83bd-94df-4b6c-9a50-b42c25b03aaa");
});

/** The two divize misses as the site lists them: they pair through the
 * name equivalence alone, so they show the new rules are on. */
const divizeMisses = [
  { siteId: 2297, date: "2026-10-30", startsAt: "18:30", round: 8, home: "TJ Sokol Brno IV", away: "KK Moravská Slavia Brno B" },
  { siteId: 2344, date: "2026-12-11", startsAt: "18:30", round: 15, home: "TJ Sokol Brno IV", away: "KK Moravská Slavia Brno C" },
];
const divizePairs = [
  [2297, "44ac482c-1798-442e-95a3-c3a13e0564a1"],
  [2344, "868a0938-131a-4858-ab68-c15c86a33e35"],
];

Deno.test("the any-date rule pairs nothing when the same home and away meet twice", () => {
  const moved = rehearsalLegacy[2];
  // Two site matches of KK MS Brno E at home to Devítka A within two months of
  // the rozpis date, neither on it.
  const twoSite = pairLegacy([
    ...divizeMisses,
    { siteId: 4017, date: "2026-10-30", startsAt: "18:00", round: 4, home: "KK Moravská Slávia Brno E", away: "KS Devítka Brno A" },
    { siteId: 4090, date: "2026-11-25", startsAt: "18:00", round: 8, home: "KK Moravská Slávia Brno E", away: "KS Devítka Brno A" },
  ], rehearsalLegacy.slice(0, 3));
  assertEquals([...twoSite], divizePairs);
  // Two rozpis rows for the one site match, neither on its date.
  const twoLegacy = pairLegacy([
    ...divizeMisses,
    { siteId: 4017, date: "2026-10-30", startsAt: "18:00", round: 4, home: "KK Moravská Slávia Brno E", away: "KS Devítka Brno A" },
  ], [...rehearsalLegacy.slice(0, 3), {
    ...moved, id: "L2", import_key: "rozpis:KP1 Sever:12:KK MS Brno E – KS Devítka Brno A",
    date: "2026-12-02",
  }]);
  assertEquals([...twoLegacy], divizePairs);
});

Deno.test("an abbreviated opponent with another team letter stays unpaired", () => {
  const pairs = pairLegacy([
    // KK MS Brno C at the B squad's slot and round: another team.
    { siteId: 9001, date: "2026-10-30", startsAt: "18:30", round: 8, home: "TJ Sokol Brno IV", away: "KK Moravská Slavia Brno C" },
    // The F squad at home to Devítka A: not the E squad's moved match.
    { siteId: 9002, date: "2026-10-30", startsAt: "18:00", round: 4, home: "KK Moravská Slávia Brno F", away: "KS Devítka Brno A" },
    // The E squad's own moved match still pairs next to it.
    { siteId: 4017, date: "2026-10-30", startsAt: "18:00", round: 4, home: "KK Moravská Slávia Brno E", away: "KS Devítka Brno A" },
  ], [rehearsalLegacy[0], rehearsalLegacy[2]]);
  assertEquals([...pairs], [[4017, "3806e9a4-56b4-4898-8492-90dc12679ce2"]]);
});

/** Both legs of two real derbies as the rozpis has them (KP2 Sever A and B). */
const derbyLegacy = [
  { id: "a0483dd5-854c-47f2-a031-d769601555d5", import_key: "rozpis:KP2 Sever B:1:SKK Veverky Brno C – SK Brno Žabovřesky B", date: "2026-09-14", starts_at: "19:00:00", home_team: "SKK Veverky Brno C", away_team: "SK Brno Žabovřesky B" },
  { id: "33fffbdd-dd36-415e-8d40-daa2e1a6cd66", import_key: "rozpis:KP2 Sever B:3:SK Brno Žabovřesky B – SKK Veverky Brno C", date: "2026-10-07", starts_at: "17:00:00", home_team: "SK Brno Žabovřesky B", away_team: "SKK Veverky Brno C" },
  { id: "7022cb6e-6379-4bd5-81e9-7cb37c981da6", import_key: "rozpis:KP2 Sever A:4:KK MS Brno H – SKK Veverky Brno B", date: "2026-10-12", starts_at: "17:00:00", home_team: "KK MS Brno H", away_team: "SKK Veverky Brno B" },
  { id: "d5fc4391-574c-42da-850a-b7ef94d30a47", import_key: "rozpis:KP2 Sever A:5:SKK Veverky Brno B – KK MS Brno H", date: "2026-10-21", starts_at: "18:30:00", home_team: "SKK Veverky Brno B", away_team: "KK MS Brno H" },
];

Deno.test("a leg whose home rights were swapped pairs with the rozpis row on its own date", () => {
  // Both legs swapped: the any-date rule would hand each leg the other's row.
  const b = pairLegacy([
    { siteId: 4189, date: "2026-09-14", startsAt: "19:00", round: 1, home: "SK Brno Žabovřesky B", away: "SKK Veverky Brno C" },
    { siteId: 4217, date: "2026-10-07", startsAt: "17:00", round: 8, home: "SKK Veverky Brno C", away: "SK Brno Žabovřesky B" },
  ], derbyLegacy);
  assertEquals(b.get(4189), "a0483dd5-854c-47f2-a031-d769601555d5");
  assertEquals(b.get(4217), "33fffbdd-dd36-415e-8d40-daa2e1a6cd66");
  // Both legs swapped where the site's rounds do not follow the rozpis: site
  // round 4 is the rozpis round 4 pairing, but on the other leg's date.
  const a = pairLegacy([
    { siteId: 4173, date: "2026-10-12", startsAt: "17:00", round: 11, home: "SKK Veverky Brno B", away: "KK Moravská Slávia Brno H" },
    { siteId: 4145, date: "2026-10-21", startsAt: "18:30", round: 4, home: "KK Moravská Slávia Brno H", away: "SKK Veverky Brno B" },
  ], derbyLegacy);
  assertEquals(a.get(4173), "7022cb6e-6379-4bd5-81e9-7cb37c981da6");
  assertEquals(a.get(4145), "d5fc4391-574c-42da-850a-b7ef94d30a47");
  // One leg swapped: both legs have the same home on the site.
  const one = pairLegacy([
    { siteId: 4189, date: "2026-09-14", startsAt: "19:00", round: 1, home: "SKK Veverky Brno C", away: "SK Brno Žabovřesky B" },
    { siteId: 4217, date: "2026-10-07", startsAt: "17:00", round: 8, home: "SKK Veverky Brno C", away: "SK Brno Žabovřesky B" },
  ], derbyLegacy);
  assertEquals(one.get(4189), "a0483dd5-854c-47f2-a031-d769601555d5");
  assertEquals(one.get(4217), "33fffbdd-dd36-415e-8d40-daa2e1a6cd66");
});

/** A KP dorostu row the site does not list this season: it stays a free
 * rozpis: row and is offered to every later sync. */
const dorostRow = {
  id: "8b91bc32-a0a8-4b8a-8987-c56a9d060916", import_key: "rozpis:KP dorostu:1:TJ Sokol Vracov B – TJ Sokol Husovice (dorost)",
  date: "2026-09-13", starts_at: "09:00:00", home_team: "TJ Sokol Vracov B", away_team: "TJ Sokol Husovice (dorost)",
};

Deno.test("the any-date rule reaches two months, never next season's match", () => {
  const at = (date: string, round: number) => [{
    siteId: 7001, date, startsAt: "10:00", round, home: "TJ Sokol Vracov B", away: "TJ Sokol Husovice (dorost)",
  }];
  assertEquals(pairLegacy(at("2026-11-12", 9), [dorostRow]).get(7001), dorostRow.id);
  assertEquals(pairLegacy(at("2026-11-13", 9), [dorostRow]).size, 0);
  assertEquals(pairLegacy(at("2026-07-14", 9), [dorostRow]).size, 0);
  // Next season's fixture of the same two teams, in another round.
  assertEquals(pairLegacy(at("2027-09-19", 3), [dorostRow]).size, 0);
});

Deno.test("two teams meeting both ways on one date pair as listed, not swapped", () => {
  const [ab, ba] = [derbyLegacy[0], { ...derbyLegacy[1], date: derbyLegacy[0].date }];
  const siteAB = { siteId: 1, date: ab.date, startsAt: "10:00", round: 20, home: ab.home_team, away: ab.away_team };
  const siteBA = { siteId: 2, date: ab.date, startsAt: "14:00", round: 21, home: ab.away_team, away: ab.home_team };
  assertEquals([...pairLegacy([siteAB, siteBA], [ab, ba])], [[1, ab.id], [2, ba.id]]);
  // Only one of the two on the site: it is the straight one, the other waits.
  assertEquals([...pairLegacy([siteAB], [ab, ba])], [[1, ab.id]]);
  // Only one of the two in the rozpis: the reversed site match is a new one.
  assertEquals([...pairLegacy([siteAB, siteBA], [ab])], [[1, ab.id]]);
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

Deno.test("PREPARATION an hour or more before the start is checked like SCHEDULED, then live", () => {
  // The site shows PREPARATION days ahead for some matches.
  const T = new Date("2026-10-10T08:00:00Z");
  const at = (h: number) => new Date(T.getTime() + h * 3600e3);
  const min = (d: Date, m: number) => new Date(d.getTime() + m * 60e3);
  assertEquals(nextCheckpoint("PREPARATION", T, at(-14 * 24)), at(-24));
  assertEquals(nextCheckpoint("PREPARATION", T, at(-2)), at(-1));
  assertEquals(nextCheckpoint("PREPARATION", T, at(-1)), min(at(-1), 15));
  assertEquals(nextCheckpoint("PREPARATION", T, at(-0.5)), min(at(-0.5), 15));
  assertEquals(nextCheckpoint("PREPARATION", T, at(1)), min(at(1), 15));
  assertEquals(nextCheckpoint("PREPARATION", T, at(11)), min(at(11), 15));
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
