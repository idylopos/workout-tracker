import test from "node:test";
import assert from "node:assert/strict";
import {
  APP_VERSION,
  createDefaultState,
  dateToDayKey,
  findPreviousExerciseLog,
  normalizeState,
  summarizeExercise,
  validateBackup,
} from "../lib.js";

test("maps local dates to the correct training day", () => {
  assert.equal(dateToDayKey("2026-07-27"), "monday");
  assert.equal(dateToDayKey("2026-08-02"), "sunday");
});

test("normalizes a partial persisted state", () => {
  const state = normalizeState({ settings: { block: 2 }, bodyLogs: [] });
  assert.equal(state.version, APP_VERSION);
  assert.equal(state.settings.block, 2);
  assert.deepEqual(state.workoutLogs, {});
  assert.deepEqual(state.sleepLogs, []);
});

test("validates backup shape before restore", () => {
  const valid = validateBackup(createDefaultState());
  assert.equal(valid.valid, true);

  const invalid = validateBackup({ version: APP_VERSION, workoutLogs: [] });
  assert.equal(invalid.valid, false);

  const malformedWorkout = createDefaultState();
  malformedWorkout.workoutLogs["not-a-date"] = { exercises: {} };
  assert.equal(validateBackup(malformedWorkout).valid, false);
});

test("finds the most recent earlier exercise log", () => {
  const logs = {
    "2026-07-01": {
      date: "2026-07-01",
      exercises: { squat: { measurement: "weight_reps", sets: [{ weight: 50, reps: 8 }] } },
    },
    "2026-07-08": {
      date: "2026-07-08",
      exercises: { squat: { measurement: "weight_reps", sets: [{ weight: 55, reps: 8 }] } },
    },
  };
  const previous = findPreviousExerciseLog(logs, "squat", "2026-07-10");
  assert.equal(previous.date, "2026-07-08");
  assert.equal(previous.sets[0].weight, 55);
});

test("keeps previous exercise values separated by plan", () => {
  const logs = {
    default: {
      date: "2026-07-08",
      planId: "form-flow",
      exercises: { squat: { measurement: "weight_reps", sets: [{ weight: 55, reps: 8 }] } },
    },
    custom: {
      date: "2026-07-09",
      planId: "custom-plan",
      exercises: { squat: { measurement: "weight_reps", sets: [{ weight: 20, reps: 10 }] } },
    },
  };
  assert.equal(findPreviousExerciseLog(logs, "squat", "2026-07-10", "form-flow").sets[0].weight, 55);
  assert.equal(findPreviousExerciseLog(logs, "squat", "2026-07-10", "custom-plan").sets[0].weight, 20);
});

test("summarizes strength sessions and estimated best performance", () => {
  const logs = {
    first: {
      date: "2026-07-01",
      exercises: { press: { measurement: "weight_reps", sets: [{ weight: 20, reps: 10 }] } },
    },
    second: {
      date: "2026-07-08",
      exercises: { press: { measurement: "weight_reps", sets: [{ weight: 22, reps: 8 }] } },
    },
  };
  const summary = summarizeExercise(logs, "press");
  assert.equal(summary.sessions, 2);
  assert.equal(summary.latest, "22 kg × 8");
  assert.equal(summary.best, "22 kg × 8");
  assert.equal(summary.points.length, 2);
});
