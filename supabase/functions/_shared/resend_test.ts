import { assertEquals } from "jsr:@std/assert@1";
import { batchDeliveryOf, type Email, resendBatch, resendEmail } from "./resend.ts";

type Call = { url: string; headers: Headers; body: unknown };

// A fetch that records each request and answers [status].
function fakeFetch(status: number) {
  const calls: Call[] = [];
  const fetch = (url: string, init: RequestInit) => {
    calls.push({ url, headers: new Headers(init.headers), body: JSON.parse(String(init.body)) });
    return Promise.resolve(new Response(status < 300 ? "{}" : "{\"name\":\"x\"}", { status }));
  };
  return { fetch, calls };
}

// Runs [body] with console.error silenced (a refused request is logged).
async function quietly<T>(body: () => Promise<T>): Promise<T> {
  const error = console.error;
  console.error = () => {};
  try {
    return await body();
  } finally {
    console.error = error;
  }
}

const mail = (to: string): Email => ({ to, subject: "Zpráva od správce", html: "<p>x</p>" });
const FROM = "Rezervátor <r@example.com>";

Deno.test("batchDeliveryOf: a refused batch content is 'invalid', the rest as deliveryOf", () => {
  // Resend's default strict batch validation fails the whole request over
  // one bad item: 422 (and 400) mean "try them one by one".
  assertEquals(batchDeliveryOf(200), "delivered");
  assertEquals(batchDeliveryOf(422), "invalid");
  assertEquals(batchDeliveryOf(400), "invalid");
  assertEquals(batchDeliveryOf(429), "retry");
  assertEquals(batchDeliveryOf(502), "retry");
  // A bad key or a key conflict would come back the same one by one.
  assertEquals(batchDeliveryOf(401), "undeliverable");
  assertEquals(batchDeliveryOf(403), "undeliverable");
  assertEquals(batchDeliveryOf(409), "undeliverable");
});

Deno.test("resendBatch: one /emails/batch request under the idempotency key", async () => {
  const { fetch, calls } = fakeFetch(200);
  const delivery = await resendBatch([mail("a@x.cz"), mail("b@x.cz")], "message/m1/0",
    { apiKey: "re_test", from: FROM, fetch });
  assertEquals(delivery, "delivered");
  assertEquals(calls.length, 1);
  assertEquals(calls[0].url, "https://api.resend.com/emails/batch");
  assertEquals(calls[0].headers.get("idempotency-key"), "message/m1/0");
  assertEquals(calls[0].headers.get("authorization"), "Bearer re_test");
  assertEquals(calls[0].headers.get("content-type"), "application/json");
  assertEquals(calls[0].body, [
    { from: FROM, to: "a@x.cz", subject: "Zpráva od správce", html: "<p>x</p>" },
    { from: FROM, to: "b@x.cz", subject: "Zpráva od správce", html: "<p>x</p>" },
  ]);
});

Deno.test("resendBatch: Resend's answer read as a batch verdict", async () => {
  for (const [status, verdict] of [[422, "invalid"], [503, "retry"], [401, "undeliverable"]] as const) {
    const { fetch } = fakeFetch(status);
    const delivery = await quietly(() =>
      resendBatch([mail("a@x.cz")], "k", { apiKey: "re_test", from: FROM, fetch })
    );
    assertEquals(delivery, verdict);
  }
});

Deno.test("resendBatch: no API key sends nothing", async () => {
  const { fetch, calls } = fakeFetch(200);
  const delivery = await quietly(() =>
    resendBatch([mail("a@x.cz")], "k", { apiKey: undefined, from: FROM, fetch })
  );
  assertEquals(delivery, "undeliverable");
  assertEquals(calls, []);
});

Deno.test("resendEmail: one /emails request, the idempotency key only when given", async () => {
  const keyed = fakeFetch(200);
  assertEquals(await resendEmail(mail("a@x.cz"), { apiKey: "re_test", from: FROM, fetch: keyed.fetch },
    "message/m1/0/3"), "delivered");
  assertEquals(keyed.calls[0].url, "https://api.resend.com/emails");
  assertEquals(keyed.calls[0].headers.get("idempotency-key"), "message/m1/0/3");
  assertEquals(keyed.calls[0].body,
    { from: FROM, to: "a@x.cz", subject: "Zpráva od správce", html: "<p>x</p>" });

  const plain = fakeFetch(200);
  await resendEmail(mail("a@x.cz"), { apiKey: "re_test", from: FROM, fetch: plain.fetch });
  assertEquals(plain.calls[0].headers.has("idempotency-key"), false);
});

Deno.test("resendEmail: no address or no API key sends nothing; a refusal is read by deliveryOf", async () => {
  const { fetch, calls } = fakeFetch(200);
  assertEquals(await quietly(() => resendEmail(mail(""), { apiKey: "re_test", from: FROM, fetch })),
    "undeliverable");
  assertEquals(await quietly(() => resendEmail(mail("a@x.cz"), { apiKey: undefined, from: FROM, fetch })),
    "undeliverable");
  assertEquals(calls, []);
  const refused = fakeFetch(422);
  assertEquals(await quietly(() =>
    resendEmail(mail("bad"), { apiKey: "re_test", from: FROM, fetch: refused.fetch })
  ), "undeliverable");
});
