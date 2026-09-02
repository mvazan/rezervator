// Formatting helpers shared by notify and cancel: HTML escaping for e-mail
// bodies / the cancel page, and the Czech day + time labels
// ("po 13.7.", "17:30") used in notification texts.

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
