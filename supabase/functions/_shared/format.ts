// Formatting helpers shared by notify and cancel: HTML escaping for e-mail
// bodies / the cancel page, the Czech day + time labels ("po 13.7.",
// "17:30") used in notification texts, and how long "before" reads in
// Czech.

export function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

export function dayLabel(sqlDate: string): string {
  const names = ["ne", "po", "út", "st", "čt", "pá", "so"];
  const d = new Date(`${sqlDate}T00:00:00Z`);
  return `${names[d.getUTCDay()]} ${d.getUTCDate()}.${d.getUTCMonth() + 1}.`;
}

export function timeLabel(sqlTime: string): string {
  const [h, m] = sqlTime.split(":");
  return `${Number(h)}:${m}`;
}

/// "za 2 hodiny", "za 1 den" — how a reminder announces its own lead time
/// (0040). Czech counts three ways and the unit changes at a day, so this
/// is a table rather than a format string; whole days read as days, the
/// rest as hours or minutes.
export function leadLabel(minutes: number): string {
  if (minutes <= 0) return "právě teď";
  if (minutes % 1440 === 0) {
    const days = minutes / 1440;
    if (days === 1) return "zítra";
    return `za ${days} ${days < 5 ? "dny" : "dnů"}`;
  }
  if (minutes % 60 === 0) {
    const hours = minutes / 60;
    if (hours === 1) return "za hodinu";
    return `za ${hours} ${hours < 5 ? "hodiny" : "hodin"}`;
  }
  if (minutes === 1) return "za minutu";
  return `za ${minutes} ${minutes < 5 ? "minuty" : "minut"}`;
}
