/** Password for a kiosk account: someone types it on a tablet, by hand,
 * once — so it is lowercase, groups of four, and free of characters that
 * look alike in a sans-serif font (0/o, 1/l/i, 5/s, 2/z). Four groups out
 * of a 28-character alphabet are ~77 bits, far past anything worth
 * guessing at a login form. */
const ALPHABET = "abcdefghjkmnpqrtuvwxy34689";
const GROUPS = 4;
const GROUP_LENGTH = 4;

export function newKioskPassword(
  randomBytes: (n: number) => Uint8Array = (n) =>
    crypto.getRandomValues(new Uint8Array(n)),
): string {
  const total = GROUPS * GROUP_LENGTH;
  const out: string[] = [];
  // Rejection sampling: taking a raw byte modulo 26 would make the first
  // few letters likelier than the rest.
  const limit = 256 - (256 % ALPHABET.length);
  while (out.length < total) {
    for (const byte of randomBytes(total)) {
      if (byte >= limit) continue;
      out.push(ALPHABET[byte % ALPHABET.length]);
      if (out.length === total) break;
    }
  }
  return Array.from(
    { length: GROUPS },
    (_, g) => out.slice(g * GROUP_LENGTH, (g + 1) * GROUP_LENGTH).join(""),
  ).join("-");
}
