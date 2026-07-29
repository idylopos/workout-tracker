import test from "node:test";
import assert from "node:assert/strict";
import { createVault, unlockVault } from "../crypto-vault.js";

test("encrypts state without leaving plaintext in the vault", async () => {
  const state = { bodyLogs: [{ date: "2026-07-29", weight: 72.4 }], workoutLogs: {} };
  const created = await createVault(state, "a-long-test-passphrase");
  const serialized = JSON.stringify(created.vault);
  assert.equal(serialized.includes("72.4"), false);
  assert.equal(serialized.includes("bodyLogs"), false);

  const unlocked = await unlockVault(created.vault, "a-long-test-passphrase");
  assert.deepEqual(unlocked.state, state);
});

test("rejects an incorrect passphrase", async () => {
  const created = await createVault({ workoutLogs: {} }, "correct-test-passphrase");
  await assert.rejects(() => unlockVault(created.vault, "incorrect-passphrase"));
});

