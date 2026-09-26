// What became of one message handed to Resend or FCM — so a caller that
// must not lose it (a reminder) can tell a delivered one from one worth
// another try, and from one that would only be refused again.

export type Delivery = "delivered" | "retry" | "undeliverable";

/// The verdict of an HTTP answer: 2xx delivered; rate limiting (429) and
/// server errors (5xx) pass, so another try is worth it; any other refusal
/// (bad address, bad credentials) would come back the same.
export function deliveryOf(status: number): Delivery {
  if (status >= 200 && status < 300) return "delivered";
  if (status === 429 || status >= 500) return "retry";
  return "undeliverable";
}

/// FCM's answer read: a token the device no longer has (UNREGISTERED, or
/// INVALID_ARGUMENT for a malformed one) is dropped from the profile, and
/// the message is worth another try — by e-mail, since the profile has no
/// token then. Otherwise [deliveryOf].
export function pushOutcome(
  status: number,
  body: string,
): { delivery: Delivery; deadToken: boolean } {
  if (status >= 200 && status < 300) {
    return { delivery: "delivered", deadToken: false };
  }
  if (body.includes("UNREGISTERED") || body.includes("INVALID_ARGUMENT")) {
    return { delivery: "retry", deadToken: true };
  }
  return { delivery: deliveryOf(status), deadToken: false };
}
