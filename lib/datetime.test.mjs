import assert from "node:assert/strict";
import test from "node:test";
import { formatManilaDate, formatManilaDateTime } from "./datetime.mjs";

test("date-only values preserve their calendar day in Manila", () => {
  assert.equal(formatManilaDate("2026-11-14"), "Nov 14, 2026");
});

test("date-time values are rendered in Asia/Manila", () => {
  assert.equal(formatManilaDateTime("2026-11-14T00:00:00Z"), "Nov 14, 2026, 8:00 AM");
});
