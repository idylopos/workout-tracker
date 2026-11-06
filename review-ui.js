import { createReviewClient, REVIEW_CONSENT_VERSION } from "./review-client.js";
import { reviewPeriod } from "./weekly-review.js";
import { normalizeReviewProfile } from "./review-storage.js";

const escape = (value) => String(value ?? "").replaceAll("&", "&amp;").replaceAll("<", "&lt;")
  .replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#039;");
const statusLabels = { applied: "적용함", not_yet: "아직", skipped: "건너뜀" };
const savedDate = (value) => new Intl.DateTimeFormat("ko-KR", {
  timeZone: "Asia/Singapore", dateStyle: "short", timeStyle: "short",
}).format(new Date(value));
const errors = {
  unauthorized: "접근 토큰이 올바르지 않습니다. 서버 설정을 확인해 주세요.",
  origin_denied: "현재 앱 주소가 서버의 허용 출처와 일치하지 않습니다.",
  rate_limit: "요청 한도에 도달했습니다. 잠시 후 다시 시도해 주세요.",
  quota: "API 크레딧 또는 사용 한도를 확인해야 합니다. 기존 기록은 안전하게 보관됩니다.",
  refusal: "모델이 이번 분석에 응답하지 않았습니다. 자동으로 대체 조언을 만들지 않습니다.",
  incomplete: "모델 응답이 완성되지 않았습니다. 서버의 출력 한도를 확인해 주세요.",
  invalid_response: "응답 형식이나 근거를 검증하지 못했습니다. 이 응답은 저장하지 않았습니다.",
  configuration: "분석 서버의 API 키·모델 설정이 필요합니다.",
  network: "분석 서버에 연결하지 못했습니다. 연결 상태와 서버 주소를 확인해 주세요.",
  busy: "서버에서 분석이 진행 중입니다. 잠시 후 다시 시도해 주세요.",
  invalid_request: "분석 데이터를 확인하지 못했습니다. 앱과 서버 버전을 확인해 주세요.",
};

export function mountReviewUi({ host, getState, getPlan, persist, isUnlocked, config }) {
  const client = createReviewClient({ getState, getPlan, persist, isUnlocked, endpoint: config.endpoint });
  host.innerHTML = `<div class="panel-head"><div><p class="eyebrow">WEEKLY REFLECTION</p>
    <h2>AI Review</h2><p>Review your week and follow through on suggestions.</p></div>
    <button type="button" class="button button-dark" id="ai-review-open" aria-expanded="false" aria-controls="ai-review-content">AI Review</button></div>
    <div id="ai-review-content" lang="ko" hidden>
      <div class="ai-review-controls"><label>분석 기간<select id="ai-review-period"><option value="completed">지난 완료 주</option><option value="current">이번 주 · 진행 중</option></select></label>
      <label>분석 모드<select id="ai-review-mode"><option value="mock">모의 응답 · 전송 없음</option>${config.endpoint ? '<option value="live">실제 API 분석</option>' : ""}</select></label></div>
      <p id="ai-review-range"></p><p id="ai-review-mode-note" class="ai-review-notice"></p>
      <details class="ai-review-profile"><summary>목표와 사용자 보고 사항</summary>
        <p>현재 진단을 뜻하지 않습니다. 필요하면 수정하고 저장하세요.</p>
        <label>목표<textarea id="ai-review-goals" rows="2" maxlength="1000"></textarea></label>
        <label>제약·유의 사항<textarea id="ai-review-constraints" rows="2" maxlength="1000"></textarea></label>
        <button class="button button-secondary" id="ai-review-profile-save" type="button">목표 저장</button>
      </details>
      <div id="ai-review-live" hidden>
        <p>전송 대상: 선택한 계획·목표·사용자 보고 사항, 선택 주와 이전 4주의 완료 운동·메모·수면·회복·기록된 신체 측정, 계산된 비교 지표, 이전 제안과 적용 상태입니다. 설정된 백엔드와 OpenAI로 전송됩니다. 초안, 앱 암호, 암호화 키는 전송하지 않습니다.</p>
        <p>API 사용은 크레딧을 소비할 수 있으며 ChatGPT 구독에 자동 포함된다고 가정하지 않습니다. 서버는 운동 기록 데이터베이스를 만들지 않습니다. OpenAI의 API 데이터 보관 정책이 적용됩니다.</p>
        <p id="ai-review-endpoint"></p>
        <label class="ai-review-consent"><input type="checkbox" id="ai-review-consent"> 위 항목의 전송과 API 사용에 동의합니다.</label>
        <label>백엔드 접근 토큰<input type="password" id="ai-review-token" autocomplete="off" spellcheck="false" placeholder="OpenAI API 키·앱 암호가 아닙니다"></label>
        <small>접근 토큰은 이 화면의 메모리에만 유지되며 백업에 포함되지 않습니다.</small>
        <button type="button" class="text-button" id="ai-review-revoke">전송 동의 철회</button>
      </div>
      <div class="ai-review-actions"><button class="button button-dark" id="ai-review-run" type="button">리뷰 만들기</button>
        <button class="button button-secondary" id="ai-review-regenerate" type="button" hidden>명시적으로 다시 분석</button>
        <button class="button button-secondary" id="ai-review-save-retry" type="button" hidden>저장 다시 시도</button></div>
      <p id="ai-review-status" role="status" aria-live="polite"></p>
      <div id="ai-review-result"></div>
      <details class="ai-review-history"><summary>저장된 리뷰</summary><div id="ai-review-history-list"></div></details>
      <p class="ai-review-footnote">정보 제공용 피드백입니다. 진단·치료를 대신하지 않으며, 증상이 지속되거나 악화되면 의료 전문가에게 평가받으세요. 제안의 적용 상태는 기록만 하며 운동 처방과 증량 규칙을 바꾸지 않습니다.</p>
    </div>`;
  const $ = (selector) => host.querySelector(selector);
  let selectedReview = null;
  let refreshTicket = 0;
  let knownPlan = "";
  let knownState = null;
  let retryRegenerate = false;
  const mode = () => $("#ai-review-mode").value;
  const periodMode = () => $("#ai-review-period").value;
  function status(text, error = false) {
    $("#ai-review-status").textContent = text;
    $("#ai-review-status").dataset.error = String(error);
  }
  function busy(value) {
    host.setAttribute("aria-busy", String(value));
    for (const selector of ["#ai-review-run", "#ai-review-regenerate", "#ai-review-period", "#ai-review-mode", "#ai-review-profile-save"]) $(selector).disabled = value;
  }
  function showMode() {
    const live = mode() === "live";
    $("#ai-review-live").hidden = !live;
    $("#ai-review-mode-note").textContent = live
      ? "실제 API 모드 · 요청할 때만 선택한 기록을 전송합니다."
      : "모의 응답 · AI API를 호출하지 않는 기능 확인용 예시입니다. 실제 AI 분석이 아닙니다.";
    const consent = getState().aiReviewConsent;
    $("#ai-review-consent").checked = consent?.endpoint === config.endpoint && consent?.version === REVIEW_CONSENT_VERSION;
    $("#ai-review-endpoint").textContent = `분석 서버: ${config.endpoint}`;
  }
  function renderHistory() {
    const entries = getState().aiReviews.filter((entry) => entry.planId === getPlan().id).slice().reverse();
    $("#ai-review-history-list").innerHTML = entries.length ? entries.map((entry) =>
      `<button class="text-button" type="button" data-review-id="${escape(entry.id)}">${escape(entry.period.start)} ~ ${escape(entry.period.end)} · ${entry.meta.mode === "mock" ? "모의" : "API"} · ${escape(savedDate(entry.createdAt))} SGT</button>`).join("") : "<p>아직 저장된 리뷰가 없습니다.</p>";
  }
  function evidence(ids, review) {
    const entries = ids.map((id) => review.evidence.find((item) => item.id === id)).filter(Boolean);
    return entries.length ? `<details class="ai-review-evidence"><summary>근거 ${entries.length}개</summary>${entries.map((item) =>
      `<p>${escape(item.label || item.id)}</p>`).join("")}</details>` : "";
  }
  function renderResult(review) {
    selectedReview = review;
    if (!review) { $("#ai-review-result").replaceChildren(); return; }
    const result = review.result;
    $("#ai-review-result").innerHTML = `<article class="ai-review-report">
      <p class="eyebrow">${review.meta.mode === "mock" ? "모의 응답 · 실제 AI 분석 아님" : "API 분석"} · ${escape(review.period.start)} ~ ${escape(review.period.end)}</p>
      <h3>이번 주 요약</h3><p>${escape(result.summary)}</p>
      <h3>기록에서 확인한 점</h3>${result.observations.map((item) => `<p>${escape(item.text)}</p>${evidence(item.evidenceIds, review)}`).join("")}
      <h3>회복</h3>${result.recoveryObservations.map((item) => `<p><strong>기록된 사실:</strong> ${escape(item.fact)}</p><p><strong>가능한 해석:</strong> ${escape(item.interpretation)}</p>${evidence(item.evidenceIds, review)}`).join("") || "<p>확인 가능한 회복 관찰이 없습니다.</p>"}
      <h3>다음 주 제안</h3>${result.recommendations.map((item) => `<section class="ai-review-recommendation"><h4>${escape(item.priority)}. ${escape(item.title)}</h4>
        <p>${escape(item.adjustment)}</p><p><strong>다음 주 확인:</strong> ${escape(item.checkNextWeek)}</p>${evidence(item.evidenceIds, review)}
        <label>적용 상태<select data-recommendation="${escape(item.id)}">${Object.entries(statusLabels).map(([value, label]) => `<option value="${value}"${(review.decisions[item.id] || "not_yet") === value ? " selected" : ""}>${label}</option>`).join("")}</select></label></section>`).join("") || "<p>추가 제안이 없습니다.</p>"}
      <h3>이전 제안 확인</h3>${result.followUp.map((item) => {
        const previous = review.previousRecommendations.find((entry) => entry.id === item.recommendationId);
        return `<p><strong>${escape(previous?.title || item.recommendationId)}</strong> · ${escape(statusLabels[previous?.status] || "아직")}</p><p>${escape(item.text)}</p>${evidence(item.evidenceIds, review)}`;
      }).join("") || "<p>이전 주에 저장된 제안이 없습니다.</p>"}
      <h3>부족한 정보</h3><ul>${result.missingInformation.map((item) => `<li>${escape(item)}</li>`).join("")}</ul>
      ${result.questions.length ? `<h3>다음에 확인할 질문</h3><ul>${result.questions.map((item) => `<li>${escape(item)}</li>`).join("")}</ul>` : ""}
      <details><summary>분석 정보</summary><p>모델: ${escape(review.meta.model)} · 프롬프트 ${escape(review.meta.promptVersion)} · 스키마 ${escape(review.meta.schemaVersion)}</p>
      <p>입력 지문: <code>${escape(review.inputFingerprint)}</code></p><p>토큰 사용: ${review.meta.usage ? escape(JSON.stringify(review.meta.usage)) : "제공되지 않음"}</p></details>
      </article>`;
  }
  async function refresh() {
    if ($("#ai-review-content").hidden || !isUnlocked() || client.busy) return;
    const ticket = ++refreshTicket;
    if (knownPlan !== getPlan().id || knownState !== getState()) {
      knownPlan = getPlan().id;
      knownState = getState();
      const profile = normalizeReviewProfile(getState().aiReviewProfile);
      $("#ai-review-goals").value = profile.goals;
      $("#ai-review-constraints").value = profile.constraints;
    }
    const period = reviewPeriod(periodMode());
    $("#ai-review-range").textContent = `${period.start} ~ ${period.end} · Asia/Singapore${period.partial ? " · 진행 중인 주" : " · 월요일–일요일 완료 주"}`;
    showMode();
    renderHistory();
    try {
      const prepared = await client.prepare(periodMode(), mode());
      if (ticket !== refreshTicket) return;
      retryRegenerate = false;
      renderResult(prepared.stored || null);
      $("#ai-review-regenerate").hidden = !prepared.stored;
      $("#ai-review-run").textContent = prepared.stored ? "저장된 리뷰 열기" : "리뷰 만들기";
      status(prepared.stale ? "기록·계획·목표 또는 이전 제안 상태가 변경되었습니다. 저장된 리뷰는 이전 입력 기준입니다. 새 분석은 ‘명시적으로 다시 분석’을 눌러야 실행됩니다." :
        prepared.stored ? "저장된 리뷰입니다. 다시 열어도 API를 호출하지 않습니다." : "완료된 운동 기록을 분석합니다. 작성 중인 초안은 제외됩니다.");
    } catch (error) { status(error.message, true); }
  }
  async function run(regenerate) {
    if (client.busy) return;
    const requestedPlan = { id: getPlan().id, name: getPlan().name };
    busy(true);
    status(mode() === "mock" ? "모의 리뷰를 준비하고 있습니다…" : "완료 기록을 분석하고 있습니다… 최대 약 55초가 걸릴 수 있습니다.");
    try {
      const outcome = await client.request({ periodMode: periodMode(), mode: mode(), regenerate, token: $("#ai-review-token").value });
      retryRegenerate = false;
      if (getPlan().id !== requestedPlan.id) {
        await refresh();
        status(`${requestedPlan.name}의 리뷰를 ${outcome.saved === false ? "아직 저장하지 못했습니다. 저장 다시 시도를 눌러 주세요." : "저장했습니다. 해당 계획의 저장된 리뷰에서 열 수 있습니다."}`);
        $("#ai-review-save-retry").hidden = outcome.saved !== false;
        return;
      }
      renderResult(outcome.review);
      renderHistory();
      $("#ai-review-regenerate").hidden = false;
      $("#ai-review-run").textContent = "저장된 리뷰 열기";
      $("#ai-review-save-retry").hidden = outcome.saved !== false;
      status(outcome.saved === false ? "분석은 완료되었지만 이 브라우저에 저장하지 못했습니다. ‘저장 다시 시도’를 누르세요. API를 다시 호출하지 않습니다." :
        outcome.stale ? "저장된 리뷰를 열었습니다. 입력이 변경되어 새 분석은 별도로 실행해야 합니다." :
        outcome.reused ? "저장된 리뷰를 열었습니다. API 호출이 없습니다." : "리뷰가 저장되었습니다. 다음 주 제안의 적용 상태를 기록할 수 있습니다.");
    } catch (error) {
      retryRegenerate = regenerate;
      status(errors[error.code] || (error.name === "TypeError" ? errors.network : error.message || "분석을 완료하지 못했습니다."), true);
      $("#ai-review-run").textContent = "다시 시도";
    } finally { busy(false); }
  }
  $("#ai-review-open").addEventListener("click", () => {
    const open = $("#ai-review-content").hidden;
    $("#ai-review-content").hidden = !open;
    $("#ai-review-open").setAttribute("aria-expanded", String(open));
    if (open) void refresh();
  });
  $("#ai-review-period").addEventListener("change", () => void refresh());
  $("#ai-review-mode").addEventListener("change", () => void refresh());
  $("#ai-review-run").addEventListener("click", () => void run(retryRegenerate));
  $("#ai-review-regenerate").addEventListener("click", () => void run(true));
  $("#ai-review-save-retry").addEventListener("click", async () => {
    const saved = await persist();
    $("#ai-review-save-retry").hidden = saved;
    status(saved ? "리뷰를 저장했습니다." : "저장 공간을 확인한 뒤 다시 시도해 주세요.", !saved);
  });
  $("#ai-review-profile-save").addEventListener("click", async () => {
    getState().aiReviewProfile = normalizeReviewProfile({ goals: $("#ai-review-goals").value, constraints: $("#ai-review-constraints").value });
    const saved = await persist();
    await refresh();
    if (!saved) status("목표를 저장하지 못했습니다. 저장 공간을 확인해 주세요.", true);
  });
  $("#ai-review-consent").addEventListener("change", async () => {
    getState().aiReviewConsent = $("#ai-review-consent").checked
      ? { endpoint: config.endpoint, version: REVIEW_CONSENT_VERSION, acceptedAt: new Date().toISOString() } : null;
    await persist();
  });
  $("#ai-review-revoke").addEventListener("click", async () => {
    client.cancel();
    getState().aiReviewConsent = null;
    $("#ai-review-consent").checked = false;
    $("#ai-review-token").value = "";
    await persist();
    status("전송 동의를 철회했습니다. 이미 전송된 요청은 취소되지 않을 수 있습니다.");
  });
  $("#ai-review-history-list").addEventListener("click", (event) => {
    const id = event.target.closest("[data-review-id]")?.dataset.reviewId;
    const entry = getState().aiReviews.find((item) => item.id === id && item.planId === getPlan().id);
    if (entry) { renderResult(entry); status("저장 당시의 리뷰와 근거입니다. API를 호출하지 않았습니다."); }
  });
  $("#ai-review-result").addEventListener("change", async (event) => {
    const id = event.target.dataset.recommendation;
    if (!id || !selectedReview?.result.recommendations.some((item) => item.id === id)) return;
    selectedReview.decisions[id] = event.target.value;
    const saved = await persist();
    status(saved ? "적용 상태를 저장했습니다. 운동 계획이나 증량은 변경되지 않습니다." : "적용 상태를 저장하지 못했습니다. 저장 다시 시도를 눌러 주세요.", !saved);
    $("#ai-review-save-retry").hidden = saved;
  });
  return { refresh, cancel: () => { client.cancel(); $("#ai-review-token").value = ""; } };
}
