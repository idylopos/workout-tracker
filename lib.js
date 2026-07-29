export const APP_VERSION = 1;
export const STORAGE_KEY = "formflow.training.v1";

export const EXTRA_ACTIVITY_TYPES = ["walking", "cycling", "elliptical", "swimming", "running", "custom"];
export const EXTRA_ACTIVITY_MEASUREMENTS = ["duration", "distance_time", "distance"];

export const MEASUREMENT_TYPES = {
  completion: {
    label: "Check-off only",
    short: "Done",
    fields: [],
  },
  weight_reps: {
    label: "Weight × reps",
    short: "Load",
    fields: [
      { key: "weight", label: "Weight", unit: "kg", min: 0, step: 0.5 },
      { key: "reps", label: "Reps", unit: "", min: 0, step: 1 },
      { key: "rir", label: "RIR", unit: "", min: 0, max: 10, step: 1 },
    ],
  },
  reps: {
    label: "Reps only",
    short: "Reps",
    fields: [
      { key: "reps", label: "Reps", unit: "", min: 0, step: 1 },
      { key: "rir", label: "RIR", unit: "", min: 0, max: 10, step: 1 },
    ],
  },
  assisted_reps: {
    label: "Assistance × reps",
    short: "Assisted",
    fields: [
      { key: "assistance", label: "Assistance", unit: "kg", min: 0, step: 0.5 },
      { key: "reps", label: "Reps", unit: "", min: 0, step: 1 },
      { key: "rir", label: "RIR", unit: "", min: 0, max: 10, step: 1 },
    ],
  },
  duration: {
    label: "Time only",
    short: "Time",
    fields: [
      { key: "minutes", label: "Minutes", unit: "min", min: 0, step: 1 },
      { key: "seconds", label: "Seconds", unit: "sec", min: 0, max: 59, step: 1 },
      { key: "rpe", label: "RPE", unit: "", min: 0, max: 10, step: 1 },
    ],
  },
  distance_time: {
    label: "Distance + time",
    short: "Distance",
    fields: [
      { key: "distance", label: "Distance", unit: "km", min: 0, step: 0.1 },
      { key: "minutes", label: "Minutes", unit: "min", min: 0, step: 1 },
      { key: "seconds", label: "Seconds", unit: "sec", min: 0, max: 59, step: 1 },
      { key: "rpe", label: "RPE", unit: "", min: 0, max: 10, step: 1 },
    ],
  },
  distance: {
    label: "Distance only",
    short: "Distance",
    fields: [
      { key: "distance", label: "Distance", unit: "km", min: 0, step: 0.1 },
      { key: "rpe", label: "RPE", unit: "", min: 0, max: 10, step: 1 },
    ],
  },
};

export const PULL_UP_STEPS = [
  {
    id: 1,
    label: "Step 1 · Assisted base",
    title: "Assisted neutral-grip pull-up",
    prescription: "3 × 5 · choose assistance that leaves about 2 reps in reserve",
    sets: 3,
    measurement: "assisted_reps",
    target: "Complete all 3 × 5 with smooth, full-range reps.",
    next: "After 2 successful sessions, keep the same assistance and move to Step 2.",
  },
  {
    id: 2,
    label: "Step 2 · Build assisted reps",
    title: "Assisted neutral-grip pull-up",
    prescription: "3 × 6–8 · keep at least 1 rep in reserve",
    sets: 3,
    measurement: "assisted_reps",
    target: "Build to 3 × 8 without shortening the range or kicking.",
    next: "After 2 successful 3 × 8 sessions, move to Step 3.",
  },
  {
    id: 3,
    label: "Step 3 · Reduce assistance",
    title: "Lightly assisted neutral-grip pull-up",
    prescription: "3 × 5–8 · reduce assistance by the smallest available step",
    sets: 3,
    measurement: "assisted_reps",
    target: "Rebuild from 3 × 5 toward 3 × 8 each time assistance is reduced.",
    next: "Move on after 2 successful 3 × 8 sessions at the lowest machine assistance or thinnest stable band.",
  },
  {
    id: 4,
    label: "Step 4 · Clean singles",
    title: "Unassisted pull-up singles",
    prescription: "5 × 1 · rest 2–3 min · no grinding or kipping",
    sets: 5,
    measurement: "reps",
    target: "Complete five clean singles, each starting from control.",
    next: "After 2 successful sessions, move to Step 5.",
  },
  {
    id: 5,
    label: "Step 5 · Repeatable doubles",
    title: "Unassisted pull-up",
    prescription: "4 × 2 · keep at least 1 rep in reserve",
    sets: 4,
    measurement: "reps",
    target: "Complete all four doubles with the same range and tempo.",
    next: "After 2 successful sessions, move to Step 6.",
  },
  {
    id: 6,
    label: "Step 6 · Build to five",
    title: "Unassisted pull-up",
    prescription: "3 sets · aim for 3–5 clean reps · stop with at least 1 rep in reserve",
    sets: 3,
    measurement: "reps",
    target: "Build the first set to five continuous, clean repetitions.",
    next: "Five clean reps completes the 0 → 5 roadmap. Stay here and add total reps gradually.",
  },
];

export const RESPONSE_SCALE = [
  {
    value: 0,
    face: "😄",
    label: "Comfortable",
    description: "No meaningful pain; at your normal baseline or better.",
  },
  {
    value: 1,
    face: "🙂",
    label: "Mild",
    description: "Noticeable but stable; movement and technique stayed normal.",
  },
  {
    value: 2,
    face: "😐",
    label: "Adjust",
    description: "Clearly rising or more noticeable; reduce load, range, or volume next time.",
  },
  {
    value: 3,
    face: "🙁",
    label: "Stop",
    description: "Sharp, limiting, or changed your movement; stop the provoking exercise.",
  },
  {
    value: 4,
    face: "😧",
    label: "Red flag",
    description: "Swelling, locking, giving way, night pain, or persistent worsening—seek assessment.",
  },
];

export function normalizeResponseRating(value, scaleVersion = 1) {
  if (value === "" || value === null || value === undefined) return "";
  const rating = Number(value);
  if (!Number.isFinite(rating)) return "";
  if (Number(scaleVersion) >= 2) return Math.max(0, Math.min(4, Math.round(rating)));
  if (rating <= 0) return 0;
  if (rating <= 3) return 1;
  if (rating <= 5) return 2;
  if (rating <= 7) return 3;
  return 4;
}

const lift = (id, name, prescription, sets, rest = 90, measurement = "weight_reps", options = {}) => ({
  id,
  name,
  prescription,
  sets,
  rest,
  measurement,
  category: "Strength",
  ...options,
});

const activity = (id, name, prescription, measurement = "duration", options = {}) => ({
  id,
  name,
  prescription,
  sets: 1,
  rest: 0,
  measurement,
  category: "Cardio",
  ...options,
});

export const WEEK_PLAN = {
  monday: {
    label: "Monday",
    short: "MON",
    focus: "Legs A + bicycle HIIT",
    kicker: "Strength · power · intervals",
    estimate: "70–90 min + later HIIT",
    tone: "lime",
    sequenceNote: "Keep the bicycle HIIT at least 6 hours after lifting.",
    warmup: [
      "Easy bicycle · 3–5 min at RPE 2–3",
      "Ankle rocks · 8/side",
      "Bodyweight hip hinge · 8",
      "Bodyweight box squat · 8",
      "Low step-down · 5/side",
      "Glute bridge with breathing · 2 × 8",
      "Squat-jump practice · 2 reps at 50–60%, then 2 at 70–80%",
      "Box-squat ramp · light × 8, 50% × 5, 70% × 3, optional 80–85% × 1",
    ],
    exercises: [
      lift("squat-jump", "Squat jump", "2 × 3 · add only after 2 symptom-stable weeks", 2, 90, "reps"),
      lift("box-squat", "Box squat", "3 × 5–8", 3, 150),
      lift("bulgarian-split-squat", "Bulgarian split squat", "2 × 8–10 / leg", 2, 120),
      lift("assisted-nordic", "Assisted Nordic hamstring", "1–2 × 3–5", 2, 120, "reps"),
      lift("hip-abduction", "Machine or cable hip abduction", "2 × 12–20", 2, 75),
      lift("standing-calf-raise", "Standing calf raise", "2 × 8–15", 2, 75),
      lift("tibialis-raise", "Tibialis raise", "2 × 12–20", 2, 60),
      lift("copenhagen-plank", "Short-lever Copenhagen plank", "2 × 15–25 sec / side", 2, 60, "duration"),
      activity(
        "bicycle-hiit",
        "Bicycle HIIT",
        "10-min warm-up; 6 × 1 min at RPE 8–9 with 2 min easy; 8–10-min cooldown",
        "duration",
        { section: "Later session" },
      ),
    ],
  },
  tuesday: {
    label: "Tuesday",
    short: "TUE",
    focus: "Push A + easy run",
    kicker: "Upper strength · aerobic base",
    estimate: "70–90 min total",
    tone: "blue",
    sequenceNote: "Keep the run conversational. Separate it from lifting when practical.",
    warmup: [
      "Easy bicycle or elliptical · 3 min",
      "Serratus wall slide · 1 × 8",
      "Very light cable external rotation · 1 × 10/side",
      "Slow arm circles · 5 each direction",
      "Landmine ramp · light × 8/side, 50% × 5/side, 70% × 3/side",
      "Dumbbell press · 1 lighter set × 5",
    ],
    exercises: [
      lift("half-kneeling-landmine-press", "Half-kneeling 1-arm landmine press", "3 × 6–10 / side", 3, 120),
      lift("neutral-db-bench", "Neutral-grip dumbbell bench press", "3 × 6–10", 3, 150),
      lift("cable-lateral-raise", "Cable lateral raise", "2 × 12–20", 2, 75),
      lift("rope-pressdown", "Rope triceps press-down", "2 × 10–15", 2, 75),
      lift("cable-external-rotation", "Cable external rotation", "2 × 12–20", 2, 60),
      activity("easy-run", "Easy run", "Block 1: 30 min, RPE 2–4 · Block 2: 30–40 min + 4 × 20-sec strides", "distance_time"),
      activity("pelvic-floor", "Pelvic-floor routine", "5 breaths; 8 × 5-sec holds with full relaxation; 8 quick contractions", "duration", {
        category: "Recovery",
      }),
    ],
  },
  wednesday: {
    label: "Wednesday",
    short: "WED",
    focus: "Pull A + Mobility A",
    kicker: "Pull-up skill · recovery",
    estimate: "55–75 min",
    tone: "orange",
    sequenceNote: "Optional cycling only when sleep, legs, running, and joints feel normal.",
    warmup: [
      "Easy bicycle · 3 min",
      "Serratus wall slide · 1 × 8",
      "Very light cable external rotation · 1 × 10/side",
      "Foot-assisted scapular pull-up · 1 × 5",
      "Highly assisted neutral-grip pull-up · 1 × 5",
      "Moderately assisted pull-up · 1 × 2–3",
    ],
    exercises: [
      lift(
        "pull-up-progression",
        "Pull-up progression",
        "Choose your current performance step below",
        3,
        150,
        "assisted_reps",
        { progression: "pullup" },
      ),
      lift("chest-supported-row", "Chest-supported neutral-grip row", "3 × 6–10", 3, 120),
      lift("face-pull", "Face pull", "2 × 12–20", 2, 75),
      lift("hammer-curl", "Neutral-grip hammer curl", "2 × 8–15", 2, 75),
      lift("mobility-a-calf", "Mobility A · Calf stretch", "2 rounds · 45 sec / side · check each round", 2, 0, "completion", {
        category: "Mobility",
      }),
      lift("mobility-a-hip-flexor", "Mobility A · Hip-flexor stretch", "2 rounds · 45 sec / side · check each round", 2, 0, "completion", {
        category: "Mobility",
      }),
      lift("mobility-a-hamstring", "Mobility A · Strap hamstring stretch", "2 rounds · 45 sec / side · check each round", 2, 0, "completion", {
        category: "Mobility",
      }),
      activity("zone-2-cycle", "Optional Zone 2 cycling", "25–40 min at RPE 2–3 · only when well recovered", "duration", {
        optional: true,
      }),
    ],
  },
  thursday: {
    label: "Thursday",
    short: "THU",
    focus: "Legs B + Run 2",
    kicker: "Posterior chain · run quality",
    estimate: "75–100 min total",
    tone: "pink",
    sequenceNote: "Block 1: lift first. Block 2: quality run first. Separate sessions by about 6 hours.",
    warmup: [
      "Easy bicycle · 3–5 min",
      "Ankle rocks · 8/side",
      "Bodyweight hip hinge · 8",
      "Bodyweight box squat · 8",
      "Low step-down · 5/side",
      "Light kettlebell deadlift · 5",
      "Light kettlebell swing · 2 × 5",
      "Trap-bar ramp · 40% × 6, 60% × 4, 75% × 2, optional 85% × 1",
    ],
    exercises: [
      lift("kettlebell-swing", "Kettlebell swing", "2–3 × 8–12", 3, 90),
      lift("trap-bar-deadlift", "Trap-bar deadlift", "3 × 4–6", 3, 180),
      lift("barbell-hip-thrust", "Barbell hip thrust", "3 × 8–12", 3, 150),
      lift("controlled-step-down", "Controlled step-down", "2 × 6–10 / leg · 3-sec lowering", 2, 90),
      lift("hip-abduction", "Machine or cable hip abduction", "2 × 12–20", 2, 75),
      lift("seated-calf-raise", "Seated calf raise", "2 × 10–15", 2, 75),
      lift("tibialis-raise", "Tibialis raise", "2 × 12–20", 2, 60),
      activity(
        "run-2",
        "Run 2",
        "Block 1 easy 25–35 min · Block 2 alternates tempo and 6 × 2-min intervals",
        "distance_time",
      ),
      activity("pelvic-floor", "Pelvic-floor routine", "5 breaths; 8 × 5-sec holds; 8 quick contractions", "duration", {
        category: "Recovery",
      }),
    ],
  },
  friday: {
    label: "Friday",
    short: "FRI",
    focus: "Push B + Mobility B",
    kicker: "Upper hypertrophy · mobility",
    estimate: "55–75 min",
    tone: "purple",
    sequenceNote: "Use comfortable shoulder paths; do not force clicking or pinching.",
    warmup: [
      "Easy bicycle or elliptical · 3 min",
      "Serratus wall slide · 1 × 8",
      "Very light cable external rotation · 1 × 10/side",
      "Slow arm circles · 5 each direction",
      "Landmine ramp · light × 8/side, 50% × 5/side, 70% × 3/side",
      "Incline dumbbell press · 1 lighter set × 5",
    ],
    exercises: [
      lift("neutral-incline-db-press", "Neutral-grip incline dumbbell press", "3 × 8–12", 3, 150),
      lift("one-arm-landmine-press", "One-arm landmine press", "2 × 10–12 / side", 2, 120),
      lift("push-up-plus", "Push-up plus", "2 × 8–15", 2, 90, "reps"),
      lift("cable-scaption", "Cable scaption raise · thumbs up", "2 × 12–20", 2, 75),
      lift("cross-body-triceps", "Cross-body cable triceps extension", "2 × 10–15", 2, 75),
      lift("cable-external-rotation", "Cable external rotation", "2 × 12–20", 2, 60),
      activity("mobility-b", "Mobility B", "Doorway chest, cross-body shoulder, and supported adductor · 2 × 45 sec / side", "duration", {
        category: "Mobility",
      }),
    ],
  },
  saturday: {
    label: "Saturday",
    short: "SAT",
    focus: "Long run + swim + optional Pull B",
    kicker: "Endurance · technique",
    estimate: "75–130 min total",
    tone: "teal",
    sequenceNote: "Walk breaks are allowed. Pull B is optional and only for a fresh, well-recovered day.",
    warmup: [
      "Long run · start with 5–10 min very easy",
      "Swim · begin with relaxed technique lengths",
      "Pull B if fresh · 2–3 min easy movement",
      "Pull B if fresh · wall slide 1 × 6",
      "Pull B if fresh · highly assisted pull-up 1 × 5",
      "Pull B if fresh · light cable row 1 × 8",
    ],
    exercises: [
      activity("long-run", "Long run", "Block 1: use the 16-week progression · Block 2: 8–10 km easy", "distance_time"),
      activity("easy-swim", "Technique-focused swim", "25–40 min at RPE 2–3 · no paddles, hard butterfly, or fatigued overhead work", "duration"),
      lift(
        "pull-up-progression",
        "Optional pull-up progression",
        "Repeat your current performance step only when fresh",
        2,
        150,
        "assisted_reps",
        { optional: true, progression: "pullup" },
      ),
      lift("one-arm-cable-row", "Optional one-arm cable row", "2 × 10–15 / side", 2, 90, "weight_reps", { optional: true }),
      lift("db-pullover", "Optional light dumbbell pullover", "2 × 10–15", 2, 90, "weight_reps", { optional: true }),
      lift("face-pull", "Optional face pull", "2 × 12–20", 2, 75, "weight_reps", { optional: true }),
      lift("cable-curl", "Optional cable curl", "1–2 × 10–15", 2, 75, "weight_reps", { optional: true }),
      activity("pelvic-floor", "Pelvic-floor routine", "5 breaths; 8 × 5-sec holds; 8 quick contractions", "duration", {
        category: "Recovery",
      }),
    ],
  },
  sunday: {
    label: "Sunday",
    short: "SUN",
    focus: "Complete rest",
    kicker: "Recover · review · reset",
    estimate: "No training",
    tone: "rest",
    sequenceNote: "Ordinary relaxed movement is fine. Review sleep, load, pain, and next-morning responses.",
    warmup: [],
    exercises: [],
  },
};

export const LONG_RUNS = [
  "4.5 km",
  "4.8 km",
  "5.2 km",
  "4.5 km cutback",
  "5.6 km",
  "6.0 km",
  "6.5 km",
  "5.2 km cutback",
  "7.0 km",
  "7.6 km",
  "8.2 km",
  "6.5 km cutback",
  "8.8 km",
  "9.4 km",
  "10.0 km",
  "6–7 km recovery",
];

export function createDefaultState() {
  return {
    version: APP_VERSION,
    settings: {
      block: 1,
      longRunWeek: 1,
      pullupStep: 1,
      weekOffset: 0,
      activePlanId: "form-flow",
    },
    exerciseConfigs: {},
    workoutLogs: {},
    savedActivities: [],
    bodyLogs: [],
    sleepLogs: [],
  };
}

function isValidExtraActivity(activity, requireSets = false) {
  if (!activity || typeof activity !== "object" || Array.isArray(activity)) return false;
  if (
    typeof activity.id !== "string" ||
    !/^[a-z0-9][a-z0-9-]{0,95}$/.test(activity.id) ||
    typeof activity.name !== "string" ||
    !activity.name.trim() ||
    activity.name.length > 80 ||
    !EXTRA_ACTIVITY_TYPES.includes(activity.type) ||
    !EXTRA_ACTIVITY_MEASUREMENTS.includes(activity.measurement)
  ) {
    return false;
  }
  if (
    activity.reusableId !== undefined &&
    activity.reusableId !== "" &&
    (typeof activity.reusableId !== "string" || !/^[a-z0-9][a-z0-9-]{0,95}$/.test(activity.reusableId))
  ) {
    return false;
  }
  if (!requireSets) return activity.sets === undefined;
  return (
    Array.isArray(activity.sets) &&
    activity.sets.every((set) => set && typeof set === "object" && !Array.isArray(set))
  );
}

export function normalizeState(value) {
  const fallback = createDefaultState();
  if (!value || typeof value !== "object") return fallback;
  const settings = { ...fallback.settings, ...(value.settings || {}) };
  settings.block = Number(settings.block) === 2 ? 2 : 1;
  settings.pullupStep = Math.max(1, Math.min(PULL_UP_STEPS.length, Number(settings.pullupStep) || 1));
  return {
    version: APP_VERSION,
    settings,
    exerciseConfigs: value.exerciseConfigs && typeof value.exerciseConfigs === "object" ? value.exerciseConfigs : {},
    workoutLogs: value.workoutLogs && typeof value.workoutLogs === "object" ? value.workoutLogs : {},
    savedActivities: Array.isArray(value.savedActivities)
      ? value.savedActivities.filter((activity) => isValidExtraActivity(activity))
      : [],
    bodyLogs: Array.isArray(value.bodyLogs) ? value.bodyLogs : [],
    sleepLogs: Array.isArray(value.sleepLogs) ? value.sleepLogs : [],
  };
}

export function validateBackup(value) {
  if (!value || typeof value !== "object") return { valid: false, reason: "The file does not contain a JSON object." };
  if (Number(value.version) !== APP_VERSION) {
    return { valid: false, reason: `Unsupported backup version. Expected version ${APP_VERSION}.` };
  }
  if (!value.workoutLogs || typeof value.workoutLogs !== "object" || Array.isArray(value.workoutLogs)) {
    return { valid: false, reason: "Workout logs are missing or malformed." };
  }
  if (!Array.isArray(value.bodyLogs) || !Array.isArray(value.sleepLogs)) {
    return { valid: false, reason: "Body or sleep logs are malformed." };
  }
  if (value.savedActivities !== undefined) {
    if (
      !Array.isArray(value.savedActivities) ||
      !value.savedActivities.every((activity) => isValidExtraActivity(activity))
    ) {
      return { valid: false, reason: "Saved extra activities are malformed." };
    }
  }
  const validDate = (date) => typeof date === "string" && /^\d{4}-\d{2}-\d{2}$/.test(date) && !Number.isNaN(Date.parse(`${date}T12:00:00`));
  const validNumber = (number) => Number.isFinite(Number(number)) && Number(number) >= 0;
  const bodyValid = value.bodyLogs.every(
    (entry) => entry && validDate(entry.date) && validNumber(entry.weight) && validNumber(entry.waist),
  );
  const sleepValid = value.sleepLogs.every(
    (entry) => entry && validDate(entry.week) && validNumber(entry.hours) && Number(entry.hours) <= 24,
  );
  if (!bodyValid || !sleepValid) {
    return { valid: false, reason: "A body or sleep record contains an invalid date or value." };
  }
  const workoutsValid = Object.values(value.workoutLogs).every((log) => {
    if (!log || typeof log !== "object" || !validDate(log.date)) return false;
    if (log.planId !== undefined && (typeof log.planId !== "string" || !/^[a-z0-9][a-z0-9-]{0,63}$/.test(log.planId))) {
      return false;
    }
    if (!log.exercises || typeof log.exercises !== "object" || Array.isArray(log.exercises)) return false;
    const exercisesValid = Object.values(log.exercises).every(
      (exercise) =>
        exercise &&
        Object.hasOwn(MEASUREMENT_TYPES, exercise.measurement) &&
        Array.isArray(exercise.sets) &&
        exercise.sets.every((set) => set && typeof set === "object" && !Array.isArray(set)),
    );
    const extraActivitiesValid =
      log.extraActivities === undefined ||
      (Array.isArray(log.extraActivities) &&
        log.extraActivities.every((activity) => isValidExtraActivity(activity, true)));
    return exercisesValid && extraActivitiesValid;
  });
  if (!workoutsValid) {
    return { valid: false, reason: "A workout record contains an invalid date, measurement type, or set list." };
  }
  return { valid: true, state: normalizeState(value) };
}

export function dateToDayKey(dateString) {
  const date = new Date(`${dateString}T12:00:00`);
  return ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"][date.getDay()];
}

export function toIsoDate(date = new Date()) {
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 10);
}

export function startOfWeek(date = new Date()) {
  const result = new Date(date);
  result.setHours(12, 0, 0, 0);
  const day = result.getDay() || 7;
  result.setDate(result.getDate() - day + 1);
  return result;
}

export function addDays(date, amount) {
  const result = new Date(date);
  result.setDate(result.getDate() + amount);
  return result;
}

export function getAllExercises(weekPlan = WEEK_PLAN) {
  const unique = new Map();
  Object.values(weekPlan).forEach((day) => {
    day.exercises.forEach((exercise) => {
      if (!unique.has(exercise.id)) unique.set(exercise.id, exercise);
    });
  });
  return [...unique.values()].sort((a, b) => a.name.localeCompare(b.name));
}

export function findPreviousExerciseLog(workoutLogs, exerciseId, beforeDate, planId = "form-flow") {
  return Object.values(workoutLogs)
    .filter(
      (log) =>
        (log.planId || "form-flow") === planId &&
        log.date < beforeDate &&
        log.exercises?.[exerciseId]?.sets?.length,
    )
    .sort((a, b) => b.date.localeCompare(a.date))
    .map((log) => ({ date: log.date, ...log.exercises[exerciseId] }))[0] || null;
}

export function findPreviousSession(workoutLogs, dayKey, beforeDate, planId = "form-flow") {
  return Object.values(workoutLogs)
    .filter((log) => (log.planId || "form-flow") === planId && log.dayKey === dayKey && log.date < beforeDate)
    .sort((a, b) => b.date.localeCompare(a.date))[0] || null;
}

function numeric(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function cardioEntryMetrics(entry) {
  if (!entry || !EXTRA_ACTIVITY_MEASUREMENTS.includes(entry.measurement) || !Array.isArray(entry.sets)) {
    return { seconds: 0, distance: 0, rpeTotal: 0, rpeCount: 0, hasActivity: false };
  }
  return entry.sets.reduce(
    (summary, set) => {
      const seconds =
        entry.measurement === "duration" || entry.measurement === "distance_time"
          ? numeric(set.minutes) * 60 + numeric(set.seconds)
          : 0;
      const distance =
        entry.measurement === "distance" || entry.measurement === "distance_time" ? numeric(set.distance) : 0;
      const hasRpe = set.rpe !== "" && set.rpe !== null && set.rpe !== undefined && Number.isFinite(Number(set.rpe));
      summary.seconds += seconds;
      summary.distance += distance;
      if (hasRpe) {
        summary.rpeTotal += numeric(set.rpe);
        summary.rpeCount += 1;
      }
      summary.hasActivity ||= Boolean(set.completed || seconds > 0 || distance > 0 || hasRpe);
      return summary;
    },
    { seconds: 0, distance: 0, rpeTotal: 0, rpeCount: 0, hasActivity: false },
  );
}

export function summarizeCardioRange(workoutLogs, startDate, endDate, cardioExerciseIds = []) {
  const plannedIds = new Set(cardioExerciseIds);
  const totals = {
    seconds: 0,
    minutes: 0,
    distance: 0,
    sessions: 0,
    extraSessions: 0,
    averageRpe: null,
  };
  let rpeTotal = 0;
  let rpeCount = 0;
  Object.values(workoutLogs).forEach((log) => {
    if (!log || log.date < startDate || log.date >= endDate) return;
    Object.entries(log.exercises || {}).forEach(([exerciseId, exercise]) => {
      if (!plannedIds.has(exerciseId)) return;
      const metrics = cardioEntryMetrics(exercise);
      if (!metrics.hasActivity) return;
      totals.seconds += metrics.seconds;
      totals.distance += metrics.distance;
      totals.sessions += 1;
      rpeTotal += metrics.rpeTotal;
      rpeCount += metrics.rpeCount;
    });
    (log.extraActivities || []).forEach((activity) => {
      const metrics = cardioEntryMetrics(activity);
      if (!metrics.hasActivity) return;
      totals.seconds += metrics.seconds;
      totals.distance += metrics.distance;
      totals.sessions += 1;
      totals.extraSessions += 1;
      rpeTotal += metrics.rpeTotal;
      rpeCount += metrics.rpeCount;
    });
  });
  totals.minutes = totals.seconds / 60;
  totals.averageRpe = rpeCount ? rpeTotal / rpeCount : null;
  return totals;
}

function bestSetMetric(measurement, sets = []) {
  if (!sets.length) return { value: 0, label: "—", volume: 0 };
  if (measurement === "completion") {
    const completed = sets.filter((set) => set.completed).length;
    return { value: completed, label: `${completed} / ${sets.length} rounds`, volume: completed };
  }
  if (measurement === "weight_reps") {
    const evaluated = sets.map((set) => {
      const weight = numeric(set.weight);
      const reps = numeric(set.reps);
      return {
        value: weight * (1 + reps / 30),
        label: `${weight || 0} kg × ${reps || 0}`,
        volume: weight * reps,
      };
    });
    const best = [...evaluated].sort((a, b) => b.value - a.value)[0];
    return { ...best, volume: evaluated.reduce((sum, set) => sum + set.volume, 0) };
  }
  if (measurement === "assisted_reps") {
    const best = sets.map((set) => numeric(set.reps)).sort((a, b) => b - a)[0];
    const total = sets.reduce((sum, set) => sum + numeric(set.reps), 0);
    return { value: best, label: `${best} reps`, volume: total };
  }
  if (measurement === "reps") {
    const best = sets.map((set) => numeric(set.reps)).sort((a, b) => b - a)[0];
    const total = sets.reduce((sum, set) => sum + numeric(set.reps), 0);
    return { value: best, label: `${best} reps`, volume: total };
  }
  if (measurement === "duration") {
    const seconds = sets.reduce((sum, set) => sum + numeric(set.minutes) * 60 + numeric(set.seconds), 0);
    return { value: seconds / 60, label: formatDuration(seconds), volume: seconds };
  }
  if (measurement === "distance_time") {
    const distance = sets.reduce((sum, set) => sum + numeric(set.distance), 0);
    const seconds = sets.reduce((sum, set) => sum + numeric(set.minutes) * 60 + numeric(set.seconds), 0);
    const pace = distance > 0 && seconds > 0 ? seconds / distance : 0;
    return {
      value: distance,
      label: `${distance || 0} km${pace ? ` · ${formatPace(pace)}/km` : ""}`,
      volume: distance,
    };
  }
  const distance = sets.map((set) => numeric(set.distance)).sort((a, b) => b - a)[0];
  return { value: distance, label: `${distance || 0} km`, volume: distance };
}

export function summarizeExercise(workoutLogs, exerciseId) {
  const allEntries = Object.values(workoutLogs)
    .filter((log) => log.exercises?.[exerciseId]?.sets?.length)
    .sort((a, b) => a.date.localeCompare(b.date))
    .map((log) => {
      const exercise = log.exercises[exerciseId];
      const metric = bestSetMetric(exercise.measurement, exercise.sets);
      return {
        date: log.date,
        measurement: exercise.measurement,
        ...metric,
      };
    });
  if (!allEntries.length) {
    return { sessions: 0, latest: "—", best: "—", volume: "—", points: [] };
  }
  const latestMeasurement = allEntries.at(-1).measurement;
  const entries = allEntries.filter((entry) => entry.measurement === latestMeasurement);
  const best = [...entries].sort((a, b) => b.value - a.value)[0];
  const totalVolume = entries.reduce((sum, entry) => sum + entry.volume, 0);
  return {
    sessions: allEntries.length,
    latest: entries.at(-1).label,
    best: best.label,
    volume: Number.isInteger(totalVolume) ? totalVolume.toLocaleString() : totalVolume.toFixed(1),
    points: entries.map((entry) => ({ date: entry.date, value: entry.value })),
  };
}

export function formatDuration(totalSeconds) {
  const seconds = Math.max(0, Math.round(numeric(totalSeconds)));
  const minutes = Math.floor(seconds / 60);
  const remainder = seconds % 60;
  return minutes ? `${minutes}:${String(remainder).padStart(2, "0")}` : `${remainder} sec`;
}

export function formatPace(secondsPerKm) {
  const seconds = Math.max(0, Math.round(numeric(secondsPerKm)));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}
