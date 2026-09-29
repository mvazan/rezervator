// Stateless one-click-reaction tokens for the react function (0051):
// `${base64url(JSON{m,u,r,x})}.${base64url(hmacSHA256(payload))}`, the
// same wire format cancel_token.ts uses (its base64url helpers and
// hmacKey are reused, unmodified). x = the epoch-ms issue time; a token
// is valid for REACT_TOKEN_DAYS after that.

import { base64urlDecode, base64urlEncode, hmacKey } from "./cancel_token.ts";

/// How long an e-mailed 👍/👎 link stays valid.
export const REACT_TOKEN_DAYS = 30;

/// Who (u) reacts how (r) to which message (m).
export type ReactPayload = { m: string; u: string; r: "up" | "down" };

/// A token for [data]; [issuedAt] (epoch ms) only for tests.
export async function signReactToken(
  data: ReactPayload,
  secret: string,
  issuedAt: number = Date.now(),
): Promise<string> {
  const payload = base64urlEncode(JSON.stringify({ ...data, x: issuedAt }));
  const signature = new Uint8Array(await crypto.subtle.sign(
    "HMAC",
    await hmacKey(secret),
    new TextEncoder().encode(payload),
  ));
  return `${payload}.${base64urlEncode(signature)}`;
}

/// The payload of a good token, or why it was refused.
export type ReactVerdict = ReactPayload | { error: "invalid" | "expired" };

/// Checks the signature and the REACT_TOKEN_DAYS expiry; [now] (epoch ms)
/// only for tests.
export async function verifyReactToken(
  token: string,
  secret: string,
  now: number = Date.now(),
): Promise<ReactVerdict> {
  const parts = token.split(".");
  if (parts.length !== 2) return { error: "invalid" };
  const [payload, signature] = parts;
  let ok = false;
  try {
    ok = await crypto.subtle.verify(
      "HMAC",
      await hmacKey(secret),
      base64urlDecode(signature),
      new TextEncoder().encode(payload),
    );
  } catch (_) {
    return { error: "invalid" };
  }
  if (!ok) return { error: "invalid" };
  let m = "";
  let u = "";
  let r = "";
  let x = 0;
  try {
    const parsed = JSON.parse(new TextDecoder().decode(base64urlDecode(payload)));
    m = String(parsed.m ?? "");
    u = String(parsed.u ?? "");
    r = String(parsed.r ?? "");
    x = Number(parsed.x ?? 0);
  } catch (_) {
    return { error: "invalid" };
  }
  if (!m || !u || (r !== "up" && r !== "down") || !Number.isFinite(x)) {
    return { error: "invalid" };
  }
  if (now - x > REACT_TOKEN_DAYS * 86400_000) return { error: "expired" };
  return { m, u, r: r as "up" | "down" };
}
