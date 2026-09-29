// Resend's HTTP API, the one place that builds its requests — apart from
// notify/index.ts so the headers and the verdicts can be tested with a
// fake fetch.

import { type Delivery, deliveryOf } from "./delivery.ts";

/// One e-mail: the address and the finished message.
export type Email = { to: string; subject: string; html: string };

/// Where Resend is and who sends: the API key (undefined = not configured,
/// nothing is sent), the sender, and fetch (injected for tests).
export type ResendConfig = {
  apiKey: string | undefined;
  from: string;
  fetch: (url: string, init: RequestInit) => Promise<Response>;
};

/// What became of one /emails/batch request: a [Delivery], or "invalid" —
/// Resend refused the batch's content (400/422). Its default strict batch
/// validation fails the whole request over one bad item (a malformed
/// address), so each e-mail is worth trying alone. Any other refusal (a
/// bad key, 401/403; a key conflict, 409) would come back the same one by
/// one: [deliveryOf].
export type BatchDelivery = Delivery | "invalid";

/// The verdict of a /emails/batch answer's [status] — see [BatchDelivery].
export function batchDeliveryOf(status: number): BatchDelivery {
  if (status === 400 || status === 422) return "invalid";
  return deliveryOf(status);
}

/// Sends [email] alone (POST /emails). [idempotencyKey], when given, goes
/// out as the `Idempotency-Key` header: Resend answers a repeat of the key
/// within 24 hours without sending again. No address or no API key sends
/// nothing (logged, "undeliverable"); a refusal is logged with Resend's
/// answer.
export async function resendEmail(
  email: Email,
  config: ResendConfig,
  idempotencyKey?: string,
): Promise<Delivery> {
  const answer = await postEmail(email, config, idempotencyKey);
  return answer ? deliveryOf(answer.status) : "undeliverable";
}

/// What became of one e-mail of a batch refused as invalid, sent alone: a
/// [Delivery], or "refused" — Resend refused the request for something
/// that is not its address (see [singleDeliveryOf]), so every other
/// e-mail alone would be refused the same.
export type SingleDelivery = Delivery | "refused";

/// Resend's error names for a request refused over the sender, the key or
/// the request itself — never over one recipient's address, which comes
/// back as a `validation_error` naming the `to` field.
const notAboutTheAddress = new Set([
  "missing_api_key",
  "restricted_api_key",
  "invalid_api_key",
  "invalid_from_address",
  "invalid_idempotency_key",
  "missing_required_field",
  "invalid_access",
  "invalid_region",
]);

/// The verdict of an /emails answer ([status], Resend's error [body]) for
/// one e-mail of a batch refused as invalid: "refused" when Resend names a
/// reason that is not the address (a 401 is always the key), else
/// [deliveryOf]. An unreadable body is not taken for "refused": one
/// e-mail too many is tried rather than the rest skipped.
export function singleDeliveryOf(status: number, body: string): SingleDelivery {
  const delivery = deliveryOf(status);
  if (delivery !== "undeliverable") return delivery;
  return status === 401 || notAboutTheAddress.has(errorName(body)) ? "refused" : delivery;
}

function errorName(body: string): string {
  try {
    const name = JSON.parse(body)?.name;
    return typeof name === "string" ? name : "";
  } catch {
    return "";
  }
}

/// One e-mail of a batch refused as invalid, alone (POST /emails, under
/// [idempotencyKey]) — [resendEmail], read by [singleDeliveryOf]. No API
/// key is "refused" as well: no e-mail would go.
export async function resendOneOfBatch(
  email: Email,
  config: ResendConfig,
  idempotencyKey: string,
): Promise<SingleDelivery> {
  const answer = await postEmail(email, config, idempotencyKey);
  if (!answer) return config.apiKey ? "undeliverable" : "refused";
  return singleDeliveryOf(answer.status, answer.body);
}

/// POST /emails for [email]; null (logged, nothing sent) without an
/// address or an API key. A refusal is logged with Resend's answer.
async function postEmail(
  email: Email,
  config: ResendConfig,
  idempotencyKey: string | undefined,
): Promise<{ status: number; body: string } | null> {
  if (!config.apiKey || !email.to) {
    console.error(`e-mail skipped for '${email.to}' (missing RESEND_API_KEY or address)`);
    return null;
  }
  const response = await config.fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: headers(config.apiKey, idempotencyKey),
    body: JSON.stringify({ from: config.from, ...email }),
  });
  const body = await response.text();
  if (!response.ok) console.error(`Resend failed for ${email.to}: ${body}`);
  return { status: response.status, body };
}

/// Sends [emails] in one request (POST /emails/batch, at most 100 — the
/// caller chunks and leaves out recipients without an address), under
/// [idempotencyKey]: the caller's retry after a 5xx reuses it, so a batch
/// Resend took before the gateway failed is not sent twice.
export async function resendBatch(
  emails: Email[],
  idempotencyKey: string,
  config: ResendConfig,
): Promise<BatchDelivery> {
  if (!config.apiKey) {
    console.error(`e-mail batch of ${emails.length} skipped (missing RESEND_API_KEY)`);
    return "undeliverable";
  }
  const response = await config.fetch("https://api.resend.com/emails/batch", {
    method: "POST",
    headers: headers(config.apiKey, idempotencyKey),
    body: JSON.stringify(emails.map((e) => ({ from: config.from, ...e }))),
  });
  if (!response.ok) {
    console.error(`Resend batch of ${emails.length} failed: ${await response.text()}`);
  }
  return batchDeliveryOf(response.status);
}

function headers(apiKey: string, idempotencyKey: string | undefined): Record<string, string> {
  return {
    Authorization: `Bearer ${apiKey}`,
    "Content-Type": "application/json",
    ...(idempotencyKey ? { "Idempotency-Key": idempotencyKey } : {}),
  };
}
