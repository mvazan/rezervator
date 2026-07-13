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
      // Tenant-scoped fan-out (0005): only the new player's own alley's
      // admins are notified; to_jsonb(new) carries tenant_id automatically.
      const { data: admins } = await supabase.from("profiles")
        .select("id, email, fcm_token")
        .eq("role", "admin")
        .eq("status", "approved")
        .eq("tenant_id", record.tenant_id);
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
            html: `<p>Na kiosku na kuzelně vznikla rezervace na tvé jméno:</p>` +
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
  // Fail closed: the function is deployed --no-verify-jwt, so a missing
  // WEBHOOK_SECRET must reject everything (loud 401) rather than open the
  // endpoint to forged payloads.
  const secret = Deno.env.get("WEBHOOK_SECRET");
  if (!secret || request.headers.get("x-webhook-secret") !== secret) {
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
