import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  ageFits,
  categoryOf,
  clubMatches,
  fetchSitePlayer,
  foldName,
  type Gender,
  GENDER_RETRY_DAYS,
  genderAction,
  genderForFound,
  isSiteSlug,
  MAX_ROWS,
  needsGender,
  parseRows,
  parseSitePlayer,
  pickForProfile,
  pickForSitePlayer,
  type RegisterRow,
  resolveProfile,
  resolveSitePlayer,
  searchRegister,
  sharedNames,
} from "./regnum.ts";

// The register's age categories, by index (see CATEGORIES in regnum.ts).
const DOROST = 2, MUZI = 4, SENIOR = 5;

const row = (
  name: string,
  club: string,
  regnum: string,
  category: number | null = MUZI,
  gender: Gender | null = null,
  id = `id${regnum}`,
): RegisterRow => ({ id, name, club, regnum, category, categoryName: "", gender });

Deno.test("categoryOf reads the register's labels; ageFits allows a year at the edges", () => {
  assertEquals(categoryOf("žáci ml., žákyně ml."), 0);
  assertEquals(categoryOf("dorostenci, dorostenky"), DOROST);
  assertEquals(categoryOf("muži, ženy"), MUZI);
  assertEquals(categoryOf("senioři, seniorky"), SENIOR);
  assertEquals(categoryOf(""), null);
  assertEquals(categoryOf("veteráni"), null);
  assertEquals(ageFits(SENIOR, 60), true);
  assertEquals(ageFits(SENIOR, 59), true, "a year off the edge");
  assertEquals(ageFits(SENIOR, 58), false);
  assertEquals(ageFits(MUZI, 58), true);
  assertEquals(ageFits(MUZI, 61), false);
  assertEquals(ageFits(DOROST, 17), true);
  assertEquals(ageFits(DOROST, 25), false);
});

Deno.test("foldName drops diacritics, case and extra spaces", () => {
  assertEquals(foldName("  Šárka   Čermáková "), "sarka cermakova");
});

Deno.test("clubMatches: a team is its club plus a letter", () => {
  assertEquals(clubMatches("TJ Sokol Rudná", "TJ Sokol Rudná A"), true);
  assertEquals(clubMatches("TJ Sokol Rudná", "TJ Sokol Rudná"), true);
  assertEquals(clubMatches("TJ Sokol Rudná", "Sokol Rudná"), true);
  assertEquals(clubMatches("TJ Jiskra Hylváty", "TJ Sokol Rudná A"), false);
  assertEquals(clubMatches("", "TJ Sokol Rudná"), false);
  assertEquals(clubMatches("TJ Sokol Rudná", ""), false);
});

// ------------------------------------------------ a match's player (his page)

const SOKOL = "TJ Sokol Rudná";

Deno.test("site player: a senior father and his son of one name in one club, told apart by category", () => {
  const rows = [
    row("Jan Novák", SOKOL, "100", SENIOR),
    row("Jan Novák", SOKOL, "200", MUZI),
  ];
  assertEquals(
    pickForSitePlayer(rows, "Jan Novák", { club: SOKOL, age: 66 }, "TJ Sokol Rudná A"),
    { status: "found", regnum: "100", gender: null },
  );
  assertEquals(
    pickForSitePlayer(rows, "Jan Novák", { club: SOKOL, age: 31 }, "TJ Sokol Rudná A"),
    { status: "found", regnum: "200", gender: null },
  );
});

Deno.test("site player: two men of one name, club and category are not guessed", () => {
  const rows = [
    row("Jan Novák", SOKOL, "100", MUZI),
    row("Jan Novák", SOKOL, "200", MUZI),
  ];
  assertEquals(
    pickForSitePlayer(rows, "Jan Novák", { club: SOKOL, age: 55 }, ""),
    { status: "ambiguous", gender: null },
  );
});

Deno.test("site player: a year past the category's edge is the same person, two is not", () => {
  const rows = [row("Jan Novák", SOKOL, "100", SENIOR)];
  assertEquals(
    pickForSitePlayer(rows, "Jan Novák", { club: SOKOL, age: 59 }, ""),
    { status: "found", regnum: "100", gender: null },
  );
  assertEquals(
    pickForSitePlayer(rows, "Jan Novák", { club: SOKOL, age: 58 }, ""),
    { status: "none" },
  );
});

Deno.test("site player: a namesake of another category is nobody he is", () => {
  const rows = [row("Jan Novák", "KK Jihlava", "100", DOROST)];
  assertEquals(
    pickForSitePlayer(rows, "Jan Novák", { club: SOKOL, age: 45 }, ""),
    { status: "none" },
  );
});

Deno.test("site player: a namesake without a category is not taken for him", () => {
  const rows = [row("Jan Novák", SOKOL, "100", null)];
  assertEquals(
    pickForSitePlayer(rows, "Jan Novák", { club: SOKOL, age: 45 }, ""),
    { status: "none" },
  );
});

Deno.test("site player: a loan player (another club) of his category is still himself", () => {
  const rows = [row("Jan Novák", "KK Jihlava", "100", MUZI)];
  assertEquals(
    pickForSitePlayer(rows, "Jan Novák", { club: SOKOL, age: 45 }, ""),
    { status: "found", regnum: "100", gender: null },
  );
});

Deno.test("site player: two registrations of one category, the page's club decides", () => {
  const rows = [
    row("Pavel Strnad", "TJ Sokol Rudná", "787", MUZI),
    row("Pavel Strnad", "TJ Jiskra Hylváty", "18424", MUZI),
  ];
  assertEquals(
    pickForSitePlayer(rows, "Pavel Strnad", { club: "TJ Sokol Rudná", age: 45 }, ""),
    { status: "found", regnum: "787", gender: null },
  );
  assertEquals(
    pickForSitePlayer(rows, "Pavel Strnad", { club: "KK Jihlava", age: 45 }, "KK Jihlava A"),
    { status: "ambiguous", gender: null },
  );
});

Deno.test("site player: with no age on the page, the club must fit", () => {
  const one = [row("Jan Novák", "KK Jihlava", "100", MUZI)];
  assertEquals(
    pickForSitePlayer(one, "Jan Novák", { club: SOKOL, age: null }, ""),
    { status: "ambiguous", gender: null },
  );
  assertEquals(
    pickForSitePlayer(one, "Jan Novák", { club: "KK Jihlava", age: null }, ""),
    { status: "found", regnum: "100", gender: null },
  );
});

Deno.test("site player: the team stands in for a page without a club", () => {
  const rows = [
    row("Jan Novák", SOKOL, "100", MUZI),
    row("Jan Novák", "KK Jihlava", "200", MUZI),
  ];
  assertEquals(
    pickForSitePlayer(rows, "Jan Novák", { club: null, age: 45 }, "TJ Sokol Rudná A"),
    { status: "found", regnum: "100", gender: null },
  );
});

Deno.test("site player: only exact names count, without diacritics too", () => {
  assertEquals(
    pickForSitePlayer([row("Pavel Strnadel", SOKOL, "1", MUZI)], "Pavel Strnad", { club: SOKOL, age: 45 }, ""),
    { status: "none" },
  );
  assertEquals(
    pickForSitePlayer([row("Šárka Čermáková", SOKOL, "9", MUZI)], "Sarka Cermakova", { club: SOKOL, age: 30 }, ""),
    { status: "found", regnum: "9", gender: null },
  );
});

// ------------------------------------------- a match player's gender (0078)

Deno.test("site player: found carries his rows' gender, null when they disagree", () => {
  assertEquals(
    pickForSitePlayer(
      [row("Jana Nováková", SOKOL, "100", MUZI, "f")],
      "Jana Nováková",
      { club: SOKOL, age: 40 },
      "",
    ),
    { status: "found", regnum: "100", gender: "f" },
  );
  // Two rows of one number, the club deciding: only that number's rows count.
  assertEquals(
    pickForSitePlayer(
      [row("Jan Novák", SOKOL, "100", MUZI, "m"), row("Jan Novák", "KK Jihlava", "200", MUZI, "f")],
      "Jan Novák",
      { club: SOKOL, age: 40 },
      "",
    ),
    { status: "found", regnum: "100", gender: "m" },
  );
  assertEquals(
    pickForSitePlayer(
      [row("Jan Novák", SOKOL, "100", MUZI, "m", "a"), row("Jan Novák", SOKOL, "100", MUZI, null, "b")],
      "Jan Novák",
      { club: SOKOL, age: 40 },
      "",
    ),
    { status: "found", regnum: "100", gender: null },
  );
});

Deno.test("site player: ambiguous for want of a club still tells a gender all candidates share", () => {
  // One number, no age on the page, a club that does not fit.
  assertEquals(
    pickForSitePlayer([row("Jana Nováková", "KK Jihlava", "100", MUZI, "f")], "Jana Nováková", { club: SOKOL, age: null }, ""),
    { status: "ambiguous", gender: "f" },
  );
  // Several numbers and no age: every row of the name is a candidate.
  assertEquals(
    pickForSitePlayer(
      [row("Jan Novák", SOKOL, "100", MUZI, "m"), row("Jan Novák", SOKOL, "200", SENIOR, "m")],
      "Jan Novák",
      { club: null, age: null },
      "",
    ),
    { status: "ambiguous", gender: "m" },
  );
  assertEquals(
    pickForSitePlayer(
      [row("Jan Novák", SOKOL, "100", MUZI, "m"), row("Jan Novák", SOKOL, "200", SENIOR, "f")],
      "Jan Novák",
      { club: null, age: null },
      "",
    ),
    { status: "ambiguous", gender: null },
  );
});

Deno.test("site player: ambiguous within his age category counts only that category's genders", () => {
  const rows = [
    row("Jan Novák", SOKOL, "100", MUZI, "m"),
    row("Jan Novák", SOKOL, "200", MUZI, "m"),
    // Filtered out by the age: her gender does not spoil theirs.
    row("Jan Novák", SOKOL, "300", DOROST, "f"),
  ];
  assertEquals(
    pickForSitePlayer(rows, "Jan Novák", { club: SOKOL, age: 40 }, ""),
    { status: "ambiguous", gender: "m" },
  );
  assertEquals(
    pickForSitePlayer(
      [row("Jan Novák", SOKOL, "100", MUZI, "m"), row("Jan Novák", SOKOL, "200", MUZI, null)],
      "Jan Novák",
      { club: SOKOL, age: 40 },
      "",
    ),
    { status: "ambiguous", gender: null },
  );
});

Deno.test("site player: none has no gender", () => {
  assertEquals(
    pickForSitePlayer([row("Jan Novák", SOKOL, "100", DOROST, "m")], "Jan Novák", { club: SOKOL, age: 40 }, ""),
    { status: "none" },
  );
});

Deno.test("needsGender: unknown, and never asked or asked a week ago or more", () => {
  const now = new Date("2026-10-15T12:00:00Z");
  assertEquals(GENDER_RETRY_DAYS, 7);
  assertEquals(needsGender({ gender: null, gender_checked_at: null }, now), true);
  assertEquals(needsGender({ gender: "m", gender_checked_at: null }, now), false);
  assertEquals(needsGender({ gender: "f", gender_checked_at: "2020-01-01T00:00:00Z" }, now), false);
  assertEquals(
    needsGender({ gender: null, gender_checked_at: "2026-10-08T12:00:01Z" }, now),
    false,
    "a second short of a week",
  );
  assertEquals(needsGender({ gender: null, gender_checked_at: "2026-10-08T12:00:00Z" }, now), true);
  assertEquals(needsGender({ gender: null, gender_checked_at: "nonsense" }, now), true);
});

Deno.test("genderForFound: the gender of the rows with the stored number, nobody else's", () => {
  const rows = [
    row("Jan Novák", SOKOL, "100", SENIOR, "m"),
    row("Jan Novák", "KK Jihlava", "200", MUZI, "f"),
  ];
  assertEquals(genderForFound(rows, "100"), "m");
  assertEquals(genderForFound(rows, "200"), "f");
  assertEquals(genderForFound(rows, "300"), null, "the number is not on the page any more");
  assertEquals(genderForFound([row("Jan Novák", SOKOL, "100", SENIOR, null)], "100"), null);
  assertEquals(genderForFound([], "100"), null);
});

Deno.test("genderAction: a found player's gender alone, an unsettled one resolved again, the rest left", () => {
  const now = new Date("2026-10-15T12:00:00Z");
  const week = 7 * 24 * 3600e3;
  const cached = (
    status: string,
    looked_up_at: string,
    gender: string | null = null,
    gender_checked_at: string | null = null,
  ) => ({ status, looked_up_at, gender, gender_checked_at });
  assertEquals(genderAction(undefined, now, week), "resolve", "nobody asked yet");
  assertEquals(genderAction(cached("found", "2026-01-01T00:00:00Z"), now, week), "gender");
  assertEquals(
    genderAction(cached("found", "2026-10-15T11:00:00Z"), now, week),
    "gender",
    "however fresh the number",
  );
  assertEquals(genderAction(cached("found", "2026-01-01T00:00:00Z", "m"), now, week), "skip");
  assertEquals(
    genderAction(cached("found", "2026-01-01T00:00:00Z", null, "2026-10-14T00:00:00Z"), now, week),
    "skip",
    "asked yesterday",
  );
  assertEquals(
    genderAction(cached("found", "2026-01-01T00:00:00Z", null, "2026-10-01T00:00:00Z"), now, week),
    "gender",
    "asked two weeks ago",
  );
  assertEquals(genderAction(cached("none", "2026-10-01T00:00:00Z"), now, week), "resolve");
  assertEquals(genderAction(cached("ambiguous", "2026-10-01T00:00:00Z"), now, week), "resolve");
  assertEquals(
    genderAction(cached("ambiguous", "2026-10-14T00:00:00Z"), now, week),
    "skip",
    "settled for a week yet",
  );
  assertEquals(genderAction(cached("none", "2026-10-01T00:00:00Z", "f"), now, week), "skip");
});

// ------------------------------------------------------------- a profile

Deno.test("profile: one person of the club is filled in by itself", () => {
  const rows = [
    row("Jan Novák", SOKOL, "100", SENIOR),
    row("Jan Novák", "KK Jihlava", "200", MUZI),
  ];
  assertEquals(pickForProfile(rows, "Jan Novák", "Sokol Rudná"), {
    status: "found",
    regnum: "100",
  });
});

Deno.test("profile: father and son in the club — the player chooses", () => {
  const rows = [
    row("Jan Novák", SOKOL, "100", SENIOR),
    row("Jan Novák", SOKOL, "200", MUZI),
  ];
  assertEquals(pickForProfile(rows, "Jan Novák", SOKOL), {
    status: "choose",
    candidates: rows,
  });
});

Deno.test("profile: a namesake of another club or a profile without a club is not assumed", () => {
  const rows = [row("Jan Novák", "KK Jihlava", "200", MUZI)];
  assertEquals(pickForProfile(rows, "Jan Novák", SOKOL), {
    status: "choose",
    candidates: rows,
  });
  assertEquals(pickForProfile(rows, "Jan Novák", ""), {
    status: "choose",
    candidates: rows,
  });
});

Deno.test("profile: nobody of that name is none", () => {
  assertEquals(
    pickForProfile([row("Jan Novák", SOKOL, "1")], "Petr Svoboda", SOKOL),
    { status: "none" },
  );
});

// -------------------------------------------------------------- the sites

Deno.test("parseRows keeps only id, name, club, category, gender and number; skips archived and odd numbers", () => {
  const rows = parseRows({
    data: [
      {
        id: 7113,
        state: "active",
        gender: 1,
        name: "Pavel",
        surname: "Strnad",
        mlst: "secret",
        ageCategory: "senioři, seniorky",
        clubId: 1,
        club: "TJ Sokol Rudná",
        registrationNumber: "787",
        registrationTo: "2027-06-30",
        functions: "",
      },
      { id: 8, state: "carence", gender: 2, name: "New", surname: "Transfer", club: "TJ", registrationNumber: "4", ageCategory: "muži, ženy" },
      { id: 3, state: "archived", name: "Old", surname: "Member", club: "TJ", registrationNumber: "3" },
      { id: 4, name: "No", surname: "Number", club: "TJ", registrationNumber: "" },
      { id: 6, name: "Bad", surname: "Number", club: "TJ", registrationNumber: "12a" },
      { id: 5, state: "active", name: "No", surname: "Category", club: "TJ", registrationNumber: "9", ageCategory: "" },
    ],
  });
  assertEquals(rows, [
    { id: "7113", name: "Pavel Strnad", club: "TJ Sokol Rudná", regnum: "787", category: SENIOR, categoryName: "senioři, seniorky", gender: "m" },
    { id: "8", name: "New Transfer", club: "TJ", regnum: "4", category: MUZI, categoryName: "muži, ženy", gender: "f" },
    { id: "5", name: "No Category", club: "TJ", regnum: "9", category: null, categoryName: "", gender: null },
  ]);
});

Deno.test("parseRows: the register's gender 1 is a man, 2 a woman, anything else unknown", () => {
  // The codes as the register's JSON gave them in October 2026 for Tomáš
  // (1) and Jana (2) Pavlů of SKK Veverky Brno; the ids and numbers here
  // are made up.
  const rows = parseRows({
    data: [
      { id: 1, state: "active", gender: 1, name: "Tomáš", surname: "Pavlů", club: "SKK Veverky Brno", registrationNumber: "11" },
      { id: 2, state: "active", gender: 2, name: "Jana", surname: "Pavlů", club: "SKK Veverky Brno", registrationNumber: "12" },
      { id: 3, state: "active", gender: 0, name: "A", surname: "Nula", club: "TJ", registrationNumber: "13" },
      { id: 4, state: "active", gender: 3, name: "B", surname: "Tři", club: "TJ", registrationNumber: "14" },
      { id: 5, state: "active", gender: "1", name: "C", surname: "Text", club: "TJ", registrationNumber: "15" },
      { id: 6, state: "active", gender: null, name: "D", surname: "Nic", club: "TJ", registrationNumber: "16" },
      { id: 7, state: "active", name: "E", surname: "Bez", club: "TJ", registrationNumber: "17" },
    ],
  });
  assertEquals(rows.map((r) => [r.name, r.gender]), [
    ["Tomáš Pavlů", "m"],
    ["Jana Pavlů", "f"],
    ["A Nula", null],
    ["B Tři", null],
    ["C Text", null],
    ["D Nic", null],
    ["E Bez", null],
  ]);
});

Deno.test("parseRows refuses an unfiltered answer (the whole register)", () => {
  const data = Array.from({ length: MAX_ROWS + 1 }, (_, i) => ({
    name: "A",
    surname: String(i),
    club: "TJ",
    registrationNumber: String(i + 1),
  }));
  try {
    parseRows({ data });
    throw new Error("should have thrown");
  } catch (e) {
    assertEquals((e as Error).message, "register: filter not applied");
  }
});

Deno.test("parseSitePlayer reads the club and the age off the page text", () => {
  const html = `<html><head><title>x</title></head><body><script>var a = "Věk: 99 let"</script>
    <h1>Profil hráče : Pavel Strnad</h1><dl><dt>Oddíl:</dt> <dd>TJ Sokol Rudná</dd>
    <dt>Věk:</dt><dd>59 let</dd><dt>Kategorie:</dt><dd>Dospělí</dd></dl></body></html>`;
  assertEquals(parseSitePlayer(html), { club: "TJ Sokol Rudná", age: 59 });
  assertEquals(parseSitePlayer("<body><p>nic</p></body>"), {
    club: null,
    age: null,
  });
});

Deno.test("isSiteSlug lets only the service's own slugs into a URL", () => {
  assertEquals(isSiteSlug("pavel-strnad"), true);
  assertEquals(isSiteSlug("jan-novak-2"), true);
  assertEquals(isSiteSlug("../etc/passwd"), false);
  assertEquals(isSiteSlug("a/b"), false);
  assertEquals(isSiteSlug(""), false);
  assertEquals(isSiteSlug("Pavel"), false);
});

/** Both sites as the real ones answer: the register's JSON list for a
 * fulltext query, the results service's player page. */
function sites(
  list: unknown,
  page: string,
  opts: { pageStatus?: number; listStatus?: number } = {},
): { fn: typeof fetch; calls: string[] } {
  const calls: string[] = [];
  const fn = ((input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    calls.push(url);
    if (!init?.signal) throw new Error(`no timeout on ${url}`);
    if (url.startsWith("https://vysledky.kuzelky.cz/")) {
      return Promise.resolve(new Response(page, { status: opts.pageStatus ?? 200 }));
    }
    return Promise.resolve(
      new Response(JSON.stringify(list), { status: opts.listStatus ?? 200 }),
    );
  }) as typeof fetch;
  return { fn, calls };
}

const PAGE =
  "<body><h1>Profil hráče : Pavel Strnad</h1> Oddíl: TJ Sokol Rudná Věk: 59 let Kategorie: Dospělí</body>";
const LIST = {
  data: [
    { id: 7113, state: "active", gender: 1, name: "Pavel", surname: "Strnad", club: "TJ Sokol Rudná", registrationNumber: "787", ageCategory: "muži, ženy" },
    { id: 31056, state: "active", gender: 1, name: "Pavel", surname: "Strnad", club: "TJ Jiskra Hylváty", registrationNumber: "18424", ageCategory: "muži, ženy" },
  ],
};

Deno.test("resolveSitePlayer: his page, then the register", async () => {
  const { fn, calls } = sites(LIST, PAGE);
  assertEquals(
    await resolveSitePlayer("Pavel Strnad", "pavel-strnad", "TJ Sokol Rudná A", fn),
    { status: "found", regnum: "787", gender: "m" },
  );
  assertEquals(calls[0], "https://vysledky.kuzelky.cz/detail-hrace/pavel-strnad");
});

Deno.test("a found player's gender: one register request by his name, his number's row", async () => {
  const { fn, calls } = sites(LIST, PAGE);
  assertEquals(genderForFound(await searchRegister("Pavel Strnad", fn), "18424"), "m");
  assertEquals(calls, [
    "https://evidence.kuzelky.cz/frontend-api/members?fulltext=Pavel%20Strnad",
  ]);
});

Deno.test("resolveSitePlayer: a bad slug asks nobody", async () => {
  const { fn, calls } = sites(LIST, PAGE);
  await assertRejects(
    () => resolveSitePlayer("Pavel Strnad", "../x", "", fn),
    Error,
    "bad slug",
  );
  assertEquals(calls.length, 0);
});

Deno.test("fetchSitePlayer: a failing page is an error, not a guess", async () => {
  const { fn } = sites(LIST, "", { pageStatus: 500 });
  await assertRejects(() => fetchSitePlayer("pavel-strnad", fn), Error, "HTTP 500");
});

Deno.test("resolveProfile: one fulltext request for the whole name", async () => {
  const { fn, calls } = sites(LIST, PAGE);
  assertEquals(await resolveProfile("Pavel Strnad", "Sokol Rudná", fn), {
    status: "found",
    regnum: "787",
  });
  assertEquals(calls, [
    "https://evidence.kuzelky.cz/frontend-api/members?fulltext=Pavel%20Strnad",
  ]);
});

Deno.test("resolveProfile: a failing register is an error, not a guess", async () => {
  const { fn } = sites({ data: [] }, PAGE, { listStatus: 503 });
  await assertRejects(() => resolveProfile("Pavel Strnad", "", fn), Error, "HTTP 503");
});

Deno.test("sharedNames: profiles of one name, whatever the case and accents", () => {
  assertEquals(
    sharedNames(["Jan Novák", "Petr Svoboda", "jan  novak", "Šárka Nová"]),
    new Set(["jan novak"]),
  );
  assertEquals(sharedNames(["Jan Novák", "Petr Svoboda"]), new Set());
});
