function parseDate(value) {
  if (value === null || value === undefined || value === "") return null;
  const text = String(value);
  const date = new Date(/^\d{4}-\d{2}-\d{2}$/.test(text) ? `${text}T00:00:00+08:00` : text);
  return Number.isNaN(date.getTime()) ? null : date;
}

export function formatManilaDate(value) {
  const date = parseDate(value);
  if (!date) return value ? String(value) : "";
  return new Intl.DateTimeFormat("en", {
    dateStyle: "medium",
    timeZone: "Asia/Manila",
  }).format(date);
}

export function formatManilaDateTime(value) {
  const date = parseDate(value);
  if (!date) return value ? String(value) : "";
  return new Intl.DateTimeFormat("en", {
    dateStyle: "medium",
    timeStyle: "short",
    timeZone: "Asia/Manila",
  }).format(date);
}
