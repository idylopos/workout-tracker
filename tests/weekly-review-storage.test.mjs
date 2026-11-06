import test from "node:test";
import assert from "node:assert/strict";
import { createDefaultState, normalizeState, validateBackup } from "../lib.js";
import { createVault, unlockVault } from "../crypto-vault.js";
import {
  DEFAULT_REVIEW_PROFILE,
  normalizeReviewConsent,
  normalizeReviewProfile,
  normalizeReviews,
  validateStoredReview,
  validateStoredReviews,
} from "../review-storage.js";

function savedReview() {
  return {
    id: "review-2026-10-26",
    planId: "form-flow",
    period: { start: "2026-10-26", end: "2026-11-01", comparisonStart: "2026-09-28", partial: false, timezone: "Asia/Singapore" },
    inputFingerprint: "a".repeat(64),
    createdAt: "2026-11-02T02:00:00.000Z",
    evidence: [{ id: "session:2026-10-26", label: "2026-10-26 벤치 프레스: 완료 1세트" }],
    previousRecommendations: [],
    meta: { mode: "mock", model: "local-mock", promptVersion: "1", schemaVersion: "1", usage: null },
    decisions: { "maintain-plan": "applied" },
    result: {
      summary: "모의 리뷰: 기록된 운동을 기준으로 현재 계획을 유지하세요.",
      observations: [{ text: "벤치 프레스 1세트를 완료로 기록했습니다.", evidenceIds: ["session:2026-10-26"] }],
      recoveryObservations: [{ fact: "회복 기록이 없습니다.", interpretation: "회복 여부를 판단할 수 없습니다.", evidenceIds: ["session:2026-10-26"] }],
      recommendations: [{ id: "maintain-plan", priority: 1, title: "현재 계획 유지", evidenceIds: ["session:2026-10-26"], adjustment: "기존 증량 규칙을 따르세요.", checkNextWeek: "다음 주 회복 기록을 확인하세요." }],
      followUp: [],
      missingInformation: ["회복 기록"],
      questions: ["다음 날 회복 상태는 어떠했나요?"],
      note: "정보 제공용이며 진단이나 치료를 대신하지 않습니다.",
    },
  };
}

function existingState() {
  const state = createDefaultState();
  state.workoutLogs["2026-10-26"] = {
    date: "2026-10-26", planId: "form-flow", dayKey: "monday",
    exercises: { press: { name: "Bench press", measurement: "weight_reps", sets: [{ weight: 30, reps: 8, completed: true }] } },
    response: { readiness: "yes", notes: "Personal workout note" },
  };
  state.workoutDrafts["2026-10-27"] = {
    date: "2026-10-27", exercises: { run: { measurement: "distance_time", sets: [{ distance: 3, minutes: 20, completed: false }] } },
  };
  state.bodyLogs = [{ date: "2026-10-26", waist: 82 }];
  state.dailySleepLogs = [{ date: "2026-10-26", hours: 7.5 }];
  state.settings.nextSessionTargets = { press: { value: 32, sourceDate: "2026-10-26" } };
  return state;
}

test("review profile keeps user-reported defaults and strips unrelated fields", () => {
  assert.deepEqual(normalizeReviewProfile(), DEFAULT_REVIEW_PROFILE);
  assert.deepEqual(normalizeReviewProfile({ goals: " 러닝 유지 ", constraints: "", apiKey: "not-retained" }), { goals: "러닝 유지", constraints: "" });
  assert.equal(normalizeReviewProfile({ goals: "a".repeat(1001) }).goals.length, 1000);
});

test("review consent retains only disclosure scope, with no credentials", () => {
  const consent = { endpoint: "https://review.example.com/api/weekly-review", version: "1", acceptedAt: "2026-11-02T02:00:00.000Z" };
  assert.deepEqual(normalizeReviewConsent({ ...consent, token: "secret", apiKey: "secret" }), consent);
  assert.equal(normalizeReviewConsent({ ...consent, endpoint: "https://user:secret@review.example.com" }), null);
  assert.equal(normalizeReviewConsent({ ...consent, endpoint: "https://review.example.com?token=secret" }), null);
  assert.equal(normalizeReviewConsent({ ...consent, endpoint: "http://review.example.com" }), null);
  assert.equal(normalizeReviewConsent({ ...consent, version: "0" }), null);
  assert.equal(normalizeReviewConsent({ ...consent, endpoint: "http://localhost:8787/api/weekly-review" }).endpoint, "http://localhost:8787/api/weekly-review");
});

test("saved reviews and recommendation decisions validate and normalize without aliasing", () => {
  const review = savedReview();
  assert.equal(validateStoredReview(review), true);
  assert.equal(validateStoredReviews([review]), true);
  const normalized = normalizeReviews([review]);
  assert.deepEqual(normalized, [review]);
  normalized[0].decisions["maintain-plan"] = "skipped";
  assert.equal(review.decisions["maintain-plan"], "applied");
  for (const status of ["applied", "not_yet", "skipped"]) {
    review.decisions["maintain-plan"] = status;
    assert.equal(validateStoredReview(review), true);
  }
});

test("malformed saved reviews, unknown evidence and unrecognized decisions are rejected", () => {
  const mutations = [
    (review) => { review.result.observations[0].evidenceIds = ["invented-session"]; },
    (review) => { review.decisions["maintain-plan"] = "automatically-applied"; },
    (review) => { review.decisions["unknown-recommendation"] = "applied"; },
    (review) => { review.period.end = "2026-11-05"; },
    (review) => { review.period.start = "2026-02-30"; },
    (review) => { review.meta.token = "secret"; },
    (review) => { review.planId = undefined; },
    (review) => { review.inputFingerprint = "invalid"; },
    (review) => { review.evidence.push({ ...review.evidence[0] }); },
    (review) => { review.result.followUp = [{ recommendationId: "invented-previous", text: "Followed", evidenceIds: [] }]; },
  ];
  for (const mutate of mutations) {
    const review = savedReview();
    mutate(review);
    assert.equal(validateStoredReview(review), false);
    assert.equal(validateStoredReviews([review]), false);
    assert.deepEqual(normalizeReviews([review]), []);
  }
  assert.equal(validateStoredReviews([savedReview(), savedReview()]), false);
  assert.equal(normalizeReviews([savedReview(), savedReview()]).length, 1);
  assert.deepEqual(normalizeReviews({}), []);
});

test("old backups without AI fields import without changing existing training data", () => {
  const legacy = existingState();
  delete legacy.aiReviews;
  delete legacy.aiReviewProfile;
  delete legacy.aiReviewConsent;
  const restored = validateBackup(JSON.parse(JSON.stringify(legacy)));
  assert.equal(restored.valid, true);
  for (const key of ["workoutLogs", "workoutDrafts", "bodyLogs", "dailySleepLogs", "settings"]) {
    assert.deepEqual(restored.state[key], legacy[key]);
  }
  assert.deepEqual(restored.state.aiReviews, []);
  assert.deepEqual(restored.state.aiReviewProfile, DEFAULT_REVIEW_PROFILE);
  assert.equal(restored.state.aiReviewConsent, null);
});

test("reviews and all three decisions round-trip through JSON backup and state normalization", () => {
  const state = existingState();
  state.aiReviewProfile = { goals: "무리 없이 꾸준히", constraints: "사용자 보고: 무릎 상태 확인" };
  for (const status of ["applied", "not_yet", "skipped"]) {
    const review = savedReview();
    review.decisions["maintain-plan"] = status;
    state.aiReviews = [review];
    const exported = JSON.parse(JSON.stringify({ ...state, app: "Form / Flow", exportedAt: new Date().toISOString() }));
    const restored = validateBackup(exported);
    assert.equal(restored.valid, true);
    assert.deepEqual(restored.state.aiReviews, state.aiReviews);
    assert.deepEqual(restored.state.aiReviewProfile, state.aiReviewProfile);
    assert.deepEqual(restored.state.workoutLogs, state.workoutLogs);
    assert.deepEqual(restored.state.workoutDrafts, state.workoutDrafts);
    assert.deepEqual(restored.state.settings.nextSessionTargets, state.settings.nextSessionTargets);
  }
  state.aiReviews[0].result.observations[0].evidenceIds = ["nonexistent"];
  assert.equal(validateBackup(state).valid, false);
});

test("review text and decisions stay inside the existing encrypted vault", async () => {
  const state = existingState();
  state.aiReviews = [savedReview()];
  state.aiReviewProfile = { goals: "개인 목표", constraints: "개인 제약" };
  const created = await createVault(state, "test-only-long-review-passphrase");
  const serialized = JSON.stringify(created.vault);
  for (const privateValue of ["aiReviews", "maintain-plan", "개인 목표", "Personal workout note", "test-only-long-review-passphrase"]) {
    assert.equal(serialized.includes(privateValue), false);
  }
  const unlocked = await unlockVault(created.vault, "test-only-long-review-passphrase");
  const restored = normalizeState(unlocked.state);
  assert.deepEqual(restored.aiReviews, state.aiReviews);
  assert.deepEqual(restored.aiReviewProfile, state.aiReviewProfile);
  assert.deepEqual(restored.workoutLogs, state.workoutLogs);
  assert.deepEqual(restored.workoutDrafts, state.workoutDrafts);
});
