import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { writeFile } from "node:fs/promises";
import {
  EXERCISE_GUIDANCE,
  LONG_RUN_PHASES,
  LONG_RUNS,
  MEASUREMENT_TYPES,
  OPTIONAL_RECOVERY_RULE,
  PULL_UP_STEPS,
  RUN_QUALITY_PROGRESSION,
  STRENGTH_PROGRESSION,
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
    return `Block 1: 25–35 min easy at RPE 2–4 · Block 2 alternates completed quality sessions: ${RUN_QUALITY_PROGRESSION.base}`;
  }
  if (exercise.id === "long-run") {
    return "Block 1: use the 18-stage progression below · Block 2: 8–10 km easy; walk breaks allowed";
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
    `**Theme:** ${day.kicker}<br>`,
    `**Estimated time:** ${day.estimate}<br>`,
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
The lookup searches every earlier completed workout and encrypted draft, so skipped weeks do not hide the latest entry.

## Mobility placement and limits

Monday's lunge twists are a brief dynamic rehearsal before the squat and jump sequence, not extra working sets. Wednesday
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

## Strength progression

- **Working-set effort:** ${STRENGTH_PROGRESSION.effort}
- **Double progression:** ${STRENGTH_PROGRESSION.load}
- **Volume target:** ${STRENGTH_PROGRESSION.volume}
- Use longer accessory rests when one minute causes a large repetition or technique drop; 75–90 seconds is appropriate.
- Do not increase long-run distance, Thursday running intensity, lower-body lifting load, jump volume, and extra cardio
  at the same time. Change one major lower-body stressor at a time.

### How the hypertrophy volume is counted

- **Chest:** 15 chest-related working sets, approximately 12–13 fractional sets when each landmine-press set is counted
  as half a chest set. The two weekly cable-fly slots add chest work without adding another heavy press.
- **Back:** 12 direct lat/mid-back sets from pull-ups, rows, and pullovers. Wednesday face pulls add 3 rear-delt and
  upper-back sets; Saturday face pulls remain optional rather than being required to reach the back target.
- **Rectus abdominis:** 6 direct dynamic sets from cable crunches and reverse crunches. Pallof presses and suitcase
  carries remain for anti-rotation and lateral trunk function, but are not counted as rectus-hypertrophy sets.
- Start each newly added chest or abdominal exercise with 2 sets for its first two exposures. Use the full prescription
  only when technique, performance, shoulder/knee response, and following-morning recovery remain stable.

There is no research-defined universal “maximal” set count. These are high-return targets that account for indirect
work and the rest of this six-day concurrent plan, rather than a claim that more sets cannot ever produce more growth.

### Visible-abs reality check

Cable crunches and reverse crunches give the rectus abdominis progressive, dynamic resistance and may make it larger.
They do not selectively remove abdominal fat. Ab visibility also depends on total fat loss and individual fat
distribution, so continue tracking body weight and waist rather than adding more abdominal sets when waist reduction
stalls. The first progression should be more repetitions or load at the target RIR, not more weekly exercises.

## Recovery gate for optional sessions

${OPTIONAL_RECOVERY_RULE.copy}

The sleep threshold is a readiness rule, not a guarantee. Sunday remains complete rest. When recovery is limited, skip
Wednesday Zone 2 cycling first, then Saturday face pulls and curls; the three-exercise Pull B base remains planned.
Do not replace skipped work with hard extra cardio.

## Block 1 and Block 2

### Block 1 — Build to a comfortable 10 km

Stay here until two separate 10 km runs are completed at RPE 4 or below with a Comfortable or Mild following-morning
response. Keep easy runs conversational and follow the 18-stage long-run progression.

### Block 2 — Improve comfortable 10 km speed

Start only after Block 1 is achieved. Tuesday adds relaxed strides; Thursday alternates controlled tempo and interval
work after each completed quality session; Saturday stays at 8–10 km easy. Begin with Tempo, then alternate:

- **Tempo:** 10 min easy; 3 × 6 min at RPE 6–7 with 2 min easy; 5–10 min easy cooldown.
- **Intervals:** 10 min easy; 6 × 2 min at RPE 8 with 2 min easy; 8–10 min easy cooldown.
- **Progression:** ${RUN_QUALITY_PROGRESSION.progression}
- Keep fast running controlled rather than maximal. Repeat the same prescription instead of progressing when form,
  joints, or following-morning recovery are not stable.

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

Stages 15 and 17 are the two 10 km qualification opportunities, separated by an 8 km cutback. Block 2 is recommended
only after two qualifying 10 km sessions. The app warns before an early Block 2 switch but leaves the final decision
with the user.

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

## Recent evidence check

- [ACSM 2026 resistance-training guidance](https://acsm.org/resistance-training-guidelines-update-2026/) supports
  goal-specific loading, multiple weekly sets, and avoiding a requirement to train to failure.
- [2024 proximity-to-failure meta-regression](https://pubmed.ncbi.nlm.nih.gov/38970765/) supports recording RIR while
  acknowledging that the exact hypertrophy relationship remains uncertain.
- [2026 weekly-volume and frequency meta-regressions](https://pubmed.ncbi.nlm.nih.gov/41343037/) found increasing
  hypertrophy with higher fractional weekly set volume, with diminishing returns and substantial individual uncertainty.
- Direct long-term abdominal-hypertrophy evidence is limited. An [abdominal-crunch resistance study](https://pubmed.ncbi.nlm.nih.gov/37621710/)
  supports loading the crunch across conventional resistance-training set structures, while an
  [ultrasound exercise comparison](https://pubmed.ncbi.nlm.nih.gov/38288259/) found greater rectus shortening and
  thickening during crunching than leg-raise variations; neither establishes a unique optimal abdominal program.
- A randomized [abdominal resistance-training trial](https://pubmed.ncbi.nlm.nih.gov/2528028/) improved abdominal
  muscular function but did not reduce abdominal skinfolds or girth, supporting the distinction between building the
  rectus abdominis and losing the fat covering it.
- [2025 running-load cohort](https://pubmed.ncbi.nlm.nih.gov/40623829/) found higher overuse-injury rates when one run
  exceeded the longest run in the prior 30 days by more than 10%; this does not make smaller increases risk-free.
- [2025 training-intensity-distribution meta-analysis](https://pubmed.ncbi.nlm.nih.gov/39888556/) found no universally
  superior intensity distribution, supporting a predominantly easy plan with limited controlled quality work.
- [CDC adult sleep guidance](https://www.cdc.gov/sleep/about/index.html) recommends at least 7 hours for adults aged
  18–60; the optional-session gate applies that threshold conservatively.
`;
}

export async function writeWorkoutPlanMarkdown(workspaceRoot = root) {
  await writeFile(resolve(workspaceRoot, "WORKOUT_PLAN.md"), renderWorkoutPlanMarkdown(), "utf8");
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await writeWorkoutPlanMarkdown();
}
