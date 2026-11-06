import test from "node:test";
import assert from "node:assert/strict";
import { EXERCISE_ALTERNATIVES, exercisesForSavedWorkout, findExerciseHistory, WEEK_PLAN } from "../lib.js";

const friday = WEEK_PLAN.friday.exercises;
const coreIds = ["reverse-crunch", "supine-heel-slide", "bird-dog"];
const core = exercises => exercises.filter(exercise => coreIds.includes(exercise.id)).map(exercise => exercise.id);

test("Fridays default to Bird Dog and reopen the core slots that were actually saved", () => {
  assert.deepEqual(core(exercisesForSavedWorkout(friday, null)), ["bird-dog"]);
  assert.equal(EXERCISE_ALTERNATIVES["bird-dog"][0].id, "supine-heel-slide");
  const log = { exercises: { "reverse-crunch": { sets: [{ reps: 12 }] } } };
  assert.deepEqual(core(exercisesForSavedWorkout(friday, log)), ["reverse-crunch"]);
  log.exercises["supine-heel-slide"] = { variantId: "bird-dog", sets: [{ reps: 5 }] };
  const original = structuredClone(log);
  assert.deepEqual(core(exercisesForSavedWorkout(friday, log)), ["reverse-crunch", "supine-heel-slide"]);
  assert.ok(EXERCISE_ALTERNATIVES["supine-heel-slide"].some(option => option.id === "bird-dog"));
  assert.deepEqual(log, original);
  assert.equal(exercisesForSavedWorkout(friday, log, "custom-plan"), friday);
});

test("Use Last finds the same performed Friday movement across the default change", () => {
  const logs = {
    oldBird: { date: "2026-10-16", exercises: { "supine-heel-slide": { variantId: "bird-dog", sets: [{ reps: 5 }] } } },
    oldSlide: { date: "2026-10-23", exercises: { "supine-heel-slide": { sets: [{ reps: 8 }] } } },
    newSlide: { date: "2026-10-30", exercises: { "bird-dog": { variantId: "supine-heel-slide", sets: [{ reps: 6 }] } } },
  };
  const reps = variant => findExerciseHistory(logs, "bird-dog", "2026-11-06", "form-flow", {}, variant)
    .map(entry => entry.sets[0].reps);
  assert.deepEqual(reps("bird-dog"), [5]);
  assert.deepEqual(reps("supine-heel-slide"), [6, 8]);
});
