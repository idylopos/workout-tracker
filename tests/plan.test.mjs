import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { validatePlan } from "../scripts/plan-utils.mjs";
import { renderWorkoutPlanMarkdown } from "../scripts/sync-plan-markdown.mjs";

test("the example folder plan passes build validation", async () => {
  const plan = JSON.parse(await readFile(new URL("../plans/example-plan/plan.json", import.meta.url), "utf8"));
  assert.deepEqual(validatePlan(plan, "example-plan"), []);
});

test("a plan ID must match its folder", () => {
  const plan = {
    schemaVersion: 1,
    id: "different-id",
    name: "Test",
    days: {
      monday: {
        exercises: [
          {
            id: "squat",
            name: "Squat",
            measurement: "reps",
            sets: 3,
            rest: 60
          }
        ]
      }
    }
  };
  assert.match(validatePlan(plan, "folder-name").join(" "), /must exactly match/);
});

test("custom exercise guidance requires setup, action, and watch text", () => {
  const plan = {
    schemaVersion: 1,
    id: "guided-plan",
    name: "Guided plan",
    days: {
      monday: {
        exercises: [
          {
            id: "squat",
            name: "Squat",
            measurement: "reps",
            sets: 3,
            rest: 60,
            guidance: {
              setup: "Stand tall.",
              action: "Squat under control.",
            },
          },
        ],
      },
    },
  };
  assert.match(validatePlan(plan, "guided-plan").join(" "), /guidance\.watch/);
});

test("the readable workout plan is rendered from the built-in plan", async () => {
  const generated = renderWorkoutPlanMarkdown();
  const checkedIn = await readFile(new URL("../WORKOUT_PLAN.md", import.meta.url), "utf8");
  assert.equal(checkedIn, generated);
  assert.match(generated, /### Block 1 — Build to a comfortable 10 km/);
  assert.match(generated, /### Block 2 — Improve comfortable 10 km speed/);
  assert.match(generated, /### Friday — Push B \+ Mobility B/);
  assert.match(generated, /This is not the adductor machine/);
  assert.match(generated, /Pull-up progression — choose by performance/);
});
