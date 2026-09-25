import { assertEquals } from "jsr:@std/assert@1";
import { deliveryOf, pushOutcome } from "./delivery.ts";

Deno.test("a 2xx answer is delivered", () => {
  assertEquals(deliveryOf(200), "delivered");
  assertEquals(deliveryOf(202), "delivered");
});

Deno.test("rate limits and server errors are worth another try", () => {
  for (const status of [429, 500, 502, 503]) {
    assertEquals(deliveryOf(status), "retry", `${status}`);
  }
});

Deno.test("any other refusal would be refused again", () => {
  for (const status of [400, 401, 403, 404, 422]) {
    assertEquals(deliveryOf(status), "undeliverable", `${status}`);
  }
});

// --- FCM ----------------------------------------------------------------

Deno.test("an accepted push is delivered", () => {
  assertEquals(pushOutcome(200, "{}"), { delivery: "delivered", deadToken: false });
});

Deno.test("a dead token is dropped and the message is worth another try — "
  + "by e-mail, as the profile has no token then", () => {
  assertEquals(
    pushOutcome(404, '{"error":{"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}}'),
    { delivery: "retry", deadToken: true },
  );
  assertEquals(
    pushOutcome(400, '{"error":{"status":"INVALID_ARGUMENT"}}'),
    { delivery: "retry", deadToken: true },
  );
});

Deno.test("FCM being busy or down is worth another try, the token stays", () => {
  assertEquals(pushOutcome(503, '{"error":{"status":"UNAVAILABLE"}}'), {
    delivery: "retry",
    deadToken: false,
  });
  assertEquals(pushOutcome(429, '{"error":{"status":"RESOURCE_EXHAUSTED"}}'), {
    delivery: "retry",
    deadToken: false,
  });
});

Deno.test("any other refusal is not tried again", () => {
  assertEquals(pushOutcome(403, '{"error":{"status":"PERMISSION_DENIED","details":[{"errorCode":"SENDER_ID_MISMATCH"}]}}'), {
    delivery: "undeliverable",
    deadToken: false,
  });
});
