import test from "node:test";
import assert from "node:assert/strict";
import {
  UNLOCK_SESSION_DURATION_MS,
  isRememberedUnlockValid,
} from "../unlock-session.js";

const vault = {
  kdf: {
    salt: "test-salt",
    iterations: 310000,
  },
};

test("uses a two-hour remembered unlock window", () => {
  assert.equal(UNLOCK_SESSION_DURATION_MS, 2 * 60 * 60 * 1000);
});

test("accepts only an unexpired key for the same encrypted vault", () => {
  const now = 1_000_000;
  const valid = {
    id: "active",
    key: { type: "secret", extractable: false },
    expiresAt: now + 1,
    salt: "test-salt",
    iterations: 310000,
  };
  assert.equal(isRememberedUnlockValid(valid, vault, now), true);
  assert.equal(isRememberedUnlockValid({ ...valid, expiresAt: now }, vault, now), false);
  assert.equal(isRememberedUnlockValid({ ...valid, salt: "different" }, vault, now), false);
  assert.equal(isRememberedUnlockValid({ ...valid, iterations: 100000 }, vault, now), false);
  assert.equal(isRememberedUnlockValid({ ...valid, key: null }, vault, now), false);
});
