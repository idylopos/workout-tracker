import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { writeFile } from "node:fs/promises";
import {
  EXERCISE_GUIDANCE,
  LONG_RUNS,
  MEASUREMENT_TYPES,
  PULL_UP_STEPS,
  WEEK_PLAN,
} from "../lib.js";

const root = resolve(import.meta.dirname, "..");

function measurementLabel(measurement) {
  return MEASUREMENT_TYPES[measurement]?.label || measurement;
}

function prescription(exercise) {
  if (exercise.id === "easy-run") {
    return "Block 1: 30 min easy at RPE 2–4 · Block 2: 30–40 min easy + 4 × 20-sec relaxed strides";
  }
  if (exercise.id === "run-2") {
    return "Block 1: 25–35 min easy · Block 2: alternate tempo and intervals; run first and separate sessions by about 6 hours";
  }
  if (exercise.id === "long-run") {
    return "Block 1: use the 16-week progression below · Block 2: 8–10 km easy; walk breaks allowed";
  }
  return exercise.prescription;
}

function guidanceFor(exercise) {
  return exercise.guidance || EXERCISE_GUIDANCE[exercise.id];
}

function exerciseMarkdown(exercise, index) {
  const guidance = guidanceFor(exercise);
  const optional = exercise.optional ? " · optional" : "";
  const rest = exercise.rest ? ` · rest ${Math.round(exercise.rest / 60)} min` : "";
  const lines = [
    `${index}. **${exercise.name}** — ${prescription(exercise)}${optional}${rest}`,
    `   - Log as: ${measurementLabel(exercise.measurement)}.`,
  ];
  if (guidance) {
    lines.push(`   - **Setup:** ${guidance.setup}`);
    lines.push(`   - **Do:** ${guidance.action}`);
    lines.push(`   - **Watch:** ${guidance.watch}`);
    if (guidance.option) lines.push(`   - **Alternative:** ${guidance.option}`);
  }
  return lines.join("\n");
}

function dayMarkdown(dayKey, day) {
  const warmup = day.warmup.length ? day.warmup.map((item) => `- ${item}`).join("\n") : "No planned warm-up.";
  const exercises = day.exercises.length
    ? day.exercises.map((exercise, index) => exerciseMarkdown(exercise, index + 1)).join("\n\n")
    : "Complete rest. Ordinary relaxed movement is fine.";
  return [
    `### ${day.label} — ${day.focus}`,
    `**Theme:** ${day.kicker}  `,
    `**Estimated time:** ${day.estimate}  `,
    `**Sequence note:** ${day.sequenceNote}`,
    "",
    "#### Warm-up",
    warmup,
    "",
    "#### Exercises and activities",
    exercises,
  ].join("\n");
}

function pullUpMarkdown() {
  return PULL_UP_STEPS.map(
    (step) =>
      `- **${step.label}** — ${step.title}: ${step.prescription}. Target: ${step.target} Next: ${step.next}`,
  ).join("\n");
}

export function renderWorkoutPlanMarkdown() {
  const days = Object.entries(WEEK_PLAN).map(([dayKey, day]) => dayMarkdown(dayKey, day)).join("\n\n");
  return `<!-- AUTO-GENERATED from lib.js (WEEK_PLAN). Run npm run sync-plan after changing the built-in plan. -->

# Form / Flow — Workout Tracker plan

This document is the readable version of the built-in plan used by the public Workout Tracker. The app remains the
place to log sets, cardio, body measurements, sleep, pain response, and encrypted drafts.

## Weekly rules

- **Sunday:** complete rest.
- **Running:** Tuesday is fixed; Thursday is the second run; Saturday is the long run.
- **Cycling:** Monday bicycle HIIT is a later session, separated from lifting by at least 6 hours. Wednesday Zone 2
  cycling is optional and only for a well-recovered day.
- **Swimming:** Saturday technique-focused swimming at easy effort.
- **Shoulder:** use comfortable paths. Do not force clicking, pinching, or the Friday raise if it remains uncomfortable.
- **Knee:** track the response during training, later that day, and the following morning. Reduce load, range, or volume
  when symptoms clearly rise.

## Block 1 and Block 2

### Block 1 — Build to a comfortable 10 km

Stay here until 10 km feels repeatable and your joints and usual energy return to baseline by the following morning.
Keep easy runs conversational and follow the long-run progression.

### Block 2 — Improve comfortable 10 km speed

Start only after Block 1 is achieved. Tuesday adds relaxed strides; Thursday alternates controlled tempo and interval
work; Saturday stays at 8–10 km easy.

## Weekly plan

${days}

## Saturday long-run progression — Block 1

${LONG_RUNS.map((distance, index) => `- Week ${index + 1}: ${distance} easy`).join("\n")}

Repeat a week when the next-morning response is not stable. Walk breaks are allowed.

## Pull-up progression — choose by performance

Choose the step that matches your current ability; it is not a calendar-week requirement. Mark the advancement check
only after two successful sessions meeting the step target, with clean technique, at least one rep in reserve, and no
worse joint response the following morning.

${pullUpMarkdown()}

## Session response

- **Comfortable:** no meaningful pain or at normal baseline.
- **Mild:** noticeable but stable; movement and technique stayed normal.
- **Adjust:** clearly rising or more noticeable; reduce load, range, or volume next time.
- **Stop:** sharp, limiting, or changed your movement; stop the provoking exercise.
- **Red flag:** swelling, locking, giving way, night pain, or persistent worsening; seek an assessment.

This is informational exercise guidance, not a diagnosis or individualized medical clearance. Stop and seek professional
assessment for persistent or worsening symptoms.
`;
}

export async function writeWorkoutPlanMarkdown(workspaceRoot = root) {
  await writeFile(resolve(workspaceRoot, "WORKOUT_PLAN.md"), renderWorkoutPlanMarkdown(), "utf8");
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await writeWorkoutPlanMarkdown();
}
