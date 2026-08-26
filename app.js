import {
  APP_VERSION,
  EXERCISE_ALTERNATIVES,
  EXERCISE_GUIDANCE,
  EXTRA_ACTIVITY_MEASUREMENTS,
  EXTRA_ACTIVITY_TYPES,
  LONG_RUN_PHASES,
  LONG_RUNS,
  MEASUREMENT_TYPES,
  OPTIONAL_RECOVERY_RULE,
  PULL_UP_STEPS,
  RESPONSE_SCALE,
  RUN_QUALITY_PROGRESSION,
  STRENGTH_PROGRESSION,
  STORAGE_KEY,
  WEEK_PLAN,
  addDays,
  createDefaultState,
  countQualifiedLongRuns,
  dateToDayKey,
  evaluateLongRunProgress,
  findPreviousExerciseLog,
  findPreviousSession,
  findOutstandingRecoveryLogs,
  formatDuration,
  getAllExercises,
  normalizeResponseRating,
  normalizeState,
  preparePreviousSets,
  shouldCollapseExerciseByDefault,
  shouldShowRestTimer,
  startOfWeek,
  summarizeCardioRange,
  summarizeExercise,
  summarizeWeeklySleep,
  toIsoDate,
  validateBackup,
} from "./lib.js";
import {
  PBKDF2_ITERATIONS,
  VAULT_STORAGE_KEY,
  createVault,
  encryptState,
  unlockVault,
  unlockVaultWithKey,
} from "./crypto-vault.js";
import {
  UNLOCK_SESSION_DURATION_MS,
  clearRememberedUnlock,
  loadRememberedUnlock,
  saveRememberedUnlock,
} from "./unlock-session.js";

const DAY_KEYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"];
const UNLOCK_BLOCK_STORAGE_KEY = "formflow.unlock-blocked.v1";
const ACTIVITY_TYPE_LABELS = {
  walking: "Walking",
  cycling: "Cycling",
  elliptical: "Elliptical",
  swimming: "Swimming",
  running: "Running",
  custom: "Custom",
};
const numberFormatter = new Intl.NumberFormat(undefined, { maximumFractionDigits: 1 });
const RUNNING_PHASES = {
  1: {
    number: "BLOCK 1",
    title: "Build to a comfortable 10 km",
    copy: "Stay here until two 10 km runs are completed at RPE 4 or below with a Comfortable or Mild following-morning response.",
    points: [
      ["Tuesday", "30 min easy · RPE 2–4"],
      ["Thursday", "25–35 min easy · lift first"],
      ["Saturday", "Follow the 18-stage long-run progression"],
    ],
  },
  2: {
    number: "BLOCK 2",
    title: "Improve your comfortable 10 km",
    copy: "Start after two qualified 10 km runs. Keep most running easy and alternate completed Thursday quality sessions.",
    points: [
      ["Tuesday", "30–40 min easy + 4 × 20-sec strides"],
      ["Thursday", "Start Tempo 3 × 6 min / Intervals 6 × 2 min · progress after 2 stable exposures"],
      ["Saturday", "8–10 km easy"],
    ],
  },
};
const BUILT_IN_PLAN = {
  id: "form-flow",
  name: "Form / Flow weekly plan",
  description: "Concurrent strength, running, cycling, swimming, and mobility.",
  days: WEEK_PLAN,
  longRuns: LONG_RUNS,
  longRunDay: "saturday",
};
let state = createDefaultState();
let selectedDate = toIsoDate();
let draftSession = null;
let activeView = "today";
let resizeFrame = null;
let activePlan = BUILT_IN_PLAN;
let planCatalog = [];
let vaultKey = null;
let vaultSalt = null;
let vaultIterations = PBKDF2_ITERATIONS;
let saveQueue = Promise.resolve();
let workoutDirty = false;
let draftSaveTimer = null;
let draftRevision = 0;
let longRunPreviewStage = null;
let longRunViewedPhase = null;
let unlockExpiresAt = null;
let unlockExpiryTimer = null;
let dailyCheckInAutoShown = false;
let dailyCheckInQueue = [];
let dailyCheckInIndex = 0;
let dailyCheckInAnswers = { sleep: null, recoveries: [] };

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const escapeHtml = (value) =>
  String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");

const els = {
  trainingDate: $("#training-date"),
  hero: $("#session-hero"),
  sessionDay: $("#session-day"),
  sessionEstimate: $("#session-estimate"),
  sessionFocus: $("#session-focus"),
  sessionNote: $("#session-note"),
  todayKicker: $("#today-kicker"),
  progressRing: $("#session-progress-ring"),
  progressValue: $("#session-progress-value"),
  warmupList: $("#warmup-list"),
  warmupCount: $("#warmup-count"),
  exerciseList: $("#exercise-list"),
  extraActivitySection: $("#extra-activity-section"),
  extraActivityList: $("#extra-activity-list"),
  loadSession: $("#load-session-button"),
  longRunCallout: $("#long-run-callout"),
  phaseGuide: $("#phase-guide"),
  sessionNotes: $("#session-notes"),
  saveBar: $(".save-bar"),
  saveStatus: $("#save-status"),
  vaultSessionStatus: $("#vault-session-status"),
  toast: $("#toast"),
};

function persistState() {
  if (!vaultKey || !vaultSalt) return Promise.resolve(false);
  const snapshot = structuredClone(state);
  saveQueue = saveQueue
    .catch(() => undefined)
    .then(async () => {
      const vault = await encryptState(snapshot, vaultKey, vaultSalt, vaultIterations);
      localStorage.setItem(VAULT_STORAGE_KEY, JSON.stringify(vault));
      localStorage.removeItem(STORAGE_KEY);
      return true;
    })
    .catch(() => {
      showToast("Could not save the encrypted vault. Export a backup and check browser storage.", "error");
      return false;
    });
  return saveQueue;
}

function setSaveStatus(message, status = "default") {
  els.saveStatus.textContent = message;
  els.saveBar.dataset.status = status;
}

function showToast(message, tone = "success") {
  els.toast.textContent = message;
  els.toast.dataset.tone = tone;
  els.toast.classList.add("is-visible");
  clearTimeout(showToast.timeout);
  showToast.timeout = setTimeout(() => els.toast.classList.remove("is-visible"), 3200);
}

function legacyState() {
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    return stored ? normalizeState(JSON.parse(stored)) : createDefaultState();
  } catch {
    return createDefaultState();
  }
}

function updateVaultSessionStatus() {
  if (!els.vaultSessionStatus) return;
  if (!unlockExpiresAt) {
    els.vaultSessionStatus.textContent = "Unlocked for this page";
    return;
  }
  const time = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" }).format(
    new Date(unlockExpiresAt),
  );
  els.vaultSessionStatus.textContent = `Unlocked until ${time}`;
}

function scheduleUnlockExpiry(expiresAt = null) {
  clearTimeout(unlockExpiryTimer);
  unlockExpiryTimer = null;
  unlockExpiresAt = Number(expiresAt) > Date.now() ? Number(expiresAt) : null;
  updateVaultSessionStatus();
  if (!unlockExpiresAt) return;
  unlockExpiryTimer = setTimeout(() => {
    void lockApp();
  }, Math.max(0, unlockExpiresAt - Date.now()));
}

async function configureRememberedUnlock(result, remember) {
  localStorage.removeItem(UNLOCK_BLOCK_STORAGE_KEY);
  if (!remember) {
    await clearRememberedUnlock();
    scheduleUnlockExpiry();
    return;
  }
  const expiresAt = await saveRememberedUnlock(
    result.key,
    result.vault,
    UNLOCK_SESSION_DURATION_MS,
  );
  scheduleUnlockExpiry(expiresAt);
}

async function restoreRememberedUnlock(vault) {
  const remembered = await loadRememberedUnlock(vault);
  if (!remembered) return null;
  try {
    const result = await unlockVaultWithKey(vault, remembered.key);
    scheduleUnlockExpiry(remembered.expiresAt);
    return result;
  } catch {
    await clearRememberedUnlock();
    scheduleUnlockExpiry();
    return null;
  }
}

function openVaultDialog(mode, storedVault = null, initialState = null) {
  const dialog = $("#privacy-dialog");
  const form = $("#privacy-form");
  const title = $("#privacy-dialog-title");
  const copy = $("#privacy-dialog-copy");
  const passphrase = $("#privacy-passphrase");
  const confirmWrap = $("#privacy-confirm-wrap");
  const confirmPassphrase = $("#privacy-confirm");
  const remember = $("#privacy-remember");
  const error = $("#privacy-error");
  const submit = $("#privacy-submit");
  const reset = $("#privacy-reset");
  const creating = mode === "create";

  title.textContent = creating ? "Create your privacy passphrase" : "Unlock your records";
  copy.textContent = creating
    ? "Your records will be encrypted before browser storage. Use at least 10 characters and keep this passphrase somewhere safe—it cannot be recovered."
    : "Enter your passphrase. It is never stored or uploaded. This browser can retain a non-exportable unlock key for up to two hours.";
  submit.textContent = creating ? "Create encrypted vault" : "Unlock";
  confirmWrap.classList.toggle("is-hidden", !creating);
  confirmPassphrase.required = creating;
  reset.classList.toggle("is-hidden", creating);
  passphrase.autocomplete = creating ? "new-password" : "current-password";
  error.textContent = "";
  form.reset();
  dialog.oncancel = (event) => event.preventDefault();

  return new Promise((resolve) => {
    form.onsubmit = async (event) => {
      event.preventDefault();
      const secret = passphrase.value;
      if (creating && secret.length < 10) {
        error.textContent = "Use at least 10 characters.";
        return;
      }
      if (creating && secret !== confirmPassphrase.value) {
        error.textContent = "The passphrases do not match.";
        return;
      }
      submit.disabled = true;
      error.textContent = creating ? "Creating encrypted vault…" : "Unlocking…";
      try {
        const result = creating
          ? await createVault(initialState, secret)
          : await unlockVault(storedVault, secret);
        passphrase.value = "";
        confirmPassphrase.value = "";
        dialog.close();
        resolve({ kind: "success", result, remember: remember.checked });
      } catch {
        error.textContent = creating
          ? "The encrypted vault could not be created in this browser."
          : "Incorrect passphrase or damaged encrypted data.";
      } finally {
        submit.disabled = false;
      }
    };
    reset.onclick = () => {
      const approved = window.confirm(
        "Erase the encrypted vault on this device? Without the passphrase, these records cannot be recovered.",
      );
      if (!approved) return;
      dialog.close();
      resolve({ kind: "erase" });
    };
    dialog.showModal();
    requestAnimationFrame(() => passphrase.focus());
  });
}

async function initializeVault() {
  while (true) {
    const stored = localStorage.getItem(VAULT_STORAGE_KEY);
    if (stored) {
      let parsed;
      try {
        parsed = JSON.parse(stored);
      } catch {
        parsed = null;
      }
      const remembered = localStorage.getItem(UNLOCK_BLOCK_STORAGE_KEY)
        ? null
        : await restoreRememberedUnlock(parsed);
      if (remembered) {
        state = normalizeState(remembered.state);
        vaultKey = remembered.key;
        vaultSalt = remembered.salt;
        vaultIterations = remembered.iterations;
        return;
      }
      const access = await openVaultDialog("unlock", parsed);
      if (access.kind === "erase") {
        localStorage.removeItem(VAULT_STORAGE_KEY);
        localStorage.removeItem(STORAGE_KEY);
        localStorage.setItem(UNLOCK_BLOCK_STORAGE_KEY, "1");
        await clearRememberedUnlock();
        scheduleUnlockExpiry();
        continue;
      }
      state = normalizeState(access.result.state);
      vaultKey = access.result.key;
      vaultSalt = access.result.salt;
      vaultIterations = access.result.iterations;
      await configureRememberedUnlock(access.result, access.remember);
      return;
    }

    const initialState = legacyState();
    const access = await openVaultDialog("create", null, initialState);
    state = normalizeState(access.result.state);
    vaultKey = access.result.key;
    vaultSalt = access.result.salt;
    vaultIterations = access.result.iterations;
    localStorage.setItem(VAULT_STORAGE_KEY, JSON.stringify(access.result.vault));
    localStorage.removeItem(STORAGE_KEY);
    await configureRememberedUnlock(access.result, access.remember);
    return;
  }
}

function formatDate(dateString, options = { weekday: "short", month: "short", day: "numeric" }) {
  return new Intl.DateTimeFormat(undefined, options).format(new Date(`${dateString}T12:00:00`));
}

function normalizeExerciseGuidance(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const normalized = {};
  ["setup", "action", "watch", "option"].forEach((key) => {
    if (typeof value[key] === "string" && value[key].trim()) normalized[key] = value[key].trim().slice(0, 500);
  });
  return normalized.setup && normalized.action && normalized.watch ? normalized : undefined;
}

function normalizePlan(raw, expectedId) {
  if (!raw || typeof raw !== "object" || raw.schemaVersion !== 1) {
    throw new Error("This plan uses an unsupported format.");
  }
  const id = String(raw.id || expectedId || "");
  if (!/^[a-z0-9][a-z0-9-]{0,63}$/.test(id) || (expectedId && id !== expectedId)) {
    throw new Error("This plan has an invalid identifier.");
  }
  const days = {};
  DAY_KEYS.forEach((dayKey) => {
    const source = raw.days?.[dayKey];
    if (!source) {
      days[dayKey] = {
        label: dayKey[0].toUpperCase() + dayKey.slice(1),
        short: dayKey.slice(0, 3).toUpperCase(),
        focus: "Rest",
        kicker: "Recovery",
        estimate: "No training",
        tone: "rest",
        sequenceNote: "No planned training.",
        warmup: [],
        exercises: [],
      };
      return;
    }
    days[dayKey] = {
      label: String(source.label || dayKey[0].toUpperCase() + dayKey.slice(1)),
      short: String(source.short || dayKey.slice(0, 3).toUpperCase()).slice(0, 8),
      focus: String(source.focus || "Training"),
      kicker: String(source.kicker || "Workout"),
      estimate: String(source.estimate || ""),
      tone: ["lime", "blue", "orange", "pink", "purple", "teal", "rest"].includes(source.tone)
        ? source.tone
        : "lime",
      sequenceNote: String(source.sequenceNote || ""),
      warmup: Array.isArray(source.warmup) ? source.warmup.map(String).slice(0, 30) : [],
      exercises: Array.isArray(source.exercises)
        ? source.exercises.slice(0, 40).map((exercise, index) => ({
            id: String(exercise.id || `${dayKey}-${index + 1}`),
            name: String(exercise.name || `Exercise ${index + 1}`),
            prescription: String(exercise.prescription || ""),
            sets: Math.max(1, Math.min(20, Number(exercise.sets) || 1)),
            rest: Math.max(0, Math.min(900, Number(exercise.rest) || 0)),
            measurement: Object.hasOwn(MEASUREMENT_TYPES, exercise.measurement)
              ? exercise.measurement
              : "reps",
            category: String(exercise.category || "Training"),
            section: exercise.section ? String(exercise.section) : undefined,
            optional: Boolean(exercise.optional),
            guidance: normalizeExerciseGuidance(exercise.guidance),
          }))
        : [],
    };
  });
  return {
    id,
    name: String(raw.name || id),
    description: String(raw.description || ""),
    days,
    longRuns: Array.isArray(raw.longRuns) ? raw.longRuns.map(String).slice(0, 52) : [],
    longRunDay: DAY_KEYS.includes(raw.longRunDay) ? raw.longRunDay : "saturday",
  };
}

async function discoverPlans() {
  try {
    const response = await fetch("./plans/index.json", { cache: "no-store" });
    if (!response.ok) return;
    const catalog = await response.json();
    planCatalog = Array.isArray(catalog.plans) ? catalog.plans : [];
  } catch {
    planCatalog = [];
  }
}

async function loadPlan(planId) {
  if (planId === BUILT_IN_PLAN.id) return BUILT_IN_PLAN;
  const entry = planCatalog.find((plan) => plan.id === planId);
  if (!entry) throw new Error("That workout plan is not available.");
  const response = await fetch(entry.path, { cache: "no-store" });
  if (!response.ok) throw new Error("The workout plan could not be loaded.");
  return normalizePlan(await response.json(), entry.id);
}

function renderPlanSelect() {
  const select = $("#plan-select");
  select.replaceChildren();
  [{ id: BUILT_IN_PLAN.id, name: BUILT_IN_PLAN.name }, ...planCatalog].forEach((plan) => {
    const option = document.createElement("option");
    option.value = plan.id;
    option.textContent = plan.name;
    option.selected = plan.id === activePlan.id;
    select.append(option);
  });
}

async function changePlan(planId, announce = true, preserveProgression = false) {
  try {
    activePlan = await loadPlan(planId);
    state.settings.activePlanId = activePlan.id;
    if (!preserveProgression) state.settings.longRunWeek = 1;
    longRunPreviewStage = null;
    longRunViewedPhase = null;
    draftSession = null;
    await persistState();
    renderPlanSelect();
    renderLongRunOptions();
    renderToday();
    renderWeek();
    if (activeView === "progress") renderProgress();
    if (announce) showToast(`${activePlan.name} loaded.`);
  } catch (error) {
    renderPlanSelect();
    showToast(error.message || "That workout plan could not be loaded.", "error");
  }
}

function switchView(view) {
  activeView = view;
  document.body.dataset.activeView = view;
  $$(".view").forEach((section) => section.classList.toggle("is-active", section.id === `view-${view}`));
  $$("[data-nav]").forEach((button) => button.classList.toggle("is-active", button.dataset.nav === view));
  window.scrollTo({ top: 0, behavior: "smooth" });
  if (view === "week") renderWeek();
  if (view === "progress") renderProgress();
  syncTimerVisibility();
}

function currentLog() {
  if (draftSession?.date === selectedDate) return draftSession;
  const draft = state.workoutDrafts[workoutLogKey(selectedDate)];
  if (draft) return draft;
  return state.workoutLogs[workoutLogKey(selectedDate)] || null;
}

function workoutLogKey(date) {
  return activePlan.id === "form-flow" ? date : `${activePlan.id}::${date}`;
}

function exerciseConfigKey(exerciseId) {
  return activePlan.id === "form-flow" ? exerciseId : `${activePlan.id}::${exerciseId}`;
}

function activeWorkoutLogs() {
  return Object.fromEntries(
    Object.entries(state.workoutLogs).filter(([, log]) => (log.planId || "form-flow") === activePlan.id),
  );
}

function createActivityId(prefix = "extra") {
  const suffix = globalThis.crypto?.randomUUID
    ? globalThis.crypto.randomUUID()
    : `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
  return `${prefix}-${suffix}`.toLowerCase();
}

function plannedCardioExerciseIds() {
  return [
    ...new Set(
      Object.values(activePlan.days)
        .flatMap((day) => day.exercises)
        .filter((exercise) => exercise.category === "Cardio")
        .map((exercise) => exercise.id),
    ),
  ];
}

function cardioSummaryForWeek(weekStart) {
  const start = toIsoDate(weekStart);
  const end = toIsoDate(addDays(weekStart, 7));
  return summarizeCardioRange(activeWorkoutLogs(), start, end, plannedCardioExerciseIds());
}

function formatCardioTime(seconds) {
  const minutes = Math.round(Number(seconds || 0) / 60);
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  const remainder = minutes % 60;
  return remainder ? `${hours}h ${remainder}m` : `${hours}h`;
}

function formatCardioDistance(distance) {
  return `${numberFormatter.format(Number(distance || 0))} km`;
}

function currentLongRunStage() {
  const total = activePlan.longRuns?.length || 1;
  return Math.max(1, Math.min(total, Number(state.settings.longRunWeek) || 1));
}

function targetLongRun(stage = currentLongRunStage()) {
  const runs = activePlan.longRuns || [];
  return runs[Math.max(0, Math.min(runs.length - 1, Number(stage || 1) - 1))];
}

function longRunPhases() {
  const count = activePlan.longRuns?.length || 0;
  if (count === LONG_RUNS.length && activePlan.id === BUILT_IN_PLAN.id) return LONG_RUN_PHASES;
  const size = Math.max(1, Math.ceil(count / 4));
  return Array.from({ length: Math.ceil(count / size) }, (_, index) => ({
    id: index + 1,
    name: `Phase ${index + 1}`,
    start: index * size + 1,
    end: Math.min(count, (index + 1) * size),
  }));
}

function longRunPhaseForStage(stage) {
  const phases = longRunPhases();
  return phases.find((phase) => Number(stage) >= phase.start && Number(stage) <= phase.end) || phases[0];
}

function longRunExerciseId() {
  const day = activePlan.days[activePlan.longRunDay];
  return day?.exercises.find((exercise) => exercise.id === "long-run")?.id || "long-run";
}

function longRunLogForStage(stage) {
  const exerciseId = longRunExerciseId();
  return Object.values(activeWorkoutLogs())
    .filter((log) => Number(log.exercises?.[exerciseId]?.progressionStage) === Number(stage))
    .sort((a, b) => b.date.localeCompare(a.date))[0] || null;
}

function longRunEvaluation(stage) {
  const log = longRunLogForStage(stage);
  return {
    ...evaluateLongRunProgress(log, targetLongRun(stage), longRunExerciseId()),
    date: log?.date || "",
  };
}

function qualifiedTenKmRuns() {
  return countQualifiedLongRuns(activeWorkoutLogs(), 10, longRunExerciseId());
}

function latestSleepLog() {
  return summarizeWeeklySleep(state.sleepLogs, state.dailySleepLogs)
    .filter((entry) => entry?.week && entry.week <= selectedDate && Number.isFinite(Number(entry.hours)))
    .sort((a, b) => b.week.localeCompare(a.week))[0] || null;
}

function dailyCheckInRecord(date = toIsoDate()) {
  const existing = state.dailyCheckIns[date];
  if (existing && typeof existing === "object") return existing;
  state.dailyCheckIns[date] = { status: "open", recoveryUnknown: [] };
  return state.dailyCheckIns[date];
}

function dueDailyCheckInItems(date = toIsoDate()) {
  const record = state.dailyCheckIns[date] || {};
  const items = [];
  const sleepLogged = state.dailySleepLogs.some((entry) => entry.date === date);
  if (!sleepLogged && !record.sleepUnknown) items.push({ type: "sleep", date });
  const recoveryUnknown = new Set(record.recoveryUnknown || []);
  findOutstandingRecoveryLogs(state.workoutLogs, date).forEach((workout) => {
    if (!recoveryUnknown.has(workout.key)) items.push({ type: "recovery", ...workout });
  });
  return items;
}

function updateDailyCheckInReminder() {
  const reminder = $("#daily-checkin-reminder");
  const date = toIsoDate();
  const record = state.dailyCheckIns[date] || {};
  const items = dueDailyCheckInItems(date);
  const hidden = !items.length || record.status === "skipped";
  reminder.classList.toggle("is-hidden", hidden);
  if (!hidden) {
    $("#daily-checkin-reminder-title").textContent = `${items.length} check-in${items.length === 1 ? "" : "s"} due`;
  }
}

function setDailyCheckInBusy(busy, message = "") {
  $("#daily-checkin-save").disabled = busy;
  $("#daily-checkin-unknown").disabled = busy;
  $("#daily-checkin-later").disabled = busy;
  $("#daily-checkin-skip").disabled = busy;
  const status = $("#daily-checkin-status");
  status.textContent = message;
  status.dataset.tone = "";
}

function closeDailyCheckIn() {
  const dialog = $("#daily-checkin-dialog");
  if (dialog.open) dialog.close();
  updateDailyCheckInReminder();
}

function dailyCheckInSummary() {
  const parts = [];
  if (dailyCheckInAnswers.sleep !== null) {
    parts.push(`${numberFormatter.format(dailyCheckInAnswers.sleep)} hours sleep`);
  }
  if (dailyCheckInAnswers.recoveries.length) {
    const latest = dailyCheckInAnswers.recoveries.at(-1);
    parts.push(`joints ${latest.label.toLowerCase()}`);
  }
  const hasRecovery = dailyCheckInAnswers.recoveries.length > 0;
  const stable = hasRecovery && dailyCheckInAnswers.recoveries.every((answer) => answer.value <= 1);
  const hasSleep = dailyCheckInAnswers.sleep !== null;
  const sleepOkay = dailyCheckInAnswers.sleep === null || dailyCheckInAnswers.sleep >= OPTIONAL_RECOVERY_RULE.sleepHours;
  let guidance = "No recovery recommendation was changed. You can add the missing answers later.";
  if (stable && sleepOkay && hasSleep) {
    guidance = "Today's workout can stay as planned. You still make the final call.";
  } else if (stable && !hasSleep) {
    guidance = "Your joints are at baseline. Use your sleep and usual energy to make the final call.";
  } else if (!hasRecovery && hasSleep && sleepOkay) {
    guidance = "Sleep meets the first recovery gate. Check your joints, legs, and usual energy before optional work.";
  } else if ((hasSleep && !sleepOkay) || (hasRecovery && !stable)) {
    guidance = "Consider keeping optional work off and adjusting today's session to how you feel.";
  }
  return {
    headline: parts.length ? parts.join(" · ") : "Check-in complete",
    guidance,
  };
}

function renderDailyCheckInStep() {
  const question = $("#daily-checkin-question");
  const save = $("#daily-checkin-save");
  const unknown = $("#daily-checkin-unknown");
  const later = $("#daily-checkin-later");
  const skip = $("#daily-checkin-skip");
  const progress = $("#daily-checkin-progress-bar");
  $("#daily-checkin-status").textContent = "";

  if (dailyCheckInIndex >= dailyCheckInQueue.length) {
    const summary = dailyCheckInSummary();
    $("#daily-checkin-title").textContent = "You're checked in.";
    $("#daily-checkin-copy").textContent = "Your answers were saved to your encrypted records.";
    question.innerHTML = `
      <div class="daily-checkin-summary">
        <h3>${escapeHtml(summary.headline)}</h3>
        <p>${escapeHtml(summary.guidance)}</p>
      </div>
    `;
    progress.style.width = "100%";
    unknown.classList.add("is-hidden");
    later.classList.add("is-hidden");
    skip.classList.add("is-hidden");
    save.textContent = "Done";
    save.dataset.action = "done";
    return;
  }

  const item = dailyCheckInQueue[dailyCheckInIndex];
  $("#daily-checkin-title").textContent = dailyCheckInIndex ? "One more thing." : "Good morning.";
  $("#daily-checkin-copy").textContent = `${dailyCheckInQueue.length} quick check-in${dailyCheckInQueue.length === 1 ? "" : "s"} · about 10 seconds`;
  progress.style.width = `${(dailyCheckInIndex / dailyCheckInQueue.length) * 100}%`;
  unknown.classList.remove("is-hidden");
  later.classList.remove("is-hidden");
  skip.classList.remove("is-hidden");
  save.textContent = "Save & continue";
  save.dataset.action = "save";

  if (item.type === "sleep") {
    question.innerHTML = `
      <h3>How long did you sleep last night?</h3>
      <p>A best estimate is enough. This will update your current weekly average.</p>
      <div class="sleep-stepper">
        <button type="button" data-sleep-adjust="-0.5" aria-label="Subtract 30 minutes">−</button>
        <label>
          <span class="sr-only">Hours slept</span>
          <input id="daily-sleep-hours" type="number" min="0" max="24" step="0.1" inputmode="decimal" placeholder="7.5" />
          <span aria-hidden="true">hr</span>
        </label>
        <button type="button" data-sleep-adjust="0.5" aria-label="Add 30 minutes">+</button>
      </div>
    `;
    $$('[data-sleep-adjust]', question).forEach((button) => {
      button.addEventListener("click", () => {
        const input = $("#daily-sleep-hours");
        const current = input.value === "" ? 7.5 : Number(input.value);
        input.value = String(Math.max(0, Math.min(24, current + Number(button.dataset.sleepAdjust))));
        input.focus();
      });
    });
    requestAnimationFrame(() => $("#daily-sleep-hours")?.focus());
    return;
  }

  question.innerHTML = `
    <h3>How do your joints feel after ${escapeHtml(formatDate(item.date, { weekday: "long" }))}'s workout?</h3>
    <p>Your answer will be added to that workout's Following morning review.</p>
    <div class="checkin-rating-grid" role="radiogroup" aria-label="Following-morning joint response">
      ${RESPONSE_SCALE.map(
        (rating) => `
          <label>
            <input type="radio" name="daily-recovery-rating" value="${rating.value}" />
            <span class="checkin-rating-choice">
              <span aria-hidden="true">${rating.face}</span>
              <strong>${escapeHtml(rating.label)}</strong>
            </span>
          </label>
        `,
      ).join("")}
    </div>
  `;
  requestAnimationFrame(() => $('input[name="daily-recovery-rating"]', question)?.focus());
}

function openDailyCheckIn({ automatic = false } = {}) {
  const date = toIsoDate();
  const record = state.dailyCheckIns[date] || {};
  if (automatic && ["deferred", "skipped", "completed"].includes(record.status)) return;
  dailyCheckInQueue = dueDailyCheckInItems(date);
  if (!dailyCheckInQueue.length) {
    updateDailyCheckInReminder();
    return;
  }
  dailyCheckInIndex = 0;
  dailyCheckInAnswers = { sleep: null, recoveries: [] };
  const dialog = $("#daily-checkin-dialog");
  if (!dialog.open) dialog.show();
  renderDailyCheckInStep();
}

async function deferDailyCheckIn() {
  const date = toIsoDate();
  const previous = state.dailyCheckIns[date] ? structuredClone(state.dailyCheckIns[date]) : null;
  const record = dailyCheckInRecord();
  record.status = "deferred";
  setDailyCheckInBusy(true, "Saving for later…");
  if (!(await persistState())) {
    if (previous) state.dailyCheckIns[date] = previous;
    else delete state.dailyCheckIns[date];
    setDailyCheckInBusy(false);
    const status = $("#daily-checkin-status");
    status.textContent = "Couldn't save yet. Keep this open and try again.";
    status.dataset.tone = "error";
    return;
  }
  setDailyCheckInBusy(false);
  closeDailyCheckIn();
  showToast("Check-in saved for later.");
}

async function skipDailyCheckIn() {
  const date = toIsoDate();
  const previous = state.dailyCheckIns[date] ? structuredClone(state.dailyCheckIns[date]) : null;
  const record = dailyCheckInRecord();
  record.status = "skipped";
  setDailyCheckInBusy(true, "Saving your choice…");
  if (!(await persistState())) {
    if (previous) state.dailyCheckIns[date] = previous;
    else delete state.dailyCheckIns[date];
    setDailyCheckInBusy(false);
    const status = $("#daily-checkin-status");
    status.textContent = "Couldn't save yet. Keep this open and try again.";
    status.dataset.tone = "error";
    return;
  }
  setDailyCheckInBusy(false);
  closeDailyCheckIn();
  showToast("Daily check-in skipped for today.");
}

function dismissDailyCheckIn() {
  if (dailyCheckInIndex >= dailyCheckInQueue.length) closeDailyCheckIn();
  else void deferDailyCheckIn();
}

async function saveDailyCheckInAnswer({ unknown = false } = {}) {
  if (dailyCheckInIndex >= dailyCheckInQueue.length) {
    closeDailyCheckIn();
    return;
  }
  const item = dailyCheckInQueue[dailyCheckInIndex];
  const record = dailyCheckInRecord();
  const before = {
    dailySleepLogs: structuredClone(state.dailySleepLogs),
    dailyCheckIns: structuredClone(state.dailyCheckIns),
    workout: item.type === "recovery" ? structuredClone(state.workoutLogs[item.key]) : null,
  };
  let savedSleep = null;
  let savedRecovery = null;
  setDailyCheckInBusy(true, "Saving encrypted check-in…");

  if (unknown) {
    if (item.type === "sleep") record.sleepUnknown = true;
    else record.recoveryUnknown = [...new Set([...(record.recoveryUnknown || []), item.key])];
  } else if (item.type === "sleep") {
    const hours = Number($("#daily-sleep-hours")?.value);
    if (!Number.isFinite(hours) || hours < 0 || hours > 24 || $("#daily-sleep-hours").value === "") {
      setDailyCheckInBusy(false);
      const status = $("#daily-checkin-status");
      status.textContent = "Enter hours between 0 and 24, or choose Not sure.";
      status.dataset.tone = "error";
      return;
    }
    upsertByDate(state.dailySleepLogs, { date: item.date, hours });
    savedSleep = hours;
  } else {
    const selected = $('input[name="daily-recovery-rating"]:checked');
    if (!selected) {
      setDailyCheckInBusy(false);
      const status = $("#daily-checkin-status");
      status.textContent = "Choose the closest response, or select Not sure.";
      status.dataset.tone = "error";
      return;
    }
    const rating = Number(selected.value);
    const workout = state.workoutLogs[item.key];
    if (!workout) {
      setDailyCheckInBusy(false);
      const status = $("#daily-checkin-status");
      status.textContent = "That workout is no longer available. Close and reopen the check-in.";
      status.dataset.tone = "error";
      return;
    }
    state.workoutLogs[item.key] = {
      ...workout,
      response: { ...(workout.response || {}), scaleVersion: 2, painNext: rating },
      updatedAt: new Date().toISOString(),
    };
    savedRecovery = RESPONSE_SCALE.find((entry) => entry.value === rating);
  }

  const lastItem = dailyCheckInIndex + 1 >= dailyCheckInQueue.length;
  record.status = lastItem ? "completed" : "open";
  const saved = await persistState();
  if (!saved) {
    state.dailySleepLogs = before.dailySleepLogs;
    state.dailyCheckIns = before.dailyCheckIns;
    if (item.type === "recovery" && before.workout) state.workoutLogs[item.key] = before.workout;
    setDailyCheckInBusy(false);
    const status = $("#daily-checkin-status");
    status.textContent = "Couldn't save yet. Keep this open and try again.";
    status.dataset.tone = "error";
    return;
  }
  if (savedSleep !== null) dailyCheckInAnswers.sleep = savedSleep;
  if (savedRecovery) dailyCheckInAnswers.recoveries.push(savedRecovery);
  dailyCheckInIndex += 1;
  setDailyCheckInBusy(false);
  renderDailyCheckInStep();
  updateDailyCheckInReminder();
  if (activeView === "progress") renderSleep();
  renderTrainingRules(activePlan.days[dateToDayKey(selectedDate)]);
}

function maybeOpenDailyCheckIn() {
  updateDailyCheckInReminder();
  if (dailyCheckInAutoShown) return;
  dailyCheckInAutoShown = true;
  requestAnimationFrame(() => openDailyCheckIn({ automatic: true }));
}

function renderTrainingRules(day) {
  const card = $("#training-rules-card");
  const hasStrength = day.exercises.some((exercise) => exercise.category === "Strength");
  card.classList.toggle("is-hidden", !hasStrength);
  if (!hasStrength) return;

  $("#strength-rule-effort").textContent = STRENGTH_PROGRESSION.effort;
  $("#strength-rule-load").textContent = STRENGTH_PROGRESSION.load;
  $("#strength-rule-volume").textContent = STRENGTH_PROGRESSION.volume;

  const sleep = latestSleepLog();
  const gate = $("#recovery-gate");
  const hours = Number(sleep?.hours);
  const sleepReady = sleep && hours >= OPTIONAL_RECOVERY_RULE.sleepHours;
  gate.dataset.status = sleepReady ? "ready" : "hold";
  $("#recovery-gate-title").textContent = sleepReady
    ? `${numberFormatter.format(hours)} h/night · sleep gate met`
    : sleep
      ? `${numberFormatter.format(hours)} h/night · keep optional work off`
      : "No weekly sleep logged · default to recovery";
  $("#recovery-gate-copy").textContent = sleepReady
    ? "Sleep meets the first gate. Add only one optional session when joints, legs, and usual energy have also been stable the following morning for two weeks."
    : OPTIONAL_RECOVERY_RULE.copy;
}

function longRunStatusCopy(evaluation) {
  if (evaluation.date) return `${evaluation.label} · ${formatDate(evaluation.date)}`;
  return evaluation.label;
}

async function setLongRunStage(stage, announce = true) {
  const total = activePlan.longRuns?.length || 0;
  if (!total) return;
  await saveWorkoutDraftNow();
  state.settings.longRunWeek = Math.max(1, Math.min(total, Number(stage) || 1));
  longRunPreviewStage = state.settings.longRunWeek;
  longRunViewedPhase = longRunPhaseForStage(state.settings.longRunWeek)?.id || 1;
  await persistState();
  renderLongRunOptions();
  renderToday();
  if (activeView === "week") renderWeek();
  if (announce) showToast(`Long-run Stage ${state.settings.longRunWeek} is now current.`);
}

function renderPhaseGuide() {
  const builtIn = activePlan.id === BUILT_IN_PLAN.id;
  $(".phase-selector").classList.toggle("is-hidden", !builtIn);
  els.phaseGuide.classList.toggle("is-hidden", !builtIn);
  if (!builtIn) return;
  const phase = RUNNING_PHASES[Number(state.settings.block) === 2 ? 2 : 1];
  $("#phase-guide-number").textContent = phase.number;
  $("#phase-guide-title").textContent = phase.title;
  $("#phase-guide-copy").textContent = phase.copy;
  $("#phase-guide-points").innerHTML = phase.points
    .map(([day, task]) => `<span><strong>${escapeHtml(day)}</strong>${escapeHtml(task)}</span>`)
    .join("");
  const qualified = qualifiedTenKmRuns();
  $("#phase-guide-status").textContent =
    Number(state.settings.block) === 1
      ? `${Math.min(qualified, 2)} of 2 qualified 10 km runs completed. Changing blocks changes only the running prescriptions.`
      : `${qualified} qualified 10 km run${qualified === 1 ? "" : "s"} logged. Keep most running easy while adding one Thursday quality session.`;
  els.phaseGuide.dataset.block = state.settings.block;
}

function activePrescription(exercise) {
  if (activePlan.id !== BUILT_IN_PLAN.id) return exercise.prescription;
  const block = Number(state.settings.block) === 2 ? 2 : 1;
  if (exercise.id === "easy-run") {
    return block === 1
      ? "30 min easy · RPE 2–4 · conversational pace"
      : "30–40 min easy · then 4 × 20-sec relaxed strides with full easy recovery";
  }
  if (exercise.id === "run-2") {
    return block === 1
      ? "25–35 min easy · RPE 2–4 · lift first and separate by about 6 hours"
      : `Alternate completed quality sessions: ${RUN_QUALITY_PROGRESSION.base}. ${RUN_QUALITY_PROGRESSION.progression}`;
  }
  if (exercise.id === "long-run") {
    return block === 1
      ? `${targetLongRun()} easy · walk breaks allowed`
      : "8–10 km easy · conversational pace · walk breaks allowed";
  }
  return exercise.prescription;
}

function renderToday() {
  clearTimeout(draftSaveTimer);
  draftSaveTimer = null;
  workoutDirty = false;
  const dayKey = dateToDayKey(selectedDate);
  const day = activePlan.days[dayKey];
  const log = currentLog();

  els.trainingDate.value = selectedDate;
  els.todayKicker.textContent = selectedDate === toIsoDate() ? "TODAY’S WORK" : formatDate(selectedDate, {
    weekday: "long",
    month: "long",
    day: "numeric",
  }).toUpperCase();
  els.sessionDay.textContent = day.label.toUpperCase();
  els.sessionEstimate.textContent = day.estimate.toUpperCase();
  els.sessionFocus.textContent = day.focus;
  els.sessionNote.textContent = day.sequenceNote;
  els.hero.dataset.tone = day.tone;

  $$("[data-block]").forEach((button) => {
    const active = Number(button.dataset.block) === Number(state.settings.block);
    button.classList.toggle("is-active", active);
    button.setAttribute("aria-pressed", String(active));
  });
  renderPhaseGuide();

  if (activePlan.longRuns?.length && dayKey === activePlan.longRunDay && Number(state.settings.block) === 1) {
    const savedStage = Number(log?.exercises?.[longRunExerciseId()]?.progressionStage);
    const displayStage = savedStage || currentLongRunStage();
    const phase = longRunPhaseForStage(displayStage);
    const evaluation = longRunEvaluation(displayStage);
    els.longRunCallout.classList.remove("is-hidden");
    els.longRunCallout.innerHTML = `
      <div class="long-run-callout-copy">
        <span>${escapeHtml(phase?.name || "Long run")} · STAGE ${displayStage} OF ${activePlan.longRuns.length}</span>
        <strong>${escapeHtml(targetLongRun(displayStage))}</strong>
        <small>${escapeHtml(longRunStatusCopy(evaluation))}. Progress by recovery, not by the calendar.</small>
      </div>
      <button class="button button-dark" type="button" id="open-long-run-roadmap">Open roadmap</button>
    `;
    $("#open-long-run-roadmap").addEventListener("click", async () => {
      await saveWorkoutDraftNow();
      longRunPreviewStage = currentLongRunStage();
      longRunViewedPhase = longRunPhaseForStage(longRunPreviewStage)?.id || 1;
      switchView("week");
    });
  } else {
    els.longRunCallout.classList.add("is-hidden");
    els.longRunCallout.replaceChildren();
  }

  renderWarmup(day, log);
  renderTrainingRules(day);
  renderExercises(day, log);
  renderExtraActivities(day, log);
  loadResponseFields(log);
  updateSessionProgress();
  updateDailyCheckInReminder();

  const saved = state.workoutLogs[workoutLogKey(selectedDate)];
  const savedDraft = state.workoutDrafts[workoutLogKey(selectedDate)];
  if (draftSession) {
    setSaveStatus("Session loaded · review & save", "restored");
  } else if (savedDraft) {
    setSaveStatus("Draft restored · review & save", "restored");
  } else if (saved) {
    setSaveStatus(`Saved ${formatDate(saved.updatedAt?.slice(0, 10) || selectedDate)}`, "saved");
  } else {
    setSaveStatus(day.exercises.length ? "Not saved yet" : "Rest day");
  }
  els.loadSession.disabled =
    !findPreviousSession(state.workoutLogs, dayKey, selectedDate, activePlan.id) || !day.exercises.length;
}

function renderWarmup(day, log) {
  els.warmupList.replaceChildren();
  const checked = log?.warmup || [];
  day.warmup.forEach((item, index) => {
    const label = document.createElement("label");
    label.className = "check-row";
    label.innerHTML = `
      <input type="checkbox" data-warmup-index="${index}" ${checked[index] ? "checked" : ""} />
      <span class="custom-check" aria-hidden="true">✓</span>
      <span>${escapeHtml(item)}</span>
    `;
    els.warmupList.append(label);
  });
  if (!day.warmup.length) {
    els.warmupList.innerHTML = `<p class="empty-copy">No warm-up today. Let recovery do its work.</p>`;
  }
  updateWarmupCount();
}

function renderExercises(day, log) {
  els.exerciseList.replaceChildren();
  if (!day.exercises.length) {
    els.exerciseList.innerHTML = `
      <article class="rest-card">
        <span class="rest-orbit" aria-hidden="true"></span>
        <p class="eyebrow">SUNDAY</p>
        <h2>Complete rest.</h2>
        <p>Ordinary relaxed movement is fine. Review the week’s sleep, load, pain, and next-morning notes.</p>
      </article>
    `;
    return;
  }
  day.exercises.forEach((exercise, index) => {
    els.exerciseList.append(createExerciseCard(exercise, index, log?.exercises?.[exercise.id]));
  });
}

function renderExtraActivities(day, log) {
  els.extraActivityList.replaceChildren();
  const activities = Array.isArray(log?.extraActivities) ? log.extraActivities : [];
  activities.forEach((activity) => els.extraActivityList.append(createExtraActivityCard(activity)));
  els.extraActivitySection.classList.toggle("is-hidden", !day.exercises.length && !activities.length);
}

function createExtraActivityCard(activity) {
  const card = $("#extra-activity-template").content.firstElementChild.cloneNode(true);
  const type = EXTRA_ACTIVITY_TYPES.includes(activity.type) ? activity.type : "custom";
  const measurement = EXTRA_ACTIVITY_MEASUREMENTS.includes(activity.measurement)
    ? activity.measurement
    : "duration";
  card.dataset.activityId = activity.id || createActivityId();
  card.dataset.reusableId = activity.reusableId || "";
  card.dataset.activityType = type;
  card.dataset.activityName = activity.name || ACTIVITY_TYPE_LABELS[type];
  $(".extra-activity-type", card).textContent = `${ACTIVITY_TYPE_LABELS[type]} · EXTRA`;
  $(".extra-activity-name", card).textContent = card.dataset.activityName;

  const measurementSelect = $(".extra-measurement-select", card);
  measurementSelect.value = measurement;
  const sets = Array.isArray(activity.sets) && activity.sets.length ? activity.sets : [{}];
  renderSetRows(card, measurement, sets, { rowLabel: "Done", removable: false });

  measurementSelect.addEventListener("change", () => {
    renderSetRows(card, measurementSelect.value, [{}], { rowLabel: "Done", removable: false });
    markWorkoutDirty();
    updateSessionProgress();
  });
  $(".remove-extra-activity", card).addEventListener("click", () => {
    card.remove();
    markWorkoutDirty();
    updateSessionProgress();
  });
  return card;
}

function collectExtraActivities() {
  return $$(".extra-activity-card", els.extraActivityList)
    .map((card) => ({
      id: card.dataset.activityId,
      reusableId: card.dataset.reusableId || undefined,
      type: card.dataset.activityType,
      name: card.dataset.activityName,
      measurement: $(".extra-measurement-select", card).value,
      sets: collectSetRows(card, $(".extra-measurement-select", card).value),
    }))
    .filter((activity) => activity.sets.some(hasSetContent));
}

function renderSavedActivityOptions(selectedId = "") {
  const select = $("#saved-activity-select");
  select.replaceChildren();
  const createOption = document.createElement("option");
  createOption.value = "";
  createOption.textContent = "Create a new activity";
  select.append(createOption);
  state.savedActivities.forEach((activity) => {
    const option = document.createElement("option");
    option.value = activity.id;
    option.textContent = `${activity.name} · ${MEASUREMENT_TYPES[activity.measurement].label}`;
    select.append(option);
  });
  select.value = selectedId;
  $("#forget-saved-activity").classList.toggle("is-hidden", !selectedId);
}

function setNewActivityDefaults() {
  $("#extra-activity-type").value = "walking";
  $("#extra-activity-name").value = "Walking";
  $("#extra-activity-measurement").value = "duration";
  $("#save-extra-activity").checked = false;
}

function openExtraActivityDialog() {
  const dialog = $("#extra-activity-dialog");
  $("#extra-activity-form").reset();
  setNewActivityDefaults();
  renderSavedActivityOptions();
  dialog.showModal();
  requestAnimationFrame(() => $("#extra-activity-type").focus());
}

function closeExtraActivityDialog() {
  $("#extra-activity-dialog").close();
}

async function forgetSavedActivity() {
  const savedId = $("#saved-activity-select").value;
  const activity = state.savedActivities.find((item) => item.id === savedId);
  if (!activity) return;
  const approved = window.confirm(`Forget “${activity.name}” as a reusable activity? Existing workout logs stay intact.`);
  if (!approved) return;
  state.savedActivities = state.savedActivities.filter((item) => item.id !== savedId);
  await persistState();
  setNewActivityDefaults();
  renderSavedActivityOptions();
  showToast("Reusable activity removed.");
}

async function addExtraActivity(event) {
  event.preventDefault();
  const type = $("#extra-activity-type").value;
  const name = $("#extra-activity-name").value.trim();
  const measurement = $("#extra-activity-measurement").value;
  if (!EXTRA_ACTIVITY_TYPES.includes(type) || !EXTRA_ACTIVITY_MEASUREMENTS.includes(measurement) || !name) {
    showToast("Choose a valid activity type, name, and measurement.", "error");
    return;
  }

  let reusableId = $("#saved-activity-select").value || "";
  if (!reusableId && $("#save-extra-activity").checked) {
    const duplicate = state.savedActivities.find(
      (activity) =>
        activity.name.toLowerCase() === name.toLowerCase() &&
        activity.type === type &&
        activity.measurement === measurement,
    );
    if (duplicate) {
      reusableId = duplicate.id;
    } else {
      reusableId = createActivityId("saved");
      state.savedActivities.push({ id: reusableId, type, name, measurement });
      state.savedActivities.sort((a, b) => a.name.localeCompare(b.name));
      await persistState();
    }
  }

  els.extraActivityList.append(
    createExtraActivityCard({
      id: createActivityId(),
      reusableId: reusableId || undefined,
      type,
      name,
      measurement,
      sets: [{}],
    }),
  );
  closeExtraActivityDialog();
  markWorkoutDirty();
  updateSessionProgress();
  showToast(`${name} added. Enter the result, then save the workout.`);
}

function markWorkoutDirty() {
  workoutDirty = true;
  draftRevision += 1;
  setSaveStatus("Saving encrypted draft…", "saving");
  clearTimeout(draftSaveTimer);
  draftSaveTimer = setTimeout(() => {
    saveWorkoutDraftNow();
  }, 250);
}

function getPullupStep(stepId) {
  return PULL_UP_STEPS.find((step) => step.id === Number(stepId)) || PULL_UP_STEPS[0];
}

function pullupSuccessCount(stepId, beforeDate) {
  return Object.values(activeWorkoutLogs()).filter((log) => {
    const exercise = log.exercises?.["pull-up-progression"];
    return (
      log.date < beforeDate &&
      Number(exercise?.progressionStep) === Number(stepId) &&
      exercise?.progressionQualified === true
    );
  }).length;
}

function pullupQualification(savedExercise) {
  const legacy = savedExercise?.progressionQualified === true;
  return {
    performance: savedExercise?.progressionPerformanceQualified ?? legacy,
    recovery: savedExercise?.progressionRecoveryQualified ?? legacy,
  };
}

function pullupSuccessfulSessions(card) {
  const stepId = Number($(".progression-select", card).value);
  const prior = pullupSuccessCount(stepId, selectedDate);
  const countsCurrent = card.dataset.progressionCounts === "true";
  const performance = $(".progression-performance-qualified", card).checked;
  const recovery = $(".progression-recovery-qualified", card).checked;
  return Math.min(2, prior + (countsCurrent && performance && recovery ? 1 : 0));
}

function pullupRoadmapStatus(stepId, currentStepId, currentReady) {
  if (stepId < currentStepId) return { key: "completed", label: "Completed" };
  if (stepId === currentStepId) {
    return currentReady ? { key: "ready", label: "Ready to advance" } : { key: "current", label: "Current step" };
  }
  if (stepId === currentStepId + 1 && currentReady) return { key: "eligible", label: "Ready to select" };
  return { key: "upcoming", label: "Not yet verified" };
}

function renderPullupRoadmap(card, previewStepId) {
  const currentStepId = Number($(".progression-select", card).value);
  const successful = pullupSuccessfulSessions(card);
  const currentReady = successful >= 2;
  const preview = getPullupStep(previewStepId || currentStepId);
  const range = $(".progression-range", card);
  range.value = preview.id;
  range.setAttribute("aria-valuetext", `${preview.label}: ${preview.title}`);
  range.style.setProperty("--range-progress", `${((preview.id - 1) / (PULL_UP_STEPS.length - 1)) * 100}%`);
  $(".progression-current-label", card).textContent = `Step ${currentStepId} of ${PULL_UP_STEPS.length}`;

  const rail = $(".progression-rail", card);
  rail.replaceChildren();
  PULL_UP_STEPS.forEach((step) => {
    const status = pullupRoadmapStatus(step.id, currentStepId, currentReady);
    const button = document.createElement("button");
    button.type = "button";
    button.className = "progression-node";
    button.dataset.status = status.key;
    button.classList.toggle("is-preview", step.id === preview.id);
    button.setAttribute("aria-label", `${step.label}. ${status.label}`);
    if (step.id === currentStepId) button.setAttribute("aria-current", "step");
    button.innerHTML = `
      <span class="progression-node-dot">${status.key === "completed" ? "✓" : step.id}</span>
      <span>${escapeHtml(step.short)}</span>
    `;
    button.addEventListener("click", () => renderPullupRoadmap(card, step.id));
    rail.append(button);
  });

  const previewStatus = pullupRoadmapStatus(preview.id, currentStepId, currentReady);
  $(".progression-title", card).textContent = `${preview.label}: ${preview.title}`;
  $(".progression-preview-status", card).textContent = previewStatus.label;
  $(".progression-preview-status", card).dataset.status = previewStatus.key;
  $(".progression-prescription", card).innerHTML = `<strong>Prescription:</strong> ${escapeHtml(preview.prescription)}`;
  $(".progression-target", card).innerHTML = `<strong>Criteria:</strong> ${escapeHtml(preview.target)}`;
  $(".progression-next", card).innerHTML = `<strong>Next:</strong> ${escapeHtml(preview.next)}`;
  const apply = $(".progression-apply", card);
  apply.classList.toggle("is-hidden", preview.id === currentStepId);
  apply.textContent =
    preview.id < currentStepId ? `Step back to Step ${preview.id}` : `Use Step ${preview.id}`;
}

function updatePullupProgressStatus(card) {
  if (card.dataset.progression !== "pullup" || card.dataset.progressionCounts !== "true") return;
  const stepId = Number($(".progression-select", card).value);
  const performance = $(".progression-performance-qualified", card).checked;
  const recovery = $(".progression-recovery-qualified", card).checked;
  const successful = pullupSuccessfulSessions(card);
  const status = $(".progression-status", card);
  if (performance && !recovery) {
    status.textContent = "Performance logged · morning check pending";
    status.dataset.ready = "false";
  } else if (successful >= 2) {
    status.textContent =
      stepId === PULL_UP_STEPS.length ? "Goal step confirmed · keep building clean reps" : "2 of 2 · ready for the next step";
    status.dataset.ready = "true";
  } else {
    status.textContent = `${successful} of 2 successful sessions`;
    status.dataset.ready = "false";
  }
  renderPullupRoadmap(card, Number($(".progression-range", card).value));
}

function applyPullupStep(card, exercise, step, resetSets = false) {
  const isOptional = Boolean(exercise.optional);
  const workingSets = isOptional ? Math.min(2, step.sets) : step.sets;
  card.dataset.progressionStep = step.id;
  card.dataset.defaultSets = workingSets;
  $(".exercise-prescription", card).textContent = isOptional
    ? `Optional technique practice · first ${workingSets} sets of ${step.label}`
    : step.prescription;
  if (resetSets) {
    const measurement = $(".measurement-select", card);
    measurement.value = step.measurement;
    state.exerciseConfigs[exerciseConfigKey(exercise.id)] = step.measurement;
    renderSetRows(card, step.measurement, Array.from({ length: workingSets }, () => ({})));
  }
}

function setupPullupGuide(card, exercise, savedExercise) {
  const guide = $(".exercise-guide", card);
  guide.classList.remove("is-hidden");
  card.dataset.progression = "pullup";
  card.dataset.progressionCounts = String(!exercise.optional);

  const stepSelect = $(".progression-select", card);
  const selectedStep = getPullupStep(savedExercise?.progressionStep ?? state.settings.pullupStep);
  stepSelect.value = selectedStep.id;

  const progressionCheck = $(".progression-check", card);
  progressionCheck.classList.toggle("is-hidden", Boolean(exercise.optional));
  const qualification = pullupQualification(savedExercise);
  const performance = $(".progression-performance-qualified", card);
  const recovery = $(".progression-recovery-qualified", card);
  performance.checked = qualification.performance;
  recovery.checked = qualification.recovery;
  recovery.disabled = selectedDate >= toIsoDate() && !qualification.recovery;
  $(".progression-check-help", card).textContent = recovery.disabled
    ? "The following-morning check becomes available tomorrow. Save today’s performance now."
    : "Confirm the following-morning response, then save this date again.";
  applyPullupStep(card, exercise, selectedStep);
  renderPullupRoadmap(card, selectedStep.id);
  updatePullupProgressStatus(card);

  $(".progression-range", card).addEventListener("input", (event) => {
    renderPullupRoadmap(card, Number(event.target.value));
  });
  $(".progression-apply", card).addEventListener("click", () => {
    const step = getPullupStep($(".progression-range", card).value);
    const hasEnteredSets = collectSetRows(card).some(hasSetContent);
    if (
      hasEnteredSets &&
      !window.confirm(`Changing to ${step.label} will clear the sets entered on this workout. Continue?`)
    ) {
      renderPullupRoadmap(card, Number(stepSelect.value));
      return;
    }
    state.settings.pullupStep = step.id;
    stepSelect.value = step.id;
    performance.checked = false;
    recovery.checked = false;
    recovery.disabled = selectedDate >= toIsoDate();
    applyPullupStep(card, exercise, step, true);
    renderPullupRoadmap(card, step.id);
    updatePullupProgressStatus(card);
    persistState();
    markWorkoutDirty();
    updateSessionProgress();
  });
  performance.addEventListener("change", () => updatePullupProgressStatus(card));
  recovery.addEventListener("change", () => updatePullupProgressStatus(card));
}

function setupExerciseGuidance(card, exercise) {
  const guide =
    exercise.guidance ||
    (activePlan.id === BUILT_IN_PLAN.id ? EXERCISE_GUIDANCE[exercise.id] : undefined);
  if (!guide) return;
  const details = $(".form-guide", card);
  details.classList.remove("is-hidden");
  ["setup", "action", "watch"].forEach((key) => {
    $(`[data-guidance="${key}"]`, details).textContent = guide[key];
  });
  const option = $(".form-guide-option", details);
  if (guide.option) {
    $(".form-guide summary small", details).textContent = "Setup · movement · alternative available";
    details.classList.add("has-alternative");
    option.classList.remove("is-hidden");
    $('[data-guidance="option"]', option).textContent = guide.option;
  }
}

function exerciseVariants(exercise) {
  const alternatives =
    activePlan.id === BUILT_IN_PLAN.id ? EXERCISE_ALTERNATIVES[exercise.id] || [] : [];
  return [
    {
      id: exercise.id,
      name: exercise.name,
      prescription: activePrescription(exercise),
      sets: exercise.sets,
      measurement: exercise.measurement,
      original: true,
    },
    ...alternatives,
  ];
}

function applyExerciseVariant(card, exercise, variant, { resetSets = false } = {}) {
  card.dataset.variantId = variant.id;
  card.dataset.variantName = variant.name;
  card.dataset.defaultSets = variant.sets;
  $(".exercise-name", card).textContent = variant.name;
  $(".exercise-prescription", card).textContent = variant.prescription;
  card.classList.toggle("has-selected-alternative", !variant.original);
  const selectedTag = $(".selected-alternative-tag", card);
  selectedTag?.classList.toggle("is-hidden", variant.original);

  $$(".alternative-choice", card).forEach((button) => {
    const selected = button.dataset.variantId === variant.id;
    button.classList.toggle("is-selected", selected);
    button.setAttribute("aria-pressed", String(selected));
  });

  if (resetSets) {
    const select = $(".measurement-select", card);
    select.value = variant.measurement;
    renderSetRows(card, variant.measurement, Array.from({ length: variant.sets }, () => ({})));
  }
}

function setupExerciseAlternatives(card, exercise, savedExercise) {
  const variants = exerciseVariants(exercise);
  if (variants.length === 1) return null;

  const picker = $(".alternative-picker", card);
  const toggle = $(".alternatives-button", card);
  const choices = $(".alternative-choices", card);
  toggle.classList.remove("is-hidden");
  choices.replaceChildren();

  variants.forEach((variant) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "alternative-choice";
    button.dataset.variantId = variant.id;
    button.setAttribute("aria-pressed", "false");
    button.innerHTML = `
      <span>${escapeHtml(variant.original ? "PLANNED EXERCISE" : "ALTERNATIVE")}</span>
      <strong>${escapeHtml(variant.name)}</strong>
      <small>${escapeHtml(variant.prescription)}</small>
    `;
    button.addEventListener("click", () => {
      if (card.dataset.variantId === variant.id) {
        picker.classList.add("is-hidden");
        toggle.setAttribute("aria-expanded", "false");
        return;
      }
      const hasEnteredSets = collectSetRows(card).some(hasSetContent);
      if (
        hasEnteredSets &&
        !window.confirm(`Changing to ${variant.name} will clear the sets entered on this workout. Continue?`)
      ) {
        return;
      }
      applyExerciseVariant(card, exercise, variant, { resetSets: true });
      updatePreviousExerciseState(card, exercise);
      picker.classList.add("is-hidden");
      toggle.setAttribute("aria-expanded", "false");
      markWorkoutDirty();
      updateSessionProgress();
      showToast(`${variant.name} selected for this workout.`);
    });
    choices.append(button);
  });

  toggle.addEventListener("click", () => {
    const opening = picker.classList.contains("is-hidden");
    picker.classList.toggle("is-hidden", !opening);
    toggle.setAttribute("aria-expanded", String(opening));
  });

  return variants.find((variant) => variant.id === savedExercise?.variantId) || variants[0];
}

function updatePreviousExerciseState(card, exercise) {
  const previous = findPreviousExerciseLog(
    state.workoutLogs,
    exercise.id,
    selectedDate,
    activePlan.id,
    state.workoutDrafts,
    card.dataset.variantId,
  );
  const previousLine = $(".previous-line", card);
  const loadPrevious = $(".load-previous", card);
  if (previous) {
    previousLine.textContent = `Last: ${formatDate(previous.date)} · ${summarizeSetPreview(previous.measurement, previous.sets)}`;
    loadPrevious.disabled = false;
  } else {
    previousLine.textContent = "No earlier log for this exercise variation.";
    loadPrevious.disabled = true;
  }
  return previous;
}

function createExerciseCard(exercise, index, savedExercise) {
  const card = $("#exercise-template").content.firstElementChild.cloneNode(true);
  const pullupStep =
    exercise.progression === "pullup"
      ? getPullupStep(savedExercise?.progressionStep ?? state.settings.pullupStep)
      : null;
  const isLongRunProgression =
    exercise.id === longRunExerciseId() &&
    activePlan.longRuns?.length &&
    (activePlan.id !== BUILT_IN_PLAN.id || Number(state.settings.block) === 1);
  const longRunStage = isLongRunProgression
    ? Math.max(
        1,
        Math.min(
          activePlan.longRuns.length,
          Number(savedExercise?.progressionStage ?? state.settings.longRunWeek) || 1,
        ),
      )
    : null;
  card.dataset.exerciseId = exercise.id;
  card.dataset.defaultSets = pullupStep
    ? exercise.optional
      ? Math.min(2, pullupStep.sets)
      : pullupStep.sets
    : exercise.sets;
  card.dataset.rest = exercise.rest;
  card.dataset.exerciseName = exercise.name;
  if (longRunStage) card.dataset.longRunStage = longRunStage;

  $(".exercise-number", card).textContent = String(index + 1).padStart(2, "0");
  $(".exercise-name", card).textContent = exercise.name;
  $(".exercise-prescription", card).textContent = pullupStep
    ? pullupStep.prescription
    : longRunStage
      ? `${targetLongRun(longRunStage)} easy · walk breaks allowed`
      : activePrescription(exercise);
  $(".exercise-tags", card).innerHTML = `
    <span>${escapeHtml(exercise.section || exercise.category)}</span>
    ${exercise.optional ? "<span class=\"tag-optional\">OPTIONAL</span>" : ""}
  `;
  setupExerciseGuidance(card, exercise);

  const selectedVariant = setupExerciseAlternatives(card, exercise, savedExercise);
  if (selectedVariant) applyExerciseVariant(card, exercise, selectedVariant);

  const measurement =
    savedExercise?.measurement ||
    pullupStep?.measurement ||
    (selectedVariant && !selectedVariant.original
      ? selectedVariant.measurement
      : state.exerciseConfigs[exerciseConfigKey(exercise.id)]) ||
    exercise.measurement;
  const select = $(".measurement-select", card);
  Object.entries(MEASUREMENT_TYPES).forEach(([key, config]) => {
    const option = document.createElement("option");
    option.value = key;
    option.textContent = config.label;
    option.selected = key === measurement;
    select.append(option);
  });

  updatePreviousExerciseState(card, exercise);

  const sets = savedExercise?.sets?.length
    ? savedExercise.sets
    : Array.from({ length: Number(card.dataset.defaultSets) }, () => ({}));
  renderSetRows(card, measurement, sets);
  if (exercise.progression === "pullup") setupPullupGuide(card, exercise, savedExercise);

  if (shouldCollapseExerciseByDefault(exercise, savedExercise, window.matchMedia("(max-width: 680px)").matches)) {
    card.classList.add("is-collapsed");
    $(".exercise-toggle", card).setAttribute("aria-expanded", "false");
  }

  $(".exercise-toggle", card).addEventListener("click", (event) => {
    const button = event.currentTarget;
    const collapsed = card.classList.toggle("is-collapsed");
    button.setAttribute("aria-expanded", String(!collapsed));
  });
  select.addEventListener("change", () => {
    state.exerciseConfigs[exerciseConfigKey(exercise.id)] = select.value;
    persistState();
    renderSetRows(card, select.value, Array.from({ length: Number(card.dataset.defaultSets) }, () => ({})));
    markWorkoutDirty();
    updateSessionProgress();
  });
  $(".load-previous", card).addEventListener("click", () => {
    const earlier = findPreviousExerciseLog(
      state.workoutLogs,
      exercise.id,
      selectedDate,
      activePlan.id,
      state.workoutDrafts,
      card.dataset.variantId,
    );
    if (!earlier) return;
    const todaySetCount = $(".set-list", card).children.length || Number(card.dataset.defaultSets);
    select.value = earlier.measurement;
    state.exerciseConfigs[exerciseConfigKey(exercise.id)] = earlier.measurement;
    persistState();
    renderSetRows(card, earlier.measurement, preparePreviousSets(earlier.sets, todaySetCount, earlier.measurement));
    clearImportedCompletion(card);
    markWorkoutDirty();
    showToast(`${exercise.name}: values loaded; today remains not done.`);
    updateSessionProgress();
  });
  $(".copy-first-set", card).addEventListener("click", () => copyFirstSetIntoEmpty(card, select.value));
  $(".add-set", card).addEventListener("click", () => {
    const setList = $(".set-list", card);
    setList.append(createSetRow(select.value, setList.children.length, {}, Number(card.dataset.rest)));
    updateCopyFirstSetButton(card, select.value);
    markWorkoutDirty();
  });
  return card;
}

function renderSetRows(card, measurement, sets, options = {}) {
  const setList = $(".set-list", card);
  setList.replaceChildren();
  sets.forEach((set, index) =>
    setList.append(createSetRow(measurement, index, set, Number(card.dataset.rest), options)),
  );
  updateCopyFirstSetButton(card, measurement);
}

function clearImportedCompletion(card) {
  $$(".set-row", card).forEach((row) => {
    $(".set-done input", row).checked = false;
    row.classList.remove("is-done");
  });

  const performance = $(".progression-performance-qualified", card);
  const recovery = $(".progression-recovery-qualified", card);
  if (performance) performance.checked = false;
  if (recovery) recovery.checked = false;
  if (card.dataset.progression === "pullup") updatePullupProgressStatus(card);
}

function repeatableFields(measurement) {
  return MEASUREMENT_TYPES[measurement].fields.filter((field) => !["rir", "rpe"].includes(field.key));
}

function updateCopyFirstSetButton(card, measurement) {
  const button = $(".copy-first-set", card);
  if (!button) return;
  button.disabled = repeatableFields(measurement).length === 0 || $$(".set-row", card).length < 2;
}

function copyFirstSetIntoEmpty(card, measurement) {
  const rows = $$(".set-row", card);
  const fields = repeatableFields(measurement);
  if (rows.length < 2 || !fields.length) return;
  const source = rows[0];
  const sourceValues = Object.fromEntries(
    fields.map((field) => [field.key, $(`[data-field="${field.key}"]`, source)?.value ?? ""]),
  );
  if (!Object.values(sourceValues).some((value) => value !== "")) {
    showToast("Enter set 1 first, then fill the remaining sets.", "error");
    return;
  }
  let copied = 0;
  rows.slice(1).forEach((row) => {
    fields.forEach((field) => {
      const input = $(`[data-field="${field.key}"]`, row);
      if (input && input.value === "" && sourceValues[field.key] !== "") {
        input.value = sourceValues[field.key];
        copied += 1;
      }
    });
  });
  if (!copied) {
    showToast("The remaining sets already have values.");
    return;
  }
  markWorkoutDirty();
  showToast("Set 1 values filled into empty sets.");
}

function createSetRow(measurement, index, values, restSeconds, options = {}) {
  const row = document.createElement("div");
  row.className = "set-row";
  row.classList.toggle("is-check-only", MEASUREMENT_TYPES[measurement].fields.length === 0);
  row.dataset.setIndex = index;
  row.style.setProperty("--field-count", MEASUREMENT_TYPES[measurement].fields.length);

  const done = document.createElement("label");
  done.className = "set-done";
  const rowLabel = options.rowLabel || (measurement === "completion" ? `Round ${index + 1}` : index + 1);
  done.innerHTML = `
    <input type="checkbox" aria-label="Mark set ${index + 1} complete" ${values.completed ? "checked" : ""} />
    <span>${escapeHtml(rowLabel)}</span>
  `;
  done.querySelector("input").addEventListener("change", (event) => {
    row.classList.toggle("is-done", event.target.checked);
    if (event.target.checked && restSeconds > 0) setTimer(restSeconds, true);
    markWorkoutDirty();
    updateSessionProgress();
  });
  row.classList.toggle("is-done", Boolean(values.completed));
  row.append(done);

  MEASUREMENT_TYPES[measurement].fields.forEach((field) => {
    const label = document.createElement("label");
    label.className = "set-field";
    label.innerHTML = `
      <span>${field.label}</span>
      <div>
        <input
          type="number"
          data-field="${field.key}"
          min="${field.min ?? ""}"
          max="${field.max ?? ""}"
          step="${field.step ?? "any"}"
          inputmode="decimal"
          value="${values[field.key] ?? ""}"
          aria-label="${field.label}, set ${index + 1}"
        />
        ${field.unit ? `<small>${field.unit}</small>` : ""}
      </div>
    `;
    row.append(label);
  });

  if (options.removable === false) return row;

  const remove = document.createElement("button");
  remove.type = "button";
  remove.className = "remove-set";
  remove.setAttribute("aria-label", `Remove set ${index + 1}`);
  remove.textContent = "×";
  remove.addEventListener("click", () => {
    const list = row.parentElement;
    if (list.children.length <= 1) {
      $$("input", row).forEach((input) => {
        if (input.type === "checkbox") input.checked = false;
        else input.value = "";
      });
      row.classList.remove("is-done");
    } else {
      row.remove();
      [...list.children].forEach((item, itemIndex) => {
        item.dataset.setIndex = itemIndex;
        $(".set-done span", item).textContent = measurement === "completion" ? `Round ${itemIndex + 1}` : itemIndex + 1;
      });
    }
    const card = list.closest(".exercise-card");
    if (card) updateCopyFirstSetButton(card, measurement);
    markWorkoutDirty();
    updateSessionProgress();
  });
  row.append(remove);
  return row;
}

function summarizeSetPreview(measurement, sets = []) {
  if (!sets.length) return "no sets";
  if (measurement === "completion") {
    return `${sets.filter((set) => set.completed).length} / ${sets.length} rounds`;
  }
  const set = sets[0];
  if (measurement === "weight_reps") return `${set.weight || "—"} kg × ${set.reps || "—"}`;
  if (measurement === "weight_distance") return `${set.weight || "—"} kg × ${set.distance || "—"} m`;
  if (measurement === "assisted_reps") return `${set.assistance || "—"} kg assist × ${set.reps || "—"}`;
  if (measurement === "reps") return `${set.reps || "—"} reps`;
  if (measurement === "duration") return formatDuration(Number(set.minutes || 0) * 60 + Number(set.seconds || 0));
  if (measurement === "distance_time") return `${set.distance || "—"} km · ${set.minutes || 0} min`;
  return `${set.distance || "—"} km`;
}

function collectSetRows(card, measurementOverride = "") {
  const measurement = measurementOverride || $(".measurement-select", card).value;
  const fields = MEASUREMENT_TYPES[measurement].fields;
  return $$(".set-row", card).map((row) => {
    const set = { completed: $(".set-done input", row).checked };
    fields.forEach((field) => {
      const input = $(`[data-field="${field.key}"]`, row);
      set[field.key] = input.value === "" ? "" : Number(input.value);
    });
    return set;
  });
}

function hasSetContent(set) {
  return set.completed || Object.entries(set).some(([key, value]) => key !== "completed" && value !== "");
}

function collectWorkoutRecord() {
  const dayKey = dateToDayKey(selectedDate);
  const exercises = {};
  $$(".exercise-card", els.exerciseList).forEach((card) => {
    const sets = collectSetRows(card);
    if (sets.some(hasSetContent)) {
      const exerciseLog = {
        name: card.dataset.variantName || card.dataset.exerciseName,
        measurement: $(".measurement-select", card).value,
        sets,
      };
      if (card.dataset.variantId && card.dataset.variantId !== card.dataset.exerciseId) {
        exerciseLog.variantId = card.dataset.variantId;
        exerciseLog.variantName = card.dataset.variantName;
      }
      if (card.dataset.progression === "pullup") {
        exerciseLog.progressionStep = Number($(".progression-select", card).value);
        exerciseLog.progressionPerformanceQualified =
          card.dataset.progressionCounts === "true" && $(".progression-performance-qualified", card).checked;
        exerciseLog.progressionRecoveryQualified =
          card.dataset.progressionCounts === "true" && $(".progression-recovery-qualified", card).checked;
        exerciseLog.progressionQualified =
          exerciseLog.progressionPerformanceQualified && exerciseLog.progressionRecoveryQualified;
      }
      if (card.dataset.longRunStage) exerciseLog.progressionStage = Number(card.dataset.longRunStage);
      exercises[card.dataset.exerciseId] = exerciseLog;
    }
  });
  const warmup = $$("[data-warmup-index]", els.warmupList).map((input) => input.checked);
  const extraActivities = collectExtraActivities();
  return {
    date: selectedDate,
    dayKey,
    planId: activePlan.id,
    warmup,
    exercises,
    extraActivities,
    response: {
      scaleVersion: 2,
      painDuring: selectedResponseRating("painDuring"),
      painLater: selectedResponseRating("painLater"),
      painNext: selectedResponseRating("painNext"),
      notes: els.sessionNotes.value.trim(),
    },
    updatedAt: new Date().toISOString(),
  };
}

async function saveWorkoutDraftNow() {
  clearTimeout(draftSaveTimer);
  draftSaveTimer = null;
  if (!workoutDirty || !vaultKey) return saveQueue;

  const revision = draftRevision;
  const key = workoutLogKey(selectedDate);
  state.workoutDrafts[key] = {
    ...collectWorkoutRecord(),
    draftedAt: new Date().toISOString(),
  };
  draftSession = null;
  const saved = await persistState();
  if (saved && revision === draftRevision) {
    workoutDirty = false;
    setSaveStatus("Encrypted draft saved", "saved");
  } else if (!saved && revision === draftRevision) {
    setSaveStatus("Draft not saved · keep this page open", "error");
  }
  return saved;
}

async function saveWorkout() {
  clearTimeout(draftSaveTimer);
  draftSaveTimer = null;
  draftRevision += 1;
  workoutDirty = false;
  const key = workoutLogKey(selectedDate);
  state.workoutLogs[key] = collectWorkoutRecord();
  delete state.workoutDrafts[key];
  draftSession = null;
  if (await persistState()) {
    showToast("Workout saved on this device.");
    renderToday();
  }
}

function selectedResponseRating(key) {
  const selected = $(`input[name="response-${key}"]:checked`);
  return selected ? Number(selected.value) : "";
}

function updateResponseDescription(key) {
  const value = selectedResponseRating(key);
  const description = $(`[data-response-description="${key}"]`);
  const option = RESPONSE_SCALE.find((item) => item.value === value);
  description.textContent = option?.description || "No response selected.";
  description.dataset.rating = option?.value ?? "";
}

function renderResponseScales() {
  ["painDuring", "painLater", "painNext"].forEach((key) => {
    const options = $(`[data-response-options="${key}"]`);
    options.replaceChildren();
    RESPONSE_SCALE.forEach((item) => {
      const label = document.createElement("label");
      label.className = "response-option";
      label.innerHTML = `
        <input type="radio" name="response-${key}" value="${item.value}" />
        <span class="response-choice" data-rating="${item.value}">
          <span class="response-face" aria-hidden="true">${item.face}</span>
          <strong>${escapeHtml(item.label)}</strong>
        </span>
      `;
      $("input", label).addEventListener("change", () => updateResponseDescription(key));
      options.append(label);
    });
  });
}

function loadResponseFields(log) {
  ["painDuring", "painLater", "painNext"].forEach((key) => {
    $$(`input[name="response-${key}"]`).forEach((input) => {
      input.checked = false;
    });
    const rating = normalizeResponseRating(log?.response?.[key], log?.response?.scaleVersion);
    const input = rating === "" ? null : $(`input[name="response-${key}"][value="${rating}"]`);
    if (input) input.checked = true;
    updateResponseDescription(key);
  });
  els.sessionNotes.value = log?.response?.notes ?? "";
}

function updateWarmupCount() {
  const inputs = $$("[data-warmup-index]", els.warmupList);
  const complete = inputs.filter((input) => input.checked).length;
  els.warmupCount.textContent = `${complete} / ${inputs.length}`;
  updateSessionProgress();
}

function updateSessionProgress() {
  const checks = [
    ...$$(".set-done input", els.exerciseList),
    ...$$(".set-done input", els.extraActivityList),
  ];
  const completed = checks.filter((check) => check.checked).length;
  const percentage = checks.length ? Math.round((completed / checks.length) * 100) : 0;
  els.progressValue.textContent = `${percentage}%`;
  els.progressRing.style.setProperty("--progress", `${percentage * 3.6}deg`);
}

function loadLastSession() {
  const dayKey = dateToDayKey(selectedDate);
  const previous = findPreviousSession(state.workoutLogs, dayKey, selectedDate, activePlan.id);
  if (!previous) return;
  draftSession = {
    ...structuredClone(previous),
    date: selectedDate,
    dayKey,
    planId: activePlan.id,
    updatedAt: null,
  };
  renderToday();
  markWorkoutDirty();
  showToast(`Loaded ${formatDate(previous.date)}. Review before saving.`);
}

function renderWeek() {
  const base = addDays(startOfWeek(new Date()), Number(state.settings.weekOffset || 0) * 7);
  const end = addDays(base, 6);
  $("#week-range").textContent = `${new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" }).format(base)} – ${new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", year: "numeric" }).format(end)}`;
  const cardio = cardioSummaryForWeek(base);
  $("#week-cardio-time").textContent = formatCardioTime(cardio.seconds);
  $("#week-cardio-distance").textContent = formatCardioDistance(cardio.distance);
  $("#week-cardio-sessions").textContent = cardio.sessions;
  $("#week-cardio-extra").textContent = cardio.extraSessions;
  renderLongRunOptions();
  renderLongRunRoadmap();
  const grid = $("#week-grid");
  grid.replaceChildren();
  DAY_KEYS.forEach((dayKey, index) => {
    const day = activePlan.days[dayKey];
    const date = toIsoDate(addDays(base, index));
    const log = state.workoutLogs[workoutLogKey(date)];
    const completedSets = log
      ? [
          ...Object.values(log.exercises || {}).flatMap((exercise) => exercise.sets || []),
          ...(log.extraActivities || []).flatMap((activity) => activity.sets || []),
        ].filter((set) => set.completed).length
      : 0;
    const card = document.createElement("button");
    card.type = "button";
    card.className = "week-card";
    card.dataset.tone = day.tone;
    card.innerHTML = `
      <span class="week-card-day">${escapeHtml(day.short)}<small>${formatDate(date, { month: "short", day: "numeric" })}</small></span>
      <span class="week-card-copy">
        <small>${escapeHtml(day.kicker)}</small>
        <strong>${escapeHtml(day.focus)}</strong>
        <span>${escapeHtml(day.estimate)}</span>
      </span>
      <span class="week-card-status ${log ? "is-logged" : ""}">${log ? `${completedSets} sets` : dayKey === "sunday" ? "REST" : "OPEN"}</span>
    `;
    card.addEventListener("click", async () => {
      await saveWorkoutDraftNow();
      selectedDate = date;
      draftSession = null;
      renderToday();
      switchView("today");
    });
    grid.append(card);
  });
}

function renderLongRunOptions() {
  const select = $("#long-run-week");
  select.replaceChildren();
  const longRuns = activePlan.longRuns || [];
  const available =
    longRuns.length && (activePlan.id !== BUILT_IN_PLAN.id || Number(state.settings.block) === 1);
  $("#long-run-control").classList.toggle("is-hidden", !available);
  const selectedStage = Math.max(
    1,
    Math.min(longRuns.length || 1, Number(longRunPreviewStage ?? state.settings.longRunWeek) || 1),
  );
  longRuns.forEach((distance, index) => {
    const option = document.createElement("option");
    option.value = index + 1;
    option.textContent = `Stage ${index + 1} · ${distance}`;
    option.selected = selectedStage === index + 1;
    select.append(option);
  });
}

function renderLongRunRoadmap() {
  const container = $("#long-run-roadmap-content");
  const runs = activePlan.longRuns || [];
  const available =
    runs.length && (activePlan.id !== BUILT_IN_PLAN.id || Number(state.settings.block) === 1);
  if (!available) {
    container.replaceChildren();
    return;
  }

  const current = Math.max(1, Math.min(runs.length, Number(state.settings.longRunWeek) || 1));
  const preview = Math.max(1, Math.min(runs.length, Number(longRunPreviewStage ?? current) || current));
  longRunPreviewStage = preview;
  const phases = longRunPhases();
  const previewPhase = longRunPhaseForStage(preview);
  const viewedPhase =
    phases.find((phase) => phase.id === Number(longRunViewedPhase)) || previewPhase || phases[0];
  longRunViewedPhase = viewedPhase.id;
  $("#long-run-stage-count").textContent = `Stage ${current} of ${runs.length}`;
  $("#long-run-week").value = String(preview);

  const phaseRail = phases
    .map((phase) => {
      const currentPhase = current >= phase.start && current <= phase.end;
      const phasePast = phase.end < current;
      return `
        <button
          type="button"
          class="long-run-phase ${phase.id === viewedPhase.id ? "is-viewing" : ""}"
          data-long-run-phase="${phase.id}"
          data-status="${currentPhase ? "current" : phasePast ? "past" : "upcoming"}"
          ${currentPhase ? 'aria-current="step"' : ""}
        >
          <span class="long-run-phase-dot">${phasePast ? "✓" : phase.id}</span>
          <strong>${escapeHtml(phase.name)}</strong>
          <small>${phase.start}–${phase.end}</small>
        </button>
      `;
    })
    .join("");

  const milestones = [];
  for (let stage = viewedPhase.start; stage <= viewedPhase.end; stage += 1) {
    const evaluation = longRunEvaluation(stage);
    const target = targetLongRun(stage);
    const recoveryStage = /cutback|recovery/i.test(target);
    milestones.push(`
      <button
        type="button"
        class="long-run-milestone ${stage === preview ? "is-preview" : ""}"
        data-long-run-stage="${stage}"
        data-status="${stage === current ? "current" : evaluation.status}"
        ${stage === current ? 'aria-current="step"' : ""}
      >
        <span>Stage ${stage}</span>
        <strong>${escapeHtml(target)}</strong>
        <small>${recoveryStage ? "RECOVERY" : escapeHtml(evaluation.label)}</small>
      </button>
    `);
  }

  const evaluation = longRunEvaluation(preview);
  const currentEvaluation = longRunEvaluation(current);
  const target = targetLongRun(preview);
  const actual =
    evaluation.distance > 0
      ? `${numberFormatter.format(evaluation.distance)} km${Number.isFinite(evaluation.rpe) ? ` · RPE ${evaluation.rpe}` : ""}`
      : "No attempt recorded";
  const action =
    preview !== current
      ? `<button class="button button-dark" type="button" data-long-run-action="use">Use Stage ${preview}</button>`
      : `
        <button class="button button-secondary" type="button" data-long-run-action="repeat">Repeat Stage ${current}</button>
        <button
          class="button button-dark"
          type="button"
          data-long-run-action="advance"
          ${currentEvaluation.status !== "ready" || current >= runs.length ? "disabled" : ""}
        >${current >= runs.length ? "Roadmap complete" : `Advance to Stage ${current + 1}`}</button>
      `;

  container.innerHTML = `
    <div class="long-run-phase-rail" aria-label="Long-run phases">${phaseRail}</div>
    <div class="long-run-phase-label">
      <span>Viewing ${escapeHtml(viewedPhase.name)}</span>
      <small>Stages ${viewedPhase.start}–${viewedPhase.end}</small>
    </div>
    <div class="long-run-milestones">${milestones.join("")}</div>
    <article class="long-run-stage-detail" data-status="${evaluation.status}">
      <div class="long-run-stage-detail-head">
        <div>
          <span>Stage ${preview}${preview === current ? " · CURRENT" : " · PREVIEW"}</span>
          <h3>${escapeHtml(target)} easy</h3>
        </div>
        <strong>${escapeHtml(longRunStatusCopy(evaluation))}</strong>
      </div>
      <p>${escapeHtml(evaluation.reason)}</p>
      <div class="long-run-stage-facts">
        <span><small>Latest result</small><strong>${escapeHtml(actual)}</strong></span>
        <span><small>Advance when</small><strong>Target at RPE ≤4 + stable morning response</strong></span>
      </div>
      <div class="long-run-stage-actions">${action}</div>
      <small class="long-run-stage-note">
        Record “Following morning” in Session response. The app recommends; you retain the final decision.
      </small>
    </article>
  `;

  $$("[data-long-run-phase]", container).forEach((button) => {
    button.addEventListener("click", () => {
      longRunViewedPhase = Number(button.dataset.longRunPhase);
      const phase = phases.find((item) => item.id === longRunViewedPhase);
      if (phase && (preview < phase.start || preview > phase.end)) longRunPreviewStage = phase.start;
      renderLongRunOptions();
      renderLongRunRoadmap();
    });
  });
  $$("[data-long-run-stage]", container).forEach((button) => {
    button.addEventListener("click", () => {
      longRunPreviewStage = Number(button.dataset.longRunStage);
      renderLongRunOptions();
      renderLongRunRoadmap();
    });
  });
  $("[data-long-run-action=\"use\"]", container)?.addEventListener("click", async () => {
    const advancingWithoutReadiness = preview > current && currentEvaluation.status !== "ready";
    if (
      advancingWithoutReadiness &&
      !window.confirm("The current stage’s advancement criteria are not confirmed. Use the previewed stage anyway?")
    ) {
      return;
    }
    await setLongRunStage(preview);
  });
  $("[data-long-run-action=\"repeat\"]", container)?.addEventListener("click", () => {
    longRunPreviewStage = current;
    showToast(`Stage ${current} remains current. Repeat it when ready.`);
    renderLongRunOptions();
    renderLongRunRoadmap();
  });
  $("[data-long-run-action=\"advance\"]", container)?.addEventListener("click", async () => {
    await setLongRunStage(current + 1);
  });
}

function renderProgress() {
  const select = $("#stats-exercise");
  const previousSelection = select.value;
  select.replaceChildren();
  getAllExercises(activePlan.days).forEach((exercise) => {
    const option = document.createElement("option");
    option.value = exercise.id;
    option.textContent = exercise.name;
    option.selected = exercise.id === previousSelection;
    select.append(option);
  });
  renderExerciseStats();
  renderCardioStats();
  renderBody();
  renderSleep();
}

function renderExerciseStats() {
  const exerciseId = $("#stats-exercise").value || getAllExercises(activePlan.days)[0]?.id;
  const stats = summarizeExercise(activeWorkoutLogs(), exerciseId);
  $("#stat-sessions").textContent = stats.sessions;
  $("#stat-latest").textContent = stats.latest;
  $("#stat-best").textContent = stats.best;
  $("#stat-volume").textContent = stats.volume;
  const empty = $("#exercise-chart-empty");
  empty.classList.toggle("is-hidden", stats.points.length >= 2);
  drawLineChart($("#exercise-chart"), [{ points: stats.points, color: "#d8ff52" }]);
}

function renderCardioStats() {
  const currentWeek = startOfWeek(new Date());
  const summaries = Array.from({ length: 8 }, (_, index) => {
    const week = addDays(currentWeek, (index - 7) * 7);
    return { week, summary: cardioSummaryForWeek(week) };
  });
  const current = summaries.at(-1).summary;
  $("#cardio-stat-time").textContent = formatCardioTime(current.seconds);
  $("#cardio-stat-distance").textContent = formatCardioDistance(current.distance);
  $("#cardio-stat-sessions").textContent = current.sessions;
  $("#cardio-stat-rpe").textContent =
    current.averageRpe === null ? "—" : numberFormatter.format(current.averageRpe);
  const hasCardio = summaries.some(({ summary }) => summary.sessions > 0);
  $("#cardio-chart-empty").classList.toggle("is-hidden", hasCardio);
  drawLineChart($("#cardio-chart"), [
    {
      points: summaries.map(({ week, summary }) => ({
        date: toIsoDate(week),
        value: Math.round(summary.minutes * 10) / 10,
      })),
      color: "#2f6bff",
    },
  ]);
}

function upsertByDate(array, entry, key = "date") {
  const index = array.findIndex((item) => item[key] === entry[key]);
  if (index >= 0) array[index] = entry;
  else array.push(entry);
  array.sort((a, b) => a[key].localeCompare(b[key]));
}

function renderBody() {
  const entries = [...state.bodyLogs].sort((a, b) => a.date.localeCompare(b.date));
  const list = $("#body-log-list");
  list.replaceChildren();
  entries.slice(-5).reverse().forEach((entry) => {
    const row = document.createElement("div");
    row.className = "log-row";
    row.innerHTML = `
      <span>${formatDate(entry.date)}</span>
      <strong>${numberFormatter.format(entry.weight)} kg</strong>
      <strong>${numberFormatter.format(entry.waist)} cm</strong>
    `;
    list.append(row);
  });
  if (!entries.length) list.innerHTML = `<p class="empty-copy">Your latest measurements will appear here.</p>`;
  drawLineChart($("#body-chart"), [
    { points: entries.map((entry) => ({ date: entry.date, value: Number(entry.weight) })), color: "#2f6bff" },
    { points: entries.map((entry) => ({ date: entry.date, value: Number(entry.waist) })), color: "#ff705d" },
  ]);
}

function renderSleep() {
  const entries = summarizeWeeklySleep(state.sleepLogs, state.dailySleepLogs);
  const list = $("#sleep-log-list");
  list.replaceChildren();
  entries.slice(-5).reverse().forEach((entry) => {
    const row = document.createElement("div");
    row.className = "log-row";
    const total = Number(entry.hours) * Number(entry.nights || 7);
    row.innerHTML = `
      <span>Week of ${formatDate(entry.week)}</span>
      <strong>${numberFormatter.format(entry.hours)} hr / night</strong>
      <strong>${entry.source === "daily" ? `${entry.nights} night${entry.nights === 1 ? "" : "s"} logged` : `${numberFormatter.format(total)} hr total`}</strong>
    `;
    list.append(row);
  });
  if (!entries.length) list.innerHTML = `<p class="empty-copy">Add your weekly average to see the recovery trend.</p>`;
  drawLineChart($("#sleep-chart"), [
    { points: entries.map((entry) => ({ date: entry.week, value: Number(entry.hours) })), color: "#7b61ff" },
  ], { baseline: 7 });
}

function drawLineChart(canvas, datasets, options = {}) {
  const rect = canvas.getBoundingClientRect();
  if (!rect.width) return;
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  const width = Math.max(300, rect.width);
  const height = rect.height || 220;
  canvas.width = width * dpr;
  canvas.height = height * dpr;
  const context = canvas.getContext("2d");
  context.scale(dpr, dpr);
  context.clearRect(0, 0, width, height);

  const padding = { top: 22, right: 18, bottom: 30, left: 18 };
  const plotWidth = width - padding.left - padding.right;
  const plotHeight = height - padding.top - padding.bottom;
  context.strokeStyle = "rgba(23, 33, 27, 0.10)";
  context.lineWidth = 1;
  for (let line = 0; line < 4; line += 1) {
    const y = padding.top + (plotHeight / 3) * line;
    context.beginPath();
    context.moveTo(padding.left, y);
    context.lineTo(width - padding.right, y);
    context.stroke();
  }

  datasets.forEach((dataset) => {
    if (!dataset.points.length) return;
    const values = dataset.points.map((point) => Number(point.value));
    let min = Math.min(...values);
    let max = Math.max(...values);
    if (options.baseline) {
      min = Math.min(min, options.baseline);
      max = Math.max(max, options.baseline);
    }
    const range = max - min || Math.max(max * 0.1, 1);
    min -= range * 0.12;
    max += range * 0.12;

    if (options.baseline) {
      const y = padding.top + plotHeight - ((options.baseline - min) / (max - min)) * plotHeight;
      context.save();
      context.setLineDash([5, 5]);
      context.strokeStyle = "rgba(23, 33, 27, 0.35)";
      context.beginPath();
      context.moveTo(padding.left, y);
      context.lineTo(width - padding.right, y);
      context.stroke();
      context.restore();
    }

    const coords = dataset.points.map((point, index) => ({
      x: padding.left + (dataset.points.length === 1 ? plotWidth / 2 : (index / (dataset.points.length - 1)) * plotWidth),
      y: padding.top + plotHeight - ((Number(point.value) - min) / (max - min)) * plotHeight,
    }));
    context.strokeStyle = dataset.color;
    context.lineWidth = 3;
    context.lineJoin = "round";
    context.lineCap = "round";
    context.beginPath();
    coords.forEach((point, index) => index ? context.lineTo(point.x, point.y) : context.moveTo(point.x, point.y));
    context.stroke();
    coords.forEach((point) => {
      context.fillStyle = "#f8f5ee";
      context.strokeStyle = dataset.color;
      context.lineWidth = 3;
      context.beginPath();
      context.arc(point.x, point.y, 4.5, 0, Math.PI * 2);
      context.fill();
      context.stroke();
    });
  });
}

async function exportData() {
  await saveWorkoutDraftNow();
  const payload = {
    ...state,
    version: APP_VERSION,
    exportedAt: new Date().toISOString(),
    app: "Form / Flow",
  };
  const blob = new Blob([JSON.stringify(payload, null, 2)], { type: "application/json" });
  const link = document.createElement("a");
  const url = URL.createObjectURL(blob);
  link.href = url;
  link.download = `form-flow-backup-${toIsoDate()}.json`;
  document.body.append(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
  showToast("Backup downloaded.");
}

async function importData(file) {
  if (!file) return;
  try {
    const parsed = JSON.parse(await file.text());
    const result = validateBackup(parsed);
    if (!result.valid) throw new Error(result.reason);
    const approved = window.confirm(
      "This will replace the records stored in this browser. Continue only if you have exported anything you want to keep.",
    );
    if (!approved) return;
    state = result.state;
    draftSession = null;
    await changePlan(state.settings.activePlanId || "form-flow", false, true);
    showToast("Backup restored.");
  } catch (error) {
    showToast(error.message || "That backup could not be imported.", "error");
  } finally {
    $("#import-data").value = "";
  }
}

async function eraseLocalData() {
  const approved = window.confirm(
    "Permanently erase every workout, body measurement, sleep record, and preference stored by this app in this browser?",
  );
  if (!approved) return;
  localStorage.removeItem(VAULT_STORAGE_KEY);
  localStorage.removeItem(STORAGE_KEY);
  localStorage.setItem(UNLOCK_BLOCK_STORAGE_KEY, "1");
  await clearRememberedUnlock();
  scheduleUnlockExpiry();
  vaultKey = null;
  vaultSalt = null;
  window.location.reload();
}

async function lockApp() {
  await saveWorkoutDraftNow();
  await saveQueue;
  localStorage.setItem(UNLOCK_BLOCK_STORAGE_KEY, "1");
  await clearRememberedUnlock();
  scheduleUnlockExpiry();
  vaultKey = null;
  vaultSalt = null;
  state = createDefaultState();
  window.location.reload();
}

const timer = {
  total: 90,
  remaining: 90,
  running: false,
  interval: null,
  endsAt: null,
  finishedTimeout: null,
};

function clearTimerFinishedState() {
  clearTimeout(timer.finishedTimeout);
  timer.finishedTimeout = null;
  $("#rest-timer").classList.remove("is-finished");
  $("#timer-label").textContent = "REST";
  syncTimerVisibility();
}

function syncTimerVisibility() {
  const restTimer = $("#rest-timer");
  restTimer.classList.toggle(
    "is-context-hidden",
    !shouldShowRestTimer(activeView, timer.running, restTimer.classList.contains("is-finished")),
  );
}

function setTimer(seconds, start = false) {
  clearInterval(timer.interval);
  clearTimerFinishedState();
  timer.total = seconds;
  timer.remaining = seconds;
  timer.running = false;
  timer.endsAt = null;
  updateTimerUi();
  if (start) startTimer();
}

function startTimer() {
  clearTimerFinishedState();
  if (timer.running) {
    timer.remaining = Math.max(0, Math.ceil((timer.endsAt - Date.now()) / 1000));
    timer.running = false;
    clearInterval(timer.interval);
    updateTimerUi();
    return;
  }
  if (timer.remaining <= 0) timer.remaining = timer.total;
  timer.running = true;
  timer.endsAt = Date.now() + timer.remaining * 1000;
  timer.interval = setInterval(() => {
    timer.remaining = Math.max(0, Math.ceil((timer.endsAt - Date.now()) / 1000));
    updateTimerUi();
    if (timer.remaining <= 0) {
      clearInterval(timer.interval);
      timer.running = false;
      timerFinished();
    }
  }, 250);
  updateTimerUi();
}

function updateTimerUi() {
  $("#timer-time").textContent = formatTimer(timer.remaining);
  $("#timer-play").textContent = timer.running ? "Ⅱ" : "▶";
  $("#timer-play").setAttribute("aria-label", timer.running ? "Pause rest timer" : "Start rest timer");
  $("#rest-timer").style.setProperty("--timer-progress", `${timer.total ? (timer.remaining / timer.total) * 360 : 0}deg`);
  $$("[data-timer]").forEach((button) => button.classList.toggle("is-active", Number(button.dataset.timer) === timer.total));
  syncTimerVisibility();
}

function formatTimer(seconds) {
  return `${String(Math.floor(seconds / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
}

function timerFinished() {
  updateTimerUi();
  $("#rest-timer").classList.add("is-finished");
  $("#timer-label").textContent = "REST DONE";
  syncTimerVisibility();
  timer.finishedTimeout = setTimeout(clearTimerFinishedState, 5000);
  try {
    const audio = new AudioContext();
    const oscillator = audio.createOscillator();
    const gain = audio.createGain();
    oscillator.frequency.value = 740;
    gain.gain.setValueAtTime(0.08, audio.currentTime);
    gain.gain.exponentialRampToValueAtTime(0.001, audio.currentTime + 0.35);
    oscillator.connect(gain).connect(audio.destination);
    oscillator.start();
    oscillator.stop(audio.currentTime + 0.35);
  } catch {
    // Visual and vibration feedback remain available if audio is blocked.
  }
  navigator.vibrate?.([120, 80, 120]);
  showToast("Rest complete. Next set.");
}

function bindEvents() {
  $$("[data-nav]").forEach((button) => button.addEventListener("click", async () => {
    if (button.dataset.nav === "today") {
      await saveWorkoutDraftNow();
      selectedDate = toIsoDate();
      draftSession = null;
      renderToday();
    }
    switchView(button.dataset.nav);
  }));
  $("#plan-select").addEventListener("change", async (event) => {
    await saveWorkoutDraftNow();
    await changePlan(event.target.value);
  });
  els.trainingDate.addEventListener("change", async () => {
    const nextDate = els.trainingDate.value || toIsoDate();
    await saveWorkoutDraftNow();
    selectedDate = nextDate;
    draftSession = null;
    renderToday();
  });
  $$("[data-block]").forEach((button) => button.addEventListener("click", async () => {
    const nextBlock = Number(button.dataset.block);
    if (
      nextBlock === 2 &&
      Number(state.settings.block) !== 2 &&
      activePlan.id === BUILT_IN_PLAN.id &&
      qualifiedTenKmRuns() < 2 &&
      !window.confirm(
        `Block 2 is recommended after two 10 km runs at RPE 4 or below with a Comfortable or Mild following-morning response. You currently have ${qualifiedTenKmRuns()} of 2. Switch anyway?`,
      )
    ) {
      return;
    }
    await saveWorkoutDraftNow();
    state.settings.block = nextBlock;
    await persistState();
    renderToday();
  }));
  els.warmupList.addEventListener("change", updateWarmupCount);
  els.loadSession.addEventListener("click", loadLastSession);
  $("#save-workout").addEventListener("click", saveWorkout);
  $("#daily-checkin-reminder").addEventListener("click", () => openDailyCheckIn());
  $("#daily-checkin-close").addEventListener("click", dismissDailyCheckIn);
  $("#daily-checkin-later").addEventListener("click", () => void deferDailyCheckIn());
  $("#daily-checkin-skip").addEventListener("click", () => void skipDailyCheckIn());
  $("#daily-checkin-unknown").addEventListener("click", () => void saveDailyCheckInAnswer({ unknown: true }));
  $("#daily-checkin-save").addEventListener("click", (event) => {
    if (event.currentTarget.dataset.action === "done") closeDailyCheckIn();
    else void saveDailyCheckInAnswer();
  });
  $("#daily-checkin-dialog").addEventListener("cancel", (event) => {
    event.preventDefault();
    dismissDailyCheckIn();
  });
  $("#daily-checkin-dialog").addEventListener("keydown", (event) => {
    if (event.key === "Enter" && event.target.matches("#daily-sleep-hours")) {
      event.preventDefault();
      void saveDailyCheckInAnswer();
    }
  });
  $("#view-today").addEventListener("input", (event) => {
    if (event.target.matches(".set-row input, #session-notes")) markWorkoutDirty();
  });
  $("#view-today").addEventListener("change", (event) => {
    if (
      event.target.matches(
        ".set-row input, [data-warmup-index], .response-option input, .progression-performance-qualified, .progression-recovery-qualified",
      )
    ) {
      markWorkoutDirty();
    }
  });

  $("#add-extra-activity").addEventListener("click", openExtraActivityDialog);
  $("#extra-activity-form").addEventListener("submit", addExtraActivity);
  $("#extra-activity-cancel").addEventListener("click", closeExtraActivityDialog);
  $("#extra-activity-cancel-icon").addEventListener("click", closeExtraActivityDialog);
  $("#forget-saved-activity").addEventListener("click", forgetSavedActivity);
  $("#extra-activity-type").addEventListener("change", (event) => {
    $("#extra-activity-name").value =
      event.target.value === "custom" ? "" : ACTIVITY_TYPE_LABELS[event.target.value];
  });
  $("#saved-activity-select").addEventListener("change", (event) => {
    const activity = state.savedActivities.find((item) => item.id === event.target.value);
    if (!activity) {
      setNewActivityDefaults();
      renderSavedActivityOptions();
      return;
    }
    $("#extra-activity-type").value = activity.type;
    $("#extra-activity-name").value = activity.name;
    $("#extra-activity-measurement").value = activity.measurement;
    $("#save-extra-activity").checked = false;
    renderSavedActivityOptions(activity.id);
  });

  $("#previous-week").addEventListener("click", () => {
    state.settings.weekOffset -= 1;
    persistState();
    renderWeek();
  });
  $("#next-week").addEventListener("click", () => {
    state.settings.weekOffset += 1;
    persistState();
    renderWeek();
  });
  $("#current-week").addEventListener("click", () => {
    state.settings.weekOffset = 0;
    persistState();
    renderWeek();
  });
  $("#long-run-week").addEventListener("change", (event) => {
    longRunPreviewStage = Number(event.target.value);
    longRunViewedPhase = longRunPhaseForStage(longRunPreviewStage)?.id || 1;
    renderLongRunRoadmap();
  });

  $("#stats-exercise").addEventListener("change", renderExerciseStats);
  $("#body-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    upsertByDate(state.bodyLogs, {
      date: $("#body-date").value,
      weight: Number($("#body-weight").value),
      waist: Number($("#body-waist").value),
    });
    const saved = await persistState();
    renderBody();
    event.target.reset();
    $("#body-date").value = toIsoDate();
    if (saved) showToast("Body measurements saved.");
  });
  $("#sleep-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    upsertByDate(state.sleepLogs, {
      week: $("#sleep-week").value,
      hours: Number($("#sleep-hours").value),
    }, "week");
    const saved = await persistState();
    renderSleep();
    event.target.reset();
    $("#sleep-week").value = toIsoDate(startOfWeek(new Date()));
    if (saved) showToast("Weekly sleep saved.");
  });

  $("#export-data").addEventListener("click", exportData);
  $("#import-data").addEventListener("change", (event) => importData(event.target.files[0]));
  $("#erase-data").addEventListener("click", eraseLocalData);
  $("#lock-app").addEventListener("click", lockApp);

  $("#timer-toggle").addEventListener("click", () => {
    const expanded = $("#rest-timer").classList.toggle("is-expanded");
    $("#timer-toggle").setAttribute("aria-expanded", String(expanded));
  });
  $("#timer-play").addEventListener("click", startTimer);
  $("#timer-reset").addEventListener("click", () => setTimer(timer.total));
  $$("[data-timer]").forEach((button) => button.addEventListener("click", () => setTimer(Number(button.dataset.timer))));

  window.addEventListener("resize", () => {
    cancelAnimationFrame(resizeFrame);
    resizeFrame = requestAnimationFrame(() => {
      if (activeView === "progress") renderProgress();
    });
  });
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") saveWorkoutDraftNow();
  });
  window.addEventListener("pagehide", () => {
    saveWorkoutDraftNow();
  });
}

async function init() {
  await initializeVault();
  document.body.dataset.activeView = activeView;
  els.trainingDate.value = selectedDate;
  $("#body-date").value = selectedDate;
  $("#sleep-week").value = toIsoDate(startOfWeek(new Date()));
  renderResponseScales();
  bindEvents();
  await discoverPlans();
  const requestedPlan = state.settings.activePlanId || "form-flow";
  try {
    activePlan = await loadPlan(requestedPlan);
  } catch {
    activePlan = BUILT_IN_PLAN;
    state.settings.activePlanId = BUILT_IN_PLAN.id;
    persistState();
  }
  renderPlanSelect();
  renderLongRunOptions();
  renderToday();
  updateTimerUi();
  maybeOpenDailyCheckIn();
}

init();
