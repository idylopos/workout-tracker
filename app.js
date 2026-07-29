import {
  APP_VERSION,
  LONG_RUNS,
  MEASUREMENT_TYPES,
  STORAGE_KEY,
  WEEK_PLAN,
  addDays,
  createDefaultState,
  dateToDayKey,
  findPreviousExerciseLog,
  findPreviousSession,
  formatDuration,
  getAllExercises,
  normalizeState,
  startOfWeek,
  summarizeExercise,
  toIsoDate,
  validateBackup,
} from "./lib.js";
import {
  PBKDF2_ITERATIONS,
  VAULT_STORAGE_KEY,
  createVault,
  encryptState,
  unlockVault,
} from "./crypto-vault.js";

const DAY_KEYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"];
const numberFormatter = new Intl.NumberFormat(undefined, { maximumFractionDigits: 1 });
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
  loadSession: $("#load-session-button"),
  longRunCallout: $("#long-run-callout"),
  painDuring: $("#pain-during"),
  painLater: $("#pain-later"),
  painNext: $("#pain-next"),
  sessionNotes: $("#session-notes"),
  saveStatus: $("#save-status"),
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

function openVaultDialog(mode, storedVault = null, initialState = null) {
  const dialog = $("#privacy-dialog");
  const form = $("#privacy-form");
  const title = $("#privacy-dialog-title");
  const copy = $("#privacy-dialog-copy");
  const passphrase = $("#privacy-passphrase");
  const confirmWrap = $("#privacy-confirm-wrap");
  const confirmPassphrase = $("#privacy-confirm");
  const error = $("#privacy-error");
  const submit = $("#privacy-submit");
  const reset = $("#privacy-reset");
  const creating = mode === "create";

  title.textContent = creating ? "Create your privacy passphrase" : "Unlock your records";
  copy.textContent = creating
    ? "Your records will be encrypted before browser storage. Use at least 10 characters and keep this passphrase somewhere safe—it cannot be recovered."
    : "Enter your passphrase. It stays in memory for this browser session and is never stored or uploaded.";
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
        resolve({ kind: "success", result });
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
      const access = await openVaultDialog("unlock", parsed);
      if (access.kind === "erase") {
        localStorage.removeItem(VAULT_STORAGE_KEY);
        localStorage.removeItem(STORAGE_KEY);
        continue;
      }
      state = normalizeState(access.result.state);
      vaultKey = access.result.key;
      vaultSalt = access.result.salt;
      vaultIterations = access.result.iterations;
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
    return;
  }
}

function formatDate(dateString, options = { weekday: "short", month: "short", day: "numeric" }) {
  return new Intl.DateTimeFormat(undefined, options).format(new Date(`${dateString}T12:00:00`));
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
  $$(".view").forEach((section) => section.classList.toggle("is-active", section.id === `view-${view}`));
  $$("[data-nav]").forEach((button) => button.classList.toggle("is-active", button.dataset.nav === view));
  window.scrollTo({ top: 0, behavior: "smooth" });
  if (view === "week") renderWeek();
  if (view === "progress") renderProgress();
}

function currentLog() {
  if (draftSession?.date === selectedDate) return draftSession;
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

function targetLongRun() {
  const runs = activePlan.longRuns || [];
  return runs[Math.max(0, Math.min(runs.length - 1, Number(state.settings.longRunWeek || 1) - 1))];
}

function renderToday() {
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
    button.classList.toggle("is-active", Number(button.dataset.block) === Number(state.settings.block));
  });

  if (activePlan.longRuns?.length && dayKey === activePlan.longRunDay && Number(state.settings.block) === 1) {
    els.longRunCallout.classList.remove("is-hidden");
    els.longRunCallout.innerHTML = `<span>PROGRESSION WEEK ${Number(state.settings.longRunWeek)}</span><strong>${escapeHtml(targetLongRun())}</strong><small>Use the plan’s progression guidance and repeat a week when recovery is not stable.</small>`;
  } else {
    els.longRunCallout.classList.add("is-hidden");
    els.longRunCallout.replaceChildren();
  }

  renderWarmup(day, log);
  renderExercises(day, log);
  loadResponseFields(log);
  updateSessionProgress();

  const saved = state.workoutLogs[workoutLogKey(selectedDate)];
  if (draftSession) {
    els.saveStatus.textContent = "Previous session loaded — review, then save";
  } else if (saved) {
    els.saveStatus.textContent = `Saved ${formatDate(saved.updatedAt?.slice(0, 10) || selectedDate)}`;
  } else {
    els.saveStatus.textContent = day.exercises.length ? "Not saved yet" : "Rest day";
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

function createExerciseCard(exercise, index, savedExercise) {
  const card = $("#exercise-template").content.firstElementChild.cloneNode(true);
  card.dataset.exerciseId = exercise.id;
  card.dataset.defaultSets = exercise.sets;
  card.dataset.rest = exercise.rest;
  card.dataset.exerciseName = exercise.name;

  $(".exercise-number", card).textContent = String(index + 1).padStart(2, "0");
  $(".exercise-name", card).textContent = exercise.name;
  $(".exercise-prescription", card).textContent = exercise.prescription;
  $(".exercise-tags", card).innerHTML = `
    <span>${escapeHtml(exercise.section || exercise.category)}</span>
    ${exercise.optional ? "<span class=\"tag-optional\">OPTIONAL</span>" : ""}
  `;

  const measurement =
    savedExercise?.measurement || state.exerciseConfigs[exerciseConfigKey(exercise.id)] || exercise.measurement;
  const select = $(".measurement-select", card);
  Object.entries(MEASUREMENT_TYPES).forEach(([key, config]) => {
    const option = document.createElement("option");
    option.value = key;
    option.textContent = config.label;
    option.selected = key === measurement;
    select.append(option);
  });

  const previous = findPreviousExerciseLog(state.workoutLogs, exercise.id, selectedDate, activePlan.id);
  const previousLine = $(".previous-line", card);
  if (previous) {
    previousLine.textContent = `Last: ${formatDate(previous.date)} · ${summarizeSetPreview(previous.measurement, previous.sets)}`;
  } else {
    previousLine.textContent = "No earlier log for this exercise.";
    $(".load-previous", card).disabled = true;
  }

  const sets = savedExercise?.sets?.length ? savedExercise.sets : Array.from({ length: exercise.sets }, () => ({}));
  renderSetRows(card, measurement, sets);

  $(".exercise-toggle", card).addEventListener("click", (event) => {
    const button = event.currentTarget;
    const collapsed = card.classList.toggle("is-collapsed");
    button.setAttribute("aria-expanded", String(!collapsed));
  });
  select.addEventListener("change", () => {
    state.exerciseConfigs[exerciseConfigKey(exercise.id)] = select.value;
    persistState();
    renderSetRows(card, select.value, Array.from({ length: Number(card.dataset.defaultSets) }, () => ({})));
    updateSessionProgress();
  });
  $(".load-previous", card).addEventListener("click", () => {
    const earlier = findPreviousExerciseLog(state.workoutLogs, exercise.id, selectedDate, activePlan.id);
    if (!earlier) return;
    select.value = earlier.measurement;
    state.exerciseConfigs[exerciseConfigKey(exercise.id)] = earlier.measurement;
    persistState();
    renderSetRows(card, earlier.measurement, structuredClone(earlier.sets));
    showToast(`${exercise.name}: previous values loaded.`);
    updateSessionProgress();
  });
  $(".add-set", card).addEventListener("click", () => {
    const setList = $(".set-list", card);
    setList.append(createSetRow(select.value, setList.children.length, {}, Number(card.dataset.rest)));
  });
  return card;
}

function renderSetRows(card, measurement, sets) {
  const setList = $(".set-list", card);
  setList.replaceChildren();
  sets.forEach((set, index) => setList.append(createSetRow(measurement, index, set, Number(card.dataset.rest))));
}

function createSetRow(measurement, index, values, restSeconds) {
  const row = document.createElement("div");
  row.className = "set-row";
  row.dataset.setIndex = index;
  row.style.setProperty("--field-count", MEASUREMENT_TYPES[measurement].fields.length);

  const done = document.createElement("label");
  done.className = "set-done";
  done.innerHTML = `
    <input type="checkbox" aria-label="Mark set ${index + 1} complete" ${values.completed ? "checked" : ""} />
    <span>${index + 1}</span>
  `;
  done.querySelector("input").addEventListener("change", (event) => {
    row.classList.toggle("is-done", event.target.checked);
    if (event.target.checked && restSeconds > 0) setTimer(restSeconds, true);
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
        $(".set-done span", item).textContent = itemIndex + 1;
      });
    }
    updateSessionProgress();
  });
  row.append(remove);
  return row;
}

function summarizeSetPreview(measurement, sets = []) {
  if (!sets.length) return "no sets";
  const set = sets[0];
  if (measurement === "weight_reps") return `${set.weight || "—"} kg × ${set.reps || "—"}`;
  if (measurement === "assisted_reps") return `${set.assistance || "—"} kg assist × ${set.reps || "—"}`;
  if (measurement === "reps") return `${set.reps || "—"} reps`;
  if (measurement === "duration") return formatDuration(Number(set.minutes || 0) * 60 + Number(set.seconds || 0));
  if (measurement === "distance_time") return `${set.distance || "—"} km · ${set.minutes || 0} min`;
  return `${set.distance || "—"} km`;
}

function collectSetRows(card) {
  const measurement = $(".measurement-select", card).value;
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

async function saveWorkout() {
  const dayKey = dateToDayKey(selectedDate);
  const exercises = {};
  $$(".exercise-card", els.exerciseList).forEach((card) => {
    const sets = collectSetRows(card);
    if (sets.some(hasSetContent)) {
      exercises[card.dataset.exerciseId] = {
        name: card.dataset.exerciseName,
        measurement: $(".measurement-select", card).value,
        sets,
      };
    }
  });
  const warmup = $$("[data-warmup-index]", els.warmupList).map((input) => input.checked);
  state.workoutLogs[workoutLogKey(selectedDate)] = {
    date: selectedDate,
    dayKey,
    planId: activePlan.id,
    warmup,
    exercises,
    response: {
      painDuring: valueOrBlank(els.painDuring.value),
      painLater: valueOrBlank(els.painLater.value),
      painNext: valueOrBlank(els.painNext.value),
      notes: els.sessionNotes.value.trim(),
    },
    updatedAt: new Date().toISOString(),
  };
  draftSession = null;
  if (await persistState()) {
    showToast("Workout saved on this device.");
    renderToday();
  }
}

function valueOrBlank(value) {
  return value === "" ? "" : Number(value);
}

function loadResponseFields(log) {
  els.painDuring.value = log?.response?.painDuring ?? "";
  els.painLater.value = log?.response?.painLater ?? "";
  els.painNext.value = log?.response?.painNext ?? "";
  els.sessionNotes.value = log?.response?.notes ?? "";
}

function updateWarmupCount() {
  const inputs = $$("[data-warmup-index]", els.warmupList);
  const complete = inputs.filter((input) => input.checked).length;
  els.warmupCount.textContent = `${complete} / ${inputs.length}`;
  updateSessionProgress();
}

function updateSessionProgress() {
  const checks = $$(".set-done input", els.exerciseList);
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
  showToast(`Loaded ${formatDate(previous.date)}. Review before saving.`);
}

function renderWeek() {
  const base = addDays(startOfWeek(new Date()), Number(state.settings.weekOffset || 0) * 7);
  const end = addDays(base, 6);
  $("#week-range").textContent = `${new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" }).format(base)} – ${new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", year: "numeric" }).format(end)}`;
  const grid = $("#week-grid");
  grid.replaceChildren();
  DAY_KEYS.forEach((dayKey, index) => {
    const day = activePlan.days[dayKey];
    const date = toIsoDate(addDays(base, index));
    const log = state.workoutLogs[workoutLogKey(date)];
    const completedSets = log
      ? Object.values(log.exercises || {}).flatMap((exercise) => exercise.sets || []).filter((set) => set.completed).length
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
    card.addEventListener("click", () => {
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
  $("#long-run-control").classList.toggle("is-hidden", !longRuns.length);
  longRuns.forEach((distance, index) => {
    const option = document.createElement("option");
    option.value = index + 1;
    option.textContent = `Week ${index + 1} · ${distance}`;
    option.selected = Number(state.settings.longRunWeek) === index + 1;
    select.append(option);
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
  const entries = [...state.sleepLogs].sort((a, b) => a.week.localeCompare(b.week));
  const list = $("#sleep-log-list");
  list.replaceChildren();
  entries.slice(-5).reverse().forEach((entry) => {
    const row = document.createElement("div");
    row.className = "log-row";
    row.innerHTML = `
      <span>Week of ${formatDate(entry.week)}</span>
      <strong>${numberFormatter.format(entry.hours)} hr / night</strong>
      <strong>${numberFormatter.format(entry.hours * 7)} hr total</strong>
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

function exportData() {
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

function eraseLocalData() {
  const approved = window.confirm(
    "Permanently erase every workout, body measurement, sleep record, and preference stored by this app in this browser?",
  );
  if (!approved) return;
  localStorage.removeItem(VAULT_STORAGE_KEY);
  localStorage.removeItem(STORAGE_KEY);
  vaultKey = null;
  vaultSalt = null;
  window.location.reload();
}

async function lockApp() {
  await saveQueue;
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
};

function setTimer(seconds, start = false) {
  clearInterval(timer.interval);
  timer.total = seconds;
  timer.remaining = seconds;
  timer.running = false;
  timer.endsAt = null;
  updateTimerUi();
  if (start) startTimer();
}

function startTimer() {
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
}

function formatTimer(seconds) {
  return `${String(Math.floor(seconds / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
}

function timerFinished() {
  updateTimerUi();
  $("#rest-timer").classList.add("is-finished");
  setTimeout(() => $("#rest-timer").classList.remove("is-finished"), 1500);
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
  $$("[data-nav]").forEach((button) => button.addEventListener("click", () => switchView(button.dataset.nav)));
  $("#plan-select").addEventListener("change", (event) => changePlan(event.target.value));
  els.trainingDate.addEventListener("change", () => {
    selectedDate = els.trainingDate.value || toIsoDate();
    draftSession = null;
    renderToday();
  });
  $$("[data-block]").forEach((button) => button.addEventListener("click", () => {
    state.settings.block = Number(button.dataset.block);
    persistState();
    renderToday();
  }));
  els.warmupList.addEventListener("change", updateWarmupCount);
  els.loadSession.addEventListener("click", loadLastSession);
  $("#save-workout").addEventListener("click", saveWorkout);

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
    state.settings.longRunWeek = Number(event.target.value);
    persistState();
    renderToday();
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
}

async function init() {
  await initializeVault();
  els.trainingDate.value = selectedDate;
  $("#body-date").value = selectedDate;
  $("#sleep-week").value = toIsoDate(startOfWeek(new Date()));
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
}

init();
