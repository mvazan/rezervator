import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
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

const row = (
  name: string,
  club: string,
  regnum: string,
  age: number | null = 40,
  id = `id${regnum}`,
): RegisterRow => ({ id, name, club, regnum, age });

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

Deno.test("site player: father and son of one name in one club, told apart by age", () => {
  const rows = [
    row("Jan Novák", SOKOL, "100", 59),
    row("Jan Novák", SOKOL, "200", 31),
  ];
  assertEquals(
    pickForSitePlayer(rows, "Jan Novák", { club: SOKOL, age: 59 }, "TJ Sokol Rudná A"),
    { status: "found", regnum: "100" },
  );
  assertEquals(
    pickForSitePlayer(rows, "Jan Novák", { club: SOKOL, age: 31 }, "TJ Sokol Rudná A"),
    { status: "found", regnum: "200" },
  );
});

Deno.test("site player: one year of difference is the same person, two is not", () => {
  const rows = [row("Jan Novák", SOKOL, "100", 59)];
  assertEquals(
    pickForSitePlayer(rows, "Jan Novák", { club: SOKOL, age: 58 }, ""),
    { status: "found", regnum: "100" },
  );
  assertEquals(
    pickForSitePlayer(rows, "Jan Novák", { club: SOKOL, age: 57 }, ""),
    { status: "none" },
  );
});

Deno.test("site player: a namesake of another age is nobody he is", () => {
  const rows = [row("Jan Novák", "KK Jihlava", "100", 31)];
  assertEquals(
    pickForSitePlayer(rows, "Jan Novák", { club: SOKOL, age: 59 }, ""),
    { status: "none" },
  );
});

Deno.test("site player: a loan player (another club) of his age is still himself", () => {
  const rows = [row("Jan Novák", "KK Jihlava", "100", 59)];
  assertEquals(
    pickForSitePlayer(rows, "Jan Novák", { club: SOKOL, age: 59 }, ""),
    { status: "found", regnum: "100" },
  );
});

Deno.test("site player: two registrations of one age, the page's club decides", () => {
  const rows = [
    row("Pavel Strnad", "TJ Sokol Rudná", "787", 59),
    row("Pavel Strnad", "TJ Jiskra Hylváty", "18424", 59),
  ];
  assertEquals(
    pickForSitePlayer(rows, "Pavel Strnad", { club: "TJ Sokol Rudná", age: 59 }, ""),
    { status: "found", regnum: "787" },
  );
  assertEquals(
    pickForSitePlayer(rows, "Pavel Strnad", { club: "KK Jihlava", age: 59 }, "KK Jihlava A"),
    { status: "ambiguous" },
  );
});

Deno.test("site player: same name, same club, same age is not guessed", () => {
  const rows = [
    row("Jan Novák", SOKOL, "100", 40),
    row("Jan Novák", SOKOL, "200", 40),
  ];
  assertEquals(
    pickForSitePlayer(rows, "Jan Novák", { club: SOKOL, age: 40 }, ""),
    { status: "ambiguous" },
  );
});

Deno.test("site player: with no age on the page, the club must fit", () => {
  const one = [row("Jan Novák", "KK Jihlava", "100", 59)];
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
    row("Jan Novák", SOKOL, "100", 59),
    row("Jan Novák", "KK Jihlava", "200", 59),
  ];
  assertEquals(
    pickForSitePlayer(rows, "Jan Novák", { club: null, age: 59 }, "TJ Sokol Rudná A"),
    { status: "found", regnum: "100" },
  );
});

Deno.test("site player: only exact names count, without diacritics too", () => {
  assertEquals(
    pickForSitePlayer([row("Pavel Strnadel", SOKOL, "1", 59)], "Pavel Strnad", { club: SOKOL, age: 59 }, ""),
    { status: "none" },
  );
  assertEquals(
    pickForSitePlayer([row("Šárka Čermáková", SOKOL, "9", 30)], "Sarka Cermakova", { club: SOKOL, age: 30 }, ""),
    { status: "found", regnum: "9" },
  );
});

// ------------------------------------------------------------- a profile

Deno.test("profile: one person of the club is filled in by itself", () => {
  const rows = [
    row("Jan Novák", SOKOL, "100", 59),
    row("Jan Novák", "KK Jihlava", "200", 31),
  ];
  assertEquals(pickForProfile(rows, "Jan Novák", "Sokol Rudná"), {
    status: "found",
    regnum: "100",
  });
});

Deno.test("profile: father and son in the club — the player chooses", () => {
  const rows = [
    row("Jan Novák", SOKOL, "100", 59),
    row("Jan Novák", SOKOL, "200", 31),
  ];
  assertEquals(pickForProfile(rows, "Jan Novák", SOKOL), {
    status: "choose",
    candidates: rows,
  });
});

Deno.test("profile: a namesake of another club or a profile without a club is not assumed", () => {
  const rows = [row("Jan Novák", "KK Jihlava", "200", 31)];
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

Deno.test("parseRows keeps only id, name, club, age and number; skips archived and odd numbers", () => {
  const rows = parseRows({
    data: [
      {
        id: 7113,
        name: "Pavel",
        surname: "Strnad",
        club: "TJ Sokol Rudná",
        reg_no: 787,
        age: 59,
        archived: 0,
        birth_no: "secret",
        birth_date: "1970-01-01",
      },
      { name: "Old", surname: "Member", club: "TJ", reg_no: 3, archived: 1 },
      { name: "No", surname: "Number", club: "TJ", reg_no: "" },
      { name: "Bad", surname: "Number", club: "TJ", reg_no: "12a" },
      { id: 5, name: "No", surname: "Age", club: "TJ", reg_no: 9, age: "?" },
    ],
  });
  assertEquals(rows, [
    { id: "7113", name: "Pavel Strnad", club: "TJ Sokol Rudná", regnum: "787", age: 59 },
    { id: "5", name: "No Age", club: "TJ", regnum: "9", age: null },
  ]);
});

Deno.test("parseRows refuses an unfiltered answer (the whole register)", () => {
  const data = Array.from({ length: MAX_ROWS + 1 }, (_, i) => ({
    name: "A",
    surname: String(i),
    club: "TJ",
    reg_no: i + 1,
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

/** Both sites as the real ones answer: the register's 302 + cookie + list,
 * the results service's player page. */
function sites(
  list: unknown,
  page: string,
  opts: { cookie?: boolean; pageStatus?: number } = {},
): { fn: typeof fetch; calls: string[] } {
  const calls: string[] = [];
  const fn = ((input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    calls.push(url);
    if (url.startsWith("https://vysledky.kuzelky.cz/")) {
      return Promise.resolve(new Response(page, { status: opts.pageStatus ?? 200 }));
    }
    if (init?.method === "POST") {
      const h = new Headers({ Location: "/m/clenove/" });
      if (opts.cookie !== false) h.append("Set-Cookie", "filter=%7B%7D; path=/");
      return Promise.resolve(new Response(null, { status: 302, headers: h }));
    }
    return Promise.resolve(new Response(JSON.stringify(list)));
  }) as typeof fetch;
  return { fn, calls };
}

const PAGE =
  "<body><h1>Profil hráče : Pavel Strnad</h1> Oddíl: TJ Sokol Rudná Věk: 59 let Kategorie: Dospělí</body>";
const LIST = {
  data: [
    { id: 7113, name: "Pavel", surname: "Strnad", club: "TJ Sokol Rudná", reg_no: 787, age: 59 },
    { id: 31056, name: "Pavel", surname: "Strnad", club: "TJ Jiskra Hylváty", reg_no: 18424, age: 59 },
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

Deno.test("resolveProfile: sets the filter, then reads the list with its cookie", async () => {
  const { fn, calls } = sites(LIST, PAGE);
  assertEquals(await resolveProfile("Pavel Strnad", "Sokol Rudná", fn), {
    status: "found",
    regnum: "787",
  });
  assertEquals(calls.length, 2);
  assertEquals(calls[1].endsWith("?aajax=t"), true);
});

Deno.test("resolveProfile: no filter cookie is an error, never a read of the list", async () => {
  const { fn, calls } = sites({ data: [] }, PAGE, { cookie: false });
  await assertRejects(
    () => resolveProfile("Pavel Strnad", "", fn),
    Error,
    "no filter cookie",
  );
  assertEquals(calls.length, 1);
});

Deno.test("sharedNames: profiles of one name, whatever the case and accents", () => {
  assertEquals(
    sharedNames(["Jan Novák", "Petr Svoboda", "jan  novak", "Šárka Nová"]),
    new Set(["jan novak"]),
  );
  assertEquals(sharedNames(["Jan Novák", "Petr Svoboda"]), new Set());
});
