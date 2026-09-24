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
export type VenueItem = { label: string; value: string };
export type VenueSection = { title: string; items: VenueItem[] };
export type SiteVenue = {
  slug: string; name: string; address: string | null; phone: string | null;
  email: string | null; lat: number | null; lng: number | null;
  sections: VenueSection[]; clubs: string[];
};
export type LegacyRow = {
  id: string; import_key: string; date: string; starts_at: string; home_team: string; away_team: string;
};
export type PairCandidate = {
  siteId: number; date: string; startsAt: string; round: number; home: string; away: string;
};

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
  const slug = str(t?.slug);
  if (typeof t?.id !== "number" || !slug) throw new Error("bad team");
  return { id: t.id, name: str(t.name) ?? slug, slug };
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
    .replaceAll("&lt;", "<").replaceAll("&gt;", ">").replaceAll("&nbsp;", " ")
    .replace(/&#x([0-9a-fA-F]+);/g, (_, hex) => String.fromCodePoint(parseInt(hex, 16)))
    .replace(/&#(\d+);/g, (_, dec) => String.fromCodePoint(parseInt(dec, 10)));

// React SSR sprinkles `<!-- -->` between interpolated text nodes (e.g. the
// h1's "Detail kuželny: <name>"); strip those along with any tags.
const textOf = (html: string) =>
  decodeEntities(html.replace(/<!--[\s\S]*?-->/g, "").replace(/<[^>]+>/g, "")).trim();

function dlPairs(dlHtml: string): { label: string; ddHtml: string }[] {
  return [...dlHtml.matchAll(/<dt[^>]*>([\s\S]*?)<\/dt>\s*<dd[^>]*>([\s\S]*?)<\/dd>/g)]
    .map((m) => ({ label: textOf(m[1]).replace(/:\s*$/, ""), ddHtml: m[2] }));
}

export function parseVenue(html: string, slug: string): SiteVenue {
  const h1 = /<h1[^>]*>([\s\S]*?)<\/h1>/.exec(html);
  const h1Text = h1 ? textOf(h1[1]) : "";
  const name = h1Text.includes(":") ? h1Text.slice(h1Text.indexOf(":") + 1).trim() : "";
  const blocks = [...html.matchAll(/<h[23][^>]*>([^<]*)<\/h[23]>\s*<dl[^>]*>([\s\S]*?)<\/dl>/g)];
  if (!name || blocks.length === 0) throw new Error("venue data missing");

  let address: string | null = null;
  let phone: string | null = null;
  let email: string | null = null;
  let lat: number | null = null;
  let lng: number | null = null;
  const sections: VenueSection[] = [];

  for (const block of blocks) {
    const title = textOf(block[1]);
    const items: VenueItem[] = [];
    for (const { label, ddHtml } of dlPairs(block[2])) {
      if (label === "Adresa") {
        const span = /<span[^>]*>([\s\S]*?)<\/span>/.exec(ddHtml);
        address = span ? textOf(span[1]) : null;
        const mapyHref = /href="([^"]*mapy\.com[^"]*)"/.exec(ddHtml);
        if (mapyHref) {
          const params = new URL(decodeEntities(mapyHref[1])).searchParams;
          const x = params.get("x");
          const y = params.get("y");
          lng = x !== null ? Number(x) : null;
          lat = y !== null ? Number(y) : null;
        } else {
          lng = null;
          lat = null;
        }
        continue;
      }
      if (label === "Telefon") {
        const tel = /href="tel:([^"]*)"/.exec(ddHtml);
        phone = tel ? tel[1] : null;
        continue;
      }
      if (label === "E-mail") {
        const mail = /href="mailto:([^"]*)"/.exec(ddHtml);
        email = mail ? mail[1] : null;
        continue;
      }
      const value = textOf(ddHtml);
      if (!value || value === "–") continue;
      items.push({ label, value });
    }
    if (items.length > 0) sections.push({ title, items });
  }

  return {
    slug, name, address, phone, email, lat, lng, sections,
    clubs: parseVenueClubs(html).map((c) => c.name),
  };
}

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
  return /^([a-z]-)?[a-z]+(-\d+)?$/.test(teamSlug.slice(clubSlug.length + 1));
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
  // The last rule is the old importer's "renamed opponent": the same slot
  // with one team in common. Loose enough that a legacy row must also have
  // just one candidate.
  const rules: { test: (c: PairCandidate, l: LegacyRow) => boolean; strict: boolean }[] = [
    {
      test: (c, l) => {
        const k = keyed(l);
        return !!k && Number(k[1]) === c.round && same(k[2], c.home) && same(k[3], c.away);
      },
      strict: false,
    },
    {
      test: (c, l) => l.date === c.date && same(l.home_team, c.home) && same(l.away_team, c.away),
      strict: false,
    },
    {
      test: (c, l) =>
        l.date === c.date && l.starts_at.slice(0, 5) === c.startsAt &&
        (same(l.home_team, c.home) || same(l.away_team, c.away)),
      strict: true,
    },
  ];
  for (const { test, strict } of rules) {
    for (const c of candidates) {
      if (pairs.has(c.siteId)) continue;
      const hits = [...free.values()].filter((l) => test(c, l));
      if (hits.length !== 1) continue;
      if (strict && candidates.filter((o) => !pairs.has(o.siteId) && test(o, hits[0])).length !== 1) {
        continue;
      }
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
