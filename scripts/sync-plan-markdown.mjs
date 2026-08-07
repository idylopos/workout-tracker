import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { writeFile } from "node:fs/promises";
import {
  EXERCISE_GUIDANCE,
  LONG_RUN_PHASES,
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
    return "Block 1: use the 16-stage progression below · Block 2: 8–10 km easy; walk breaks allowed";
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

The tracker can remember a non-exportable browser unlock key for a fixed two-hour window. It never stores the
passphrase, and **Lock app** clears the remembered key immediately.

During logging, **Use Last** keeps today's planned set count, copies reusable values from the prior workout, and clears
all completion, effort, and pull-up qualification fields. When today has more sets than the prior workout, the last
prior set provides starting values for the additional rows. Importing values never marks today's exercise complete.

## Mobility placement and limits

Monday's 3D lunges are a brief dynamic rehearsal before the squat and jump sequence, not extra working sets. Wednesday
Mobility A is performed last (after optional cycling) as one easy round of movement practice. The five-exercise sequence
itself has not been shown to be uniquely superior: cat–cow, frog rock-backs, lateral lunges, and seated good mornings
practice comfortable motion, while bridge leg lifts primarily train trunk–pelvic stability.

Dynamic stretching can improve acute range of motion and may support subsequent dynamic performance, but lasting
flexibility requires repeated training over time. Resistance training through a comfortable range can also improve
range of motion. Post-exercise stretching should not be treated as a recovery method because trials do not show
meaningful improvements in soreness, strength recovery, or performance.

Evidence: [acute stretching review](https://pubmed.ncbi.nlm.nih.gov/26642915/),
[chronic stretching meta-analysis](https://pubmed.ncbi.nlm.nih.gov/37301370/),
[resistance training and range-of-motion meta-analysis](https://pmc.ncbi.nlm.nih.gov/articles/PMC9935664/), and
[post-exercise stretching meta-analysis](https://pubmed.ncbi.nlm.nih.gov/34025459/).

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

These are performance-and-recovery stages, not fixed calendar weeks. The app groups them as
${LONG_RUN_PHASES.map((phase) => `${phase.name} (${phase.start}–${phase.end})`).join(", ")}.

${LONG_RUNS.map((distance, index) => `- Stage ${index + 1}: ${distance} easy`).join("\n")}

Repeat a stage when the distance is not yet easy or the next-morning response is not stable. Walk breaks are allowed.
The tracker records the stage used with that workout and enables the next-stage action after the target is completed at
RPE 4 or below with a Comfortable or Mild following-morning response. This is a recommendation; the user retains the
final decision and can repeat or step back.

## Pull-up progression — choose by performance

Choose the step that matches your current ability; it is not a calendar-week requirement. In the app, drag or tap the
roadmap to preview a step, then confirm separately before changing the current step. Each qualified session requires
both the performance check—target met with clean technique and at least one rep in reserve—and the following-morning
recovery check. Advance after two qualified sessions; stepping back does not delete past logs.

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
