import { assertEquals } from "jsr:@std/assert@1";
import {
  deliverMessage,
  deliverReaction,
  type Email,
  type MessageDeps,
  reactionChange,
  type Recipient,
} from "./message_notify.ts";
import { resendBatch, resendOneOfBatch } from "./resend.ts";

const baseMessage = {
  id: "m1", tenant_id: "t1", kind: "message" as const, audience: "block" as const,
  author_id: "author", author_role: "player" as const, on_date: "2026-10-02", block_id: "b1",
  title: null, body: "Přijďte dřív.", notify: true,
};

const recipient = (id: string, push: boolean) => ({
  id, email: `${id}@example.com`, fcm_token: push ? "tok" : null,
});

// The message's author as notify loads it for a reaction: a recipient plus
// the standing the read rule checks (baseMessage is in alley t1).
const author = (status = "approved", role = "player", tenant = "t1") => ({
  ...recipient("author", true), status, role, tenant_id: tenant,
});

// Recording fakes for deliverMessage's deps: a recipient with a token is
// pushed, the rest are e-mailed; pushes, e-mail batches and pauses land in
// the returned logs. An override replaces its fake.
function fakeDeps(overrides: Partial<MessageDeps> = {}) {
  const pushed: { id: string; title: string; body: string; data?: Record<string, string> }[] =
    [];
  const batches: Email[][] = [];
  const batchKeys: string[] = [];
  const singles: { to: string; key: string }[] = [];
  const pauses: number[] = [];
  const deps: MessageDeps = {
    byPush: (r: Recipient) => r.fcm_token != null,
    push: (r, title, body, opts) => {
      pushed.push({ id: r.id, title, body, data: opts.data });
      return Promise.resolve("delivered");
    },
    sendEmails: (emails, key) => {
      batches.push(emails);
      batchKeys.push(key);
      return Promise.resolve("delivered");
    },
    sendEmail: (email, key) => {
      singles.push({ to: email.to, key });
      return Promise.resolve("delivered");
    },
    reactLink: (u, reaction) => Promise.resolve(`https://x/react?t=${u}-${reaction}`),
    pause: (ms) => {
      pauses.push(ms);
      return Promise.resolve();
    },
    ...overrides,
  };
  return { deps, pushed, batches, batchKeys, singles, pauses };
}

// Runs [body] with console.error recorded instead of printed.
async function withErrorsLogged(body: () => Promise<void>): Promise<unknown[][]> {
  const logged: unknown[][] = [];
  const error = console.error;
  console.error = (...args: unknown[]) => {
    logged.push(args);
  };
  try {
    await body();
  } finally {
    console.error = error;
  }
  return logged;
}

// A full message_recipients row, as the webhook's `record` carries it.
const row = (reaction: "up" | "down" | null, reply: string | null) => ({
  message_id: "m1", user_id: "p1", reaction, reply,
});

Deno.test("reactionChange: null unless reaction or reply changed to non-null", () => {
  assertEquals(reactionChange({ reaction: null, reply: null }, row("up", null)),
    { reaction: "up", reply: null });
  assertEquals(reactionChange({ reaction: "up", reply: null }, row("up", "ok")),
    { reaction: "up", reply: "ok" });
  // A reply with no chip pressed still tells the author.
  assertEquals(reactionChange({ reaction: null, reply: null }, row(null, "Přijdu.")),
    { reaction: null, reply: "Přijdu." });
  // Clearing everything is not worth a push.
  assertEquals(reactionChange({ reaction: "up", reply: null }, row(null, null)), null);
  assertEquals(reactionChange({ reaction: null, reply: null }, row(null, null)), null);
  // Nothing changed (a read_at-only UPDATE never reaches here, but be safe).
  assertEquals(reactionChange({ reaction: "up", reply: "ok" }, row("up", "ok")), null);
});

Deno.test("deliverMessage: notify=false sends nothing", async () => {
  const { deps, pushed, batches } = fakeDeps();
  const n = await deliverMessage(
    { ...baseMessage, notify: false },
    { authorName: "Bára Kantýnská", authorIsAdmin: false, context: "pá 2. 10. · 16:00–17:00" },
    [recipient("p1", true), recipient("e1", false)],
    deps,
  );
  assertEquals(n, 0);
  assertEquals(pushed, []);
  assertEquals(batches, []);
});

Deno.test("deliverMessage: pushes go one at a time", async () => {
  // p1's push settles only on a later timer tick: a Promise.all fan-out
  // would start p2 before p1 ends.
  const log: string[] = [];
  const { deps, batches } = fakeDeps({
    push: (r) => {
      log.push(`start ${r.id}`);
      return new Promise((resolve) =>
        setTimeout(() => {
          log.push(`end ${r.id}`);
          resolve("delivered");
        }, r.id === "p1" ? 5 : 0)
      );
    },
  });
  const n = await deliverMessage(
    baseMessage,
    { authorName: "Bára Kantýnská", authorIsAdmin: false, context: "pá 2. 10. · 16:00–17:00" },
    [recipient("p1", true), recipient("p2", true)],
    deps,
  );
  assertEquals(n, 2);
  assertEquals(log, ["start p1", "end p1", "start p2", "end p2"]);
  assertEquals(batches, []);
});

Deno.test("deliverMessage: e-mails go out in one Resend batch per 100, not one request each", async () => {
  // A 150-player notice by e-mail is two requests, far under Resend's
  // per-second rate limit however it is set — sent one by one, it would
  // trip it (a 429 is not retried by anyone).
  const { deps, pushed, batches, batchKeys, pauses } = fakeDeps();
  const mailed = Array.from({ length: 150 }, (_, i) => recipient(`e${i}`, false));
  let n = 0;
  const logged = await withErrorsLogged(async () => {
    n = await deliverMessage(
      baseMessage,
      { authorName: "Bára Kantýnská", authorIsAdmin: false, context: null },
      [recipient("p0", true), ...mailed, { id: "x", email: "", fcm_token: null }],
      deps,
    );
  });
  assertEquals(pushed.map((p) => p.id), ["p0"]);
  assertEquals(batches.map((b) => b.length), [100, 50]);
  assertEquals(batches.flat().map((e) => e.to), mailed.map((r) => r.email));
  // Each batch under its own idempotency key: the message and the batch.
  assertEquals(batchKeys, ["message/m1/0", "message/m1/1"]);
  // Each e-mail carries its own recipient's 👍/👎 links.
  const e7 = batches[0][7];
  assertEquals(e7.html.includes("react?t=e7-up"), true);
  assertEquals(e7.html.includes("react?t=e7-down"), true);
  assertEquals(e7.subject, pushed[0].title);
  // No address and no token (x): nothing to send it by — logged, not
  // counted, and kept out of the batch.
  assertEquals(n, 151);
  assertEquals(logged.length, 1);
  assertEquals(String(logged[0][0]).includes("x"), true);
  assertEquals(pauses, []);
});

Deno.test("deliverMessage: a batch Resend refused as busy is tried once more after a pause", async () => {
  // Busy now (a 429 from other traffic in the same second), fine a
  // second later.
  const calls: Email[][] = [];
  const keys: string[] = [];
  const answers = ["retry", "delivered"] as const;
  const first = fakeDeps({
    sendEmails: (emails, key) => {
      calls.push(emails);
      keys.push(key);
      return Promise.resolve(answers[calls.length - 1]);
    },
  });
  const logged = await withErrorsLogged(async () => {
    await deliverMessage(baseMessage,
      { authorName: "Bára Kantýnská", authorIsAdmin: false, context: null },
      [recipient("e1", false), recipient("e2", false)], first.deps);
  });
  assertEquals(calls.length, 2);
  assertEquals(calls[1], calls[0]);
  // The retry reuses the key: a batch Resend took before a gateway's 5xx
  // is answered from Resend's record, not sent to everyone twice.
  assertEquals(keys, ["message/m1/0", "message/m1/0"]);
  assertEquals(first.pauses, [1000]);
  assertEquals(logged, []);

  // Still busy: one more try only, then logged — no loop.
  let tries = 0;
  const busy = fakeDeps({
    sendEmails: () => {
      tries++;
      return Promise.resolve("retry");
    },
  });
  const loggedBusy = await withErrorsLogged(async () => {
    await deliverMessage(baseMessage,
      { authorName: "Bára Kantýnská", authorIsAdmin: false, context: null },
      [recipient("e1", false)], busy.deps);
  });
  assertEquals(tries, 2);
  assertEquals(busy.pauses, [1000]);
  assertEquals(loggedBusy.length, 1);
  assertEquals(String(loggedBusy[0][0]).includes("m1"), true);
});

Deno.test("deliverMessage: a batch that throws is logged and the next one still goes", async () => {
  const sizes: number[] = [];
  const { deps } = fakeDeps({
    sendEmails: (emails) => {
      sizes.push(emails.length);
      return sizes.length === 1
        ? Promise.reject(new TypeError("connection reset"))
        : Promise.resolve("delivered");
    },
  });
  const logged = await withErrorsLogged(async () => {
    await deliverMessage(baseMessage,
      { authorName: "Bára Kantýnská", authorIsAdmin: false, context: null },
      Array.from({ length: 101 }, (_, i) => recipient(`e${i}`, false)), deps);
  });
  assertEquals(sizes, [100, 1]);
  assertEquals(logged.length, 1);
});

Deno.test("deliverMessage: a batch refused as invalid goes out one by one, paced", async () => {
  // Resend's strict batch validation fails all 100 over one malformed
  // address; alone, only that one fails. A busy single is tried once
  // more; a refused or throwing one is logged and the rest still go.
  const { deps, batches, singles, pauses } = fakeDeps({
    sendEmails: (emails) => {
      batches.push(emails);
      return Promise.resolve("invalid");
    },
  });
  const tries = new Map<string, number>();
  deps.sendEmail = (email, key) => {
    singles.push({ to: email.to, key });
    const n = (tries.get(email.to) ?? 0) + 1;
    tries.set(email.to, n);
    if (email.to === "e1@example.com") return Promise.resolve("undeliverable");
    if (email.to === "e2@example.com") return Promise.reject(new TypeError("connection reset"));
    if (email.to === "e3@example.com" && n === 1) return Promise.resolve("retry");
    return Promise.resolve("delivered");
  };
  let n = 0;
  const logged = await withErrorsLogged(async () => {
    n = await deliverMessage(baseMessage,
      { authorName: "Bára Kantýnská", authorIsAdmin: false, context: null },
      ["e0", "e1", "e2", "e3", "e4"].map((id) => recipient(id, false)), deps);
  });
  assertEquals(batches.length, 1);
  assertEquals(singles, [
    { to: "e0@example.com", key: "message/m1/0/0" },
    { to: "e1@example.com", key: "message/m1/0/1" },
    { to: "e2@example.com", key: "message/m1/0/2" },
    { to: "e3@example.com", key: "message/m1/0/3" },
    { to: "e3@example.com", key: "message/m1/0/3" },
    { to: "e4@example.com", key: "message/m1/0/4" },
  ]);
  // 500 ms between singles (Resend's per-second limit), 1 s before e3's
  // one more try.
  assertEquals(pauses, [500, 500, 500, 1000, 500]);
  // Counted once each, as the batch they were.
  assertEquals(n, 5);
  // The fallback itself, e1 refused, e2 thrown.
  assertEquals(logged.length, 3);
  assertEquals(String(logged[1][0]).includes("e1@example.com"), true);
  assertEquals(String(logged[2][0]).includes("e2@example.com"), true);
});

Deno.test("deliverMessage: to the staff the author decides the title, not the audience", async () => {
  // An admin may write to „Správci“ or „Službě“ too: their push and e-mail
  // say „Zpráva od správce“ (the staff title by author_role), never that a
  // player wrote. A player (the duty included) stays „Zpráva od hráče: …“.
  const { deps, pushed, batches } = fakeDeps();
  const both = [recipient("p1", true), recipient("e1", false)];
  const context = "k tréninku pá 2. 10. · 16:00–17:00";
  for (const audience of ["admins", "duty"] as const) {
    await deliverMessage({ ...baseMessage, audience, author_role: "admin" },
      { authorName: "Adam Správce", authorIsAdmin: true, context }, both, deps);
    await deliverMessage({ ...baseMessage, audience, author_role: "player" },
      { authorName: "Petr Novák", authorIsAdmin: false, context }, both, deps);
  }
  assertEquals(pushed.map((p) => p.title), [
    "Zpráva od správce",
    "Zpráva od hráče: Petr Novák",
    "Zpráva od správce",
    "Zpráva od hráče: Petr Novák",
  ]);
  assertEquals(batches.map((b) => b[0].subject), pushed.map((p) => p.title));
  assertEquals(pushed[0].body, `Přijďte dřív.\n${context}`);
});

// Resend behind a fake fetch: the batch and each single answer [answer]'s
// status, error name and message (the name when left out); the requests
// land in the returned log.
function resendDeps(answer: (url: string, to: string[]) => [number, string, string?]) {
  const requests: { url: string; to: string[] }[] = [];
  const fetch = (url: string, init: RequestInit) => {
    const body = JSON.parse(String(init.body));
    const to = (Array.isArray(body) ? body : [body]).map((e: { to: string }) => e.to);
    requests.push({ url, to });
    const [status, name, message = name] = answer(url, to);
    const text = status < 300 ? "{}" : JSON.stringify({ statusCode: status, name, message });
    return Promise.resolve(new Response(text, { status }));
  };
  const config = { apiKey: "re_test", from: "Rezervátor <r@example.com>", fetch };
  const fake = fakeDeps({
    sendEmails: (emails, key) => resendBatch(emails, key, config),
    sendEmail: (email, key) => resendOneOfBatch(email, config, key),
  });
  return { ...fake, requests };
}

const fiveByMail = ["e0", "e1", "e2", "e3", "e4"].map((id) => recipient(id, false));
const single = "https://api.resend.com/emails";
const badFrom = "Invalid `from` field. The email address needs to follow the " +
  "`email@example.com` or `Name <email@example.com>` format.";
const badTo = badFrom.replace("`from`", "`to`");

Deno.test("deliverMessage: a refusal that is not about the address stops the one-by-one fallback", async () => {
  // A request Resend refuses whole (here a missing field) fails the batch
  // and every e-mail alone the same: after the first single says so, the
  // other four are not tried 500 ms apart, and the stop is logged once.
  const { deps, requests, pauses } = resendDeps(() => [422, "missing_required_field"]);
  let n = 0;
  const logged = await withErrorsLogged(async () => {
    n = await deliverMessage(baseMessage,
      { authorName: "Bára Kantýnská", authorIsAdmin: false, context: null }, fiveByMail, deps);
  });
  assertEquals(requests.map((r) => r.url), [`${single}/batch`, single]);
  assertEquals(pauses, []);
  assertEquals(n, 5);
  const stops = logged.filter((l) => String(l[0]).includes("not about the address"));
  assertEquals(stops.length, 1);
  assertEquals(String(stops[0][0]).includes("4 not sent"), true);
});

Deno.test("deliverMessage: Resend's validation_error naming `from` stops the fallback too", async () => {
  // A malformed RESEND_FROM, as Resend answers it today: a 400
  // validation_error whose message names the field — no error name of its
  // own. One batch request, one single, no pauses.
  const { deps, requests, pauses } = resendDeps(() => [400, "validation_error", badFrom]);
  const logged = await withErrorsLogged(async () => {
    await deliverMessage(baseMessage,
      { authorName: "Bára Kantýnská", authorIsAdmin: false, context: null }, fiveByMail, deps);
  });
  assertEquals(requests.map((r) => r.url), [`${single}/batch`, single]);
  assertEquals(pauses, []);
  assertEquals(logged.filter((l) => String(l[0]).includes("4 not sent")).length, 1);
});

Deno.test("deliverMessage: a first single refused over its own address does not stop the rest", async () => {
  // Resend's strict batch fails over e0's malformed address; alone, only
  // e0 fails, and the other four still go.
  const { deps, requests, pauses } = resendDeps((url, to) =>
    url.endsWith("/batch") || to[0] === "e0@example.com"
      ? [400, "validation_error", badTo]
      : [200, ""]
  );
  await withErrorsLogged(async () => {
    await deliverMessage(baseMessage,
      { authorName: "Bára Kantýnská", authorIsAdmin: false, context: null }, fiveByMail, deps);
  });
  assertEquals(requests.length, 6);
  assertEquals(pauses, [500, 500, 500, 500]);
});

Deno.test("deliverMessage: a failed push or link skips only that recipient", async () => {
  // A network error in one push (or an OAuth failure in FCM), or a link
  // that cannot be signed, must not cost everyone after it their one
  // attempt: pg_net does not retry the webhook.
  const { deps, pushed, batches } = fakeDeps({
    reactLink: (u, reaction) =>
      u === "p3"
        ? Promise.reject(new Error("sign failed"))
        : Promise.resolve(`https://x/react?t=${u}-${reaction}`),
  });
  const push = deps.push;
  deps.push = (r, title, body, opts) =>
    r.id === "p2" ? Promise.reject(new TypeError("connection reset")) : push(r, title, body, opts);
  let n = 0;
  const logged = await withErrorsLogged(async () => {
    n = await deliverMessage(
      baseMessage,
      { authorName: "Bára Kantýnská", authorIsAdmin: false, context: null },
      [recipient("p1", true), recipient("p2", true), recipient("p3", false), recipient("p4", false)],
      deps,
    );
  });
  assertEquals(pushed.map((p) => p.id), ["p1"]);
  assertEquals(batches.map((b) => b.map((e) => e.to)), [["p4@example.com"]]);
  // Attempted: p1, p2 (pushed, then failed) and p4; p3 never got to a send.
  assertEquals(n, 3);
  assertEquals(logged.length, 2);
  assertEquals(String(logged[0][0]).includes("p2"), true);
  assertEquals(String(logged[1][0]).includes("p3"), true);
});

Deno.test("deliverReaction: notifies the author once, with the text and reply", async () => {
  const sent: { to: string; title: string; body: string; data?: Record<string, string> }[] = [];
  const ok = await deliverReaction(
    { message_id: "m1", user_id: "p1", reaction: "up", reply: "Přijdu dřív." },
    { reaction: "up", reply: "Přijdu dřív." },
    { message: baseMessage, author: author(), reactorName: "Petr Novák" },
    (r, title, body, opts) => {
      sent.push({ to: r.id, title, body, data: opts.data });
      return Promise.resolve("delivered");
    },
  );
  assertEquals(ok, true);
  // The data carries the alley, so the app can tell a tap on another
  // alley's reaction (its account moved since) from its own.
  assertEquals(sent, [{
    to: "author",
    title: "Reakce na tvou zprávu",
    body: "Petr Novák: 👍 Přijdu dřív.",
    data: { kind: "message_reaction", message_id: "m1", tenant_id: "t1" },
  }]);
});

Deno.test("deliverReaction: an author who may no longer read the message hears nothing", async () => {
  // The read rule (can_read_message): an account set back to pending, set
  // as the kiosk or moved to another alley loses what it once got — the
  // reactor's name and reply must not reach it by push or e-mail either.
  for (const gone of [author("pending"), author("approved", "kiosk"), author("approved", "player", "t2")]) {
    let called = false;
    const ok = await deliverReaction(
      { message_id: "m1", user_id: "p1", reaction: "down", reply: "nestihnu, jsem nemocný" },
      { reaction: "down", reply: "nestihnu, jsem nemocný" },
      { message: baseMessage, author: gone, reactorName: "Petr" },
      () => { called = true; return Promise.resolve("delivered"); },
    );
    assertEquals(ok, false);
    assertEquals(called, false);
  }
  // An approved admin of the alley still hears.
  let heard = false;
  await deliverReaction(
    { message_id: "m1", user_id: "p1", reaction: "up", reply: null },
    { reaction: "up", reply: null },
    { message: baseMessage, author: author("approved", "admin"), reactorName: "Petr" },
    () => { heard = true; return Promise.resolve("delivered"); },
  );
  assertEquals(heard, true);
});

Deno.test("deliverReaction: a notice's reaction (should not happen, but stay safe) sends nothing", async () => {
  let called = false;
  const ok = await deliverReaction(
    { message_id: "m1", user_id: "p1", reaction: "up", reply: null },
    { reaction: "up", reply: null },
    { message: { ...baseMessage, kind: "notice" }, author: author(), reactorName: "Petr" },
    () => { called = true; return Promise.resolve("delivered"); },
  );
  assertEquals(ok, false);
  assertEquals(called, false);
});

Deno.test("deliverReaction: no author profile sends nothing", async () => {
  let called = false;
  const ok = await deliverReaction(
    { message_id: "m1", user_id: "p1", reaction: "up", reply: null },
    { reaction: "up", reply: null },
    { message: baseMessage, author: null, reactorName: "Petr" },
    () => { called = true; return Promise.resolve("delivered"); },
  );
  assertEquals(ok, false);
  assertEquals(called, false);
});

Deno.test("reactionChange: a half clear says nothing, a new chip does", () => {
  // Taking back the 👍 while the reply stays, or deleting the reply while
  // the 👍 stays: nothing new was said.
  assertEquals(reactionChange({ reaction: "up", reply: "ok" }, row(null, "ok")), null);
  assertEquals(reactionChange({ reaction: "up", reply: "ok" }, row("up", null)), null);
  // A blank reply is no reply.
  assertEquals(reactionChange({ reaction: null, reply: null }, row(null, "  ")), null);
  // Switching the chip is fresh; the answer carries the kept reply too.
  assertEquals(reactionChange({ reaction: "up", reply: "ok" }, row("down", "ok")),
    { reaction: "down", reply: "ok" });
  // No old_record at all (a partial webhook payload): the row's answer is new.
  assertEquals(reactionChange({}, row("up", null)), { reaction: "up", reply: null });
});

Deno.test("deliverMessage: texts, push data and e-mails by kind and audience", async () => {
  // Every run has one pushed (p1) and one e-mailed (e1) recipient.
  const { deps, pushed, batches } = fakeDeps();
  const both = [recipient("p1", true), recipient("e1", false)];
  const ctx = { authorName: "Bára Kantýnská", authorIsAdmin: true, context: "celý den pá 2. 10." };
  // Staff → players (an admin's day message).
  await deliverMessage({ ...baseMessage, audience: "day", block_id: null, author_role: "admin" },
    ctx, both, deps);
  // Player → staff.
  await deliverMessage({ ...baseMessage, audience: "admins" },
    { ...ctx, authorIsAdmin: false, context: null }, both, deps);
  // A notice: its title, the nástěnka link, no reaction links.
  await deliverMessage({ ...baseMessage, kind: "notice", audience: "all", on_date: null,
    block_id: null, title: "Brigáda", body: "V sobotu uklízíme." },
    ctx, both, deps);

  assertEquals(pushed[0].title, "Zpráva od správce");
  assertEquals(pushed[0].body, "Přijďte dřív.\ncelý den pá 2. 10.");
  assertEquals(pushed[0].data, { kind: "message", message_id: "m1", tenant_id: "t1" });
  const mail0 = batches[0][0];
  assertEquals(mail0.to, "e1@example.com");
  assertEquals(mail0.subject, "Zpráva od správce");
  assertEquals(mail0.html.includes("https://x/react?t=e1-up"), true);
  assertEquals(mail0.html.includes("https://x/react?t=e1-down"), true);
  assertEquals(mail0.html.includes("https://rezervator.online/#/zpravy/m1"), true);
  assertEquals(pushed[1].title, "Zpráva od hráče: Bára Kantýnská");
  assertEquals(pushed[1].body, "Přijďte dřív.");
  assertEquals(batches[1][0].subject, "Zpráva od hráče: Bára Kantýnská");
  assertEquals(pushed[2].title, "Brigáda");
  assertEquals(pushed[2].body, "V sobotu uklízíme.");
  assertEquals(pushed[2].data, { kind: "notice", message_id: "m1", tenant_id: "t1" });
  assertEquals(batches[2][0].subject, "Brigáda");
  assertEquals(batches[2][0].html.includes("https://rezervator.online/#/nastenka/m1"), true);
  assertEquals(batches[2][0].html.includes("react?t="), false);
});
