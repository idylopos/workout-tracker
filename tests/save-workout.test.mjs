import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { workoutRecordKind } from "../lib.js";

const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
const saveWorkout = app.slice(app.indexOf("async function saveWorkout()"), app.indexOf("function selectedResponseRating("));
const renderTarget = app.slice(app.indexOf("function renderNextSessionTarget("), app.indexOf("function renderSetRows("));

test("the mobile save bar becomes sticky only for a draft with activity or a day note", () => {
  const classes = new Set();
  const saveBar = { classList: { toggle(name, enabled) { if (enabled) classes.add(name); else classes.delete(name); } } };
  const ctx = vm.createContext({ els: { saveBar, saveButton: {} }, workoutRecordKind });
  vm.runInContext(app.slice(app.indexOf("function updateSaveAction("), app.indexOf("function showToast(")), ctx);
  const note = { response: { notes: "Recovery day" } };
  ctx.updateSaveAction({}, true);
  assert.equal(classes.has("has-pending-work"), false);
  ctx.updateSaveAction(note, true);
  assert.equal(classes.has("has-pending-work"), true);
  assert.equal(ctx.els.saveButton.textContent, "Save day note");
  ctx.updateSaveAction(note, false);
  assert.equal(classes.has("has-pending-work"), false);
  ctx.updateSaveAction({ warmup: [true] }, true);
  assert.equal(classes.has("has-pending-work"), true);
  assert.equal(ctx.els.saveButton.textContent, "Save workout");
});

test("Save workout keeps a pristine day empty, saves notes separately, and accepts an unchecked result", async () => {
  const date = "2026-11-06";
  const record = { date, warmup: [false], exercises: {}, extraActivities: [], response: {} };
  const state = { workoutLogs: {}, workoutDrafts: {} };
  const ctx = vm.createContext({
    state, selectedDate: date, workoutLogKey: (day) => day, workoutRecordKind,
    $$: () => [], collectWorkoutRecord: () => structuredClone(record),
    persistState: async () => true, renderToday() {}, showToast() {},
    draftSaveTimer: null, draftRevision: 0, workoutDirty: false, clearTimeout, savedThisVisit: new Set(),
  });
  vm.runInContext(saveWorkout, ctx);
  await ctx.saveWorkout();
  assert.deepEqual(state.workoutLogs, {});
  record.response.notes = "Recovery day";
  await ctx.saveWorkout();
  assert.equal(workoutRecordKind(state.workoutLogs[date]), "note");
  record.exercises.squat = { measurement: "reps", sets: [{ reps: 3, completed: false }] };
  await ctx.saveWorkout();
  assert.equal(workoutRecordKind(state.workoutLogs[date]), "workout");
  const saved = state.workoutLogs[date];
  record.exercises = {};
  record.response = {};
  await ctx.saveWorkout();
  assert.equal(state.workoutLogs[date], saved);
});

test("accepted targets are suggestions on matching rows and never create an actual value on render", () => {
  const card = { dataset: { exerciseId: "press", measurement: "weight_reps" } };
  const note = {};
  const fields = ["weight", "reps", "rir"].map((field) => ({ dataset: { field }, value: "" }));
  const ctx = vm.createContext({
    state: { workoutLogs: {}, settings: { nextSessionTargets: {
      "form-flow:press": { sourceDate: "2026-10-30", measurement: "weight_reps", field: "weight", value: 24, reps: 8 },
    } } },
    selectedDate: "2026-11-06", activePlan: { id: "form-flow" }, workoutLogKey: (day) => day,
    $: () => note, $$: () => fields,
  });
  vm.runInContext(renderTarget, ctx);
  ctx.renderNextSessionTarget(card);
  assert.equal(note.hidden, false);
  assert.deepEqual(fields.map((field) => field.dataset.acceptedTarget), [24, 8, undefined]);
  assert.deepEqual(fields.map((field) => field.value), ["", "", ""]);
  card.dataset.variantId = "fly";
  ctx.renderNextSessionTarget(card);
  assert.equal(note.hidden, true);
  card.dataset.variantId = "press";
  card.dataset.measurement = "reps";
  ctx.renderNextSessionTarget(card);
  assert.equal(note.hidden, true);
  card.dataset.measurement = "weight_reps";
  fields.push({ dataset: { field: "weight" }, value: "" });
  ctx.renderNextSessionTarget(card);
  assert.equal(note.hidden, false);
  assert.equal(fields.at(-1).placeholder, 24);
  assert.equal(fields.at(-1).value, "");
});
