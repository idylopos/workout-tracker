import test from "node:test";
import assert from "node:assert/strict";
import { createDefaultState, WEEK_PLAN, MEASUREMENT_TYPES } from "../lib.js";
import { buildReviewPayload, reviewPeriod, fingerprintReviewPayload, validateReviewPayload } from "../weekly-review.js";

const now = new Date("2026-11-04T04:00:00Z");
const plan = { id: "form-flow", name: "Current selected plan", days: {
  monday: { exercises: [{ id: "press", name: "Press", measurement: "weight_reps", prescription: "3 × 6–8", sets: 3, category: "Strength" }] },
  tuesday: { exercises: [{ id: "run", name: "Run", measurement: "distance_time", sets: 1, category: "Cardio" }] },
} };
const set = (values = {}) => ({ completed: true, weight: 20, reps: 8, ...values });
const exercise = (values = {}) => ({ name: "Press", measurement: "weight_reps", sets: [set()], ...values });
const log = (date, values = {}) => ({ date, planId: "form-flow", exercises: { press: exercise() }, ...values });
const payload = (state, options = {}) => buildReviewPayload(state, plan, { now, ...options });

// UTC instants intentionally straddle Singapore's Monday boundary.
test("review weeks use Singapore Monday–Sunday including year boundaries", () => {
  assert.deepEqual(reviewPeriod("completed", new Date("2026-11-01T15:59:59Z")), {
    start: "2026-10-19", end: "2026-10-25", comparisonStart: "2026-09-21", partial: false, timezone: "Asia/Singapore",
  });
  assert.equal(reviewPeriod("completed", new Date("2026-11-01T16:00:00Z")).start, "2026-10-26");
  assert.equal(reviewPeriod("completed", new Date("2027-01-04T01:00:00Z")).start, "2026-12-28");
  assert.equal(reviewPeriod("completed", new Date("2027-01-04T01:00:00Z")).end, "2027-01-03");
  assert.deepEqual(reviewPeriod("current", new Date("2026-11-01T16:00:00Z")), {
    start: "2026-11-02", end: "2026-11-02", comparisonStart: "2026-10-05", partial: true, timezone: "Asia/Singapore",
  });
  assert.throws(() => reviewPeriod("arbitrary", now));
});

test("partial and empty weeks state insufficient data without filling missing records with zero", () => {
  const result = payload(createDefaultState(), { mode: "current" });
  assert.equal(result.period.partial, true);
  assert.equal(result.metrics.current.calendarDays, 3);
  assert.equal(result.metrics.current.recordedWorkouts, 0);
  assert.equal(result.metrics.current.sleep.average, null);
  assert.equal(result.metrics.current.cardio.recordedSeconds, null);
  assert.equal(result.metrics.current.body.weight.average, null);
  assert.equal(result.metrics.current.body.waist.change, null);
  assert.equal(result.metrics.weeksWithCompletedWorkouts, 0);
  assert.ok(result.limitations.some((entry) => entry.includes("충분한 자료가 없음")));
  assert.ok(result.limitations.some((entry) => entry.includes("부분 주")));
  assert.equal(validateReviewPayload(result), result);
});

test("drafts, other plans, incomplete rows and duplicated saved keys cannot inflate completed metrics", () => {
  const state = createDefaultState();
  state.workoutLogs.a = log("2026-10-26", { exercises: { press: exercise({ sets: [set(), set({ completed: false, weight: 100 })] }) } });
  state.workoutLogs.duplicate = structuredClone(state.workoutLogs.a);
  state.workoutLogs.other = log("2026-10-27", { planId: "different-plan" });
  state.workoutLogs.uncompleted = log("2026-10-28", { exercises: { press: exercise({ sets: [set({ completed: false })] }) } });
  state.workoutDrafts.a = log("2026-10-26", { exercises: { press: exercise({ sets: [set({ weight: 999 })] }) } });
  state.workoutDrafts.onlyDraft = log("2026-10-29");
  const before = structuredClone(state);
  const result = payload(state);
  assert.equal(result.workouts.length, 1);
  assert.equal(result.metrics.current.completedSets, 1);
  assert.equal(result.metrics.current.savedSetSlots, 3);
  assert.equal(result.metrics.current.savedWorkoutsWithoutCompletedSets, 1);
  assert.equal(result.metrics.current.recordedSetCompletionRatio, 0.333);
  assert.equal(result.workouts[0].exercises[0].sets[0].weight, 20);
  assert.deepEqual(state, before);
  assert.equal(validateReviewPayload(result), result);
});

test("missing RIR and recovery remain unknown, while recorded zero RIR remains a real observation", () => {
  const state = createDefaultState();
  state.workoutLogs.a = log("2026-10-26", { exercises: { press: exercise({ sets: [set({ rir: "" }), set({ rir: 0 }), set({ rir: 2 })] }) } });
  const result = payload(state);
  assert.deepEqual(result.metrics.current.rir, { average: 1, count: 2, eligible: 3 });
  assert.deepEqual(result.metrics.current.recovery, { yes: 0, no: 0, unknown: 1, total: 1 });
  assert.equal(result.workouts[0].response.painNext, null);
  assert.equal(result.workouts[0].exercises[0].sets[0].rir, null);
  assert.ok(result.evidence.some((entry) => entry.id === "metrics:current:rir" && entry.label.includes("3개 완료 세트 중 2개")));
});

test("daily sleep and independent body fields show coverage, legacy weekly sleep is not double counted", () => {
  const state = createDefaultState();
  state.dailySleepLogs = [{ date: "2026-10-26", hours: 6 }, { date: "2026-10-27", hours: 8 }, { date: "2026-10-28", hours: "" }];
  state.sleepLogs = [{ week: "2026-10-26", hours: 9 }];
  state.bodyLogs = [{ date: "2026-10-26", weight: 70 }, { date: "2026-10-27", waist: 80 }, { date: "2026-10-29", weight: 71 }];
  const result = payload(state);
  assert.deepEqual(result.metrics.current.sleep, { average: 7, count: 2, eligible: 7 });
  assert.equal(result.metrics.legacyWeeklySleepRecords.length, 1);
  assert.deepEqual(result.metrics.current.body.weight, { first: 70, last: 71, change: 1, average: 70.5, count: 2, unit: "kg" });
  assert.deepEqual(result.metrics.current.body.waist, { first: 80, last: 80, change: null, average: 80, count: 1, unit: "cm" });
  assert.equal(result.metrics.bodyRecords[0].waist, null);
});

test("cardio duration counts completed recorded time only and does not pool timed strength with cardio", () => {
  const state = createDefaultState();
  state.workoutLogs.a = log("2026-10-27", { exercises: {
    run: exercise({ name: "Run", measurement: "distance_time", sets: [{ completed: true, minutes: 20, distance: 3, rpe: 4 }, { completed: true, distance: 2 }, { completed: false, minutes: 100 }] }),
    plank: exercise({ name: "Plank", measurement: "duration", category: "Strength", sets: [{ completed: true, minutes: 3 }] }),
  }, extraActivities: [{ id: "cycle", name: "Cycling", type: "cycling", measurement: "duration", sets: [{ completed: true, minutes: 10 }] }] });
  const result = payload(state);
  assert.deepEqual(result.metrics.current.cardio, { recordedSeconds: 1800, durationSets: 2, totalSets: 3 });
  assert.equal(result.workouts[0].exercises.at(-1).source, "extra");
});

test("exercise identity isolates variant, apparatus, unit, plan and pull-up progression step", () => {
  const state = createDefaultState();
  state.workoutLogs.current = log("2026-10-26", { exercises: { press: exercise({ equipment: "machine-a", units: { weight: "kg" } }) } });
  const variants = [
    { equipment: "machine-b" }, { equipment: "machine-a", variantId: "incline" },
    { equipment: "machine-a", units: { weight: "lb" } }, { equipment: "machine-a", progressionStep: 2 },
    { equipment: "machine-a", name: "Renamed historical movement" },
  ];
  variants.forEach((variant, index) => { state.workoutLogs[`prior-${index}`] = log(`2026-10-${String(10 + index).padStart(2, "0")}`, { exercises: { press: exercise(variant) } }); });
  state.workoutLogs.same = log("2026-10-19", { exercises: { press: exercise({ equipment: "machine-a", sets: [set({ weight: 18 })] }) } });
  state.workoutLogs.other = log("2026-10-20", { planId: "another", exercises: { press: exercise({ equipment: "machine-a" }) } });
  const trend = payload(state).metrics.exerciseTrends[0];
  assert.equal(trend.current.sessions, 1);
  assert.equal(trend.baseline.sessions, 1);
  assert.equal(trend.loadAtMatchedReps[0].delta, 2);
  assert.equal(trend.units.weight, "kg");
});

test("higher assistance at equal reps is explicitly easier, never labelled increased performance", () => {
  const state = createDefaultState();
  state.workoutLogs.current = log("2026-10-26", { exercises: { pullup: exercise({ name: "Assisted pull-up", measurement: "assisted_reps", sets: [{ completed: true, assistance: 40, reps: 8 }] }) } });
  state.workoutLogs.prior = log("2026-10-19", { exercises: { pullup: exercise({ name: "Assisted pull-up", measurement: "assisted_reps", sets: [{ completed: true, assistance: 30, reps: 8 }] }) } });
  const result = payload(state);
  const trend = result.metrics.exerciseTrends[0];
  assert.equal(trend.loadField, "assistance");
  assert.equal(trend.loadAtMatchedReps[0].delta, 10);
  assert.equal(trend.loadAtMatchedReps[0].interpretation, "more_assistance_easier");
  assert.deepEqual(trend.repsAtMatchedLoad, []);
  assert.equal(result.metrics.weeksWithCompletedWorkouts, 1);
  assert.ok(result.limitations.some((entry) => entry.includes("1주뿐")));
  assert.ok(result.evidence.some((entry) => entry.id === "trend:1" && entry.label.includes("more_assistance_easier")));
});

test("only saved historical targets are used; current snapshot never invents historical plan versions", () => {
  const state = createDefaultState();
  state.workoutLogs.a = log("2026-10-26", { exercises: { press: exercise({ coachingPlan: { kind: "strength", sets: 2, minReps: 6, maxReps: 8, minRir: 2 },
    coaching: { technique: "yes", reserve: 2 }, sets: [set({ rir: 2 }), set({ rir: 2 })] }) } });
  state.workoutLogs.b = log("2026-10-27");
  const result = payload(state);
  assert.equal(result.plan.snapshot[0].exercises[0].sets, 3);
  assert.equal(result.plan.snapshot[0].exercises[0].prescription, "3 × 6–8");
  assert.equal(result.metrics.current.historicalTargetSets, 2);
  assert.equal(result.metrics.current.historicalTargetExerciseCount, 1);
  assert.equal(result.workouts[0].recordedPlanVersion, null);
  assert.equal(result.workouts[0].exercises[0].progressionConstraint.action, "pending");
  assert.match(result.workouts[0].exercises[0].progressionConstraint.title, /Recovery/);
  assert.ok(result.plan.rules.some((rule) => rule.includes("Step 4")));
  assert.equal(validateReviewPayload(result), result);
});

test("previous decisions use latest review per earlier period and never include current/self reviews", () => {
  const state = createDefaultState();
  const review = (id, periodStart, createdAt, status = "not_yet", planId = "form-flow") => ({ id, planId, period: { start: periodStart }, createdAt,
    result: { recommendations: [{ id: "keep", title: "현재 계획 유지", adjustment: "회복을 기록" }] }, decisions: { keep: status } });
  state.aiReviews = [review("old", "2026-10-19", "2026-10-26T01:00:00Z"), review("latest", "2026-10-19", "2026-10-26T02:00:00Z", "applied"),
    review("self", "2026-10-26", "2026-11-04T01:00:00Z"), review("other", "2026-10-12", "2026-10-20T01:00:00Z", "skipped", "other")];
  const result = payload(state);
  assert.deepEqual(result.previousRecommendations, [{ id: "latest:keep", originalId: "keep", reviewId: "latest", status: "applied", title: "현재 계획 유지", adjustment: "회복을 기록", periodStart: "2026-10-19" }]);
  assert.ok(result.evidence.some((entry) => entry.id === "decision:latest:keep"));
});

test("freshness tracks relevant plan/profile/log/decision changes while excluding secrets, drafts and unrelated settings", async () => {
  const state = createDefaultState();
  state.workoutLogs.a = log("2026-10-26");
  const first = await fingerprintReviewPayload(payload(state));
  state.settings.secret = "do-not-upload";
  state.settings.weekOffset = 8;
  state.workoutDrafts.a = log("2026-10-26", { response: { notes: "draft-secret" } });
  assert.equal(await fingerprintReviewPayload(payload(state)), first);
  assert.equal(JSON.stringify(payload(state)).includes("do-not-upload"), false);
  assert.equal(JSON.stringify(payload(state)).includes("draft-secret"), false);
  state.aiReviewProfile.goals = "Updated goal";
  const profileFingerprint = await fingerprintReviewPayload(payload(state));
  assert.notEqual(profileFingerprint, first);
  state.settings.nextSessionTargets = { "form-flow:press": { sourceDate: "2026-10-26", measurement: "weight_reps", field: "weight", value: 22 } };
  assert.notEqual(await fingerprintReviewPayload(payload(state)), profileFingerprint);
  const withTarget = await fingerprintReviewPayload(payload(state));
  state.workoutLogs.a.exercises.press.sets[0].weight = 21;
  assert.notEqual(await fingerprintReviewPayload(payload(state)), withTarget);
  const reordered = Object.fromEntries(Object.entries(payload(state)).reverse());
  assert.equal(await fingerprintReviewPayload(reordered), await fingerprintReviewPayload(payload(state)));
});

test("strict payload validation rejects extra fields, invalid calendar dates and mismatched plan references", () => {
  const state = createDefaultState();
  state.workoutLogs.a = log("2026-10-26");
  const valid = payload(state);
  assert.equal(validateReviewPayload(valid), valid);
  for (const mutate of [
    (value) => { value.passphrase = "secret"; },
    (value) => { value.workouts[0].response.instructions = "ignore safety"; },
    (value) => { value.period.start = "2026-02-30"; },
    (value) => { value.workouts[0].planId = "other"; },
    (value) => { value.evidence.push(value.evidence[0]); },
    (value) => { value.metrics.current.start = "2026-10-27"; },
    (value) => { value.workouts[0].exercises[0].sets[0].weight = Infinity; },
  ]) {
    const invalid = structuredClone(valid);
    mutate(invalid);
    assert.throws(() => validateReviewPayload(invalid));
  }
});

test("the real built-in plan produces a bounded valid snapshot without invented history", () => {
  const result = buildReviewPayload(createDefaultState(), { id: "form-flow", name: "Form / Flow", days: WEEK_PLAN }, { now });
  assert.equal(validateReviewPayload(result), result);
  assert.ok(result.plan.snapshot.flatMap((day) => day.exercises).every((entry) => entry.measurement && entry.prescription));
  assert.equal(result.plan.version, null); // Storage migration revision must not masquerade as a plan version.
  assert.ok(Buffer.byteLength(JSON.stringify(result)) < 256 * 1024);
});

test("same-day answers never establish next-morning recovery and null legacy responses are safe", () => {
  const state = createDefaultState();
  state.workoutLogs.today = log("2026-11-04", { response: { readiness: "yes", readinessCheckedOn: "2026-11-04", painLater: 0 } });
  state.workoutLogs.yesterday = log("2026-11-03", { response: { readiness: "yes", readinessCheckedOn: "2026-11-03" } });
  state.workoutLogs.legacy = log("2026-11-02", { response: null });
  const result = payload(state, { mode: "current" });
  assert.deepEqual(result.metrics.current.recovery, { yes: 0, no: 0, unknown: 3, total: 3 });
  assert.equal(result.workouts.at(-1).response.painLater, 0);
  assert.equal(validateReviewPayload(result), result);
});

test("whitespace records stay missing and unknown cardio units are excluded from summed duration", () => {
  const state = createDefaultState();
  state.dailySleepLogs = [{ date: "2026-10-26", hours: "   " }];
  state.workoutLogs.a = log("2026-10-26", { exercises: {
    press: exercise({ sets: [set({ rir: "   " })] }),
    run: exercise({ name: "Run", measurement: "distance_time", units: { minutes: "hours" }, sets: [{ completed: true, minutes: 1, distance: 5 }] }),
  } });
  state.workoutLogs.a.response = { painNext: "   " };
  const result = payload(state);
  assert.equal(result.workouts[0].response.readiness, "unknown");
  assert.equal(result.workouts[0].response.painNext, null);
  assert.equal(result.metrics.current.rir.average, null);
  assert.equal(result.metrics.current.sleep.count, 0);
  assert.deepEqual(result.metrics.current.cardio, { recordedSeconds: null, durationSets: 0, totalSets: 1 });
});

test("progression constraints cannot use a prior different apparatus or unit to qualify an increase", () => {
  const trained = (extra = {}) => exercise({ sets: [set({ rir: 2 })],
    coachingPlan: { kind: "strength", sets: 1, minReps: 6, maxReps: 8, minRir: 2 }, coaching: { technique: "yes" }, ...extra });
  for (const changed of [{ equipment: "other-machine" }, { units: { weight: "lb" } }]) {
    const state = createDefaultState();
    state.workoutLogs.current = log("2026-10-26", { response: { readiness: "yes" }, exercises: { press: trained() } });
    state.workoutLogs.prior = log("2026-10-19", { response: { readiness: "yes" }, exercises: { press: trained(changed) } });
    const result = payload(state);
    assert.equal(result.workouts.at(-1).exercises[0].progressionConstraint.action, "repeat");
    assert.equal(result.metrics.exerciseTrends[0].baseline.sessions, 0);
    state.workoutLogs.prior.exercises.press = trained();
    assert.equal(payload(state).workouts.at(-1).exercises[0].progressionConstraint.action, "increase");
  }
});

test("mock recommendations remain visibly synthetic when carried into a later review", () => {
  const state = createDefaultState();
  state.aiReviews = [{ id: "mock-one", planId: "form-flow", period: { start: "2026-10-19" }, createdAt: "2026-10-26T01:00:00Z", meta: { mode: "mock" },
    result: { recommendations: [{ id: "keep", title: "현재 계획 유지", adjustment: "회복 기록" }] }, decisions: { keep: "applied" } }];
  const result = payload(state);
  assert.match(result.previousRecommendations[0].title, /^\[모의 응답\]/);
  assert.equal(state.aiReviews[0].result.recommendations[0].title, "현재 계획 유지");
});


test("a realistic complete five-week plan, coaching and daily health records fit the bounded request", () => {
  const state = createDefaultState();
  const days = Object.keys(WEEK_PLAN);
  for (let index = 0; index < 35; index++) {
    const date = new Date(Date.UTC(2026, 8, 28 + index)).toISOString().slice(0, 10);
    const exercises = Object.fromEntries(WEEK_PLAN[days[index % 7]].exercises.map((entry) => {
      const range = entry.prescription.match(/×\s*(\d+)\s*[–-]\s*(\d+)/);
      const coachingPlan = entry.category === "Strength" && entry.measurement === "weight_reps" && range
        ? { kind: "strength", sets: entry.sets, minReps: Number(range[1]), maxReps: Number(range[2]), minRir: 2 } : null;
      return [entry.id, { name: entry.name, measurement: entry.measurement,
        sets: Array.from({ length: entry.sets }, () => ({ completed: true,
          ...Object.fromEntries(MEASUREMENT_TYPES[entry.measurement].fields.map((field) => [field.key, field.key === "weight" ? 20 : 2])) })),
        coachingPlan, coaching: coachingPlan ? { technique: "yes" } : {} }];
    }));
    state.workoutLogs[date] = { date, exercises, response: { readiness: "yes", painDuring: 0, painNext: 0, scaleVersion: 2 } };
    state.dailySleepLogs.push({ date, hours: 7 });
    if (index % 7 === 0) state.bodyLogs.push({ date, weight: 70, waist: 80 });
  }
  const result = buildReviewPayload(state, { id: "form-flow", name: "Form / Flow", days: WEEK_PLAN }, { now });
  assert.equal(validateReviewPayload(result), result);
  assert.equal(result.metrics.weeksWithCompletedWorkouts, 4);
  assert.equal(result.metrics.current.sleep.count, 7);
  assert.ok(result.metrics.current.completedSets + result.metrics.baseline.completedSets > 500);
  assert.ok(Buffer.byteLength(JSON.stringify(result)) < 500 * 1024);
});

test("saved historical targets count even when every set for an exercise was left incomplete", () => {
  const state = createDefaultState();
  const target = { kind: "strength", sets: 3, minReps: 6, maxReps: 8, minRir: 2 };
  state.workoutLogs.a = log("2026-10-26", { exercises: {
    press: exercise({ coachingPlan: target, sets: [set(), set({ completed: false }), set({ completed: false })] }),
    row: exercise({ name: "Row", coachingPlan: target, sets: [set({ completed: false }), set({ completed: false }), set({ completed: false })] }),
  } });
  state.workoutLogs.b = log("2026-10-27", { exercises: {
    press: exercise({ coachingPlan: target, sets: [set({ completed: false }), set({ completed: false }), set({ completed: false })] }),
  } });
  const result = payload(state);
  assert.equal(result.metrics.current.historicalTargetSets, 9);
  assert.equal(result.metrics.current.historicalTargetCompletedSets, 1);
  assert.equal(result.metrics.current.historicalTargetExerciseCount, 3);
  assert.equal(result.metrics.current.recordedWorkouts, 1);
  assert.equal(result.workouts[0].exercises.length, 1);
  assert.equal(validateReviewPayload(result), result);
});

test("progression constraints cannot claim a second qualifying session outside the payload history window", () => {
  const state = createDefaultState();
  const trained = () => exercise({ sets: [set({ rir: 2 })], coachingPlan: { kind: "strength", sets: 1, minReps: 6, maxReps: 8, minRir: 2 },
    coaching: { technique: "yes" } });
  state.workoutLogs.current = log("2026-10-26", { response: { readiness: "yes" }, exercises: { press: trained() } });
  state.workoutLogs.old = log("2026-09-21", { response: { readiness: "yes" }, exercises: { press: trained() } });
  const result = payload(state);
  assert.equal(result.workouts.length, 1);
  assert.equal(result.workouts[0].exercises[0].progressionConstraint.action, "repeat");
  assert.ok(result.limitations.some((entry) => entry.includes("더 오래된 이력")));
  assert.equal(state.workoutLogs.old.date, "2026-09-21");
});
