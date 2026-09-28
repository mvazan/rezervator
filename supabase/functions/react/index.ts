// react — one-click 👍/👎 from a message e-mail (0051). GET ?t=<token> ->
// verifies the signed token, writes the reaction, redirects to a static
// result page. Deploy with --no-verify-jwt (recipients have no session);
// the HMAC token (_shared/react_token.ts) is the sole authorization.
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically;
// CANCEL_TOKEN_SECRET is shared with the cancel and notify functions.

import { createClient } from "@supabase/supabase-js";
import { handleReact, mayReact } from "../_shared/react_handler.ts";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const RESULT_PAGE = "https://rezervator.online/reakce.html";

Deno.serve(async (request) => {
  const url = new URL(request.url);
  return await handleReact(url, {
    secret: Deno.env.get("CANCEL_TOKEN_SECRET"),
    now: () => Date.now(),
    // The row and its account: the service role bypasses RLS, so
    // mayReact re-applies the app's rule (approved non-kiosk member of the
    // row's alley). A database error throws — handleReact logs it.
    recipientMayReact: async (m, u) => {
      const { data, error } = await supabase.from("message_recipients")
        .select("tenant_id, profiles!inner(status, role, tenant_id)")
        .eq("message_id", m).eq("user_id", u).maybeSingle();
      if (error) throw error;
      return mayReact(data);
    },
    writeReaction: async (m, u, r) => {
      const { data, error } = await supabase.from("message_recipients")
        .update({ reaction: r }).eq("message_id", m).eq("user_id", u)
        .select("message_id");
      if (error) throw error;
      return (data?.length ?? 0) > 0;
    },
    resultPage: RESULT_PAGE,
    logError: (message, detail) =>
      detail === undefined ? console.error(message) : console.error(message, detail),
  });
});
