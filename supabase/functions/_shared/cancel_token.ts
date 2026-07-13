// Stateless one-click-cancel tokens: `${base64url(JSON{rid,exp})}.${base64url(hmacSHA256(payload))}`.
// exp = epoch seconds of the reservation's block start (Europe/Prague wall
// clock) — once the training has started, cancellation is an admin decision.

export function base64urlEncode(data: Uint8Array | string): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function base64urlDecode(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/") +
    "=".repeat((4 - value.length % 4) % 4);
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

async function hmacKey(secret: string): Promise<CryptoKey> {
  return await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

export async function signCancelToken(
  rid: string,
  exp: number,
  secret: string,
): Promise<string> {
  const payload = base64urlEncode(JSON.stringify({ rid, exp }));
  const signature = new Uint8Array(await crypto.subtle.sign(
    "HMAC",
    await hmacKey(secret),
    new TextEncoder().encode(payload),
  ));
  return `${payload}.${base64urlEncode(signature)}`;
}

export type CancelVerdict = { rid: string } | { error: "invalid" | "expired" };

export async function verifyCancelToken(
  token: string,
  secret: string,
): Promise<CancelVerdict> {
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
  let rid = "";
  let exp = 0;
  try {
    const parsed = JSON.parse(new TextDecoder().decode(base64urlDecode(payload)));
    rid = String(parsed.rid ?? "");
    exp = Number(parsed.exp ?? 0);
  } catch (_) {
    return { error: "invalid" };
  }
  if (!rid || !Number.isFinite(exp)) return { error: "invalid" };
  if (Date.now() / 1000 > exp) return { error: "expired" };
  return { rid };
}

/// Epoch seconds of `sqlDate` (`YYYY-MM-DD`) + `sqlTime` (`HH:MM[:SS]`)
/// interpreted as Europe/Prague wall clock. The offset is sampled at the
/// moment itself, so DST is handled (±1 h drift only inside the transition
/// hour — fine for a cancel-link expiry).
export function pragueEpoch(sqlDate: string, sqlTime: string): number {
  const utcGuess = Date.parse(`${sqlDate}T${sqlTime.slice(0, 5)}:00Z`);
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "Europe/Prague",
    timeZoneName: "longOffset",
  }).formatToParts(new Date(utcGuess));
  const name = parts.find((p) => p.type === "timeZoneName")?.value ?? "GMT+01:00";
  const match = name.match(/GMT([+-])(\d{2}):(\d{2})/);
  const offsetMinutes = match
    ? (match[1] === "+" ? 1 : -1) * (Number(match[2]) * 60 + Number(match[3]))
    : 60;
  return Math.floor(utcGuess / 1000) - offsetMinutes * 60;
}

/// Today (`YYYY-MM-DD`) in Europe/Prague.
export function pragueToday(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Prague" })
    .format(new Date());
}
