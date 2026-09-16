import test from "node:test";
import assert from "node:assert/strict";
import {
  EXTRA_ACTIVITY_MEASUREMENTS,
  createDefaultState,
  measurementFields,
  optionalCardioFields,
  preparePreviousSets,
  summarizeCardioRange,
  summarizeCardioSet,
  validateBackup,
} from "../lib.js";

const readings = {
  completed: true, minutes: 24, seconds: 30, distance: 8.25, calories: 285,
  averageRpm: 82.5, averageHeartRate: 151, rpe: 7,
};

test("every cardio measurement can capture the complete machine readout without duplicate fields", () => {
  for (const measurement of EXTRA_ACTIVITY_MEASUREMENTS) {
    const keys = measurementFields(measurement).map((field) => field.key);
    assert.equal(new Set(keys).size, keys.length);
    assert.deepEqual([...keys].sort(), Object.keys(readings).filter((key) => key !== "completed").sort());
  }
  assert.deepEqual(optionalCardioFields("weight_distance"), []);
  assert.deepEqual(optionalCardioFields("weight_reps"), []);
});

test("backup and draft restore retain optional cardio readings and reusable HIIT activities", () => {
  const state = createDefaultState();
  const entry = { measurement: "duration", sets: [readings] };
  const log = {
    date: "2026-09-16", dayKey: "wednesday", planId: "form-flow",
    exercises: { cycle: entry },
    extraActivities: [{ id: "test-hiit", name: "Bike HIIT", type: "hiit", measurement: "distance", sets: [readings] }],
  };
  state.workoutLogs.saved = log;
  state.workoutDrafts.draft = log;
  state.savedActivities = [{ id: "saved-hiit", name: "Bike HIIT", type: "hiit", measurement: "duration" }];
  const result = validateBackup(JSON.parse(JSON.stringify(state)));
  assert.equal(result.valid, true);
  assert.deepEqual(result.state.workoutLogs.saved.exercises.cycle, entry);
  assert.deepEqual(result.state.workoutDrafts.draft.extraActivities[0].sets[0], readings);
  assert.deepEqual(result.state.savedActivities, state.savedActivities);
});

test("cardio totals include supplemental time, distance, and calories across measurement modes", () => {
  const logs = {
    day: { date: "2026-09-16", exercises: {
      cycle: { measurement: "duration", sets: [readings] },
      carry: { measurement: "weight_distance", sets: [{ distance: 40 }] },
    }, extraActivities: [
      { measurement: "distance", sets: [{ distance: 3, minutes: 10, seconds: 15, calories: 95 }] },
      { measurement: "duration", sets: [{ minutes: 5 }] },
    ] },
    outside: { date: "2026-09-22", exercises: { cycle: { measurement: "duration", sets: [readings] } } },
  };
  const totals = summarizeCardioRange(logs, "2026-09-14", "2026-09-21", ["cycle"]);
  assert.equal(totals.seconds, 2385);
  assert.equal(totals.distance, 11.25);
  assert.equal(totals.calories, 380);
  assert.equal(totals.sessions, 3);
  assert.equal(totals.averageRpe, 7);
});

test("previous-set targets exclude optional machine results and heart-rate averages", () => {
  const before = structuredClone(readings);
  assert.deepEqual(preparePreviousSets([readings], 2, "duration"), [
    { completed: false, minutes: 24, seconds: 30 },
    { completed: false, minutes: 24, seconds: 30 },
  ]);
  assert.deepEqual(readings, before);
});

test("the previous-session readout distinguishes missing readings from recorded zeros", () => {
  assert.equal(summarizeCardioSet(readings), "24:30 · 8.25 km · 285 kcal · 82.5 rpm avg · 151 bpm avg · RPE 7");
  assert.equal(summarizeCardioSet({ minutes: "", calories: 0, averageRpm: "", averageHeartRate: 120 }), "0 kcal · 120 bpm avg");
  assert.equal(summarizeCardioSet({}), "No metrics recorded");
});
