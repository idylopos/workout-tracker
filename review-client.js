import { buildReviewPayload, fingerprintReviewPayload } from "./weekly-review.js";
import { createMockReview, validateReviewResult } from "./review-contract.js";
import { MAX_STORED_REVIEWS, validateStoredReview } from "./review-storage.js";

export const REVIEW_CONSENT_VERSION = "1";
export const REVIEW_TIMEOUT_MS = 55_000;

export class ReviewError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

export function findPeriodReview(reviews, payload, mode) {
  return [...reviews].reverse().find((entry) => entry.planId === payload.plan.id &&
    entry.period.start === payload.period.start && entry.period.partial === payload.period.partial &&
    entry.meta.mode === mode);
}

export function createReviewClient({ getState, getPlan, persist, isUnlocked, endpoint = "", fetchImpl = globalThis.fetch,
  now = () => new Date(), mockAdapter = createMockReview, timeoutMs = REVIEW_TIMEOUT_MS }) {
  let pending = null;
  let abort = null;
  let generation = 0;
  let regenerationAttempt = null;

  async function prepare(periodMode = "completed", mode = "mock") {
    if (!isUnlocked()) throw new ReviewError("locked", "먼저 앱 잠금을 해제해 주세요.");
    const payload = buildReviewPayload(getState(), getPlan(), { mode: periodMode, now: now() });
    const inputFingerprint = await fingerprintReviewPayload(payload);
    const stored = findPeriodReview(getState().aiReviews, payload, mode);
    return { payload, inputFingerprint, stored, stale: Boolean(stored && stored.inputFingerprint !== inputFingerprint) };
  }

  async function execute({ periodMode = "completed", mode = "mock", regenerate = false, token = "" } = {}) {
    const ticket = generation;
    const owner = getState();
    const { payload, inputFingerprint, stored, stale } = await prepare(periodMode, mode);
    const assertCurrentSession = () => {
      if (ticket !== generation || !isUnlocked() || getState() !== owner) {
        throw new ReviewError("cancelled", "앱 상태가 바뀌어 분석을 취소했습니다.");
      }
    };
    assertCurrentSession();
    if (stored && !regenerate) return { review: stored, reused: true, stale };
    if (owner.aiReviews.length >= MAX_STORED_REVIEWS) {
      throw new ReviewError("storage_limit", "리뷰 저장 한도(500개)에 도달했습니다. 기존 리뷰와 백업은 그대로 유지됩니다. 추가 요청은 전송하지 않았습니다.");
    }
    if (!payload.metrics.current.recordedWorkouts) {
      throw new ReviewError("insufficient_data", "이 기간에는 완료된 운동 기록이 없습니다. 운동을 저장한 뒤 다시 확인해 주세요. 작성 중인 초안은 분석하지 않습니다.");
    }
    let response;
    if (mode === "live") {
      const consent = owner.aiReviewConsent;
      if (!endpoint || consent?.endpoint !== endpoint || consent?.version !== REVIEW_CONSENT_VERSION) {
        throw new ReviewError("consent", "실제 분석 전에 전송 항목과 API 사용 안내에 동의해 주세요.");
      }
      if (token.trim().length < 32) throw new ReviewError("auth", "서버에서 설정한 접근 토큰을 입력해 주세요. OpenAI API 키나 앱 암호가 아닙니다.");
      if (regenerate && regenerationAttempt?.fingerprint !== inputFingerprint) {
        regenerationAttempt = { fingerprint: inputFingerprint, requestId: crypto.randomUUID() };
      }
      const body = JSON.stringify({ payload, inputFingerprint,
        ...(regenerate ? { requestId: regenerationAttempt.requestId } : {}) });
      if (new TextEncoder().encode(body).length > 500 * 1024) throw new ReviewError("too_large", "분석 기록이 전송 한도를 초과했습니다. 기존 기록은 그대로 보관됩니다.");
      abort = new AbortController();
      const timer = setTimeout(() => abort?.abort(), timeoutMs);
      try {
        const res = await fetchImpl(endpoint, { method: "POST", credentials: "omit", redirect: "error",
          headers: { "Content-Type": "application/json", Authorization: `Bearer ${token.trim()}` },
          body, signal: abort.signal });
        const text = await res.text();
        if (text.length > 120_000) throw new ReviewError("invalid_response", "응답이 허용 크기를 초과했습니다.");
        let parsed;
        try { parsed = JSON.parse(text); } catch { throw new ReviewError("invalid_response", "서버 응답을 확인할 수 없습니다."); }
        if (!res.ok) throw new ReviewError(parsed.error?.code || String(res.status), "분석 요청을 완료하지 못했습니다.");
        response = parsed;
      } catch (error) {
        if (error.name === "AbortError") throw new ReviewError("timeout", "응답 대기 시간이 초과되었습니다. 잠시 후 직접 다시 시도해 주세요.");
        throw error;
      } finally { clearTimeout(timer); abort = null; }
    } else if (mode === "mock") response = await mockAdapter(payload);
    else throw new ReviewError("invalid_mode", "분석 모드를 확인해 주세요.");
    try { validateReviewResult(response.result, payload); }
    catch { throw new ReviewError("invalid_response", "응답의 근거 또는 형식을 검증하지 못했습니다."); }
    if (response.meta?.mode !== mode || typeof response.meta.model !== "string" ||
      response.meta.schemaVersion !== payload.schemaVersion || response.meta.promptVersion !== payload.promptVersion) {
      throw new ReviewError("invalid_response", "응답의 모델·버전 정보를 확인할 수 없습니다.");
    }
    assertCurrentSession();
    const review = { id: crypto.randomUUID(), planId: payload.plan.id, period: payload.period, inputFingerprint,
      result: response.result, meta: response.meta, createdAt: now().toISOString(),
      decisions: {}, evidence: payload.evidence, previousRecommendations: payload.previousRecommendations };
    if (!validateStoredReview(review)) throw new ReviewError("invalid_response", "응답의 저장 정보를 검증하지 못했습니다.");
    const currentFingerprint = await fingerprintReviewPayload(buildReviewPayload(owner, getPlan(), { mode: periodMode, now: now() }));
    assertCurrentSession();
    owner.aiReviews.push(review);
    regenerationAttempt = null;
    const saved = await persist();
    // Keep the result in memory if browser storage fails; let the user retry saving without another API request.
    return { review, reused: false, stale: currentFingerprint !== inputFingerprint, saved };
  }

  return {
    prepare,
    get busy() { return pending !== null; },
    request(options) {
      if (pending) return pending;
      pending = execute(options).finally(() => { pending = null; });
      return pending;
    },
    cancel() { generation += 1; abort?.abort(); },
  };
}
