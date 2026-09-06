import test from "node:test";
import assert from "node:assert/strict";
import { progressionAdvice, nextSessionTarget, recordedReserve, isGuidedSessionQualified } from "../progression.js";
import { recoveryReadiness, eveningCheckInItems, getDailyCheckInItems, evaluateLongRunProgress, createDefaultState, validateBackup } from "../lib.js";

const today = "2026-09-06";
function lift(date = "2026-09-05", options = {}) {
  const exercise = {
    name: "Bench", measurement: "weight_reps",
    coachingPlan: { kind: "strength", sets: 3, minReps: 6, maxReps: 10, minRir: 2 },
    coaching: { technique: "yes" },
    sets: Array.from({ length: 3 }, () => ({ weight: 20, reps: 10, rir: 2, completed: true })), ...options,
  };
  return { date, planId: "form-flow", response: { readiness: "yes" }, exercises: { bench: exercise } };
}
function pullup(date, step = 2) {
  const log = lift(date);
  const exercise = log.exercises.bench;
  exercise.measurement = "assisted_reps";
  exercise.progressionStep = step;
  exercise.coachingPlan = { kind: "pullup", sets: 3, minReps: 6, maxReps: 8, minRir: 1 };
  exercise.sets = Array.from({ length: 3 }, () => ({ assistance: 23, reps: 8, rir: 1, completed: true }));
  log.exercises = { pullup: exercise };
  return log;
}

test("strength increases only after two matching, recovered sessions", () => {
  const current = lift();
  assert.equal(progressionAdvice(current, "bench", {}, today).action, "repeat");
  const history = { previous: lift("2026-09-01"), current };
  assert.equal(progressionAdvice(current, "bench", history, today).action, "increase");
  history.previous.exercises.bench.sets[0].weight = 15;
  assert.equal(progressionAdvice(current, "bench", history, today).action, "repeat");
  history.previous = lift("2026-09-01");
  history.previous.planId = "another-plan";
  assert.equal(progressionAdvice(current, "bench", history, today).action, "repeat");
});

test("missing, uncertain, or same-day recovery never increases difficulty", () => {
  for (const response of [{}, { readiness: "unknown" }]) {
    const log = { ...lift(), response };
    assert.equal(progressionAdvice(log, "bench", { prior: lift("2026-09-01") }, today).action, "pending");
  }
  assert.equal(progressionAdvice(lift(today), "bench", { prior: lift("2026-09-01") }, today).action, "pending");
  assert.equal(recoveryReadiness({ scaleVersion: 2, painNext: 0, readiness: "unknown" }), "unknown");
  assert.equal(recoveryReadiness({ scaleVersion: 2, painNext: 3, readiness: "yes" }), "no");
});

test("incomplete sets and a recent unsuccessful exposure break qualification", () => {
  const log = lift();
  log.exercises.bench.sets[2].completed = false;
  assert.equal(progressionAdvice(log, "bench", { prior: lift("2026-09-01") }, today).action, "repeat");
  const prior = lift("2026-09-04");
  prior.exercises.bench.coaching.technique = "no";
  assert.equal(progressionAdvice(lift(), "bench", { older: lift("2026-09-01"), prior }, today).action, "repeat");
});

test("hardest logged effort cannot be overridden by an optimistic answer", () => {
  const log = lift();
  log.exercises.bench.sets[0].rir = 0;
  log.exercises.bench.sets[1].rir = "";
  log.exercises.bench.coaching.reserve = 4;
  assert.equal(recordedReserve(log.exercises.bench), null);
  assert.equal(progressionAdvice(log, "bench", {}, today).action, "reduce");
  log.exercises.bench.sets[0].rir = "";
  log.exercises.bench.coaching.reserve = "unknown";
  assert.equal(progressionAdvice(log, "bench", {}, today).action, "pending");
});

test("limiting symptoms pause the exercise rather than suggesting heavier or lighter work", () => {
  const log = lift();
  log.response = { readiness: "yes", painDuring: 3, scaleVersion: 2 };
  assert.equal(progressionAdvice(log, "bench", {}, today).action, "pending");
  assert.equal(isGuidedSessionQualified(log, "bench", today), false);
});

test("pull-ups at 3 × 6 do not satisfy the 3 × 8 target", () => {
  const log = pullup("2026-09-05");
  log.exercises.pullup.sets.forEach((set) => { set.reps = 6; });
  assert.equal(progressionAdvice(log, "pullup", { previous: pullup("2026-09-02") }, today).action, "repeat");
  assert.equal(isGuidedSessionQualified(log, "pullup", today), false);
});

test("pull-up assistance reduction requires two targets and an explicit smaller assistance", () => {
  const log = pullup("2026-09-05");
  const advice = progressionAdvice(log, "pullup", { previous: pullup("2026-09-02") }, today);
  assert.equal(advice.nextStep, 3);
  assert.equal(nextSessionTarget(log, "pullup", advice, ""), null);
  assert.equal(nextSessionTarget(log, "pullup", advice, "30"), null);
  assert.equal(nextSessionTarget(log, "pullup", advice, "20").value, 20);
});

test("singles require three unassisted reps plus two assisted back-off sets", () => {
  const log = pullup("2026-09-05", 4);
  log.exercises.pullup.coachingPlan = { kind: "pullup", sets: 5, minReps: 1, maxReps: 1, minRir: 1 };
  log.exercises.pullup.sets = [...Array.from({ length: 3 }, () => ({ completed: true, assistance: 0, reps: 1, rir: 1 })),
    ...Array.from({ length: 2 }, () => ({ completed: true, assistance: 15, reps: 5, rir: 1 }))];
  assert.equal(isGuidedSessionQualified(log, "pullup", today), true);
  log.exercises.pullup.sets[2].assistance = 5;
  assert.equal(isGuidedSessionQualified(log, "pullup", today), false);
});

test("assisted doubles never qualify as unassisted doubles", () => {
  const log = pullup("2026-09-05", 5);
  log.exercises.pullup.coachingPlan = { kind: "pullup", sets: 4, minReps: 2, maxReps: 2, minRir: 1 };
  log.exercises.pullup.sets = Array.from({ length: 4 }, () => ({ completed: true, assistance: 5, reps: 2, rir: 1 }));
  assert.equal(isGuidedSessionQualified(log, "pullup", today), false);
  log.exercises.pullup.sets.forEach((set) => { set.assistance = 0; });
  assert.equal(isGuidedSessionQualified(log, "pullup", today), true);
});

test("a conversational run can qualify without fabricating an RPE", () => {
  const exercise = { measurement: "distance_time", sets: [{ completed: true, distance: 4.5, rpe: "" }],
    coaching: { conversational: "yes" }, coachingPlan: { kind: "run", stage: 1, distance: 4.5, totalStages: 18 } };
  const log = { date: "2026-09-05", response: { readiness: "yes" }, exercises: { "long-run": exercise } };
  assert.equal(progressionAdvice(log, "long-run", {}, today).nextStage, 2);
  assert.equal(evaluateLongRunProgress(log, "4.5 km").status, "ready");
  assert.equal(exercise.sets[0].rpe, "");
  exercise.sets[0].rpe = 5;
  assert.equal(progressionAdvice(log, "long-run", {}, today).action, "repeat");
  assert.equal(evaluateLongRunProgress(log, "4.5 km").status, "repeat");
});

test("accepting a load checks direction and leaves the original log intact", () => {
  const log = lift();
  const before = structuredClone(log);
  const advice = { action: "increase", title: "Add load", detail: "Restart at 6 reps" };
  assert.equal(nextSessionTarget(log, "bench", advice, "20"), null);
  assert.equal(nextSessionTarget(log, "bench", advice, "-1"), null);
  assert.equal(nextSessionTarget(log, "bench", advice, "22.5").reps, 6);
  assert.deepEqual(log, before);
});

test("evening questions are optional, same-day, and only after returning", () => {
  const logs = { one: lift(today) };
  assert.equal(eveningCheckInItems(logs, today, 17).length, 0);
  assert.equal(eveningCheckInItems(logs, today, 19, {}, ["one"]).length, 0);
  assert.equal(eveningCheckInItems(logs, today, 19).length, 1);
  assert.equal(eveningCheckInItems(logs, today, 19, { laterUnknown: ["one"] }).length, 0);
  logs.one.savedAt = "2026-09-06T10:30:00Z";
  assert.equal(eveningCheckInItems(logs, today, 19, {}, [], Date.parse("2026-09-06T11:00:00Z")).length, 0);
  assert.equal(eveningCheckInItems(logs, today, 19, {}, [], Date.parse("2026-09-06T12:00:00Z")).length, 1);
  delete logs.one.savedAt;
  logs.one.response.painLater = 0;
  assert.equal(eveningCheckInItems(logs, today, 19).length, 0);
});

test("recovery answers stop repeat prompts while unknown remains explicit", () => {
  const log = lift();
  assert.equal(getDailyCheckInItems({ log }, [{ date: today, hours: 7 }], {}, today).length, 0);
  log.response.readiness = "unknown";
  assert.equal(getDailyCheckInItems({ log }, [{ date: today, hours: 7 }], {}, today).length, 1);
  assert.equal(getDailyCheckInItems({ log }, [{ date: today, hours: 7 }], { [today]: { recoveryUnknown: ["log"] } }, today).length, 0);
});

test("new answers and accepted targets survive backup normalization", () => {
  const state = createDefaultState();
  state.workoutLogs = { [today]: lift(today) };
  state.settings.nextSessionTargets = { "form-flow:bench": { field: "weight", value: 22.5, sourceDate: today } };
  const result = validateBackup(JSON.parse(JSON.stringify(state)));
  assert.equal(result.valid, true);
  assert.equal(result.state.workoutLogs[today].exercises.bench.coaching.technique, "yes");
  assert.equal(result.state.settings.nextSessionTargets["form-flow:bench"].value, 22.5);
});

test("step 3 cannot jump to singles without explicit readiness", () => {
  const current = pullup("2026-09-05", 3);
  const prior = pullup("2026-09-02", 3);
  assert.equal(progressionAdvice(current, "pullup", { prior }, today).action, "repeat");
  current.exercises.pullup.coaching.readySingle = "yes";
  assert.equal(progressionAdvice(current, "pullup", { prior }, today).nextStep, 4);
});

test("legacy unassisted reps can accept an assisted reduction without rewriting old measurements", () => {
  const log = pullup("2026-09-05", 5);
  log.exercises.pullup.measurement = "reps";
  log.exercises.pullup.sets.forEach((set) => { delete set.assistance; });
  const target = nextSessionTarget(log, "pullup", { action: "reduce", title: "Use more assistance", detail: "Keep reserve" }, "10");
  assert.equal(target.measurement, "assisted_reps");
  assert.equal(target.value, 10);
  assert.equal(log.exercises.pullup.measurement, "reps");
});
