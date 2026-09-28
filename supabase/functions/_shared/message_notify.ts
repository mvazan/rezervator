// notify's delivery of a new messages row and of a reaction on it (0051),
// kept apart from notify/index.ts so it can be tested (the
// duty_reminders.ts shape). Both take their send function injected.

import type { Delivery } from "./delivery.ts";
import {
  appMessageUrl,
  appNoticeUrl,
  messageEmailHtml,
  noticeEmailHtml,
  noticeText,
  playerMessageText,
  reactionText,
  staffMessageText,
} from "./message_texts.ts";

/// A notification recipient: the profile's id, e-mail and push token.
export type Recipient = { id: string; email: string; fcm_token: string | null };

/// The `messages` row (0051) as the webhook's `record` carries it — only
/// the columns delivery reads.
export type MessageRow = {
  id: string;
  tenant_id: string;
  kind: "notice" | "message";
  audience: "all" | "day" | "block" | "admins" | "duty";
  author_id: string | null;
  author_role: "admin" | "player";
  on_date: string | null;
  block_id: string | null;
  title: string | null;
  body: string;
  notify: boolean;
};

/// The `message_recipients` row (0051) as the webhook's `record` carries
/// it — only the columns a reaction notification reads.
export type MessageRecipientRow = {
  message_id: string;
  user_id: string;
  reaction: "up" | "down" | null;
  reply: string | null;
};

/// What changed on a message_recipients UPDATE that is worth telling the
/// author about: a fresh reaction or reply (either alone counts) — then
/// the row's whole current answer, both halves. Never a clear, not even a
/// half one: taking back the 👍 while the reply stays (or the reverse)
/// sends nothing, since nothing new was said. `old` may be a partial row
/// (the webhook's old_record).
export function reactionChange(
  old: Partial<MessageRecipientRow>,
  record: MessageRecipientRow,
): { reaction: "up" | "down" | null; reply: string | null } | null {
  const freshReaction = record.reaction != null && record.reaction !== old.reaction;
  const freshReply = record.reply != null && record.reply.trim() !== "" &&
    record.reply !== old.reply;
  if (!freshReaction && !freshReply) return null;
  return { reaction: record.reaction, reply: record.reply };
}

/// Sends [record] to every one of [recipients], sequentially (not
/// Promise.all — Resend's free tier rate-limits around 2 req/s, and a
/// 40-player "all" notice would trip it with no retry). Returns how many
/// sends were attempted. record.notify === false sends nothing.
export async function deliverMessage(
  record: MessageRow,
  ctx: { authorName: string; authorIsAdmin: boolean; context: string | null },
  recipients: Recipient[],
  deps: {
    send: (
      r: Recipient,
      title: string,
      body: string,
      opts: { data?: Record<string, string>; html?: string },
    ) => Promise<Delivery>;
    reactLink: (userId: string, reaction: "up" | "down") => Promise<string>;
  },
): Promise<number> {
  if (!record.notify) return 0;
  // The same text for everyone: who wrote it and what about does not
  // depend on the recipient.
  const text = record.kind === "notice"
    ? noticeText(record.title ?? "", record.body)
    : record.audience === "admins" || record.audience === "duty"
    ? playerMessageText(ctx.authorName, record.body, ctx.context)
    : staffMessageText(record.body, { fromAdmin: ctx.authorIsAdmin, context: ctx.context });
  let attempted = 0;
  for (const r of recipients) {
    // A message's e-mail carries the recipient's own signed 👍/👎 links.
    let html: string;
    if (record.kind === "message") {
      const [upLink, downLink] = await Promise.all([
        deps.reactLink(r.id, "up"),
        deps.reactLink(r.id, "down"),
      ]);
      html = messageEmailHtml(text, { upLink, downLink, appLink: appMessageUrl(record.id) });
    } else {
      html = noticeEmailHtml(text.title, record.body, appNoticeUrl(record.id));
    }
    attempted++;
    await deps.send(r, text.title, text.body, {
      data: { kind: record.kind, message_id: record.id },
      html,
    });
  }
  return attempted;
}

/// Notifies [ctx.message]'s author of a fresh reaction/reply. False (sends
/// nothing) for a notice, or a message whose author profile could not be
/// loaded (deleted account). [changed] is reactionChange's verdict — a
/// clear never gets here.
export async function deliverReaction(
  record: MessageRecipientRow,
  changed: { reaction: "up" | "down" | null; reply: string | null },
  ctx: { message: MessageRow; author: Recipient | null; reactorName: string },
  send: (
    r: Recipient,
    title: string,
    body: string,
    opts: { data?: Record<string, string> },
  ) => Promise<Delivery>,
): Promise<boolean> {
  if (ctx.message.kind !== "message") return false;
  if (ctx.author == null) return false;
  const text = reactionText(ctx.reactorName, changed.reaction, changed.reply);
  await send(ctx.author, text.title, text.body, {
    data: { kind: "message_reaction", message_id: record.message_id },
  });
  return true;
}
