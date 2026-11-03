export function sanitizeCsvCell(value) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  const text = String(value ?? "");
  return /^[ ]*[=+\-@\t\r]/.test(text) ? `'${text}` : text;
}

export function serializeCsv(rows) {
  return rows.map((row) => row.map((value) => {
    const safeValue = sanitizeCsvCell(value);
    return `"${String(safeValue).replaceAll('"', '""')}"`;
  }).join(",")).join("\r\n");
}

export function downloadCsv(fileName, rows) {
  const blobUrl = URL.createObjectURL(new Blob([serializeCsv(rows)], { type: "text/csv;charset=utf-8" }));
  const link = document.createElement("a");
  link.href = blobUrl;
  link.download = fileName;
  link.click();
  URL.revokeObjectURL(blobUrl);
}