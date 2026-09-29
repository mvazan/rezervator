import {
  assert,
  assertEquals,
  assertMatch,
  assertStringIncludes,
} from "jsr:@std/assert@1";
import {
  CANCEL_PAGE,
  CANCEL_STAVS,
  type CancelDeps,
  handleCancel,
  KDY_PATTERN,
  slotLabel,
} from "./cancel_flow.ts";
import { signCancelToken } from "./cancel_token.ts";

const SECRET = "test-secret";
const RID = "3f6b0a4e-1c2d-4e5f-8a9b-0c1d2e3f4a5b";
const FUNCTION_URL = "http://localhost/functions/v1/cancel";

type Fake = CancelDeps & { cancelCalls: string[] };

function fake(
  overrides: Partial<CancelDeps> & { cancelledAt?: string | null } = {},
): Fake {
  const cancelCalls: string[] = [];
  return {
    secret: SECRET,
    reservation: () =>
      Promise.resolve({
        date: "2026-07-13",
        lane: 2,
        block_id: "b1",
        cancelled_at: overrides.cancelledAt ?? null,
      }),
    block: () => Promise.resolve({ starts_at: "17:30:00", ends_at: "19:00:00" }),
    ...overrides,
    cancel: (rid) => {
      cancelCalls.push(rid);
      return overrides.cancel ? overrides.cancel(rid) : Promise.resolve(true);
    },
    cancelCalls,
  };
}

async function liveToken(): Promise<string> {
  return await signCancelToken(RID, Math.floor(Date.now() / 1000) + 3600, SECRET);
}

function call(method: string, token: string): Request {
  return new Request(`${FUNCTION_URL}?token=${encodeURIComponent(token)}`, {
    method,
  });
}

/** The page the response redirects to, as its query parameters. */
function landing(response: Response): URLSearchParams {
  const location = response.headers.get("location") ?? "";
  assert(
    location.startsWith(`${CANCEL_PAGE}?`),
    `expected a redirect to ${CANCEL_PAGE}, got ${location}`,
  );
  return new URL(location).searchParams;
}

Deno.test("GET with a live token lands on the confirmation, cancels nothing", async () => {
  const token = await liveToken();
  const deps = fake();
  const response = await handleCancel(call("GET", token), deps);
  assertEquals(response.status, 302);
  const page = landing(response);
  assertEquals(page.get("stav"), "potvrdit");
  assertEquals(page.get("token"), token);
  assertEquals(page.get("kdy"), "po 13.7. 17:30–19:00, dráha 2");
  assertEquals(deps.cancelCalls, []);
});

Deno.test("GET never cancels, whatever the token or reservation", async () => {
  const token = await liveToken();
  const expired = await signCancelToken(RID, 1, SECRET);
  const cases: Array<[string, Fake]> = [
    [token, fake()],
    [token, fake({ cancelledAt: "2026-07-01T10:00:00Z" })],
    [token, fake({ reservation: () => Promise.resolve(null) })],
    [expired, fake()],
    ["garbage", fake()],
  ];
  for (const [t, deps] of cases) {
    await handleCancel(call("GET", t), deps);
    assertEquals(deps.cancelCalls, []);
  }
});

Deno.test("POST cancels and lands on the result with 303", async () => {
  const deps = fake();
  const response = await handleCancel(call("POST", await liveToken()), deps);
  // 303: the browser follows with a GET, so reloading the result page never
  // re-submits the form.
  assertEquals(response.status, 303);
  const page = landing(response);
  assertEquals(page.get("stav"), "zruseno");
  assertEquals(page.get("kdy"), "po 13.7. 17:30–19:00, dráha 2");
  assertEquals(page.get("token"), null);
  assertEquals(deps.cancelCalls, [RID]);
});

Deno.test("POST that loses the race to another cancel lands on hotovo", async () => {
  const deps = fake({ cancel: () => Promise.resolve(false) });
  const page = landing(await handleCancel(call("POST", await liveToken()), deps));
  assertEquals(page.get("stav"), "hotovo");
});

Deno.test("POST on an already cancelled reservation does not write again", async () => {
  const deps = fake({ cancelledAt: "2026-07-01T10:00:00Z" });
  const page = landing(await handleCancel(call("POST", await liveToken()), deps));
  assertEquals(page.get("stav"), "hotovo");
  assertEquals(deps.cancelCalls, []);
});

Deno.test("POST that fails brings the button back with the token", async () => {
  const token = await liveToken();
  const deps = fake({ cancel: () => Promise.reject(new Error("db down")) });
  const originalError = console.error;
  console.error = () => {};
  try {
    const response = await handleCancel(call("POST", token), deps);
    assertEquals(response.status, 303);
    const page = landing(response);
    assertEquals(page.get("stav"), "chyba");
    assertEquals(page.get("token"), token);
    assertEquals(page.get("kdy"), "po 13.7. 17:30–19:00, dráha 2");
  } finally {
    console.error = originalError;
  }
});

Deno.test("bad, expired and orphaned tokens land on their own stav", async () => {
  const expired = await signCancelToken(RID, 1, SECRET);
  for (const method of ["GET", "POST"]) {
    assertEquals(
      landing(await handleCancel(call(method, "garbage"), fake())).get("stav"),
      "neplatny",
    );
    assertEquals(
      landing(await handleCancel(call(method, expired), fake())).get("stav"),
      "vyprselo",
    );
    const orphan = fake({ reservation: () => Promise.resolve(null) });
    assertEquals(
      landing(await handleCancel(call(method, await liveToken()), orphan))
        .get("stav"),
      "nenalezena",
    );
  }
});

Deno.test("a token signed with another secret is neplatny", async () => {
  const foreign = await signCancelToken(RID, 4102444800, "other-secret");
  const page = landing(await handleCancel(call("GET", foreign), fake()));
  assertEquals(page.get("stav"), "neplatny");
});

Deno.test("other methods are refused before anything is read", async () => {
  let read = false;
  const deps = fake({
    reservation: () => {
      read = true;
      return Promise.resolve(null);
    },
  });
  for (const method of ["HEAD", "PUT", "DELETE"]) {
    const response = await handleCancel(call(method, await liveToken()), deps);
    assertEquals(response.status, 405);
  }
  assertEquals(read, false);
  assertEquals(deps.cancelCalls, []);
});

Deno.test("slotLabel without a block drops the times", () => {
  assertEquals(
    slotLabel({ date: "2026-07-13", lane: 4 }, null),
    "po 13.7., dráha 4",
  );
});

Deno.test("every slotLabel shape passes the page's kdy filter", () => {
  // One date per weekday, single and double digits, both shapes.
  const dates = [
    "2026-07-12", "2026-07-13", "2026-07-14", "2026-07-15",
    "2026-07-16", "2026-07-17", "2026-07-18", "2026-12-31", "2026-01-01",
  ];
  for (const date of dates) {
    assertMatch(
      slotLabel({ date, lane: 12 }, { starts_at: "09:00:00", ends_at: "10:30:00" }),
      KDY_PATTERN,
    );
    assertMatch(slotLabel({ date, lane: 1 }, null), KDY_PATTERN);
  }
});

// web/cancel.html ships with the web build, this function with the backend:
// two deploys, one contract. These pin the page to it.
const html = Deno.readTextFileSync(
  new URL("../../../web/cancel.html", import.meta.url),
);

Deno.test("the page knows every stav the function redirects to", () => {
  for (const stav of CANCEL_STAVS) {
    assertStringIncludes(html, `${stav}: [`);
  }
});

Deno.test("the page filters kdy with the same pattern", () => {
  assertStringIncludes(html, `/${KDY_PATTERN.source}/`);
});

Deno.test("the page POSTs back to this project's cancel function", () => {
  const config = Deno.readTextFileSync(
    new URL("../../config.toml", import.meta.url),
  );
  const projectId = config.match(/^project_id = "([a-z0-9]+)"/m)?.[1];
  assert(projectId, "project_id not found in supabase/config.toml");
  assertStringIncludes(
    html,
    `"https://${projectId}.supabase.co/functions/v1/cancel"`,
  );
});

Deno.test("the page never submits on its own", () => {
  // Link scanners that run JavaScript must not be able to cancel either:
  // only a click on the button may send the POST.
  assert(
    !/\.submit\(|requestSubmit|\.click\(|fetch\(|sendBeacon|XMLHttpRequest|autofocus/
      .test(html),
  );
});
