import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { pragueEpoch } from "./cancel_token.ts";
import type { SiteMatch } from "./federation.ts";
import {
  jobOutcome, matchJobsFor, planCompetition, planTeams,
  processFederationJobs, runCompetition,
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
  });
});

Deno.test("planCompetition keeps the ids of our matches it skipped for no time", () => {
  const { rows, keepIds } = planCompetition({
    matches: [
      match({ id: 1 }),
      match({ id: 4, time: null }),
      match({ id: 7, time: null, homeTeam: { id: 3, name: "KK X", slug: "kk-x-muzi" } }),
    ],
    teams, legacy: [],
  });
  assertEquals(rows.map((r) => r.site_match_id), [1]);
  assertEquals(keepIds, [4]);
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
});

// ------------------------------------------------------- processFederationJobs

type FakeJob = {
  id: number; kind: string; attempts: number; run_at: string;
  payload: Record<string, unknown>;
};
type Call =
  | { kind: "update"; id: unknown; set: Record<string, unknown> }
  | { kind: "delete"; id: unknown }
  | { kind: "rpc"; name: string; args: Record<string, unknown> };

/** A minimal in-memory stand-in for the `notification_jobs` slice of the
 * Supabase query builder — just the chains processFederationJobs actually
 * issues: `select().eq().lte().order().limit()` (the due query),
 * `update().eq().eq().select()` (the optimistic-lock lease),
 * `update().eq()` (the outcome re-arm, no lock) and `delete().eq()`. Mutates
 * `jobs` in place so a test can assert on it directly after the run. */
function fakeJobsDb(
  jobs: FakeJob[],
  onRpc?: (name: string, args: Record<string, unknown>) => { data: unknown; error: unknown },
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
      if (table !== "notification_jobs") return { data: [], error: null };
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
      return { data: rows.map((j) => ({ ...j })), error: null };
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

Deno.test("processFederationJobs: a job past MAX_ATTEMPTS is deleted without fetching", async () => {
  const jobs: FakeJob[] = [{
    id: 2, kind: "federation_match", attempts: 6, // > MAX_ATTEMPTS (5)
    run_at: new Date(Date.now() - 60e3).toISOString(),
    payload: { tenant_id: "t1", site_match_id: 1, slug: "x" },
  }];
  const { db } = fakeJobsDb(jobs);
  let fetched = false;
  const get = async () => {
    fetched = true;
    return "";
  };

  await processFederationJobs(db, get, new Date());

  assert(!fetched);
  assertEquals(jobs.length, 0);
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
  assertEquals(recorded!.args.p_error, "federation_match: network down");
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
