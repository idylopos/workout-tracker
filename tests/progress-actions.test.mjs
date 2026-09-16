import test from "node:test";
import assert from "node:assert/strict";
import { progressOverviewAction, summarizeProgressOverview } from "../lib.js";

const ready = { workouts: 2, dueReviews: 0, latestResponse: { value: 0 }, averageSleep: 8, sleepNights: 3 };

test("Empty Progress offers a workout and missing sleep offers the actual nightly flow", () => {
  assert.deepEqual(progressOverviewAction(summarizeProgressOverview({}, [], "2026-09-16")), {
    target: "today", label: "Log a workout",
  });
  const sparse = { ...ready, averageSleep: null, sleepNights: 0 };
  assert.equal(progressOverviewAction(sparse, [{ type: "sleep" }]).target, "sleep");
  assert.equal(progressOverviewAction(sparse, []).target, "sleep-history");
  assert.equal(progressOverviewAction({ ...ready, sleepNights: 1 }, [{ type: "sleep" }]).target, "sleep");
});

test("Progress prioritizes due recovery, then the relevant plan or sleep history", () => {
  assert.equal(progressOverviewAction({ ...ready, dueReviews: 1 }, [{ type: "sleep" }, { type: "recovery" }]).target, "recovery");
  assert.equal(progressOverviewAction({ ...ready, latestResponse: { value: 2 } }).target, "week");
  assert.equal(progressOverviewAction({ ...ready, averageSleep: 6 }).target, "sleep-history");
  assert.equal(progressOverviewAction(ready).target, "exercise");
});

test("Progress never links to a check-in that is unavailable or mutates the snapshot", () => {
  const summary = { ...ready, dueReviews: 1 };
  const before = structuredClone(summary);
  assert.notEqual(progressOverviewAction(summary, []).target, "recovery");
  assert.deepEqual(summary, before);
});
