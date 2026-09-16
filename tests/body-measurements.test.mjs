import test from "node:test";
import assert from "node:assert/strict";
import { bodyMeasurementPoints, createDefaultState, mergeBodyMeasurement, validateBackup } from "../lib.js";

test("weight and waist can be logged independently without inventing a zero", () => {
  assert.deepEqual(mergeBodyMeasurement(null, { date: "2026-09-16", weight: "72.4", waist: "" }), {
    date: "2026-09-16", weight: 72.4,
  });
  assert.deepEqual(mergeBodyMeasurement(null, { date: "2026-09-16", weight: "", waist: "83" }), {
    date: "2026-09-16", waist: 83,
  });
});

test("same-day partial updates preserve the other reading without mutating existing history", () => {
  const existing = { date: "2026-09-16", weight: 72.4, waist: 84 };
  assert.deepEqual(mergeBodyMeasurement(existing, { date: existing.date, waist: "83.5", weight: "" }), {
    date: existing.date, weight: 72.4, waist: 83.5,
  });
  assert.deepEqual(mergeBodyMeasurement(existing, { date: existing.date, waist: "", weight: "73" }), {
    date: existing.date, weight: 73, waist: 84,
  });
  assert.deepEqual(existing, { date: "2026-09-16", weight: 72.4, waist: 84 });
  assert.deepEqual(mergeBodyMeasurement(existing, { date: "2026-09-17", weight: "73" }), {
    date: "2026-09-17", weight: 73,
  });
});

test("empty or invalid submissions do not create a body record", () => {
  for (const entry of [{}, { weight: "", waist: " " }, { weight: "NaN" }, { waist: -1 }, { weight: Infinity }, { waist: true }]) {
    assert.equal(mergeBodyMeasurement(null, { date: "2026-09-16", ...entry }), null);
  }
});

test("partial and legacy paired body measurements survive backup restore", () => {
  const state = createDefaultState();
  state.bodyLogs = [
    { date: "2026-09-14", weight: 72.4 },
    { date: "2026-09-15", waist: 84 },
    { date: "2026-09-16", weight: 72, waist: 83.5 },
    { date: "2026-09-17", weight: null, waist: 83 },
  ];
  const restored = validateBackup(JSON.parse(JSON.stringify(state)));
  assert.equal(restored.valid, true);
  assert.deepEqual(restored.state.bodyLogs, state.bodyLogs);
  for (const fields of [{}, { weight: "", waist: null }, { weight: 72, waist: "invalid" }, { waist: -2 }, { weight: false }]) {
    assert.equal(validateBackup({ ...state, bodyLogs: [{ date: "2026-09-16", ...fields }] }).valid, false);
  }
});

test("sparse body charts omit missing readings while keeping the shared date positions", () => {
  const entries = [
    { date: "2026-09-16", weight: 72, waist: 83.5 },
    { date: "2026-09-14", weight: 72.4 },
    { date: "2026-09-15", waist: 84 },
  ];
  assert.deepEqual(bodyMeasurementPoints(entries, "weight"), [
    { date: "2026-09-14", value: 72.4, position: 0 },
    { date: "2026-09-16", value: 72, position: 1 },
  ]);
  assert.deepEqual(bodyMeasurementPoints(entries, "waist"), [
    { date: "2026-09-15", value: 84, position: 0.5 },
    { date: "2026-09-16", value: 83.5, position: 1 },
  ]);
  assert.deepEqual(bodyMeasurementPoints([{ date: "2026-09-16", waist: 83.5 }], "weight"), []);
  assert.equal(entries[0].date, "2026-09-16");
});
