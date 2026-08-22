import test from "node:test";
import assert from "node:assert/strict";
import {
  APP_VERSION,
  EXERCISE_GUIDANCE,
  LONG_RUN_PHASES,
  LONG_RUNS,
  MEASUREMENT_TYPES,
  WEEK_PLAN,
  countQualifiedLongRuns,
  createDefaultState,
  dateToDayKey,
  evaluateLongRunProgress,
  findPreviousExerciseLog,
  getAllExercises,
  longRunTargetDistance,
  normalizeResponseRating,
  normalizeState,
  preparePreviousSets,
  shouldCollapseExerciseByDefault,
  shouldShowRestTimer,
  summarizeCardioRange,
  summarizeExercise,
  validateBackup,
} from "../lib.js";

test("shows the rest timer outside Today only while active or finished", () => {
  assert.equal(shouldShowRestTimer("today", false, false), true);
  assert.equal(shouldShowRestTimer("progress", false, false), false);
  assert.equal(shouldShowRestTimer("progress", true, false), true);
  assert.equal(shouldShowRestTimer("data", false, true), true);
});

test("collapses only untouched optional exercises on compact screens", () => {
  const optional = { optional: true };
  const required = { optional: false };
  assert.equal(shouldCollapseExerciseByDefault(optional, null, true), true);
  assert.equal(shouldCollapseExerciseByDefault(optional, { sets: [] }, true), false);
  assert.equal(shouldCollapseExerciseByDefault(required, null, true), false);
  assert.equal(shouldCollapseExerciseByDefault(optional, null, false), false);
});

test("Use Last preserves today's set count and clears completion and effort", () => {
  const copied = preparePreviousSets(
    [
      { weight: 45, reps: 10, rir: 2, completed: true },
      { weight: 50, reps: 8, rir: 1, completed: true },
    ],
    3,
    "weight_reps",
  );

  assert.deepEqual(copied, [
    { weight: 45, reps: 10, completed: false },
    { weight: 50, reps: 8, completed: false },
    { weight: 50, reps: 8, completed: false },
  ]);
});

test("Use Last trims extra historical sets without marking today's sets done", () => {
  const copied = preparePreviousSets(
    [{ completed: true }, { completed: true }, { completed: true }],
    2,
    "completion",
  );
  assert.deepEqual(copied, [{ completed: false }, { completed: false }]);
});

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
  assert.equal(state.settings.builtInPlanRevision, 2);
});

test("migrates the old built-in suitcase carry default without changing other measurement preferences", () => {
  const state = normalizeState({
    settings: { builtInPlanRevision: 1 },
    exerciseConfigs: { "suitcase-carry": "weight_reps", "box-squat": "reps" },
    workoutLogs: {
      "2026-08-21": {
        date: "2026-08-21",
        exercises: {
          "suitcase-carry": {
            measurement: "weight_reps",
            sets: [{ completed: true, weight: 20, reps: 30, rir: 2 }],
          },
        },
      },
    },
  });
  assert.equal(state.exerciseConfigs["suitcase-carry"], undefined);
  assert.equal(state.exerciseConfigs["box-squat"], "reps");
  assert.deepEqual(state.workoutLogs["2026-08-21"].exercises["suitcase-carry"], {
    measurement: "weight_distance",
    sets: [{ completed: true, weight: 20, distance: 30, rir: 2 }],
  });
});

test("keeps pull-up progression within the supported roadmap", () => {
  assert.equal(normalizeState({ settings: { pullupStep: 4 } }).settings.pullupStep, 4);
  assert.equal(normalizeState({ settings: { pullupStep: 99 } }).settings.pullupStep, 6);
  assert.equal(normalizeState({ settings: { pullupStep: -2 } }).settings.pullupStep, 1);
});

test("keeps long-run progression within the supported settings range", () => {
  assert.equal(normalizeState({ settings: { longRunWeek: 7 } }).settings.longRunWeek, 7);
  assert.equal(normalizeState({ settings: { longRunWeek: 99 } }).settings.longRunWeek, 52);
  assert.equal(normalizeState({ settings: { longRunWeek: -2 } }).settings.longRunWeek, 1);
  assert.deepEqual(LONG_RUN_PHASES.map((phase) => [phase.start, phase.end]), [
    [1, 4],
    [5, 8],
    [9, 12],
    [13, 18],
  ]);
  assert.equal(LONG_RUNS.length, 18);
  assert.equal(LONG_RUNS[16], "10.0 km repeat");
});

test("evaluates long-run readiness from target, RPE, and next-morning response", () => {
  assert.equal(longRunTargetDistance("6–7 km recovery"), 6);
  const ready = evaluateLongRunProgress(
    {
      exercises: {
        "long-run": {
          measurement: "distance_time",
          progressionStage: 5,
          sets: [{ completed: true, distance: 5.6, minutes: 42, rpe: 4 }],
        },
      },
      response: { scaleVersion: 2, painNext: 1 },
    },
    "5.6 km",
  );
  assert.equal(ready.status, "ready");

  const pending = evaluateLongRunProgress(
    {
      exercises: {
        "long-run": {
          measurement: "distance_time",
          sets: [{ completed: true, distance: 5.6, minutes: 42, rpe: 3 }],
        },
      },
      response: { scaleVersion: 2, painNext: "" },
    },
    "5.6 km",
  );
  assert.equal(pending.status, "pending");

  const repeat = evaluateLongRunProgress(
    {
      exercises: {
        "long-run": {
          measurement: "distance_time",
          sets: [{ completed: true, distance: 5.6, minutes: 42, rpe: 6 }],
        },
      },
      response: { scaleVersion: 2, painNext: 0 },
    },
    "5.6 km",
  );
  assert.equal(repeat.status, "repeat");
});

test("requires two separately qualified 10 km runs before Block 2", () => {
  const qualified = (date) => ({
    date,
    exercises: {
      "long-run": {
        measurement: "distance_time",
        sets: [{ completed: true, distance: 10, minutes: 72, rpe: 4 }],
      },
    },
    response: { scaleVersion: 2, painNext: 1 },
  });
  assert.equal(countQualifiedLongRuns({ first: qualified("2026-08-01") }), 1);
  assert.equal(countQualifiedLongRuns({ first: qualified("2026-08-01"), second: qualified("2026-08-15") }), 2);
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

  const progressionBackup = createDefaultState();
  progressionBackup.workoutLogs["2026-08-01"] = {
    date: "2026-08-01",
    dayKey: "saturday",
    planId: "form-flow",
    exercises: {
      "long-run": {
        measurement: "distance_time",
        progressionStage: 5,
        sets: [{ completed: true, distance: 5.6, minutes: 42, seconds: 0, rpe: 3 }],
      },
      "pull-up-progression": {
        measurement: "assisted_reps",
        progressionStep: 2,
        progressionPerformanceQualified: true,
        progressionRecoveryQualified: true,
        progressionQualified: true,
        sets: [{ completed: true, assistance: 20, reps: 8, rir: 1 }],
      },
    },
    response: { scaleVersion: 2, painNext: 0 },
  };
  assert.equal(validateBackup(progressionBackup).valid, true);
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

test("uses high-return chest, back, and rectus-abdominis volumes without removing functional core work", () => {
  const tuesday = WEEK_PLAN.tuesday.exercises;
  const wednesday = WEEK_PLAN.wednesday.exercises;
  const friday = WEEK_PLAN.friday.exercises;
  const saturday = WEEK_PLAN.saturday.exercises;
  assert.equal(tuesday.find((exercise) => exercise.id === "cable-lateral-raise").sets, 3);
  assert.equal(tuesday.find((exercise) => exercise.id === "cable-chest-fly").sets, 2);
  assert.equal(tuesday.find((exercise) => exercise.id === "kneeling-cable-crunch").sets, 3);
  assert.equal(wednesday.find((exercise) => exercise.id === "face-pull").sets, 3);
  assert.equal(wednesday[4].id, "pallof-press");
  assert.equal(wednesday[4].sets, 2);
  assert.equal(wednesday[4].measurement, "weight_reps");
  assert.equal(friday.find((exercise) => exercise.id === "cable-scaption").sets, 3);
  assert.equal(friday.find((exercise) => exercise.id === "cable-chest-fly").sets, 2);
  assert.equal(friday.find((exercise) => exercise.id === "reverse-crunch").sets, 3);
  assert.equal(friday.find((exercise) => exercise.id === "suitcase-carry").sets, 2);
  assert.equal(friday.find((exercise) => exercise.id === "suitcase-carry").measurement, "weight_distance");
  assert.equal(MEASUREMENT_TYPES.weight_distance.label, "Weight + distance");
  assert.equal(friday.some((exercise) => exercise.id === "push-up-plus"), false);
  assert.equal(friday.some((exercise) => exercise.id === "mobility-b"), false);
  assert.equal(friday.filter((exercise) => exercise.id.startsWith("mobility-b-")).length, 3);
  assert.ok(["pull-up-progression", "one-arm-cable-row", "db-pullover"].every((id) => !saturday.find((exercise) => exercise.id === id).optional));
  assert.ok(["face-pull", "cable-curl"].every((id) => saturday.find((exercise) => exercise.id === id).optional));

  const fractionalChestSets =
    tuesday.find((exercise) => exercise.id === "neutral-db-bench").sets +
    tuesday.find((exercise) => exercise.id === "cable-chest-fly").sets +
    tuesday.find((exercise) => exercise.id === "half-kneeling-landmine-press").sets * 0.5 +
    friday.find((exercise) => exercise.id === "neutral-incline-db-press").sets +
    friday.find((exercise) => exercise.id === "cable-chest-fly").sets +
    friday.find((exercise) => exercise.id === "one-arm-landmine-press").sets * 0.5;
  const directBackSets =
    wednesday.find((exercise) => exercise.id === "pull-up-progression").sets +
    wednesday.find((exercise) => exercise.id === "chest-supported-row").sets +
    saturday.find((exercise) => exercise.id === "pull-up-progression").sets +
    saturday.find((exercise) => exercise.id === "one-arm-cable-row").sets +
    saturday.find((exercise) => exercise.id === "db-pullover").sets;
  assert.equal(fractionalChestSets, 12.5);
  assert.equal(directBackSets, 12);
  assert.equal(
    tuesday.find((exercise) => exercise.id === "kneeling-cable-crunch").sets +
      friday.find((exercise) => exercise.id === "reverse-crunch").sets,
    6,
  );
});

test("keeps lunge-twist preparation and Mobility A low-volume", () => {
  const mondayWarmup = WEEK_PLAN.monday.warmup;
  const wednesday = WEEK_PLAN.wednesday.exercises;
  const mobilityA = wednesday.filter((exercise) => exercise.id.startsWith("mobility-a-"));
  assert.match(mondayWarmup.join(" "), /Lunge twist/);
  assert.match(mondayWarmup.join(" "), /rotate the upper torso toward the lead leg/);
  assert.equal(mobilityA.length, 5);
  assert.ok(mobilityA.every((exercise) => exercise.sets === 1 && exercise.measurement === "completion"));
  assert.equal(wednesday.at(-1).id, "mobility-a-seated-good-morning");
});

test("provides a quick form guide for every built-in exercise", () => {
  const missing = getAllExercises(WEEK_PLAN)
    .map((exercise) => exercise.id)
    .filter((exerciseId) => !EXERCISE_GUIDANCE[exerciseId]);
  assert.deepEqual(missing, []);
  assert.match(EXERCISE_GUIDANCE["assisted-nordic"].option, /bridge hamstring walkouts/i);
  assert.match(EXERCISE_GUIDANCE["mobility-a-bridge-march"].watch, /stability drill, not a stretch/i);
  assert.match(EXERCISE_GUIDANCE["mobility-b-adductor"].setup, /not the adductor machine/i);
  assert.match(EXERCISE_GUIDANCE["cable-scaption"].option, /machine lateral raise/i);
  assert.match(EXERCISE_GUIDANCE["cable-scaption"].setup, /one-arm cable scaption raise/i);
  assert.match(EXERCISE_GUIDANCE["cable-scaption"].action, /side deltoid.*shoulder width/i);
  assert.match(EXERCISE_GUIDANCE["cable-chest-fly"].watch, /shoulder discomfort/i);
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

test("finds the last exercise across skipped weeks and encrypted drafts", () => {
  const logs = {
    old: {
      date: "2026-06-01",
      exercises: { squat: { measurement: "weight_reps", sets: [{ weight: 50, reps: 8 }] } },
    },
    recentWithoutSquat: {
      date: "2026-07-20",
      exercises: { press: { measurement: "weight_reps", sets: [{ weight: 20, reps: 10 }] } },
    },
  };
  const drafts = {
    newerSquat: {
      date: "2026-07-06",
      exercises: { squat: { measurement: "weight_reps", sets: [{ weight: 57.5, reps: 6 }] } },
    },
  };

  const previous = findPreviousExerciseLog(logs, "squat", "2026-08-01", "form-flow", drafts);
  assert.equal(previous.date, "2026-07-06");
  assert.equal(previous.sets[0].weight, 57.5);
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

test("summarizes loaded carries as weight-distance work", () => {
  const summary = summarizeExercise(
    {
      session: {
        date: "2026-08-21",
        exercises: {
          "suitcase-carry": {
            measurement: "weight_distance",
            sets: [
              { weight: 20, distance: 30 },
              { weight: 22, distance: 25 },
            ],
          },
        },
      },
    },
    "suitcase-carry",
  );
  assert.equal(summary.latest, "20 kg × 30 m");
  assert.equal(summary.volume, "1,150");
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
