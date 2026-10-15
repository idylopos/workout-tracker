import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { findExerciseHistory, findPreviousExerciseLog, preparePreviousSets, MEASUREMENT_TYPES, EXTRA_ACTIVITY_MEASUREMENTS, measurementFields, summarizeCardioSet } from "../lib.js";

const entry = (date, weight, extra = {}) => ({ date, exercises: { squat: { measurement: "weight_reps", sets: [{ weight, reps: 8, rir: 2, completed: true }] } }, ...extra });
const logs = { oldest: entry("2026-06-01", 70), older: entry("2026-07-01", 80), deload: entry("2026-07-08", 40) };

test("history preserves latest deload and lists every older entry newest first", () => {
  const history = findExerciseHistory(logs, "squat", "2026-07-15");
  assert.deepEqual(history.map((item) => item.sets[0].weight), [40, 80, 70]);
  assert.deepEqual(findPreviousExerciseLog(logs, "squat", "2026-07-15"), history[0]);
  assert.deepEqual(findExerciseHistory(logs, "squat", "2026-06-01"), []);
  assert.equal(findPreviousExerciseLog({}, "squat", "2026-07-15"), null);
});

test("history scopes plan, date and variant, and drafts replace duplicate saved dates", () => {
  const mixed = { ...logs, future: entry("2026-07-16", 99), today: entry("2026-07-15", 98), otherPlan: entry("2026-07-14", 97, { planId: "other" }), alternative: { date: "2026-07-13", exercises: { squat: { variantId: "front-squat", measurement: "weight_reps", sets: [{ weight: 60 }] } } } };
  const drafts = { duplicate: entry("2026-07-08", 42) };
  const history = findExerciseHistory(mixed, "squat", "2026-07-15", "form-flow", drafts, "squat");
  assert.deepEqual(history.map((item) => item.sets[0].weight), [42, 80, 70]);
  assert.equal(findExerciseHistory(mixed, "squat", "2026-07-15", "form-flow", drafts, "front-squat")[0].sets[0].weight, 60);
  assert.equal(logs.deload.exercises.squat.sets[0].weight, 40);
});

// Exercise the real app functions, with only DOM and persistence boundaries stubbed.
// This is interaction coverage, not a substitute for browser/layout QA.
const source = readFileSync(new URL("../app.js", import.meta.url), "utf8");
const functions = source.slice(source.indexOf("function exerciseHistory("), source.indexOf("function createExerciseCard("));
const summary = source.slice(source.indexOf("function summarizeSetPreview("), source.indexOf("function collectSetRows("));
class Element {
  constructor() { this.dataset = {}; this.children = []; this.attributes = {}; this.events = {}; this.hiddenClasses = new Set(["is-hidden"]); this.classList = { add: (name) => this.hiddenClasses.add(name), contains: (name) => this.hiddenClasses.has(name), toggle: (name, force) => { const value = force ?? !this.hiddenClasses.has(name); if (value) this.hiddenClasses.add(name); else this.hiddenClasses.delete(name); }, remove: (name) => this.hiddenClasses.delete(name) }; }
  replaceChildren(...children) { this.children = children; }
  append(...children) { this.children.push(...children); }
  setAttribute(key, value) { this.attributes[key] = value; }
  addEventListener(key, value) { this.events[key] = value; }
  focus() { this.focused = true; }
  get firstElementChild() { return this.children[0]; }
}
function harness(workoutLogs = logs) {
  const card = new Element();
  card.dataset.defaultSets = "3";
  card.dataset.variantId = "squat";
  card.sets = [{ completed: false, weight: "", reps: "", rir: "" }, { completed: false }, { completed: false }];
  card.nodes = Object.fromEntries([".exercise-history-picker", ".load-previous", ".previous-line", ".measurement-select", ".set-list", ".exercise-history-choices", ".exercise-history-empty", ".exercise-history-cancel", ".progression-performance-qualified", ".progression-recovery-qualified"].map((key) => [key, new Element()]));
  card.nodes[".measurement-select"].value = "weight_reps";
  card.nodes[".set-list"].children = [1, 2, 3];
  const stats = { dirty: 0, persists: 0, confirms: 0, allow: true };
  const context = vm.createContext({
    findExerciseHistory, preparePreviousSets, MEASUREMENT_TYPES, EXTRA_ACTIVITY_MEASUREMENTS, measurementFields, summarizeCardioSet,
    state: { workoutLogs, workoutDrafts: {}, exerciseConfigs: {} }, selectedDate: "2026-07-15", activePlan: { id: "form-flow" },
    $: (selector, target) => target.nodes[selector],
    document: { createElement: () => new Element() },
    window: { confirm: () => { stats.confirms++; return stats.allow; } },
    formatDate: (date) => date, exerciseConfigKey: (id) => id,
    collectSetRows: (target) => target.sets,
    hasSetContent: (set) => set.completed || Object.entries(set).some(([key, value]) => key !== "completed" && value !== ""),
    persistState: () => stats.persists++, markWorkoutDirty: () => stats.dirty++, showToast: () => {}, updateSessionProgress: () => {},
    renderSetRows: (target, measurement, sets) => { target.sets = sets; target.nodes[".set-list"].children = sets; },
    clearImportedCompletion: (target) => { target.nodes[".progression-performance-qualified"].checked = false; target.nodes[".progression-recovery-qualified"].checked = false; },
  });
  vm.runInContext(functions + summary, context);
  return { card, stats, context, exercise: { id: "squat", name: "Squat" } };
}

test("Use last loads deload, changes to Load more, and older selection keeps today's set count", () => {
  const { card, stats, context: c, exercise } = harness();
  c.updatePreviousExerciseState(card, exercise);
  assert.equal(card.nodes[".load-previous"].textContent, "Use last");
  c.loadExerciseHistoryEntry(card, exercise, c.exerciseHistory(card, exercise)[0]);
  assert.equal(card.nodes[".load-previous"].textContent, "Load more");
  assert.equal(card.sets.length, 3);
  assert.ok(card.sets.every((set) => set.weight === 40 && !set.completed && set.rir === undefined));
  c.openExerciseHistory(card, exercise);
  const choices = card.nodes[".exercise-history-choices"].children;
  assert.deepEqual(choices.map((choice) => choice.children[0].textContent), ["2026-07-01", "2026-06-01"]);
  assert.equal(choices[0].children[1].textContent, "Last set: 80 kg × 8");
  choices[1].events.click();
  assert.ok(card.sets.every((set) => set.weight === 70));
  assert.equal(stats.confirms, 0);
  c.openExerciseHistory(card, exercise);
  assert.equal(card.nodes[".exercise-history-choices"].children.length, 2);
});

test("opening and cancelling preserve inputs, completion, config and dirty state", () => {
  const { card, stats, context: c, exercise } = harness();
  c.loadExerciseHistoryEntry(card, exercise, c.exerciseHistory(card, exercise)[0]);
  card.sets[0].weight = 45;
  card.sets[0].completed = true;
  const before = JSON.stringify(card.sets);
  c.openExerciseHistory(card, exercise);
  c.closeExerciseHistory(card, { focus: true });
  assert.equal(JSON.stringify(card.sets), before);
  assert.equal(stats.dirty, 1);
  assert.equal(stats.persists, 1);
  assert.equal(card.nodes[".load-previous"].attributes["aria-expanded"], "false");
  assert.equal(card.nodes[".load-previous"].focused, true);
});

test("edited imports and pre-existing entries require confirmation; declining is non-mutating", () => {
  const { card, stats, context: c, exercise } = harness();
  card.sets[0].weight = 25;
  stats.allow = false;
  assert.equal(c.loadExerciseHistoryEntry(card, exercise, c.exerciseHistory(card, exercise)[0]), false);
  assert.equal(card.sets[0].weight, 25);
  assert.equal(stats.dirty, 0);
  assert.equal(card.dataset.previousImportSnapshot, undefined);
  stats.allow = true;
  c.loadExerciseHistoryEntry(card, exercise, c.exerciseHistory(card, exercise)[0]);
  card.sets[0].reps = 10;
  stats.allow = false;
  c.openExerciseHistory(card, exercise);
  card.nodes[".exercise-history-choices"].children[0].events.click();
  assert.equal(card.sets[0].reps, 10);
  assert.equal(card.nodes[".exercise-history-picker"].classList.contains("is-hidden"), false);
  assert.equal(stats.confirms, 3);
});

test("no history disables import; no older history displays a cancellable empty state", () => {
  const empty = harness({});
  empty.context.updatePreviousExerciseState(empty.card, empty.exercise);
  assert.equal(empty.card.nodes[".load-previous"].disabled, true);
  const { card, context: c, exercise } = harness({ deload: logs.deload });
  c.loadExerciseHistoryEntry(card, exercise, c.exerciseHistory(card, exercise)[0]);
  c.openExerciseHistory(card, exercise);
  assert.equal(card.nodes[".exercise-history-choices"].children.length, 0);
  assert.equal(card.nodes[".exercise-history-empty"].classList.contains("is-hidden"), false);
  assert.equal(card.nodes[".exercise-history-cancel"].focused, true);
});

test("variant, measurement and new session reset import state rather than reusing stale history", () => {
  const { card, context: c, exercise } = harness();
  c.loadExerciseHistoryEntry(card, exercise, c.exerciseHistory(card, exercise)[0]);
  c.openExerciseHistory(card, exercise);
  card.dataset.variantId = "front-squat";
  c.updatePreviousExerciseState(card, exercise);
  assert.equal(card.dataset.previousImportSnapshot, undefined);
  assert.equal(card.dataset.previousImportDate, undefined);
  assert.equal(card.nodes[".load-previous"].textContent, "Use last");
  assert.equal(card.nodes[".load-previous"].disabled, true);
  assert.equal(card.nodes[".exercise-history-picker"].classList.contains("is-hidden"), true);
  const fresh = harness();
  fresh.context.updatePreviousExerciseState(fresh.card, fresh.exercise);
  assert.equal(fresh.card.nodes[".load-previous"].textContent, "Use last");
  // Verify lifecycle wiring: fresh cards initialize state, variant and measurement changes reset it.
  assert.match(source, /applyExerciseVariant\(card, exercise, variant, \{ resetSets: true \}\);\s+updatePreviousExerciseState\(card, exercise\)/);
  assert.match(source, /renderSetRows\(card, select.value, sets\);\s+updatePreviousExerciseState\(card, exercise\)/);
  assert.match(source, /event.key === "Escape"[\s\S]*?closeExerciseHistory\(card, \{ focus: true \}\)/);
});

test("picker previews zero assistance faithfully and does not advertise optional cardio readings", () => {
  const { context: c } = harness();
  assert.equal(c.summarizeSetPreview("assisted_reps", [{ assistance: 0, reps: 5 }]), "0 kg assist × 5");
  assert.equal(c.summarizeSetPreview("weight_reps", [{ weight: "", reps: 8 }]), "— kg × 8");
  const imported = preparePreviousSets([{ minutes: 20, calories: 200, averageHeartRate: 120, rpe: 4 }], 1, "duration");
  assert.equal(c.summarizeSetPreview("duration", imported), "20:00");
});

test("completion and qualification edits are protected and cleared only after approval", () => {
  const { card, stats, context: c, exercise } = harness();
  c.loadExerciseHistoryEntry(card, exercise, c.exerciseHistory(card, exercise)[0]);
  card.nodes[".progression-performance-qualified"].checked = true;
  card.nodes[".progression-recovery-qualified"].checked = true;
  card.sets[0].completed = true;
  card.sets[0].rir = 1;
  stats.allow = false;
  c.loadExerciseHistoryEntry(card, exercise, c.exerciseHistory(card, exercise)[1]);
  assert.equal(card.dataset.previousImportDate, "2026-07-08");
  assert.equal(card.sets[0].completed, true);
  assert.equal(card.nodes[".progression-performance-qualified"].checked, true);
  stats.allow = true;
  c.loadExerciseHistoryEntry(card, exercise, c.exerciseHistory(card, exercise)[1]);
  assert.equal(card.dataset.previousImportDate, "2026-07-01");
  assert.ok(card.sets.every((set) => !set.completed && set.rir === undefined));
  assert.equal(card.nodes[".progression-performance-qualified"].checked, false);
  assert.equal(card.nodes[".progression-recovery-qualified"].checked, false);
});

test("measurement reset closes history and re-evaluates history for a changed date or plan", () => {
  const { card, context: c, exercise } = harness();
  c.loadExerciseHistoryEntry(card, exercise, c.exerciseHistory(card, exercise)[0]);
  c.openExerciseHistory(card, exercise);
  card.nodes[".measurement-select"].value = "reps";
  c.updatePreviousExerciseState(card, exercise);
  assert.equal(card.nodes[".exercise-history-picker"].classList.contains("is-hidden"), true);
  assert.equal(card.nodes[".load-previous"].textContent, "Use last");
  assert.equal(card.nodes[".measurement-select"].value, "reps");
  c.selectedDate = "2026-06-01";
  c.updatePreviousExerciseState(card, exercise);
  assert.equal(card.nodes[".load-previous"].disabled, true);
  c.selectedDate = "2026-07-15";
  c.activePlan.id = "other";
  c.updatePreviousExerciseState(card, exercise);
  assert.equal(card.nodes[".load-previous"].disabled, true);
});
