import test from "node:test";
import assert from "node:assert/strict";
import { createVault, unlockVault, unlockVaultWithKey } from "../crypto-vault.js";

test("encrypts state without leaving plaintext in the vault", async () => {
  const state = {
    bodyLogs: [{ date: "2026-07-29", weight: 72.4 }],
    workoutLogs: {},
    workoutDrafts: {
      "2026-07-31": {
        date: "2026-07-31",
        exercises: { press: { measurement: "weight_reps", sets: [{ weight: 24, reps: 8 }] } },
      },
    },
  };
  const created = await createVault(state, "a-long-test-passphrase");
  const serialized = JSON.stringify(created.vault);
  assert.equal(serialized.includes("72.4"), false);
  assert.equal(serialized.includes("bodyLogs"), false);
  assert.equal(serialized.includes("workoutDrafts"), false);
  assert.equal(serialized.includes("press"), false);

  const unlocked = await unlockVault(created.vault, "a-long-test-passphrase");
  assert.deepEqual(unlocked.state, state);
  assert.equal(unlocked.key.extractable, false);

  const resumed = await unlockVaultWithKey(created.vault, unlocked.key);
  assert.deepEqual(resumed.state, state);
});

test("rejects an incorrect passphrase", async () => {
  const created = await createVault({ workoutLogs: {} }, "correct-test-passphrase");
  await assert.rejects(() => unlockVault(created.vault, "incorrect-passphrase"));
});
