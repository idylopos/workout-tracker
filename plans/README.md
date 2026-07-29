# Add a workout plan

Each public plan lives in its own folder:

```text
plans/
  my-plan/
    plan.json
```

Push the folder to `main`. The GitHub Pages workflow validates it, adds it to the plan picker, and publishes it
automatically. No central registry needs to be edited.

The folder name and the JSON `id` must match. Use lowercase letters, numbers, and hyphens. Start by copying
`example-plan/plan.json`.

## Privacy

Everything inside `plans/` is public. Do not include names, birth dates, measurements, diagnoses, contact details, private
notes, or other personal information. Plan folders contain programming instructions only. User-entered logs remain in
each visitor's browser and are not part of a plan.

## Required plan fields

```json
{
  "schemaVersion": 1,
  "id": "my-plan",
  "name": "My weekly plan",
  "description": "Optional public summary",
  "days": {
    "monday": {
      "label": "Monday",
      "short": "MON",
      "focus": "Full Body",
      "kicker": "Strength",
      "estimate": "45–60 min",
      "tone": "lime",
      "sequenceNote": "Optional session instruction.",
      "warmup": ["Easy cardio · 5 min"],
      "exercises": [
        {
          "id": "goblet-squat",
          "name": "Goblet squat",
          "prescription": "3 × 8–12",
          "sets": 3,
          "rest": 120,
          "measurement": "weight_reps",
          "category": "Strength",
          "optional": false
        }
      ]
    }
  }
}
```

Days that are omitted become rest days. Supported tones are `lime`, `blue`, `orange`, `pink`, `purple`, `teal`, and
`rest`.

Supported measurements:

- `weight_reps`
- `reps`
- `assisted_reps`
- `duration`
- `distance_time`
- `distance`

An exercise ID may be reused on multiple days when those logs should contribute to the same exercise statistics.

## Optional progression

Add `longRuns` and `longRunDay` when the plan has a week-by-week progression:

```json
{
  "longRunDay": "saturday",
  "longRuns": ["4.5 km", "5.0 km", "5.5 km", "Recovery · 4.5 km"]
}
```

## Prompt for a plan generator

Give an AI the example file and ask:

> Create a safe weekly workout plan as one valid JSON object matching this example exactly. Use schemaVersion 1, a
> lowercase hyphenated ID, only supported measurement values, 1–20 sets, and 0–900 rest seconds. Omit personal
> identifiers and medical details. Return JSON only.

AI-generated exercise guidance should be reviewed by a qualified professional when injuries, medical conditions, or
individualized clearance are relevant.

