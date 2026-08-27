export const APP_VERSION = 1;
export const STORAGE_KEY = "formflow.training.v1";

export const EXTRA_ACTIVITY_TYPES = ["walking", "cycling", "elliptical", "swimming", "running", "custom"];
export const EXTRA_ACTIVITY_MEASUREMENTS = ["duration", "distance_time", "distance"];

export const STRENGTH_PROGRESSION = {
  effort: "Finish compound working sets with 2–3 RIR and isolation working sets with 1–3 RIR. Power, mobility, cardio, and pull-up work follow their own prescriptions.",
  load: "When every planned working set reaches the top of its rep range at the target RIR with stable technique and symptoms in two sessions, add the smallest available load and restart near the lower end of the range.",
  volume: "Full weekly targets are about 12–13 fractional chest sets, 12 direct lat/mid-back sets plus rear-delt work, and 6 direct dynamic rectus-abdominis sets. For newly added work, perform 2 sets on the first two exposures before using the full prescription.",
};

export const OPTIONAL_RECOVERY_RULE = {
  sleepHours: 7,
  copy: "Keep optional Zone 2 cycling and Saturday accessory add-ons off by default until weekly average sleep is at least 7 hours and joints, legs, and usual energy have returned to baseline the following morning for two stable weeks. Then add only one optional item at a time.",
};

export const RUN_QUALITY_PROGRESSION = {
  base: "Tempo—10 min easy, 3 × 6 min at RPE 6–7 with 2 min easy, then 5–10 min easy; Intervals—10 min easy, 6 × 2 min at RPE 8 with 2 min easy, then 8–10 min easy",
  progression: "Complete each workout twice with stable form, joints, and following-morning recovery before adding work. Then progress tempo 3 × 6 → 3 × 7 → 3 × 8 min and intervals 6 × 2 → 5 × 3 → 4 × 4 min. Change duration rather than deliberately increasing pace, and use an easy Thursday when accumulated fatigue is above normal.",
};

export const MEASUREMENT_TYPES = {
  completion: {
    label: "Check-off only",
    short: "Done",
    fields: [],
  },
  weight_reps: {
    label: "Weight × reps",
    short: "Load",
    fields: [
      { key: "weight", label: "Weight", unit: "kg", min: 0, step: 0.5 },
      { key: "reps", label: "Reps", unit: "", min: 0, step: 1 },
      { key: "rir", label: "RIR", unit: "", min: 0, max: 10, step: 1 },
    ],
  },
  weight_distance: {
    label: "Weight + distance",
    short: "Carry",
    fields: [
      { key: "weight", label: "Weight", unit: "kg", min: 0, step: 0.5 },
      { key: "distance", label: "Distance", unit: "m", min: 0, step: 1 },
      { key: "rir", label: "RIR", unit: "", min: 0, max: 10, step: 1 },
    ],
  },
  reps: {
    label: "Reps only",
    short: "Reps",
    fields: [
      { key: "reps", label: "Reps", unit: "", min: 0, step: 1 },
      { key: "rir", label: "RIR", unit: "", min: 0, max: 10, step: 1 },
    ],
  },
  assisted_reps: {
    label: "Assistance × reps",
    short: "Assisted",
    fields: [
      { key: "assistance", label: "Assistance", unit: "kg", min: 0, step: 0.5 },
      { key: "reps", label: "Reps", unit: "", min: 0, step: 1 },
      { key: "rir", label: "RIR", unit: "", min: 0, max: 10, step: 1 },
    ],
  },
  duration: {
    label: "Time only",
    short: "Time",
    fields: [
      { key: "minutes", label: "Minutes", unit: "min", min: 0, step: 1 },
      { key: "seconds", label: "Seconds", unit: "sec", min: 0, max: 59, step: 1 },
      { key: "rpe", label: "RPE", unit: "", min: 0, max: 10, step: 1 },
    ],
  },
  distance_time: {
    label: "Distance + time",
    short: "Distance",
    fields: [
      { key: "distance", label: "Distance", unit: "km", min: 0, step: 0.1 },
      { key: "minutes", label: "Minutes", unit: "min", min: 0, step: 1 },
      { key: "seconds", label: "Seconds", unit: "sec", min: 0, max: 59, step: 1 },
      { key: "rpe", label: "RPE", unit: "", min: 0, max: 10, step: 1 },
    ],
  },
  distance: {
    label: "Distance only",
    short: "Distance",
    fields: [
      { key: "distance", label: "Distance", unit: "km", min: 0, step: 0.1 },
      { key: "rpe", label: "RPE", unit: "", min: 0, max: 10, step: 1 },
    ],
  },
};

export function preparePreviousSets(previousSets, targetCount, measurement) {
  const sources = Array.isArray(previousSets) ? previousSets : [];
  const count = Math.max(1, Number.parseInt(targetCount, 10) || 1);
  const reusableFields = (MEASUREMENT_TYPES[measurement]?.fields || [])
    .map((field) => field.key)
    .filter((key) => key !== "rir" && key !== "rpe");

  const source = sources.findLast((set) =>
    reusableFields.some((key) => set?.[key] !== undefined && set[key] !== null && set[key] !== ""),
  ) || {};

  return Array.from({ length: count }, () => {
    const nextSet = { completed: false };
    reusableFields.forEach((key) => {
      if (source[key] !== undefined && source[key] !== null && source[key] !== "") {
        nextSet[key] = source[key];
      }
    });
    return nextSet;
  });
}

export function shouldShowRestTimer(view, running, finished) {
  return view === "today" || Boolean(running) || Boolean(finished);
}

export function shouldCollapseExerciseByDefault(exercise, savedExercise, compactViewport) {
  return Boolean(compactViewport && exercise?.optional && !savedExercise);
}

export const PULL_UP_STEPS = [
  {
    id: 1,
    short: "Base",
    label: "Step 1 · Assisted base",
    title: "Assisted neutral-grip pull-up",
    prescription: "3 × 5 · choose assistance that leaves about 2 reps in reserve",
    sets: 3,
    measurement: "assisted_reps",
    target: "Complete all 3 × 5 with smooth, full-range reps.",
    next: "After 2 successful sessions, keep the same assistance and move to Step 2.",
  },
  {
    id: 2,
    short: "Build reps",
    label: "Step 2 · Build assisted reps",
    title: "Assisted neutral-grip pull-up",
    prescription: "3 × 6–8 · keep at least 1 rep in reserve",
    sets: 3,
    measurement: "assisted_reps",
    target: "Build to 3 × 8 without shortening the range or kicking.",
    next: "After 2 successful 3 × 8 sessions, move to Step 3.",
  },
  {
    id: 3,
    short: "Less help",
    label: "Step 3 · Reduce assistance",
    title: "Lightly assisted neutral-grip pull-up",
    prescription: "3 × 5–8 · reduce assistance by the smallest available step",
    sets: 3,
    measurement: "assisted_reps",
    target: "Rebuild from 3 × 5 toward 3 × 8 each time assistance is reduced.",
    next: "Move on after 2 successful 3 × 8 sessions at the lowest machine assistance or thinnest stable band.",
  },
  {
    id: 4,
    short: "Singles",
    label: "Step 4 · Clean singles",
    title: "Unassisted pull-up singles",
    prescription: "5 × 1 · rest 2–3 min · no grinding or kipping",
    sets: 5,
    measurement: "reps",
    target: "Complete five clean singles, each starting from control.",
    next: "After 2 successful sessions, move to Step 5.",
  },
  {
    id: 5,
    short: "Doubles",
    label: "Step 5 · Repeatable doubles",
    title: "Unassisted pull-up",
    prescription: "4 × 2 · keep at least 1 rep in reserve",
    sets: 4,
    measurement: "reps",
    target: "Complete all four doubles with the same range and tempo.",
    next: "After 2 successful sessions, move to Step 6.",
  },
  {
    id: 6,
    short: "5 reps",
    label: "Step 6 · Build to five",
    title: "Unassisted pull-up",
    prescription: "3 sets · aim for 3–5 clean reps · stop with at least 1 rep in reserve",
    sets: 3,
    measurement: "reps",
    target: "Build the first set to five continuous, clean repetitions.",
    next: "Five clean reps completes the 0 → 5 roadmap. Stay here and add total reps gradually.",
  },
];

export const RESPONSE_SCALE = [
  {
    value: 0,
    face: "😄",
    label: "Comfortable",
    description: "No meaningful pain; at your normal baseline or better.",
  },
  {
    value: 1,
    face: "🙂",
    label: "Mild",
    description: "Noticeable but stable; movement and technique stayed normal.",
  },
  {
    value: 2,
    face: "😐",
    label: "Adjust",
    description: "Clearly rising or more noticeable; reduce load, range, or volume next time.",
  },
  {
    value: 3,
    face: "🙁",
    label: "Stop",
    description: "Sharp, limiting, or changed your movement; stop the provoking exercise.",
  },
  {
    value: 4,
    face: "😧",
    label: "Red flag",
    description: "Swelling, locking, giving way, night pain, or persistent worsening—seek assessment.",
  },
];

const guidance = (setup, action, watch, option = "") => ({ setup, action, watch, option });

export const EXERCISE_GUIDANCE = {
  "squat-jump": guidance(
    "Stand about hip-width apart with a stable foot tripod.",
    "Dip only slightly, jump vertically, and land softly in the same stance. Reset before every rep.",
    "Keep the landing quiet and knees tracking over the feet. Stop if knee symptoms rise.",
  ),
  "box-squat": guidance(
    "Set the box at a depth you can control. Brace, keep the whole foot planted, and sit back toward it.",
    "Touch down under control without relaxing, then drive the floor away to stand.",
    "Do not drop onto the box or let the knees collapse inward. Shorten the range if symptoms increase.",
  ),
  "bulgarian-split-squat": guidance(
    "Place the rear foot on a low bench and keep enough distance for the front heel to stay down.",
    "Lower mostly through the front leg, then push through the whole front foot to rise.",
    "Use support for balance. Keep the front knee tracking with the toes and use a comfortable depth.",
  ),
  "assisted-nordic": guidance(
    "Kneel on padding with the ankles firmly anchored; use a band or hands for assistance.",
    "Keep hips extended and lower the body as one line as slowly as possible, then assist the return.",
    "Start with a short range. Stop for hamstring cramping, sharp pain, or loss of hip position.",
    "No ankle anchor or band: use bridge hamstring walkouts for 2 × 6–10. If available, use slider or stability-ball leg curls for 2 × 8–12, or a seated/lying leg-curl machine for 2 × 8–12. Move slowly; these preserve knee-flexion hamstring work but are not identical to Nordic eccentric exposure.",
  ),
  "hip-abduction": guidance(
    "Set the machine or cable so the pelvis stays level and the working leg begins under control.",
    "Move the thigh outward without leaning, pause briefly, and return slowly.",
    "Use a range that comes from the hip rather than twisting the pelvis or turning the toes far outward.",
  ),
  "standing-calf-raise": guidance(
    "Stand tall with the ball of the foot secure and use light hand support.",
    "Rise onto the toes, pause at the top, then lower under control through a comfortable stretch.",
    "Keep the ankle tracking straight; do not bounce or roll onto the outer edge of the foot.",
  ),
  "seated-calf-raise": guidance(
    "Sit with knees bent about 90° and the balls of the feet secure on the platform.",
    "Lift the heels, pause, and lower slowly through a comfortable range.",
    "Avoid bouncing or letting the feet roll inward or outward.",
  ),
  "tibialis-raise": guidance(
    "Lean against a wall with heels on the floor and feet slightly forward.",
    "Lift the forefeet and toes toward the shins, pause, then lower slowly.",
    "Keep the heels planted and shorten the stance if the front of the shin cramps.",
  ),
  "copenhagen-plank": guidance(
    "Lie side-on with the top knee supported on a bench and the lower knee bent beneath you.",
    "Lift the hips into a straight shoulder-to-knee line and breathe normally.",
    "Stop if you feel groin pain rather than muscular effort. Use more bench support to make it easier.",
  ),
  "bicycle-hiit": guidance(
    "Adjust the saddle so the knee remains slightly bent at the bottom of the pedal stroke.",
    "Warm up fully, ride each hard minute at RPE 8–9, and make every recovery genuinely easy.",
    "Hard does not mean all-out. Keep cadence controlled and stop for chest pain, dizziness, or unusual breathlessness.",
  ),
  "half-kneeling-landmine-press": guidance(
    "Kneel with the leg opposite the pressing arm forward. Hold the bar end near the shoulder and brace gently.",
    "Press up and forward along the bar path while allowing the shoulder blade to rotate, then lower slowly.",
    "Do not lean back, shrug, or force a pinching range. Keep about two reps in reserve.",
  ),
  "neutral-db-bench": guidance(
    "Lie with feet planted and hold the dumbbells with palms facing each other.",
    "Lower with elbows roughly 30–45° from the torso, then press without bouncing.",
    "Stop the descent before shoulder discomfort and keep the shoulder blades comfortably supported.",
  ),
  "cable-lateral-raise": guidance(
    "Stand tall with the cable low and the arm slightly in front of the body.",
    "Lead with the elbow and raise only through a comfortable range, then lower for about two seconds.",
    "Use light weight; do not shrug, swing, or push through shoulder discomfort.",
  ),
  "rope-pressdown": guidance(
    "Stand tall with elbows close to the ribs and shoulders relaxed.",
    "Extend the elbows, separate the rope slightly at the bottom, and return without moving the upper arms.",
    "Avoid leaning your body onto the cable or letting the shoulders roll forward.",
  ),
  "cable-external-rotation": guidance(
    "Set a light cable at elbow height and keep the elbow gently against the side, bent 90°.",
    "Rotate the forearm outward while the upper arm stays still, then return slowly.",
    "Use a small, painless range. Do not twist the torso or chase heavier loads.",
  ),
  "easy-run": guidance(
    "Begin with 5–10 minutes very easy and use a relaxed, natural stride.",
    "Keep the effort conversational at RPE 2–4; walk breaks are allowed.",
    "Reduce duration or pace if knee symptoms rise during the run or are worse the following morning.",
  ),
  "pelvic-floor": guidance(
    "Breathe normally and imagine gently lifting around the urethra and anus without moving the pelvis.",
    "Use a submaximal contraction, then fully release for at least as long as each hold.",
    "Do not hold your breath, bear down, or keep the muscles clenched between reps.",
  ),
  "pull-up-progression": guidance(
    "Use a neutral grip, begin with controlled shoulder blades, and select the assistance shown in your current step.",
    "Pull the chest toward the handles without kicking, then lower to the step’s full controlled range.",
    "Stop before grinding or shoulder pain. Advance only after the performance checks shown below.",
  ),
  "chest-supported-row": guidance(
    "Set the bench so the chest stays supported and use a neutral grip.",
    "Pull the elbows back toward the hips, pause, and lower until the shoulder blades move naturally forward.",
    "Do not lift the chest off the pad, shrug, or jerk the weight.",
  ),
  "face-pull": guidance(
    "Set the rope around upper-chest to face height and step back into light tension.",
    "Pull toward the nose or forehead with elbows comfortably out, then return slowly.",
    "Keep the ribs down and shoulders away from the ears; use a painless path.",
  ),
  "hammer-curl": guidance(
    "Stand tall with palms facing each other and elbows near the ribs.",
    "Curl without moving the upper arms, then lower under control.",
    "Avoid swinging, leaning back, or letting the shoulders roll forward.",
  ),
  "kneeling-cable-crunch": guidance(
    "Kneel facing the cable with the rope beside the head and hips mostly still.",
    "Exhale and curl the ribs toward the pelvis, then return under control.",
    "Do not pull with the arms, sit the hips backward, or hold your breath.",
  ),
  "pallof-press": guidance(
    "Set a cable at chest height. Stand side-on, hold the handle at the sternum with both hands, and place the feet hip-width apart.",
    "Press the handle straight out until the arms are extended, hold for two seconds, then return under control.",
    "Keep the hips and shoulders square. Do not let the cable rotate the torso. Reduce the load if the ribs flare or you hold your breath.",
  ),
  "mobility-a-cat-cow": guidance(
    "Start on hands and knees with hands under shoulders and knees under hips.",
    "Move slowly between a comfortable rounded and gently extended spine for six controlled cycles.",
    "Spread the movement across the spine; do not force the neck or lower back into end range.",
  ),
  "mobility-a-frog": guidance(
    "On padding, place both knees comfortably wide with the lower legs supported and keep the spine neutral.",
    "Rock the hips backward and forward through a mild inner-thigh stretch for eight slow repetitions.",
    "Use a narrower knee position if needed; stop before groin, hip, or knee pain.",
  ),
  "mobility-a-lateral-lunge": guidance(
    "Half-kneel on padding, place the other foot out to the side, and keep that whole foot planted.",
    "Shift gently toward the planted foot for six controlled repetitions, keeping its knee aligned with the toes.",
    "Use a shallow range and support the hands on a bench if balance or the knee feels uncertain.",
  ),
  "mobility-a-bridge-march": guidance(
    "Lie on your back with knees bent, feet planted, and lift into a comfortable glute bridge.",
    "Keep the pelvis level while alternately lifting one foot only a few centimetres for six repetitions per side.",
    "This is a stability drill, not a stretch; lower the hips if the back arches or hamstrings cramp.",
  ),
  "mobility-a-seated-good-morning": guidance(
    "Sit near the front of a bench with feet comfortably wide, whole feet planted, and hands across the chest.",
    "Keep a long spine and hinge forward from the hips for eight slow, unloaded repetitions.",
    "Stop at a mild posterior-chain stretch; do not round forcefully, bounce, or add weight.",
  ),
  "zone-2-cycle": guidance(
    "Use a comfortable saddle height and begin with several easy minutes.",
    "Ride steadily at RPE 2–3, where full sentences remain easy.",
    "This is optional recovery volume; skip it when sleep, legs, running, or joints are not normal.",
  ),
  "kettlebell-swing": guidance(
    "Place the bell slightly ahead, hinge to grip it, and hike it back between the thighs.",
    "Snap the hips to float the bell, then let it return into the next hinge.",
    "It is a hip hinge, not a squat or arm raise. Stop if the back rounds or the bell pulls the shoulders.",
  ),
  "trap-bar-deadlift": guidance(
    "Stand centered in the bar, brace, and take the handles with the whole foot planted.",
    "Push the floor away and stand tall, then hinge and bend the knees to return the bar under control.",
    "Keep the load close and spine steady; do not jerk from the floor or lean back at lockout.",
  ),
  "barbell-hip-thrust": guidance(
    "Place the upper back on a bench, pad the bar, and set feet so the shins are near vertical at the top.",
    "Drive through the whole foot, finish by squeezing the glutes, and lower under control.",
    "Do not overarch the lower back or throw the head backward.",
  ),
  "controlled-step-down": guidance(
    "Stand on a low step with the working foot fully supported and use a rail if needed.",
    "Lower the free heel toward the floor for about three seconds, lightly touch, then rise.",
    "Keep the pelvis level and knee tracking over the foot. Reduce step height if symptoms increase.",
  ),
  "run-2": guidance(
    "Complete the prescribed easy warm-up before any faster work.",
    "Follow the current block’s effort and recovery exactly; keep fast reps controlled rather than maximal.",
    "End the quality portion if form deteriorates or knee symptoms rise, and monitor the following morning.",
  ),
  "neutral-incline-db-press": guidance(
    "Use a low incline, plant the feet, and hold the dumbbells with palms facing each other.",
    "Lower with elbows in a comfortable 30–45° path, then press smoothly.",
    "Use the lowest comfortable incline and stop the descent before pinching or clicking becomes uncomfortable.",
  ),
  "cable-chest-fly": guidance(
    "Set two cable handles around mid-chest height, use a split stance, and begin with the elbows softly bent and the hands only slightly behind the torso.",
    "Bring the upper arms inward in a wide hugging arc, pause when the hands meet, then return slowly through a comfortable chest stretch.",
    "Keep the shoulders down and ribs stacked. Do not chase a deep stretch, let the elbows drift far behind the body, or continue through front-of-shoulder discomfort.",
    "Use a neutral-grip machine chest press for 2 × 10–15 if the fly path is not completely comfortable.",
  ),
  "one-arm-landmine-press": guidance(
    "Stand in a split stance with the bar near the working shoulder and ribs stacked over the pelvis.",
    "Press up and forward while allowing the shoulder blade to move, then lower slowly.",
    "Do not twist, lean back, shrug, or force an uncomfortable endpoint.",
  ),
  "cable-scaption": guidance(
    "This is simply a one-arm cable scaption raise: set a cable pulley at its lowest position with a very light load. Stand sideways with the working arm farther from the machine and hold the handle with a slight elbow bend.",
    "Set the arm 20–30° forward of directly sideways—like a wide V when viewed from above—with the thumb up or slightly forward. Raise slowly to the highest completely comfortable point (shoulder height is a ceiling, not a requirement), then lower for about two seconds. This trains the side deltoid to help build shoulder width.",
    "First reduce the load or range and stop before discomfort. If the shoulder still feels uncomfortable, do not force the exercise.",
    "Use a supported machine lateral raise for 2–3 × 12–20 in a comfortable path. If that also feels uncomfortable, omit Friday’s raise and keep the landmine presses.",
  ),
  "cross-body-triceps": guidance(
    "Set the cable above shoulder height and hold it with the opposite hand across the body.",
    "Keep the upper arm quiet while straightening the elbow down and across, then return slowly.",
    "Use a shoulder position that feels natural; do not pull the shoulder forward.",
  ),
  "reverse-crunch": guidance(
    "Lie on your back with hips and knees bent and arms supported beside you.",
    "Exhale, gently roll the pelvis toward the ribs, and lift the tailbone slightly before lowering slowly.",
    "Do not swing the legs, throw the hips overhead, or hold your breath.",
  ),
  "suitcase-carry": guidance(
    "Hold one kettlebell or dumbbell at the side. Stand tall with the shoulders level and the free arm relaxed.",
    "Walk with short, controlled steps for the set distance, then switch sides.",
    "Do not lean away from the weight or let the hip drop. Stop the set if grip fails before the trunk does, and note it in the log.",
  ),
  "mobility-b-chest": guidance(
    "Place the forearm on a doorway with the elbow below shoulder height.",
    "Step or turn away gently until the chest feels a mild stretch.",
    "Do not force the shoulder forward or continue if the front of the shoulder pinches.",
  ),
  "mobility-b-shoulder": guidance(
    "Bring one arm across the chest and support it above the elbow with the other arm.",
    "Draw it gently closer while keeping the shoulder down and relaxed.",
    "The stretch should be behind the shoulder, not a pinch at the front or top.",
  ),
  "mobility-b-adductor": guidance(
    "This is not the adductor machine. Put both hands on a bench, keep one knee under the hip, and extend the other leg to the side with its foot flat.",
    "Keep the spine neutral and slowly send the hips backward until the inner thigh feels a gentle stretch.",
    "Use the bench for support and stop before groin, hip, or knee pain.",
  ),
  "long-run": guidance(
    "Start 5–10 minutes very easily and choose a flat, familiar route when possible.",
    "Stay conversational and use planned or unplanned walk breaks to keep the effort easy.",
    "Repeat rather than advance the progression if joint symptoms or usual energy are not back to baseline the next morning.",
  ),
  "easy-swim": guidance(
    "Begin with relaxed technique lengths and choose strokes that feel comfortable at the shoulder.",
    "Keep the effort at RPE 2–3 with generous rest as needed.",
    "Avoid paddles, hard butterfly, or fatigued overhead work; stop any stroke that provokes shoulder discomfort.",
  ),
  "one-arm-cable-row": guidance(
    "Stand or sit square to the cable with the arm reaching forward under control.",
    "Pull the elbow toward the hip without rotating the torso, then return slowly.",
    "Keep the shoulder away from the ear and use a comfortable reach.",
  ),
  "db-pullover": guidance(
    "Lie supported on a bench, hold one light dumbbell over the chest, and keep a small elbow bend.",
    "Lower only until the shoulders remain comfortable, then bring the weight back over the chest.",
    "Keep the ribs down and do not chase a deep overhead stretch or painful clicking.",
  ),
  "cable-curl": guidance(
    "Stand tall with elbows near the ribs and wrists neutral.",
    "Curl without moving the upper arms, then lower slowly.",
    "Avoid swinging, leaning back, or allowing the shoulders to roll forward.",
  ),
};

export const EXERCISE_ALTERNATIVES = {
  "assisted-nordic": [
    {
      id: "seated-or-lying-leg-curl",
      name: "Seated or lying leg curl",
      prescription: "2 × 8–12 · slow, controlled lowering",
      sets: 2,
      measurement: "weight_reps",
    },
    {
      id: "slider-or-ball-leg-curl",
      name: "Slider or stability-ball leg curl",
      prescription: "2 × 8–12 · keep hips lifted",
      sets: 2,
      measurement: "reps",
    },
    {
      id: "bridge-hamstring-walkout",
      name: "Bridge hamstring walkout",
      prescription: "2 × 6–10 · controlled steps out and back",
      sets: 2,
      measurement: "reps",
    },
  ],
};

export function normalizeResponseRating(value, scaleVersion = 1) {
  if (value === "" || value === null || value === undefined) return "";
  const rating = Number(value);
  if (!Number.isFinite(rating)) return "";
  if (Number(scaleVersion) >= 2) return Math.max(0, Math.min(4, Math.round(rating)));
  if (rating <= 0) return 0;
  if (rating <= 3) return 1;
  if (rating <= 5) return 2;
  if (rating <= 7) return 3;
  return 4;
}

export function longRunTargetDistance(target) {
  const match = String(target || "").match(/\d+(?:\.\d+)?/);
  return match ? Number(match[0]) : 0;
}

export function evaluateLongRunProgress(log, target, exerciseId = "long-run") {
  const exercise = log?.exercises?.[exerciseId];
  const sets = Array.isArray(exercise?.sets) ? exercise.sets : [];
  const entered = sets.filter((set) => Number(set?.distance) > 0);
  if (!entered.length) {
    return {
      status: "not-started",
      label: "Not logged yet",
      reason: "Complete this stage’s long run before advancing.",
      distance: 0,
      rpe: null,
    };
  }

  const bestSet = entered.reduce((best, set) => (Number(set.distance) > Number(best.distance) ? set : best));
  const distance = Number(bestSet.distance);
  const targetDistance = longRunTargetDistance(target);
  const rpe = bestSet.rpe === "" || bestSet.rpe === undefined ? null : Number(bestSet.rpe);
  if (!bestSet.completed) {
    return {
      status: "pending",
      label: "Run entered",
      reason: "Mark the long-run set complete to finish this attempt.",
      distance,
      rpe,
    };
  }
  if (targetDistance && distance + 0.05 < targetDistance) {
    return {
      status: "repeat",
      label: "Repeat recommended",
      reason: `Logged ${distance} km; this stage targets ${target}.`,
      distance,
      rpe,
    };
  }
  if (!Number.isFinite(rpe)) {
    return {
      status: "pending",
      label: "RPE needed",
      reason: "Add the run’s RPE before deciding whether to advance.",
      distance,
      rpe: null,
    };
  }
  if (rpe > 4) {
    return {
      status: "repeat",
      label: "Repeat recommended",
      reason: `The run was RPE ${rpe}; repeat until the prescribed distance feels easy and conversational.`,
      distance,
      rpe,
    };
  }

  const nextMorning = normalizeResponseRating(log?.response?.painNext, log?.response?.scaleVersion);
  if (nextMorning === "") {
    return {
      status: "pending",
      label: "Morning check pending",
      reason: "Reopen this workout the following morning and record your response.",
      distance,
      rpe,
    };
  }
  if (Number(nextMorning) > 1) {
    return {
      status: "repeat",
      label: "Repeat recommended",
      reason: "The following-morning response was above Mild; repeat, reduce, or step back.",
      distance,
      rpe,
    };
  }
  return {
    status: "ready",
    label: "Ready to advance",
    reason: "Target completed at easy effort with a stable following-morning response.",
    distance,
    rpe,
  };
}

export function countQualifiedLongRuns(workoutLogs, targetDistance = 10, exerciseId = "long-run") {
  return Object.values(workoutLogs || {}).filter(
    (log) => evaluateLongRunProgress(log, `${targetDistance} km`, exerciseId).status === "ready",
  ).length;
}

const lift = (id, name, prescription, sets, rest = 90, measurement = "weight_reps", options = {}) => ({
  id,
  name,
  prescription,
  sets,
  rest,
  measurement,
  category: "Strength",
  ...options,
});

const activity = (id, name, prescription, measurement = "duration", options = {}) => ({
  id,
  name,
  prescription,
  sets: 1,
  rest: 0,
  measurement,
  category: "Cardio",
  ...options,
});

export const WEEK_PLAN = {
  monday: {
    label: "Monday",
    short: "MON",
    focus: "Legs A + bicycle HIIT",
    kicker: "Strength · power · intervals",
    estimate: "70–90 min + later HIIT",
    tone: "lime",
    sequenceNote: "Keep the bicycle HIIT at least 6 hours after lifting.",
    warmup: [
      "Easy bicycle · 3–5 min at RPE 2–3",
      "Ankle rocks · 8/side",
      "Bodyweight hip hinge · 8",
      "Lunge twist · 1 × 4/side · step forward, use a shallow comfortable lunge, rotate the upper torso toward the lead leg, then return",
      "Bodyweight box squat · 8",
      "Low step-down · 5/side",
      "Glute bridge with breathing · 2 × 8",
      "Squat-jump practice · 2 reps at 50–60%, then 2 at 70–80%",
      "Box-squat ramp · light × 8, 50% × 5, 70% × 3, optional 80–85% × 1",
    ],
    exercises: [
      lift("squat-jump", "Squat jump", "2 × 3 · add only after 2 symptom-stable weeks", 2, 90, "reps"),
      lift("box-squat", "Box squat", "3 × 5–8", 3, 150),
      lift("bulgarian-split-squat", "Bulgarian split squat", "2 × 8–10 / leg", 2, 120),
      lift("assisted-nordic", "Assisted Nordic hamstring", "1–2 × 3–5", 2, 120, "reps"),
      lift("hip-abduction", "Machine or cable hip abduction", "2 × 12–20", 2, 75),
      lift("standing-calf-raise", "Standing calf raise", "2 × 8–15", 2, 75),
      lift("tibialis-raise", "Tibialis raise", "2 × 12–20", 2, 60),
      lift("copenhagen-plank", "Short-lever Copenhagen plank", "2 × 15–25 sec / side", 2, 60, "duration"),
      activity(
        "bicycle-hiit",
        "Bicycle HIIT",
        "10-min warm-up; 6 × 1 min at RPE 8–9 with 2 min easy; 8–10-min cooldown",
        "duration",
        { section: "Later session" },
      ),
    ],
  },
  tuesday: {
    label: "Tuesday",
    short: "TUE",
    focus: "Push A + easy run",
    kicker: "Upper strength · aerobic base",
    estimate: "85–105 min total",
    tone: "blue",
    sequenceNote: "Keep the run conversational. Separate it from lifting when practical.",
    warmup: [
      "Easy bicycle or elliptical · 3 min",
      "Serratus wall slide · 1 × 8",
      "Very light cable external rotation · 1 × 10/side",
      "Slow arm circles · 5 each direction",
      "Landmine ramp · light × 8/side, 50% × 5/side, 70% × 3/side",
      "Dumbbell press · 1 lighter set × 5",
    ],
    exercises: [
      lift(
        "half-kneeling-landmine-press",
        "Half-kneeling 1-arm landmine press",
        "3 × 6–8 / side · keep 2 RIR · use a comfortable path",
        3,
        120,
      ),
      lift("neutral-db-bench", "Neutral-grip dumbbell bench press", "3 × 6–10", 3, 150),
      lift("cable-chest-fly", "Cable chest fly", "2 × 10–15 · comfortable shoulder range", 2, 90),
      lift("cable-lateral-raise", "Cable lateral raise", "3 × 12–20 · stop before shrugging", 3, 75),
      lift("rope-pressdown", "Rope triceps press-down", "2 × 10–15", 2, 75),
      lift("cable-external-rotation", "Cable external rotation", "2 × 12–20", 2, 60),
      lift("kneeling-cable-crunch", "Kneeling cable crunch", "3 × 8–15 · controlled spinal flexion", 3, 90),
      activity("easy-run", "Easy run", "Block 1: 30 min, RPE 2–4 · Block 2: 30–40 min + 4 × 20-sec strides", "distance_time"),
      activity("pelvic-floor", "Pelvic-floor routine", "5 breaths; 8 × 5-sec holds with full relaxation; 8 quick contractions", "duration", {
        category: "Recovery",
      }),
    ],
  },
  wednesday: {
    label: "Wednesday",
    short: "WED",
    focus: "Pull A + Mobility A",
    kicker: "Pull-up skill · recovery",
    estimate: "60–80 min",
    tone: "orange",
    sequenceNote: "Optional cycling stays off by default until the sleep and following-morning recovery gate is met. Complete Mobility A last and keep it easy—not a second leg workout.",
    warmup: [
      "Easy bicycle · 3 min",
      "Serratus wall slide · 1 × 8",
      "Very light cable external rotation · 1 × 10/side",
      "Foot-assisted scapular pull-up · 1 × 5",
      "Highly assisted neutral-grip pull-up · 1 × 5",
      "Moderately assisted pull-up · 1 × 2–3",
    ],
    exercises: [
      lift(
        "pull-up-progression",
        "Pull-up progression",
        "Choose your current performance step below",
        3,
        150,
        "assisted_reps",
        { progression: "pullup" },
      ),
      lift("chest-supported-row", "Chest-supported neutral-grip row", "3 × 6–10", 3, 120),
      lift("face-pull", "Face pull", "3 × 12–20 · controlled rear-delt focus", 3, 75),
      lift("hammer-curl", "Neutral-grip hammer curl", "2 × 8–15", 2, 75),
      lift(
        "pallof-press",
        "Pallof press",
        "2 × 8–10 / side · 2-sec hold at full extension",
        2,
        60,
      ),
      activity("zone-2-cycle", "Optional Zone 2 cycling", "25–40 min at RPE 2–3 · only after the optional-session recovery gate is met", "duration", {
        optional: true,
      }),
      lift("mobility-a-cat-cow", "Mobility A · Cat–cow", "1 round · 6 slow cycles", 1, 0, "completion", {
        category: "Mobility",
      }),
      lift("mobility-a-frog", "Mobility A · Dynamic frog rock-back", "1 round · 8 slow reps", 1, 0, "completion", {
        category: "Mobility",
      }),
      lift("mobility-a-lateral-lunge", "Mobility A · Half-kneeling lateral lunge", "1 round · 6 controlled reps / side", 1, 0, "completion", {
        category: "Mobility",
      }),
      lift("mobility-a-bridge-march", "Mobility A · Bridge leg lift", "1 round · 6 alternating reps / side", 1, 0, "completion", {
        category: "Mobility",
      }),
      lift("mobility-a-seated-good-morning", "Mobility A · Seated good morning", "1 round · 8 slow unloaded reps", 1, 0, "completion", {
        category: "Mobility",
      }),
    ],
  },
  thursday: {
    label: "Thursday",
    short: "THU",
    focus: "Legs B + Run 2",
    kicker: "Posterior chain · run quality",
    estimate: "75–100 min total",
    tone: "pink",
    sequenceNote: "Block 1: lift first. Block 2: quality run first. Separate sessions by about 6 hours.",
    warmup: [
      "Easy bicycle · 3–5 min",
      "Ankle rocks · 8/side",
      "Bodyweight hip hinge · 8",
      "Bodyweight box squat · 8",
      "Low step-down · 5/side",
      "Light kettlebell deadlift · 5",
      "Light kettlebell swing · 2 × 5",
      "Trap-bar ramp · 40% × 6, 60% × 4, 75% × 2, optional 85% × 1",
    ],
    exercises: [
      lift("kettlebell-swing", "Kettlebell swing", "2–3 × 8–12", 3, 90),
      lift("trap-bar-deadlift", "Trap-bar deadlift", "3 × 4–6", 3, 180),
      lift("barbell-hip-thrust", "Barbell hip thrust", "3 × 8–12", 3, 150),
      lift("controlled-step-down", "Controlled step-down", "2 × 6–10 / leg · 3-sec lowering", 2, 90),
      lift("hip-abduction", "Machine or cable hip abduction", "2 × 12–20", 2, 75),
      lift("seated-calf-raise", "Seated calf raise", "2 × 10–15", 2, 75),
      lift("tibialis-raise", "Tibialis raise", "2 × 12–20", 2, 60),
      activity(
        "run-2",
        "Run 2",
        `Block 1: 25–35 min easy at RPE 2–4 · Block 2 alternates completed quality sessions: ${RUN_QUALITY_PROGRESSION.base}`,
        "distance_time",
      ),
      activity("pelvic-floor", "Pelvic-floor routine", "5 breaths; 8 × 5-sec holds; 8 quick contractions", "duration", {
        category: "Recovery",
      }),
    ],
  },
  friday: {
    label: "Friday",
    short: "FRI",
    focus: "Push B + Mobility B",
    kicker: "Upper hypertrophy · mobility",
    estimate: "75–95 min",
    tone: "purple",
    sequenceNote: "Use comfortable shoulder paths; do not force clicking or pinching.",
    warmup: [
      "Easy bicycle or elliptical · 3 min",
      "Serratus wall slide · 1 × 8",
      "Very light cable external rotation · 1 × 10/side",
      "Slow arm circles · 5 each direction",
      "Landmine ramp · light × 8/side, 50% × 5/side, 70% × 3/side",
      "Incline dumbbell press · 1 lighter set × 5",
    ],
    exercises: [
      lift("neutral-incline-db-press", "Neutral-grip incline dumbbell press", "3 × 8–12", 3, 150),
      lift("one-arm-landmine-press", "One-arm landmine press", "2 × 10–12 / side", 2, 120),
      lift("cable-chest-fly", "Cable chest fly", "2 × 10–15 · comfortable shoulder range", 2, 90),
      lift(
        "cable-scaption",
        "One-arm cable scaption raise (side delt)",
        "3 × 12–20 · raise only through a fully comfortable range; otherwise use the guide’s substitute",
        3,
        75,
      ),
      lift("cross-body-triceps", "Cross-body cable triceps extension", "2 × 10–15", 2, 75),
      lift("cable-external-rotation", "Cable external rotation", "2 × 12–20", 2, 60),
      lift(
        "suitcase-carry",
        "Suitcase carry",
        "2 × 20–30 m / side",
        2,
        60,
        "weight_distance",
      ),
      lift("reverse-crunch", "Reverse crunch", "3 × 10–20 · curl the pelvis; do not swing", 3, 75, "reps"),
      lift("mobility-b-chest", "Mobility B · Doorway chest stretch", "2 rounds · 45 sec / side", 2, 0, "completion", {
        category: "Mobility",
      }),
      lift("mobility-b-shoulder", "Mobility B · Cross-body shoulder stretch", "2 rounds · 45 sec / side", 2, 0, "completion", {
        category: "Mobility",
      }),
      lift("mobility-b-adductor", "Mobility B · Adductor Rock Back", "2 rounds · 45 sec / side", 2, 0, "completion", {
        category: "Mobility",
      }),
    ],
  },
  saturday: {
    label: "Saturday",
    short: "SAT",
    focus: "Long run + swim + Pull B",
    kicker: "Endurance · technique",
    estimate: "105–155 min total",
    tone: "teal",
    sequenceNote: "Long run and the three-exercise Pull B base are planned. Separate them by at least 4 hours when practical. Keep swimming easy; optional face pulls and curls are the first strength work to skip when recovery is limited.",
    warmup: [
      "Long run · start with 5–10 min very easy",
      "Swim · begin with relaxed technique lengths",
      "Pull B · 2–3 min easy movement",
      "Pull B · wall slide 1 × 6",
      "Pull B · highly assisted pull-up 1 × 5",
      "Pull B · light cable row 1 × 8",
    ],
    exercises: [
      activity("long-run", "Long run", "Block 1: use the 18-stage progression · Block 2: 8–10 km easy", "distance_time"),
      activity("easy-swim", "Technique-focused swim", "25–40 min at RPE 2–3 · no paddles, hard butterfly, or fatigued overhead work", "duration"),
      lift(
        "pull-up-progression",
        "Pull-up progression",
        "Repeat your current performance step · stop with the prescribed RIR",
        2,
        150,
        "assisted_reps",
        { progression: "pullup" },
      ),
      lift("one-arm-cable-row", "One-arm cable row", "2 × 10–15 / side", 2, 90),
      lift("db-pullover", "Light dumbbell pullover", "2 × 10–15", 2, 90),
      lift("face-pull", "Optional face pull", "2 × 12–20", 2, 75, "weight_reps", { optional: true }),
      lift("cable-curl", "Optional cable curl", "1–2 × 10–15", 2, 75, "weight_reps", { optional: true }),
      activity("pelvic-floor", "Pelvic-floor routine", "5 breaths; 8 × 5-sec holds; 8 quick contractions", "duration", {
        category: "Recovery",
      }),
    ],
  },
  sunday: {
    label: "Sunday",
    short: "SUN",
    focus: "Complete rest",
    kicker: "Recover · review · reset",
    estimate: "No training",
    tone: "rest",
    sequenceNote: "Ordinary relaxed movement is fine. Review sleep, load, pain, and next-morning responses.",
    warmup: [],
    exercises: [],
  },
};

export const LONG_RUNS = [
  "4.5 km",
  "4.8 km",
  "5.2 km",
  "4.5 km cutback",
  "5.6 km",
  "6.0 km",
  "6.5 km",
  "5.2 km cutback",
  "7.0 km",
  "7.6 km",
  "8.2 km",
  "6.5 km cutback",
  "8.8 km",
  "9.4 km",
  "10.0 km",
  "8.0 km cutback",
  "10.0 km repeat",
  "6–7 km recovery",
];

export const LONG_RUN_PHASES = [
  { id: 1, name: "Foundation", start: 1, end: 4 },
  { id: 2, name: "Build", start: 5, end: 8 },
  { id: 3, name: "Extend", start: 9, end: 12 },
  { id: 4, name: "10 km", start: 13, end: 18 },
];

export function createDefaultState() {
  return {
    version: APP_VERSION,
    settings: {
      block: 1,
      longRunWeek: 1,
      pullupStep: 1,
      weekOffset: 0,
      activePlanId: "form-flow",
      builtInPlanRevision: 2,
    },
    exerciseConfigs: {},
    workoutLogs: {},
    workoutDrafts: {},
    savedActivities: [],
    bodyLogs: [],
    sleepLogs: [],
    dailySleepLogs: [],
    dailyCheckIns: {},
  };
}

function isValidExtraActivity(activity, requireSets = false) {
  if (!activity || typeof activity !== "object" || Array.isArray(activity)) return false;
  if (
    typeof activity.id !== "string" ||
    !/^[a-z0-9][a-z0-9-]{0,95}$/.test(activity.id) ||
    typeof activity.name !== "string" ||
    !activity.name.trim() ||
    activity.name.length > 80 ||
    !EXTRA_ACTIVITY_TYPES.includes(activity.type) ||
    !EXTRA_ACTIVITY_MEASUREMENTS.includes(activity.measurement)
  ) {
    return false;
  }
  if (
    activity.reusableId !== undefined &&
    activity.reusableId !== "" &&
    (typeof activity.reusableId !== "string" || !/^[a-z0-9][a-z0-9-]{0,95}$/.test(activity.reusableId))
  ) {
    return false;
  }
  if (!requireSets) return activity.sets === undefined;
  return (
    Array.isArray(activity.sets) &&
    activity.sets.every((set) => set && typeof set === "object" && !Array.isArray(set))
  );
}

function migrateSuitcaseCarryLogs(records) {
  return Object.fromEntries(
    Object.entries(records || {}).map(([key, log]) => {
      const carry = log?.exercises?.["suitcase-carry"];
      if (carry?.measurement !== "weight_reps" || !Array.isArray(carry.sets)) return [key, log];
      return [
        key,
        {
          ...log,
          exercises: {
            ...log.exercises,
            "suitcase-carry": {
              ...carry,
              measurement: "weight_distance",
              sets: carry.sets.map(({ reps, ...set }) => ({
                ...set,
                ...(reps !== undefined && reps !== "" ? { distance: reps } : {}),
              })),
            },
          },
        },
      ];
    }),
  );
}

export function normalizeState(value) {
  const fallback = createDefaultState();
  if (!value || typeof value !== "object") return fallback;
  const previousBuiltInPlanRevision = Number(value.settings?.builtInPlanRevision) || 1;
  const settings = { ...fallback.settings, ...(value.settings || {}) };
  settings.block = Number(settings.block) === 2 ? 2 : 1;
  settings.longRunWeek = Math.max(1, Math.min(52, Number(settings.longRunWeek) || 1));
  settings.pullupStep = Math.max(1, Math.min(PULL_UP_STEPS.length, Number(settings.pullupStep) || 1));
  settings.builtInPlanRevision = 2;
  const exerciseConfigs =
    value.exerciseConfigs && typeof value.exerciseConfigs === "object" ? { ...value.exerciseConfigs } : {};
  if (previousBuiltInPlanRevision < 2 && exerciseConfigs["suitcase-carry"] === "weight_reps") {
    delete exerciseConfigs["suitcase-carry"];
  }
  const sourceWorkoutLogs = value.workoutLogs && typeof value.workoutLogs === "object" ? value.workoutLogs : {};
  const sourceWorkoutDrafts =
    value.workoutDrafts && typeof value.workoutDrafts === "object" && !Array.isArray(value.workoutDrafts)
      ? value.workoutDrafts
      : {};
  const workoutLogs = previousBuiltInPlanRevision < 2 ? migrateSuitcaseCarryLogs(sourceWorkoutLogs) : sourceWorkoutLogs;
  const workoutDrafts =
    previousBuiltInPlanRevision < 2 ? migrateSuitcaseCarryLogs(sourceWorkoutDrafts) : sourceWorkoutDrafts;
  return {
    version: APP_VERSION,
    settings,
    exerciseConfigs,
    workoutLogs,
    workoutDrafts,
    savedActivities: Array.isArray(value.savedActivities)
      ? value.savedActivities.filter((activity) => isValidExtraActivity(activity))
      : [],
    bodyLogs: Array.isArray(value.bodyLogs) ? value.bodyLogs : [],
    sleepLogs: Array.isArray(value.sleepLogs) ? value.sleepLogs : [],
    dailySleepLogs: Array.isArray(value.dailySleepLogs) ? value.dailySleepLogs : [],
    dailyCheckIns:
      value.dailyCheckIns && typeof value.dailyCheckIns === "object" && !Array.isArray(value.dailyCheckIns)
        ? value.dailyCheckIns
        : {},
  };
}

export function validateBackup(value) {
  if (!value || typeof value !== "object") return { valid: false, reason: "The file does not contain a JSON object." };
  if (Number(value.version) !== APP_VERSION) {
    return { valid: false, reason: `Unsupported backup version. Expected version ${APP_VERSION}.` };
  }
  if (!value.workoutLogs || typeof value.workoutLogs !== "object" || Array.isArray(value.workoutLogs)) {
    return { valid: false, reason: "Workout logs are missing or malformed." };
  }
  if (
    value.workoutDrafts !== undefined &&
    (!value.workoutDrafts || typeof value.workoutDrafts !== "object" || Array.isArray(value.workoutDrafts))
  ) {
    return { valid: false, reason: "Workout drafts are malformed." };
  }
  if (!Array.isArray(value.bodyLogs) || !Array.isArray(value.sleepLogs)) {
    return { valid: false, reason: "Body or sleep logs are malformed." };
  }
  if (value.dailySleepLogs !== undefined && !Array.isArray(value.dailySleepLogs)) {
    return { valid: false, reason: "Daily sleep logs are malformed." };
  }
  if (
    value.dailyCheckIns !== undefined &&
    (!value.dailyCheckIns || typeof value.dailyCheckIns !== "object" || Array.isArray(value.dailyCheckIns))
  ) {
    return { valid: false, reason: "Daily check-in records are malformed." };
  }
  if (value.savedActivities !== undefined) {
    if (
      !Array.isArray(value.savedActivities) ||
      !value.savedActivities.every((activity) => isValidExtraActivity(activity))
    ) {
      return { valid: false, reason: "Saved extra activities are malformed." };
    }
  }
  const validDate = (date) => typeof date === "string" && /^\d{4}-\d{2}-\d{2}$/.test(date) && !Number.isNaN(Date.parse(`${date}T12:00:00`));
  const validNumber = (number) => Number.isFinite(Number(number)) && Number(number) >= 0;
  const bodyValid = value.bodyLogs.every(
    (entry) => entry && validDate(entry.date) && validNumber(entry.weight) && validNumber(entry.waist),
  );
  const sleepValid = value.sleepLogs.every(
    (entry) => entry && validDate(entry.week) && validNumber(entry.hours) && Number(entry.hours) <= 24,
  );
  const dailySleepValid = (value.dailySleepLogs || []).every(
    (entry) => entry && validDate(entry.date) && validNumber(entry.hours) && Number(entry.hours) <= 24,
  );
  const checkInsValid = Object.entries(value.dailyCheckIns || {}).every(
    ([date, entry]) =>
      validDate(date) &&
      entry &&
      typeof entry === "object" &&
      ["open", "deferred", "skipped", "completed"].includes(entry.status || "open") &&
      (entry.sleepUnknown === undefined || typeof entry.sleepUnknown === "boolean") &&
      (entry.recoveryUnknown === undefined || Array.isArray(entry.recoveryUnknown)),
  );
  if (!bodyValid || !sleepValid || !dailySleepValid || !checkInsValid) {
    return { valid: false, reason: "A body or sleep record contains an invalid date or value." };
  }
  const validWorkoutRecord = (log) => {
    if (!log || typeof log !== "object" || !validDate(log.date)) return false;
    if (log.planId !== undefined && (typeof log.planId !== "string" || !/^[a-z0-9][a-z0-9-]{0,63}$/.test(log.planId))) {
      return false;
    }
    if (!log.exercises || typeof log.exercises !== "object" || Array.isArray(log.exercises)) return false;
    const exercisesValid = Object.values(log.exercises).every(
      (exercise) =>
        exercise &&
        Object.hasOwn(MEASUREMENT_TYPES, exercise.measurement) &&
        Array.isArray(exercise.sets) &&
        exercise.sets.every((set) => set && typeof set === "object" && !Array.isArray(set)),
    );
    const extraActivitiesValid =
      log.extraActivities === undefined ||
      (Array.isArray(log.extraActivities) &&
        log.extraActivities.every((activity) => isValidExtraActivity(activity, true)));
    return exercisesValid && extraActivitiesValid;
  };
  const workoutsValid =
    Object.values(value.workoutLogs).every(validWorkoutRecord) &&
    Object.values(value.workoutDrafts || {}).every(validWorkoutRecord);
  if (!workoutsValid) {
    return { valid: false, reason: "A workout record contains an invalid date, measurement type, or set list." };
  }
  return { valid: true, state: normalizeState(value) };
}

export function dateToDayKey(dateString) {
  const date = new Date(`${dateString}T12:00:00`);
  return ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"][date.getDay()];
}

export function toIsoDate(date = new Date()) {
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 10);
}

export function startOfWeek(date = new Date()) {
  const result = new Date(date);
  result.setHours(12, 0, 0, 0);
  const day = result.getDay() || 7;
  result.setDate(result.getDate() - day + 1);
  return result;
}

export function addDays(date, amount) {
  const result = new Date(date);
  result.setDate(result.getDate() + amount);
  return result;
}

export function findOutstandingRecoveryLogs(workoutLogs, today = toIsoDate(), lookbackDays = 2) {
  const earliest = toIsoDate(addDays(new Date(`${today}T12:00:00`), -Math.max(1, Number(lookbackDays) || 2)));
  return Object.entries(workoutLogs || {})
    .filter(([, log]) => {
      if (!log?.date || log.date >= today || log.date < earliest) return false;
      const response = log.response || {};
      const hasFollowingMorning =
        response.painNext !== undefined && response.painNext !== null && response.painNext !== "";
      return !hasFollowingMorning && Object.keys(log.exercises || {}).length > 0;
    })
    .sort(([, a], [, b]) => b.date.localeCompare(a.date))
    .map(([key, log]) => ({ key, date: log.date, dayKey: log.dayKey || dateToDayKey(log.date) }));
}

export function summarizeWeeklySleep(weeklySleepLogs = [], dailySleepLogs = []) {
  const summaries = new Map(
    weeklySleepLogs.map((entry) => [entry.week, { ...entry, nights: 7, source: "weekly" }]),
  );
  const dailyByWeek = new Map();
  dailySleepLogs.forEach((entry) => {
    if (!entry?.date || !Number.isFinite(Number(entry.hours))) return;
    const week = toIsoDate(startOfWeek(new Date(`${entry.date}T12:00:00`)));
    if (!dailyByWeek.has(week)) dailyByWeek.set(week, []);
    dailyByWeek.get(week).push(Number(entry.hours));
  });
  dailyByWeek.forEach((hours, week) => {
    summaries.set(week, {
      week,
      hours: hours.reduce((sum, value) => sum + value, 0) / hours.length,
      nights: hours.length,
      source: "daily",
    });
  });
  return [...summaries.values()].sort((a, b) => a.week.localeCompare(b.week));
}

export function getAllExercises(weekPlan = WEEK_PLAN) {
  const unique = new Map();
  Object.values(weekPlan).forEach((day) => {
    day.exercises.forEach((exercise) => {
      if (!unique.has(exercise.id)) unique.set(exercise.id, exercise);
    });
  });
  return [...unique.values()].sort((a, b) => a.name.localeCompare(b.name));
}

export function findPreviousExerciseLog(
  workoutLogs,
  exerciseId,
  beforeDate,
  planId = "form-flow",
  workoutDrafts = {},
  variantId,
) {
  const recordsByPlanAndDate = new Map();
  [...Object.values(workoutLogs || {}), ...Object.values(workoutDrafts || {})].forEach((log) => {
    if (!log?.date) return;
    recordsByPlanAndDate.set(`${log.planId || "form-flow"}::${log.date}`, log);
  });

  return [...recordsByPlanAndDate.values()]
    .filter(
      (log) => {
        const exercise = log.exercises?.[exerciseId];
        return (
          (log.planId || "form-flow") === planId &&
          log.date < beforeDate &&
          exercise?.sets?.length &&
          (!variantId || (exercise.variantId || exerciseId) === variantId)
        );
      },
    )
    .sort((a, b) => b.date.localeCompare(a.date))
    .map((log) => ({ date: log.date, ...log.exercises[exerciseId] }))[0] || null;
}

export function findPreviousSession(workoutLogs, dayKey, beforeDate, planId = "form-flow") {
  return Object.values(workoutLogs)
    .filter((log) => (log.planId || "form-flow") === planId && log.dayKey === dayKey && log.date < beforeDate)
    .sort((a, b) => b.date.localeCompare(a.date))[0] || null;
}

function numeric(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function cardioEntryMetrics(entry) {
  if (!entry || !EXTRA_ACTIVITY_MEASUREMENTS.includes(entry.measurement) || !Array.isArray(entry.sets)) {
    return { seconds: 0, distance: 0, rpeTotal: 0, rpeCount: 0, hasActivity: false };
  }
  return entry.sets.reduce(
    (summary, set) => {
      const seconds =
        entry.measurement === "duration" || entry.measurement === "distance_time"
          ? numeric(set.minutes) * 60 + numeric(set.seconds)
          : 0;
      const distance =
        entry.measurement === "distance" || entry.measurement === "distance_time" ? numeric(set.distance) : 0;
      const hasRpe = set.rpe !== "" && set.rpe !== null && set.rpe !== undefined && Number.isFinite(Number(set.rpe));
      summary.seconds += seconds;
      summary.distance += distance;
      if (hasRpe) {
        summary.rpeTotal += numeric(set.rpe);
        summary.rpeCount += 1;
      }
      summary.hasActivity ||= Boolean(set.completed || seconds > 0 || distance > 0 || hasRpe);
      return summary;
    },
    { seconds: 0, distance: 0, rpeTotal: 0, rpeCount: 0, hasActivity: false },
  );
}

export function summarizeCardioRange(workoutLogs, startDate, endDate, cardioExerciseIds = []) {
  const plannedIds = new Set(cardioExerciseIds);
  const totals = {
    seconds: 0,
    minutes: 0,
    distance: 0,
    sessions: 0,
    extraSessions: 0,
    averageRpe: null,
  };
  let rpeTotal = 0;
  let rpeCount = 0;
  Object.values(workoutLogs).forEach((log) => {
    if (!log || log.date < startDate || log.date >= endDate) return;
    Object.entries(log.exercises || {}).forEach(([exerciseId, exercise]) => {
      if (!plannedIds.has(exerciseId)) return;
      const metrics = cardioEntryMetrics(exercise);
      if (!metrics.hasActivity) return;
      totals.seconds += metrics.seconds;
      totals.distance += metrics.distance;
      totals.sessions += 1;
      rpeTotal += metrics.rpeTotal;
      rpeCount += metrics.rpeCount;
    });
    (log.extraActivities || []).forEach((activity) => {
      const metrics = cardioEntryMetrics(activity);
      if (!metrics.hasActivity) return;
      totals.seconds += metrics.seconds;
      totals.distance += metrics.distance;
      totals.sessions += 1;
      totals.extraSessions += 1;
      rpeTotal += metrics.rpeTotal;
      rpeCount += metrics.rpeCount;
    });
  });
  totals.minutes = totals.seconds / 60;
  totals.averageRpe = rpeCount ? rpeTotal / rpeCount : null;
  return totals;
}

function bestSetMetric(measurement, sets = []) {
  if (!sets.length) return { value: 0, label: "—", volume: 0 };
  if (measurement === "completion") {
    const completed = sets.filter((set) => set.completed).length;
    return { value: completed, label: `${completed} / ${sets.length} rounds`, volume: completed };
  }
  if (measurement === "weight_reps") {
    const evaluated = sets.map((set) => {
      const weight = numeric(set.weight);
      const reps = numeric(set.reps);
      return {
        value: weight * (1 + reps / 30),
        label: `${weight || 0} kg × ${reps || 0}`,
        volume: weight * reps,
      };
    });
    const best = [...evaluated].sort((a, b) => b.value - a.value)[0];
    return { ...best, volume: evaluated.reduce((sum, set) => sum + set.volume, 0) };
  }
  if (measurement === "weight_distance") {
    const evaluated = sets.map((set) => {
      const weight = numeric(set.weight);
      const distance = numeric(set.distance);
      return {
        value: weight * distance,
        label: `${weight || 0} kg × ${distance || 0} m`,
        volume: weight * distance,
      };
    });
    const best = [...evaluated].sort((a, b) => b.value - a.value)[0];
    return { ...best, volume: evaluated.reduce((sum, set) => sum + set.volume, 0) };
  }
  if (measurement === "assisted_reps") {
    const best = sets.map((set) => numeric(set.reps)).sort((a, b) => b - a)[0];
    const total = sets.reduce((sum, set) => sum + numeric(set.reps), 0);
    return { value: best, label: `${best} reps`, volume: total };
  }
  if (measurement === "reps") {
    const best = sets.map((set) => numeric(set.reps)).sort((a, b) => b - a)[0];
    const total = sets.reduce((sum, set) => sum + numeric(set.reps), 0);
    return { value: best, label: `${best} reps`, volume: total };
  }
  if (measurement === "duration") {
    const seconds = sets.reduce((sum, set) => sum + numeric(set.minutes) * 60 + numeric(set.seconds), 0);
    return { value: seconds / 60, label: formatDuration(seconds), volume: seconds };
  }
  if (measurement === "distance_time") {
    const distance = sets.reduce((sum, set) => sum + numeric(set.distance), 0);
    const seconds = sets.reduce((sum, set) => sum + numeric(set.minutes) * 60 + numeric(set.seconds), 0);
    const pace = distance > 0 && seconds > 0 ? seconds / distance : 0;
    return {
      value: distance,
      label: `${distance || 0} km${pace ? ` · ${formatPace(pace)}/km` : ""}`,
      volume: distance,
    };
  }
  const distance = sets.map((set) => numeric(set.distance)).sort((a, b) => b - a)[0];
  return { value: distance, label: `${distance || 0} km`, volume: distance };
}

export function summarizeExercise(workoutLogs, exerciseId) {
  const allEntries = Object.values(workoutLogs)
    .filter((log) => log.exercises?.[exerciseId]?.sets?.length)
    .sort((a, b) => a.date.localeCompare(b.date))
    .map((log) => {
      const exercise = log.exercises[exerciseId];
      const metric = bestSetMetric(exercise.measurement, exercise.sets);
      return {
        date: log.date,
        measurement: exercise.measurement,
        ...metric,
      };
    });
  if (!allEntries.length) {
    return { sessions: 0, latest: "—", best: "—", volume: "—", points: [] };
  }
  const latestMeasurement = allEntries.at(-1).measurement;
  const entries = allEntries.filter((entry) => entry.measurement === latestMeasurement);
  const best = [...entries].sort((a, b) => b.value - a.value)[0];
  const totalVolume = entries.reduce((sum, entry) => sum + entry.volume, 0);
  return {
    sessions: allEntries.length,
    latest: entries.at(-1).label,
    best: best.label,
    volume: Number.isInteger(totalVolume) ? totalVolume.toLocaleString() : totalVolume.toFixed(1),
    points: entries.map((entry) => ({ date: entry.date, value: entry.value })),
  };
}

export function formatDuration(totalSeconds) {
  const seconds = Math.max(0, Math.round(numeric(totalSeconds)));
  const minutes = Math.floor(seconds / 60);
  const remainder = seconds % 60;
  return minutes ? `${minutes}:${String(remainder).padStart(2, "0")}` : `${remainder} sec`;
}

export function formatPace(secondsPerKm) {
  const seconds = Math.max(0, Math.round(numeric(secondsPerKm)));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}
