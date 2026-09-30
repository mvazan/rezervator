import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { pragueEpoch } from "./cancel_token.ts";
import { parseMatch, resultPayload, type SiteMatch } from "./federation.ts";
import {
  jobOutcome, matchJobsFor, planClubs, planCompetition, planTeams,
  processFederationJobs, runCompetition, runDiscover, runLeagueMatch, SITE,
} from "./federation_jobs.ts";

const fixture = (name: string) =>
  Deno.readTextFileSync(new URL(`./fixtures/federation/${name}`, import.meta.url));

const match = (over: Partial<SiteMatch> & { id: number }): SiteMatch => ({
  slug: `jihomoravska-divize-2026-2027-kolo-1-m${over.id}`, date: "2026-10-10", time: "10:00",
  round: 1, status: "SCHEDULED", matchType: "TEAMS_OF_6", discipline: "T120", videoUrl: null,
  homeTeam: { id: 1, name: "TJ Sokol Brno IV", slug: "tj-sokol-brno-iv-muzi" },
  awayTeam: { id: 2, name: "KC Zlín B", slug: "kc-zlin-b-muzi" },
  competition: { slug: "jihomoravska-divize-2026-2027", name: "Jihomoravská divize" },
  totals: { home: null, away: null },
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
    // The site's team slugs, so the database can tell our teams apart the
    // way runMatch does, whatever the admin renamed them to.
    home_slug: "tj-sokol-brno-iv-muzi", away_slug: "kc-zlin-b-muzi",
  });
});

Deno.test("planCompetition keeps the ids of our matches it skipped for no time", () => {
  const { rows, keepIds, inactiveIds } = planCompetition({
    matches: [
      match({ id: 1 }),
      match({ id: 4, time: null }),
      match({ id: 7, time: null, homeTeam: { id: 3, name: "KK X", slug: "kk-x-muzi" } }),
    ],
    teams, legacy: [],
  });
  assertEquals(rows.map((r) => r.site_match_id), [1]);
  assertEquals(keepIds, [4]);
  assertEquals(inactiveIds, []); // an active team's time-less match is still polled
});

Deno.test("planCompetition keeps an inactive team's matches without writing them", () => {
  const { rows, keepIds, inactiveIds } = planCompetition({
    matches: [
      match({ id: 1 }),
      match({ id: 3, homeTeam: { id: 3, name: "KK X", slug: "kk-x-muzi" },
              awayTeam: { id: 4, name: "TJ Sokol Husovice", slug: "tj-sokol-husovice-muzi" } }),
      match({ id: 8, homeTeam: { id: 3, name: "KK X", slug: "kk-x-muzi" } }),
    ],
    teams, legacy: [],
  });
  assertEquals(rows.map((r) => r.site_match_id), [1]);
  assertEquals(keepIds, [3]);
  assertEquals(inactiveIds, [3]);
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
      date: "2026-10-10", starts_at: "10:00:00", home_team: "TJ Sokol Brno IV A",
      away_team: "KC Zlín B" }],
  });
  assertEquals(rows[0].legacy_id, "L1");
});

Deno.test("planCompetition hands the start time to the pairing", () => {
  const { rows } = planCompetition({
    matches: [match({ id: 1, round: 5, date: "2026-10-17", time: "17:00" })],
    teams,
    legacy: [{ id: "L1", import_key: "rozpis:JmD:3:TJ Sokol Brno IV A – KC Zlín",
      date: "2026-10-17", starts_at: "17:00:00", home_team: "TJ Sokol Brno IV A",
      away_team: "KC Zlín" }],
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
      match({ id: 7, status: "FORFEIT", date: "2026-09-20" }),
      match({ id: 8, status: "FORFEIT", date: "2026-09-20" }),
      match({ id: 9, status: "FINISHED", date: "2026-10-09" }),
      match({ id: 10, status: "PREPARATION", date: "2026-10-10", time: "09:00" }),
    ],
    statusById: new Map([
      [1, "scheduled"], [2, "finished"], [3, null], [4, null], [5, null],
      [7, null], [8, "forfeit"], [9, "in_progress"], [10, "scheduled"],
    ]),
    now,
  });
  assertEquals(jobs.map((j) => j.site_match_id).sort((a, b) => a - b), [1, 3, 4, 7, 9, 10]);
  for (const id of [7, 9, 10]) assertEquals(jobs.find((j) => j.site_match_id === id)!.run_at, now);
  assertEquals(jobs.find((j) => j.site_match_id === 1)!.run_at, now);
  assertEquals(jobs.find((j) => j.site_match_id === 4)!.run_at, new Date("2026-10-10T08:00:00Z"));
});

Deno.test("matchJobsFor: PREPARATION an hour or more before the start is armed like SCHEDULED", () => {
  const now = new Date("2026-10-10T06:00:00Z"); // 08:00 Prague
  const jobs = matchJobsFor({
    matches: [
      match({ id: 1, status: "PREPARATION", date: "2026-10-24", time: "10:00" }),
      match({ id: 2, status: "PREPARATION", date: "2026-10-11", time: "10:00" }),
      match({ id: 3, status: "PREPARATION", date: "2026-10-10", time: "10:00" }),
      match({ id: 4, status: "PREPARATION", date: "2026-10-10", time: "08:30" }),
    ],
    statusById: new Map([[1, "preparation"], [2, "preparation"], [3, null], [4, "scheduled"]]),
    now,
  });
  assertEquals(jobs.map((j) => [j.site_match_id, j.run_at]), [
    [2, new Date("2026-10-10T08:00:00Z")],
    [3, new Date("2026-10-10T07:00:00Z")],
    [4, now],
  ]);
});

Deno.test("matchJobsFor: a stored match without a venue is fetched now, once listed", () => {
  const now = new Date("2026-10-10T06:00:00Z");
  const jobs = matchJobsFor({
    matches: [
      match({ id: 1, status: "SCHEDULED", date: "2026-11-20" }),
      match({ id: 2, status: "FINISHED", date: "2026-09-20" }),
      match({ id: 3, status: "SCHEDULED", date: "2026-11-27" }),
      match({ id: 4, status: "SCHEDULED", date: "2026-12-04" }),
    ],
    statusById: new Map([[1, null], [2, "finished"], [3, null]]),
    venueless: new Set([1, 2, 4]),
    now,
  });
  assertEquals(jobs.map((j) => [j.site_match_id, j.run_at]), [[1, now], [2, now]]);
});

Deno.test("matchJobsFor: a stored match whose last fetch failed is fetched now, finished or not", () => {
  // Its job gave up (or was dropped), and a finished match has no checkpoint
  // left: without this nothing would run it again to clear its error.
  const now = new Date("2026-10-10T06:00:00Z");
  const jobs = matchJobsFor({
    matches: [
      match({ id: 1, status: "FINISHED", date: "2026-09-20" }),
      match({ id: 2, status: "FINISHED", date: "2026-09-20" }),
      match({ id: 3, status: "SCHEDULED", date: "2026-11-20" }),
      match({ id: 4, status: "FORFEIT", date: "2026-09-20" }),
    ],
    statusById: new Map([[1, "finished"], [2, "finished"], [3, null]]),
    failing: new Set([1, 3, 4]),
    now,
  });
  assertEquals(jobs.map((j) => [j.site_match_id, j.run_at]), [[1, now], [3, now]]);
});

Deno.test("planTeams: teams of venue clubs with their venue club, names reused", () => {
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
  });
  assertEquals(teamsOut, [
    { site_slug: "tj-sokol-brno-iv-muzi", site_team_id: 1, site_name: "TJ Sokol Brno IV",
      competition_slug: "jihomoravska-divize-2026-2027", competition_name: "Jihomoravská divize",
      name: "TJ Sokol Brno IV A", club_slug: "tj-sokol-brno-iv" },
    { site_slug: "tj-sokol-husovice-b-muzi", site_team_id: null, site_name: "TJ Sokol Husovice B",
      competition_slug: "jihomoravska-divize-2026-2027", competition_name: "Jihomoravská divize",
      name: "TJ Sokol Husovice B", club_slug: "tj-sokol-husovice" },
  ]);
});

Deno.test("planClubs: a renamed club by its slug, else one unlinked club by name, else none", () => {
  const venue = [
    { slug: "tj-sokol-brno-iv", name: "TJ Sokol Brno IV" },
    { slug: "tj-sokol-husovice", name: "TJ Sokol Husovice" },
    { slug: "ks-devitka-brno", name: "KS Devítka Brno" },
    { slug: "skk-veverky-brno", name: "SKK Veverky Brno" },
  ];
  const ours = [
    { id: "c1", name: "Sokol Brno IV", site_slug: null },
    // Renamed in the app after a discovery linked it: its slug still wins,
    // even over an unlinked club with the site's very name.
    { id: "c2", name: "Devítka", site_slug: "ks-devitka-brno" },
    { id: "c4", name: "KS Devítka Brno", site_slug: null },
    { id: "c3", name: "Veverky", site_slug: null },
  ];
  assertEquals(planClubs(venue, ours), [
    { slug: "tj-sokol-brno-iv", name: "TJ Sokol Brno IV", match_id: "c1" },
    { slug: "tj-sokol-husovice", name: "TJ Sokol Husovice", match_id: null },
    { slug: "ks-devitka-brno", name: "KS Devítka Brno", match_id: "c2" },
    { slug: "skk-veverky-brno", name: "SKK Veverky Brno", match_id: "c3" },
  ]);
  // A club linked to another venue club is never matched by name.
  assertEquals(
    planClubs([{ slug: "tj-sokol-brno-iv-b", name: "Sokol Brno IV" }],
      [{ id: "c1", name: "Sokol Brno IV", site_slug: "tj-sokol-brno-iv" }]),
    [{ slug: "tj-sokol-brno-iv-b", name: "Sokol Brno IV", match_id: null }],
  );
});

Deno.test("jobOutcome: rearm, stop, back off, give up", () => {
  const now = new Date("2026-10-10T06:00:00Z");
  const next = new Date("2026-10-10T07:00:00Z");
  assertEquals(jobOutcome({ next }, 2, now), { action: "rearm", run_at: next, attempts: 0 });
  assertEquals(jobOutcome({ next: null }, 0, now), { action: "delete" });
  assertEquals(jobOutcome({ error: "x" }, 2, now),
    { action: "rearm", run_at: new Date(now.getTime() + 4 * 60e3), attempts: 3 });
  assertEquals(jobOutcome({ error: "x" }, 5, now), { action: "delete" });
});

// ------------------------------------------------------- processFederationJobs

type FakeJob = {
  id: number; kind: string; attempts: number; run_at: string;
  payload: Record<string, unknown>;
};
type Call =
  | { kind: "update"; id: unknown; set: Record<string, unknown> }
  | { kind: "delete"; id: unknown }
  | { kind: "rpc"; name: string; args: Record<string, unknown> }
  | { kind: "read"; table: string; eqs: [string, unknown][] };

/** The tenant's teams as runMatch reads them: the home side of
 * match_finished.html (TJ Sokol Rudná A) is an active team of ours. */
const fixtureTeams = [{ site_slug: "tj-sokol-rudna-a-muzi", active: true }];

/** A minimal in-memory stand-in for the `notification_jobs` slice of the
 * Supabase query builder — just the chains processFederationJobs actually
 * issues: `select().eq().lte().order().limit()` (the due query),
 * `update().eq().eq().select()` (the optimistic-lock lease),
 * `update().eq()` (the outcome re-arm, no lock) and `delete().eq()`. Mutates
 * `jobs` in place so a test can assert on it directly after the run.
 * `onDue` gets the stored jobs a due query has just read — a stand-in for
 * another tick touching them before this one leases. Any other table's
 * read is logged as a `read` call; `teams` answers `teams`. */
function fakeJobsDb(
  jobs: FakeJob[],
  onRpc?: (name: string, args: Record<string, unknown>) => { data: unknown; error: unknown },
  leaseError?: { message: string },
  onDue?: (due: FakeJob[]) => void,
  teams: { site_slug: string; active: boolean }[] = fixtureTeams,
  // What a read of league_matches finds (the row a league job is about).
  leagueRows: unknown[] | undefined = [{ id: "lg" }],
) {
  const calls: Call[] = [];
  function chainFor(table: string) {
    const eqs: [string, unknown][] = [];
    let lte: [string, unknown] | undefined;
    let limit: number | undefined;
    let update: Record<string, unknown> | undefined;
    let isDelete = false;
    let isSelect = false;
    // deno-lint-ignore no-explicit-any
    const chain: any = {
      select() {
        isSelect = true;
        return chain;
      },
      eq(col: string, val: unknown) {
        eqs.push([col, val]);
        return chain;
      },
      lte(col: string, val: unknown) {
        lte = [col, val];
        return chain;
      },
      order() {
        return chain;
      },
      limit(n: number) {
        limit = n;
        return chain;
      },
      update(payload: Record<string, unknown>) {
        update = payload;
        return chain;
      },
      delete() {
        isDelete = true;
        return chain;
      },
      then(onFulfilled: (v: unknown) => unknown, onRejected: (e: unknown) => unknown) {
        return resolve().then(onFulfilled, onRejected);
      },
    };
    async function resolve() {
      if (table !== "notification_jobs") {
        calls.push({ kind: "read", table, eqs });
        const data = table === "teams"
          ? teams.map((t) => ({ ...t }))
          : table === "league_matches" && leagueRows
          ? leagueRows
          : [];
        return { data, error: null };
      }
      const idEq = eqs.find(([c]) => c === "id")?.[1];
      if (isDelete) {
        const at = jobs.findIndex((j) => j.id === idEq);
        if (at >= 0) jobs.splice(at, 1);
        calls.push({ kind: "delete", id: idEq });
        return { data: null, error: null };
      }
      if (update) {
        const job = jobs.find((j) => j.id === idEq);
        if (!job) return { data: isSelect ? [] : null, error: null };
        const runAtEq = eqs.find(([c]) => c === "run_at")?.[1];
        if (runAtEq !== undefined && leaseError) return { data: null, error: leaseError };
        if (runAtEq !== undefined && job.run_at !== runAtEq) {
          return { data: isSelect ? [] : null, error: null }; // lost the optimistic lock
        }
        Object.assign(job, update);
        calls.push({ kind: "update", id: idEq, set: update });
        return { data: isSelect ? [{ id: job.id }] : null, error: null };
      }
      const kindEq = eqs.find(([c]) => c === "kind")?.[1];
      let rows = jobs.filter((j) => j.kind === kindEq);
      if (lte) rows = rows.filter((j) => j.run_at <= (lte![1] as string));
      if (limit !== undefined) rows = rows.slice(0, limit);
      const due = rows.map((j) => ({ ...j }));
      onDue?.(rows);
      return { data: due, error: null };
    }
    return chain;
  }
  const db = {
    from(table: string) {
      return chainFor(table);
    },
    async rpc(name: string, args: Record<string, unknown>) {
      calls.push({ kind: "rpc", name, args });
      return onRpc ? onRpc(name, args) : { data: {}, error: null };
    },
  };
  return { db, calls };
}

Deno.test("processFederationJobs: a successful match job is re-armed — run_at/attempts only, payload untouched", async () => {
  const html = fixture("match_finished.html"); // FINISHED, 2026-09-16 17:30 Prague, id 4859
  const slug = "divize-as-2026-2027-kolo-1-tj-sokol-rudna-a-muzi-tj-sokol-vrsovice-a-muzi";
  const start = pragueEpoch("2026-09-16", "17:30") * 1000;
  const now = new Date(start + 3600e3); // 1h after kickoff — inside T+24h, so nextCheckpoint rearms
  const jobs: FakeJob[] = [{
    id: 1, kind: "federation_match", attempts: 0,
    run_at: new Date(now.getTime() - 60e3).toISOString(),
    payload: { tenant_id: "t1", site_match_id: 4859, slug, requested_at: "2026-09-16T10:00:00.000Z" },
  }];
  const { db, calls } = fakeJobsDb(jobs);
  const fetched: string[] = [];
  const get = async (path: string) => {
    fetched.push(path);
    return html;
  };

  await processFederationJobs(db, get, now);

  assertEquals(fetched, [`/detail-zapasu/${slug}`]);
  assertEquals(jobs[0].attempts, 0);
  assertEquals(jobs[0].run_at, new Date(start + 24 * 3600e3).toISOString());
  assertEquals(jobs[0].payload.requested_at, "2026-09-16T10:00:00.000Z"); // untouched
  const writes = calls.filter((c) => c.kind === "update" && c.id === 1) as
    { kind: "update"; id: unknown; set: Record<string, unknown> }[];
  assert(writes.length > 0);
  for (const w of writes) assertEquals(Object.keys(w.set).sort(), ["attempts", "run_at"]);
});

Deno.test("processFederationJobs: a match job whose teams of ours are all switched off is dropped unwritten", async () => {
  // A job armed before the admin switched the team off, or by refresh_match:
  // the page shows neither side is an active team of ours, so no result is
  // written and the job stops instead of polling the match to its end.
  const slug = "divize-as-2026-2027-kolo-1-tj-sokol-rudna-a-muzi-tj-sokol-vrsovice-a-muzi";
  const now = new Date(pragueEpoch("2026-09-16", "17:30") * 1000 + 3600e3);
  const jobs: FakeJob[] = [{
    id: 30, kind: "federation_match", attempts: 0,
    run_at: new Date(now.getTime() - 60e3).toISOString(),
    payload: { tenant_id: "t1", site_match_id: 4859, slug },
  }];
  const { db, calls } = fakeJobsDb(jobs, undefined, undefined, undefined, [
    { site_slug: "tj-sokol-rudna-a-muzi", active: false },
    { site_slug: "tj-sokol-brno-iv-muzi", active: true },
  ]);

  await processFederationJobs(db, async () => fixture("match_finished.html"), now);

  assertEquals(jobs.length, 0);
  assert(calls.some((c) => c.kind === "delete" && c.id === 30));
  assert(!calls.some((c) => c.kind === "rpc" && c.name === "apply_federation_result"));
  const read = calls.find((c) => c.kind === "read" && c.table === "teams") as
    { kind: "read"; table: string; eqs: [string, unknown][] } | undefined;
  assertEquals(read?.eqs, [["tenant_id", "t1"]]);
});

Deno.test("processFederationJobs: a match job runs when either side is an active team of ours", async () => {
  const slug = "divize-as-2026-2027-kolo-1-tj-sokol-rudna-a-muzi-tj-sokol-vrsovice-a-muzi";
  const start = pragueEpoch("2026-09-16", "17:30") * 1000;
  const now = new Date(start + 3600e3);
  const jobs: FakeJob[] = [{
    id: 31, kind: "federation_match", attempts: 0,
    run_at: new Date(now.getTime() - 60e3).toISOString(),
    payload: { tenant_id: "t1", site_match_id: 4859, slug },
  }];
  const { db, calls } = fakeJobsDb(jobs, undefined, undefined, undefined, [
    { site_slug: "tj-sokol-rudna-a-muzi", active: false },
    { site_slug: "tj-sokol-vrsovice-a-muzi", active: true },
  ]);

  await processFederationJobs(db, async () => fixture("match_finished.html"), now);

  assert(calls.some((c) => c.kind === "rpc" && c.name === "apply_federation_result"));
  assertEquals(jobs[0].run_at, new Date(start + 24 * 3600e3).toISOString());
});

Deno.test("processFederationJobs: a match job whose slot is gone is deleted, not re-armed", async () => {
  const slug = "divize-as-2026-2027-kolo-1-tj-sokol-rudna-a-muzi-tj-sokol-vrsovice-a-muzi";
  const now = new Date(pragueEpoch("2026-09-16", "17:30") * 1000 + 3600e3);
  const jobs: FakeJob[] = [{
    id: 9, kind: "federation_match", attempts: 0,
    run_at: new Date(now.getTime() - 60e3).toISOString(),
    payload: { tenant_id: "t1", site_match_id: 4859, slug },
  }];
  const { db, calls } = fakeJobsDb(jobs, (name) =>
    ({ data: name === "apply_federation_result" ? false : null, error: null }));

  await processFederationJobs(db, async () => fixture("match_finished.html"), now);

  assertEquals(jobs.length, 0);
  assert(calls.some((c) => c.kind === "delete" && c.id === 9));
  assert(!calls.some((c) =>
    c.kind === "rpc" && c.name === "record_federation_run" && c.args.p_error !== null
  ));
});

Deno.test("processFederationJobs: a match fetch that succeeds records one success under match:<site_match_id>", async () => {
  // The success removes the match's own error entry, which is what clears
  // its "Chyba:" on the admin card. With no entry to remove,
  // record_federation_run returns before any write (tenancy_rls.sql 13b), so
  // this one call per fetch costs no row update and no Realtime event.
  const slug = "divize-as-2026-2027-kolo-1-tj-sokol-rudna-a-muzi-tj-sokol-vrsovice-a-muzi";
  const now = new Date(pragueEpoch("2026-09-16", "17:30") * 1000 + 3600e3);
  const jobs: FakeJob[] = [{
    id: 10, kind: "federation_match", attempts: 2,
    run_at: new Date(now.getTime() - 60e3).toISOString(),
    payload: { tenant_id: "t1", site_match_id: 4859, slug },
  }];
  const { db, calls } = fakeJobsDb(jobs);

  await processFederationJobs(db, async () => fixture("match_finished.html"), now);

  const recorded = calls.filter((c) => c.kind === "rpc" && c.name === "record_federation_run") as
    { kind: "rpc"; name: string; args: Record<string, unknown> }[];
  assertEquals(recorded.map((c) => c.args), [
    { p_tenant: "t1", p_key: "match:4859", p_report: null, p_error: null },
  ]);
  assertEquals(jobs[0].attempts, 0);
});

Deno.test("processFederationJobs: a match or venue success removes only its own key, a failure names the match", async () => {
  // One tick: match 4859 and the venue fetch work, match 4860 fails. Each
  // records under its own key, so neither success can clear 4860's error.
  const ok = "divize-as-2026-2027-kolo-1-tj-sokol-rudna-a-muzi-tj-sokol-vrsovice-a-muzi";
  const broken = "divize-as-2026-2027-kolo-2-tj-sokol-vrsovice-a-muzi-tj-sokol-rudna-a-muzi";
  const now = new Date(pragueEpoch("2026-09-16", "17:30") * 1000 + 3600e3);
  const due = new Date(now.getTime() - 60e3).toISOString();
  const jobs: FakeJob[] = [
    { id: 20, kind: "federation_match", attempts: 0, run_at: due,
      payload: { tenant_id: "t1", site_match_id: 4859, slug: ok } },
    { id: 21, kind: "federation_match", attempts: 0, run_at: due,
      payload: { tenant_id: "t1", site_match_id: 4860, slug: broken } },
    { id: 22, kind: "federation_venue", attempts: 0, run_at: due,
      payload: { tenant_id: "t1", slug: "tj-sokol-brno-iv" } },
  ];
  const { db, calls } = fakeJobsDb(jobs);
  const get = async (path: string) => {
    if (path === `/detail-zapasu/${broken}`) throw new Error("HTTP 503");
    return path.startsWith("/detail-kuzelny/") ? fixture("venue.html") : fixture("match_finished.html");
  };
  const original = console.error;
  console.error = () => {};
  try {
    await processFederationJobs(db, get, now);
  } finally {
    console.error = original;
  }

  const recorded = (calls.filter((c) => c.kind === "rpc" && c.name === "record_federation_run") as
    { kind: "rpc"; name: string; args: Record<string, unknown> }[])
    .map((c) => c.args)
    .sort((a, b) => String(a.p_key).localeCompare(String(b.p_key)));
  assertEquals(recorded, [
    { p_tenant: "t1", p_key: "match:4859", p_report: null, p_error: null },
    { p_tenant: "t1", p_key: "match:4860", p_report: null,
      p_error: `federation_match ${broken}: HTTP 503` },
    { p_tenant: "t1", p_key: "venue:tj-sokol-brno-iv", p_report: null, p_error: null },
  ]);
});

Deno.test("processFederationJobs: a failed success record leaves a match job's re-arm alone", async () => {
  const slug = "divize-as-2026-2027-kolo-1-tj-sokol-rudna-a-muzi-tj-sokol-vrsovice-a-muzi";
  const start = pragueEpoch("2026-09-16", "17:30") * 1000;
  const now = new Date(start + 3600e3);
  const jobs: FakeJob[] = [{
    id: 11, kind: "federation_match", attempts: 0,
    run_at: new Date(now.getTime() - 60e3).toISOString(),
    payload: { tenant_id: "t1", site_match_id: 4859, slug },
  }];
  const { db } = fakeJobsDb(jobs, (name) =>
    name === "record_federation_run"
      ? { data: null, error: { message: "db down" } }
      : { data: {}, error: null });
  const original = console.error;
  console.error = () => {};
  try {
    await processFederationJobs(db, async () => fixture("match_finished.html"), now);
  } finally {
    console.error = original;
  }

  assertEquals(jobs[0].attempts, 0);
  assertEquals(jobs[0].run_at, new Date(start + 24 * 3600e3).toISOString());
});

Deno.test("processFederationJobs: a job past MAX_ATTEMPTS is deleted without fetching", async () => {
  const jobs: FakeJob[] = [{
    id: 2, kind: "federation_match", attempts: 6, // > MAX_ATTEMPTS (5)
    run_at: new Date(Date.now() - 60e3).toISOString(),
    payload: { tenant_id: "t1", site_match_id: 1, slug: "x" },
  }];
  const { db, calls } = fakeJobsDb(jobs);
  let fetched = false;
  const get = async () => {
    fetched = true;
    return "";
  };

  await processFederationJobs(db, get, new Date());

  assert(!fetched);
  assertEquals(jobs.length, 0);
  const recorded = calls.find((c) => c.kind === "rpc" && c.name === "record_federation_run") as
    { kind: "rpc"; name: string; args: Record<string, unknown> } | undefined;
  assertEquals(recorded?.args, {
    p_tenant: "t1", p_key: "match:1", p_report: null,
    p_error: "federation_match x: dropped after 6 attempts",
  });
});

Deno.test("processFederationJobs: a failing lease is logged and the job left alone", async () => {
  const jobs: FakeJob[] = [{
    id: 5, kind: "federation_match", attempts: 1,
    run_at: new Date(Date.now() - 60e3).toISOString(),
    payload: { tenant_id: "t1", site_match_id: 1, slug: "x" },
  }];
  const before = JSON.parse(JSON.stringify(jobs));
  const { db } = fakeJobsDb(jobs, undefined, { message: "lease boom" });
  let fetched = false;
  const get = async () => {
    fetched = true;
    return "";
  };
  const errors: unknown[][] = [];
  const original = console.error;
  console.error = (...args: unknown[]) => errors.push(args);
  try {
    await processFederationJobs(db, get, new Date());
  } finally {
    console.error = original;
  }

  assert(!fetched);
  assertEquals(jobs, before);
  assert(errors.some((e) => JSON.stringify(e).includes("lease boom")));
});

Deno.test("processFederationJobs: a job whose run_at moved since the due query is not run", async () => {
  const now = new Date("2026-10-10T06:00:00Z");
  const jobs: FakeJob[] = [{
    id: 1, kind: "federation_match", attempts: 0,
    run_at: new Date(now.getTime() - 60e3).toISOString(),
    payload: { tenant_id: "t1", site_match_id: 1, slug: "x" },
  }];
  const { db, calls } = fakeJobsDb(jobs, undefined, undefined, (due) => {
    for (const job of due) {
      job.run_at = new Date(now.getTime() + 10 * 60e3).toISOString();
      job.attempts = 1;
    }
  });
  let fetched = false;
  const get = async () => {
    fetched = true;
    return "";
  };

  await processFederationJobs(db, get, now);

  assert(!fetched);
  assertEquals(jobs[0].attempts, 1);
  assertEquals(jobs[0].run_at, new Date(now.getTime() + 10 * 60e3).toISOString());
  assert(!calls.some((c) => (c.kind === "update" || c.kind === "delete") && c.id === 1));
});

Deno.test("processFederationJobs: a tick runs at most 10 match jobs, then at most 3 venue jobs", async () => {
  const now = new Date("2026-10-10T06:00:00Z");
  const due = new Date(now.getTime() - 60e3).toISOString();
  const jobs: FakeJob[] = [
    ...Array.from({ length: 4 }, (_, i): FakeJob => ({
      id: 100 + i, kind: "federation_venue", attempts: 0, run_at: due,
      payload: { tenant_id: "t1", slug: `v${i}` },
    })),
    ...Array.from({ length: 12 }, (_, i): FakeJob => ({
      id: i + 1, kind: "federation_match", attempts: 0, run_at: due,
      payload: { tenant_id: "t1", site_match_id: i + 1, slug: `m${i}` },
    })),
  ];
  const { db } = fakeJobsDb(jobs);
  const fetched: string[] = [];
  const get = async (path: string) => {
    fetched.push(path);
    throw new Error("site down");
  };
  const original = console.error;
  console.error = () => {};
  try {
    await processFederationJobs(db, get, now);
  } finally {
    console.error = original;
  }

  assertEquals(fetched.length, 13);
  assert(fetched.slice(0, 10).every((p) => p.startsWith("/detail-zapasu/")));
  assert(fetched.slice(10).every((p) => p.startsWith("/detail-kuzelny/")));
  assertEquals(jobs.filter((j) => j.kind === "federation_match" && j.attempts === 0).length, 2);
  assertEquals(jobs.filter((j) => j.kind === "federation_venue" && j.attempts === 0).length, 1);
});

Deno.test("processFederationJobs: a failing competition job records its error under its report key", async () => {
  const now = new Date("2026-10-10T06:00:00Z");
  const jobs: FakeJob[] = [{
    id: 6, kind: "federation_competition", attempts: 0,
    run_at: new Date(now.getTime() - 60e3).toISOString(),
    payload: { tenant_id: "t1", competition_slug: "kp1-sever-2026-2027" },
  }];
  const { db, calls } = fakeJobsDb(jobs);
  const get = async () => {
    throw new Error("site down");
  };

  await processFederationJobs(db, get, now);

  const recorded = calls.find((c) => c.kind === "rpc" && c.name === "record_federation_run") as
    { kind: "rpc"; name: string; args: Record<string, unknown> } | undefined;
  assertEquals(recorded?.args.p_key, "competition:kp1-sever-2026-2027");
  assertEquals(recorded?.args.p_error, "federation_competition: site down");
});

Deno.test("processFederationJobs: a failing job backs off from its attempts and records the error", async () => {
  const now = new Date("2026-10-10T06:00:00Z");
  const jobs: FakeJob[] = [{
    id: 3, kind: "federation_match", attempts: 2,
    run_at: new Date(now.getTime() - 60e3).toISOString(),
    payload: { tenant_id: "t1", site_match_id: 1, slug: "boom" },
  }];
  const { db, calls } = fakeJobsDb(jobs);
  const get = async () => {
    throw new Error("network down");
  };

  await processFederationJobs(db, get, now);

  assertEquals(jobs[0].attempts, 3);
  assertEquals(jobs[0].run_at, new Date(now.getTime() + 4 * 60e3).toISOString());
  const recorded = calls.find((c) => c.kind === "rpc" && c.name === "record_federation_run") as
    { kind: "rpc"; name: string; args: Record<string, unknown> } | undefined;
  assert(recorded);
  assertEquals(recorded!.args.p_key, "match:1");
  assertEquals(recorded!.args.p_error, "federation_match boom: network down");
});

Deno.test("processFederationJobs: a venue job fetches the venue page, upserts it, records a success and is deleted", async () => {
  const now = new Date("2026-10-10T06:00:00Z");
  const jobs: FakeJob[] = [{
    id: 7, kind: "federation_venue", attempts: 0,
    run_at: new Date(now.getTime() - 60e3).toISOString(),
    payload: { tenant_id: "t1", slug: "tj-sokol-brno-iv" },
  }];
  const { db, calls } = fakeJobsDb(jobs);
  const fetched: string[] = [];
  const get = async (path: string) => {
    fetched.push(path);
    return fixture("venue.html");
  };

  await processFederationJobs(db, get, now);

  assertEquals(fetched, ["/detail-kuzelny/tj-sokol-brno-iv"]);
  const upsert = calls.find((c) => c.kind === "rpc" && c.name === "upsert_federation_venue") as
    { kind: "rpc"; name: string; args: Record<string, unknown> } | undefined;
  assertEquals(upsert?.args.p_tenant, "t1");
  const venue = upsert?.args.p_venue as Record<string, unknown>;
  assertEquals(venue.slug, "tj-sokol-brno-iv");
  assertEquals(venue.name, "TJ Sokol Brno IV");
  assertEquals(venue.phone, "736435492");
  assert(Array.isArray(venue.sections) && Array.isArray(venue.clubs));
  assertEquals(jobs.length, 0);
  const recorded = calls.filter((c) => c.kind === "rpc" && c.name === "record_federation_run") as
    { kind: "rpc"; name: string; args: Record<string, unknown> }[];
  assertEquals(recorded.map((c) => c.args), [
    { p_tenant: "t1", p_key: "venue:tj-sokol-brno-iv", p_report: null, p_error: null },
  ]);
});

Deno.test("processFederationJobs: a failing venue job records its error under venue:<slug>", async () => {
  const now = new Date("2026-10-10T06:00:00Z");
  const jobs: FakeJob[] = [{
    id: 8, kind: "federation_venue", attempts: 0,
    run_at: new Date(now.getTime() - 60e3).toISOString(),
    payload: { tenant_id: "t1", slug: "jinde" },
  }];
  const { db, calls } = fakeJobsDb(jobs);
  const get = async () => {
    throw new Error("site down");
  };

  await processFederationJobs(db, get, now);

  const recorded = calls.find((c) => c.kind === "rpc" && c.name === "record_federation_run") as
    { kind: "rpc"; name: string; args: Record<string, unknown> } | undefined;
  assertEquals(recorded?.args.p_key, "venue:jinde");
  assertEquals(recorded?.args.p_error, "federation_venue: site down");
  assertEquals(jobs[0].attempts, 1);
});

Deno.test("processFederationJobs: a zero budget leases nothing", async () => {
  const jobs: FakeJob[] = [{
    id: 4, kind: "federation_match", attempts: 0,
    run_at: new Date(Date.now() - 60e3).toISOString(),
    payload: { tenant_id: "t1", site_match_id: 1, slug: "x" },
  }];
  const before = JSON.parse(JSON.stringify(jobs));
  const { db, calls } = fakeJobsDb(jobs);
  let fetched = false;
  const get = async () => {
    fetched = true;
    return "";
  };

  await processFederationJobs(db, get, new Date(), 0);

  assert(!fetched);
  assertEquals(jobs, before);
  assertEquals(calls.length, 0);
});

// ------------------------------------------------------------- runCompetition

Deno.test("runCompetition: throws when the site ignores ?round= and re-serves the current round", async () => {
  const html = fixture("competition_round_finished.html"); // currentRound 1, roundIds.length >= 20
  // deno-lint-ignore no-explicit-any
  const chain: any = {
    select() {
      return chain;
    },
    eq() {
      return chain;
    },
    like() {
      return chain;
    },
    then(onFulfilled: (v: unknown) => unknown) {
      return Promise.resolve({ data: [], error: null }).then(onFulfilled);
    },
  };
  const db = {
    from() {
      return chain;
    },
    async rpc() {
      return { data: {}, error: null };
    },
  };
  const get = async (_path: string) => html; // always the round-1 page, whatever ?round= asks for

  await assertRejects(
    () => runCompetition(db, get, "t1", "jihomoravska-divize-2026-2027", new Date()),
    Error,
    "round",
  );
});

/** A competition round page as the site renders it (RSC flight chunk). */
function competitionPage(
  matches: SiteMatch[], { roundIds = [1], current = 1 }: { roundIds?: number[]; current?: number } = {},
): string {
  const data = {
    data: {
      title: "Jihomoravská divize", rounds: roundIds.map((id) => ({ id: String(id), name: `${id}. kolo` })),
      currentRound: {
        id: String(current), matches: matches.map((m) => ({ ...m, time: m.time ?? "$undefined" })),
      },
    },
  };
  return `<script>self.__next_f.push([1,${JSON.stringify(`5:${JSON.stringify(data)}\n`)}])</script>`;
}

type Legacy = {
  id: string; import_key: string; date: string; starts_at: string; home_team: string; away_team: string;
};

/** The reads and RPCs runCompetition issues. apply_federation_matches
 * "rekeys" the paired legacy rows, so the read after it sees them gone.
 * `lastReport`: the tenant's federation_sync.last_report (no row if absent). */
function fakeCompetitionDb(state: {
  teams: { site_slug: string; name: string; active: boolean }[];
  legacy: Legacy[];
  stored: {
    site_match_id: number; venue_slug: string | null; match_results: { status: string } | null;
  }[];
  lastReport?: Record<string, unknown>;
}) {
  const rpcs: { name: string; args: Record<string, unknown> }[] = [];
  const selects: string[] = [];
  const db = {
    from(table: string) {
      let cols = "";
      let like: [string, string] | undefined;
      // deno-lint-ignore no-explicit-any
      const chain: any = {
        select(c: string) {
          cols = c;
          selects.push(`${table}: ${c}`);
          return chain;
        },
        eq() {
          return chain;
        },
        like(col: string, pattern: string) {
          like = [col, pattern];
          return chain;
        },
        maybeSingle() {
          return chain;
        },
        then(onFulfilled: (v: unknown) => unknown) {
          let data: unknown = [];
          if (table === "teams") data = state.teams;
          else if (table === "federation_sync") {
            data = state.lastReport ? { last_report: state.lastReport } : null;
          }
          else if (like?.[0] === "import_key") data = state.legacy.map((l) => ({ ...l }));
          else if (like?.[0] === "site_slug") data = state.stored;
          void cols;
          return Promise.resolve({ data, error: null }).then(onFulfilled);
        },
      };
      return chain;
    },
    async rpc(name: string, args: Record<string, unknown>) {
      rpcs.push({ name, args });
      if (name === "apply_federation_matches") {
        const paired = new Set((args.p_matches as { legacy_id: string | null }[])
          .map((r) => r.legacy_id).filter((id) => id));
        state.legacy = state.legacy.filter((l) => !paired.has(l.id));
        return { data: { inserted: 0, updated: 0, rekeyed: paired.size, deleted: 0 }, error: null };
      }
      return { data: null, error: null };
    },
  };
  return { db, rpcs, selects };
}

const ourTeam = { site_slug: "tj-sokol-brno-iv-muzi", name: "TJ Sokol Brno IV A", active: true };
const legacyRow = (id: string, date: string, home: string, away: string): Legacy => ({
  id, import_key: `rozpis:JmD:1:${home} – ${away}`, date, starts_at: "17:00:00",
  home_team: home, away_team: away,
});

Deno.test("runCompetition: keeps time-less ids, fetches venue-less matches, reports unpaired legacy rows", async () => {
  const slug = "jihomoravska-divize-2026-2027";
  const page = competitionPage([
    match({ id: 1, date: "2026-10-10", time: "10:00" }),
    match({ id: 2, date: "2026-10-17", time: null }),
    match({ id: 3, date: "2026-11-07", time: "10:00",
      homeTeam: { id: 9, name: "KK Y", slug: "kk-y-muzi" },
      awayTeam: { id: 1, name: "TJ Sokol Brno IV", slug: "tj-sokol-brno-iv-muzi" } }),
  ]);
  const { db, rpcs, selects } = fakeCompetitionDb({
    teams: [ourTeam],
    legacy: [
      { ...legacyRow("L1", "2026-10-10", "TJ Sokol Brno IV A", "KC Zlín B"), starts_at: "10:00:00" },
      legacyRow("L2", "2026-10-24", "TJ Sokol Brno IV A", "KK Starý"),
      legacyRow("L3", "2026-10-20", "KK Cizí", "KK Jiný"),
      legacyRow("L4", "2027-03-01", "TJ Sokol Brno IV A", "KK Z"),
    ],
    stored: [
      { site_match_id: 1, venue_slug: null, match_results: null },
      { site_match_id: 3, venue_slug: "tj-sokol-brno-iv", match_results: null },
    ],
  });
  const now = new Date("2026-10-01T06:00:00Z");

  const report = await runCompetition(db, async () => page, "t1", slug, now);

  const apply = rpcs.find((r) => r.name === "apply_federation_matches")!;
  assertEquals(apply.args.p_keep_ids, [2]);
  assertEquals((apply.args.p_matches as { legacy_id: string | null }[]).map((r) => r.legacy_id),
    ["L1", null]);
  assert(selects.some((s) => s.includes("import_key") && s.includes("starts_at")));
  const enqueued = rpcs.filter((r) => r.name === "enqueue_federation_match");
  assertEquals(enqueued.map((r) => [r.args.p_site_match_id, r.args.p_run_at]),
    [[1, now.toISOString()]]);
  assertEquals(report.legacy_unpaired, [{ date: "2026-10-24", title: "TJ Sokol Brno IV A – KK Starý" }]);
});

Deno.test("runCompetition: pages through every round once and sends all rounds' matches", async () => {
  const roundIds = [1, 2, 3];
  const fetched: string[] = [];
  const get = async (path: string) => {
    fetched.push(path);
    const round = Number(/\?round=(\d+)$/.exec(path)?.[1] ?? 2);
    return competitionPage([match({ id: round, round, date: `2026-10-${10 + round}` })],
      { roundIds, current: round });
  };
  const { db, rpcs } = fakeCompetitionDb({ teams: [ourTeam], legacy: [], stored: [] });

  await runCompetition(db, get, "t1", "jihomoravska-divize-2026-2027", new Date("2026-10-01T06:00:00Z"));

  assertEquals(fetched, [1, 2, 3].map((r) => `/detail-souteze/jihomoravska-divize-2026-2027?round=${r}`));
  const apply = rpcs.find((r) => r.name === "apply_federation_matches")!;
  assertEquals((apply.args.p_matches as { site_match_id: number }[]).map((r) => r.site_match_id), [1, 2, 3]);
});

Deno.test("runCompetition: an inactive team's listed matches go to p_keep_ids, not p_matches", async () => {
  const page = competitionPage([
    match({ id: 1, date: "2026-10-10", time: "10:00" }),
    match({ id: 5, date: "2026-10-17", time: "10:00",
      homeTeam: { id: 4, name: "TJ Sokol Husovice", slug: "tj-sokol-husovice-muzi" },
      awayTeam: { id: 9, name: "KK Y", slug: "kk-y-muzi" } }),
  ]);
  const { db, rpcs } = fakeCompetitionDb({
    teams: [ourTeam, { site_slug: "tj-sokol-husovice-muzi", name: "TJ Sokol Husovice", active: false }],
    legacy: [],
    stored: [],
  });

  await runCompetition(db, async () => page, "t1", "jihomoravska-divize-2026-2027",
    new Date("2026-10-01T06:00:00Z"));

  const apply = rpcs.find((r) => r.name === "apply_federation_matches")!;
  assertEquals((apply.args.p_matches as { site_match_id: number }[]).map((r) => r.site_match_id), [1]);
  assertEquals(apply.args.p_keep_ids, [5]);
});

Deno.test("runCompetition: arms no match job for a stored match of an inactive team alone", async () => {
  // Thursday night; Saturday's matches are within 48 h. The inactive team's
  // match stays stored (p_keep_ids) but is not polled.
  const page = competitionPage([
    match({ id: 1, date: "2026-10-10", time: "10:00" }),
    match({ id: 5, date: "2026-10-10", time: "14:00",
      homeTeam: { id: 4, name: "TJ Sokol Husovice", slug: "tj-sokol-husovice-muzi" },
      awayTeam: { id: 9, name: "KK Y", slug: "kk-y-muzi" } }),
    match({ id: 6, date: "2026-10-10", time: "17:00",
      homeTeam: { id: 4, name: "TJ Sokol Husovice", slug: "tj-sokol-husovice-muzi" },
      awayTeam: { id: 1, name: "TJ Sokol Brno IV", slug: "tj-sokol-brno-iv-muzi" } }),
  ]);
  const { db, rpcs } = fakeCompetitionDb({
    teams: [ourTeam, { site_slug: "tj-sokol-husovice-muzi", name: "TJ Sokol Husovice", active: false }],
    legacy: [],
    stored: [1, 5, 6].map((id) => ({ site_match_id: id, venue_slug: "tj-sokol-brno-iv", match_results: null })),
  });

  const report = await runCompetition(db, async () => page, "t1", "jihomoravska-divize-2026-2027",
    new Date("2026-10-08T20:00:00Z"));

  const apply = rpcs.find((r) => r.name === "apply_federation_matches")!;
  assertEquals(apply.args.p_keep_ids, [5]);
  const enqueued = rpcs.filter((r) => r.name === "enqueue_federation_match");
  assertEquals(enqueued.map((r) => r.args.p_site_match_id), [1, 6]);
  assertEquals(report.match_jobs, 2);
});

Deno.test("runCompetition: re-arms now every stored match whose match:<id> key holds an error", async () => {
  // Both matches are finished and stored so: only the failing one, whose
  // job gave up at its T+24 h checkpoint, is fetched again — the nightly
  // pass and „Synchronizovat teď“ are its daily retry.
  const page = competitionPage([
    match({ id: 1, status: "FINISHED", date: "2026-09-20", time: "10:00" }),
    match({ id: 2, status: "FINISHED", date: "2026-09-27", time: "10:00" }),
  ]);
  const { db, rpcs, selects } = fakeCompetitionDb({
    teams: [ourTeam],
    legacy: [],
    stored: [1, 2].map((id) => ({
      site_match_id: id, venue_slug: "tj-sokol-brno-iv", match_results: { status: "finished" },
    })),
    lastReport: {
      "match:1": { error: "federation_match x: HTTP 503", at: "2026-09-21T08:31:00Z" },
      "match:77": { error: "federation_match y: HTTP 503", at: "2026-09-21T08:31:00Z" },
      "venue:tj-sokol-brno-iv": { error: "federation_venue: HTTP 404", at: "2026-09-21T08:31:00Z" },
      "competition:jihomoravska-divize-2026-2027": { at: "2026-09-30T01:00:00Z", inserted: 0 },
    },
  });
  const now = new Date("2026-10-01T01:00:00Z");

  const report = await runCompetition(db, async () => page, "t1", "jihomoravska-divize-2026-2027", now);

  assert(selects.includes("federation_sync: last_report"));
  const enqueued = rpcs.filter((r) => r.name === "enqueue_federation_match");
  assertEquals(enqueued.map((r) => [r.args.p_site_match_id, r.args.p_run_at]),
    [[1, now.toISOString()]]);
  assertEquals(report.match_jobs, 1);
});

Deno.test("runCompetition: at most 20 unpaired legacy rows, in date order", async () => {
  const page = competitionPage([
    match({ id: 1, date: "2026-09-01", time: "10:00" }),
    match({ id: 2, date: "2026-12-31", time: "10:00" }),
  ]);
  const legacy = Array.from({ length: 25 }, (_, i) =>
    legacyRow(`L${i}`, `2026-10-${String(30 - i).padStart(2, "0")}`, "TJ Sokol Brno IV A", `KK ${i}`));
  const { db } = fakeCompetitionDb({ teams: [ourTeam], legacy, stored: [] });

  const report = await runCompetition(db, async () => page, "t1", "x", new Date("2026-08-01T00:00:00Z"));

  const out = report.legacy_unpaired as { date: string }[];
  assertEquals(out.length, 20);
  assertEquals(out[0].date, "2026-10-06");
  assertEquals(out.map((o) => o.date), [...out.map((o) => o.date)].sort());
});

// ---------------------------------------------------------------- runDiscover

/** The reads and the RPC runDiscover issues. `clubs`: the alley's clubs;
 * `result`: what apply_federation_discovery answers. */
function fakeDiscoverDb(
  sync: { venue_slug: string | null } | null,
  clubs: { id: string; name: string; site_slug: string | null }[] =
    [{ id: "c1", name: "Sokol Brno IV", site_slug: null }],
  result: unknown = {
    created: 1, teams_created: ["TJ Sokol Brno IV A"], clubs_linked: ["Sokol Brno IV"],
    clubs_created: ["TJ Sokol Husovice", "KS Devítka Brno", "SKK Veverky Brno"],
  },
) {
  const rpcs: { name: string; args: Record<string, unknown> }[] = [];
  const db = {
    from(table: string) {
      // deno-lint-ignore no-explicit-any
      const chain: any = {
        select() {
          return chain;
        },
        eq() {
          return chain;
        },
        not() {
          return chain;
        },
        maybeSingle() {
          return Promise.resolve({ data: table === "federation_sync" ? sync : null, error: null });
        },
        then(onFulfilled: (v: unknown) => unknown) {
          const data = table === "clubs"
            ? clubs
            : table === "priority_slots"
            ? [{ home_team: "TJ Sokol Brno IV A", away_team: "KK Blansko" }]
            : [];
          return Promise.resolve({ data, error: null }).then(onFulfilled);
        },
      };
      return chain;
    },
    async rpc(name: string, args: Record<string, unknown>) {
      rpcs.push({ name, args });
      return { data: result, error: null };
    },
  };
  return { db, rpcs };
}

/** A season's matches sitemap: one match of a venue club, two without. */
const matchesSitemap = `<?xml version="1.0" encoding="UTF-8"?><urlset>${
  [
    "jihomoravska-divize-2026-2027-kolo-1-tj-sokol-brno-iv-muzi-sk-kuzelky-dubnany-muzi",
    "jihomoravska-divize-2026-2027-kolo-1-kc-zlin-b-muzi-kk-moravska-slavia-brno-c-muzi",
    "divize-as-2026-2027-kolo-1-tj-sokol-rudna-a-muzi-tj-sokol-vrsovice-a-muzi",
  ].map((slug) => `<url><loc>${SITE}/detail-zapasu/${slug}</loc></url>`).join("")
}</urlset>`;

function discoverSite(pages: Record<string, string> = {}) {
  const site: Record<string, string> = {
    "/detail-kuzelny/tj-sokol-brno-iv": fixture("venue.html"),
    // An older season listed first: discovery must take the newest.
    "/sitemap.xml": fixture("sitemap_index.xml").replace("<sitemap>",
      `<sitemap><loc>${SITE}/sitemap/matches-19.xml</loc></sitemap><sitemap>`),
    "/sitemap/matches-20.xml": matchesSitemap,
    "/detail-souteze/jihomoravska-divize-2026-2027": fixture("competition_round_finished.html"),
    ...pages,
  };
  const fetched: string[] = [];
  const get = async (path: string) => {
    fetched.push(path);
    if (!(path in site)) throw new Error(`unexpected GET ${path}`);
    return site[path];
  };
  return { get, fetched };
}

Deno.test("runDiscover: venue clubs → season sitemap → competitions → teams", async () => {
  const { db, rpcs } = fakeDiscoverDb({ venue_slug: "tj-sokol-brno-iv" });
  const { get, fetched } = discoverSite();

  const report = await runDiscover(db, get, "t1");

  assertEquals(fetched, [
    "/detail-kuzelny/tj-sokol-brno-iv", "/sitemap.xml", "/sitemap/matches-20.xml",
    "/detail-souteze/jihomoravska-divize-2026-2027",
  ]);
  assertEquals(rpcs.map((r) => r.name), ["apply_federation_discovery"]);
  assertEquals(rpcs[0].args, {
    p_tenant: "t1",
    p_clubs: [
      { slug: "tj-sokol-brno-iv", name: "TJ Sokol Brno IV", match_id: "c1" },
      { slug: "tj-sokol-husovice", name: "TJ Sokol Husovice", match_id: null },
      { slug: "ks-devitka-brno", name: "KS Devítka Brno", match_id: null },
      { slug: "skk-veverky-brno", name: "SKK Veverky Brno", match_id: null },
    ],
    p_teams: [{
      site_slug: "tj-sokol-brno-iv-muzi", site_team_id: 243, site_name: "TJ Sokol Brno IV",
      competition_slug: "jihomoravska-divize-2026-2027", competition_name: "Jihomoravská divize",
      name: "TJ Sokol Brno IV A", club_slug: "tj-sokol-brno-iv",
    }],
  });
  assertEquals(report, {
    teams: 1, competitions: 1, created: 1, teams_created: ["TJ Sokol Brno IV A"],
    clubs_linked: ["Sokol Brno IV"],
    clubs_created: ["TJ Sokol Husovice", "KS Devítka Brno", "SKK Veverky Brno"],
  });
});

Deno.test("runDiscover: the report names the teams the database created, none when it names none", async () => {
  const run = (result: unknown) =>
    runDiscover(fakeDiscoverDb({ venue_slug: "tj-sokol-brno-iv" }, undefined, result).db,
      discoverSite().get, "t1");

  const again = await run({
    created: 0, teams_created: [], clubs_created: [], clubs_linked: ["Sokol Brno IV"],
  });
  assertEquals(again.created, 0);
  assertEquals(again.teams_created, []);

  // An apply_federation_discovery from before teams_created: the report
  // still carries the key, empty — the app reads a missing one the same.
  const older = await run({ created: 1, clubs_created: [], clubs_linked: ["Sokol Brno IV"] });
  assertEquals(older, {
    teams: 1, competitions: 1, created: 1, teams_created: [], clubs_created: [],
    clubs_linked: ["Sokol Brno IV"],
  });
});

Deno.test("runDiscover: a renamed club by its slug, a club by its name, a missing one to create", async () => {
  const prebor = "krajsky-prebor-jmk-2-tridy-sever-a-2026-2027";
  const sitemap = matchesSitemap.replace("</urlset>",
    `<url><loc>${SITE}/detail-zapasu/${prebor}-kolo-1-ks-devitka-brno-b-muzi-kk-slovan-rosice-d-muzi</loc></url></urlset>`);
  const ours = [
    { id: "c1", name: "Sokol Brno IV", site_slug: null },
    { id: "c2", name: "Devítka", site_slug: "ks-devitka-brno" },
    { id: "c3", name: "Veverky", site_slug: null },
  ];
  const { db, rpcs } = fakeDiscoverDb({ venue_slug: "tj-sokol-brno-iv" }, ours, {
    created: 2, teams_created: ["KS Devítka Brno B", "TJ Sokol Husovice E"],
    clubs_created: ["TJ Sokol Husovice"],
    clubs_linked: ["Sokol Brno IV", "Devítka", "Veverky"],
  });
  const { get } = discoverSite({
    "/sitemap/matches-20.xml": sitemap,
    [`/detail-souteze/${prebor}`]: fixture("competition_current_teams_of_4.html"),
  });

  const report = await runDiscover(db, get, "t1");

  assertEquals(rpcs.map((r) => r.name), ["apply_federation_discovery"]);
  assertEquals(rpcs[0].args.p_clubs, [
    { slug: "tj-sokol-brno-iv", name: "TJ Sokol Brno IV", match_id: "c1" },
    { slug: "tj-sokol-husovice", name: "TJ Sokol Husovice", match_id: null },
    { slug: "ks-devitka-brno", name: "KS Devítka Brno", match_id: "c2" },
    { slug: "skk-veverky-brno", name: "SKK Veverky Brno", match_id: "c3" },
  ]);
  const teams = rpcs[0].args.p_teams as { site_slug: string; club_slug: string }[];
  assertEquals(teams.map((t) => [t.site_slug, t.club_slug]), [
    ["tj-sokol-brno-iv-muzi", "tj-sokol-brno-iv"],
    ["skk-veverky-brno-b-muzi", "skk-veverky-brno"],
    ["tj-sokol-husovice-e-muzi", "tj-sokol-husovice"],
    ["tj-sokol-brno-iv-b-muzi", "tj-sokol-brno-iv"],
    ["ks-devitka-brno-b-muzi", "ks-devitka-brno"],
  ]);
  assertEquals(report, {
    teams: 5, competitions: 2, created: 2,
    teams_created: ["KS Devítka Brno B", "TJ Sokol Husovice E"],
    clubs_created: ["TJ Sokol Husovice"],
    clubs_linked: ["Sokol Brno IV", "Devítka", "Veverky"],
  });
});

Deno.test("runDiscover: no venue, no clubs on it, or no matches sitemap fails the job", async () => {
  await assertRejects(
    () => runDiscover(fakeDiscoverDb({ venue_slug: null }).db, discoverSite().get, "t1"),
    Error, "kuželna není nastavená",
  );
  await assertRejects(
    () => runDiscover(fakeDiscoverDb(null).db, discoverSite().get, "t1"),
    Error, "kuželna není nastavená",
  );
  await assertRejects(
    () => runDiscover(fakeDiscoverDb({ venue_slug: "tj-sokol-brno-iv" }).db,
      discoverSite({ "/detail-kuzelny/tj-sokol-brno-iv": "<html></html>" }).get, "t1"),
    Error, "na stránce kuželny nejsou žádné kluby",
  );
  const noMatches = fixture("sitemap_index.xml").replace(/<loc>[^<]*matches-\d+\.xml<\/loc>/g, "");
  const { db, rpcs } = fakeDiscoverDb({ venue_slug: "tj-sokol-brno-iv" });
  await assertRejects(
    () => runDiscover(db, discoverSite({ "/sitemap.xml": noMatches }).get, "t1"),
    Error, "sitemapa zápasů chybí",
  );
  assertEquals(rpcs, []);
});

// ---------------------------------------------------------------- league (0055)

Deno.test("planCompetition: every match no active team of ours plays is a league row (timeless, switched-off and our own timeless ones too)", () => {
  const { rows, league, keepIds } = planCompetition({
    matches: [
      match({ id: 1 }),
      // Two foreign teams: a league match.
      match({ id: 2, homeTeam: { id: 3, name: "KK X", slug: "kk-x-muzi" },
              totals: {
                home: { points: 6, total: 3200, fulls: 2100, spares: 1100, errors: 10, set_points: 15 },
                away: { points: 2, total: 3100, fulls: 2050, spares: 1050, errors: 14, set_points: 9 },
              }, status: "FINISHED" }),
      // No time yet: still a league match, with a null start.
      match({ id: 3, time: null, homeTeam: { id: 3, name: "KK X", slug: "kk-x-muzi" } }),
      // Ours but switched off: kept, never fetched as ours — and a league
      // match, so the round has no hole.
      match({ id: 4, homeTeam: { id: 3, name: "KK X", slug: "kk-x-muzi" },
              awayTeam: { id: 4, name: "TJ Sokol Husovice", slug: "tj-sokol-husovice-muzi" } }),
      // Ours (active) with no time yet: no slot to be, so it shows from here.
      match({ id: 5, time: null }),
      // The site sends an empty string for a missing time: still no time.
      match({ id: 6, time: "", homeTeam: { id: 3, name: "KK X", slug: "kk-x-muzi" } }),
    ],
    teams,
    legacy: [],
  });
  assertEquals(rows.map((r) => r.site_match_id), [1]);
  assertEquals(keepIds, [4, 5]);
  assertEquals(league.map((l) => l.site_match_id), [2, 3, 4, 5, 6]);
  assertEquals(league.map((l) => l.starts_at), ["10:00", null, "10:00", null, null]);
  assertEquals(league[0], {
    site_match_id: 2, site_slug: "jihomoravska-divize-2026-2027-kolo-1-m2",
    date: "2026-10-10", starts_at: "10:00", home_team: "KK X", away_team: "KC Zlín B",
    home_team_slug: "kk-x-muzi", away_team_slug: "kc-zlin-b-muzi",
    competition: "Jihomoravská divize", round: 1, video_url: null, status: "finished",
    match_type: "TEAMS_OF_6", discipline: "T120",
    home: { points: 6, total: 3200, fulls: 2100, spares: 1100, errors: 10, set_points: 15 },
    away: { points: 2, total: 3100, fulls: 2050, spares: 1050, errors: 14, set_points: 9 },
  });
});

Deno.test("runCompetition: the league matches go to apply_league_matches, after ours", async () => {
  const slug = "jihomoravska-divize-2026-2027";
  const page = competitionPage([
    match({ id: 1 }),
    match({ id: 2, homeTeam: { id: 3, name: "KK X", slug: "kk-x-muzi" } }),
  ]);
  const { db, rpcs } = fakeCompetitionDb({ teams: [ourTeam], legacy: [], stored: [] });
  await runCompetition(db, async () => page, "t1", slug, new Date("2026-10-01T10:00:00Z"));
  const names = rpcs.map((r) => r.name);
  assert(names.indexOf("apply_league_matches") > names.indexOf("apply_federation_matches"));
  const call = rpcs.find((r) => r.name === "apply_league_matches")!;
  assertEquals(call.args.p_competition_slug, slug);
  assertEquals((call.args.p_matches as { site_match_id: number }[]).map((l) => l.site_match_id), [2]);
});

Deno.test("processFederationJobs: a league match job fetches the detail once, writes only apply_league_result and leaves no report", async () => {
  const slug = "divize-as-2026-2027-kolo-1-tj-sokol-rudna-a-muzi-tj-sokol-vrsovice-a-muzi";
  const now = new Date(pragueEpoch("2026-09-16", "17:30") * 1000 + 6 * 3600e3);
  const jobs: FakeJob[] = [{
    id: 50, kind: "federation_league_match", attempts: 0,
    run_at: new Date(now.getTime() - 60e3).toISOString(),
    payload: { tenant_id: "t1", site_match_id: 4859, slug },
  }];
  const { db, calls } = fakeJobsDb(jobs, undefined, undefined, undefined, [
    { site_slug: "tj-sokol-brno-iv-muzi", active: true },
  ]);
  const fetched: string[] = [];
  await processFederationJobs(db, async (path) => {
    fetched.push(path);
    return fixture("match_finished.html");
  }, now);
  // One fetch of the detail, then done and gone: no re-arm, no live polling.
  assertEquals(fetched, [`/detail-zapasu/${slug}`]);
  assertEquals(jobs.length, 0);
  const rpcNames = calls.filter((c) => c.kind === "rpc").map((c) => (c as { name: string }).name);
  assertEquals(rpcNames, ["apply_league_result"]);
});

Deno.test("processFederationJobs: a failing league job is retried but never lands in last_report", async () => {
  const now = new Date("2026-10-01T10:00:00Z");
  const jobs: FakeJob[] = [{
    id: 51, kind: "federation_league_match", attempts: 0,
    run_at: new Date(now.getTime() - 60e3).toISOString(),
    payload: { tenant_id: "t1", site_match_id: 1, slug: "x-kolo-1-a-b" },
  }];
  const { db, calls } = fakeJobsDb(jobs);
  let fetches = 0;
  await processFederationJobs(db, () => {
    fetches++;
    return Promise.reject(new Error("site down"));
  }, now);
  assertEquals(fetches, 1, "the job did run");
  assertEquals(jobs[0].attempts, 1, "leased once");
  assertEquals(jobs.length, 1, "backed off, not deleted");
  assert(!calls.some((c) => c.kind === "rpc" && (c as { name: string }).name === "record_federation_run"));
});

Deno.test("processFederationJobs: league jobs are leased last, after the venues", async () => {
  const now = new Date("2026-10-01T10:00:00Z");
  const due = new Date(now.getTime() - 60e3).toISOString();
  const jobs: FakeJob[] = [
    { id: 60, kind: "federation_league_match", attempts: 0, run_at: due,
      payload: { tenant_id: "t1", site_match_id: 1, slug: "x-kolo-1-a-b" } },
    { id: 61, kind: "federation_venue", attempts: 0, run_at: due,
      payload: { tenant_id: "t1", slug: "kk-a" } },
  ];
  const order: string[] = [];
  const { db } = fakeJobsDb(jobs);
  await processFederationJobs(db, (path) => {
    order.push(path);
    return Promise.reject(new Error("stop"));
  }, now);
  assertEquals(order, ["/detail-kuzelny/kk-a", "/detail-zapasu/x-kolo-1-a-b"]);
});

Deno.test("runCompetition: a failing apply_league_matches costs us nothing — our match jobs are still armed, the report says why", async () => {
  const slug = "jihomoravska-divize-2026-2027";
  const page = competitionPage([
    match({ id: 1, status: "IN_PROGRESS" }),
    match({ id: 2, homeTeam: { id: 3, name: "KK X", slug: "kk-x-muzi" } }),
  ]);
  const { db, rpcs } = fakeCompetitionDb({
    teams: [ourTeam], legacy: [],
    stored: [{ site_match_id: 1, venue_slug: null, match_results: null }],
  });
  const failing = {
    ...db,
    async rpc(name: string, args: Record<string, unknown>) {
      if (name === "apply_league_matches") {
        rpcs.push({ name, args });
        return { data: null, error: { message: "league boom" } };
      }
      return await db.rpc(name, args);
    },
  };
  const report = await runCompetition(failing, async () => page, "t1", slug,
    new Date("2026-10-01T10:00:00Z"));
  assertEquals((report as Record<string, unknown>).league_error, "league boom");
  assert(rpcs.some((r) => r.name === "enqueue_federation_match" && r.args.p_site_match_id === 1));
});

Deno.test("runLeagueMatch: a match that is gone is not fetched", async () => {
  let fetched = false;
  const { db, calls } = fakeJobsDb([], undefined, undefined, undefined, undefined, []);
  const next = await runLeagueMatch(db, () => {
    fetched = true;
    return Promise.resolve("");
  }, "t1", 1, "x-kolo-1-a-b");
  assertEquals(next, null);
  assert(!fetched);
  assert(!calls.some((c) => c.kind === "rpc"));
});

Deno.test("runLeagueMatch: the existence read is scoped to the tenant and the match", async () => {
  const { db, calls } = fakeJobsDb([], undefined, undefined, undefined, undefined, []);
  await runLeagueMatch(db, () => Promise.resolve(""), "t1", 77, "x-kolo-1-a-b");
  const read = calls.find((c) => c.kind === "read" && c.table === "league_matches") as
    { kind: "read"; table: string; eqs: [string, unknown][] } | undefined;
  assertEquals(read?.eqs, [["tenant_id", "t1"], ["site_match_id", 77]]);
});

Deno.test("planCompetition: a league row carries the admin's name for a team of ours, and an empty time counts as none", () => {
  const mk = (id: number, time: string | null, home: string, away: string) => ({
    id, slug: `x-kolo-1-${id}`, date: "2026-10-03", time, round: 1, status: "SCHEDULED",
    matchType: "TEAMS_OF_6", discipline: "T100", videoUrl: null,
    homeTeam: { slug: home, name: home.toUpperCase() }, awayTeam: { slug: away, name: away.toUpperCase() },
    competition: { slug: "x", name: "X" }, totals: { home: null, away: null },
  }) as unknown as Parameters<typeof planCompetition>[0]["matches"][number];
  const { league } = planCompetition({
    matches: [mk(1, "", "ours-off", "foreign")],
    teams: [{ site_slug: "ours-off", name: "Naše vypnuté", active: false }] as never,
    legacy: [],
  });
  assertEquals(league[0].home_team, "Naše vypnuté");
  assertEquals(league[0].away_team, "FOREIGN");
  assertEquals(league[0].starts_at, null);
});

Deno.test("matchJobsFor: a stored match with an empty or missing time is planned at noon, no throw", () => {
  const now = new Date("2026-10-10T08:30:00Z");
  for (const time of ["", null]) {
    matchJobsFor({ matches: [match({ id: 9, time })], statusById: new Map([[9, null]]), now });
  }
});

Deno.test("runCompetition: a stored match of ours whose site time became '' does not fail the run; the live match is armed", async () => {
  const slug = "jihomoravska-divize-2026-2027";
  const page = competitionPage([
    match({ id: 1, status: "IN_PROGRESS" }),
    match({ id: 9, date: "2026-10-17", time: "" }),
  ]);
  const { db, rpcs } = fakeCompetitionDb({
    teams: [ourTeam], legacy: [],
    stored: [1, 9].map((id) => ({ site_match_id: id, venue_slug: "v", match_results: null })),
  });
  const report = await runCompetition(db, async () => page, "t1", slug,
    new Date("2026-10-10T08:30:00Z")) as Record<string, unknown>;
  assert(rpcs.some((r) => r.name === "enqueue_federation_match" && r.args.p_site_match_id === 1));
  assertEquals(report.skipped_no_time, ["TJ Sokol Brno IV – KC Zlín B (2026-10-17): bez času"]);
  const league = rpcs.find((r) => r.name === "apply_league_matches")!.args.p_matches as
    { site_match_id: number; starts_at: unknown; home_team: string }[];
  assertEquals(league.map((l) => [l.site_match_id, l.starts_at, l.home_team]),
    [[9, null, "TJ Sokol Brno IV A"]]);
});

Deno.test("runCompetition: a malformed time ('TBD') is none: no NaN slot, no league_error", async () => {
  const slug = "jihomoravska-divize-2026-2027";
  const page = competitionPage([
    match({ id: 1, status: "IN_PROGRESS" }),
    match({ id: 9, date: "2026-10-17", time: "TBD" }),
    match({ id: 5, time: "TBD", homeTeam: { id: 7, name: "KK X", slug: "kk-x-muzi" } }),
  ]);
  const { db, rpcs } = fakeCompetitionDb({
    teams: [ourTeam], legacy: [],
    stored: [1, 9].map((id) => ({ site_match_id: id, venue_slug: "v", match_results: null })),
  });
  const report = await runCompetition(db, async () => page, "t1", slug,
    new Date("2026-10-10T08:30:00Z")) as Record<string, unknown>;
  assertEquals(report.league_error, undefined);
  const slots = rpcs.find((r) => r.name === "apply_federation_matches")!.args.p_matches as
    { ends_at: string }[];
  assert(slots.every((s) => !s.ends_at.includes("NaN")));
  const league = rpcs.find((r) => r.name === "apply_league_matches")!.args.p_matches as
    { site_match_id: number; starts_at: unknown }[];
  assertEquals(league.map((l) => [l.site_match_id, l.starts_at]).sort(), [[5, null], [9, null]]);
  assert(rpcs.some((r) => r.name === "enqueue_federation_match" && r.args.p_site_match_id === 1));
});

Deno.test("planCompetition: league rows carry the admin's team names on BOTH sides, active-timeless included", () => {
  const away = { id: 1, name: "TJ Sokol Brno IV", slug: "tj-sokol-brno-iv-muzi" };
  const other = { id: 2, name: "KC Zlín B", slug: "kc-zlin-b-muzi" };
  const { league } = planCompetition({
    matches: [
      match({ id: 5, time: null }),
      match({ id: 6, time: null, homeTeam: other, awayTeam: away }),
    ],
    teams: [ourTeam], legacy: [],
  });
  assertEquals(league.map((l) => [l.home_team, l.away_team]),
    [["TJ Sokol Brno IV A", "KC Zlín B"], ["KC Zlín B", "TJ Sokol Brno IV A"]]);
  const off = planCompetition({
    matches: [match({ id: 7, homeTeam: other, awayTeam: away })],
    teams: [{ ...ourTeam, active: false }], legacy: [],
  }).league;
  assertEquals([off[0].home_team, off[0].away_team], ["KC Zlín B", "TJ Sokol Brno IV A"]);
});

Deno.test("planCompetition: a league row keeps the video link and the round page's totals", () => {
  const totals = {
    home: { points: 3, total: 3169, fulls: 2180, spares: 989, errors: 30, set_points: 12.5 },
    away: { points: 5, total: 3280, fulls: 2193, spares: 1087, errors: 31, set_points: 11.5 },
  };
  const { league } = planCompetition({
    matches: [match({ id: 5, homeTeam: { id: 7, name: "KK X", slug: "kk-x-muzi" },
      videoUrl: "https://www.youtube.com/watch?v=x", totals })],
    teams: [], legacy: [],
  });
  assertEquals(league[0].video_url, "https://www.youtube.com/watch?v=x");
  assertEquals([league[0].home, league[0].away], [totals.home, totals.away]);
});

// What runLeagueMatch hands apply_league_result, and how a failure ends the job.
function leagueDb(rpcResult: { data: unknown; error: { message: string } | null }) {
  const rpcs: { name: string; args: Record<string, unknown> }[] = [];
  const db = {
    from() {
      // deno-lint-ignore no-explicit-any
      const chain: any = { select: () => chain, eq: () => chain, limit: () => chain,
        then: (ok: (v: unknown) => unknown) => Promise.resolve({ data: [{ id: "lg" }], error: null }).then(ok) };
      return chain;
    },
    rpc(name: string, args: Record<string, unknown>) {
      rpcs.push({ name, args });
      return Promise.resolve(rpcResult);
    },
  };
  return { db, rpcs };
}

Deno.test("runLeagueMatch: apply_league_result gets the tenant, the job's match id and the detail's payload", async () => {
  const html = fixture("match_substitution.html");
  const { db, rpcs } = leagueDb({ data: true, error: null });
  assertEquals(await runLeagueMatch(db, () => Promise.resolve(html), "t1", 4050, "slug"), null);
  assertEquals(rpcs, [{ name: "apply_league_result",
    args: { p_tenant: "t1", p_site_match_id: 4050, p_result: resultPayload(parseMatch(html)) } }]);
});

Deno.test("runLeagueMatch: an RPC error or an unparsable page rejects; false (row gone) ends the job", async () => {
  const html = fixture("match_substitution.html");
  await assertRejects(() => runLeagueMatch(leagueDb({ data: null, error: { message: "boom" } }).db,
    () => Promise.resolve(html), "t1", 4050, "slug"), Error, "boom");
  await assertRejects(() => runLeagueMatch(leagueDb({ data: true, error: null }).db,
    () => Promise.resolve("<html>not a match</html>"), "t1", 4050, "slug"));
  assertEquals(await runLeagueMatch(leagueDb({ data: false, error: null }).db,
    () => Promise.resolve(html), "t1", 4050, "slug"), null);
});

Deno.test("processFederationJobs: a league match job that fails is retried with backoff, not dropped", async () => {
  const slug = "divize-as-2026-2027-kolo-1-tj-sokol-rudna-a-muzi-tj-sokol-vrsovice-a-muzi";
  const now = new Date("2026-10-01T10:00:00Z");
  const jobs: FakeJob[] = [{
    id: 51, kind: "federation_league_match", attempts: 0,
    run_at: new Date(now.getTime() - 60e3).toISOString(),
    payload: { tenant_id: "t1", site_match_id: 4859, slug },
  }];
  const { db, calls } = fakeJobsDb(jobs, (name) =>
    name === "apply_league_result" ? { data: null, error: { message: "boom" } } : { data: null, error: null });
  await processFederationJobs(db, async () => fixture("match_finished.html"), now);
  const j = jobs.find((x) => x.id === 51);
  assert(j, "the job is kept");
  assertEquals(j.attempts, 1);
  assert(new Date(j.run_at).getTime() > now.getTime(), "run_at pushed into the future");
  void calls;
});
