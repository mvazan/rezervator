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
