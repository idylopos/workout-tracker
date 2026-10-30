import test from 'node:test';
import assert from 'node:assert/strict';
import { loadReviewContext, loadChoices } from '../load-picker.js';
import { nextSessionTarget } from '../progression.js';
const make = (date = '2026-10-30', loads = [30, 27.5]) => ({ date, planId: 'form-flow', exercises: { press: {
  measurement: 'weight_reps', coachingPlan: { kind: 'strength' },
  sets: loads.map(weight => ({ weight, reps: 10, completed: true })),
} } });

test('load review uses completed working sets and direction boundaries', () => {
  const log = make();
  log.exercises.press.sets.push({ weight: 5, completed: false });
  const reduce = loadReviewContext(log, 'press', {}, { action: 'reduce' });
  assert.equal(reduce.reference, 27.5);
  assert.equal(reduce.current.length, 2);
  assert.equal(loadReviewContext(log, 'press', {}, { action: 'increase' }).reference, 30);
  assert.equal(nextSessionTarget(log, 'press', { action: 'reduce' }, 27.5), null);
  assert.equal(nextSessionTarget(log, 'press', { action: 'reduce' }, 25).value, 25);
});

test('history excludes other plans, variants, units/measurements, future and incomplete sets', () => {
  const log = make();
  const valid = make('2026-10-20', [22.5, 25]);
  const otherPlan = { ...make('2026-10-25'), planId: 'other' };
  const variant = make('2026-10-26'); variant.exercises.press.variantId = 'other';
  const measurement = make('2026-10-27'); measurement.exercises.press.measurement = 'assisted_reps';
  const incomplete = make('2026-10-28'); incomplete.exercises.press.sets.forEach(set => set.completed = false);
  const context = loadReviewContext(log, 'press', { valid, otherPlan, variant, measurement, incomplete, future: make('2026-11-01') }, { action: 'reduce' });
  assert.deepEqual(context.recent.map(entry => entry.date), ['2026-10-20']);
  assert.deepEqual(context.recent[0].sets.map(set => set.load), [22.5, 25]);
});

test('missing current loads stay unknown; zero and decimal loads remain usable', () => {
  assert.equal(loadReviewContext(make(undefined, ['']), 'press', {}, { action: 'reduce' }).reference, null);
  const context = loadReviewContext(make(undefined, [0]), 'press', {}, { action: 'increase' });
  assert.equal(context.reference, 0);
  assert.ok(loadChoices(context, 0.1).includes(0.3));
  assert.ok(loadChoices(context, 0.1, 1.125).includes(1.125));
  assert.ok(loadChoices(context, 0.1).every(value => value >= 0));
  assert.deepEqual(loadChoices(context, 0), []);
});

test('pull-up assistance reverses reduction direction and step 3 requires less assistance', () => {
  const log = make();
  const exercise = log.exercises.press;
  exercise.coachingPlan.kind = 'pullup'; exercise.measurement = 'assisted_reps';
  exercise.sets = [20, 25].map(assistance => ({ assistance, reps: 8, completed: true }));
  const context = loadReviewContext(log, 'press', {}, { action: 'reduce' });
  assert.equal(context.field, 'assistance'); assert.equal(context.direction, 1); assert.equal(context.reference, 25);
  assert.equal(nextSessionTarget(log, 'press', { action: 'reduce' }, 27.5).value, 27.5);
  const step = loadReviewContext(log, 'press', {}, { action: 'step', nextStep: 3 });
  assert.equal(step.direction, -1); assert.equal(step.reference, 20);
  exercise.measurement = 'reps'; exercise.sets = [{ reps: 5, completed: true }];
  assert.equal(loadReviewContext(log, 'press', {}, { action: 'reduce' }).reference, 0);
});
