import test from "node:test";
import assert from "node:assert/strict";
import { createDefaultState, WEEK_PLAN } from "../lib.js";
import { createMockReview } from "../review-contract.js";
import { createReviewClient } from "../review-client.js";
import { MAX_STORED_REVIEWS } from "../review-storage.js";

const ENDPOINT = "https://review.example.com/api/weekly-review";
const TOKEN = "test-only-backend-token-with-over-32-characters";
const liveOptions = { mode: "live", token: TOKEN };

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function liveResponse(body) {
  const response = createMockReview(body.payload);
  response.meta = { mode: "live", model: "test-model", schemaVersion: "1", promptVersion: "1",
    usage: { inputTokens: 100, outputTokens: 50, totalTokens: 150 } };
  return new Response(JSON.stringify(response), { status: 200, headers: { "Content-Type": "application/json" } });
}

function harness(options = {}) {
  let state = createDefaultState();
  let date = new Date("2026-11-04T02:00:00.000Z");
  let unlocked = true;
  const plan = { id: "form-flow", name: "Form / Flow weekly plan", days: structuredClone(WEEK_PLAN) };
  state.workoutLogs["2026-10-26"] = {
    date: "2026-10-26", planId: "form-flow", dayKey: "monday",
    exercises: { press: { name: "Bench press", measurement: "weight_reps",
      sets: [{ weight: 30, reps: 8, completed: true }] } },
    response: { readiness: "yes", notes: "Recorded session" },
  };
  state.workoutDrafts["2026-10-27"] = { date: "2026-10-27", exercises: {
    run: { measurement: "distance_time", sets: [{ distance: 4, minutes: 25, completed: true }] },
  } };
  state.aiReviewConsent = { endpoint: ENDPOINT, version: "1", acceptedAt: date.toISOString() };
  const calls = { adapter: 0, fetch: 0, persist: 0, requests: [] };
  const client = createReviewClient({
    getState: () => state, getPlan: () => plan, isUnlocked: () => unlocked, now: () => new Date(date), endpoint: ENDPOINT,
    persist: async () => { calls.persist += 1; return options.persistResult ?? true; },
    mockAdapter: async (payload) => { calls.adapter += 1; return options.mockAdapter ? options.mockAdapter(payload) : createMockReview(payload); },
    fetchImpl: async (url, request) => {
      calls.fetch += 1;
      const body = JSON.parse(request.body);
      calls.requests.push({ url, ...request, body });
      return options.fetchImpl ? options.fetchImpl(url, request, body) : liveResponse(body);
    },
    ...(options.timeoutMs === undefined ? {} : { timeoutMs: options.timeoutMs }),
  });
  return { client, plan, calls, get state() { return state; },
    setDate(value) { date = new Date(value); }, setUnlocked(value) { unlocked = value; }, replaceState(value) { state = value; } };
}

test("double clicks coalesce into one pending review and one persistence operation", async () => {
  const entered = deferred();
  const release = deferred();
  const fixture = harness({ mockAdapter: async (payload) => {
    entered.resolve();
    await release.promise;
    return createMockReview(payload);
  } });
  const first = fixture.client.request();
  const second = fixture.client.request();
  assert.equal(first, second);
  assert.equal(fixture.client.busy, true);
  await entered.promise;
  assert.equal(fixture.calls.adapter, 1);
  release.resolve();
  const [a, b] = await Promise.all([first, second]);
  assert.equal(a.review, b.review);
  assert.equal(fixture.state.aiReviews.length, 1);
  assert.equal(fixture.calls.persist, 1);
  assert.equal(fixture.client.busy, false);
});

test("unchanged inputs reopen a saved review without calling either adapter again", async () => {
  const fixture = harness();
  const first = await fixture.client.request();
  const second = await fixture.client.request();
  assert.equal(second.reused, true);
  assert.equal(second.stale, false);
  assert.equal(second.review.id, first.review.id);
  assert.equal(fixture.calls.adapter, 1);
  assert.equal(fixture.calls.fetch, 0);
  assert.equal(fixture.calls.persist, 1);
});

test("profile, plan and log changes mark saved reviews stale until explicit regeneration", async (t) => {
  const changes = {
    profile: (fixture) => { fixture.state.aiReviewProfile.goals = "러닝보다 근력 유지에 집중"; },
    plan: (fixture) => { fixture.plan.days.monday.exercises[0].prescription += " with a changed target"; },
    log: (fixture) => { fixture.state.workoutLogs["2026-10-26"].exercises.press.sets[0].reps += 1; },
  };
  for (const [name, change] of Object.entries(changes)) {
    await t.test(name, async () => {
      const fixture = harness();
      const first = await fixture.client.request();
      change(fixture);
      const stale = await fixture.client.request();
      assert.equal(stale.reused, true);
      assert.equal(stale.stale, true);
      assert.equal(fixture.calls.adapter, 1);
      assert.equal(stale.review.id, first.review.id);
      const regenerated = await fixture.client.request({ regenerate: true });
      assert.equal(regenerated.reused, false);
      assert.equal(regenerated.stale, false);
      assert.notEqual(regenerated.review.inputFingerprint, first.review.inputFingerprint);
      assert.notEqual(regenerated.review.id, first.review.id);
      assert.equal(fixture.state.aiReviews.length, 2);
      assert.equal(fixture.calls.adapter, 2);
    });
  }
});

test("recorded prior decisions change next week's fingerprint and reach the next review", async () => {
  const fixture = harness();
  const first = await fixture.client.request();
  const recommendation = first.review.result.recommendations[0];
  fixture.state.workoutLogs["2026-11-02"] = { ...structuredClone(fixture.state.workoutLogs["2026-10-26"]), date: "2026-11-02" };
  fixture.setDate("2026-11-11T02:00:00.000Z");
  const before = await fixture.client.prepare();
  first.review.decisions[recommendation.id] = "applied";
  const after = await fixture.client.prepare();
  assert.notEqual(after.inputFingerprint, before.inputFingerprint);
  assert.equal(after.payload.previousRecommendations[0].status, "applied");
  const next = await fixture.client.request();
  assert.equal(next.review.previousRecommendations[0].status, "applied");
  assert.equal(next.review.result.followUp[0].recommendationId, `${first.review.id}:${recommendation.id}`);
  assert.match(next.review.result.followUp[0].text, /적용함/);
});

test("failed persistence keeps the response in memory and reopening does not spend another request", async () => {
  const fixture = harness({ persistResult: false });
  const workouts = structuredClone(fixture.state.workoutLogs);
  const result = await fixture.client.request();
  assert.equal(result.saved, false);
  assert.equal(fixture.state.aiReviews.length, 1);
  const reopened = await fixture.client.request();
  assert.equal(reopened.review.id, result.review.id);
  assert.equal(reopened.reused, true);
  assert.equal(fixture.calls.adapter, 1);
  assert.deepEqual(fixture.state.workoutLogs, workouts);
});

test("invalid metadata and fabricated evidence fail without saving any review", async (t) => {
  const mutations = {
    "token accounting": (response) => { response.meta.usage = { inputTokens: 3, outputTokens: 2, totalTokens: 8 }; },
    "unexpected metadata": (response) => { response.meta.token = "must-never-be-persisted"; },
    "missing usage": (response) => { delete response.meta.usage; },
    "wrong mode": (response) => { response.meta.mode = "live"; },
    "fabricated evidence": (response) => { response.result.observations[0].evidenceIds = ["nonexistent-workout"]; },
  };
  for (const [name, mutate] of Object.entries(mutations)) {
    await t.test(name, async () => {
      const fixture = harness({ mockAdapter: (payload) => {
        const response = createMockReview(payload);
        mutate(response);
        return response;
      } });
      const workouts = structuredClone(fixture.state.workoutLogs);
      await assert.rejects(fixture.client.request(), { code: "invalid_response" });
      assert.equal(fixture.state.aiReviews.length, 0);
      assert.equal(fixture.calls.persist, 0);
      assert.deepEqual(fixture.state.workoutLogs, workouts);
    });
  }
});

test("live requests require matching consent and a backend token before sending data", async () => {
  const fixture = harness();
  fixture.state.aiReviewConsent = null;
  await assert.rejects(fixture.client.request(liveOptions), { code: "consent" });
  fixture.state.aiReviewConsent = { endpoint: "https://other.example.com/api/weekly-review", version: "1" };
  await assert.rejects(fixture.client.request(liveOptions), { code: "consent" });
  fixture.state.aiReviewConsent = { endpoint: ENDPOINT, version: "1" };
  await assert.rejects(fixture.client.request({ mode: "live" }), { code: "auth" });
  assert.equal(fixture.calls.fetch, 0);
  const live = await fixture.client.request(liveOptions);
  assert.equal(live.review.meta.mode, "live");
  assert.equal(fixture.calls.fetch, 1);
  assert.equal(fixture.calls.requests[0].headers.Authorization, `Bearer ${TOKEN}`);
  assert.equal(fixture.calls.requests[0].credentials, "omit");
  assert.equal(fixture.calls.requests[0].redirect, "error");
  assert.equal(JSON.stringify(fixture.state).includes(TOKEN), false);
});

test("cancelling synchronously during fingerprinting prevents any live request", async () => {
  const fixture = harness();
  const request = fixture.client.request(liveOptions);
  fixture.client.cancel();
  await assert.rejects(request, { code: "cancelled" });
  assert.equal(fixture.calls.fetch, 0);
  assert.equal(fixture.state.aiReviews.length, 0);
  assert.equal(fixture.client.busy, false);
});

test("a locked app cannot prepare or transmit a review", async () => {
  const fixture = harness();
  fixture.setUnlocked(false);
  await assert.rejects(fixture.client.prepare(), { code: "locked" });
  await assert.rejects(fixture.client.request(liveOptions), { code: "locked" });
  assert.equal(fixture.calls.fetch, 0);
  assert.equal(fixture.calls.adapter, 0);
});

test("cancelled network results cannot be saved even when the transport ignores abort", async () => {
  const entered = deferred();
  const release = deferred();
  const fixture = harness({ fetchImpl: async (_url, _request, body) => {
    entered.resolve();
    await release.promise;
    return liveResponse(body);
  } });
  const workouts = structuredClone(fixture.state.workoutLogs);
  const request = fixture.client.request(liveOptions);
  await entered.promise;
  fixture.client.cancel();
  release.resolve();
  await assert.rejects(request, { code: "cancelled" });
  assert.equal(fixture.state.aiReviews.length, 0);
  assert.equal(fixture.calls.persist, 0);
  assert.deepEqual(fixture.state.workoutLogs, workouts);
});

test("network timeout performs no automatic retry and preserves all local records", async () => {
  const fixture = harness({ timeoutMs: 5, fetchImpl: (_url, request) => new Promise((_resolve, reject) => {
    request.signal.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")), { once: true });
  }) });
  const before = structuredClone(fixture.state);
  await assert.rejects(fixture.client.request(liveOptions), { code: "timeout" });
  assert.equal(fixture.calls.fetch, 1);
  assert.equal(fixture.calls.persist, 0);
  assert.deepEqual(fixture.state, before);
  assert.equal(fixture.client.busy, false);
});

test("failed explicit regeneration retries reuse a nonce; a later regeneration gets a new nonce", async () => {
  let attempt = 0;
  const fixture = harness({ fetchImpl: (_url, _request, body) => {
    attempt += 1;
    if (attempt === 2) throw new TypeError("Test network failure after the request may have reached the server");
    return liveResponse(body);
  } });
  await fixture.client.request(liveOptions);
  assert.equal(fixture.calls.requests[0].body.requestId, undefined);
  await assert.rejects(fixture.client.request({ ...liveOptions, regenerate: true }), /Test network failure/);
  assert.equal(fixture.state.aiReviews.length, 1);
  await fixture.client.request({ ...liveOptions, regenerate: true });
  await fixture.client.request({ ...liveOptions, regenerate: true });
  const [, failed, retry, next] = fixture.calls.requests;
  assert.match(failed.body.requestId, /^[a-f0-9-]{36}$/);
  assert.equal(retry.body.requestId, failed.body.requestId);
  assert.notEqual(next.body.requestId, retry.body.requestId);
  assert.equal(next.body.inputFingerprint, retry.body.inputFingerprint);
  assert.equal(fixture.state.aiReviews.length, 3);
});

test("a draft alone is insufficient and never initiates a request", async () => {
  const fixture = harness();
  fixture.state.workoutLogs = {};
  await assert.rejects(fixture.client.request(liveOptions), { code: "insufficient_data" });
  assert.equal(fixture.calls.fetch, 0);
  assert.equal(Object.keys(fixture.state.workoutDrafts).length, 1);
});

test("a week with zero eligible workouts can still open a saved review", async () => {
  const fixture = harness();
  const first = await fixture.client.request(liveOptions);
  fixture.state.workoutLogs = {};
  const prepared = await fixture.client.prepare("completed", "live");
  assert.equal(prepared.payload.metrics.current.recordedWorkouts, 0);
  assert.equal(prepared.stored.id, first.review.id);
  assert.equal((await fixture.client.request(liveOptions)).reused, true);
  await assert.rejects(fixture.client.request({ ...liveOptions, regenerate: true }), { code: "insufficient_data" });
  assert.equal(fixture.calls.fetch, 1);
});

test("a response is marked stale when inputs changed while generation was in flight", async () => {
  const entered = deferred();
  const release = deferred();
  const fixture = harness({ mockAdapter: async (payload) => {
    entered.resolve();
    await release.promise;
    return createMockReview(payload);
  } });
  const request = fixture.client.request();
  await entered.promise;
  fixture.state.aiReviewProfile.constraints = "새로 기록한 사용자 제약";
  release.resolve();
  const result = await request;
  assert.equal(result.stale, true);
  assert.equal(fixture.state.aiReviews.length, 1);
  assert.equal((await fixture.client.prepare()).stale, true);
});

test("replacing app state while a request runs does not write the response into either state", async () => {
  const entered = deferred();
  const release = deferred();
  const fixture = harness({ mockAdapter: async (payload) => {
    entered.resolve();
    await release.promise;
    return createMockReview(payload);
  } });
  const owner = fixture.state;
  const request = fixture.client.request();
  await entered.promise;
  fixture.replaceState(createDefaultState());
  release.resolve();
  await assert.rejects(request, { code: "cancelled" });
  assert.deepEqual(owner.aiReviews, []);
  assert.deepEqual(fixture.state.aiReviews, []);
});

test("the review cap blocks new paid requests and retains every existing review", async () => {
  const fixture = harness();
  const first = await fixture.client.request();
  fixture.state.aiReviews = Array.from({ length: MAX_STORED_REVIEWS }, (_, index) => ({
    ...structuredClone(first.review), id: `review-${index}`,
  }));
  await assert.rejects(fixture.client.request({ ...liveOptions, regenerate: true }), { code: "storage_limit" });
  assert.equal(fixture.calls.fetch, 0);
  assert.equal(fixture.state.aiReviews.length, MAX_STORED_REVIEWS);
  assert.equal((await fixture.client.request()).reused, true);
});
