# Health recording verification

The shared adapter uses `HKWorkoutSession` and its `HKLiveWorkoutBuilder` on iOS 26 and watchOS 26. A user explicitly chooses Health recording when starting a workout. Denied or unavailable Health access leaves manual recording available. Only the session's designated local recording owner creates a builder or exports a workout. The iPhone's mirrored Watch session has separate identity and metrics and never exports.

The app requests workout and active energy write access, and workout, heart rate and active energy read access. Unavailable readings remain nil. Only readings received from Health are displayed; manual set values are not converted into sensor samples. Activity mapping uses explicit session kinds, falling back to `other` for unspecified cardio. Neither routes nor location access are requested.

## Durable export rules

`HealthJournal` stores an export correlation UUID before recording begins and a `saving` intent before `finishWorkout()` can run. Correlation, domain workout ID, workspace generation and owner are stored as Health metadata. Successful export stores the returned Health workout UUID. A failed or nil completion after entering `finishWorkout()` is ambiguous and becomes pending verification. A nil successful result is permitted by HealthKit while a device is locked.

Reconciliation queries the correlation metadata and verifies the other identity metadata. One matching UUID completes the journal; no matches or conflicting matches remain unresolved. Health read permission is opaque, so an empty query never authorizes a duplicate write. A retry is available only after a failure before the save call and while the original builder is retained in memory. The adapter does not recreate sensor recordings from historical sets after relaunch. Corrupt journal data disables recording instead of silently replacing export history.

The journal is device-local, stored atomically in Application Support with complete protection until first authentication. A workspace reset does not delete it. It is not part of the portable workout backup and must not be replaced by imported data. These are durable application deduplication rules, not a claim that HealthKit provides globally exactly-once writes.

## Host integration

- Persist workout start and each domain change before invoking recording actions.
- Re-read the current domain workout and generation after asynchronous start or recovery. Discard if it was abandoned or retired, finish if it ended while waiting, and align pause state.
- On relaunch, call `recover(workout:)` for the local live workout. Recovery adopts only matching durable correlation metadata; it never starts another session on failure. Call `reconcilePendingExports()` to inspect interrupted saves.
- `onSessionStateChanged` reports system pause/resume. Persist a matching domain operation only when the domain's live state differs; the callback does not finish a workout or bypass partial-finish confirmation.
- Watch mirroring starts after collection begins. The phone registers its mirroring handler during adapter initialization. Mirrored identity and metrics are separate from phone-owned recording. A live mirrored session is never adopted as a phone-owned builder.

## Automated checks and remaining device gates

The 12 `HealthJournalTests` pass using the installed Xcode toolchain. They cover owner and generation isolation, write-ahead transitions, coding round trips, terminal export protection, 100 repeated empty reconciliation results, ambiguous-save retry rejection, positive reconciliation, conflicting matches, known pre-save retry and malformed journal validation. Both apps compiled with the adapter on 2026-09-18. These checks do not simulate Health authorization, sensor delivery or real-device background behavior.

Before release, use a signed physical iPhone/Watch pair to verify:

1. Allow, deny and later revoke Health permissions. Verify no fabricated zeros and manual logging throughout.
2. Start on Watch, lock phone, collect heart rate/energy, pause/resume from hardware/system controls, and finish. Confirm one Health workout with matching metadata and one designated exporter.
3. Disconnect the phone, finish offline on Watch, reconnect and verify application history delivery without phone export.
4. Terminate the owner during recording, recover it, then pause/finish. Also finish/abandon the domain while recovery is awaiting its result.
5. Interrupt before save, after the durable save intent, and immediately after Health saves. Relaunch and confirm a matching result resolves the journal while empty queries remain pending.
6. Finish while locked. Confirm a nil Health result does not trigger another save.
7. Reset the workspace during permission/recovery and verify the original recording stops without rewriting retained workout history.
8. Check live mirroring reconnect/relaunch behavior on the physical pair. This implementation has no Live Activity, no remote set-edit protocol through HealthKit, and no promise of mirrored-session recovery when the system does not supply a recoverable session.

API references: [Building a multidevice workout app](https://developer.apple.com/documentation/healthkit/building-a-multidevice-workout-app), [HKWorkoutSession](https://developer.apple.com/documentation/healthkit/hkworkoutsession), and the installed SDK's `HKWorkoutBuilder.h`, `HKHealthStore.h`, `HKLiveWorkoutBuilder.h` and `HKWorkoutSession.h` contracts.
