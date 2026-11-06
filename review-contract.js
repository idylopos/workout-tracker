// Shared by the static UI and server. Structured output is still checked locally.
export const REVIEW_SCHEMA_VERSION = "1";
export const REVIEW_PROMPT_VERSION = "1";

const string = (maxLength = 1200) => ({ type: "string", minLength: 1, maxLength });
const list = (items, maxItems, minItems = 0) => ({ type: "array", items, minItems, maxItems });
const object = (properties) => ({ type: "object", properties, required: Object.keys(properties), additionalProperties: false });
const evidenceIds = list(string(400), 8, 1);

export const reviewResultSchema = object({
  summary: string(1600),
  observations: list(object({ text: string(), evidenceIds }), 8),
  recoveryObservations: list(object({ fact: string(), interpretation: string(), evidenceIds }), 4),
  recommendations: list(object({
    id: { type: "string", pattern: "^[a-z0-9][a-z0-9_-]{0,63}$" },
    priority: { type: "integer", minimum: 1, maximum: 3 },
    title: string(160), evidenceIds, adjustment: string(), checkNextWeek: string(800),
  }), 3),
  followUp: list(object({ recommendationId: string(300), text: string(), evidenceIds: list(string(400), 8) }), 12),
  missingInformation: list(string(800), 12),
  questions: list(string(400), 2),
  note: string(600),
});

function assertShape(value, schema, path = "review") {
  if (schema.type === "object") {
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${path}: object required`);
    if (Object.keys(value).some((key) => !Object.hasOwn(schema.properties, key))) throw new Error(`${path}: unexpected field`);
    for (const key of schema.required) {
      if (!Object.hasOwn(value, key)) throw new Error(`${path}: missing field`);
      assertShape(value[key], schema.properties[key], `${path}.${key}`);
    }
  } else if (schema.type === "array") {
    if (!Array.isArray(value) || value.length < schema.minItems || value.length > schema.maxItems) throw new Error(`${path}: invalid list length`);
    value.forEach((item, index) => assertShape(item, schema.items, `${path}[${index}]`));
  } else if (schema.type === "string") {
    if (typeof value !== "string" || !value.trim() || value.length < (schema.minLength || 1) ||
      value.length > (schema.maxLength || 64) || (schema.pattern && !new RegExp(schema.pattern).test(value))) {
      throw new Error(`${path}: invalid text`);
    }
  } else if (!Number.isInteger(value) || value < schema.minimum || value > schema.maximum) {
    throw new Error(`${path}: invalid number`);
  }
}

export function validateReviewResult(result, payload) {
  assertShape(result, reviewResultSchema);
  const available = new Set((payload?.evidence || []).map((entry) => entry.id));
  const previous = new Set((payload?.previousRecommendations || []).map((entry) => entry.id));
  for (const entry of [...result.observations, ...result.recoveryObservations, ...result.recommendations, ...result.followUp]) {
    if (new Set(entry.evidenceIds).size !== entry.evidenceIds.length || entry.evidenceIds.some((id) => !available.has(id))) {
      throw new Error("Review cites evidence that does not exist in this request");
    }
  }
  if (result.followUp.length !== previous.size || result.followUp.some((entry) => !previous.has(entry.recommendationId)) ||
    new Set(result.followUp.map((entry) => entry.recommendationId)).size !== result.followUp.length) {
    throw new Error("Review cites an unknown or duplicate previous recommendation");
  }
  if (new Set(result.recommendations.map((entry) => entry.id)).size !== result.recommendations.length ||
    new Set(result.recommendations.map((entry) => entry.priority)).size !== result.recommendations.length) {
    throw new Error("Recommendation identifiers and priorities must be unique");
  }
  return result;
}

export function createMockReview(payload) {
  const evidence = payload.evidence?.[0];
  const evidenceIds = evidence ? [evidence.id] : [];
  const result = {
    summary: `[모의 응답] ${payload.period.start}–${payload.period.end}의 기록을 이용한 기능 확인용 예시입니다. OpenAI에 전송하지 않았으며 실제 AI 분석이 아닙니다.`,
    observations: evidence ? [{ text: `앱이 계산한 근거를 확인하세요: ${evidence.label}`, evidenceIds }] : [],
    recoveryObservations: [],
    recommendations: evidence ? [{ id: "keep-recording", priority: 1, title: "기록과 기존 계획 유지",
      evidenceIds, adjustment: "이 모의 제안은 운동 처방을 바꾸지 않습니다. 기존 증량 조건과 회복 확인을 그대로 따르세요.",
      checkNextWeek: "완료 기록과 회복·수면 기록이 충분한지 다음 주에 확인하세요." }] : [],
    followUp: (payload.previousRecommendations || []).slice(0, 12).map((entry) => ({
      recommendationId: entry.id,
      text: `이전 제안 ‘${entry.title}’의 사용자 기록은 ‘${{ applied: "적용함", not_yet: "아직", skipped: "건너뜀" }[entry.status] || "아직"}’입니다. 실제 수행 여부를 독립적으로 확인한 결과는 아닙니다.`,
      evidenceIds: [],
    })),
    missingInformation: (payload.limitations || []).slice(0, 12).map((entry) => String(entry).slice(0, 800)),
    questions: [],
    note: "정보 제공용입니다. 진단이나 치료가 아니며, 증상이 지속되거나 악화되면 의료진의 평가를 받으세요.",
  };
  validateReviewResult(result, payload);
  return { result, meta: { mode: "mock", model: "local-mock", promptVersion: REVIEW_PROMPT_VERSION,
    schemaVersion: REVIEW_SCHEMA_VERSION, usage: null } };
}
