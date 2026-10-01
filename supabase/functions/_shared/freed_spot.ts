// Text of the „a spot was freed“ notification (0058) — pure, so the wording
// is tested without a webhook, a database or a phone.

export type Message = { title: string; body: string };

/** [when]: 'st 8.10. 17:00–18:00, dráha 2', as the other reservation texts. */
export const freedSpotMessage = (when: string): Message => ({
  title: "Uvolnilo se místo 🎳",
  body: `${when} — zarezervuj si ho, dokud je volné.`,
});
