// notify's delivery of a new messages row and of a reaction on it (0051),
// kept apart from notify/index.ts so it can be tested (the
// duty_reminders.ts shape). Both take their send functions injected.

import type { Delivery } from "./delivery.ts";
import { isMemberOf, type Membership } from "./membership.ts";
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

/// One e-mail of a Resend batch: the address and the finished message.
export type Email = { to: string; subject: string; html: string };

/// Resend takes at most this many e-mails in one /emails/batch request.
export const emailBatchSize = 100;

/// How long a batch Resend refused as busy (429) or down (5xx) waits
/// before its one more try: the rate limit is per second.
export const emailRetryPauseMs = 1000;

/// What deliverMessage sends with — injected, so it can be tested.
export type MessageDeps = {
  /// Whether [r] gets it by push (FCM configured and a token); everyone
  /// else is e-mailed.
  byPush: (r: Recipient) => boolean;
  push: (
    r: Recipient,
    title: string,
    body: string,
    opts: { data?: Record<string, string> },
  ) => Promise<Delivery>;
  /// One Resend /emails/batch request of at most [emailBatchSize].
  sendEmails: (emails: Email[]) => Promise<Delivery>;
  reactLink: (userId: string, reaction: "up" | "down") => Promise<string>;
  pause: (ms: number) => Promise<void>;
};

/// Sends [record] to every one of [recipients]. Pushes go one at a time
/// (not Promise.all over the whole list). E-mails go out as Resend
/// batches of up to [emailBatchSize] — one request each, not one per
/// recipient, so a 40-player "all" notice to web-only players cannot trip
/// Resend's per-second rate limit, and the fan-out stays short (pg_net
/// gives the webhook 5 s). A batch Resend answers as busy or down is
/// tried once more after [emailRetryPauseMs]. A recipient whose push or
/// links throw, or a batch that throws, is logged and skipped; the rest
/// still get theirs. Returns how many sends were attempted (each e-mail
/// of a batch counts, a retry does not). record.notify === false sends
/// nothing.
export async function deliverMessage(
  record: MessageRow,
  ctx: { authorName: string; authorIsAdmin: boolean; context: string | null },
  recipients: Recipient[],
  deps: MessageDeps,
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
  const emails: Email[] = [];
  for (const r of recipients) {
    // One recipient's failure (a network error in fetch, an FCM OAuth
    // failure, a link that cannot be signed) is logged and skipped: the
    // webhook is not retried, so throwing would cost everyone after it
    // their one attempt. A missing CANCEL_TOKEN_SECRET is the caller's
    // check, made once before the fan-out.
    try {
      if (deps.byPush(r)) {
        attempted++;
        await deps.push(r, text.title, text.body, {
          data: pushData(record.kind, record.id, record.tenant_id),
        });
        continue;
      }
      if (!r.email) {
        console.error(`message ${record.id} to ${r.id} skipped: no push token, no e-mail`);
        continue;
      }
      emails.push({ to: r.email, subject: text.title, html: await emailHtml(record, text, r, deps) });
    } catch (error) {
      console.error(`message ${record.id} to ${r.id} failed:`, error);
    }
  }
  for (let i = 0; i < emails.length; i += emailBatchSize) {
    const batch = emails.slice(i, i + emailBatchSize);
    attempted += batch.length;
    try {
      let delivery = await deps.sendEmails(batch);
      if (delivery === "retry") {
        await deps.pause(emailRetryPauseMs);
        delivery = await deps.sendEmails(batch);
      }
      if (delivery !== "delivered") {
        console.error(`message ${record.id}: e-mail batch of ${batch.length} not sent (${delivery})`);
      }
    } catch (error) {
      console.error(`message ${record.id}: e-mail batch of ${batch.length} failed:`, error);
    }
  }
  return attempted;
}

/// [record]'s e-mail to [r]: a message's carries r's own signed 👍/👎
/// links, a notice's the nástěnka link.
async function emailHtml(
  record: MessageRow,
  text: { title: string; body: string },
  r: Recipient,
  deps: MessageDeps,
): Promise<string> {
  if (record.kind === "notice") {
    return noticeEmailHtml(text.title, record.body, appNoticeUrl(record.id));
  }
  const [upLink, downLink] = await Promise.all([
    deps.reactLink(r.id, "up"),
    deps.reactLink(r.id, "down"),
  ]);
  return messageEmailHtml(text, { upLink, downLink, appLink: appMessageUrl(record.id) });
}

/// Notifies [ctx.message]'s author of a fresh reaction/reply. False (sends
/// nothing) for a notice, a message whose author profile could not be
/// loaded (deleted account), or an author who may no longer read it — set
/// as the kiosk, back to pending or moved to another alley ([isMemberOf],
/// the rule the react function's mayReact applies): the reactor's name
/// and reply must not reach an account the app would deny them to.
/// [changed] is reactionChange's verdict — a clear never gets here.
export async function deliverReaction(
  record: MessageRecipientRow,
  changed: { reaction: "up" | "down" | null; reply: string | null },
  ctx: { message: MessageRow; author: (Recipient & Membership) | null; reactorName: string },
  send: (
    r: Recipient,
    title: string,
    body: string,
    opts: { data?: Record<string, string> },
  ) => Promise<Delivery>,
): Promise<boolean> {
  if (ctx.message.kind !== "message") return false;
  const author = ctx.author;
  if (author == null || !isMemberOf(author, ctx.message.tenant_id)) return false;
  const text = reactionText(ctx.reactorName, changed.reaction, changed.reply);
  await send(author, text.title, text.body, {
    data: pushData("message_reaction", record.message_id, ctx.message.tenant_id),
  });
  return true;
}

/// A message push's `data`: what it is, which message, and its alley — so
/// the app opens the message only while signed in to that alley (an
/// account can move; a tap on an old push must not open a wrong one).
function pushData(
  kind: "message" | "notice" | "message_reaction",
  messageId: string,
  tenantId: string,
): Record<string, string> {
  return { kind, message_id: messageId, tenant_id: tenantId };
}
