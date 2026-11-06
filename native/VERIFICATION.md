# Development verification — 2026-09-19

## Follow-up: Review brief recovery

A missing essential previously disabled “Create and review prompt” while its explanation was far above the action. Missing fields now open their questionnaire section directly; the primary action becomes “Complete missing answers”, and the section provides “Return to brief”. Optional bio fields and privacy inclusion remain optional. Structured requirement identifiers preserve the existing validation rules and avoid routing by display text.

Verified after this fix: **207 shared tests**, **8 hosted AppStore tests**, and **one new end-to-end UI regression** passed, with lint and diff checks clean. The UI test leaves training location missing, repairs it through the primary action, returns to the brief and creates a simple bodyweight prompt with optional fields blank. Logs: `/tmp/formflow-core-brief-fix.log`, `/tmp/formflow-brief-fix.log`; result bundle: `/tmp/formflow-brief-fix.xcresult`. The broader baseline and its source fingerprint below describe the earlier checkpoint, before this follow-up.

## Earlier development checkpoint

Environment: Xcode 27.0 (27A266a), iOS 27.0 Simulator (24A434) on an iPhone 18 Pro, and watchOS 27.0 Simulator. Deployment minimums remain iOS/watchOS 26; those minimum versions have not been exercised on hardware.

There are **403 distinct passing tests** across the current integration and focused rerun: 205 shared Swift domain, 85 web, 109 hosted iPhone and 4 iPhone UI tests. Native execution was Simulator-only. The focused rerun corrected UI-test interactions without changing production code.

| Check | Evidence |
| --- | --- |
| Web regression and progression parity | 85 passed; `/tmp/formflow-web-0919-final.log` |
| Shared Swift domain | 205 passed; `/tmp/formflow-core-0919-final.log` |
| Hosted iPhone persistence/integration | 109 passed; `/tmp/formflow-native-0919-final.log` |
| iPhone UI workflows | Four distinct passes: profile answers/section survive relaunch; sample plan becomes a recorded partial workout; largest-text welcome/profile controls remain reachable; selected-profile deletion requires review/confirmation, cancellation preserves data, and confirmed deletion survives relaunch |
| Native compilation | iPhone and embedded Watch targets compile for Simulator. No Swift compiler warnings; Xcode emits AppIntents metadata notices because these targets do not define App Intents |
| Watch launch | Latest Watch app installed and launched on paired Watch Series 12 (46 mm) Simulator. Empty state inspected in `/tmp/formflow-watch-0919-final.png` |
| Static checks | `npm run lint` passed for 137 source/data files, 21 JavaScript syntax checks, Swift syntax and Xcode project checks. `git diff --check` passed |
| Native CI | Workflow added and previously syntax checked locally; no GitHub run, signing or distribution performed |

The full native run recorded 109 hosted and three UI passes, plus a failure in the new deletion test's navigation. Its log remains at `/tmp/formflow-native-0919-final.log`; Xcode subsequently pruned that run's result bundle under its normal derived-data retention. The passing deletion rerun is recorded in `/tmp/formflow-deletion-ui-0919.log` and `Test-FormFlowiOS-2026.09.19_14-16-40-+0800.xcresult`. A copy outside Xcode's result-retention directory is at `/tmp/formflow-verification-0919/deletion-ui.xcresult`; its summary records one passed test, zero failures and zero skips. These local temporary artifacts are not committed repository files.

The deletion test originally tapped an offscreen SwiftUI switch label, leaving Review disabled. It now scrolls the complete row into view, taps the trailing switch, verifies selection, and scrolls the lazily rendered Review button into view. iOS 27 presents the native confirmation as a popover whose accessible dismiss region replaces its Cancel row; the test handles both presentations. Cancellation, confirmation and both relaunch checks then passed. Verbose Simulator diagnostic collection stalled after the initial failure; only that run's diagnostic collector was stopped, allowing Xcode to finalize the completed results. Focused runs used `-collect-test-diagnostics never`, retaining normal test logs and screenshot attachments.

New persistence coverage includes selected-category dependency cleanup, original source/recovery-copy deletion, rollback and stale-preview refusal, reload failures after committed deletion, retired Watch records remaining read-only without blocking a new scheduled workout, earlier native-backup operation compatibility, reviewed legacy activity reuse, and source-preserving edits. Shared coverage also includes versioned transport, deterministic 90-minute replay scenarios, supplied-profile constraints, and legacy progression evidence with source revalidation.

Limited visual evidence includes the passing deletion preview (`/tmp/formflow-deletion-ui-passed/C286E31A-0EDA-43CF-85D9-E72025B20A35.png`), the earlier largest-text experience choice with wrapping labels, and a dark welcome screen on iPhone 18 Pro Max (`/tmp/formflow-dark-welcome-0919.png`). These checks do not establish full accessibility or dark-mode coverage.

The UI tests use synthetic isolated workspaces and disable Health and WatchConnectivity. Shared tests establish replay, ownership, conflicts and export-journal rules; they do not reproduce Bluetooth, sensor delivery or the operating system's workout lifecycle. The Watch screenshot verifies only startup and its empty state, not a cached-plan transfer or completed workout.

The tested source/configuration fingerprint is SHA-256 `9e8e5fa4420a6bf43196729358c3047dfad3aac3d7d6202f9060c395cd1cc76f` across 121 files. It covers nonhidden, non-Markdown files in `native/` and `packages/FormFlowCore/` (excluding `xcuserdata`), plus `package.json`, the lint/project-generator scripts and the native CI workflow. Hash input is each sorted relative path, NUL, file bytes, NUL. The workspace is uncommitted.

Before release, complete [RELEASE_ACCEPTANCE.md](RELEASE_ACCEPTANCE.md) and the physical scenarios in [HEALTH_VERIFICATION.md](HEALTH_VERIFICATION.md): a real 90-minute disconnected workout, denied/revoked permissions, locked/background recording, interrupted Health saves, Watch replacement, full VoiceOver/Switch Control and small-device layouts, minimum-device performance, and representative-user onboarding. Legacy facts can support guarded progression; date-only legacy groups remain separate from native session trends. Signing, distribution assets and TestFlight remain unconfigured.
