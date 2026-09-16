import test from "node:test";
import assert from "node:assert/strict";
import { summarizeExercise } from "../lib.js";

function log(date, measurement, sets) {
  return { date, exercises: { exercise: { measurement, sets } } };
}

test("Progress exposes dates, recorded results, plotted estimates, and work units", () => {
  const logs = {
    older: log("2026-09-09", "weight_reps", [{ weight: 30, reps: 8 }]),
    newer: log("2026-09-16", "weight_reps", [{ weight: 32, reps: 10 }]),
  };
  const before = structuredClone(logs);
  const stats = summarizeExercise(logs, "exercise");
  assert.deepEqual(stats.points.map(({ date, label }) => ({ date, label })), [
    { date: "2026-09-09", label: "30 kg × 8" },
    { date: "2026-09-16", label: "32 kg × 10" },
  ]);
  assert.equal(stats.points[0].value, 38);
  assert.equal(stats.metric.title, "Estimated max");
  assert.equal(stats.metric.unit, "kg");
  assert.equal(stats.metric.totalLabel, "Total work (kg × reps)");
  assert.match(stats.metric.note, /not a tested maximum/);
  assert.equal(stats.volume, "560");
  assert.deepEqual(logs, before);
});

test("Every exercise measurement names the quantity plotted and its aggregate unit", () => {
  const cases = [
    ["completion", { completed: true }, "rounds", "Total rounds", 1],
    ["weight_distance", { weight: 10, distance: 20 }, "kg × m", "Total work (kg × m)", 200],
    ["reps", { reps: 8 }, "reps", "Total reps", 8],
    ["assisted_reps", { reps: 8, assistance: 20 }, "reps", "Total reps", 8],
    ["duration", { minutes: 2, seconds: 30 }, "min", "Total time (sec)", 2.5],
    ["duration_calories", { minutes: 2, seconds: 30, calories: 20 }, "min", "Total time (sec)", 2.5],
    ["distance_time", { distance: 2, minutes: 12 }, "km", "Total distance (km)", 2],
    ["distance", { distance: 2 }, "km", "Sum of best distances (km)", 2],
  ];
  for (const [measurement, set, unit, totalLabel, value] of cases) {
    const stats = summarizeExercise({ day: log("2026-09-16", measurement, [set]) }, "exercise");
    assert.equal(stats.metric.unit, unit, measurement);
    assert.equal(stats.metric.totalLabel, totalLabel, measurement);
    assert.equal(stats.points[0].value, value, measurement);
    assert.ok(stats.points[0].label, measurement);
    if (measurement === "assisted_reps") assert.match(stats.metric.note, /does not account for changes in assistance/);
  }
});

test("Sparse history stays honest and different measurement types are not joined", () => {
  const empty = summarizeExercise({}, "exercise");
  assert.deepEqual(empty.points, []);
  assert.equal(empty.metric, null);
  const mixed = summarizeExercise({
    older: log("2026-09-09", "weight_reps", [{ weight: 30, reps: 8 }]),
    newer: log("2026-09-16", "reps", [{ reps: 10 }]),
  }, "exercise");
  assert.equal(mixed.sessions, 2);
  assert.equal(mixed.points.length, 1);
  assert.equal(mixed.metric.unit, "reps");
  assert.deepEqual(mixed.points[0], { date: "2026-09-16", value: 10, label: "10 reps" });
});
