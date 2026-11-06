import XCTest
@testable import FormFlowCore

final class RemoteWorkoutTransportTests: XCTestCase {
    func testLostStartReplyProbeReturnsSameWorkoutWithoutStartingAnother() throws {
        let plan = try XCTUnwrap(PlanImporter.importText(PlanContract.exampleJSON).plan)
        let session = try XCTUnwrap(plan.days.flatMap(\.sessions).first)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let intent = RemoteWorkoutStartIntent(syncGeneration: "generation", planID: plan.id, planRevisionID: "revision",
            prescriptionID: session.id, scheduledSessionID: "today-session", scheduledDay: .init(instant: now, timeZone: .current), requestedAt: now)
        let first = resolve(intent, plan: plan, now: now)
        XCTAssertEqual(first.status, .started)
        let replay = resolve(intent, previous: first, allowStart: false, plan: plan,
            workouts: [try XCTUnwrap(first.workout)], now: now.addingTimeInterval(600))
        XCTAssertEqual(replay, first)
        XCTAssertEqual(replay.workout?.id, first.workout?.id)
    }
    func testProbeNeverStartsAndExpiryPreventsLateExecution() throws {
        let plan = try XCTUnwrap(PlanImporter.importText(PlanContract.exampleJSON).plan)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let intent = RemoteWorkoutStartIntent(syncGeneration: "generation", planID: plan.id, planRevisionID: "revision",
            prescriptionID: try XCTUnwrap(plan.days.flatMap(\.sessions).first).id, requestedAt: now)
        let pending = resolve(intent, allowStart: false, plan: plan, now: now.addingTimeInterval(10))
        XCTAssertEqual(pending.status, .pending); XCTAssertNil(pending.workout)
        let expired = resolve(intent, allowStart: false, plan: plan, now: now.addingTimeInterval(61))
        XCTAssertEqual(expired.status, .rejected)
        let late = resolve(intent, previous: expired, plan: plan, now: now.addingTimeInterval(62))
        XCTAssertEqual(late, expired); XCTAssertNil(late.workout)
    }
    func testDifferentIntentForSameScheduleFindsExistingOwnerWorkout() throws {
        let plan = try XCTUnwrap(PlanImporter.importText(PlanContract.exampleJSON).plan)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let prescriptionID = try XCTUnwrap(plan.days.flatMap(\.sessions).first).id
        let firstIntent = RemoteWorkoutStartIntent(syncGeneration: "generation", planID: plan.id, planRevisionID: "revision",
            prescriptionID: prescriptionID, scheduledSessionID: "today-session", scheduledDay: .init(instant: now, timeZone: .current), requestedAt: now)
        let first = resolve(firstIntent, plan: plan, now: now)
        let secondIntent = RemoteWorkoutStartIntent(syncGeneration: "generation", planID: plan.id, planRevisionID: "revision",
            prescriptionID: prescriptionID, scheduledSessionID: "today-session", scheduledDay: .init(instant: now, timeZone: .current), requestedAt: now)
        let second = resolve(secondIntent, plan: plan, workouts: [try XCTUnwrap(first.workout)], now: now)
        XCTAssertEqual(second.status, .existing)
        XCTAssertEqual(second.workout?.id, first.workout?.id)
        let other = RemoteWorkoutStartIntent(syncGeneration: "generation", planID: plan.id, planRevisionID: "revision",
            prescriptionID: prescriptionID, scheduledSessionID: "different-session", scheduledDay: .init(instant: now, timeZone: .current), requestedAt: now)
        XCTAssertEqual(resolve(other, plan: plan, workouts: [try XCTUnwrap(first.workout)], now: now).status, .rejected)
    }
    func testReusedIdentityAndOldGenerationCannotStart() throws {
        let plan = try XCTUnwrap(PlanImporter.importText(PlanContract.exampleJSON).plan)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let intent = RemoteWorkoutStartIntent(syncGeneration: "generation", planID: plan.id, planRevisionID: "revision",
            prescriptionID: try XCTUnwrap(plan.days.flatMap(\.sessions).first).id, requestedAt: now)
        let accepted = resolve(intent, plan: plan, now: now)
        let changed = RemoteWorkoutStartIntent(id: intent.id, syncGeneration: "generation", planID: plan.id, planRevisionID: "revision",
            prescriptionID: intent.prescriptionID, requestedAt: now, recordWithHealth: true)
        XCTAssertEqual(resolve(changed, previous: accepted, plan: plan, now: now).status, .rejected)
        let old = RemoteWorkoutStartResolver.resolve(intent, previous: nil, allowStart: true, plan: plan,
            planRevisionID: "revision", syncGeneration: "new-generation", ownerDeviceID: "watch", workouts: [], now: now)
        XCTAssertEqual(old.status, .rejected); XCTAssertNil(old.workout)
    }
    func testCompetingProposalRetainsAcceptedAndProposedValuesAcrossTransport() throws {
        let exercise = PlanExercise(instanceId: "squat", exerciseId: "squat", name: "Squat", measurement: .weightReps,
                                    target: .init(sets: 1, restSeconds: 60, reps: .init(min: 8, max: 12)))
        let prescription = PlanSession(id: "session", name: "Strength", kind: "strength", estimatedMinutes: 30, exercises: [exercise])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let original = try WorkoutSession.start(prescription: prescription, planID: "plan", planRevisionID: "revision",
            ownerDeviceID: "watch", at: now, timeZoneIdentifier: "UTC", syncGeneration: "generation")
        let setID = try XCTUnwrap(original.exercises.first?.sets.first?.id)
        let ownerEdit = WorkoutOperation(session: original,
            command: .updateSet(setID: setID, values: .init(reps: 8, load: .init(value: 20, unit: .kg))), at: now)
        let accepted = WorkoutReducer.apply(ownerEdit, to: original, at: now).session
        let proposal = WorkoutOperation(session: original,
            command: .updateSet(setID: setID, values: .init(reps: 12, load: .init(value: 25, unit: .kg))),
            originDeviceID: "phone", at: now)
        let reduction = WorkoutReducer.apply(proposal, to: accepted, at: now)
        XCTAssertEqual(reduction.status, .conflict)
        let result = WorkoutProposalResult(operation: proposal, status: reduction.status, workout: reduction.session, issues: reduction.issues)
        let restored = try JSONDecoder().decode(WorkoutProposalResult.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(restored.operation, proposal)
        XCTAssertEqual(restored.workout?.exercises.first?.sets.first?.actual.reps, 8)
        XCTAssertEqual(restored.workout?.conflicts.first?.operation, proposal)
        XCTAssertEqual(restored.workout?.conflicts.first?.acceptedSets.first?.actual.load?.value, 20)
        XCTAssertEqual(WorkoutSnapshotMerge.classify(incoming: reduction.session, existing: accepted), .auditExtension)
        XCTAssertEqual(WorkoutSnapshotMerge.classify(incoming: accepted, existing: reduction.session), .staleAudit)
        XCTAssertEqual(WorkoutSnapshotMerge.classify(incoming: accepted, existing: original), .newer)
        XCTAssertEqual(WorkoutSnapshotMerge.classify(incoming: original, existing: reduction.session), .older)
    }
    func testAuditMergeRejectsEqualRevisionActualChangesAndDeletedHistory() throws {
        let original = try snapshot()
        let setID = try XCTUnwrap(original.exercises.first?.sets.first?.id)
        let rejected = WorkoutReducer.apply(WorkoutOperation(session: original,
            command: .extendRest(seconds: 30), at: original.startedAt), to: original, at: original.startedAt).session
        XCTAssertEqual(rejected.revision, original.revision)
        XCTAssertEqual(WorkoutSnapshotMerge.classify(incoming: rejected, existing: original), .auditExtension)
        var changed = rejected
        changed.exercises[0].sets[0].actual.reps = 42
        XCTAssertEqual(WorkoutSnapshotMerge.classify(incoming: changed, existing: original), .conflict)
        let accepted = WorkoutReducer.apply(WorkoutOperation(session: rejected,
            command: .skipSet(setID: setID, reason: nil), at: original.startedAt), to: rejected, at: original.startedAt).session
        XCTAssertEqual(WorkoutSnapshotMerge.classify(incoming: accepted, existing: rejected), .newer)
        var missingAudit = accepted; missingAudit.operationReceipts.removeFirst()
        XCTAssertEqual(WorkoutSnapshotMerge.classify(incoming: missingAudit, existing: rejected), .conflict)
    }
    func testBufferedSnapshotMayOnlyRemoveExactOperationAfterOwnerReceipt() throws {
        let original = try snapshot()
        let future = WorkoutOperation(sessionID: original.id, originDeviceID: "phone", syncGeneration: original.syncGeneration,
            expectedRevision: 1, command: .pause, createdAt: original.startedAt)
        let buffered = WorkoutReducer.apply(future, to: original, at: original.startedAt).session
        XCTAssertEqual(WorkoutSnapshotMerge.classify(incoming: buffered, existing: original), .auditExtension)
        let advanced = WorkoutReducer.apply(WorkoutOperation(session: buffered, command: .pause, at: original.startedAt),
            to: buffered, at: original.startedAt).session
        XCTAssertTrue(advanced.pendingOperations.isEmpty)
        XCTAssertTrue(advanced.operationReceipts.contains { $0.operation == future })
        XCTAssertEqual(WorkoutSnapshotMerge.classify(incoming: advanced, existing: buffered), .newer)
        var dropped = advanced
        dropped.operationReceipts.removeAll { $0.operation == future }
        XCTAssertEqual(WorkoutSnapshotMerge.classify(incoming: dropped, existing: buffered), .conflict)
    }
    func testParallelAuditBranchesCannotSilentlyOverwriteEachOther() throws {
        let original = try snapshot()
        let first = WorkoutReducer.apply(WorkoutOperation(session: original, command: .extendRest(seconds: 30),
            at: original.startedAt), to: original, at: original.startedAt).session
        let second = WorkoutReducer.apply(WorkoutOperation(session: original, command: .extendRest(seconds: 60),
            at: original.startedAt), to: original, at: original.startedAt).session
        XCTAssertEqual(WorkoutSnapshotMerge.classify(incoming: first, existing: second), .conflict)
        XCTAssertEqual(WorkoutSnapshotMerge.classify(incoming: first, existing: first), .identical)
    }
    func testProposalResultNeedsExactOwnerReceiptBeforeConfirmingChange() throws {
        let original = try snapshot()
        let operation = WorkoutOperation(session: original, command: .pause, originDeviceID: "phone", at: original.startedAt)
        let accepted = WorkoutReducer.apply(operation, to: original, at: original.startedAt).session
        XCTAssertTrue(RemoteWorkoutResultValidator.validate(WorkoutProposalResult(operation: operation,
            status: .applied, workout: accepted, issues: [])).isEmpty)
        for unsupported in [nil, original, try snapshot()] {
            XCTAssertFalse(RemoteWorkoutResultValidator.validate(WorkoutProposalResult(operation: operation,
                status: .applied, workout: unsupported, issues: [])).isEmpty)
        }
        XCTAssertFalse(RemoteWorkoutResultValidator.validate(WorkoutProposalResult(operation: operation,
            status: .conflict, workout: accepted, issues: [])).isEmpty)
        XCTAssertTrue(RemoteWorkoutResultValidator.validate(WorkoutProposalResult(operation: operation,
            status: .rejected, workout: nil, issues: [.init(code: "ownerUnavailable", message: "Owner unavailable")])).isEmpty)
    }
    func testStartResultMustMatchRequestedPrescriptionAndSchedule() throws {
        let plan = try XCTUnwrap(PlanImporter.importText(PlanContract.exampleJSON).plan)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let intent = RemoteWorkoutStartIntent(syncGeneration: "generation", planID: plan.id, planRevisionID: "revision",
            prescriptionID: try XCTUnwrap(plan.days.flatMap(\.sessions).first).id, scheduledSessionID: "today", scheduledDay: .init(instant: now, timeZone: .current), requestedAt: now)
        let started = resolve(intent, plan: plan, now: now)
        XCTAssertTrue(RemoteWorkoutResultValidator.validate(started).isEmpty)
        XCTAssertFalse(RemoteWorkoutResultValidator.validate(RemoteWorkoutStartResult(intent: intent,
            status: .started, workout: try snapshot(), message: "Started", resolvedAt: now)).isEmpty)
        XCTAssertFalse(RemoteWorkoutResultValidator.validate(RemoteWorkoutStartResult(intent: intent,
            status: .existing, message: "Started", resolvedAt: now)).isEmpty)
        XCTAssertFalse(RemoteWorkoutResultValidator.validate(RemoteWorkoutStartResult(intent: intent,
            status: .pending, workout: started.workout, message: "Pending", resolvedAt: now)).isEmpty)
    }
    private func snapshot() throws -> WorkoutSession {
        let plan = try XCTUnwrap(PlanImporter.importText(PlanContract.exampleJSON).plan)
        return try WorkoutSession.start(prescription: XCTUnwrap(plan.days.flatMap(\.sessions).first),
            planID: plan.id, planRevisionID: "revision", ownerDeviceID: "watch",
            at: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "UTC", syncGeneration: "generation")
    }
    private func resolve(_ intent: RemoteWorkoutStartIntent, previous: RemoteWorkoutStartResult? = nil,
                         allowStart: Bool = true, plan: WeeklyPlan, workouts: [WorkoutSession] = [], now: Date) -> RemoteWorkoutStartResult {
        RemoteWorkoutStartResolver.resolve(intent, previous: previous, allowStart: allowStart, plan: plan,
            planRevisionID: "revision", syncGeneration: "generation", ownerDeviceID: "watch", workouts: workouts,
            now: now, timeZoneIdentifier: "UTC")
    }
}
