// Registration numbers from the ČKA member register (https://evidence.kuzelky.cz).
//
// The register is a PHP page: a POST to `/` with `ffulltext` answers 302 and
// sets a `filter` cookie; `/?aajax=t` then returns the list for that filter as
// JSON — and the WHOLE register, every member, when the cookie is missing.
// Each row carries far more than a number (birth date and number, …); only the
// name, club and registration number are ever read, and nothing else is kept,
// logged or returned.
//
// IO is injected (`fetchFn`), so the matching is testable without the site.

const BASE = "https://evidence.kuzelky.cz/";
const USER_AGENT = "rezervator/1.0 (+https://rezervator.online)";

/** A filtered answer is a handful of rows; a long one means the filter was
 * not applied, and the answer is the whole register — dropped unread. */
export const MAX_ROWS = 50;

export type RegisterRow = { name: string; club: string; regnum: string };

export type Resolved =
  | { status: "found"; regnum: string }
  | { status: "none" }
  | { status: "ambiguous" };

type Fetch = typeof fetch;

/** Lower case, no diacritics, single spaces: the key names are compared by. */
export function foldName(s: string): string {
  return s
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
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

/** Picks the number of [name] from the register's rows for it: the rows that
 * are exactly that name; one number among them is the answer; with several
 * people of that name the club decides, and when it does not, nobody is
 * guessed. */
export function pick(
  rows: RegisterRow[],
  name: string,
  club: string,
): Resolved {
  const key = foldName(name);
  const named = rows.filter((r) => foldName(r.name) === key);
  const numbers = new Set(named.map((r) => r.regnum));
  if (numbers.size === 0) return { status: "none" };
  if (numbers.size === 1) return { status: "found", regnum: [...numbers][0] };
  const ofClub = new Set(
    named.filter((r) => clubMatches(r.club, club)).map((r) => r.regnum),
  );
  return ofClub.size === 1
    ? { status: "found", regnum: [...ofClub][0] }
    : { status: "ambiguous" };
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
    const regnum = String(r.reg_no ?? "").trim();
    if (!/^[0-9]{1,8}$/.test(regnum)) continue;
    // An archived row is a former member; the live one wins when both exist.
    if (r.archived) continue;
    const first = String(r.name ?? "").trim();
    const last = String(r.surname ?? "").trim();
    rows.push({
      name: `${first} ${last}`.trim(),
      club: String(r.club ?? "").trim(),
      regnum,
    });
  }
  return rows;
}

/** Asks the register for [name]. Two requests: the filter, then its list. */
export async function searchRegister(
  name: string,
  fetchFn: Fetch = fetch,
): Promise<RegisterRow[]> {
  const set = await fetchFn(BASE, {
    method: "POST",
    redirect: "manual",
    headers: {
      "User-Agent": USER_AGENT,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({ ffulltext: name, setFFilter: "1" }),
  });
  await set.body?.cancel();
  const cookie = cookieOf(set.headers, "filter");
  if (cookie === null) throw new Error("register: no filter cookie");
  const list = await fetchFn(`${BASE}?aajax=t`, {
    headers: { "User-Agent": USER_AGENT, Cookie: cookie },
  });
  if (!list.ok) throw new Error(`register: HTTP ${list.status}`);
  return parseRows(await list.json());
}

/** `name=value` of the Set-Cookie called [name], or null. */
function cookieOf(headers: Headers, name: string): string | null {
  for (const line of headers.getSetCookie()) {
    const pair = line.split(";")[0];
    if (pair.startsWith(`${name}=`)) return pair;
  }
  return null;
}

/** The number of [name] (of [club], when it has one), looked up in the
 * register. */
export async function resolveRegnum(
  name: string,
  club: string,
  fetchFn: Fetch = fetch,
): Promise<Resolved> {
  return pick(await searchRegister(name, fetchFn), name, club);
}
