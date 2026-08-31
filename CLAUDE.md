# Form / Flow workout tracker

Static, mobile-first workout log. No framework, no bundler: `index.html`, `styles.css`, `app.js`, `lib.js` are the app;
`npm run build` copies them plus the plan catalog into `dist/` (gitignored). Serve `dist/` locally with
`python3 -m http.server 8080` from inside `dist/` so `/plans/index.json` resolves.

## Testing

- Run: `npm test` (Node's built-in runner over `tests/*.test.mjs`)
- After changing the built-in plan in `lib.js`: `npm run sync-plan` and commit `WORKOUT_PLAN.md` with it.
- Never commit code that makes existing tests fail.

## Skill routing

When the user's request matches an available skill, invoke it via the Skill tool. When in doubt, invoke the skill.

Key routing rules:
- Product ideas/brainstorming → invoke /office-hours
- Strategy/scope → invoke /plan-ceo-review
- Architecture → invoke /plan-eng-review
- Design system/plan review → invoke /design-consultation or /plan-design-review
- Full review pipeline → invoke /autoplan
- Bugs/errors → invoke /investigate
- QA/testing site behavior → invoke /qa or /qa-only
- Code review/diff check → invoke /review
- Visual polish → invoke /design-review
- Ship/deploy/PR → invoke /ship or /land-and-deploy
- Save progress → invoke /context-save
- Resume context → invoke /context-restore
- Author a backlog-ready spec/issue → invoke /spec
