import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  clubMatches,
  foldName,
  MAX_ROWS,
  parseRows,
  pick,
  resolveRegnum,
  type RegisterRow,
} from "./regnum.ts";

const row = (name: string, club: string, regnum: string): RegisterRow => ({
  name,
  club,
  regnum,
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

Deno.test("pick: one person of that name is the answer, whatever the club", () => {
  const rows = [row("Pavel Strnad", "TJ Sokol Rudná", "787")];
  assertEquals(pick(rows, "Pavel Strnad", "KK Jihlava A"), {
    status: "found",
    regnum: "787",
  });
});

Deno.test("pick: only exact names count (a fulltext hit on a longer name does not)", () => {
  const rows = [row("Pavel Strnadel", "TJ Sokol Rudná", "1")];
  assertEquals(pick(rows, "Pavel Strnad", ""), { status: "none" });
});

Deno.test("pick: two people of that name are told apart by the club", () => {
  const rows = [
    row("Pavel Strnad", "TJ Sokol Rudná", "787"),
    row("Pavel Strnad", "TJ Jiskra Hylváty", "18424"),
  ];
  assertEquals(pick(rows, "Pavel Strnad", "TJ Sokol Rudná A"), {
    status: "found",
    regnum: "787",
  });
  assertEquals(pick(rows, "Pavel Strnad", "Neznámý klub"), {
    status: "ambiguous",
  });
  assertEquals(pick(rows, "Pavel Strnad", ""), { status: "ambiguous" });
});

Deno.test("pick: the same number twice is still one person", () => {
  const rows = [
    row("Jan Novák", "TJ A", "5"),
    row("Jan Novák", "TJ B", "5"),
  ];
  assertEquals(pick(rows, "Jan Novák", ""), { status: "found", regnum: "5" });
});

Deno.test("pick: matches without diacritics", () => {
  const rows = [row("Šárka Čermáková", "TJ A", "9")];
  assertEquals(pick(rows, "Sarka Cermakova", ""), {
    status: "found",
    regnum: "9",
  });
});

Deno.test("parseRows keeps only name, club and number; skips archived and odd numbers", () => {
  const rows = parseRows({
    data: [
      {
        name: "Pavel",
        surname: "Strnad",
        club: "TJ Sokol Rudná",
        reg_no: 787,
        archived: 0,
        birth_no: "secret",
        birth_date: "1970-01-01",
      },
      { name: "Old", surname: "Member", club: "TJ", reg_no: 3, archived: 1 },
      { name: "No", surname: "Number", club: "TJ", reg_no: "" },
      { name: "Bad", surname: "Number", club: "TJ", reg_no: "12a" },
    ],
  });
  assertEquals(rows, [
    { name: "Pavel Strnad", club: "TJ Sokol Rudná", regnum: "787" },
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

/** A register that answers like the real one: a 302 with the filter cookie,
 * then the list for it. */
function register(
  list: unknown,
  opts: { cookie?: boolean; ok?: boolean } = {},
): { fn: typeof fetch; calls: { url: string; cookie: string | null }[] } {
  const calls: { url: string; cookie: string | null }[] = [];
  const fn = ((input: string | URL | Request, init?: RequestInit) => {
    const headers = new Headers(init?.headers);
    calls.push({ url: String(input), cookie: headers.get("Cookie") });
    if (init?.method === "POST") {
      const h = new Headers({ Location: "/m/clenove/" });
      if (opts.cookie !== false) h.append("Set-Cookie", "filter=%7B%7D; path=/");
      return Promise.resolve(new Response(null, { status: 302, headers: h }));
    }
    return Promise.resolve(
      new Response(JSON.stringify(list), { status: opts.ok === false ? 500 : 200 }),
    );
  }) as typeof fetch;
  return { fn, calls };
}

Deno.test("resolveRegnum: sets the filter, then reads the list with its cookie", async () => {
  const { fn, calls } = register({
    data: [
      { name: "Pavel", surname: "Strnad", club: "TJ Sokol Rudná", reg_no: 787 },
    ],
  });
  assertEquals(await resolveRegnum("Pavel Strnad", "TJ Sokol Rudná A", fn), {
    status: "found",
    regnum: "787",
  });
  assertEquals(calls.length, 2);
  assertEquals(calls[1].url.endsWith("?aajax=t"), true);
  assertEquals(calls[1].cookie, "filter=%7B%7D");
});

Deno.test("resolveRegnum: no filter cookie is an error, never a read of the list", async () => {
  const { fn, calls } = register({ data: [] }, { cookie: false });
  await assertRejects(
    () => resolveRegnum("Pavel Strnad", "", fn),
    Error,
    "no filter cookie",
  );
  assertEquals(calls.length, 1);
});

Deno.test("resolveRegnum: a failing list is an error", async () => {
  const { fn } = register({ data: [] }, { ok: false });
  await assertRejects(() => resolveRegnum("Pavel Strnad", "", fn), Error, "HTTP 500");
});
