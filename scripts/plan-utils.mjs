export const PLAN_ID_PATTERN = /^[a-z0-9][a-z0-9-]{0,63}$/;
export const DAY_KEYS = new Set(["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]);
export const MEASUREMENT_KEYS = new Set([
  "completion",
  "weight_reps",
  "weight_distance",
  "reps",
  "assisted_reps",
  "duration",
  "distance_time",
  "distance",
]);

export function validatePlan(plan, folderName) {
  const errors = [];
  if (!plan || typeof plan !== "object" || Array.isArray(plan)) return ["plan.json must contain a JSON object."];
  if (plan.schemaVersion !== 1) errors.push("schemaVersion must be 1.");
  if (!PLAN_ID_PATTERN.test(folderName)) {
    errors.push("The plan folder must use lowercase letters, numbers, and hyphens only.");
  }
  if (folderName === "form-flow") errors.push('The plan ID "form-flow" is reserved for the built-in plan.');
  if (plan.id !== folderName) errors.push(`id must exactly match the folder name "${folderName}".`);
  if (typeof plan.name !== "string" || !plan.name.trim() || plan.name.length > 120) {
    errors.push("name must be a non-empty string of at most 120 characters.");
  }
  if (!plan.days || typeof plan.days !== "object" || Array.isArray(plan.days)) {
    errors.push("days must be an object.");
    return errors;
  }
  const suppliedDays = Object.entries(plan.days);
  if (!suppliedDays.length) errors.push("days must contain at least one weekday.");
  suppliedDays.forEach(([dayKey, day]) => {
    if (!DAY_KEYS.has(dayKey)) {
      errors.push(`Unknown weekday "${dayKey}".`);
      return;
    }
    if (!day || typeof day !== "object" || Array.isArray(day)) {
      errors.push(`${dayKey} must be an object.`);
      return;
    }
    if (!Array.isArray(day.exercises)) {
      errors.push(`${dayKey}.exercises must be an array.`);
      return;
    }
    if (day.warmup !== undefined && !Array.isArray(day.warmup)) {
      errors.push(`${dayKey}.warmup must be an array when provided.`);
    }
    day.exercises.forEach((exercise, index) => {
      const path = `${dayKey}.exercises[${index}]`;
      if (!exercise || typeof exercise !== "object" || Array.isArray(exercise)) {
        errors.push(`${path} must be an object.`);
        return;
      }
      if (!PLAN_ID_PATTERN.test(exercise.id || "")) errors.push(`${path}.id is invalid.`);
      if (typeof exercise.name !== "string" || !exercise.name.trim()) errors.push(`${path}.name is required.`);
      if (!MEASUREMENT_KEYS.has(exercise.measurement)) {
        errors.push(`${path}.measurement must be one of: ${[...MEASUREMENT_KEYS].join(", ")}.`);
      }
      if (!Number.isInteger(exercise.sets) || exercise.sets < 1 || exercise.sets > 20) {
        errors.push(`${path}.sets must be an integer from 1 to 20.`);
      }
      if (!Number.isFinite(exercise.rest) || exercise.rest < 0 || exercise.rest > 900) {
        errors.push(`${path}.rest must be a number from 0 to 900 seconds.`);
      }
      if (exercise.guidance !== undefined) {
        if (!exercise.guidance || typeof exercise.guidance !== "object" || Array.isArray(exercise.guidance)) {
          errors.push(`${path}.guidance must be an object when provided.`);
        } else {
          ["setup", "action", "watch"].forEach((key) => {
            if (
              typeof exercise.guidance[key] !== "string" ||
              !exercise.guidance[key].trim() ||
              exercise.guidance[key].length > 500
            ) {
              errors.push(`${path}.guidance.${key} must be a non-empty string of at most 500 characters.`);
            }
          });
          if (
            exercise.guidance.option !== undefined &&
            (typeof exercise.guidance.option !== "string" ||
              !exercise.guidance.option.trim() ||
              exercise.guidance.option.length > 500)
          ) {
            errors.push(`${path}.guidance.option must be a non-empty string of at most 500 characters when provided.`);
          }
        }
      }
    });
  });
  if (plan.longRuns !== undefined && !Array.isArray(plan.longRuns)) {
    errors.push("longRuns must be an array when provided.");
  }
  if (plan.longRunDay !== undefined && !DAY_KEYS.has(plan.longRunDay)) {
    errors.push("longRunDay must be a lowercase weekday.");
  }
  return errors;
}
