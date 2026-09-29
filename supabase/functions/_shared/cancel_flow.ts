// The one-click cancel flow behind the cancel edge function, with the
// database and the clock passed in so its two rules are testable: only a
// POST may cancel, and nothing may once the block has started.
//
// Every answer is a redirect to web/cancel.html, never HTML from here: the
// edge runtime rewrites the Content-Type to text/plain (with nosniff and a
// `sandbox` CSP), so a page served by the function renders as source code and
// its form could not submit anyway. A redirect passes through untouched. The
// page reads `stav` (+ `kdy`, and `token` when it offers the button) and
// POSTs back here itself.

import { pragueEpoch, verifyCancelToken } from "./cancel_token.ts";
import { dayLabel, timeLabel } from "./format.ts";

/** Ships with the Flutter web build: web/cancel.html lands in the site root. */
export const CANCEL_PAGE = "https://rezervator.online/cancel.html";

/** Every `stav` the page must know (a test holds web/cancel.html to it). */
export const CANCEL_STAVS = [
  "potvrdit",
  "zruseno",
  "hotovo",
  "nenalezena",
  "vyprselo",
  "neplatny",
  "chyba",
] as const;
export type CancelStav = typeof CANCEL_STAVS[number];

/** What slotLabel can produce. The page shows `kdy` only when it matches,
 * so a hand-made link cannot put arbitrary text on the club's domain; the
 * same literal sits in web/cancel.html (a test compares them). */
export const KDY_PATTERN =
  /^(po|út|st|čt|pá|so|ne) \d{1,2}\.\d{1,2}\.( \d{1,2}:\d{2}–\d{1,2}:\d{2})?, dráha \d{1,2}$/;

export type Reservation = {
  date: string;
  lane: number;
  block_id: string;
  cancelled_at: string | null;
};
export type Block = { starts_at: string; ends_at: string };

export interface CancelDeps {
  secret: string;
  reservation(rid: string): Promise<Reservation | null>;
  block(id: string): Promise<Block | null>;
  /** true when this call cancelled it, false when it already was; throws
   * when the write fails. */
  cancel(rid: string): Promise<boolean>;
  /** Epoch milliseconds; tests pin it. */
  now?(): number;
}

export function slotLabel(
  reservation: { date: string; lane: number },
  block: Block | null,
): string {
  return block
    ? `${dayLabel(reservation.date)} ${timeLabel(block.starts_at)}–` +
      `${timeLabel(block.ends_at)}, dráha ${reservation.lane}`
    : `${dayLabel(reservation.date)}, dráha ${reservation.lane}`;
}

function show(
  status: 302 | 303,
  stav: CancelStav,
  extra: { kdy?: string; token?: string } = {},
): Response {
  const query = new URLSearchParams({ stav });
  if (extra.kdy) query.set("kdy", extra.kdy);
  if (extra.token) query.set("token", extra.token);
  return Response.redirect(`${CANCEL_PAGE}?${query}`, status);
}

export async function handleCancel(
  request: Request,
  deps: CancelDeps,
): Promise<Response> {
  const post = request.method === "POST";
  if (!post && request.method !== "GET") {
    return new Response("method not allowed", { status: 405 });
  }
  // 303 after the POST: the browser follows it with a GET, so reloading the
  // result never re-submits.
  const status = post ? 303 : 302;
  const token = new URL(request.url).searchParams.get("token") ?? "";

  const verdict = await verifyCancelToken(token, deps.secret);
  if ("error" in verdict) {
    return show(status, verdict.error === "expired" ? "vyprselo" : "neplatny");
  }
  const reservation = await deps.reservation(verdict.rid);
  if (!reservation) return show(status, "nenalezena");
  if (reservation.cancelled_at) return show(status, "hotovo");
  const block = await deps.block(reservation.block_id);
  const kdy = slotLabel(reservation, block);

  // The token expires at the start the reservation had when the link went
  // out, but a move keeps the row (and so the token) and may make it
  // earlier. The block it is in now decides: once that has started,
  // cancelling is an admin decision — a one-click cancel would erase the
  // attendance. time_blocks is FK RESTRICT, so no block means a failed read:
  // refuse rather than guess, and keep the button for a retry.
  if (!block) return show(status, "chyba", { kdy, token });
  const now = deps.now?.() ?? Date.now();
  if (now / 1000 >= pragueEpoch(reservation.date, block.starts_at)) {
    return show(status, "vyprselo", { kdy });
  }

  if (!post) {
    // E-mail link-prefetch scanners follow GETs: this only reads. The page
    // puts the token into its form, and a click on the button POSTs it back.
    return show(status, "potvrdit", { kdy, token });
  }

  let cancelled: boolean;
  try {
    cancelled = await deps.cancel(verdict.rid);
  } catch (error) {
    console.error("cancel failed:", error);
    return show(status, "chyba", { kdy, token });
  }
  return cancelled ? show(status, "zruseno", { kdy }) : show(status, "hotovo");
}
