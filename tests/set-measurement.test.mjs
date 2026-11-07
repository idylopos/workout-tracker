import test from "node:test";
import assert from "node:assert/strict";
import {
  changeSetMeasurement, createDefaultState, EXTRA_ACTIVITY_MEASUREMENTS, normalizeState, workoutRecordKind,
} from "../lib.js";

test("changing strength measurements keeps shared values, extra rows and each completion flag", () => {
  const original = [
    { completed: true, weight: 24, reps: 8, rir: 0 },
    { completed: false, weight: "", reps: 6, rir: "" },
    { completed: false, weight: "", reps: "", rir: "" },
    { completed: true, weight: 20, reps: 10, rir: 2 },
  ];
  const snapshot = structuredClone(original);
  const narrowed = changeSetMeasurement(original, "weight_reps", "reps");
  assert.deepEqual(narrowed.removedFields, []);
  assert.ok(narrowed.sets.every((set) => !Object.hasOwn(set, "weight")));
  assert.deepEqual(original, snapshot);
  assert.deepEqual(changeSetMeasurement(narrowed.sets, "reps", "weight_reps"), {
    removedFields: [],
    sets: [
      { completed: true, weight: 24, reps: 8, rir: 0 },
      { completed: false, reps: 6 },
      { completed: false },
      { completed: true, weight: 20, reps: 10, rir: 2 },
    ],
  });
});

test("a draft or saved workout reloaded in Reps only restores each weight and keeps later edits", () => {
  const date = "2026-11-06";
  for (const records of ["workoutDrafts", "workoutLogs"]) {
    const state = createDefaultState();
    const { sets } = changeSetMeasurement([
      { completed: true, weight: 24.5, reps: 8, rir: 2 },
      { completed: false, weight: 0, reps: 5 },
      { completed: false, weight: "", reps: 4 },
    ], "weight_reps", "reps");
    Object.assign(sets[0], { completed: false, reps: 9, rir: 1 });
    state[records][date] = { date, exercises: { press: { measurement: "reps", sets } } };

    const reloaded = normalizeState(JSON.parse(JSON.stringify(state)))[records][date].exercises.press;
    const restored = changeSetMeasurement(reloaded.sets, reloaded.measurement, "weight_reps").sets;
    assert.deepEqual(restored, [
      { completed: false, weight: 24.5, reps: 9, rir: 1 },
      { completed: false, weight: 0, reps: 5 },
      { completed: false, reps: 4 },
    ], records);
  }
});

test("editing or clearing a restored weight replaces its previous value on the next round trip", () => {
  const original = [{ completed: true, weight: 24, reps: 8 }];
  const roundTrip = (sets) => {
    const hidden = changeSetMeasurement(sets, "weight_reps", "reps").sets;
    return changeSetMeasurement(hidden, "reps", "weight_reps").sets;
  };
  const restored = roundTrip(original);
  restored[0].weight = 30;
  const edited = roundTrip(restored);
  assert.equal(edited[0].weight, 30);
  edited[0].weight = "";
  assert.deepEqual(roundTrip(edited), [{ completed: true, reps: 8 }]);
});

test("an inactive weight alone can be restored without counting a workout", () => {
  const { sets } = changeSetMeasurement([{ completed: false, weight: 24 }], "weight_reps", "reps");
  assert.equal(workoutRecordKind({ exercises: { press: { measurement: "reps", sets } } }), "empty");
  assert.deepEqual(changeSetMeasurement(sets, "reps", "weight_reps").sets, [{ completed: false, weight: 24 }]);
});

test("confirmation names only populated fields that will be lost, including recorded zeros", () => {
  assert.deepEqual(changeSetMeasurement([
    { completed: false, assistance: 0, reps: "", rir: null },
    { completed: true, assistance: undefined, reps: "", rir: 0 },
  ], "assisted_reps", "completion"), {
    removedFields: ["Assistance", "RIR"],
    sets: [{ completed: false }, { completed: true }],
  });
});

test("changing cardio measures preserves primary and supplemental readings without prompting", () => {
  const original = [{ completed: true, minutes: 24, seconds: 30, distance: 8.25, calories: 0,
    averageRpm: 83, averageHeartRate: 125, rpe: 6 }];
  for (const measurement of EXTRA_ACTIVITY_MEASUREMENTS) {
    assert.deepEqual(changeSetMeasurement(original, "distance_time", measurement), {
      removedFields: [], sets: original,
    });
  }
});

test("carry and cardio distances keep their physical distance across a unit change", () => {
  const carry = [{ completed: true, distance: 40 }, { completed: false, distance: 1001 }];
  const cardio = changeSetMeasurement(carry, "weight_distance", "distance");
  assert.deepEqual(cardio, {
    sets: [{ completed: true, distance: 0.04 }, { completed: false, distance: 1.001 }],
    removedFields: [],
  });
  assert.deepEqual(changeSetMeasurement(cardio.sets, "distance", "weight_distance"), {
    sets: carry, removedFields: [],
  });
});
