import {
  MEASUREMENT_TYPES, OPTIONAL_RECOVERY_RULE, PULL_UP_STEPS, RUN_QUALITY_PROGRESSION, STRENGTH_PROGRESSION,
  normalizeResponseRating, recoveryReadiness,
} from "./lib.js";

import { progressionAdvice } from "./progression.js";
import { DEFAULT_REVIEW_PROFILE } from "./review-storage.js";
export { DEFAULT_REVIEW_PROFILE } from "./review-storage.js";

export const REVIEW_SCHEMA_VERSION = "1";
export const REVIEW_PROMPT_VERSION = "1";
const DAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"];
const DAY_MS = 86_400_000;
const numeric = (value) => !["number", "string"].includes(typeof value) || (typeof value === "string" && value.trim() === "")
  ? null : Number.isFinite(Number(value)) && Number(value) >= 0 ? Number(value) : null;
const text = (value, limit = 1000) => typeof value === "string" ? value.slice(0, limit) : "";
const inRange = (date, start, end) => typeof date === "string" && date >= start && date <= end;
const dateAdd = (date, days) => new Date(Date.parse(`${date}T00:00:00Z`) + days * DAY_MS).toISOString().slice(0, 10);
const dayKey = (date) => DAYS[(new Date(`${date}T00:00:00Z`).getUTCDay() + 6) % 7];
const dayCount = (start, end) => Math.round((Date.parse(`${end}T00:00:00Z`) - Date.parse(`${start}T00:00:00Z`)) / DAY_MS) + 1;
const mean = (values) => values.length ? values.reduce((sum, value) => sum + value, 0) / values.length : null;
const rounded = (value) => value === null ? null : Math.round(value * 1000) / 1000;
const average = (values, eligible) => ({ average: rounded(mean(values)), count: values.length, eligible });

export function singaporeDate(now = new Date()) {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Asia/Singapore", year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(new Date(now));
  const part = (name) => parts.find((entry) => entry.type === name).value;
  return `${part("year")}-${part("month")}-${part("day")}`;
}

export function reviewPeriod(mode = "completed", now = new Date()) {
  if (!["completed", "current"].includes(mode)) throw new Error("Unknown review period.");
  const today = singaporeDate(now);
  const monday = dateAdd(today, -DAYS.indexOf(dayKey(today)));
  const start = mode === "current" ? monday : dateAdd(monday, -7);
  return {
    start, end: mode === "current" ? today : dateAdd(start, 6), comparisonStart: dateAdd(start, -28),
    partial: mode === "current", timezone: "Asia/Singapore",
  };
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  }
  return value;
}
export async function fingerprintReviewPayload(payload) {
  const bytes = new TextEncoder().encode(JSON.stringify(canonical(payload)));
  const digest = await globalThis.crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

const setFields = ["weight", "reps", "assistance", "minutes", "seconds", "distance", "calories", "rir", "rpe", "averageHeartRate", "averageRpm"];
function cleanSet(set, index, measurement) {
  const relevant = new Set((MEASUREMENT_TYPES[measurement]?.fields || []).map((field) => field.key));
  return { index: index + 1, ...Object.fromEntries(setFields.filter((field) => relevant.has(field) || numeric(set[field]) !== null)
    .map((field) => [field, ["rir", "rpe"].includes(field) && numeric(set[field]) > 10 ? null : numeric(set[field])])) };
}
function unitsFor(exercise) {
  const units = Object.fromEntries((MEASUREMENT_TYPES[exercise.measurement]?.fields || [])
    .map((field) => [field.key, field.unit || "count"]));
  if (["duration", "duration_calories", "distance", "distance_time"].includes(exercise.measurement)) {
    Object.assign(units, { minutes: "min", seconds: "sec", distance: "km", calories: "kcal", averageHeartRate: "bpm", averageRpm: "rpm" });
  }
  // Imported records can explicitly identify a different unit; never pool those with the app's kg records.
  if (exercise.units && typeof exercise.units === "object") {
    for (const key of Object.keys(units)) if (typeof exercise.units[key] === "string") units[key] = text(exercise.units[key], 20);
  }
  return units;
}
function cleanTarget(target) {
  if (!target || !["strength", "pullup", "run"].includes(target.kind)) return null;
  return {
    kind: target.kind,
    ...Object.fromEntries(["sets", "minReps", "maxReps", "minRir", "distance", "stage", "totalStages"]
      .map((field) => [field, numeric(target[field])])),
  };
}
function cleanExercise(id, exercise, definitions, source = "planned", advice = null) {
  if (!exercise || !Array.isArray(exercise.sets) || !MEASUREMENT_TYPES[exercise.measurement]) return null;
  const sets = exercise.sets.flatMap((set, index) => set?.completed === true ? [cleanSet(set, index, exercise.measurement)] : []);
  if (!sets.length) return null;
  const definition = definitions.get(id);
  const name = text(exercise.name || exercise.variantName || id, 160);
  const variantId = text(exercise.variantId, 96);
  const equipment = text(exercise.equipment, 120) || null;
  const units = unitsFor(exercise);
  const progressionStep = numeric(exercise.progressionStep);
  return {
    id: text(id, 120), name, variantId, equipment, units, measurement: exercise.measurement,
    category: source === "extra" ? "Cardio" : text(exercise.category || definition?.category, 40),
    progressionStep, progressionStage: numeric(exercise.progressionStage), target: cleanTarget(exercise.coachingPlan),
    sets, savedSetSlots: exercise.sets.length, source,
    coaching: { technique: text(exercise.coaching?.technique, 30), reserve: numeric(exercise.coaching?.reserve),
      conversational: text(exercise.coaching?.conversational, 30), readySingle: text(exercise.coaching?.readySingle, 30) },
    progressionConstraint: advice ? { action: text(advice.action, 40), title: text(advice.title, 200), detail: text(advice.detail, 1000) } : null,
  };
}
function cleanResponse(response, workoutDate, today) {
  response = response && typeof response === "object" ? response : {};
  const pain = (field) => {
    const value = numeric(response[field]) === null ? "" : normalizeResponseRating(response[field], response.scaleVersion);
    return value === "" ? null : value;
  };
  return {
    painDuring: pain("painDuring"), painLater: pain("painLater"), painNext: pain("painNext"),
    readiness: workoutDate >= today || (response.readinessCheckedOn && response.readinessCheckedOn <= workoutDate)
      ? "unknown" : recoveryReadiness({ ...response, painNext: numeric(response.painNext) }), readinessCheckedOn: text(response.readinessCheckedOn, 10) || null,
    notes: text(response.notes),
  };
}
function planSnapshot(state, plan) {
  const snapshot = DAYS.filter((day) => plan.days?.[day]).map((day) => ({
    day, exercises: (plan.days[day].exercises || []).map((exercise) => ({
      id: text(exercise.id, 120), name: text(exercise.name, 160), measurement: text(exercise.measurement, 40),
      sets: numeric(exercise.sets), prescription: text(exercise.prescription, 600),
      category: text(exercise.category, 40), optional: Boolean(exercise.optional),
    })),
  }));
  const ids = new Set(snapshot.flatMap((day) => day.exercises.map((exercise) => exercise.id)));
  const prefix = plan.id === "form-flow" ? "" : `${plan.id}::`;
  const exerciseConfigs = [...ids].sort().flatMap((exerciseId) => {
    const value = state.exerciseConfigs?.[`${prefix}${exerciseId}`];
    return typeof value === "string" ? [{ exerciseId, measurement: value }] : [];
  });
  const builtin = plan.id === "form-flow";
  // builtInPlanRevision is a storage migration marker, not a historical content version.
  const version = plan.version ?? plan.revision ?? null;
  return {
    id: text(plan.id, 64), name: text(plan.name, 160), version: version === null || version === undefined ? null : String(version),
    snapshot, exerciseConfigs,
    longRuns: (plan.longRuns || []).map((entry) => text(typeof entry === "string" ? entry : JSON.stringify(entry), 600)),
    longRunDay: text(plan.longRunDay, 20),
    nextSessionTargets: [...ids].sort().flatMap((exerciseId) => {
      const target = state.settings?.nextSessionTargets?.[`${plan.id}:${exerciseId}`];
      return target ? [{ exerciseId, sourceDate: text(target.sourceDate, 10), measurement: text(target.measurement, 40),
        variantId: text(target.variantId, 96), progressionStep: numeric(target.progressionStep), action: text(target.action, 40),
        field: text(target.field, 40), value: numeric(target.value), reps: numeric(target.reps) }] : [];
    }),
    settings: {
      block: builtin ? numeric(state.settings?.block) : null,
      longRunWeek: builtin ? numeric(state.settings?.longRunWeek) : null,
      pullupStep: builtin ? numeric(state.settings?.pullupStep) : null,
    },
    rules: [
      "기존 증량 및 회복 조건을 우회하지 않는다. 여러 주요 운동 부하를 동시에 올리지 않는다. 명확한 이유가 없으면 현재 계획을 유지한다.",
      "제안 적용 표시는 사용자의 결정 기록이며 운동 처방을 자동 변경하지 않는다.",
      ...(builtin ? [STRENGTH_PROGRESSION.effort, STRENGTH_PROGRESSION.load, OPTIONAL_RECOVERY_RULE.copy, RUN_QUALITY_PROGRESSION.progression,
        "Long runs advance only after the recorded stage target at easy conversational effort and normal next-morning recovery; repeat or step back otherwise. Block 2 requires two qualified 10 km runs, RPE ≤4 and stable following-morning recovery. Existing explicit acceptance is still required.",
        ...PULL_UP_STEPS.map((step) => `${step.label}: ${step.prescription}. ${step.target} ${step.next}`)] :
        ["선택한 사용자 정의 계획에는 앱의 자동 증량 안내가 적용되지 않는다. 현재 스냅샷은 과거 처방을 입증하지 않는다."]),
    ],
  };
}
function uniqueDated(records, dateField, start, end, project) {
  const entries = new Map();
  for (const record of records || []) {
    if (!record || !inRange(record[dateField], start, end)) continue;
    const clean = project(record);
    if (clean) entries.set(record[dateField], clean);
  }
  return [...entries.values()].sort((a, b) => (a.date || a.week).localeCompare(b.date || b.week));
}
function previousRecommendations(state, planId, start) {
  const latest = new Map();
  for (const review of [...(state.aiReviews || [])].sort((a, b) => String(a.createdAt).localeCompare(String(b.createdAt)))) {
    if (review.planId !== planId || !review.period?.start || review.period.start >= start) continue;
    latest.set(review.period.start, review);
  }
  return [...latest.values()].sort((a, b) => b.period.start.localeCompare(a.period.start)).slice(0, 4).reverse()
    .flatMap((review) => (review.result?.recommendations || []).slice(0, 3).map((recommendation) => ({
      id: `${review.id}:${recommendation.id}`, originalId: text(recommendation.id, 120), reviewId: text(review.id, 120),
      status: ["applied", "not_yet", "skipped"].includes(review.decisions?.[recommendation.id])
        ? review.decisions[recommendation.id] : "not_yet",
      title: `${review.meta?.mode === "mock" ? "[모의 응답] " : ""}${text(recommendation.title, 280)}`, adjustment: text(recommendation.adjustment, 1000), periodStart: review.period.start,
    })));
}
function bodySummary(records, field) {
  const values = records.filter((entry) => entry[field] !== null);
  return {
    first: values[0]?.[field] ?? null, last: values.at(-1)?.[field] ?? null,
    change: values.length >= 2 ? rounded(values.at(-1)[field] - values[0][field]) : null,
    average: rounded(mean(values.map((entry) => entry[field]))), count: values.length, unit: field === "weight" ? "kg" : "cm",
  };
}
function summarizeRange(workouts, savedRecords, sleepRecords, bodyRecords, start, end) {
  const logs = workouts.filter((workout) => inRange(workout.date, start, end));
  const exercises = logs.flatMap((workout) => workout.exercises);
  const sets = exercises.flatMap((exercise) => exercise.sets);
  const saved = savedRecords.filter((record) => inRange(record.date, start, end));
  const days = new Set(logs.map((log) => log.date));
  const calendarDays = dayCount(start, end);
  const savedSetSlots = saved.reduce((sum, log) => sum + [...Object.values(log.exercises || {}), ...(log.extraActivities || [])]
    .reduce((count, exercise) => count + (exercise?.sets?.length || 0), 0), 0);
  const rirSets = exercises.filter((exercise) => MEASUREMENT_TYPES[exercise.measurement]?.fields.some((field) => field.key === "rir"))
    .flatMap((exercise) => exercise.sets);
  const rpeSets = exercises.filter((exercise) => MEASUREMENT_TYPES[exercise.measurement]?.fields.some((field) => field.key === "rpe"))
    .flatMap((exercise) => exercise.sets);
  const cardio = exercises.filter((exercise) => exercise.category === "Cardio" || ["distance", "distance_time", "duration_calories"].includes(exercise.measurement));
  const cardioSets = cardio.flatMap((exercise) => exercise.sets);
  const durations = cardio.flatMap((exercise) => exercise.sets.filter((set) =>
    (set.minutes != null || set.seconds != null) && (set.minutes == null || exercise.units.minutes === "min") &&
    (set.seconds == null || exercise.units.seconds === "sec")).map((set) => (set.minutes ?? 0) * 60 + (set.seconds ?? 0)));
  const sleeps = sleepRecords.filter((entry) => inRange(entry.date, start, end));
  const bodies = bodyRecords.filter((entry) => inRange(entry.date, start, end));
  // Saved targets still count when none of that exercise's sets were completed.
  // Only actual saved coaching targets are eligible; today's plan supplies no historical denominator.
  const targets = saved.flatMap((log) => [...Object.values(log.exercises || {}), ...(log.extraActivities || [])])
    .flatMap((exercise) => {
      const target = cleanTarget(exercise?.coachingPlan);
      return target?.sets !== null && target?.sets !== undefined && Array.isArray(exercise.sets)
        ? [{ target, completedSets: exercise.sets.filter((set) => set?.completed === true).length }] : [];
    });
  const recovery = { yes: 0, no: 0, unknown: 0, total: logs.length };
  logs.forEach((log) => recovery[log.response.readiness]++);
  return {
    start, end, calendarDays, recordedWorkouts: logs.length, completedWorkoutDays: days.size,
    daysWithoutCompletedRecords: calendarDays - days.size,
    savedWorkoutsWithoutCompletedSets: saved.length - logs.length,
    completedSets: sets.length, savedSetSlots,
    recordedSetCompletionRatio: savedSetSlots ? rounded(sets.length / savedSetSlots) : null,
    historicalTargetSets: targets.reduce((sum, exercise) => sum + exercise.target.sets, 0),
    historicalTargetCompletedSets: targets.reduce((sum, exercise) => sum + Math.min(exercise.completedSets, exercise.target.sets), 0),
    historicalTargetExerciseCount: targets.length,
    rir: average(rirSets.flatMap((set) => set.rir == null ? [] : [set.rir]), rirSets.length),
    rpe: average(rpeSets.flatMap((set) => set.rpe == null ? [] : [set.rpe]), rpeSets.length),
    cardio: { recordedSeconds: durations.length ? rounded(durations.reduce((sum, value) => sum + value, 0)) : null,
      durationSets: durations.length, totalSets: cardioSets.length },
    sleep: average(sleeps.map((entry) => entry.hours), calendarDays), recovery,
    body: { weight: bodySummary(bodies, "weight"), waist: bodySummary(bodies, "waist") },
  };
}
function exerciseIdentity(exercise) {
  return JSON.stringify([exercise.id, exercise.name, exercise.variantId, exercise.equipment,
    exercise.measurement, canonical(exercise.units), exercise.progressionStep, exercise.source]);
}
function constraintFor(log, id, savedRecords, definitions, today) {
  const current = cleanExercise(id, log.exercises[id], definitions);
  if (!current?.target) return null;
  const prior = savedRecords.filter((entry) => entry && entry.date < log.date &&
    (entry.planId || "form-flow") === (log.planId || "form-flow") && entry.exercises?.[id])
    .sort((a, b) => b.date.localeCompare(a.date))[0];
  const previous = prior && cleanExercise(id, prior.exercises[id], definitions);
  const safeLog = (entry) => ({ ...entry, response: {
    ...(entry.response && typeof entry.response === "object" ? entry.response : {}),
    readiness: cleanResponse(entry.response, entry.date, today).readiness,
  } });
  // Preserve the immediately preceding session requirement: an unmatched latest session breaks the pair.
  const history = previous && exerciseIdentity(previous) === exerciseIdentity(current) ? { prior: safeLog(prior) } : {};
  return progressionAdvice(safeLog(log), id, history, today);
}
function exerciseTrends(workouts, start) {
  const groups = new Map();
  workouts.forEach((workout) => workout.exercises.forEach((exercise) => {
    const identity = exerciseIdentity(exercise);
    if (!groups.has(identity)) groups.set(identity, { exercise, current: [], baseline: [] });
    groups.get(identity)[workout.date >= start ? "current" : "baseline"].push({ date: workout.date, ...exercise });
  }));
  return [...groups.values()].filter((group) => group.current.length).map(({ exercise, current, baseline }) => {
    const loadField = exercise.measurement === "assisted_reps" ? "assistance" : "weight";
    const summarize = (entries) => {
      const sets = entries.flatMap((entry) => entry.sets);
      return {
        sessions: entries.length, sets: sets.length,
        load: average(sets.flatMap((set) => set[loadField] == null ? [] : [set[loadField]]), sets.length),
        reps: average(sets.flatMap((set) => set.reps == null ? [] : [set.reps]), sets.length),
      };
    };
    const matched = (matchField, valueField) => {
      const currentSets = current.flatMap((entry) => entry.sets).filter((set) => set[matchField] != null && set[valueField] != null);
      const baselineSets = baseline.flatMap((entry) => entry.sets).filter((set) => set[matchField] != null && set[valueField] != null);
      return [...new Set(currentSets.map((set) => set[matchField]))].sort((a, b) => a - b).flatMap((matchValue) => {
        const now = currentSets.filter((set) => set[matchField] === matchValue).map((set) => set[valueField]);
        const before = baselineSets.filter((set) => set[matchField] === matchValue).map((set) => set[valueField]);
        if (!before.length) return [];
        const delta = rounded(mean(now) - mean(before));
        return [{ matchValue, current: rounded(mean(now)), baseline: rounded(mean(before)), delta,
          currentCount: now.length, baselineCount: before.length,
          interpretation: valueField === "assistance" ? delta > 0 ? "more_assistance_easier" : delta < 0 ? "less_assistance_harder" : "unchanged"
            : "observed_change_not_proof_of_performance" }];
      });
    };
    return {
      identity: exerciseIdentity(exercise), exerciseId: exercise.id, name: exercise.name, variantId: exercise.variantId,
      equipment: exercise.equipment, measurement: exercise.measurement, units: exercise.units,
      current: summarize(current), baseline: summarize(baseline), loadField,
      loadAtMatchedReps: matched("reps", loadField), repsAtMatchedLoad: matched(loadField, "reps"),
      limitation: exercise.equipment === null ? "장비 정보가 기록되지 않아 동일 기구 사용은 확인할 수 없음. 같은 운동명·변형·단위의 관측값만 비교함."
        : "동일 운동명·장비·변형·단위의 관측값 비교이며 인과관계나 근육 증가를 입증하지 않음.",
    };
  });
}

export function buildReviewPayload(state, plan, { mode = "completed", now = new Date() } = {}) {
  const period = reviewPeriod(mode, now);
  const snapshot = planSnapshot(state, plan);
  const definitions = new Map(Object.values(plan.days || {}).flatMap((day) => day.exercises || []).map((exercise) => [exercise.id, exercise]));
  const source = Object.entries(state.workoutLogs || {})
    .filter(([, log]) => log && (log.planId || "form-flow") === plan.id && inRange(log.date, period.comparisonStart, period.end))
    .sort(([a, one], [b, two]) => one.date.localeCompare(two.date) || a.localeCompare(b));
  // The app has one saved workout per plan/date. Duplicated backup keys cannot inflate a review.
  const byDate = new Map(source.map(([, log]) => [log.date, log]));
  const savedRecords = [...byDate.values()];
  const workouts = savedRecords.flatMap((log) => {
    const exercises = [
      ...Object.entries(log.exercises || {}).map(([id, exercise]) => cleanExercise(id, exercise, definitions, "planned",
        plan.id === "form-flow" && cleanTarget(exercise?.coachingPlan) && Array.isArray(exercise.sets)
          ? constraintFor(log, id, savedRecords, definitions, singaporeDate(now)) : null)),
      ...(log.extraActivities || []).map((activity) => cleanExercise(activity.id, activity, definitions, "extra")),
    ].filter(Boolean);
    if (!exercises.length) return [];
    return [{
      id: `session:${log.date}`, date: log.date, dayKey: dayKey(log.date), planId: snapshot.id,
      recordedPlanVersion: log.planVersion === undefined || log.planVersion === null ? null : String(log.planVersion),
      response: cleanResponse(log.response, log.date, singaporeDate(now)), exercises,
    }];
  });
  const sleepRecords = uniqueDated(state.dailySleepLogs, "date", period.comparisonStart, period.end,
    (entry) => numeric(entry.hours) !== null && Number(entry.hours) <= 24 ? { date: entry.date, hours: Number(entry.hours) } : null);
  const bodyRecords = uniqueDated(state.bodyLogs, "date", period.comparisonStart, period.end,
    (entry) => numeric(entry.weight) !== null || numeric(entry.waist) !== null
      ? { date: entry.date, weight: numeric(entry.weight), waist: numeric(entry.waist) } : null);
  const legacyWeeklySleepRecords = uniqueDated(state.sleepLogs, "week", period.comparisonStart, period.end,
    (entry) => numeric(entry.hours) !== null && Number(entry.hours) <= 24 ? { week: entry.week, hours: Number(entry.hours) } : null);
  const current = summarizeRange(workouts, savedRecords, sleepRecords, bodyRecords, period.start, period.end);
  const baseline = summarizeRange(workouts, savedRecords, sleepRecords, bodyRecords, period.comparisonStart, dateAdd(period.start, -1));
  const weeksWithCompletedWorkouts = new Set(workouts.filter((workout) => workout.date < period.start)
    .map((workout) => dateAdd(workout.date, -DAYS.indexOf(dayKey(workout.date))))).size;
  const trends = exerciseTrends(workouts, period.start);
  const previous = previousRecommendations(state, plan.id, period.start);
  const limitations = [
    "현재 선택한 계획 스냅샷만 제공됨. 과거 전체 계획 버전·처방은 확인할 수 없어 과거 운동을 현재 계획으로 평가하지 않음. 저장된 coaching target이 있는 운동만 해당 당시 세트 목표를 사용함.",
    "리뷰의 증량 제약 검토는 선택 기간과 이전 4주의 저장 기록만 사용함. 더 오래된 이력은 이 리뷰에서 자격 확인 근거로 사용하지 않으며 앱의 기존 증량 동작은 변경하지 않음.",
    "기록 없는 날은 운동을 하지 않았다는 뜻이 아님. 저장된 세트의 완료 비율은 계획 준수율이 아님. 초안과 완료 표시 없는 세트는 분석에서 제외함.",
    "일일 수면의 날짜는 체크인 날짜(전날 밤 수면)이며, 기존 주간 수면 평균은 일일 기록과 합산하지 않음. 체중·허리는 전체 사용자 기록이며 특정 계획의 효과로 해석하지 않음.",
    "유산소 시간은 min/sec 단위가 확인된 값만 합산함. RIR/RPE·통증·회복·신체측정 누락은 0 또는 정상으로 추정하지 않음. 장비 미기록 시 동일 기구를 사용했는지 확인할 수 없음.",
    ...(period.partial ? ["이번 주는 진행 중인 부분 주이므로 완료된 한 주의 총량과 직접 비교하지 않음."] : []),
    ...(weeksWithCompletedWorkouts < 4 ? [`이전 4주 중 완료 운동 기록이 있는 주는 ${weeksWithCompletedWorkouts}주뿐임. 비교 이력이 제한됨.`] : []),
    ...(!current.recordedWorkouts ? ["선택한 기간에 완료 표시된 운동 기록이 없어 주간 운동 리뷰에 충분한 자료가 없음."] : []),
  ];
  const metricEvidence = (range, name) => {
    const prefix = `metrics:${name}`;
    const label = `${range.start}–${range.end}`;
    const shown = (value) => value === null ? "미기록" : value;
    return [
      { id: `${prefix}:rir`, label: `${label}: RIR 평균 ${shown(range.rir.average)}, 해당 ${range.rir.eligible}개 완료 세트 중 ${range.rir.count}개 기록` },
      { id: `${prefix}:rpe`, label: `${label}: RPE 평균 ${shown(range.rpe.average)}, 해당 ${range.rpe.eligible}개 완료 세트 중 ${range.rpe.count}개 기록` },
      { id: `${prefix}:cardio`, label: `${label}: 유산소 기록 시간 ${shown(range.cardio.recordedSeconds)}초, ${range.cardio.totalSets}개 완료 유산소 세트 중 시간 ${range.cardio.durationSets}개 기록` },
      { id: `${prefix}:sleep`, label: `${label}: 수면 평균 ${shown(range.sleep.average)}시간, ${range.sleep.count}/${range.sleep.eligible}일 기록` },
      { id: `${prefix}:recovery`, label: `${label}: 다음날 회복 정상 ${range.recovery.yes}, 미회복 ${range.recovery.no}, 미확인 ${range.recovery.unknown} / ${range.recovery.total}회` },
      ...["weight", "waist"].map((field) => ({ id: `${prefix}:${field}`, label: `${label}: ${field === "weight" ? "체중" : "허리"} ${range.body[field].count}회 기록, 처음 ${shown(range.body[field].first)} → 마지막 ${shown(range.body[field].last)} ${range.body[field].unit}, 변화 ${shown(range.body[field].change)}` })),
    ];
  };
  const exerciseEvidenceLabel = (workout, exercise) => {
    const labels = { weight: "중량", assistance: "보조", reps: "반복", rir: "RIR", rpe: "RPE", minutes: "분", seconds: "초",
      distance: "거리", calories: "열량", averageHeartRate: "심박수", averageRpm: "RPM" };
    const relevant = new Set((MEASUREMENT_TYPES[exercise.measurement]?.fields || []).map((field) => field.key));
    const values = setFields.flatMap((field) => {
      const recorded = exercise.sets.flatMap((set) => set[field] == null ? [] : [set[field]]);
      if (!relevant.has(field) && !recorded.length) return [];
      return [`${labels[field]} 평균 ${rounded(mean(recorded)) ?? "미기록"}${exercise.units[field] || ""} (${recorded.length}/${exercise.sets.length}세트)`];
    });
    return `${workout.date} · ${exercise.name} · 완료 ${exercise.sets.length}/${exercise.savedSetSlots}개 저장 세트: ${values.join(", ")}`.slice(0, 1000);
  };
  const evidence = [
    ...metricEvidence(current, "current"), ...metricEvidence(baseline, "baseline"),
    { id: "metrics:current", label: `${period.start}–${period.end}: 완료 기록 ${current.recordedWorkouts}회, ${current.completedSets}세트; 수면 ${current.sleep.count}/${current.calendarDays}일; 회복 확인 ${current.recovery.yes + current.recovery.no}/${current.recovery.total}회` },
    { id: "metrics:baseline", label: `${period.comparisonStart}–${baseline.end}: 완료 기록 ${baseline.recordedWorkouts}회, 비교 가능한 기록 ${weeksWithCompletedWorkouts}/4주` },
    ...workouts.flatMap((workout) => [
      { id: workout.id, label: `${workout.date}: ${workout.exercises.map((exercise) => exercise.name).join(", ")}`.slice(0, 1000) },
      ...workout.exercises.map((exercise, index) => ({ id: `${workout.id}:exercise:${index + 1}`,
        label: exerciseEvidenceLabel(workout, exercise) })),
    ]),
    ...sleepRecords.map((entry) => ({ id: `sleep:${entry.date}`, label: `${entry.date} 체크인: 전날 밤 수면 ${entry.hours}시간` })),
    ...bodyRecords.map((entry) => ({ id: `body:${entry.date}`, label: `${entry.date}: 체중 ${entry.weight ?? "미기록"} kg, 허리 ${entry.waist ?? "미기록"} cm` })),
    ...previous.map((entry) => ({ id: `decision:${entry.id}`, label: `${entry.periodStart} 제안: ${entry.title} · 사용자 결정 ${entry.status}` })),
    ...trends.map((entry, index) => ({ id: `trend:${index + 1}`, label: `${entry.name}: 이번 ${entry.current.sessions}회 / 이전 4주 ${entry.baseline.sessions}회. ${entry.loadField === "assistance" ? "보조량" : "중량"} 평균 ${entry.current.load.average ?? "미기록"} (${entry.current.load.count}세트) / ${entry.baseline.load.average ?? "미기록"} (${entry.baseline.load.count}세트) ${entry.units[entry.loadField] || ""}; 반복 평균 ${entry.current.reps.average ?? "미기록"} / ${entry.baseline.reps.average ?? "미기록"}. 동일 반복수 비교 ${entry.loadAtMatchedReps.slice(0, 3).map((match) => `${match.matchValue}회: ${match.baseline}→${match.current}, ${match.interpretation}`).join("; ") || "없음"}. ${entry.limitation}`.slice(0, 1000) })),
  ];
  return {
    schemaVersion: REVIEW_SCHEMA_VERSION, promptVersion: REVIEW_PROMPT_VERSION, period, plan: snapshot,
    profile: { goals: text(state.aiReviewProfile?.goals ?? DEFAULT_REVIEW_PROFILE.goals, 1000),
      constraints: text(state.aiReviewProfile?.constraints ?? DEFAULT_REVIEW_PROFILE.constraints, 1000), constraintsSource: "user_reported" },
    workouts, metrics: { current, baseline, weeksWithCompletedWorkouts, comparisonWeeks: 4,
      exerciseTrends: trends, sleepRecords, legacyWeeklySleepRecords, bodyRecords },
    evidence, previousRecommendations: previous, limitations,
  };
}

// A small data-only schema shared with the backend; every object rejects unknown fields.
const stringSchema = (maxLength = 1000) => ({ type: "string", maxLength });
const numberSchema = { type: "number", minimum: 0, maximum: 1_000_000_000 };
const nullableNumber = { anyOf: [numberSchema, { type: "null" }] };
const deltaSchema = { anyOf: [{ type: "number", minimum: -1_000_000_000, maximum: 1_000_000_000 }, { type: "null" }] };
const nullableString = (maxLength = 1000) => ({ anyOf: [stringSchema(maxLength), { type: "null" }] });
const enumSchema = (...values) => ({ enum: values });
const objectSchema = (properties, required = Object.keys(properties)) => ({ type: "object", properties, required, additionalProperties: false });
const arraySchema = (items, maxItems) => ({ type: "array", items, maxItems });
const dateSchema = { type: "string", pattern: "^\\d{4}-\\d{2}-\\d{2}$", maxLength: 10 };
const averageSchema = objectSchema({ average: nullableNumber, count: numberSchema, eligible: numberSchema });
const unitsSchema = objectSchema(Object.fromEntries(setFields.map((field) => [field, stringSchema(20)])), []);
const targetSchema = { anyOf: [objectSchema({ kind: enumSchema("strength", "pullup", "run"),
  ...Object.fromEntries(["sets", "minReps", "maxReps", "minRir", "distance", "stage", "totalStages"].map((field) => [field, nullableNumber])) }), { type: "null" }] };
const exerciseSchema = objectSchema({
  id: stringSchema(120), name: stringSchema(160), variantId: stringSchema(96),
  equipment: nullableString(120), units: unitsSchema, measurement: enumSchema(...Object.keys(MEASUREMENT_TYPES)), category: stringSchema(40),
  progressionStep: nullableNumber, progressionStage: nullableNumber, target: targetSchema,
  sets: arraySchema(objectSchema({ index: numberSchema, ...Object.fromEntries(setFields.map((field) => [field, nullableNumber])) }, ["index"]), 100),
  savedSetSlots: numberSchema, source: enumSchema("planned", "extra"),
  coaching: objectSchema({ technique: stringSchema(30), reserve: nullableNumber, conversational: stringSchema(30), readySingle: stringSchema(30) }),
  progressionConstraint: { anyOf: [objectSchema({ action: stringSchema(40), title: stringSchema(200), detail: stringSchema() }), { type: "null" }] },
});
const bodySummarySchema = objectSchema({ first: nullableNumber, last: nullableNumber, change: deltaSchema,
  average: nullableNumber, count: numberSchema, unit: enumSchema("kg", "cm") });
const rangeSchema = objectSchema({
  start: dateSchema, end: dateSchema, calendarDays: numberSchema, recordedWorkouts: numberSchema, completedWorkoutDays: numberSchema,
  daysWithoutCompletedRecords: numberSchema, savedWorkoutsWithoutCompletedSets: numberSchema, completedSets: numberSchema, savedSetSlots: numberSchema,
  recordedSetCompletionRatio: nullableNumber, historicalTargetSets: numberSchema, historicalTargetCompletedSets: numberSchema,
  historicalTargetExerciseCount: numberSchema, rir: averageSchema, rpe: averageSchema,
  cardio: objectSchema({ recordedSeconds: nullableNumber, durationSets: numberSchema, totalSets: numberSchema }), sleep: averageSchema,
  recovery: objectSchema({ yes: numberSchema, no: numberSchema, unknown: numberSchema, total: numberSchema }),
  body: objectSchema({ weight: bodySummarySchema, waist: bodySummarySchema }),
});
const exerciseSummarySchema = objectSchema({ sessions: numberSchema, sets: numberSchema, load: averageSchema, reps: averageSchema });
const matchSchema = objectSchema({ matchValue: numberSchema, current: numberSchema, baseline: numberSchema, delta: deltaSchema,
  currentCount: numberSchema, baselineCount: numberSchema,
  interpretation: enumSchema("more_assistance_easier", "less_assistance_harder", "unchanged", "observed_change_not_proof_of_performance") });
export const REVIEW_PAYLOAD_SCHEMA = objectSchema({
  schemaVersion: enumSchema(REVIEW_SCHEMA_VERSION), promptVersion: enumSchema(REVIEW_PROMPT_VERSION),
  period: objectSchema({ start: dateSchema, end: dateSchema, comparisonStart: dateSchema,
    partial: { type: "boolean" }, timezone: enumSchema("Asia/Singapore") }),
  plan: objectSchema({
    id: stringSchema(64), name: stringSchema(160), version: nullableString(100),
    snapshot: arraySchema(objectSchema({ day: enumSchema(...DAYS), exercises: arraySchema(objectSchema({
      id: stringSchema(120), name: stringSchema(160), measurement: stringSchema(40), sets: nullableNumber,
      prescription: stringSchema(600), category: stringSchema(40), optional: { type: "boolean" },
    }), 100) }), 7),
    exerciseConfigs: arraySchema(objectSchema({ exerciseId: stringSchema(120), measurement: stringSchema(40) }), 200),
    longRuns: arraySchema(stringSchema(600), 100), longRunDay: stringSchema(20),
    nextSessionTargets: arraySchema(objectSchema({ exerciseId: stringSchema(120), sourceDate: stringSchema(10),
      measurement: stringSchema(40), variantId: stringSchema(96), progressionStep: nullableNumber,
      action: stringSchema(40), field: stringSchema(40), value: nullableNumber, reps: nullableNumber }), 200),
    settings: objectSchema({ block: nullableNumber, longRunWeek: nullableNumber, pullupStep: nullableNumber }),
    rules: arraySchema(stringSchema(2000), 20),
  }),
  profile: objectSchema({ goals: stringSchema(), constraints: stringSchema(), constraintsSource: enumSchema("user_reported") }),
  workouts: arraySchema(objectSchema({ id: stringSchema(160), date: dateSchema, dayKey: enumSchema(...DAYS), planId: stringSchema(64),
    recordedPlanVersion: nullableString(100), response: objectSchema({ painDuring: nullableNumber, painLater: nullableNumber,
      painNext: nullableNumber, readiness: enumSchema("yes", "no", "unknown"), readinessCheckedOn: nullableString(10), notes: stringSchema() }),
    exercises: arraySchema(exerciseSchema, 150) }), 35),
  metrics: objectSchema({ current: rangeSchema, baseline: rangeSchema, weeksWithCompletedWorkouts: numberSchema,
    comparisonWeeks: enumSchema(4), exerciseTrends: arraySchema(objectSchema({ identity: stringSchema(1400), exerciseId: stringSchema(120),
      name: stringSchema(160), variantId: stringSchema(96), equipment: nullableString(120), measurement: enumSchema(...Object.keys(MEASUREMENT_TYPES)),
      units: unitsSchema, current: exerciseSummarySchema, baseline: exerciseSummarySchema, loadField: enumSchema("weight", "assistance"),
      loadAtMatchedReps: arraySchema(matchSchema, 100), repsAtMatchedLoad: arraySchema(matchSchema, 100), limitation: stringSchema(),
    }), 200),
    sleepRecords: arraySchema(objectSchema({ date: dateSchema, hours: numberSchema }), 35),
    legacyWeeklySleepRecords: arraySchema(objectSchema({ week: dateSchema, hours: numberSchema }), 5),
    bodyRecords: arraySchema(objectSchema({ date: dateSchema, weight: nullableNumber, waist: nullableNumber }), 35),
  }),
  evidence: arraySchema(objectSchema({ id: stringSchema(400), label: stringSchema() }), 1500),
  previousRecommendations: arraySchema(objectSchema({ id: stringSchema(300), originalId: stringSchema(120), reviewId: stringSchema(120),
    status: enumSchema("applied", "not_yet", "skipped"), title: stringSchema(300), adjustment: stringSchema(), periodStart: dateSchema }), 12),
  limitations: arraySchema(stringSchema(2000), 20),
});

function schemaMatches(value, schema) {
  if (schema.anyOf) return schema.anyOf.some((candidate) => schemaMatches(value, candidate));
  if (schema.enum) return schema.enum.includes(value);
  if (schema.type === "null") return value === null;
  if (schema.type === "string") return typeof value === "string" && value.length <= schema.maxLength && (!schema.pattern || new RegExp(schema.pattern).test(value));
  if (schema.type === "number") return typeof value === "number" && Number.isFinite(value) && value >= schema.minimum && value <= schema.maximum;
  if (schema.type === "boolean") return typeof value === "boolean";
  if (schema.type === "array") return Array.isArray(value) && value.length <= schema.maxItems && value.every((item) => schemaMatches(item, schema.items));
  if (schema.type === "object") return value !== null && typeof value === "object" && !Array.isArray(value) &&
    schema.required.every((key) => Object.hasOwn(value, key)) && Object.keys(value).every((key) =>
      Object.hasOwn(schema.properties, key) && schemaMatches(value[key], schema.properties[key]));
  return false;
}
export function validateReviewPayload(payload) {
  if (!schemaMatches(payload, REVIEW_PAYLOAD_SCHEMA)) throw new Error("Invalid review payload shape.");
  const { period, workouts, evidence, previousRecommendations: previous, metrics } = payload;
  const validDate = (date) => /^\d{4}-\d{2}-\d{2}$/.test(date) && !Number.isNaN(Date.parse(`${date}T00:00:00Z`)) && dateAdd(date, 0) === date;
  if (![period.start, period.end, period.comparisonStart].every(validDate) || dayKey(period.start) !== "monday" ||
    period.comparisonStart !== dateAdd(period.start, -28) || period.end < period.start || period.end > dateAdd(period.start, 6) ||
    (!period.partial && period.end !== dateAdd(period.start, 6))) throw new Error("Invalid review period.");
  if (new Set(evidence.map((item) => item.id)).size !== evidence.length || evidence.some((item) => !item.id || !item.label) ||
    new Set(previous.map((item) => item.id)).size !== previous.length) throw new Error("Duplicate or missing review references.");
  if (new Set(workouts.map((item) => item.date)).size !== workouts.length || workouts.some((workout) =>
    !validDate(workout.date) || !inRange(workout.date, period.comparisonStart, period.end) || workout.planId !== payload.plan.id ||
    workout.dayKey !== dayKey(workout.date) || !workout.exercises.length || workout.exercises.some((exercise) => !exercise.sets.length)) ||
    previous.some((item) => !validDate(item.periodStart) || item.periodStart >= period.start) ||
    metrics.current.start !== period.start || metrics.current.end !== period.end || metrics.baseline.start !== period.comparisonStart ||
    metrics.baseline.end !== dateAdd(period.start, -1)) throw new Error("Inconsistent review records.");
  return payload;
}
