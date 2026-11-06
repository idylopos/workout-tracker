# Form / Flow native apps

An account-free SwiftUI iPhone app and companion Watch app, with shared training logic in a local Swift package. The existing web tracker remains available separately.

## Implemented workflows

- **Plan creation:** seven resumable, adaptive training-profile sections; reviewable known/unknown context; an editable, versioned external-AI prompt; explicit selection of sensitive fields; saved prompt and response history. Changed answers, privacy choices or template versions require rebuilding before copy.
- **Plan import:** paste/file input, bounded and strict v2 parsing, compatible legacy v1 plans, actionable format findings, correction prompt, local exercise/alternative/interval editing, calendar preview and explicit activation. A saved revision library and explicit reimport choices protect existing plans. Backups route to a separate restore preview.
- **Existing program:** a bundled snapshot of the web program, with its original guidance, two blocks, six pull-up steps and 18 long-run stages. Loading requires review; it is not assigned automatically to a new user.
- **iPhone training:** blank actual values, durable drafts, explicit set/interval completion, alternatives, extra activities, previous-value copying, rest deadlines, pause/resume, partial finish, corrections and immutable historical prescriptions.
- **Watch training:** cached plans, local set/interval drafts and recording, alternatives, extra activities, rest, partial finish and durable delivery to iPhone. Remote start requests retain their identity and are reconciled after uncertain delivery. Non-owner edits are revision-checked proposals.
- **Calendar and review:** one-off moves/skips/missed decisions, readable imported web history, native workout trends, manual sleep/body records, session-linked recovery, optional supported progression and explicit future-target acceptance. Exact legacy facts can contribute to supported progression without fabricated session timing. Legacy reusable activities have a review-and-convert path that preserves their source and requires missing targets. Duplicate records can be excluded reversibly; unavailable-device snapshots remain available for review.
- **Health and privacy:** opt-in Health recording with a manual fallback, a persistent export journal, selected-category backup/restore and deletion, local app locking and workspace reset with retired device generations. Deletion previews dependencies and requires confirmation; retained incomplete records from an older workspace become read-only and do not block new training.

This is a development build. Automated checks establish specific storage and domain behavior; they do not establish the physical-device, accessibility, usability or performance release gates in the PRD.

## Open and run

1. Complete Xcode first-run setup and install iPhone and Watch Simulator runtimes.
2. Open `native/FormFlow.xcodeproj`, choose **FormFlowiOS**, select an iPhone Simulator and Run.
3. Choose **FormFlowWatch** and a paired Watch Simulator to run the companion.
4. For hardware, set your signing team on both app targets and use suitable bundle identifiers. Enable the HealthKit capability in the corresponding signing configuration.

Deployment minimums are iOS 26 and watchOS 26. Development verification used Xcode 27. The project has no third-party app dependencies.

```sh
xcodebuild -project native/FormFlow.xcodeproj -scheme FormFlowiOS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/formflow-build CODE_SIGNING_ALLOWED=NO build

xcodebuild -project native/FormFlow.xcodeproj -scheme FormFlowWatch \
  -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath /tmp/formflow-build CODE_SIGNING_ALLOWED=NO build
```

`scripts/generate-native-project.py` regenerates the checked-in Xcode project using Python's standard library. Source folders use synchronized Xcode groups, so added Swift files are included automatically. Regenerate when changing targets or build settings; it replaces the project file.

## Verify

The [development verification record](VERIFICATION.md) documents an earlier checkpoint of **403 distinct passing tests**: 205 shared Swift domain, 85 web, 109 hosted iPhone and 4 iPhone UI tests. The deletion UI test passed after correcting its scrolling and native-popover interactions; the verification record distinguishes the full run from that focused rerun. The subsequent Review brief fix passed 207 shared tests, eight hosted AppStore tests and a new full questionnaire-to-prompt UI regression. Native execution was Simulator-only; physical-device release checks remain outstanding.

Use the full Xcode toolchain, selected with `xcode-select`, for XCTest:

```sh
npm run lint
npm test
swift test --package-path packages/FormFlowCore
xcrun simctl list devices available

# Replace the ID with an installed iPhone Simulator from the previous command.
xcodebuild -project native/FormFlow.xcodeproj -scheme FormFlowiOS \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_ID' \
  -derivedDataPath /tmp/formflow-build CODE_SIGNING_ALLOWED=NO test
```

The iPhone scheme includes hosted persistence tests and XCUITest flows. UI tests use a separate persistent workspace per test, with Health and Watch transport disabled. This makes relaunch tests meaningful without modifying the ordinary app store; these UI tests do not verify paired-device transport.

[Native CI](../.github/workflows/native.yml) runs lint, web tests, shared Swift tests, hosted/UI tests and a Watch build. It uses the [macOS 26 GitHub runner](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md) and discovers an installed iPhone Simulator rather than assuming a device name. The workflow has not yet run on GitHub.

## Code and data boundaries

| Path | Responsibility |
| --- | --- |
| `packages/FormFlowCore` | Plan/profile contracts, import, schedule, workout reducer, transport validation, recovery, progression, trends and backup adapters |
| `native/FormFlowiOS` | SwiftUI workflows, SwiftData persistence, backup transactions and app lock |
| `native/FormFlowWatch` | Watch interaction, atomically stored workout/draft archive and owner operations |
| `native/Shared/PlanBridge.swift` | Versioned plan delivery, durable transfer inbox/outbox, receipts, remote starts and proposed edits |
| `native/Shared/HealthRecording.swift` | Optional owner recording, mirroring, recovery and export reconciliation |

Public v2 schema/example and the built-in program snapshot live in the package's `Resources` directory. Imported JSON is data: no scripts or arbitrary progression rules execute. Parser limits establish readability, not exercise suitability. Legacy prose remains available for review rather than being converted into guessed numeric targets.

Only activated training content and relevant recording data cross to the Watch. Private profile answers, prompts and raw AI responses remain on iPhone unless the user explicitly includes them in a copy/export. There is no embedded AI API, app account or custom backend. Device backups follow system settings; the app is not an independently encrypted vault.

Restore is previewed and committed atomically. Older native backups whose operations predate an explicit version field remain compatible without changing their original source bytes. Restored in-progress workouts remain archived rather than restarting a recording. Reset deletes app records and retires the old synchronization generation. Selected deletion also retires that generation when removing plans or workout history; unrelated parsed records remain. Both deletion paths remove private database recovery copies, and selected deletion removes original imported files and raw response drafts because those may contain copies of the selected data. Existing exports and Apple Health workouts remain outside app deletion. The minimal local Health export journal is retained to prevent blind duplicate writes.

The SwiftData schema is explicitly versioned. Before adopting an existing development store or opening a later schema version, the app takes a consistent SQLite recovery copy, including committed WAL contents. A restore that replaces existing records also keeps a before-image. The original pre-migration copy survives failed retries; a newer store version is refused before opening. Startup errors offer retry and a user-directed recovery-folder export, protected by the existing app-lock preference. This export includes all private categories and is not a normal JSON backup. JSON backups and recovery exports are explicitly labeled unencrypted. A load failure after committed deletion blocks editing until reload succeeds, preventing stale displayed data from being saved again.

Future schema changes must preserve prior model definitions and add explicit migration stages; do not edit a released schema in place. The implementation follows [SwiftData schema migration](https://developer.apple.com/documentation/swiftdata/schemamigrationplan) and uses the [SQLite backup API](https://www.sqlite.org/backup.html) rather than copying a live database file.

## Remaining release verification

See [the acceptance evidence inventory](RELEASE_ACCEPTANCE.md), [the PRD acceptance matrix](../PRD.md#112-required-release-scenarios), [native interface decisions](DESIGN.md) and [Health recording verification](HEALTH_VERIFICATION.md).

Physical iPhone/Watch checks remain outstanding: denied/revoked permissions, sensor delivery, offline relaunch and reconnection, background/locked recording, lost acknowledgments, Watch replacement, system interruption, haptics and Health reconciliation. Full VoiceOver/Switch Control, small-Watch/large-text coverage, minimum-device performance and a representative usability study also remain open. Legacy workouts/body/sleep have readable preserved-history screens, but are not all native editable rows or included in native-session trends. Signing, distribution assets and TestFlight rollout are not configured.
