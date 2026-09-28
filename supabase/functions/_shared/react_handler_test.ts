import { assertEquals } from "jsr:@std/assert@1";
import { handleReact, mayReact } from "./react_handler.ts";
import { signReactToken } from "./react_token.ts";

const SECRET = "test-secret";
const RESULT_PAGE = "https://rezervator.online/reakce.html";

function url(token: string): URL {
  return new URL(`https://x/react?t=${encodeURIComponent(token)}`);
}

Deno.test("a valid, existing recipient reacts and gets ok=1", async () => {
  const token = await signReactToken({ m: "m1", u: "u1", r: "up" }, SECRET);
  const written: { m: string; u: string; r: string }[] = [];
  const res = await handleReact("GET", url(token), {
    secret: SECRET,
    now: () => Date.now(),
    recipientMayReact: (m, u) => Promise.resolve(m === "m1" && u === "u1"),
    writeReaction: (m, u, r) => {
      written.push({ m, u, r });
      return Promise.resolve(true);
    },
    resultPage: RESULT_PAGE,
    logError: () => {},
  });
  assertEquals(res.status, 303);
  assertEquals(res.headers.get("location"), `${RESULT_PAGE}?ok=1`);
  assertEquals(written, [{ m: "m1", u: "u1", r: "up" }]);
});

Deno.test("a tampered token gets ok=0 and writes nothing", async () => {
  const token = await signReactToken({ m: "m1", u: "u1", r: "up" }, SECRET);
  const [payload, signature] = token.split(".");
  const flipped = (signature[0] === "A" ? "B" : "A") + signature.slice(1);
  let wrote = false;
  const res = await handleReact("GET", url(`${payload}.${flipped}`), {
    secret: SECRET,
    now: () => Date.now(),
    recipientMayReact: () => Promise.resolve(true),
    writeReaction: () => {
      wrote = true;
      return Promise.resolve(true);
    },
    resultPage: RESULT_PAGE,
    logError: () => {},
  });
  assertEquals(res.status, 303);
  assertEquals(res.headers.get("location"), `${RESULT_PAGE}?ok=0`);
  assertEquals(wrote, false);
});

Deno.test("an expired token gets ok=0", async () => {
  const issuedAt = Date.now();
  const token = await signReactToken({ m: "m1", u: "u1", r: "up" }, SECRET, issuedAt);
  const res = await handleReact("GET", url(token), {
    secret: SECRET,
    now: () => issuedAt + 31 * 86400_000,
    recipientMayReact: () => Promise.resolve(true),
    writeReaction: () => Promise.resolve(true),
    resultPage: RESULT_PAGE,
    logError: () => {},
  });
  assertEquals(res.headers.get("location"), `${RESULT_PAGE}?ok=0`);
});

Deno.test("a valid token for a recipient row that no longer exists gets ok=0", async () => {
  const token = await signReactToken({ m: "m1", u: "u1", r: "down" }, SECRET);
  let wrote = false;
  const res = await handleReact("GET", url(token), {
    secret: SECRET,
    now: () => Date.now(),
    recipientMayReact: () => Promise.resolve(false),
    writeReaction: () => {
      wrote = true;
      return Promise.resolve(true);
    },
    resultPage: RESULT_PAGE,
    logError: () => {},
  });
  assertEquals(res.headers.get("location"), `${RESULT_PAGE}?ok=0`);
  assertEquals(wrote, false);
});

Deno.test("a missing token gets ok=0", async () => {
  const res = await handleReact("GET", new URL("https://x/react"), {
    secret: SECRET,
    now: () => Date.now(),
    recipientMayReact: () => Promise.resolve(true),
    writeReaction: () => Promise.resolve(true),
    resultPage: RESULT_PAGE,
    logError: () => {},
  });
  assertEquals(res.headers.get("location"), `${RESULT_PAGE}?ok=0`);
});

Deno.test("no secret configured fails closed with 500 and logs why", async () => {
  const logged: string[] = [];
  const res = await handleReact("GET", url("whatever"), {
    secret: undefined,
    now: () => Date.now(),
    recipientMayReact: () => Promise.resolve(true),
    writeReaction: () => Promise.resolve(true),
    resultPage: RESULT_PAGE,
    logError: (message) => logged.push(message),
  });
  assertEquals(res.status, 500);
  assertEquals(logged, ["CANCEL_TOKEN_SECRET is not set"]);
});

Deno.test("a failed recipient lookup is logged and gets ok=0", async () => {
  const token = await signReactToken({ m: "m1", u: "u1", r: "up" }, SECRET);
  const logged: { message: string; detail: unknown }[] = [];
  const boom = new Error("PGRST301");
  let wrote = false;
  const res = await handleReact("GET", url(token), {
    secret: SECRET,
    now: () => Date.now(),
    recipientMayReact: () => Promise.reject(boom),
    writeReaction: () => {
      wrote = true;
      return Promise.resolve(true);
    },
    resultPage: RESULT_PAGE,
    logError: (message, detail) => logged.push({ message, detail }),
  });
  assertEquals(res.headers.get("location"), `${RESULT_PAGE}?ok=0`);
  assertEquals(wrote, false);
  assertEquals(logged, [{ message: "react lookup failed:", detail: boom }]);
});

Deno.test("a failed write is logged and gets ok=0", async () => {
  const token = await signReactToken({ m: "m1", u: "u1", r: "down" }, SECRET);
  const logged: { message: string; detail: unknown }[] = [];
  const boom = new Error("permission denied");
  const res = await handleReact("GET", url(token), {
    secret: SECRET,
    now: () => Date.now(),
    recipientMayReact: () => Promise.resolve(true),
    writeReaction: () => Promise.reject(boom),
    resultPage: RESULT_PAGE,
    logError: (message, detail) => logged.push({ message, detail }),
  });
  assertEquals(res.headers.get("location"), `${RESULT_PAGE}?ok=0`);
  assertEquals(logged, [{ message: "react write failed:", detail: boom }]);
});

Deno.test("an orphaned token or a write that matched no row logs nothing", async () => {
  const token = await signReactToken({ m: "m1", u: "u1", r: "up" }, SECRET);
  const logged: string[] = [];
  for (const [may, wrote] of [[false, true], [true, false]]) {
    const res = await handleReact("GET", url(token), {
      secret: SECRET,
      now: () => Date.now(),
      recipientMayReact: () => Promise.resolve(may),
      writeReaction: () => Promise.resolve(wrote),
      resultPage: RESULT_PAGE,
      logError: (message) => logged.push(message),
    });
    assertEquals(res.headers.get("location"), `${RESULT_PAGE}?ok=0`);
  }
  assertEquals(logged, []);
});

Deno.test("HEAD (a link scanner's probe) answers the same 303 and writes nothing", async () => {
  // A mail gateway that checks both 👍 and 👎 with HEAD must not record
  // 'up' then 'down' — each write would push the author.
  const token = await signReactToken({ m: "m1", u: "u1", r: "up" }, SECRET);
  const touched: string[] = [];
  const deps = {
    secret: SECRET,
    now: () => Date.now(),
    recipientMayReact: () => {
      touched.push("lookup");
      return Promise.resolve(true);
    },
    writeReaction: () => {
      touched.push("write");
      return Promise.resolve(true);
    },
    resultPage: RESULT_PAGE,
    logError: () => {},
  };
  const res = await handleReact("HEAD", url(token), deps);
  assertEquals(res.status, 303);
  assertEquals(res.headers.get("location"), `${RESULT_PAGE}?ok=1`);
  // A bad token still reads as one.
  const bad = await handleReact("HEAD", new URL("https://x/react?t=nonsense"), deps);
  assertEquals(bad.headers.get("location"), `${RESULT_PAGE}?ok=0`);
  assertEquals(touched, []);
});

Deno.test("any other method gets 405 and writes nothing", async () => {
  const token = await signReactToken({ m: "m1", u: "u1", r: "down" }, SECRET);
  let wrote = false;
  for (const method of ["POST", "PUT", "OPTIONS", "DELETE"]) {
    const res = await handleReact(method, url(token), {
      secret: SECRET,
      now: () => Date.now(),
      recipientMayReact: () => Promise.resolve(true),
      writeReaction: () => {
        wrote = true;
        return Promise.resolve(true);
      },
      resultPage: RESULT_PAGE,
      logError: () => {},
    });
    assertEquals(res.status, 405);
    assertEquals(res.headers.get("allow"), "GET, HEAD");
  }
  assertEquals(wrote, false);
});

// mayReact mirrors message_recipients_update_own + the select policy's
// alley check: the app path reacts only while an approved non-kiosk member
// of the row's alley, so the e-mail path must not do more.
const member = (status: string, role: string, tenant = "t1") => ({
  tenant_id: "t1",
  profiles: { status, role, tenant_id: tenant },
});

Deno.test("mayReact: an approved player or admin of the row's alley may react", () => {
  assertEquals(mayReact(member("approved", "player")), true);
  assertEquals(mayReact(member("approved", "admin")), true);
});

Deno.test("mayReact: no recipient row (orphaned token) may not react", () => {
  assertEquals(mayReact(null), false);
});

Deno.test("mayReact: an account set as the kiosk may not react", () => {
  assertEquals(mayReact(member("approved", "kiosk")), false);
});

Deno.test("mayReact: an account back to pending may not react", () => {
  assertEquals(mayReact(member("pending", "player")), false);
});

Deno.test("mayReact: an account now in another alley may not react", () => {
  assertEquals(mayReact(member("approved", "player", "t2")), false);
});

Deno.test("mayReact: a row without its profile may not react", () => {
  assertEquals(mayReact({ tenant_id: "t1", profiles: null }), false);
});

Deno.test("mayReact: reads the profile embedded as an object or a one-row array", () => {
  const profile = { status: "approved", role: "player", tenant_id: "t1" };
  assertEquals(mayReact({ tenant_id: "t1", profiles: [profile] }), true);
  assertEquals(mayReact({ tenant_id: "t1", profiles: [{ ...profile, role: "kiosk" }] }), false);
  assertEquals(mayReact({ tenant_id: "t1", profiles: [] }), false);
});
