# Native design and workflow review

Reviewed: 2026-09-14. Target: [PRD.md](PRD.md) and the earlier interactive set/rest concept.

Implementation note, 2026-09-18: native iPhone and Watch apps now exist. The findings and scores below are the historical review of the specification, not a new assessment of the implemented UI. The adaptive training brief, early AI-handoff explanation, three-tab structure, recoverable drafts, explicit actuals, partial finish, optional Health recording and durable Watch ownership are implemented. See [native/DESIGN.md](native/DESIGN.md) for current component/state decisions and [native/README.md](native/README.md) for verification limits. Simulator checks have begun; the participant and physical-device verification requested below remains open.

## Verdict

The product direction is coherent. Keep the external-AI plan builder, private local records, three iPhone tabs, focused Watch execution, and explicit recovery/progression decisions. The design is ready for focused prototypes, but several workflows need decisions before their production screens are implemented.

The largest gap is between the data rules and the user's next action. The PRD describes persistence, validation, and synchronization thoroughly; it is less specific about how a novice repairs a plan, performs a first workout, changes a schedule, or recovers from an unavailable recording device.

Overall design completeness at review time: **6/10**, a qualitative assessment of the specification. This is not a usability result or a rating of a finished native interface. No native app existed at the time of this review. The prior concept covers a repeated middle set with illustrative values; this review inspected its interaction definitions, not a new physical-device or rendered-layout test.

Recommendations below are proposals. Recording this review does not adopt a new scope or begin implementation.

## What already works

- Today / Plan / Progress gives users a manageable top-level structure. Keep Settings outside the primary training tabs.
- The iPhone/Watch division matches the different jobs: plan and understand training on iPhone; perform concise actions on Watch.
- Local persistence, unknown recovery states, immutable prescriptions, and explicit target acceptance protect the meaning of users' records.
- Imported plans can be logged even when their progression policy is unsupported.
- The forest, paper, and lime identity can translate to native semantic colors without replacing system navigation or typography.
- Permission denial, duplicate messages, and failed Health export already have engineering acceptance cases. The remaining work is to specify understandable screens and actions for those states.

## Review coverage

Scores describe the current plan, before adopting changes. A higher score requires specifying and then testing the missing interactions; writing more requirements alone cannot establish usability.

| Design pass | Score | Finding and completion condition |
| --- | --- | --- |
| Information architecture | 7/10 | Tabs are clear; Today priorities, review hierarchy, and scheduled versus active-session edit scope need explicit layouts |
| Interaction states | 5/10 | Storage states are detailed; first-set, last-set, repair replacement, missed-session, and interruption controls are incomplete |
| User journey | 6/10 | The core journey exists; external-AI round trips and manual progression need clear endings and escape routes |
| Visual specificity | 6/10 | A focused workout concept exists; onboarding, plan review, end states, and error states have no concrete visual reference |
| Design system alignment | 5/10 | Brand direction exists, but no native component/state specification or DESIGN.md exists |
| Accessibility and adaptation | 6/10 | Goals and test intent exist; small-Watch/large-text layouts, input focus, and status announcements need decisions |
| Decision completeness | 5/10 | Several user-visible choices would currently fall to the engineer during implementation |

## Findings and recommendations

P1 means resolve before implementing the affected workflow. P2 means specify and validate before the first release. These priorities are design judgments, not discovered production defects.

### D1 — P2: Explain the external-AI journey before collecting a thorough training brief

User clarification adopted on 2026-09-18: collect sufficient context for personalization. The concern is expectation-setting and relevant questions, not a target of fewer screens. Keep the seven topics when useful, adapt follow-ups, and make skipped information explicitly unknown.

Evidence: PRD sections 5.2–5.3 present seven questionnaire screens, then introduce the outbound handoff. Welcome makes a starter plan optional, while section 8.3 anticipates bundled starter assets.

Risk: a person may expect the app to generate the plan itself and discover the external step only after giving substantial information. A novice without a preferred AI has no definite alternative route. Equipment increments and detailed bio also add decisions before their immediate value is apparent.

Recommendation:

- Keep **Create my plan** as the primary route, with one visible explanation: **Use your preferred AI, then bring the plan back here.**
- Collect goals, separate strength/cardio experience, recent routine and current capabilities, available time/days, equipment, background, and preferences in the main journey. Require the basic training constraints; allow sensitive answers and uncertain details to be skipped. Show a brief with known and unknown context before prompt creation, and ask the external AI to clarify consequential gaps.
- Ask equipment-specific loading increments when first entering that exercise's load rather than during general onboarding.
- Make **Use a starter plan** a definite secondary route if the product intends to serve users without an AI. Choose an appropriate starter offering explicitly; do not silently assign the existing intensive built-in program to every novice.
- Keep **Bring an existing plan** available, distinguishing a compatible plan file from using the conversion prompt for a PDF, screenshot, or plain text.

Verify: before entering data, a first-time participant can explain what happens inside the app, what happens in their AI, and how to continue if they do not want that route. Measure the total journey including external time and help needed, alongside the current in-app-only metric.

### D2 — P1: Give AI handoff and repair a recoverable draft flow

Evidence: PRD sections 5.3–5.4 preserve responses and edits, but do not define which draft receives a corrected response or how that response interacts with intervening user edits.

Risk: repeated copy/paste trips become a loop with no clear progress; a correction can unexpectedly replace the user's edits or activate the wrong draft.

Recommendation:

- Present a persistent draft with three understandable stages: **Prompt copied → Add response → Review plan**. The app records local actions; it does not claim to know whether the external AI has finished.
- Give each draft a visible goal/name and last-updated time. Returning from another app resumes the current draft; changing candidates is explicit.
- When a parsed response lacks editable details, show **Your plan needs 2 details** with inline inputs for those fields. Require user-entered corrections and preserve unknowns. Do not require another LLM trip for every missing set count.
- Use **Copy correction prompt** for malformed or unsupported responses that cannot be repaired through the supported editor. Also allow retry, keep draft for later, and return to the starting choices.
- Before replacing a draft with a corrected response, preview material changes to schedule/exercises/targets and identify local edits that would be replaced. Offer **Use corrected version** or **Keep my edited version**; retain the prior candidate.
- A response containing questions should keep the draft in an awaiting-plan state with **Update my answers** and a clear return path.

Verify: a participant fixes a missing field without editing JSON, resumes after leaving the app, and imports a corrected response after making a local edit without losing either version.

### D3 — P1: Review and activate a real calendar, then define schedule-edit scope

Evidence: PRD section 5.4 offers a weekly review, mismatches, and start date; sections 8.1 and 10 allow future-session regeneration. A midweek start, a missed workout, and an ordinary one-off move lack defined user actions.

Risk: users inspect a long exercise list before noticing the AI ignored their availability. Activating a Wednesday start may unexpectedly shift weekday programming. Moving one workout may unintentionally change every week or stack missed work onto today.

Recommendation:

- Order plan review as **schedule/time/equipment summary → issues needing a decision → expandable session details**.
- For each explicit mismatch, show the exact difference and relevant actions: **Change this detail**, **Ask my AI to revise**, or **Keep this difference** where the user can reasonably decide. Structural errors remain blocking; medical suitability is never represented as an overridable format warning.
- Preview the first actual dates before **Use this plan**. Default proposal: preserve named weekdays and start with the first scheduled day on or after the selected date; do not move earlier-week sessions automatically.
- Distinguish **Move this workout**, **Skip this workout**, and **Change weekly schedule**. A missed session remains missed until the user chooses an action.
- Moving a session shows existing work on the destination date. It must not automatically add the missed workload to today's plan.
- A plan revision previews which future sessions change and asks how to handle one-off moves. Active and historical prescriptions remain intact.

Verify: a participant activates a midweek plan, moves a missed Monday workout once, and changes the recurring schedule without confusing those actions or losing history.

### D4 — P1: Design the first set and the last set, not only a repeated middle set

Evidence: PRD sections 5.5–5.6 require novice support, targets, editable actuals, and finish. Section 8.2 permits unassigned load. The existing concept starts at set 2 with illustrative 20 kg × 10; after its third set, its completion view has no working next-exercise action.

Risk: a first-time user cannot tell whether a number is prescribed, previously performed, or already logged. A novice with no known load has no first-set path. The middle-set interaction does not establish how exercises and the whole session finish.

Recommendation:

- Separate **Target: 8–10 reps** from **What you did**. Label reused values **Last time** or **Previous set**. Reusing a value never implies completion.
- For an unassigned load, show **Add weight used**. Do not invent a load from bio or display the concept's sample value as a recommendation. If partial logging is allowed, make **Weight not recorded** an explicit state rather than zero.
- Provide a discoverable short form cue and **Alternative exercise** action. A missing guide gets an honest state rather than generated instructional text.
- On Watch, tap the field to open a clearly labeled Crown editor; show which value is being edited, its unit, and Done/Cancel. Back it with touch controls. Do not silently round a user's entry without explaining the supported increment.
- For a normal middle set: **Log set → Rest → Next set**. Effort is optional during rest and can be marked **Not sure**.
- For the last set of an exercise: **Log set → Exercise complete**, with **Next exercise** and a rest interval only where prescribed. Zero-rest/completion work skips an empty rest screen.
- The final exercise leads to **Finish workout** and a summary of recorded versus skipped work. Finishing remains an explicit action.

Apple recommends pairing Crown interactions with touch equivalents and making navigation/focus deliberate. See [Digital Crown guidance](https://developer.apple.com/design/human-interface-guidelines/digital-crown).

Verify: a novice completes one entire exercise from an unknown load, adjusts an actual value, skips rest, undoes a set, advances exercises, and finishes a partial workout using both devices' intended controls.

### D5 — P1: Make disconnected and unfinished workouts understandable

Evidence: PRD section 9 fixes the recording owner and queues non-owner edits; sections 5.5–5.6 show start, pause, and finish controls. The visible behavior between those states remains unspecified.

Risk: the phone appears to stop a Watch workout when it cannot reach Watch, or a user starts a duplicate because the first start looks unsuccessful. An interrupted session can remain pending with no understandable recovery action.

Recommendation:

- Remember the last successfully used recording device as the primary Start choice, while keeping an obvious device selector.
- Show **Starting on Watch** until confirmed. On uncertainty offer **Check Watch** and **Try connection again**. An explicit separate phone session explains that Watch may already be recording.
- When disconnected, show **Recording on Watch · last updated…**. An unacknowledged pause/finish request must not switch to a confirmed paused/completed presentation. Provide **Use Watch to pause** or an equivalent truthful next action.
- Distinguish durable queued set corrections from live session controls. Pending edits are visible without implying the owner accepted them.
- On return to an unfinished workout, show session name, recording device, last saved set, and recorded time with **Resume**, **Finish with recorded work**, and **Discard session**.
- If the owner cannot be recovered, allow saving the already received work as an interrupted result. Explain that recording on an unreachable Watch has not been confirmed stopped. Later Watch data must trigger review rather than overwrite or duplicate that result.
- Define leaving the screen separately from pausing recording. After accidental finish, allow correcting the saved log; continuing exercise starts a clearly related new recording segment if the original Health session has ended.
- Resolve conflicts with **Use Watch value**, **Use iPhone value**, **Enter corrected value**, and **Review later**. Labels must identify the affected set, not only a synchronization error code.

Verify: participants can correctly identify where recording is running and whether a pause/finish succeeded during a simulated disconnection. No normal action requires understanding the term “recording owner.”

### D6 — P2: Complete the recovery-to-next-target journey for imported plans

Evidence: PRD section 5.7 specifies recovery and acceptance rules, but not a clear recommendation entry point or the everyday manual-target workflow for imported plans.

Risk: a user provides recovery information without seeing how it affects training. Most imported plans have manual progression, so the advertised train/review/adjust journey ends without an obvious adjustment action.

Recommendation:

- Today shows a due check-in beneath the current workout/resume action; check-ins never block starting or resuming training.
- Define **Later** as eligible to appear again at the next appropriate visit, **Not sure** as a saved unknown answer, and **Skip this check-in** as dismissing that prompt while keeping the missing data explicit. All can be edited from the associated session.
- A supported recommendation appears as **Next time**, showing current target → proposed target, a short reason, and the upcoming session affected. Actions: **Use next time**, **Keep current**, and **Details**.
- For manual plans, show **Repeat current target** and **Edit next target** with comparable past performance. Updating the future target must not require rebuilding the whole weekly plan.
- When recovery is unknown, explain what is missing without presenting it as failure or inferring a readiness score.

Verify: after finishing a sample workout and returning the following day, a participant can supply or skip recovery, understand the next-target state, and repeat or edit a target on a manual imported plan.

### D7 — P2: Specify screen hierarchy, empty states, and a small native component system

Evidence: PRD sections 5.1 and 5.6 name the destinations and visual direction, but no native DESIGN.md or screen/state component specification exists.

Recommendation:

- Today prioritizes **Resume active workout**, otherwise **Next scheduled workout**; due check-ins and later sessions follow. Completed-day state shows what was recorded and the next planned day. A rest day is a valid state with **Log extra activity** available.
- Plan uses a weekly list and expandable session details. Progress begins with recent history and meaningful trends; insufficient history gets an explanation and a useful next action rather than a blank chart.
- Settings is a toolbar destination, not a fourth equal training tab.
- Define semantic surface/text/accent/destructive colors, SF text styles, numeric styles, control roles, spacing, and light/dark behavior. Keep the lime fill for primary workout actions and preserve readable foreground contrast.
- Specify common components: session row, target/actual editor, set status, rest control, import issue row, disclosure guide, save-status detail, and next-target review.
- Provide native text-input and Dynamic Type behavior instead of adopting web-specific font rules. Brand identity can live in color and composition while system typography supports the native experience.

Verify: a person can identify the next useful action on an empty, active, resting, completed, and error state without opening Settings or reading a technical explanation.

### D8 — P2: Make accessibility and small-Watch behavior concrete

Evidence: PRD sections 5.6 and 11 require accessibility but do not specify how the essential controls adapt. The concept uses small secondary labels and assumes both values fit beside each other.

Recommendation:

- Specify the smallest supported Watch layout at the largest supported text setting. Allow one editable quantity at a time rather than compressing two inputs and their units.
- Keep the primary completion action reachable and separate from finish/discard. Adopt approximately 44-point touch targets where practical for workout controls, with adequate spacing.
- Give each quantity a complete accessible label, value, unit, and input hint. Announce successful save, rest expiry, and meaningful connection changes; do not announce each timer tick.
- Haptics supplement visible state; they are not the only indication that rest ended. Preserve the manual/no-Health background limitations already in the PRD.
- Support Dynamic Type, contrast, light/dark appearance, reduced motion, and touch alternatives to Crown editing. Avoid encoding completed/pending/error status through color alone.

These recommendations follow [Apple's accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility) and [Watch layout guidance](https://developer.apple.com/design/human-interface-guidelines/layout). Final contrast, truncation, and reachability need rendered and physical-device verification.

## Proposed interaction-state coverage

This table describes the next design pass; it is not evidence that these states have been implemented.

| Flow | Waiting/loading | Empty | Error | Success | Partial/interrupted |
| --- | --- | --- | --- | --- | --- |
| Profile | Local save occurs without blocking Next | Short explanation and required choices | Inline field feedback preserving answers | Reviewed summary | Resume exact step |
| AI handoff | “Prompt copied”; no fake generation spinner | Copy prompt or choose another starting route | Copy failed with Retry | Response attached to named draft | Resume handoff / keep for later |
| Import | Checking response | Paste response / choose file | Specific issue with inline fix or correction prompt | Reviewable weekly plan | Preserve candidate and local edits |
| Activation | Saving plan and dates | No scheduled sessions: return to review | Invalid date/conflict with affected sessions shown | First scheduled workout and actual date | Save draft without changing active plan |
| Start | Starting on selected device | Watch cache empty: synchronize from phone | Unconfirmed start with Check Watch / Retry | Confirmed active workout | Recover original start request |
| Logging | Local save pending | Actual quantity not entered | Input issue without lost value | Set logged, then rest/advance | Unsynced correction explicitly pending |
| Finish | Saving recorded work | No completed work: review or discard | Local save failed: preserve session and retry | Summary plus next action | Finish recorded work / resume |
| Recovery | Saving answer | No due items: no prompt | Retry answer save | Answer linked to named session | Later / not sure / skipped remain distinct |
| Next target | Rechecking relevant history | Manual repeat/edit route | Stale advice: show updated comparison | Future session updated | Keep current while reviewing |
| Synchronization | Saved locally, waiting to sync | No pending work | Specific conflict or connection action | Synced status in detail | Both values preserved for review |

## Proposed journey and emotional checkpoints

These are hypotheses for usability testing, not claims about observed users.

| Stage | User's likely question | What the design must answer |
| --- | --- | --- |
| First five seconds | “Does this help me, and do I need another app?” | Plain product purpose, external-AI expectation, and starting choices |
| Profile | “Why do you need this?” | Required versus optional, purpose, and export choices |
| External handoff | “What do I copy, and how do I get back?” | Stable draft, exact copy action, clear return stage |
| Plan review | “Did it follow my requirements?” | Schedule/equipment/time fit before exercise detail |
| First workout | “What do I enter now?” | Prescribed target versus actual result; unknown load path |
| During training | “Did that save? Am I resting?” | Immediate local feedback, clear timer and recording device |
| Missed/interrupted workout | “Have I broken my plan?” | Move, skip, resume, and finish-recorded-work choices without punishment |
| Following day | “What should I do next?” | Recovery context plus repeat/edit/accept future target |
| Long-term use | “Can I change plans without losing my history?” | Stable history, explicit revisions, and accessible backup |

## Prototype and specification tasks

These are proposed tasks derived from the findings. Estimates cover design/specification effort, not production coding or participant recruitment. No supported AI time-compression benchmark exists for this repository, so none is assumed.

| Task | Priority | Deliverable | Verify | Estimate |
| --- | --- | --- | --- | --- |
| T1: Explain starting routes and collect relevant context (D1) | P2 | Revised welcome/adaptive profile flow in PRD | Participant explains external handoff and can review known/unknown context | 2–3 hours |
| T2: Specify draft, repair, and replacement states (D2) | P1 | Handoff/repair prototype and draft-state requirements | Missing-field repair plus corrected-response/local-edit conflict | 3–5 hours |
| T3: Specify calendar activation and change scope (D3) | P1 | Review/activation/reschedule prototype | Midweek start and one-off missed-session move | 3–5 hours |
| T4: Complete first-to-last-set interaction (D4) | P1 | iPhone/Watch exercise flow with target/actual controls | Unknown load through final exercise and partial finish | 4–6 hours |
| T5: Specify disconnected and unfinished session recovery (D5) | P1 | State/action table and recovery screens | Unconfirmed remote start, pause, finish, and later conflict | 4–6 hours |
| T6: Complete recovery and manual next-target path (D6) | P2 | Today/review/next-target flow | Unknown recovery and manual repeat/edit | 2–3 hours |
| T7: Define native components and adaptation (D7–D8) | P2 | DESIGN.md plus smallest-Watch/large-text variants | Native layout review and accessible control walkthrough | 3–5 hours |

First prototype round: complete novice onboarding/import, one repair, one first workout, and one disconnected session. Follow with calendar changes and recovery-to-next-target. Each finding should produce an explicit PRD decision and a test case before the related screen is implemented.

## Deliberately deferred

- A visual rebrand: the current identity is sufficient to test the workflows.
- Embedded AI generation: the user selected an external-AI copy/import model.
- A new clinical suitability engine: outside the product scope and not a substitute for user review.
- A full program-authoring canvas: focused edits cover the identified problems.
- More charts, animations, and convenience surfaces: validate the core journey first.
- Foundation code and production screens: implementation was paused during this review, then authorized by the user on 2026-09-18. The first native slice is tracked in `native/README.md`; remaining findings are not all implemented.

## Decisions still open

1. Is a starter-plan route required for users who do not want to use an external AI? Recommendation: yes, with an explicitly chosen suitable starter offering.
2. Should failed-but-parseable imports support inline repairs? Recommendation: yes for supported missing/invalid fields; never guess doses.
3. What is the initial partial-week rule? Recommendation: preserve weekdays and start on the first eligible date.
4. Can users save a set with an unrecorded actual load? Recommendation: allow an explicit unknown state where the measurement/domain rules support it, preserving limits on resulting statistics/progression.
5. What should happen when a recording device cannot be recovered? Recommendation: save received work as interrupted, keep uncertainty visible, and reconcile later data without pretending the remote recording stopped.
6. What is the first-release manual next-target editor? Recommendation: repeat or edit an individual upcoming exercise target without regenerating the plan.

The review is complete. The proposals remain open until they are adopted or revised; the current PRD is not being declared design-complete or usability-validated.
