import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { pragueEpoch } from "./cancel_token.ts";
import type { SiteMatch } from "./federation.ts";
import {
  jobOutcome, matchJobsFor, planCompetition, planTeams,
  processFederationJobs, runCompetition, runDiscover, SITE,
} from "./federation_jobs.ts";

const fixture = (name: string) =>
  Deno.readTextFileSync(new URL(`./fixtures/federation/${name}`, import.meta.url));

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
        return { data: table === "teams" ? teams.map((t) => ({ ...t })) : [], error: null };
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
 * "rekeys" the paired legacy rows, so the read after it sees them gone. */
function fakeCompetitionDb(state: {
  teams: { site_slug: string; name: string; active: boolean }[];
  legacy: Legacy[];
  stored: { site_match_id: number; venue_slug: string | null; match_results: null }[];
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
        then(onFulfilled: (v: unknown) => unknown) {
          let data: unknown = [];
          if (table === "teams") data = state.teams;
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

/** The reads and the RPC runDiscover issues. */
function fakeDiscoverDb(sync: { venue_slug: string | null } | null) {
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
            ? [{ id: "c1", name: "Sokol Brno IV" }]
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
      return { data: 1, error: null };
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
  assertEquals(rpcs.map((r) => r.name), ["upsert_federation_teams"]);
  assertEquals(rpcs[0].args, {
    p_tenant: "t1",
    p_teams: [{
      site_slug: "tj-sokol-brno-iv-muzi", site_team_id: 243, site_name: "TJ Sokol Brno IV",
      competition_slug: "jihomoravska-divize-2026-2027", competition_name: "Jihomoravská divize",
      name: "TJ Sokol Brno IV A", club_id: "c1",
    }],
  });
  assertEquals(report, { teams: 1, created: 1 });
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
