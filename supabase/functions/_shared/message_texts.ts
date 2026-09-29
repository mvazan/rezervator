// Texts of the messages/nástěnka notifications (0051) — pure, so the
// wording is tested without a webhook, a database or a phone. Template:
// group_messages.ts.

import { dutyDayLabel, escapeHtml, timeLabel } from "./format.ts";

/// A notification text: the push title and body (the e-mail subject and
/// its plain text); the same shape as group_messages.ts's.
export type Message = { title: string; body: string };

/// The web app the e-mail links open.
export const APP_ORIGIN = "https://rezervator.online";

/// A message (Zprávy) and a notice (Nástěnka) deep link — the hash routes
/// go_router serves on web.
export const appMessageUrl = (id: string): string => `${APP_ORIGIN}/#/zpravy/${id}`;
export const appNoticeUrl = (id: string): string => `${APP_ORIGIN}/#/nastenka/${id}`;

/// What a message is about, from its `messages` row: the audience and,
/// for a day/block/training message, the date and the block's times.
export type MessageContext = {
  audience: string;
  onDate: string | null;
  blockStart: string | null;
  blockEnd: string | null;
};

/// "pá 2. 10. · 16:00–17:00" (block), "celý den pá 2. 10." (day), "k
/// tréninku po 5. 10. · 18:00–19:00" (a player's message about a
/// training, audience admins/duty with a date), or null (admins/duty
/// with no date, or a notice).
export function messageContext(ctx: MessageContext): string | null {
  if (ctx.onDate == null) return null;
  const day = dutyDayLabel(ctx.onDate);
  const time = ctx.blockStart != null && ctx.blockEnd != null
    ? ` · ${timeLabel(ctx.blockStart)}–${timeLabel(ctx.blockEnd)}`
    : "";
  if (ctx.audience === "day") return `celý den ${day}`;
  if (ctx.audience === "block") return `${day}${time}`;
  return `k tréninku ${day}${time}`;
}

/// Cuts [text] to at most [max] UTF-16 units for a notice's push preview,
/// breaking on whitespace (a space or a line break) so no word is split.
/// A text with no whitespace to break on is cut hard at [max] — then the
/// cut backs off by one unit rather than end on half a surrogate pair
/// (an emoji), which would not be valid Unicode in the push payload.
export function cutOnWord(text: string, max = 120): string {
  if (text.length <= max) return text;
  const slice = text.slice(0, max);
  // The next unit is whitespace: the slice ends on a whole word.
  if (/\s/.test(text[max])) return slice.trimEnd();
  const lastSpace = slice.search(/\s\S*$/);
  const onWord = lastSpace > 0 ? slice.slice(0, lastSpace).trimEnd() : "";
  if (onWord.length > 0) return onWord;
  return /[\uD800-\uDBFF]$/.test(slice) ? slice.slice(0, -1) : slice;
}

/// A notice's push: its title, and the body cut to 120 characters.
export function noticeText(title: string, body: string): Message {
  return { title, body: cutOnWord(body, 120) };
}

/// Staff → players: „Zpráva od správce“ / „Zpráva od služby“ (no name),
/// the text and then the context on its own line. Not for a message to the
/// staff: deliverMessage picks [adminToStaffMessageText] or
/// [playerMessageText] there, by the author's role.
export function staffMessageText(
  body: string,
  opts: { fromAdmin: boolean; context: string | null },
): Message {
  const title = opts.fromAdmin ? "Zpráva od správce" : "Zpráva od služby";
  return { title, body: opts.context ? `${body}\n${opts.context}` : body };
}

/// Admin → staff („Správci“, „Službě“): „Zpráva od správce ({jméno})“ —
/// the app's „Od správce (…)“ header — the text and then the context when
/// the message carries one. Only for an admin author (`author_role`
/// 'admin'); never the player title.
export function adminToStaffMessageText(
  authorName: string,
  body: string,
  context: string | null,
): Message {
  return {
    title: `Zpráva od správce (${authorName})`,
    body: context ? `${body}\n${context}` : body,
  };
}

/// Player → staff: „Zpráva od hráče: {jméno}“, the text and then the context
/// when the message carries one. Only for a player author (`author_role`
/// 'player', the duty included); an admin → staff is
/// [adminToStaffMessageText].
export function playerMessageText(
  authorName: string,
  body: string,
  context: string | null,
): Message {
  return {
    title: `Zpráva od hráče: ${authorName}`,
    body: context ? `${body}\n${context}` : body,
  };
}

/// A reaction, a reply, or both (a reply alone is allowed — the tile lets
/// a recipient answer without pressing a chip).
export function reactionText(
  reactorName: string,
  reaction: "up" | "down" | null,
  reply: string | null,
): Message {
  const parts: string[] = [];
  if (reaction) parts.push(reaction === "up" ? "👍" : "👎");
  if (reply && reply.trim().length > 0) parts.push(reply.trim());
  return {
    title: "Reakce na tvou zprávu",
    body: `${reactorName}: ${parts.join(" ")}`,
  };
}

/// A `message`'s e-mail: the text (its context is already the last line
/// of `m.body`, see staffMessageText/playerMessageText) and — since e-mail
/// recipients have no in-app reply — two one-click 👍/👎 links plus a
/// link into the app for a text reply.
export function messageEmailHtml(
  m: Message,
  opts: { upLink: string; downLink: string; appLink: string },
): string {
  const bodyHtml = escapeHtml(m.body).replace(/\n/g, "<br>");
  return `<p>${bodyHtml}</p>` +
    `<p><a href="${opts.upLink}">👍</a> &nbsp; <a href="${opts.downLink}">👎</a></p>` +
    `<p><a href="${opts.appLink}">Odpovědět v aplikaci</a></p>`;
}

/// A notice's e-mail: the title, the full text and „Otevřít nástěnku“.
export function noticeEmailHtml(title: string, body: string, boardLink: string): string {
  return `<p><b>${escapeHtml(title)}</b></p>` +
    `<p>${escapeHtml(body).replace(/\n/g, "<br>")}</p>` +
    `<p><a href="${boardLink}">Otevřít nástěnku</a></p>`;
}
