import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";

const read = (file) => readFile(new URL(`../${file}`, import.meta.url), "utf8");
const [html, css, source] = await Promise.all(["index.html", "styles.css", "app.js"].map(read));

test("draft status lives by the workout heading and final save follows the review disclosure", () => {
  const hero = html.slice(html.indexOf('<article class="session-hero"'), html.indexOf('</article>'));
  assert.match(hero, /id="draft-status"[^>]*role="status"/);
  assert.match(hero, /id="save-status"/);
  const review = html.slice(html.indexOf('id="review-step"'), html.indexOf('id="next-session-entry"'));
  assert.match(review, /<\/details>\s*<div class="workout-save">[\s\S]*id="save-workout"/);
  assert.equal((html.match(/id="save-workout"/g) || []).length, 1);
  assert.doesNotMatch(html + css, /save-bar/);
  assert.match(html, /href="#review-step"/);
  assert.match(source, /if \(target.tagName === "DETAILS"\) target.open = true;/);
  assert.doesNotMatch(css.match(/\.workout-save \{[^}]*\}/)[0], /position:/);
  assert.doesNotMatch(css, /bottom: (?:104px|calc\(142px)/);
  assert.match(css, /body\[data-active-view="today"\] \.timer \{[^}]*bottom: calc\(74px \+ var\(--safe-bottom\)\)/);
});

function setup() {
  const state = { workoutLogs: {}, workoutDrafts: {} };
  const alert = { hidden: true, textContent: "" };
  const status = { textContent: "" };
  const draftStatus = { dataset: {} };
  const button = { disabled: false };
  let allowStorage = true;
  let stored;
  let pending;
  let reps = 5;
  const context = vm.createContext({
    state, els: { workoutStorageAlert: alert, saveStatus: status, draftStatus },
    $: () => button, $$: () => [],
    workoutLogKey: (date) => date,
    selectedDate: "2026-11-25", draftSaveTimer: null, draftSession: null, finalSavePending: false,
    workoutDirty: true, draftRevision: 1, storageMode: "local", saveQueue: Promise.resolve(),
    clearTimeout() {}, collectWorkoutRecord: () => ({ exercises: { row: { sets: [{ reps }] } } }),
    persistState: () => {
      const snapshot = structuredClone(state);
      const result = pending || Promise.resolve(allowStorage);
      pending = null;
      context.saveQueue = result.then((ok) => {
        if (ok) stored = snapshot;
        return ok;
      });
      return context.saveQueue;
    },
    savedThisVisit: new Set(), showToast() {}, renderToday() {}, openCoaching() {},
  });
  for (const [start, end] of [["function setSaveStatus(", "function showToast("], ["async function saveWorkoutDraftNow(", "function selectedResponseRating("]]) {
    vm.runInContext(source.slice(source.indexOf(start), source.indexOf(end)), context);
  }
  return {
    state, alert, status, draftStatus, button, get stored() { return stored; },
    fail: () => { allowStorage = false; },
    edit: (value) => { reps = value; context.draftRevision += 1; context.workoutDirty = true; },
    delay: () => {
      let finish;
      pending = new Promise((resolve) => { finish = resolve; });
      return finish;
    },
    recover: () => { allowStorage = true; },
    run: (code) => vm.runInContext(code, context),
  };
}

test("automatic draft stays separate from explicit final save; status and alert reflect persistence", async () => {
  const ui = setup();
  await ui.run("saveWorkoutDraftNow()");
  assert.equal(ui.status.textContent, "Draft saved on this device");
  assert.ok(ui.stored.workoutDrafts["2026-11-25"]);
  assert.equal(ui.stored.workoutLogs["2026-11-25"], undefined);
  await ui.run("saveWorkout()");
  assert.ok(ui.stored.workoutLogs["2026-11-25"].savedAt);
  assert.equal(ui.stored.workoutDrafts["2026-11-25"], undefined);
  assert.equal(ui.alert.hidden, true);
});

test("failed draft warns persistently; failed final leaves draft intact and can be retried", async () => {
  const ui = setup();
  ui.fail();
  await ui.run("saveWorkoutDraftNow()");
  assert.match(ui.status.textContent, /Draft not saved/);
  assert.equal(ui.alert.hidden, false);
  assert.equal(ui.draftStatus.dataset.status, "error");
  ui.recover();
  await ui.run("saveWorkoutDraftNow()");
  assert.equal(ui.alert.hidden, true);
  const draft = ui.state.workoutDrafts["2026-11-25"];
  ui.fail();
  await ui.run("saveWorkout()");
  assert.equal(ui.state.workoutLogs["2026-11-25"], undefined);
  assert.equal(ui.state.workoutDrafts["2026-11-25"], draft);
  assert.match(ui.alert.textContent, /Workout not saved/);
  assert.equal(ui.alert.hidden, false);
  assert.equal(ui.button.disabled, false);
  ui.recover();
  await ui.run("saveWorkout()");
  assert.ok(ui.stored.workoutLogs["2026-11-25"].savedAt);
  assert.equal(ui.button.disabled, false);
});


test("a concurrent edit during a failed explicit write can only persist as a draft", async () => {
  const ui = setup();
  const finish = ui.delay();
  const finalSave = ui.run("saveWorkout()");
  assert.equal(ui.button.disabled, true);
  ui.edit(9);
  const autoSave = ui.run("saveWorkoutDraftNow()");
  finish(false);
  await Promise.all([finalSave, autoSave]);
  assert.equal(ui.stored.workoutLogs["2026-11-25"], undefined);
  assert.equal(ui.stored.workoutDrafts["2026-11-25"].exercises.row.sets[0].reps, 9);
  assert.equal(ui.button.disabled, false);
  await ui.run("saveWorkout()");
  assert.equal(ui.stored.workoutLogs["2026-11-25"].exercises.row.sets[0].reps, 9);
});
