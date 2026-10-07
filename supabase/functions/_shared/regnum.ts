// Registration numbers from the ČKA member register (https://evidence.kuzelky.cz).
//
// The register is a web app over a JSON API: `GET /frontend-api/members
// ?fulltext=<name>` answers `{ data: [...] }` — and the WHOLE register, every
// member, without a filter. (Until October 2026 it was a PHP page with a
// filter cookie; that page is gone.) Each row carries more than a number;
// only the name, club, age category, state, number and the register's own row
// id are ever read, and nothing else is kept, logged or returned.
//
// Who is who: the results service (vysledky.kuzelky.cz) and the register share
// no id, and the results service publishes no number. Its player page does
// show the club („Oddíl“) and the age („Věk“); the register shows the age
// CATEGORY (dorostenci, muži, senioři, …) — enough to tell a senior father from
// his son, though not two men of one name, one club and one category. A
// match's player is therefore resolved against his page ([resolveSitePlayer]);
// a profile has no such page, so it is filled only when the club leaves one
// candidate, and otherwise the player picks from [profileCandidates] himself.
//
// IO is injected (`fetchFn`), so the matching is testable without the sites.

const BASE = "https://evidence.kuzelky.cz/";
const SITE = "https://vysledky.kuzelky.cz";
const USER_AGENT = "rezervator/1.0 (+https://rezervator.online)";

/** A filtered answer is a handful of rows (a common surname alone some
 * dozens); a long one means the filter was not applied, and the answer is the
 * whole register (thousands) — dropped unread. */
export const MAX_ROWS = 200;

/** No answer from a site in this long is a failure, not a wait: one stuck
 * request would otherwise hold the whole call until the platform kills it. */
export const TIMEOUT_MS = 10_000;

/** Years by which a page's age may miss a category's range and still count:
 * the two sites compute the age on different days (and the register by the
 * season), so a player at the edge sits on either side. */
export const AGE_TOLERANCE = 1;

/** The register's age categories, in order, with the ages they span — read
 * off the register against the results service's ages (senioři from 60, muži
 * below; the youth bounds are ČKA's usual ones). [AGE_TOLERANCE] covers the
 * edges. */
const CATEGORIES: { prefix: string; from: number; to: number }[] = [
  { prefix: "zaci ml", from: 0, to: 10 },
  { prefix: "zaci st", from: 11, to: 14 },
  { prefix: "doros", from: 15, to: 18 },
  { prefix: "junior", from: 19, to: 22 },
  { prefix: "muzi", from: 23, to: 59 },
  { prefix: "senior", from: 60, to: 150 },
];

/** The category's index in [CATEGORIES] from the register's label
 * („senioři, seniorky“), or null when the label is empty or unknown. */
export function categoryOf(label: string): number | null {
  const key = foldName(label);
  const i = CATEGORIES.findIndex((c) => key.startsWith(c.prefix));
  return i < 0 ? null : i;
}

/** Whether a player of [age] can be in [category] ([AGE_TOLERANCE] at the
 * edges). */
export function ageFits(category: number, age: number): boolean {
  const c = CATEGORIES[category];
  return age >= c.from - AGE_TOLERANCE && age <= c.to + AGE_TOLERANCE;
}

export type RegisterRow = {
  /** The register's own row id: opaque, only to point at one candidate. */
  id: string;
  name: string;
  club: string;
  regnum: string;
  /** Index into [CATEGORIES], null when the register gives none. */
  category: number | null;
  /** The register's own label of it, for a player to recognise himself. */
  categoryName: string;
};

export type Resolved =
  | { status: "found"; regnum: string }
  | { status: "none" }
  | { status: "ambiguous" };

/** What the results service's player page says about a player. */
export type SitePlayer = { club: string | null; age: number | null };

type Fetch = typeof fetch;

/** Lower case, no diacritics, single spaces: the key names are compared by. */
export function foldName(s: string): string {
  return s
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/\s+/g, " ")
    .trim();
}

/** Whether a register club and a team / club name of ours are the same club:
 * the team is the club plus a letter („TJ Sokol Rudná A“), or the club in the
 * app is a short form of the register's („Sokol Rudná“). */
export function clubMatches(registerClub: string, ours: string): boolean {
  const r = foldName(registerClub);
  const o = foldName(ours);
  if (r === "" || o === "") return false;
  return o.startsWith(r) || r.includes(o);
}

/** The rows that are exactly [name]. */
export function named(rows: RegisterRow[], name: string): RegisterRow[] {
  const key = foldName(name);
  return rows.filter((r) => foldName(r.name) === key);
}

const regnumsOf = (rows: RegisterRow[]) => new Set(rows.map((r) => r.regnum));

/** The folded names that more than one of [names] has: profiles of one alley
 * that bear the same name (a parent and a child) cannot be told apart by name
 * and club, so none of them is filled in by itself — each picks himself. */
export function sharedNames(names: string[]): Set<string> {
  const seen = new Set<string>();
  const shared = new Set<string>();
  for (const name of names) {
    const key = foldName(name);
    if (seen.has(key)) shared.add(key);
    seen.add(key);
  }
  return shared;
}

/** The number of a MATCH's player, who is known by his page on the results
 * service. Of the rows of that name the ones whose age category fits his age
 * stay (a namesake of another category is somebody else, and none that fits
 * means he is not in the register — nobody is guessed); one number among them
 * is the answer; with several the club decides, else `ambiguous`. */
export function pickForSitePlayer(
  rows: RegisterRow[],
  name: string,
  site: SitePlayer,
  team: string,
): Resolved {
  let candidates = named(rows, name);
  const age = site.age;
  if (age !== null) {
    candidates = candidates.filter(
      (r) => r.category !== null && ageFits(r.category, age),
    );
  }
  if (candidates.length === 0) return { status: "none" };
  if (regnumsOf(candidates).size === 1) {
    // Without an age to check, one namesake of another club proves nothing.
    if (age === null && !clubFits(candidates, site.club, team)) {
      return { status: "ambiguous" };
    }
    return { status: "found", regnum: candidates[0].regnum };
  }
  const ofClub = candidates.filter((r) => clubFits([r], site.club, team));
  return regnumsOf(ofClub).size === 1
    ? { status: "found", regnum: ofClub[0].regnum }
    : { status: "ambiguous" };
}

/** Whether a row's club is the player's club by his page, else his team. */
function clubFits(rows: RegisterRow[], siteClub: string | null, team: string) {
  const ours = siteClub ?? team;
  return rows.some((r) => clubMatches(r.club, ours));
}

export type ProfileMatch =
  | { status: "found"; regnum: string }
  | { status: "none" }
  | { status: "choose"; candidates: RegisterRow[] };

/** The number of a PROFILE, which has a name and maybe a club but no page.
 * Filled by itself only when the club leaves exactly one person; every other
 * case with a namesake in the register is [choose] — the player says which
 * one is he. No namesake at all is [none]. */
export function pickForProfile(
  rows: RegisterRow[],
  name: string,
  club: string,
): ProfileMatch {
  const candidates = named(rows, name);
  if (candidates.length === 0) return { status: "none" };
  const ofClub = club === ""
    ? []
    : candidates.filter((r) => clubMatches(r.club, club));
  if (ofClub.length > 0 && regnumsOf(ofClub).size === 1) {
    return { status: "found", regnum: ofClub[0].regnum };
  }
  return { status: "choose", candidates };
}

/** The rows of the register's JSON, reduced to what is needed. Throws when
 * the answer is not a filtered list. */
export function parseRows(json: unknown): RegisterRow[] {
  const data = (json as { data?: unknown } | null)?.data;
  if (!Array.isArray(data)) throw new Error("register: no data");
  if (data.length > MAX_ROWS) throw new Error("register: filter not applied");
  const rows: RegisterRow[] = [];
  for (const raw of data) {
    const r = raw as Record<string, unknown>;
    const regnum = String(r.registrationNumber ?? "").trim();
    if (!/^[0-9]{1,8}$/.test(regnum)) continue;
    // An archived row is a former member; the live one wins when both exist.
    if (r.state === "archived") continue;
    const first = String(r.name ?? "").trim();
    const last = String(r.surname ?? "").trim();
    const categoryName = String(r.ageCategory ?? "").trim();
    rows.push({
      id: String(r.id ?? "").trim(),
      name: `${first} ${last}`.trim(),
      club: String(r.club ?? "").trim(),
      regnum,
      category: categoryOf(categoryName),
      categoryName,
    });
  }
  return rows;
}

/** Asks the register for [name]: one request. */
export async function searchRegister(
  name: string,
  fetchFn: Fetch = fetch,
): Promise<RegisterRow[]> {
  const url = `${BASE}frontend-api/members?fulltext=${encodeURIComponent(name)}`;
  const list = await fetchFn(url, {
    headers: { "User-Agent": USER_AGENT, Accept: "application/json" },
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!list.ok) throw new Error(`register: HTTP ${list.status}`);
  return parseRows(await list.json());
}

/** The club and the age out of a results-service player page: its text reads
 * „Profil hráče : Jan Novák Oddíl: TJ Sokol Rudná Věk: 59 let Kategorie: …“.
 * Null parts when the page does not say. */
export function parseSitePlayer(html: string): SitePlayer {
  const text = html
    .slice(Math.max(0, html.indexOf("<body")))
    .replace(/<script[\s\S]*?<\/script>/g, " ")
    .replace(/<style[\s\S]*?<\/style>/g, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/\s+/g, " ");
  const club = /Oddíl:\s*(.+?)\s+Věk:/.exec(text)?.[1]?.trim() || null;
  const age = /Věk:\s*(\d{1,3})\s+let/.exec(text)?.[1];
  return { club, age: age === undefined ? null : Number(age) };
}

/** A results-service player slug, as the service builds them. Anything else
 * never reaches a URL. */
export const isSiteSlug = (slug: string) => /^[a-z0-9][a-z0-9-]{0,99}$/.test(slug);

/** Reads a player's page on the results service. */
export async function fetchSitePlayer(
  slug: string,
  fetchFn: Fetch = fetch,
): Promise<SitePlayer> {
  if (!isSiteSlug(slug)) throw new Error("site: bad slug");
  const res = await fetchFn(`${SITE}/detail-hrace/${slug}`, {
    headers: { "User-Agent": USER_AGENT },
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!res.ok) throw new Error(`site: HTTP ${res.status}`);
  return parseSitePlayer(await res.text());
}

/** The number of a match's player: his page for club and age, the register
 * for the rest. */
export async function resolveSitePlayer(
  name: string,
  slug: string,
  team: string,
  fetchFn: Fetch = fetch,
): Promise<Resolved> {
  const site = await fetchSitePlayer(slug, fetchFn);
  return pickForSitePlayer(
    await searchRegister(name, fetchFn),
    name,
    site,
    team,
  );
}

/** What a profile's name and club make of the register. */
export async function resolveProfile(
  name: string,
  club: string,
  fetchFn: Fetch = fetch,
): Promise<ProfileMatch> {
  return pickForProfile(await searchRegister(name, fetchFn), name, club);
}
