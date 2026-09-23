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
