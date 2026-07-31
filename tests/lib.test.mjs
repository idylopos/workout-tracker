import test from "node:test";
import assert from "node:assert/strict";
import {
  APP_VERSION,
  WEEK_PLAN,
  createDefaultState,
  dateToDayKey,
  findPreviousExerciseLog,
  normalizeResponseRating,
  normalizeState,
  summarizeCardioRange,
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
  assert.equal(state.settings.pullupStep, 1);
  assert.deepEqual(state.workoutLogs, {});
  assert.deepEqual(state.workoutDrafts, {});
  assert.deepEqual(state.sleepLogs, []);
});

test("keeps pull-up progression within the supported roadmap", () => {
  assert.equal(normalizeState({ settings: { pullupStep: 4 } }).settings.pullupStep, 4);
  assert.equal(normalizeState({ settings: { pullupStep: 99 } }).settings.pullupStep, 6);
  assert.equal(normalizeState({ settings: { pullupStep: -2 } }).settings.pullupStep, 1);
});

test("maps legacy 0–10 pain logs to the descriptive five-level scale", () => {
  assert.equal(normalizeResponseRating(0), 0);
  assert.equal(normalizeResponseRating(3), 1);
  assert.equal(normalizeResponseRating(5), 2);
  assert.equal(normalizeResponseRating(7), 3);
  assert.equal(normalizeResponseRating(10), 4);
  assert.equal(normalizeResponseRating(3, 2), 3);
  assert.equal(normalizeResponseRating("", 2), "");
});

test("validates backup shape before restore", () => {
  const valid = validateBackup(createDefaultState());
  assert.equal(valid.valid, true);

  const invalid = validateBackup({ version: APP_VERSION, workoutLogs: [] });
  assert.equal(invalid.valid, false);

  const malformedWorkout = createDefaultState();
  malformedWorkout.workoutLogs["not-a-date"] = { exercises: {} };
  assert.equal(validateBackup(malformedWorkout).valid, false);

  const malformedActivity = createDefaultState();
  malformedActivity.savedActivities = [{ id: "bad", name: "", type: "flying", measurement: "duration" }];
  assert.equal(validateBackup(malformedActivity).valid, false);

  const malformedDraft = createDefaultState();
  malformedDraft.workoutDrafts.today = { date: "not-a-date", exercises: {} };
  assert.equal(validateBackup(malformedDraft).valid, false);

  const legacyWithoutDrafts = createDefaultState();
  delete legacyWithoutDrafts.workoutDrafts;
  assert.equal(validateBackup(legacyWithoutDrafts).valid, true);
});

test("keeps encrypted workout drafts during state normalization", () => {
  const draft = {
    date: "2026-07-31",
    dayKey: "friday",
    planId: "form-flow",
    exercises: {
      press: { measurement: "weight_reps", sets: [{ completed: false, weight: 20, reps: 8 }] },
    },
  };
  const state = normalizeState({ workoutDrafts: { "2026-07-31": draft } });
  assert.deepEqual(state.workoutDrafts["2026-07-31"], draft);
});

test("rebalances direct abdominal and deltoid work without stacking Friday presses", () => {
  const tuesday = WEEK_PLAN.tuesday.exercises;
  const wednesday = WEEK_PLAN.wednesday.exercises;
  const friday = WEEK_PLAN.friday.exercises;
  assert.equal(tuesday.find((exercise) => exercise.id === "cable-lateral-raise").sets, 3);
  assert.equal(wednesday.find((exercise) => exercise.id === "face-pull").sets, 3);
  assert.equal(wednesday.find((exercise) => exercise.id === "kneeling-cable-crunch").sets, 2);
  assert.equal(friday.find((exercise) => exercise.id === "cable-scaption").sets, 3);
  assert.equal(friday.find((exercise) => exercise.id === "reverse-crunch").sets, 2);
  assert.equal(friday.some((exercise) => exercise.id === "push-up-plus"), false);
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

test("summarizes check-off mobility rounds", () => {
  const summary = summarizeExercise(
    {
      session: {
        date: "2026-07-08",
        exercises: {
          calf: {
            measurement: "completion",
            sets: [{ completed: true }, { completed: false }],
          },
        },
      },
    },
    "calf",
  );
  assert.equal(summary.latest, "1 / 2 rounds");
  assert.equal(summary.volume, "1");
});

test("keeps valid reusable activities when normalizing saved state", () => {
  const state = normalizeState({
    savedActivities: [
      { id: "saved-incline-walk", name: "Incline walk", type: "walking", measurement: "duration" },
      { id: "invalid", name: "", type: "custom", measurement: "duration" },
    ],
  });
  assert.deepEqual(state.savedActivities, [
    { id: "saved-incline-walk", name: "Incline walk", type: "walking", measurement: "duration" },
  ]);
});

test("combines planned and extra cardio in weekly totals", () => {
  const summary = summarizeCardioRange(
    {
      monday: {
        date: "2026-07-27",
        exercises: {
          bike: {
            measurement: "duration",
            sets: [{ completed: true, minutes: 20, seconds: 0, rpe: 7 }],
          },
        },
        extraActivities: [
          {
            id: "extra-incline-walk",
            type: "walking",
            name: "Incline walk",
            measurement: "distance_time",
            sets: [{ completed: true, distance: 2.5, minutes: 25, seconds: 0, rpe: 3 }],
          },
        ],
      },
      outside: {
        date: "2026-08-03",
        exercises: {
          bike: {
            measurement: "duration",
            sets: [{ completed: true, minutes: 60, rpe: 5 }],
          },
        },
      },
    },
    "2026-07-27",
    "2026-08-03",
    ["bike"],
  );
  assert.equal(summary.minutes, 45);
  assert.equal(summary.distance, 2.5);
  assert.equal(summary.sessions, 2);
  assert.equal(summary.extraSessions, 1);
  assert.equal(summary.averageRpe, 5);
});
