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
}): { rows: SlotRow[]; skipped: string[]; keepIds: number[] } {
  const ours = new Set(args.teams.map((t) => t.site_slug));
  const active = new Set(args.teams.filter((t) => t.active).map((t) => t.site_slug));
  const nameOf = new Map(args.teams.map((t) => [t.site_slug, t.name]));
  const unique = [...new Map(args.matches.map((m) => [m.id, m])).values()];
  const rows: SlotRow[] = [];
  const skipped: string[] = [];
  const keepIds: number[] = [];
  for (const m of unique) {
    if (!active.has(m.homeTeam.slug) && !active.has(m.awayTeam.slug)) continue;
    if (!m.time) {
      skipped.push(`${m.homeTeam.name} – ${m.awayTeam.name} (${m.date}): bez času`);
      keepIds.push(m.id);
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
  return { rows, skipped, keepIds };
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
  const ourClubs = must(await db.from("clubs").select("id, name").eq("tenant_id", tenantId)) as
    { id: string; name: string }[];
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
      const page = parseCompetition(await get(`/detail-souteze/${slug}?round=${id}`));
      // A site that ignores ?round= and always serves the current round would
      // otherwise silently drop every other round from p_matches — and
      // apply_federation_matches reads a missing round as "withdrawn", deleting
      // its future slots. Fail the job instead.
      if (page.currentRound !== id) throw new Error(`round ${id} not served`);
      pages.push(page);
    }
  }
  const matches = pages.flatMap((p) => p.matches);
  const legacy = must(await db.from("priority_slots")
    .select("id, import_key, date, home_team, away_team")
    .eq("tenant_id", tenantId).like("import_key", "rozpis:%")) as LegacyRow[];
  const { rows, skipped, keepIds } = planCompetition({ matches, teams, legacy });
  const report = must(await db.rpc("apply_federation_matches", {
    p_tenant: tenantId, p_competition_slug: slug, p_matches: rows, p_keep_ids: keepIds,
  })) as Record<string, unknown>;
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

/** Runs a DB write that must not blow up the job it's cleaning up after: any
 * thrown error or returned `{ error }` is logged and swallowed. Used for the
 * three writes that happen once a job's outcome is already decided (delete,
 * re-arm, record_federation_run on failure) — none of them should turn a
 * handled job failure into an unhandled one. */
async function logged(
  label: string,
  op: () => Promise<{ error?: unknown } | void | null | undefined>,
): Promise<void> {
  try {
    const res = await op();
    if (res && typeof res === "object" && "error" in res && res.error) {
      console.error(`${label} failed:`, { error: res.error });
    }
  } catch (error) {
    console.error(`${label} failed:`, { error });
  }
}

/** Cron entry point. `budgetMs` (default 60s, the edge function's rough time
 * budget for this part of the tick) stops LEASING new jobs — already-leased
 * jobs in the current concurrency batch still run to completion. A budget of
 * 0 leases nothing, which is what makes it testable: `Date.now() - started`
 * is compared with `>=`, not `>`, so the very first check already stops the
 * run rather than racing the clock's millisecond resolution. */
export async function processFederationJobs(
  db: Db, get: Fetcher, now = new Date(), budgetMs = 60_000,
) {
  const started = Date.now();
  const overBudget = () => Date.now() - started >= budgetMs;
  for (const [kind, limit] of LIMITS) {
    if (overBudget()) break;
    const due = must(await db.from("notification_jobs").select("id, payload, attempts, run_at")
      .eq("kind", kind).lte("run_at", now.toISOString()).order("run_at").limit(limit)) as Job[];
    const leased: Job[] = [];
    for (const job of due) {
      if (overBudget()) break;
      // A job that has been leased this many times without ever reaching
      // jobOutcome's own give-up check (attempts >= MAX_ATTEMPTS, only seen
      // on a caught failure) was killed mid-run by the runtime, repeatedly —
      // leasing counts as an attempt precisely so this can't loop forever.
      if (job.attempts > MAX_ATTEMPTS) {
        console.error(`job ${kind}/${job.id} exceeded ${MAX_ATTEMPTS} attempts without finishing, deleting`);
        await logged(`delete stale ${kind}/${job.id}`, () =>
          db.from("notification_jobs").delete().eq("id", job.id));
        continue;
      }
      const { data } = await db.from("notification_jobs")
        .update({ run_at: new Date(Date.now() + LEASE_MS).toISOString(), attempts: job.attempts + 1 })
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
          await logged(`record_federation_run ${kind}/${job.id}`, () =>
            db.rpc("record_federation_run", {
              p_tenant: String(job.payload.tenant_id), p_key: kind, p_report: null,
              p_error: `${kind}: ${message}`,
            }));
        }
        if (outcome.action === "delete") {
          await logged(`delete ${kind}/${job.id}`, () =>
            db.from("notification_jobs").delete().eq("id", job.id));
        } else {
          await logged(`rearm ${kind}/${job.id}`, () =>
            db.from("notification_jobs")
              .update({ run_at: outcome.run_at.toISOString(), attempts: outcome.attempts })
              .eq("id", job.id));
        }
      }));
    }
  }
}
