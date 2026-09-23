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
