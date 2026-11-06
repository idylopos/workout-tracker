import { REVIEW_PROMPT_VERSION, REVIEW_SCHEMA_VERSION, validateReviewResult } from "./review-contract.js";

export const MAX_STORED_REVIEWS = 500;
export const REVIEW_DECISIONS = ["applied", "not_yet", "skipped"];
export const DEFAULT_REVIEW_PROFILE = Object.freeze({
  goals: "근육 증가, 체지방 감소, 근력 운동과 러닝을 병행하며 지속 가능한 회복",
  constraints: "과거 어깨 충돌 증상 경험, 간헐적인 무릎 통증 (사용자 보고, 현재 진단 아님)",
});

const object = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const text = (value, max, allowEmpty = false) => typeof value === "string" &&
  (allowEmpty || value.trim().length > 0) && value.length <= max;
const fields = (value, allowed) => object(value) && Object.keys(value).every((key) => allowed.includes(key));
const timestamp = (value) => text(value, 40) && Number.isFinite(Date.parse(value));
const day = (value) => typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value) &&
  Number.isFinite(Date.parse(`${value}T00:00:00Z`)) && new Date(`${value}T00:00:00Z`).toISOString().slice(0, 10) === value;

export function normalizeReviewProfile(value) {
  return Object.fromEntries(Object.entries(DEFAULT_REVIEW_PROFILE).map(([key, fallback]) => [
    key, typeof value?.[key] === "string" ? value[key].trim().slice(0, 1000) : fallback,
  ]));
}

export function normalizeReviewConsent(value) {
  if (!object(value) || value.version !== REVIEW_SCHEMA_VERSION || !timestamp(value.acceptedAt)) return null;
  try {
    const endpoint = new URL(value.endpoint);
    if (endpoint.username || endpoint.password || endpoint.search || endpoint.hash ||
      !(endpoint.protocol === "https:" || (endpoint.protocol === "http:" &&
        ["localhost", "127.0.0.1", "[::1]"].includes(endpoint.hostname)))) return null;
    return { endpoint: endpoint.href, version: value.version, acceptedAt: value.acceptedAt };
  } catch {
    return null;
  }
}

function validPeriod(period) {
  if (!fields(period, ["start", "end", "comparisonStart", "partial", "timezone"]) ||
    !day(period.start) || !day(period.end) || !day(period.comparisonStart) ||
    typeof period.partial !== "boolean" || period.timezone !== "Asia/Singapore") return false;
  const start = Date.parse(`${period.start}T00:00:00Z`);
  const end = Date.parse(`${period.end}T00:00:00Z`);
  const comparison = Date.parse(`${period.comparisonStart}T00:00:00Z`);
  return new Date(start).getUTCDay() === 1 && end >= start && end - start <= 6 * 86400000 &&
    (period.partial || end - start === 6 * 86400000) && start - comparison === 28 * 86400000;
}

function validMeta(meta) {
  if (!fields(meta, ["mode", "model", "promptVersion", "schemaVersion", "usage"]) ||
    !["mock", "live"].includes(meta.mode) || !text(meta.model, 200) ||
    meta.promptVersion !== REVIEW_PROMPT_VERSION || meta.schemaVersion !== REVIEW_SCHEMA_VERSION) return false;
  if (meta.usage === null) return true;
  return fields(meta.usage, ["inputTokens", "outputTokens", "totalTokens"]) &&
    ["inputTokens", "outputTokens", "totalTokens"].every((key) => Number.isSafeInteger(meta.usage[key]) && meta.usage[key] >= 0) &&
    meta.usage.totalTokens === meta.usage.inputTokens + meta.usage.outputTokens;
}

function validEvidence(evidence) {
  return Array.isArray(evidence) && evidence.length <= 5000 && evidence.every((entry) =>
    fields(entry, ["id", "label"]) && text(entry.id, 256) && text(entry.label, 2000)) &&
    new Set(evidence.map((entry) => entry.id)).size === evidence.length;
}

function validPreviousRecommendations(entries) {
  return Array.isArray(entries) && entries.length <= 1500 && entries.every((entry) =>
    fields(entry, ["id", "originalId", "reviewId", "status", "title", "adjustment", "periodStart"]) &&
    text(entry.id, 256) && text(entry.originalId, 128) && text(entry.reviewId, 128) &&
    REVIEW_DECISIONS.includes(entry.status) && text(entry.title, 1000) && text(entry.adjustment, 4000) && day(entry.periodStart)) &&
    new Set(entries.map((entry) => entry.id)).size === entries.length;
}

// Backups are untrusted input. Validate the same evidence references as a fresh
// response before preserving a review through normalization or vault unlock.
export function validateStoredReview(entry) {
  try {
    if (!fields(entry, ["id", "planId", "period", "inputFingerprint", "result", "meta", "createdAt", "decisions", "evidence", "previousRecommendations"]) ||
      !text(entry.id, 128) || typeof entry.planId !== "string" || !/^[a-z0-9][a-z0-9-]{0,63}$/.test(entry.planId) ||
      !validPeriod(entry.period) || !/^[a-f0-9]{64}$/.test(entry.inputFingerprint) ||
      !timestamp(entry.createdAt) || !validMeta(entry.meta) || !validEvidence(entry.evidence) ||
      !validPreviousRecommendations(entry.previousRecommendations) || !object(entry.decisions)) return false;
    if (new TextEncoder().encode(JSON.stringify(entry)).byteLength > 300_000) return false;
    validateReviewResult(entry.result, { evidence: entry.evidence, previousRecommendations: entry.previousRecommendations });
    const recommendationIds = new Set(entry.result.recommendations.map((recommendation) => recommendation.id));
    return Object.entries(entry.decisions).every(([id, decision]) => recommendationIds.has(id) && REVIEW_DECISIONS.includes(decision));
  } catch {
    return false;
  }
}

export function validateStoredReviews(value) {
  return value === undefined || (Array.isArray(value) && value.length <= MAX_STORED_REVIEWS &&
    value.every(validateStoredReview) && new Set(value.map((entry) => entry.id)).size === value.length);
}

export function normalizeReviews(value) {
  if (!Array.isArray(value)) return [];
  const seen = new Set();
  return value.slice(-MAX_STORED_REVIEWS).filter((entry) => {
    if (!validateStoredReview(entry) || seen.has(entry.id)) return false;
    seen.add(entry.id);
    return true;
  }).map((entry) => structuredClone(entry));
}
