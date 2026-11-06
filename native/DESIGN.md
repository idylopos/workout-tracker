# Native interface decisions

This document describes the implemented direction. It does not substitute for the accessibility and usability checks in the PRD.

## Navigation and layout

- iPhone uses Today, Plan and Progress tabs. Settings is a labeled toolbar destination on each tab.
- Today puts recovery requests, an interrupted local workout, and a current Watch recording ahead of future sessions. Before activation it explains the external-AI journey and offers profile building or direct import.
- Plan setup uses native forms, pickers and editable summaries. A saved draft survives leaving the screen. Review and activation are separate actions.
- Workout editing uses a full screen for numerical entry. Planned targets remain visible above actual values. Missing actuals stay empty.
- Watch uses a scrollable list of cached sessions, compact workout actions and dedicated set/interval editors. Draft values, confirmed local saves and phone receipts have distinct labels.

## Color and typography

`Theme.swift` owns iPhone semantic colors. Light appearance uses paper (`#F6F2E9`), forest (`#17211B`) and lime (`#D8FF52`). Dark appearance uses forest surfaces and lime emphasis. Primary actions use dark text on lime; ordinary links use the appearance-specific accent. Use system primary/secondary text colors on system list surfaces.

Use system text styles instead of fixed text sizes. Numerical elapsed/rest displays use monospaced digits. Text wraps and the containing form scrolls; avoid fixed-height content cards. Destructive actions use system destructive roles and an explanation before confirmation.

## Interaction and state

| State | User-facing behavior |
| --- | --- |
| Profile has missing essentials | Show tappable missing fields; the primary action opens the first missing section, with a direct Return to brief action. Preserve optional unknowns |
| Profile changed after prompt creation | Mark the prompt stale; rebuild before copying |
| AI handoff | Show the exact copyable text; never imply an AI request is running |
| Invalid plan | Preserve the response, show concrete findings, offer a correction prompt |
| Valid plan | Review schedule, instructions and targets before activation |
| Workout draft | Save entered actuals without marking work complete |
| Confirmed set | Show recorded values and completion; start rest from its saved deadline |
| Save failure | Keep the unacknowledged change available for retry; do not claim it was recorded |
| Watch unreachable | Distinguish a local save from a confirmed transfer |
| Conflicting edit | Preserve accepted and proposed values for explicit review |
| Health unavailable | Keep manual logging usable and sensor metrics unavailable |
| Partial finish | Confirm; retain incomplete work separately from completed results |
| Selected deletion | Start with no choices selected; review record counts and dependent source copies; confirm explicitly |
| Retained incomplete record after workspace retirement | Show archived, read-only actuals and frozen elapsed time; allow a separate new workout |
| Deleted data committed but reload failed | Replace editing with a reload action; never save stale displayed values back into the store |

Put navigation and secondary actions in separate rows where possible. When a List row contains more than one control, give its secondary buttons an explicit style so SwiftUI does not activate every button in the row. Logging, copying, activation, restore and deletion always require explicit user actions.

## Accessibility verification

Primary controls have text labels and UI automation identifiers. Statuses use words and symbols in addition to color. Charts include textual counts and actual-value lists. Forms use system navigation and scrolling; there are no essential custom motion effects.

Simulator checks cover reachability of welcome/profile actions at the largest accessibility text size. A separate dark-appearance welcome screenshot was inspected on iPhone 18 Pro Max; the forest surfaces, text and primary action remained readable. These are limited screen checks. Before release, test VoiceOver focus/order and announcements, all numerical editors, Switch Control, reduced motion, contrast and large text on the smallest supported iPhone and Watch. A readable Simulator screenshot is not evidence that these full-device workflows have passed.
