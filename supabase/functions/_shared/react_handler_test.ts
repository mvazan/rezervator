import { assertEquals } from "jsr:@std/assert@1";
import { handleReact } from "./react_handler.ts";
import { signReactToken } from "./react_token.ts";

const SECRET = "test-secret";
const RESULT_PAGE = "https://rezervator.online/reakce.html";

function url(token: string): URL {
  return new URL(`https://x/react?t=${encodeURIComponent(token)}`);
}

Deno.test("a valid, existing recipient reacts and gets ok=1", async () => {
  const token = await signReactToken({ m: "m1", u: "u1", r: "up" }, SECRET);
  const written: { m: string; u: string; r: string }[] = [];
  const res = await handleReact(url(token), {
    secret: SECRET,
    now: () => Date.now(),
    recipientExists: (m, u) => Promise.resolve(m === "m1" && u === "u1"),
    writeReaction: (m, u, r) => {
      written.push({ m, u, r });
      return Promise.resolve(true);
    },
    resultPage: RESULT_PAGE,
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
  const res = await handleReact(url(`${payload}.${flipped}`), {
    secret: SECRET,
    now: () => Date.now(),
    recipientExists: () => Promise.resolve(true),
    writeReaction: () => {
      wrote = true;
      return Promise.resolve(true);
    },
    resultPage: RESULT_PAGE,
  });
  assertEquals(res.status, 303);
  assertEquals(res.headers.get("location"), `${RESULT_PAGE}?ok=0`);
  assertEquals(wrote, false);
});

Deno.test("an expired token gets ok=0", async () => {
  const issuedAt = Date.now();
  const token = await signReactToken({ m: "m1", u: "u1", r: "up" }, SECRET, issuedAt);
  const res = await handleReact(url(token), {
    secret: SECRET,
    now: () => issuedAt + 31 * 86400_000,
    recipientExists: () => Promise.resolve(true),
    writeReaction: () => Promise.resolve(true),
    resultPage: RESULT_PAGE,
  });
  assertEquals(res.headers.get("location"), `${RESULT_PAGE}?ok=0`);
});

Deno.test("a valid token for a recipient row that no longer exists gets ok=0", async () => {
  const token = await signReactToken({ m: "m1", u: "u1", r: "down" }, SECRET);
  let wrote = false;
  const res = await handleReact(url(token), {
    secret: SECRET,
    now: () => Date.now(),
    recipientExists: () => Promise.resolve(false),
    writeReaction: () => {
      wrote = true;
      return Promise.resolve(true);
    },
    resultPage: RESULT_PAGE,
  });
  assertEquals(res.headers.get("location"), `${RESULT_PAGE}?ok=0`);
  assertEquals(wrote, false);
});

Deno.test("a missing token gets ok=0", async () => {
  const res = await handleReact(new URL("https://x/react"), {
    secret: SECRET,
    now: () => Date.now(),
    recipientExists: () => Promise.resolve(true),
    writeReaction: () => Promise.resolve(true),
    resultPage: RESULT_PAGE,
  });
  assertEquals(res.headers.get("location"), `${RESULT_PAGE}?ok=0`);
});

Deno.test("no secret configured fails closed with 500", async () => {
  const res = await handleReact(url("whatever"), {
    secret: undefined,
    now: () => Date.now(),
    recipientExists: () => Promise.resolve(true),
    writeReaction: () => Promise.resolve(true),
    resultPage: RESULT_PAGE,
  });
  assertEquals(res.status, 500);
});
