// Shared record selection and controls for the next-session load review.
const numeric = (value) => value !== '' && value != null && Number.isFinite(Number(value)) && Number(value) >= 0 ? Number(value) : null;
const rounded = (value) => Math.round(value * 1000000) / 1000000;

export function loadReviewContext(log, exerciseId, history, advice) {
  const exercise = log.exercises[exerciseId];
  const field = exercise.coachingPlan.kind === 'pullup' ? 'assistance' : 'weight';
  const workingSets = (entry) => (entry.sets || []).filter(set => set.completed).map(set => ({
    load: field === 'assistance' && entry.measurement === 'reps' ? 0 : numeric(set[field]),
    reps: numeric(set.reps),
  }));
  const current = workingSets(exercise);
  const direction = advice.nextStep === 3 ? -1 : advice.action === 'reduce' ? (field === 'assistance' ? 1 : -1) : 1;
  const known = current.map(set => set.load).filter(value => value !== null);
  const reference = current.length && known.length === current.length
    ? (direction < 0 ? Math.min(...known) : Math.max(...known)) : null;
  const recent = Object.values(history || {}).filter(entry => {
    const candidate = entry.exercises?.[exerciseId];
    return entry.date < log.date && (entry.planId || 'form-flow') === (log.planId || 'form-flow') && candidate &&
      (candidate.variantId || exerciseId) === (exercise.variantId || exerciseId) &&
      candidate.measurement === exercise.measurement && candidate.progressionStep === exercise.progressionStep;
  }).sort((a, b) => b.date.localeCompare(a.date))
    .map(entry => ({ date: entry.date, sets: workingSets(entry.exercises[exerciseId]).filter(set => set.load !== null) }))
    .filter(entry => entry.sets.length).slice(0, 5);
  return { field, current, reference, direction, recent };
}

export function loadChoices(context, increment, selected) {
  const step = numeric(increment);
  if (!step || context.reference === null) return [];
  const values = [context.reference, ...context.recent.flatMap(entry => entry.sets.map(set => set.load))];
  if (numeric(selected) !== null) values.push(Number(selected));
  for (let i = -12; i <= 12; i++) values.push(rounded(context.reference + i * step));
  return [...new Set(values.filter(value => value >= 0))].sort((a, b) => a - b);
}

export function mountLoadPicker(root, context) {
  const element = (tag, text, className) => {
    const node = document.createElement(tag);
    if (text !== undefined) node.textContent = text;
    if (className) node.className = className;
    return node;
  };
  root.className = 'load-picker';
  const label = context.field === 'assistance' ? 'assistance' : 'load';
  const currentText = context.current.map(set => `${set.load ?? 'Missing'} kg${set.reps === null ? '' : ` × ${set.reps}`}`).join(' / ');
  root.append(element('p', `This workout · ${currentText || 'No completed sets'}`, 'load-record'));
  if (context.field === 'assistance') root.append(element('p', 'More assistance = easier. Less assistance = harder.', 'load-hint'));
  if (context.reference === null) root.append(element('p', 'Complete the missing working-set loads in this workout before choosing a next target.', 'load-hint'));
  const heading = element('label', `Next ${label} (kg)`, 'load-heading');
  heading.htmlFor = 'coach-load';
  const input = element('input');
  input.id = 'coach-load'; input.type = 'number'; input.min = '0'; input.step = 'any'; input.inputMode = 'decimal';
  input.setAttribute('aria-describedby', 'coach-load-change coach-load-note');
  // Start at the recorded boundary: a change remains an explicit user choice.
  input.value = context.reference ?? '';
  const delta = element('p', '', 'load-change'); delta.id = 'coach-load-change'; delta.setAttribute('aria-live', 'polite');
  root.append(heading, input, delta);
  const controls = element('div', undefined, 'load-slider-row');
  const minus = element('button', '−', 'button button-secondary'); minus.type = 'button'; minus.setAttribute('aria-label', 'Decrease kilograms');
  const plus = element('button', '+', 'button button-secondary'); plus.type = 'button'; plus.setAttribute('aria-label', 'Increase kilograms');
  const slider = element('input'); slider.type = 'range'; slider.min = '0'; slider.step = '1'; slider.setAttribute('aria-label', `Next ${label} in kilograms`);
  controls.append(minus, slider, plus);
  const stepLabel = element('label', 'Adjustment step (kg)', 'load-step');
  const stepInput = element('input'); stepInput.type = 'number'; stepInput.min = '0.001'; stepInput.step = 'any'; stepInput.value = '2.5'; stepInput.inputMode = 'decimal';
  stepLabel.append(stepInput);
  const note = element('small', 'Set the step to match your equipment, or type any available load above. Past weights are references, not a guarantee of equipment availability. Nothing changes until you accept.');
  note.id = 'coach-load-note';
  root.append(controls, stepLabel, note);
  let choices = [];
  const update = () => {
    const value = numeric(input.value);
    const step = numeric(stepInput.value);
    choices = loadChoices(context, step, value);
    slider.max = String(Math.max(0, choices.length - 1));
    slider.value = String(Math.max(0, choices.indexOf(value)));
    slider.setAttribute('aria-valuetext', value === null ? 'No load selected' : `${value} kilograms`);
    slider.disabled = !choices.length || value === null;
    minus.disabled = !step || value === null || value < step || context.reference === null;
    plus.disabled = !step || value === null || context.reference === null;
    stepInput.setCustomValidity(step ? '' : 'Enter a positive adjustment step.');
    if (value === null || context.reference === null) delta.textContent = 'Enter a load after checking the workout record.';
    else {
      const change = rounded(value - context.reference);
      const comparison = context.direction < 0 ? 'lowest' : 'highest';
      const valid = context.direction * change > 0;
      delta.textContent = `${change > 0 ? '+' : ''}${change} kg vs this workout’s ${comparison} working load (${context.reference} kg). ${valid ? 'Direction matches the recommendation.' : `Choose ${context.direction < 0 ? 'less' : 'more'} ${label}.`}`;
    }
  };
  minus.addEventListener('click', () => { input.value = rounded(Number(input.value) - Number(stepInput.value)); update(); });
  plus.addEventListener('click', () => { input.value = rounded(Number(input.value) + Number(stepInput.value)); update(); });
  slider.addEventListener('input', () => { input.value = choices[Number(slider.value)]; update(); });
  input.addEventListener('input', update); stepInput.addEventListener('input', update);
  const records = element('div', undefined, 'load-history');
  records.append(element('h4', 'Recent working loads'));
  if (!context.recent.length) records.append(element('p', 'No earlier matching workout. Start from this workout and set your equipment’s step.', 'load-hint'));
  for (const entry of context.recent) {
    const row = element('div', undefined, 'load-history-row');
    row.append(element('span', entry.date));
    for (const value of new Set(entry.sets.map(set => set.load))) {
      const button = element('button', `${value} kg`, 'button button-secondary'); button.type = 'button';
      button.setAttribute('aria-label', `Use ${value} kilograms from ${entry.date}`);
      button.addEventListener('click', () => { input.value = value; update(); });
      row.append(button);
    }
    records.append(row);
  }
  root.append(records);
  update();
}
