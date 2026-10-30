import test from 'node:test';
import assert from 'node:assert/strict';
import { exercisesForSavedWorkout, WEEK_PLAN } from '../lib.js';

test('new Fridays use heel slides; saved reverse crunch records stay editable', () => {
  const planned = WEEK_PLAN.friday.exercises;
  const old = { exercises: { 'reverse-crunch': { name: 'Reverse crunch', measurement: 'reps', sets: [{ reps: 12, completed: true }] } } };
  const original = structuredClone(old);
  assert.ok(exercisesForSavedWorkout(planned, null).some(e => e.id === 'supine-heel-slide'));
  const restored = exercisesForSavedWorkout(planned, old);
  assert.ok(restored.some(e => e.id === 'reverse-crunch' && e.sets === 1));
  assert.ok(!restored.some(e => e.id === 'supine-heel-slide'));
  assert.deepEqual(old, original);
  old.exercises['supine-heel-slide'] = { sets: [{ reps: 6 }] };
  assert.ok(['reverse-crunch', 'supine-heel-slide'].every(id => exercisesForSavedWorkout(planned, old).some(e => e.id === id)));
  assert.equal(exercisesForSavedWorkout(planned, old, 'custom-plan'), planned);
});
