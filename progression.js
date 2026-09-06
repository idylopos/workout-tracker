import { normalizeResponseRating, recoveryReadiness } from "./lib.js";

const number = (value) => value !== "" && value !== null && value !== undefined && Number.isFinite(Number(value))
  ? Number(value) : null;

export function recordedReserve(exercise) {
  const sets = (exercise?.sets || []).filter((set) => set.completed);
  if (!sets.length || sets.some((set) => number(set.rir) === null)) return null;
  return Math.min(...sets.map((set) => Number(set.rir)));
}

function effort(exercise) {
  const known = (exercise.sets || []).filter((set) => set.completed)
    .map((set) => number(set.rir)).filter((value) => value !== null);
  const logged = recordedReserve(exercise);
  const answer = number(exercise.coaching?.reserve);
  return logged ?? (answer === null ? null : Math.min(answer, ...known));
}

function performance(exercise) {
  const plan = exercise.coachingPlan;
  const sets = (exercise.sets || []).filter((set) => set.completed);
  if (!plan || !sets.length) return { qualified: false, reason: "Log the working sets first." };
  const answers = exercise.coaching || {};
  if (answers.technique !== "yes") return { qualified: false, reason: "Confirm clean technique before progressing." };
  const reserve = effort(exercise);
  if (reserve === null) return { qualified: false, reason: "Add your reps in reserve, or choose Not sure and repeat." };
  if (reserve < plan.minRir) return { qualified: false, reason: `Leave at least ${plan.minRir} reps in reserve before progressing.` };
  const reps = (set, min) => number(set.reps) !== null && Number(set.reps) >= min;
  const unassisted = (set) => exercise.measurement === "reps" || number(set.assistance) === 0;
  let complete = sets.length === plan.sets;
  if (plan.kind === "pullup" && exercise.progressionStep === 4) {
    complete = sets.length === 5 && sets.slice(0, 3).every((set) => reps(set, 1) && unassisted(set)) &&
      sets.slice(3).every((set) => reps(set, 5) && number(set.assistance) > 0);
  } else if (plan.kind === "pullup" && exercise.progressionStep === 6) {
    complete = sets.length === 3 && reps(sets[0], 5) && sets.every((set) => reps(set, 3) && unassisted(set));
  } else {
    complete = complete && sets.every((set) => reps(set, plan.maxReps));
    if (plan.kind === "pullup" && exercise.progressionStep === 5) complete = complete && sets.every(unassisted);
  }
  if (plan.kind === "strength") complete = complete && sets.every((set) => number(set.weight) !== null);
  if (plan.kind === "pullup" && exercise.progressionStep <= 3) {
    complete = complete && sets.every((set) => number(set.assistance) !== null);
  }
  return { qualified: complete, reason: complete ? "Target met with clean technique and enough reserve." :
    `Build toward ${plan.sets} sets at the target with clean technique; keep the current difficulty.` };
}

export function guidedPerformanceQualified(exercise) {
  return performance(exercise).qualified;
}

export function isGuidedSessionQualified(log, exerciseId, today) {
  const exercise = log?.exercises?.[exerciseId];
  return Boolean(log?.date < today && exercise && recoveryReadiness(log.response) === "yes" &&
    !["painDuring", "painLater"].some((key) => normalizeResponseRating(log.response?.[key], log.response?.scaleVersion) > 1) &&
    performance(exercise).qualified);
}

function matchingDose(a, b) {
  if (a.measurement !== b.measurement || a.variantId !== b.variantId ||
    a.progressionStep !== b.progressionStep || a.coachingPlan?.sets !== b.coachingPlan?.sets ||
    a.coachingPlan?.maxReps !== b.coachingPlan?.maxReps) return false;
  const field = a.coachingPlan.kind === "pullup" ? "assistance" : "weight";
  const values = (exercise) => exercise.sets.filter((set) => set.completed).map((set) => number(set[field]));
  return JSON.stringify(values(a)) === JSON.stringify(values(b));
}

export function progressionAdvice(log, exerciseId, history, today) {
  const exercise = log?.exercises?.[exerciseId];
  const plan = exercise?.coachingPlan;
  const result = (action, title, detail, extra = {}) => ({ action, title, detail, ...extra });
  if (!plan) return result("pending", "Keep your current plan", "No progression target is available for this exercise.");
  const readiness = log.date < today ? recoveryReadiness(log.response) : "unknown";
  const symptoms = ["painDuring", "painLater", ...(log.date < today ? ["painNext"] : [])]
    .map((key) => normalizeResponseRating(log.response?.[key], log.response?.scaleVersion));
  if (symptoms.some((value) => value !== "" && value >= 3)) {
    return result("pending", "Pause the provoking exercise", "Stop for sharp or limiting symptoms; seek assessment for persistent worsening or red flags. No increase is suggested.");
  }
  const answer = exercise.coaching || {};
  const sets = (exercise.sets || []).filter((set) => set.completed);
  if (!sets.length) return result("pending", "Log your result first", "Only completed sets count toward progression.");
  const isRun = plan.kind === "run";
  if (readiness === "no" || symptoms.some((value) => value !== "" && value > 1) ||
    ["difficult", "no"].includes(answer.technique) || (!isRun && effort(exercise) !== null && effort(exercise) < plan.minRir)) {
    return result("reduce", isRun ? "Make the next run easier" : "Reduce the difficulty",
      isRun ? "Run easily, shorten the distance or use walk breaks. Wait for your usual recovery before progressing." :
        "Use less load or more pull-up assistance, and stop with the prescribed reps in reserve.");
  }
  if (isRun) {
    const rpes = sets.map((set) => number(set.rpe));
    const conversational = answer.conversational === "yes" || (rpes.every((rpe) => rpe !== null && rpe <= 4));
    if (answer.conversational === "no" || rpes.some((rpe) => rpe !== null && rpe > 4)) {
      return result("repeat", "Repeat at an easier pace", "Keep it conversational; walk breaks are fine. Do not extend the distance yet.");
    }
    if (!conversational || readiness === "unknown") {
      return result("pending", "Keep the current run target", !conversational ?
        "Confirm whether the run was conversational. Missing effort does not qualify for an increase." :
        "We’ll check recovery when you return. No distance increase yet.");
    }
    const distance = Math.max(...sets.map((set) => number(set.distance) || 0));
    if (plan.stage && distance + 0.05 >= plan.distance && plan.stage < plan.totalStages) {
      return result("stage", "Ready for the next long-run stage", "The distance was completed at easy effort and recovery is back to normal.", { nextStage: plan.stage + 1 });
    }
    return result("repeat", "Keep the current run target", plan.stage ? "Repeat until the planned distance is comfortable." :
      "Keep this run easy. Progress the long run separately, one lower-body stressor at a time.");
  }
  if (answer.technique !== "yes" || effort(exercise) === null) {
    return result("pending", "Keep your current plan", performance(exercise).reason);
  }
  if (readiness === "unknown") return result("pending", "Recovery check pending", "Your answers are saved. We’ll suggest the next step after your recovery check.");
  const current = performance(exercise);
  if (!current.qualified) return result("repeat", "Keep the same difficulty", current.reason);
  const earlier = Object.values(history || {}).filter((candidate) => candidate.date < log.date &&
    (candidate.planId || "form-flow") === (log.planId || "form-flow") && candidate.exercises?.[exerciseId]);
  const prior = earlier.sort((a, b) => b.date.localeCompare(a.date))[0];
  const count = 1 + Number(Boolean(prior && matchingDose(exercise, prior.exercises[exerciseId]) && isGuidedSessionQualified(prior, exerciseId, today)));
  if (count < 2) return result("repeat", "One qualifying session — repeat once more", "Meet the same target at the same difficulty, with clean technique and normal recovery, before increasing.");
  if (plan.kind === "pullup") {
    const step = Number(exercise.progressionStep);
    if (step === 3 && answer.readySingle !== "yes") return result("repeat", "Keep building with assistance", "Before singles, confirm low practical assistance and a clean unassisted rep with another in reserve.");
    if (step === 6) return result("repeat", "Five clean reps achieved", "Keep this step and gradually build total clean repetitions.");
    return result("step", `Ready for pull-up Step ${step + 1}`, "Two sessions met the target with reserve and stable recovery. Accept to change future sessions.", { nextStep: step + 1 });
  }
  return result("increase", "Add the smallest available load", "Two sessions met every set’s top rep target with enough reserve and normal recovery. Restart near the lower end of the rep range.");
}

export function nextSessionTarget(log, exerciseId, advice, enteredLoad = "") {
  const exercise = log.exercises[exerciseId];
  const field = exercise.coachingPlan.kind === "pullup" ? "assistance" : "weight";
  const values = exercise.sets.filter((set) => set.completed).map((set) =>
    field === "assistance" && exercise.measurement === "reps" ? 0 : number(set[field]));
  const load = number(enteredLoad);
  if ((["increase", "reduce"].includes(advice.action) || advice.nextStep === 3) && exercise.coachingPlan.kind !== "run") {
    if (load === null || load < 0 || values.some((value) => value === null)) return null;
    if (advice.action === "increase" && load <= Math.max(...values)) return null;
    if (advice.nextStep === 3 && load >= Math.min(...values)) return null;
    if (advice.action === "reduce" && (field === "assistance" ? load <= Math.max(...values) : load >= Math.min(...values))) return null;
  }
  if (advice.action === "pending") return null;
  return {
    sourceDate: log.date, measurement: field === "assistance" && load !== null ? "assisted_reps" : exercise.measurement, variantId: exercise.variantId || "",
    progressionStep: advice.nextStep || exercise.progressionStep || null, action: advice.action, title: advice.title,
    detail: advice.detail, ...(load !== null ? { field, value: load } : advice.nextStep === 2 && values.every((value) => value !== null)
      ? { field, value: Math.max(...values) } : {}),
    ...(advice.action === "increase" ? { reps: exercise.coachingPlan.minReps } : {}),
  };
}
