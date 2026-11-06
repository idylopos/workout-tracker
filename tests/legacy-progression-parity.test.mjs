import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { isGuidedSessionQualified } from "../progression.js";

test("shared legacy progression fixtures retain current web qualification decisions", () => {
  const fixtures = JSON.parse(readFileSync(new URL("./fixtures/legacy-progression-parity.json", import.meta.url), "utf8"));
  for (const fixture of fixtures) {
    assert.equal(isGuidedSessionQualified(fixture.log, fixture.exerciseID, fixture.today), fixture.expectedQualified, fixture.name);
  }
});
