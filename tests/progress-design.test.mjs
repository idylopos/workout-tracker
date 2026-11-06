import test from "node:test";
import assert from "node:assert/strict";
import { progressExerciseOptions, summarizeExercise } from "../lib.js";

const exercises = [
  { id: "nordic", name: "Assisted Nordic hamstring" },
  { id: "row", name: "Chest-supported row" },
  { id: "press", name: "Press" },
];
const logs = {
  older: { date: "2026-09-09", exercises: {
    row: { measurement: "weight_reps", sets: [{ weight: 30, reps: 8 }] },
    nordic: { measurement: "reps", sets: [{ reps: "", rir: 3, completed: false }] },
  } },
  newer: { date: "2026-09-16", exercises: {
    press: { measurement: "weight_reps", sets: [{ weight: 20, reps: 10 }] },
  } },
};

test("Progress opens recent recorded results rather than the first unlogged exercise", () => {
  const before = structuredClone(logs);
  const choices = progressExerciseOptions(exercises, logs);
  assert.equal(choices.selectedId, "press");
  assert.deepEqual(choices.logged.map((exercise) => exercise.id), ["press", "row"]);
  assert.deepEqual(choices.unlogged.map((exercise) => exercise.id), ["nordic"]);
  assert.deepEqual(logs, before);
  assert.equal(summarizeExercise(logs, "nordic").sessions, 0);
});

test("Progress keeps explicit choices, handles empty history and rejects a missing plan exercise", () => {
  assert.equal(progressExerciseOptions(exercises, logs, "nordic").selectedId, "nordic");
  assert.equal(progressExerciseOptions(exercises, logs, "another-plan").selectedId, "press");
  assert.equal(progressExerciseOptions(exercises, {}).selectedId, "nordic");
  assert.equal(progressExerciseOptions([], {}).selectedId, "");
});

test("Progress recognizes completed mobility and bodyweight reps without inventing load", () => {
  const recorded = { day: { date: "2026-09-16", exercises: {
    nordic: { measurement: "reps", sets: [{ reps: 5 }] },
    row: { measurement: "completion", sets: [{ completed: true }] },
    press: { measurement: "weight_reps", sets: [{ weight: 30, reps: "" }] },
  } } };
  assert.deepEqual(progressExerciseOptions(exercises, recorded).logged.map((exercise) => exercise.id), ["nordic", "row"]);
});

test("a leg curl logged instead of a deadlift has its own exercise history", () => {
  const deadlift = { id: "trap-bar-deadlift", name: "Trap-bar deadlift" };
  const workout = { date: "2026-11-05", exercises: { [deadlift.id]: {
    variantId: "seated-leg-curl", variantName: "Seated leg curl",
    measurement: "weight_reps", sets: [{ weight: 15, reps: 10 }],
  } } };
  const logs = { thursday: workout };
  const options = progressExerciseOptions([deadlift], logs);
  assert.deepEqual(options.logged.map(option => option.name), ["Seated leg curl"]);
  assert.equal(summarizeExercise(logs, deadlift.id).sessions, 0);
  assert.equal(summarizeExercise(logs, "seated-leg-curl").sessions, 1);
});
