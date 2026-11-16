import { formatManilaDateTime } from "./datetime.mjs";

function escapeHtml(value) {
  return String(value ?? "—")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

export function createReportPrintHtml({ title, description, startDate, endDate, generatedAt = new Date(), headers, rows, truncated }) {
  const tableHeaders = headers.map((header) => `<th>${escapeHtml(header)}</th>`).join("");
  const tableRows = rows.map((row) => `<tr>${row.map((value) => `<td>${escapeHtml(value)}</td>`).join("")}</tr>`).join("");
  const generatedLabel = typeof generatedAt === "string" ? generatedAt : formatManilaDateTime(generatedAt);
  const truncationNotice = truncated
    ? "<p class=\"truncation-notice\">This report was capped at 5,000 rows.</p>"
    : "";

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(title)} report</title>
  <style>
    @page { size: landscape; margin: 14mm; }
    * { box-sizing: border-box; }
    body { margin: 0; color: #17201b; font: 10pt Arial, sans-serif; }
    h1 { margin: 0 0 5px; font-size: 19pt; }
    .description, .period, .generated, .row-count { margin: 0 0 7px; color: #526057; }
    .row-count { margin-bottom: 14px; }
    table { width: 100%; border-collapse: collapse; table-layout: auto; }
    thead { display: table-header-group; }
    tr { break-inside: avoid; }
    th, td { padding: 6px 7px; border: 1px solid #dce1dc; text-align: left; vertical-align: top; overflow-wrap: anywhere; }
    th { color: #173f5f; background: #e7f2f8; font-size: 8pt; }
    td { font-size: 8pt; }
    .truncation-notice { margin-top: 12px; color: #765628; font-size: 9pt; }
  </style>
</head>
<body>
  <h1>${escapeHtml(title)}</h1>
  <p class="description">${escapeHtml(description)}</p>
  <p class="period">Period: ${escapeHtml(startDate)} to ${escapeHtml(endDate)}</p>
  <p class="generated">Generated: ${escapeHtml(generatedLabel)} (Asia/Manila)</p>
  <p class="row-count">${rows.length} rows</p>
  <table>
    <thead><tr>${tableHeaders}</tr></thead>
    <tbody>${tableRows}</tbody>
  </table>
  ${truncationNotice}
</body>
</html>`;
}
