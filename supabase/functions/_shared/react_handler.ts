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

import { isMemberOf, type Membership } from "./membership.ts";
import { verifyReactToken } from "./react_token.ts";

/// What handleReact needs from the outside world: the HMAC secret
/// (undefined = not configured), a clock (epoch ms), the recipient lookup
/// (true when the row exists and its account may react — see [mayReact])
/// and write (true when a row was updated) — both service role in the
/// deployed function, both throw on a database error — the static page to
/// redirect to, and where to log a failure (console.error when deployed).
export type ReactDeps = {
  secret: string | undefined;
  now: () => number;
  recipientMayReact: (messageId: string, userId: string) => Promise<boolean>;
  writeReaction: (messageId: string, userId: string, reaction: "up" | "down") => Promise<boolean>;
  resultPage: string;
  logError: (message: string, detail?: unknown) => void;
};

/// A message_recipients row with its account, as the deployed lookup
/// selects it (`tenant_id, profiles!inner(status, role, tenant_id)`).
/// PostgREST embeds the to-one profile as an object; the untyped client
/// types it as an array, so both are read (federation_jobs.ts does the same).
export type RecipientMembership = {
  tenant_id: string;
  profiles: Membership | Membership[] | null;
};

/// Whether the e-mail link may still write [row]'s reaction: the app's own
/// rule (message_recipients_update_own, plus the select policy's alley
/// check), which the service role would otherwise bypass — the row exists
/// and its account is an approved non-kiosk member of the row's alley
/// ([isMemberOf], the same rule notify applies to a reaction's author). An
/// account set as the kiosk, back to pending or moved to another alley
/// reacts to nothing, from the app or from an e-mail.
export function mayReact(row: RecipientMembership | null): boolean {
  if (row == null) return false;
  const embedded = row.profiles;
  const profile = Array.isArray(embedded) ? embedded[0] : embedded;
  return isMemberOf(profile, row.tenant_id);
}

/// Answers a [method] request for [url]. GET verifies the `t` token, writes
/// its reaction when the recipient may still react, and answers a 303 to
/// `resultPage?ok=1` (written), `?ok=retry` (a database error: the link is
/// fine and a second click may well work) or `?ok=0` (missing, bad, expired
/// or orphaned token, a recipient who may no longer react, nothing
/// written); a 500 when no secret is configured (fail closed).
/// HEAD — what a link scanner or mail gateway probes with — answers the
/// same 303 as far as the token tells, and stops before the database:
/// only the one-click GET is the accepted write. Any other method: 405,
/// nothing written. The misconfiguration and database errors are logged —
/// a dead link on the page must not be the only trace.
export async function handleReact(
  method: string,
  url: URL,
  deps: ReactDeps,
): Promise<Response> {
  if (method !== "GET" && method !== "HEAD") {
    return new Response("method not allowed", {
      status: 405,
      headers: { Allow: "GET, HEAD" },
    });
  }
  if (!deps.secret) {
    deps.logError("CANCEL_TOKEN_SECRET is not set");
    return new Response("misconfigured", { status: 500 });
  }
  const token = url.searchParams.get("t");
  const ok = () => Response.redirect(`${deps.resultPage}?ok=1`, 303);
  const fail = () => Response.redirect(`${deps.resultPage}?ok=0`, 303);
  const retry = () => Response.redirect(`${deps.resultPage}?ok=retry`, 303);
  if (!token) return fail();
  const verdict = await verifyReactToken(token, deps.secret, deps.now());
  if ("error" in verdict) return fail();
  if (method === "HEAD") return ok();
  let allowed: boolean;
  try {
    allowed = await deps.recipientMayReact(verdict.m, verdict.u);
  } catch (error) {
    deps.logError("react lookup failed:", error);
    return retry();
  }
  if (!allowed) return fail();
  let wrote: boolean;
  try {
    wrote = await deps.writeReaction(verdict.m, verdict.u, verdict.r);
  } catch (error) {
    deps.logError("react write failed:", error);
    return retry();
  }
  return wrote ? ok() : fail();
}
