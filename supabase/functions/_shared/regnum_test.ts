import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  ageFits,
  categoryOf,
  clubMatches,
  fetchSitePlayer,
  foldName,
  isSiteSlug,
  MAX_ROWS,
  parseRows,
  parseSitePlayer,
  pickForProfile,
  pickForSitePlayer,
  type RegisterRow,
  resolveProfile,
  resolveSitePlayer,
  sharedNames,
} from "./regnum.ts";

// The register's age categories, by index (see CATEGORIES in regnum.ts).
const DOROST = 2, MUZI = 4, SENIOR = 5;

const row = (
  name: string,
  club: string,
  regnum: string,
  category: number | null = MUZI,
  id = `id${regnum}`,
): RegisterRow => ({ id, name, club, regnum, category, categoryName: "" });

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
    { status: "found", regnum: "100" },
  );
  assertEquals(
    pickForSitePlayer(rows, "Jan Novák", { club: SOKOL, age: 31 }, "TJ Sokol Rudná A"),
    { status: "found", regnum: "200" },
  );
});

Deno.test("site player: two men of one name, club and category are not guessed", () => {
  const rows = [
    row("Jan Novák", SOKOL, "100", MUZI),
    row("Jan Novák", SOKOL, "200", MUZI),
  ];
  assertEquals(
    pickForSitePlayer(rows, "Jan Novák", { club: SOKOL, age: 55 }, ""),
    { status: "ambiguous" },
  );
});

Deno.test("site player: a year past the category's edge is the same person, two is not", () => {
  const rows = [row("Jan Novák", SOKOL, "100", SENIOR)];
  assertEquals(
    pickForSitePlayer(rows, "Jan Novák", { club: SOKOL, age: 59 }, ""),
    { status: "found", regnum: "100" },
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
    { status: "found", regnum: "100" },
  );
});

Deno.test("site player: two registrations of one category, the page's club decides", () => {
  const rows = [
    row("Pavel Strnad", "TJ Sokol Rudná", "787", MUZI),
    row("Pavel Strnad", "TJ Jiskra Hylváty", "18424", MUZI),
  ];
  assertEquals(
    pickForSitePlayer(rows, "Pavel Strnad", { club: "TJ Sokol Rudná", age: 45 }, ""),
    { status: "found", regnum: "787" },
  );
  assertEquals(
    pickForSitePlayer(rows, "Pavel Strnad", { club: "KK Jihlava", age: 45 }, "KK Jihlava A"),
    { status: "ambiguous" },
  );
});

Deno.test("site player: with no age on the page, the club must fit", () => {
  const one = [row("Jan Novák", "KK Jihlava", "100", MUZI)];
  assertEquals(
    pickForSitePlayer(one, "Jan Novák", { club: SOKOL, age: null }, ""),
    { status: "ambiguous" },
  );
  assertEquals(
    pickForSitePlayer(one, "Jan Novák", { club: "KK Jihlava", age: null }, ""),
    { status: "found", regnum: "100" },
  );
});

Deno.test("site player: the team stands in for a page without a club", () => {
  const rows = [
    row("Jan Novák", SOKOL, "100", MUZI),
    row("Jan Novák", "KK Jihlava", "200", MUZI),
  ];
  assertEquals(
    pickForSitePlayer(rows, "Jan Novák", { club: null, age: 45 }, "TJ Sokol Rudná A"),
    { status: "found", regnum: "100" },
  );
});

Deno.test("site player: only exact names count, without diacritics too", () => {
  assertEquals(
    pickForSitePlayer([row("Pavel Strnadel", SOKOL, "1", MUZI)], "Pavel Strnad", { club: SOKOL, age: 45 }, ""),
    { status: "none" },
  );
  assertEquals(
    pickForSitePlayer([row("Šárka Čermáková", SOKOL, "9", MUZI)], "Sarka Cermakova", { club: SOKOL, age: 30 }, ""),
    { status: "found", regnum: "9" },
  );
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

Deno.test("parseRows keeps only id, name, club, category and number; skips archived and odd numbers", () => {
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
      { id: 8, state: "carence", name: "New", surname: "Transfer", club: "TJ", registrationNumber: "4", ageCategory: "muži, ženy" },
      { id: 3, state: "archived", name: "Old", surname: "Member", club: "TJ", registrationNumber: "3" },
      { id: 4, name: "No", surname: "Number", club: "TJ", registrationNumber: "" },
      { id: 6, name: "Bad", surname: "Number", club: "TJ", registrationNumber: "12a" },
      { id: 5, state: "active", name: "No", surname: "Category", club: "TJ", registrationNumber: "9", ageCategory: "" },
    ],
  });
  assertEquals(rows, [
    { id: "7113", name: "Pavel Strnad", club: "TJ Sokol Rudná", regnum: "787", category: SENIOR, categoryName: "senioři, seniorky" },
    { id: "8", name: "New Transfer", club: "TJ", regnum: "4", category: MUZI, categoryName: "muži, ženy" },
    { id: "5", name: "No Category", club: "TJ", regnum: "9", category: null, categoryName: "" },
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
    { id: 7113, state: "active", name: "Pavel", surname: "Strnad", club: "TJ Sokol Rudná", registrationNumber: "787", ageCategory: "muži, ženy" },
    { id: 31056, state: "active", name: "Pavel", surname: "Strnad", club: "TJ Jiskra Hylváty", registrationNumber: "18424", ageCategory: "muži, ženy" },
  ],
};

Deno.test("resolveSitePlayer: his page, then the register", async () => {
  const { fn, calls } = sites(LIST, PAGE);
  assertEquals(
    await resolveSitePlayer("Pavel Strnad", "pavel-strnad", "TJ Sokol Rudná A", fn),
    { status: "found", regnum: "787" },
  );
  assertEquals(calls[0], "https://vysledky.kuzelky.cz/detail-hrace/pavel-strnad");
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
