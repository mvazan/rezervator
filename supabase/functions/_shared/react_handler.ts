// The react function's logic (0051), apart from Deno.serve/env/the real
// Supabase client so it can be unit-tested (the duty_reminders.ts /
// group_messages.ts shape). A one-click GET reaction link with no confirm
// step — accepted here (unlike cancel/index.ts, which renders a confirm
// page because a cancellation is destructive and its own link can be
// prefetched by a mail scanner): a reaction is harmless and reversible in
// the app, so the extra step was not worth it. Never HTML: edge-function
// bodies are served as text/plain regardless of the Content-Type header
// (see calendar-oauth-callback/index.ts's comment) — always redirect to a
// static result page.

import { verifyReactToken } from "./react_token.ts";

/// What handleReact needs from the outside world: the HMAC secret
/// (undefined = not configured), a clock (epoch ms), the recipient-row
/// lookup and write (service role in the deployed function), and the
/// static page to redirect to.
export type ReactDeps = {
  secret: string | undefined;
  now: () => number;
  recipientExists: (messageId: string, userId: string) => Promise<boolean>;
  writeReaction: (messageId: string, userId: string, reaction: "up" | "down") => Promise<boolean>;
  resultPage: string;
};

/// Verifies the `t` token of [url], writes its reaction when the recipient
/// row still exists, and answers a 303 to `resultPage?ok=1` (written) or
/// `?ok=0` (missing, bad, expired or orphaned token, or nothing written);
/// a 500 when no secret is configured (fail closed).
export async function handleReact(url: URL, deps: ReactDeps): Promise<Response> {
  if (!deps.secret) {
    return new Response("misconfigured", { status: 500 });
  }
  const token = url.searchParams.get("t");
  const ok = () => Response.redirect(`${deps.resultPage}?ok=1`, 303);
  const fail = () => Response.redirect(`${deps.resultPage}?ok=0`, 303);
  if (!token) return fail();
  const verdict = await verifyReactToken(token, deps.secret, deps.now());
  if ("error" in verdict) return fail();
  if (!(await deps.recipientExists(verdict.m, verdict.u))) return fail();
  const wrote = await deps.writeReaction(verdict.m, verdict.u, verdict.r);
  return wrote ? ok() : fail();
}
