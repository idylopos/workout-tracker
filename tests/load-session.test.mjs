import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { dateToDayKey, findPreviousSession, matchingSessionExercises, MEASUREMENT_TYPES } from "../lib.js";

const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
const load = app.slice(app.indexOf("function loadLastSession("), app.indexOf("function renderWeek("));
const fill = app.slice(app.indexOf("function repeatableFields("), app.indexOf("function updateCopyFirstSetButton("));

function row(values = {}, checked = false) {
  const inputs = Object.fromEntries(Object.entries(values).map(([key, value]) => [
    key, { value, validity: { badInput: false } },
  ]));
  return {
    inputs, checked, classList: { contains: () => false },
    querySelector(selector) {
      if (selector === ".set-done input") return { checked: this.checked };
      return inputs[selector.match(/data-field="(\w+)"/)[1]];
    },
  };
}

function loadSession(cards, exercises) {
  const previous = {
    date: "2026-10-30", dayKey: "friday", exercises,
    response: { notes: "Previous note", painDuring: 2 }, warmup: [true],
    extraActivities: [{ name: "Previous run" }],
  };
  let dirty = 0;
  const context = vm.createContext({
    MEASUREMENT_TYPES, matchingSessionExercises, dateToDayKey, findPreviousSession,
    selectedDate: "2026-11-06", activePlan: { id: "form-flow" }, state: { workoutLogs: { previous } },
    els: { exerciseList: cards },
    $: (selector, node) => node.querySelector(selector),
    $$: (selector, node) => selector === ".set-row" ? node.rows : node,
    markWorkoutDirty: () => { dirty++; }, formatDate: String, showToast() {},
  });
  vm.runInContext(fill + load + "\nloadLastSession();", context);
  return dirty;
}

test("Load last session fills matching blank targets only, preserving today's actuals and set count", () => {
  const rows = [
    row({ weight: "30", reps: "", rir: "3" }),
    row({ weight: "", reps: "", rir: "" }, true),
    row({ weight: "", reps: "0", rir: "" }),
    row({ weight: "", reps: "", rir: "" }),
  ];
  const card = { dataset: { exerciseId: "press", measurement: "weight_reps" }, rows };
  const history = { press: { measurement: "weight_reps", sets: [
    { weight: 24, reps: 8, rir: 2, completed: true },
    { weight: 22, reps: 10, rir: 1, completed: true },
    { weight: 0, reps: 12, rir: 4, completed: true },
  ] } };
  assert.equal(loadSession([card], history), 1);
  assert.deepEqual(rows.map(r => [r.checked, r.inputs.weight.value, r.inputs.reps.value, r.inputs.rir.value]), [
    [false, "30", 8, "3"], [true, "", "", ""], [false, 0, "0", ""], [false, "", "", ""],
  ]);
  assert.equal(loadSession([card], history), 0);
});

test("session prefill respects variation, measurement, progression stage and optional cardio fields", () => {
  const cards = [
    { dataset: { exerciseId: "hinge", variantId: "curl", measurement: "weight_reps" }, rows: [row({ weight: "" })] },
    { dataset: { exerciseId: "carry", measurement: "distance" }, rows: [row({ distance: "" })] },
    { dataset: { exerciseId: "pullup", measurement: "assisted_reps", progressionStep: "3" }, rows: [row({ assistance: "" })] },
    { dataset: { exerciseId: "longrun", measurement: "distance", longRunStage: "7" }, rows: [row({ distance: "" })] },
    { dataset: { exerciseId: "ride", measurement: "duration" }, rows: [row({ minutes: "", rpe: "", calories: "" })] },
  ];
  const history = {
    hinge: { measurement: "weight_reps", sets: [{ weight: 90 }] },
    carry: { measurement: "weight_distance", sets: [{ distance: 40 }] },
    pullup: { measurement: "assisted_reps", progressionStep: 2, sets: [{ assistance: 15 }] },
    longrun: { measurement: "distance", progressionStage: 6, sets: [{ distance: 9 }] },
    ride: { measurement: "duration", sets: [{ minutes: 30, rpe: 8, calories: 250 }] },
  };
  assert.equal(loadSession(cards, history), 1);
  assert.deepEqual(cards.map(card => Object.values(card.rows[0].inputs).map(input => input.value)), [
    [""], [""], [""], [""], [30, "", ""],
  ]);
});
