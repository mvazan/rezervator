// notify — push/e-mail notifications for Rezervátor.
//
// Triggered by Supabase Database Webhooks (triggers in 0001_schema.sql) on:
//   INSERT profiles      -> "new player waiting for approval" (to admins)
//   INSERT reservations  -> kiosk booking confirmation (to the player;
//                           the e-mail variant carries a one-click cancel link)
//   UPDATE reservations  -> admin cancelled an upcoming reservation, or an
//                           admin MOVED it ("termín přesunut z X na Y") —
//                           both honour the per-change notify_player flag +
//                           optional notify_message the RPCs stamp (0011)
//   INSERT tenants       -> "new kuželna waiting for approval" (to the
//                           superadmins — trigger added in 0014)
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
import { firebaseConfigured, sendPush } from "../_shared/fcm.ts";
import { dayLabel, escapeHtml, timeLabel } from "../_shared/format.ts";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

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
  if (firebaseConfigured() && recipient.fcm_token) {
    await sendPush(
      supabase,
      recipient.id,
      recipient.fcm_token,
      title,
      body,
      options.data,
    );
  } else {
    await sendEmail(
      recipient.email,
      title,
      options.html ?? `<p>${escapeHtml(body)}</p>`,
    );
  }
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

/// 'po 13.7. 17:30–18:30, dráha 2' for the OLD side of a move — the block
/// row still exists (moves only retarget block_id), so a plain lookup works.
async function whenLabel(record: Record<string, unknown>): Promise<string | null> {
  const { data: block } = await supabase.from("time_blocks")
    .select("starts_at, ends_at").eq("id", record.block_id).single();
  if (!block) return null;
  return `${dayLabel(record.date as string)} ` +
    `${timeLabel(block.starts_at)}–${timeLabel(block.ends_at)}, ` +
    `dráha ${record.lane}`;
}

async function handle(payload: WebhookPayload) {
  const record = payload.record ?? {};

  switch (payload.table) {
    case "tenants": {
      // A new kuželna waits for the superadmin's approval (0014). Existing
      // tenants only ever UPDATE (approval), which stays silent.
      if (payload.type !== "INSERT" || record.status !== "pending") return;
      const { data: superadmins } = await supabase.from("profiles")
        .select("id, email, fcm_token")
        .eq("superadmin", true);
      const name = escapeHtml(String(record.name ?? "?"));
      const founder = escapeHtml(String(record.founder_email ?? "?"));
      await Promise.all((superadmins ?? []).map((admin) =>
        notifyRecipient(
          admin as Recipient,
          "Nová kuželna čeká na schválení",
          `„${record.name}" (${record.founder_email ?? "?"}). ` +
            `Schval ji v aplikaci: Správa → Kuželny.`,
          {
            data: { kind: "pending_tenant" },
            html: `<p>Někdo založil novou kuželnu <b>${name}</b> ` +
              `(zakladatel: ${founder}).</p>` +
              `<p>Schval ji v aplikaci: Správa kuželny → Kuželny.</p>`,
          },
        )
      ));
      return;
    }

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
        // Fail closed: signing with an empty key would mint links anyone
        // could forge. A missing secret is a deployment bug — surface it
        // as a 500 in the function logs instead.
        const cancelSecret = Deno.env.get("CANCEL_TOKEN_SECRET");
        if (!cancelSecret) throw new Error("CANCEL_TOKEN_SECRET is not set");
        const token = await signCancelToken(
          record.id as string,
          exp,
          cancelSecret,
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
        const old = payload.old_record ?? {};
        const wasLive = old.cancelled_at == null;
        if (!wasLive) return;
        // The admin's per-change choice (0011): a silent move/cancel sets
        // notify_player=false on the same UPDATE.
        const wantsNotify = record.notify_player !== false;

        // ADMIN CANCEL of an upcoming reservation.
        if (record.cancelled_at != null) {
          if (record.cancelled_via !== "admin") return;
          if (!wantsNotify) return;
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

        // ADMIN MOVE of a live reservation (block/lane/date changed).
        const moved = old.block_id !== record.block_id ||
          old.lane !== record.lane ||
          old.date !== record.date;
        if (!moved || !wantsNotify) return;
        const [ctx, oldWhen] = await Promise.all([
          reservationContext(record),
          whenLabel(old),
        ]);
        if (!ctx) return;
        const custom = String(record.notify_message ?? "").trim();
        const standard = oldWhen == null
          ? `Nový termín: ${ctx.when}.`
          : `Z ${oldWhen} na ${ctx.when}.`;
        const body = custom.length > 0 ? `${custom} (${ctx.when})` : standard;
        await notifyRecipient(
          ctx.player,
          "Termín přesunut",
          body,
          {
            data: { kind: "reservation_moved" },
            html: `<p>Tvoje rezervace byla přesunuta:</p>` +
              (oldWhen == null
                ? ""
                : `<p>Původně: ${escapeHtml(oldWhen)}</p>`) +
              `<p>Nově: <b>${escapeHtml(ctx.when)}</b></p>` +
              (custom.length > 0 ? `<p>${escapeHtml(custom)}</p>` : ""),
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
