import assert from "node:assert/strict";
import test from "node:test";
import { createReportPrintHtml } from "./report-print.mjs";

test("printable reports escape untrusted titles, headers, and cell values", () => {
  const html = createReportPrintHtml({
    title: "<img src=x onerror=alert(1)>",
    description: "Report",
    startDate: "2026-01-01",
    endDate: "2026-01-31",
    generatedAt: "Nov 17, 2026, 8:28 AM",
    headers: ["Equipment"],
    rows: [["<script>alert(1)</script>"]],
  });

  assert.match(html, /&lt;img src=x onerror=alert\(1\)&gt;/);
  assert.match(html, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
  assert.match(html, /Generated: Nov 17, 2026, 8:28 AM \(Asia\/Manila\)/);
  assert.doesNotMatch(html, /<script>|<img/);
});

test("printable reports include all rows and flag capped exports", () => {
  const html = createReportPrintHtml({
    title: "Utilization",
    description: "Borrowed unit-days.",
    startDate: "2026-01-01",
    endDate: "2026-01-31",
    headers: ["Equipment"],
    rows: [["Camera"], ["Laptop"]],
    truncated: true,
  });

  assert.match(html, /2 rows/);
  assert.match(html, /Camera/);
  assert.match(html, /Laptop/);
  assert.match(html, /capped at 5,000 rows/);
});
