import { assertEquals } from "jsr:@std/assert@1";
import { deliverMessage, deliverReaction, reactionChange } from "./message_notify.ts";

const baseMessage = {
  id: "m1", tenant_id: "t1", kind: "message" as const, audience: "block" as const,
  author_id: "author", author_role: "player" as const, on_date: "2026-10-02", block_id: "b1",
  title: null, body: "Přijďte dřív.", notify: true,
};

const recipient = (id: string, push: boolean) => ({
  id, email: `${id}@example.com`, fcm_token: push ? "tok" : null,
});

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
  const sent: string[] = [];
  const n = await deliverMessage(
    { ...baseMessage, notify: false },
    { authorName: "Bára Kantýnská", authorIsAdmin: false, context: "pá 2. 10. · 16:00–17:00" },
    [recipient("p1", true)],
    { send: (r) => { sent.push(r.id); return Promise.resolve("delivered"); },
      reactLink: () => Promise.resolve("https://x/react?t=1") },
  );
  assertEquals(n, 0);
  assertEquals(sent, []);
});

Deno.test("deliverMessage: one send per recipient, sequential", async () => {
  const order: string[] = [];
  const n = await deliverMessage(
    baseMessage,
    { authorName: "Bára Kantýnská", authorIsAdmin: false, context: "pá 2. 10. · 16:00–17:00" },
    [recipient("p1", true), recipient("p2", false)],
    {
      send: (r, _title, _body, opts) => {
        order.push(r.id);
        if (r.id === "p2") {
          assertEquals(typeof opts.html, "string");
          assertEquals(opts.html!.includes("react?t="), true);
        }
        return Promise.resolve("delivered");
      },
      reactLink: (u, reaction) => Promise.resolve(`https://x/react?t=${u}-${reaction}`),
    },
  );
  assertEquals(n, 2);
  assertEquals(order, ["p1", "p2"]);
});

Deno.test("deliverReaction: notifies the author once, with the text and reply", async () => {
  let sent: { title: string; body: string } | null = null;
  const ok = await deliverReaction(
    { message_id: "m1", user_id: "p1", reaction: "up", reply: "Přijdu dřív." },
    { reaction: "up", reply: "Přijdu dřív." },
    { message: baseMessage, author: recipient("author", true), reactorName: "Petr Novák" },
    (_r, title, body) => { sent = { title, body }; return Promise.resolve("delivered"); },
  );
  assertEquals(ok, true);
  assertEquals(sent, { title: "Reakce na tvou zprávu", body: "Petr Novák: 👍 Přijdu dřív." });
});

Deno.test("deliverReaction: a notice's reaction (should not happen, but stay safe) sends nothing", async () => {
  let called = false;
  const ok = await deliverReaction(
    { message_id: "m1", user_id: "p1", reaction: "up", reply: null },
    { reaction: "up", reply: null },
    { message: { ...baseMessage, kind: "notice" }, author: recipient("author", true), reactorName: "Petr" },
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

Deno.test("deliverMessage: texts and push data by kind and audience", async () => {
  const sent: { title: string; body: string; data?: Record<string, string>; html?: string }[] = [];
  const deps = {
    send: (_r: unknown, title: string, body: string,
      opts: { data?: Record<string, string>; html?: string }) => {
      sent.push({ title, body, ...opts });
      return Promise.resolve("delivered" as const);
    },
    reactLink: (u: string, reaction: "up" | "down") =>
      Promise.resolve(`https://x/react?t=${u}-${reaction}`),
  };
  const ctx = { authorName: "Bára Kantýnská", authorIsAdmin: true, context: "celý den pá 2. 10." };
  // Staff → players (an admin's day message).
  await deliverMessage({ ...baseMessage, audience: "day", block_id: null, author_role: "admin" },
    ctx, [recipient("p1", false)], deps);
  // Player → staff.
  await deliverMessage({ ...baseMessage, audience: "admins" },
    { ...ctx, authorIsAdmin: false, context: null }, [recipient("a1", false)], deps);
  // A notice: its title, the nástěnka link, no reaction links.
  await deliverMessage({ ...baseMessage, kind: "notice", audience: "all", on_date: null,
    block_id: null, title: "Brigáda", body: "V sobotu uklízíme." },
    ctx, [recipient("p1", false)], deps);

  assertEquals(sent[0].title, "Zpráva od správce");
  assertEquals(sent[0].body, "Přijďte dřív.\ncelý den pá 2. 10.");
  assertEquals(sent[0].data, { kind: "message", message_id: "m1" });
  assertEquals(sent[0].html!.includes("https://x/react?t=p1-up"), true);
  assertEquals(sent[0].html!.includes("https://x/react?t=p1-down"), true);
  assertEquals(sent[0].html!.includes("https://rezervator.online/#/zpravy/m1"), true);
  assertEquals(sent[1].title, "Zpráva od Bára Kantýnská");
  assertEquals(sent[1].body, "Přijďte dřív.");
  assertEquals(sent[2].title, "Brigáda");
  assertEquals(sent[2].body, "V sobotu uklízíme.");
  assertEquals(sent[2].data, { kind: "notice", message_id: "m1" });
  assertEquals(sent[2].html!.includes("https://rezervator.online/#/nastenka/m1"), true);
  assertEquals(sent[2].html!.includes("react?t="), false);
});
