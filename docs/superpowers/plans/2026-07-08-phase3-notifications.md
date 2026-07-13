# Rezervátor — Phase 3 (Notifications + One-Click Cancel) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Supabase Edge Functions `notify` (webhook → push via FCM if the player has a token, else Czech e-mail via Resend; kiosk bookings carry a one-click cancel link) and `cancel` (GET confirm page → POST cancels without login).

**Architecture:** DB webhook triggers (already in `0001_schema.sql`) POST to `notify` guarded by `x-webhook-secret`. `notify` resolves recipients with the service-role client and picks the channel per recipient. Cancel links are stateless HMAC-SHA256 tokens (`_shared/cancel_token.ts`, shared by both functions), expiring at the block's start (Europe/Prague). `cancel` uses a GET/POST split so e-mail link-prefetch scanners can never cancel.

**Tech Stack:** Deno Edge Functions (TypeScript, `jsr:@supabase/supabase-js@2`), Resend REST API, FCM HTTP v1 (code lifted from `/Users/mvazan/Home/terminator/supabase/functions/notify/index.ts` — dormant until FIREBASE_SERVICE_ACCOUNT is set in Phase 5).

## Global Constraints

- Repo `/Users/mvazan/Home/rezervator`, branch `phase-1-reservations`. All user-facing copy CZECH.
- Notification kinds: `pending_player` (to admins), `kiosk_booking` (to the booked player, WITH cancel link in the e-mail variant), `admin_cancelled` (only when `date >= today` in Prague — retro no-show cancels stay silent). Nothing else (no prefs table — YAGNI).
- Channel rule per recipient: `fcm_token != null` AND Firebase configured → push; otherwise e-mail (skip silently with a console.error when the address is empty).
- `cancel` must NEVER cancel on GET. POST only. Token scope: one reservation id; expiry: block start.
- **No local Deno/Docker available** — verification is static (careful read + reviewer). Do not invent test harnesses; runtime verification happens at the user's deploy (SETUP.md §Fáze 3). `flutter analyze`/`flutter test` must stay green (no Dart changes expected in Tasks 1–2).
- Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Shared token module + `notify` function

**Files:**
- Create: `supabase/functions/_shared/cancel_token.ts`, `supabase/functions/notify/index.ts`

**Interfaces:**
- Consumes: schema tables (profiles, reservations, time_blocks), webhook payload shape from `notify_webhook()` in `0001_schema.sql`
- Produces: `signCancelToken(rid, exp, secret)`, `verifyCancelToken(token, secret)`, `pragueEpoch(sqlDate, sqlTime)` (used by Task 2); deployed function `notify`

- [ ] **Step 1: `supabase/functions/_shared/cancel_token.ts`** — full content:

```ts
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
```

- [ ] **Step 2: `supabase/functions/notify/index.ts`** — full content. The FCM section (ServiceAccount → sendToTokens) is lifted from `/Users/mvazan/Home/terminator/supabase/functions/notify/index.ts` lines 16–149 nearly verbatim (no notification_prefs here); read that file while transcribing to keep the proven code exact:

```ts
// notify — push/e-mail notifications for Rezervátor.
//
// Triggered by Supabase Database Webhooks (triggers in 0001_schema.sql) on:
//   INSERT profiles      -> "new player waiting for approval" (to admins)
//   INSERT reservations  -> kiosk booking confirmation (to the player;
//                           the e-mail variant carries a one-click cancel link)
//   UPDATE reservations  -> admin cancelled an upcoming reservation
//
// Channel per recipient: FCM push when profiles.fcm_token is set AND
// FIREBASE_SERVICE_ACCOUNT is configured; otherwise e-mail via Resend.
// Secrets: WEBHOOK_SECRET, RESEND_API_KEY, CANCEL_TOKEN_SECRET,
// optional FIREBASE_SERVICE_ACCOUNT, optional RESEND_FROM.
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically.
// Deploy with --no-verify-jwt (DB triggers can't mint JWTs; the
// x-webhook-secret header is the gate).

import { createClient } from "jsr:@supabase/supabase-js@2";
import { pragueEpoch, pragueToday, signCancelToken } from "../_shared/cancel_token.ts";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

// ---------------------------------------------------------------------------
// FCM HTTP v1 (lifted from Termínátor; dormant until FIREBASE_SERVICE_ACCOUNT
// is set).
// ---------------------------------------------------------------------------

type ServiceAccount = {
  project_id: string;
  client_email: string;
  private_key: string;
};

const serviceAccount: ServiceAccount = JSON.parse(
  Deno.env.get("FIREBASE_SERVICE_ACCOUNT") ?? "{}",
);

const hasFirebase = Boolean(serviceAccount.client_email);

let cachedToken: { token: string; expiresAt: number } | null = null;

function base64url(data: Uint8Array | string): string {
  const bytes = typeof data === "string"
    ? new TextEncoder().encode(data)
    : data;
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  const body = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

async function getAccessToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && cachedToken.expiresAt > now + 60) {
    return cachedToken.token;
  }

  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64url(JSON.stringify({
    iss: serviceAccount.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const key = await importPrivateKey(serviceAccount.private_key);
  const signature = new Uint8Array(await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(`${header}.${claims}`),
  ));
  const jwt = `${header}.${claims}.${base64url(signature)}`;

  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  if (!response.ok) {
    throw new Error(`OAuth token failed: ${await response.text()}`);
  }
  const json = await response.json();
  cachedToken = { token: json.access_token, expiresAt: now + 3500 };
  return json.access_token;
}

async function sendPush(
  userId: string,
  token: string,
  title: string,
  body: string,
  data: Record<string, string> = {},
) {
  const accessToken = await getAccessToken();
  const url =
    `https://fcm.googleapis.com/v1/projects/${serviceAccount.project_id}/messages:send`;
  const response = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      message: {
        token,
        notification: { title, body },
        data,
        android: { priority: "HIGH" },
      },
    }),
  });
  if (!response.ok) {
    const text = await response.text();
    console.error(`FCM send failed for ${userId}: ${text}`);
    if (text.includes("UNREGISTERED") || text.includes("INVALID_ARGUMENT")) {
      await supabase.from("profiles").update({ fcm_token: null })
        .eq("id", userId);
    }
  }
}

// ---------------------------------------------------------------------------
// E-mail via Resend
// ---------------------------------------------------------------------------

async function sendEmail(to: string, subject: string, html: string) {
  const key = Deno.env.get("RESEND_API_KEY");
  if (!key || !to) {
    console.error(`e-mail skipped for '${to}' (missing RESEND_API_KEY or address)`);
    return;
  }
  const from = Deno.env.get("RESEND_FROM") ?? "Rezervátor <onboarding@resend.dev>";
  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ from, to, subject, html }),
  });
  if (!response.ok) {
    console.error(`Resend failed for ${to}: ${await response.text()}`);
  }
}

type Recipient = {
  id: string;
  email: string;
  fcm_token: string | null;
};

/// Push when possible, e-mail otherwise.
async function notifyRecipient(
  recipient: Recipient,
  title: string,
  body: string,
  options: { data?: Record<string, string>; html?: string } = {},
) {
  if (hasFirebase && recipient.fcm_token) {
    await sendPush(recipient.id, recipient.fcm_token, title, body, options.data);
  } else {
    await sendEmail(
      recipient.email,
      title,
      options.html ?? `<p>${escapeHtml(body)}</p>`,
    );
  }
}

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function dayLabel(sqlDate: string): string {
  const names = ["ne", "po", "út", "st", "čt", "pá", "so"];
  const d = new Date(`${sqlDate}T00:00:00Z`);
  return `${names[d.getUTCDay()]} ${d.getUTCDate()}.${d.getUTCMonth() + 1}.`;
}

function timeLabel(sqlTime: string): string {
  const [h, m] = sqlTime.split(":");
  return `${Number(h)}:${m}`;
}

// ---------------------------------------------------------------------------
// Event handlers
// ---------------------------------------------------------------------------

type WebhookPayload = {
  type: "INSERT" | "UPDATE" | "DELETE";
  table: string;
  record: Record<string, unknown> | null;
  old_record: Record<string, unknown> | null;
};

async function reservationContext(record: Record<string, unknown>) {
  const [playerResult, blockResult] = await Promise.all([
    supabase.from("profiles").select("id, email, fcm_token, display_name")
      .eq("id", record.player_id).single(),
    supabase.from("time_blocks").select("starts_at, ends_at")
      .eq("id", record.block_id).single(),
  ]);
  const player = playerResult.data;
  const block = blockResult.data;
  if (!player || !block) return null;
  const when = `${dayLabel(record.date as string)} ` +
    `${timeLabel(block.starts_at)}–${timeLabel(block.ends_at)}, ` +
    `dráha ${record.lane}`;
  return { player: player as Recipient & { display_name: string }, block, when };
}

async function handle(payload: WebhookPayload) {
  const record = payload.record ?? {};

  switch (payload.table) {
    case "profiles": {
      if (payload.type !== "INSERT" || record.status !== "pending") return;
      const { data: admins } = await supabase.from("profiles")
        .select("id, email, fcm_token")
        .eq("role", "admin")
        .eq("status", "approved");
      const name = escapeHtml(String(record.display_name ?? "?"));
      await Promise.all((admins ?? []).map((admin) =>
        notifyRecipient(
          admin as Recipient,
          "Nový hráč čeká na schválení",
          `${record.display_name} se zaregistroval(a). Schval ho v sekci Hráči.`,
          {
            data: { kind: "pending_player" },
            html: `<p><b>${name}</b> se zaregistroval(a) do Rezervátoru.</p>` +
              `<p>Schval ho v aplikaci: Správa kuželny → Hráči.</p>`,
          },
        )
      ));
      return;
    }

    case "reservations": {
      if (payload.type === "INSERT") {
        if (record.created_via !== "kiosk") return;
        const ctx = await reservationContext(record);
        if (!ctx) return;
        const exp = pragueEpoch(
          record.date as string,
          ctx.block.starts_at as string,
        );
        const token = await signCancelToken(
          record.id as string,
          exp,
          Deno.env.get("CANCEL_TOKEN_SECRET") ?? "",
        );
        const cancelUrl =
          `${Deno.env.get("SUPABASE_URL")}/functions/v1/cancel?token=${token}`;
        await notifyRecipient(
          ctx.player,
          "Rezervace z kiosku 🎳",
          `${ctx.when}. Pokud jsi to nebyl ty, zruš ji v aplikaci.`,
          {
            data: {
              kind: "kiosk_booking",
              reservation_id: String(record.id),
            },
            html: `<p>Na kiosku na kuželně vznikla rezervace na tvé jméno:</p>` +
              `<p><b>${escapeHtml(ctx.when)}</b></p>` +
              `<p>Pokud jsi to nebyl ty — nebo termín nechceš — zruš ji jedním kliknutím:</p>` +
              `<p><a href="${cancelUrl}">Zrušit rezervaci</a></p>` +
              `<p>Odkaz platí do začátku tréninku.</p>`,
          },
        );
        return;
      }

      if (payload.type === "UPDATE") {
        const wasLive = payload.old_record?.cancelled_at == null;
        const isCancelled = record.cancelled_at != null;
        if (!wasLive || !isCancelled) return;
        if (record.cancelled_via !== "admin") return;
        // Retro no-show cancels (past dates) stay silent.
        if ((record.date as string) < pragueToday()) return;
        const ctx = await reservationContext(record);
        if (!ctx) return;
        const note = String(record.cancel_note ?? "").trim();
        const reason = note.length > 0 ? note : "zrušeno správcem";
        await notifyRecipient(
          ctx.player,
          "Trénink zrušen",
          `${ctx.when} — ${reason}.`,
          {
            data: { kind: "admin_cancelled" },
            html: `<p>Tvoje rezervace byla zrušena:</p>` +
              `<p><b>${escapeHtml(ctx.when)}</b></p>` +
              `<p>Důvod: ${escapeHtml(reason)}.</p>`,
          },
        );
        return;
      }
      return;
    }
  }
}

Deno.serve(async (request) => {
  const secret = Deno.env.get("WEBHOOK_SECRET");
  if (secret && request.headers.get("x-webhook-secret") !== secret) {
    return new Response("unauthorized", { status: 401 });
  }
  try {
    const payload = await request.json() as WebhookPayload;
    await handle(payload);
    return new Response("ok");
  } catch (error) {
    console.error("notify failed:", error);
    return new Response(`error: ${error}`, { status: 500 });
  }
});
```

- [ ] **Step 3: Static verification** — re-read both files against this listing; check every `import` path resolves within the repo; `flutter analyze`/`flutter test` still green (nothing Dart touched).
- [ ] **Step 4: Commit** — `feat: notify edge function with resend email and cancel tokens`

---

### Task 2: `cancel` function

**Files:**
- Create: `supabase/functions/cancel/index.ts`

**Interfaces:**
- Consumes: `verifyCancelToken` from `_shared/cancel_token.ts`; reservations/time_blocks via service role
- Produces: deployed function `cancel` (`--no-verify-jwt`)

- [ ] **Step 1: `supabase/functions/cancel/index.ts`** — full content:

```ts
// cancel — one-click reservation cancellation from e-mail links.
//
// GET  ?token=…  -> Czech confirmation page (a button). E-mail link-prefetch
//                   scanners follow GETs — rendering only, NEVER cancelling.
// POST ?token=…  -> verifies the token and cancels the reservation.
//
// Deploy with --no-verify-jwt (recipients have no session). The HMAC token
// (see _shared/cancel_token.ts) is the sole authorization: one reservation,
// valid until the block starts.

import { createClient } from "jsr:@supabase/supabase-js@2";
import { verifyCancelToken } from "../_shared/cancel_token.ts";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function dayLabel(sqlDate: string): string {
  const names = ["ne", "po", "út", "st", "čt", "pá", "so"];
  const d = new Date(`${sqlDate}T00:00:00Z`);
  return `${names[d.getUTCDay()]} ${d.getUTCDate()}.${d.getUTCMonth() + 1}.`;
}

function timeLabel(sqlTime: string): string {
  const [h, m] = sqlTime.split(":");
  return `${Number(h)}:${m}`;
}

function page(title: string, bodyHtml: string, formHtml = ""): Response {
  const html = `<!doctype html>
<html lang="cs"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${escapeHtml(title)} · Rezervátor</title>
<style>
  body { font-family: -apple-system, system-ui, sans-serif; background: #f4f4f4;
         display: flex; justify-content: center; padding: 48px 16px; }
  .card { background: #fff; border-radius: 16px; padding: 32px; max-width: 420px;
          box-shadow: 0 2px 12px rgba(0,0,0,.08); text-align: center; }
  h1 { font-size: 1.3rem; margin: 0 0 12px; }
  button { background: #00695c; color: #fff; border: 0; border-radius: 12px;
           padding: 14px 24px; font-size: 1rem; font-weight: 600; cursor: pointer; }
  p { color: #333; line-height: 1.5; }
</style></head>
<body><div class="card"><h1>🎳 ${escapeHtml(title)}</h1>${bodyHtml}${formHtml}</div></body></html>`;
  return new Response(html, {
    headers: { "Content-Type": "text/html; charset=utf-8" },
  });
}

Deno.serve(async (request) => {
  const url = new URL(request.url);
  const token = url.searchParams.get("token") ?? "";
  const secret = Deno.env.get("CANCEL_TOKEN_SECRET") ?? "";

  const verdict = await verifyCancelToken(token, secret);
  if ("error" in verdict) {
    return page(
      "Odkaz neplatí",
      verdict.error === "expired"
        ? "<p>Trénink už začal — rezervaci teď může zrušit jen správce.</p>"
        : "<p>Odkaz je poškozený nebo neplatný.</p>",
    );
  }

  const { data: reservation } = await supabase.from("reservations")
    .select("id, date, lane, block_id, cancelled_at")
    .eq("id", verdict.rid)
    .maybeSingle();
  if (!reservation) {
    return page("Rezervace nenalezena", "<p>Tahle rezervace už neexistuje.</p>");
  }
  if (reservation.cancelled_at) {
    return page("Hotovo", "<p>Rezervace už je zrušená.</p>");
  }

  const { data: block } = await supabase.from("time_blocks")
    .select("starts_at, ends_at")
    .eq("id", reservation.block_id)
    .single();
  const when = block
    ? `${dayLabel(reservation.date)} ${timeLabel(block.starts_at)}–` +
      `${timeLabel(block.ends_at)}, dráha ${reservation.lane}`
    : `${dayLabel(reservation.date)}, dráha ${reservation.lane}`;

  if (request.method === "GET") {
    // action="" re-POSTs to the same URL, token included in the query.
    return page(
      "Zrušit rezervaci?",
      `<p><b>${escapeHtml(when)}</b></p><p>Opravdu chceš tuhle rezervaci zrušit?</p>`,
      `<form method="post" action=""><button type="submit">Zrušit rezervaci</button></form>`,
    );
  }

  if (request.method === "POST") {
    const { data: updated, error } = await supabase.from("reservations")
      .update({
        cancelled_at: new Date().toISOString(),
        cancelled_via: "one_click",
      })
      .eq("id", verdict.rid)
      .is("cancelled_at", null)
      .select("id");
    if (error) {
      console.error("cancel failed:", error);
      return page("Chyba", "<p>Zrušení se nepovedlo. Zkus to prosím znovu.</p>");
    }
    if (!updated || updated.length === 0) {
      return page("Hotovo", "<p>Rezervace už byla zrušená.</p>");
    }
    return page(
      "Rezervace zrušena ✔",
      `<p><b>${escapeHtml(when)}</b></p><p>Termín je zase volný. Díky, žes dal vědět!</p>`,
    );
  }

  return new Response("method not allowed", { status: 405 });
});
```

- [ ] **Step 2: Static verification** (as Task 1) — plus specifically confirm: GET path contains NO write, POST guard `.is('cancelled_at', null)` present, `action=""` keeps the token query param.
- [ ] **Step 3: Commit** — `feat: one-click cancel edge function`

---

### Task 3: SETUP.md §Fáze 3

**Files:**
- Modify: `SETUP.md`

**Spec:** Append a numbered section „Fáze 3 — notifikace" in the existing style:
1. Resend: create account → API key. Free tier limits (100/den, 3000/měsíc). Optional custom domain later; start with `onboarding@resend.dev` sender (mention `RESEND_FROM` secret for later).
2. `supabase link --project-ref <ref>` (once).
3. `supabase secrets set WEBHOOK_SECRET=… RESEND_API_KEY=… CANCEL_TOKEN_SECRET=…` — WEBHOOK_SECRET must equal the value pasted into `0001_schema.sql` in §Fáze 0; CANCEL_TOKEN_SECRET: `openssl rand -hex 24`.
4. `supabase functions deploy notify --no-verify-jwt` and `supabase functions deploy cancel --no-verify-jwt` (explain why no-verify-jwt: DB triggers and e-mail recipients have no JWT; notify is guarded by the secret header, cancel by the HMAC token).
5. Test checklist: make a booking with `created_via='kiosk'` via SQL editor (example INSERT calling `create_reservation` as admin is NOT kiosk — instead temporary: `update reservations set created_via='kiosk'`… simpler: note that the real end-to-end test comes with the kiosk in Fáze 4; for now test `cancel` by generating a token via a one-off SQL/JS snippet — provide a small deno-less test: admin cancels an upcoming reservation from the app → e-mail arrives). Keep instructions honest and minimal.
6. Note: push notifications activate later (Fáze 5, FIREBASE_SERVICE_ACCOUNT) — e-mail covers everyone until then.

- [ ] **Step 1:** Write the section. **Step 2:** `flutter analyze`/`test` untouched-green sanity. **Step 3:** Commit `docs: setup guide for notifications phase`.
