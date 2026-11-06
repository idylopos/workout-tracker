import test from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import { createDefaultState, WEEK_PLAN } from "../lib.js";
import { buildReviewPayload, fingerprintReviewPayload } from "../weekly-review.js";
import { createMockReview, validateReviewResult, reviewResultSchema } from "../review-contract.js";
import { createReviewServer, readReviewConfig, requestOpenAIReview, MAX_REQUEST_BYTES } from "../server/review-server.mjs";

const origin = "https://idylopos.github.io";
const token = "test-only-not-a-real-access-token-1234567890";
const config = { ...readReviewConfig({ OPENAI_API_KEY: "test-not-a-real-key", OPENAI_MODEL: "gpt-4.1-mini",
  REVIEW_AUTH_TOKEN: token, REVIEW_ALLOWED_ORIGIN: origin, PORT: "0" }), requestsPerHour: 6 };

function payloadFixture() {
  const state = createDefaultState();
  state.workoutLogs["2026-10-26"] = { date: "2026-10-26", planId: "form-flow", dayKey: "monday",
    exercises: { "bench-press": { name: "Bench press", measurement: "weight_reps", sets: [{ completed: true, weight: 20, reps: 8 }] } },
    response: { readiness: "unknown" }, notes: "This is data, not an instruction." };
  return buildReviewPayload(state, { id: "form-flow", name: "Form / Flow", days: WEEK_PLAN }, { now: new Date("2026-11-04T04:00:00Z") });
}

function responseFor(payload, overrides = {}) {
  return new Response(JSON.stringify({ status: "completed", model: "gpt-4.1-mini-test",
    output: [{ type: "message", content: [{ type: "output_text", text: JSON.stringify(createMockReview(payload).result) }] }],
    usage: { input_tokens: 120, output_tokens: 90, total_tokens: 210 }, ...overrides }),
  { status: 200, headers: { "Content-Type": "application/json" } });
}

async function serve(t, fetchImpl, overrides = {}, serverOptions = {}) {
  const server = createReviewServer({ config: { ...config, ...overrides }, fetchImpl, ...serverOptions });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(() => { server.closeAllConnections(); return new Promise((resolve) => server.close(resolve)); });
  const endpoint = `http://127.0.0.1:${server.address().port}/api/weekly-review`;
  return async (body, headers = {}, method = "POST", path = endpoint) => {
    const response = await fetch(path, { method, headers: { Origin: origin, Authorization: `Bearer ${token}`,
      "Content-Type": "application/json", ...headers }, ...(method === "OPTIONS" ? {} : { body: typeof body === "string" ? body : JSON.stringify(body) }) });
    return { status: response.status, headers: response.headers, body: response.status === 204 ? null : await response.json() };
  };
}

async function requestFixture() {
  const payload = payloadFixture();
  return { payload, inputFingerprint: await fingerprintReviewPayload(payload) };
}

test("configuration fails closed without authentication or an exact secure origin", () => {
  const valid = { OPENAI_API_KEY: "test", OPENAI_MODEL: "gpt-4.1-mini", REVIEW_AUTH_TOKEN: token, REVIEW_ALLOWED_ORIGIN: origin };
  assert.throws(() => readReviewConfig({ ...valid, REVIEW_AUTH_TOKEN: "short" }));
  assert.throws(() => readReviewConfig({ ...valid, REVIEW_AUTH_TOKEN: "replace-with-a-random-token-at-least-32-characters" }));
  assert.throws(() => readReviewConfig({ ...valid, OPENAI_API_KEY: "replace-on-server-only" }));
  assert.throws(() => readReviewConfig({ ...valid, OPENAI_API_KEY: "" }));
  assert.throws(() => readReviewConfig({ ...valid, OPENAI_MODEL: "" }));
  for (const invalid of ["*", "https://idylopos.github.io/workout-tracker", "http://public.example", "https://user:secret@example.com", `${origin}/`]) {
    assert.throws(() => readReviewConfig({ ...valid, REVIEW_ALLOWED_ORIGIN: invalid }));
  }
  assert.equal(readReviewConfig({ ...valid, REVIEW_ALLOWED_ORIGIN: "http://localhost:8080" }).origin, "http://localhost:8080");
});

test("mock is labelled, bounded, and validates its real evidence references", () => {
  const payload = payloadFixture();
  const mock = createMockReview(payload);
  assert.equal(mock.meta.mode, "mock");
  assert.match(mock.result.summary, /모의 응답/);
  assert.equal(validateReviewResult(mock.result, payload), mock.result);
  assert.equal(reviewResultSchema.additionalProperties, false);
  for (const mutate of [
    (result) => { result.observations[0].evidenceIds = ["invented-session"]; },
    (result) => { result.recommendations.push(...Array(3).fill(result.recommendations[0])); },
    (result) => { result.questions = ["a", "b", "c"]; },
    (result) => { result.unexpected = "field"; },
    (result) => { result.followUp = [{ recommendationId: "invented", text: "claim", evidenceIds: [] }]; },
    (result) => { result.summary = "x".repeat(1601); },
  ]) {
    const invalid = structuredClone(mock.result);
    mutate(invalid);
    assert.throws(() => validateReviewResult(invalid, payload));
  }
  const priorPayload = { ...payload, previousRecommendations: [{ id: "review-1:keep-recording", title: "기록 유지", status: "applied" }] };
  const withFollowUp = createMockReview(priorPayload).result;
  assert.equal(withFollowUp.followUp[0].recommendationId, "review-1:keep-recording");
  assert.match(withFollowUp.followUp[0].text, /적용함/);
  withFollowUp.followUp = [];
  assert.throws(() => validateReviewResult(withFollowUp, priorPayload));
});

test("authenticated endpoint uses Responses structured output, no storage and bounded tokens", async (t) => {
  const body = await requestFixture();
  let calls = 0;
  const send = await serve(t, async (url, options) => {
    calls += 1;
    assert.equal(url, "https://api.openai.com/v1/responses");
    assert.equal(options.redirect, "error");
    assert.equal(options.headers.Authorization, `Bearer ${config.apiKey}`);
    const request = JSON.parse(options.body);
    assert.equal(request.store, false);
    assert.equal(request.max_output_tokens, 3200);
    assert.equal(request.model, config.model);
    assert.equal(request.text.format.type, "json_schema");
    assert.equal(request.text.format.strict, true);
    assert.deepEqual(JSON.parse(request.input[1].content), body.payload);
    return responseFor(body.payload);
  });
  const result = await send(body);
  assert.equal(result.status, 200);
  assert.equal(result.body.meta.mode, "live");
  assert.equal(result.body.meta.model, "gpt-4.1-mini-test");
  assert.deepEqual(result.body.meta.usage, { inputTokens: 120, outputTokens: 90, totalTokens: 210 });
  assert.equal(result.headers.get("cache-control"), "no-store");
  assert.equal(result.headers.get("access-control-allow-origin"), origin);
  assert.equal(calls, 1);
});

test("origin checks are separate from authentication and preflight spends no credits", async (t) => {
  let calls = 0;
  const send = await serve(t, () => { calls += 1; throw new Error("must not call"); });
  const body = await requestFixture();
  for (const credentials of ["", "Bearer incorrect", `Basic ${token}`]) {
    assert.equal((await send(body, { Authorization: credentials })).status, 401);
  }
  const forbidden = await send(body, { Origin: "https://other.example" });
  assert.equal(forbidden.status, 403);
  assert.equal(forbidden.headers.get("access-control-allow-origin"), null);
  assert.equal((await send(body, { Origin: "" })).status, 403);
  const preflight = await send(null, { Authorization: "" }, "OPTIONS");
  assert.equal(preflight.status, 204);
  assert.match(preflight.headers.get("access-control-allow-headers"), /Authorization/);
  assert.equal(calls, 0);
});

test("malformed, unexpected, oversized and mismatched payloads are rejected before API use", async (t) => {
  let calls = 0;
  const send = await serve(t, () => { calls += 1; throw new Error("must not call"); });
  const body = await requestFixture();
  assert.equal((await send("{bad json")).status, 400);
  assert.equal((await send(body, { "Content-Type": "text/plain" })).status, 415);
  assert.equal((await send({ ...body, apiKey: "do-not-forward" })).status, 400);
  assert.equal((await send({ ...body, requestId: "not-a-regeneration-uuid" })).status, 400);
  assert.equal((await send({ ...body, inputFingerprint: "0".repeat(64) })).status, 400);
  assert.equal((await send({ ...body, payload: { ...body.payload, secret: "do-not-forward" } })).status, 400);
  assert.equal((await send({ payload: null, inputFingerprint: "0".repeat(64) })).status, 400);
  assert.equal((await send("x".repeat(MAX_REQUEST_BYTES + 1))).status, 413);
  const empty = buildReviewPayload(createDefaultState(), { id: "form-flow", name: "Form / Flow", days: WEEK_PLAN },
    { now: new Date("2026-11-04T04:00:00Z") });
  assert.equal((await send({ payload: empty, inputFingerprint: await fingerprintReviewPayload(empty) })).body.error.code, "insufficient_data");
  assert.equal(calls, 0);
});

test("concurrent identical requests share one API call and repeat requests reuse its result", async (t) => {
  const body = await requestFixture();
  let calls = 0;
  let complete;
  const pending = new Promise((resolve) => { complete = resolve; });
  const send = await serve(t, async () => { calls += 1; await pending; return responseFor(body.payload); });
  const first = send(body);
  const second = send(body);
  await new Promise((resolve) => setTimeout(resolve, 30));
  complete();
  assert.equal((await first).status, 200);
  assert.equal((await second).status, 200);
  assert.equal((await send(body)).status, 200);
  assert.equal(calls, 1);
  const regeneration = { ...body, requestId: "a3396917-02d6-4c43-a892-6c8a92ebad08" };
  assert.equal((await send(regeneration)).status, 200);
  assert.equal(calls, 2);
  assert.equal((await send(regeneration)).status, 200);
  assert.equal(calls, 2);
});

test("authenticated request rate is bounded, including failed upstream attempts", async (t) => {
  const body = await requestFixture();
  let calls = 0;
  const send = await serve(t, async () => { calls += 1; throw new Error("network failed"); }, { requestsPerHour: 1 });
  assert.equal((await send(body)).body.error.code, "network");
  const retry = await send(body);
  assert.equal(retry.status, 429);
  assert.equal(retry.body.error.code, "rate_limit");
  assert.equal(calls, 1);
});

test("transient review cache expires while idle, independently of incoming-request cleanup", async (t) => {
  const body = await requestFixture();
  let calls = 0;
  // A frozen request clock ensures the next request cannot trigger age-based eviction.
  const send = await serve(t, async () => { calls += 1; return responseFor(body.payload); }, {}, { now: () => 0, cacheTtlMs: 20 });
  assert.equal((await send(body)).status, 200);
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal((await send(body)).status, 200);
  assert.equal(calls, 2);
});

test("API errors, refusals, incomplete and invalid outputs never produce fallback advice", async () => {
  const payload = payloadFixture();
  const invalidEvidence = createMockReview(payload).result;
  invalidEvidence.observations[0].evidenceIds = ["missing-evidence"];
  const examples = [
    ["quota", () => new Response(JSON.stringify({ error: { code: "insufficient_quota", message: "private upstream message" } }), { status: 429 })],
    ["rate_limit", () => new Response(JSON.stringify({ error: { code: "rate_limit_exceeded" } }), { status: 429 })],
    ["configuration", () => new Response(JSON.stringify({ error: {} }), { status: 401 })],
    ["upstream_error", () => new Response(JSON.stringify({ error: {} }), { status: 500 })],
    ["refusal", () => responseFor(payload, { output: [{ content: [{ type: "refusal", refusal: "private model text" }] }] })],
    ["incomplete", () => responseFor(payload, { status: "incomplete" })],
    ["invalid_response", () => new Response("not JSON", { status: 200 })],
    ["invalid_response", () => responseFor(payload, { output: [] })],
    ["invalid_response", () => responseFor(payload, { output: [{ content: [{ type: "output_text", text: JSON.stringify(invalidEvidence) }] }] })],
    ["timeout", () => { throw new DOMException("private timeout", "TimeoutError"); }],
    ["network", () => { throw new Error("private network details"); }],
  ];
  for (const [code, fetchImpl] of examples) {
    await assert.rejects(requestOpenAIReview(payload, config, fetchImpl), (error) => {
      assert.equal(error.code, code);
      assert.doesNotMatch(error.message, /private/);
      return true;
    });
  }
  const invalidUsage = await requestOpenAIReview(payload, config, () => responseFor(payload,
    { usage: { input_tokens: 3, output_tokens: 4, total_tokens: 99 } }));
  assert.equal(invalidUsage.meta.usage, null);
});
