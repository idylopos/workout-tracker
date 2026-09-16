import test from "node:test";
import assert from "node:assert/strict";
import { progressDisclosureOpen } from "../lib.js";

test("Optional Progress sections initially collapse when empty and open for saved data", () => {
  assert.equal(progressDisclosureOpen({ open: false, hasData: false, scopeChanged: true }), false);
  assert.equal(progressDisclosureOpen({ open: false, hasData: true, scopeChanged: true }), true);
});

test("Re-rendering respects an explicitly opened empty form or closed populated history", () => {
  assert.equal(progressDisclosureOpen({ open: true, hasData: false, previousHasData: false, scopeChanged: false }), true);
  assert.equal(progressDisclosureOpen({ open: false, hasData: true, previousHasData: true, scopeChanged: false }), false);
});

test("First saved data opens the history and a new plan does not inherit old disclosure state", () => {
  assert.equal(progressDisclosureOpen({ open: false, hasData: true, previousHasData: false, scopeChanged: false }), true);
  assert.equal(progressDisclosureOpen({ open: true, hasData: false, previousHasData: true, scopeChanged: true }), false);
});
