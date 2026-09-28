// react — one-click 👍/👎 from a message e-mail (0051). GET ?t=<token> ->
// verifies the signed token, writes the reaction, redirects to a static
// result page. Deploy with --no-verify-jwt (recipients have no session);
// the HMAC token (_shared/react_token.ts) is the sole authorization.
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically;
// CANCEL_TOKEN_SECRET is shared with the cancel and notify functions.

import { createClient } from "@supabase/supabase-js";
import { handleReact } from "../_shared/react_handler.ts";

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
    recipientExists: async (m, u) => {
      const { data } = await supabase.from("message_recipients")
        .select("message_id").eq("message_id", m).eq("user_id", u).maybeSingle();
      return data != null;
    },
    writeReaction: async (m, u, r) => {
      const { data } = await supabase.from("message_recipients")
        .update({ reaction: r }).eq("message_id", m).eq("user_id", u).select();
      return (data?.length ?? 0) > 0;
    },
    resultPage: RESULT_PAGE,
  });
});
