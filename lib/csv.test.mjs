import assert from "node:assert/strict";
import test from "node:test";
import { sanitizeCsvCell, serializeCsv } from "./csv.mjs";

test("sanitizeCsvCell protects formula-leading text and preserves numbers", () => {
  const cases = [
    ["=1+1", "'=1+1"],
    ["+cmd", "'+cmd"],
    ["-1", "'-1"],
    ["@SUM(A1)", "'@SUM(A1)"],
    ["\t=1", "'\t=1"],
    [" =1", "' =1"],
    ["normal", "normal"],
  ];

  for (const [value, expected] of cases) {
    assert.equal(sanitizeCsvCell(value), expected);
  }
  assert.equal(sanitizeCsvCell(42.5), 42.5);
  assert.equal(typeof sanitizeCsvCell(42.5), "number");
});

test("serializeCsv sanitizes formula-leading cells", () => {
  assert.equal(
    serializeCsv([["=1+1", "+cmd", "-1", "@SUM(A1)", "\t=1", " =1", "normal", 42]]),
    "\"'=1+1\",\"'+cmd\",\"'-1\",\"'@SUM(A1)\",\"'\t=1\",\"' =1\",\"normal\",\"42\"",
  );
});

test("serializeCsv quotes commas, quotes, and embedded newlines", () => {
  assert.equal(
    serializeCsv([["Name"], ['Smith, "Jane"\nDoe']]),
    '"Name"\r\n"Smith, ""Jane""\nDoe"',
  );
});