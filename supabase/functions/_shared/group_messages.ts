// Texts of the player-group notifications (0044) — pure, so the wording is
// tested without a webhook, a database or a phone.

export type Message = { title: string; body: string };

export const groupInviteMessage = (inviter: string): Message => ({
  title: "Pozvánka do skupiny",
  body: `${inviter} tě zve do skupiny — přijmi ji v Můj profil.`,
});

export const groupJoinedMessage = (joiner: string): Message => ({
  title: "Nový člen skupiny",
  body: `${joiner} je teď ve skupině.`,
});

export const groupBookedMessage = (by: string, when: string): Message => ({
  title: "Trénink zarezervován",
  body: `${by} ti zarezervoval(a) trénink: ${when}.`,
});

export const groupCancelledMessage = (by: string, when: string): Message => ({
  title: "Trénink zrušen",
  body: `${by} ti zrušil(a) trénink: ${when}.`,
});
