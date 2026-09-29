// cancel — one-click reservation cancellation from e-mail links.
//
// GET  ?token=…  -> redirect to the Czech confirmation page (a button). E-mail
//                   link-prefetch scanners follow GETs — reading only, NEVER
//                   cancelling.
// POST ?token=…  -> verifies the token, cancels the reservation and redirects
//                   to the same page with the outcome.
//
// The page is web/cancel.html on rezervator.online, not HTML from here — the
// edge runtime turns any HTML into text/plain (see _shared/cancel_flow.ts,
// which holds the flow itself).
//
// Deploy with --no-verify-jwt (recipients have no session). The HMAC token
// (see _shared/cancel_token.ts) is the sole authorization: one reservation,
// valid until the block starts.

import { createClient } from "@supabase/supabase-js";
import { handleCancel } from "../_shared/cancel_flow.ts";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

Deno.serve(async (request) => {
  // Fail closed (mirrors notify's WEBHOOK_SECRET guard): with no secret the
  // HMAC check would pass for tokens signed with an empty key.
  const secret = Deno.env.get("CANCEL_TOKEN_SECRET");
  if (!secret) {
    console.error("CANCEL_TOKEN_SECRET is not set");
    return new Response("misconfigured", { status: 500 });
  }

  return await handleCancel(request, {
    secret,
    reservation: async (rid) => {
      const { data } = await supabase.from("reservations")
        .select("date, lane, block_id, cancelled_at")
        .eq("id", rid)
        .maybeSingle();
      return data;
    },
    block: async (id) => {
      const { data } = await supabase.from("time_blocks")
        .select("starts_at, ends_at")
        .eq("id", id)
        .single();
      return data;
    },
    cancel: async (rid) => {
      const { data, error } = await supabase.from("reservations")
        .update({
          cancelled_at: new Date().toISOString(),
          cancelled_via: "one_click",
        })
        .eq("id", rid)
        .is("cancelled_at", null)
        .select("id");
      if (error) throw error;
      return (data ?? []).length > 0;
    },
  });
});
