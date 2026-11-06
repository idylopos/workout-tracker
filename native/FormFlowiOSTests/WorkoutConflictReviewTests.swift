import XCTest
import SwiftData
import FormFlowCore
@testable import FormFlowiOS

@MainActor
final class WorkoutConflictReviewTests: XCTestCase {
    func testKeepingAcceptedPreservesWorkoutAndRetainsDecision() throws {
        let fixture = try makeFixture()
        let review = WorkoutConflictReviewStore(context: ModelContext(fixture.container))
        try review.keepAccepted(workout: fixture.workout, conflict: fixture.conflict, reviewer: fixture.deviceID)
        XCTAssertEqual(try readWorkout(fixture.container), fixture.workout)
        let saved = try review.history(sessionID: fixture.workout.id)
        XCTAssertEqual(saved.map(\.choice), [.keptAccepted])
        XCTAssertEqual(saved.first?.originalOperation, fixture.conflict.operation)
        XCTAssertNil(saved.first?.replacementOperation)
    }

    func testReviewedProposalUsesNewIDAndLatestRevisionWithoutReloggingCompletedSet() throws {
        let fixture = try makeFixture()
        let store = try makeStore(fixture.container)
        let operation = try store.conflictReviews.prepareProposed(workout: fixture.workout,
            conflict: fixture.conflict, reviewer: fixture.deviceID)
        XCTAssertNotEqual(operation.id, fixture.conflict.operation.id)
        XCTAssertEqual(operation.expectedRevision, fixture.workout.revision)
        guard case .updateSet = operation.command else { return XCTFail("Completed work must be corrected, not completed again") }
        XCTAssertEqual(try readWorkout(fixture.container), fixture.workout)

        XCTAssertTrue(store.submitReviewedWorkoutOperation(operation))
        let saved = try readWorkout(fixture.container)
        XCTAssertEqual(saved.conflicts, fixture.workout.conflicts)
        XCTAssertEqual(saved.operationReceipts.last?.operation, operation)
        XCTAssertEqual(saved.operationReceipts.last?.status, .applied)
        XCTAssertEqual(saved.exercises.first?.sets.first?.completedAt, fixture.workout.exercises.first?.sets.first?.completedAt)
        XCTAssertEqual(saved.rest, fixture.workout.rest)
    }

    func testFailedReviewCommitDoesNotMarkReviewedOrChangeAcceptedValues() throws {
        let fixture = try makeFixture()
        let review = WorkoutConflictReviewStore(context: ModelContext(fixture.container)) { _ in
            throw NSError(domain: "ReviewDiskFailure", code: 1)
        }
        XCTAssertThrowsError(try review.prepareProposed(workout: fixture.workout,
            conflict: fixture.conflict, reviewer: fixture.deviceID))
        XCTAssertTrue(try review.history(sessionID: fixture.workout.id).isEmpty)
        XCTAssertThrowsError(try review.keepAccepted(workout: fixture.workout,
            conflict: fixture.conflict, reviewer: fixture.deviceID))
        XCTAssertTrue(try review.history(sessionID: fixture.workout.id).isEmpty)
        XCTAssertEqual(try readWorkout(fixture.container), fixture.workout)
    }

    func testFailedCorrectionSaveRetainsPreparedReviewWithoutClaimingApplied() throws {
        let fixture = try makeFixture()
        var failWrites = false
        let store = try AppStore(context: ModelContext(fixture.container), bridge: PlanBridge(isEnabled: false), healthEnabled: false) { context in
            if failWrites { throw NSError(domain: "ReviewDiskFailure", code: 1) }
            try context.save()
        }
        let operation = try store.conflictReviews.prepareProposed(workout: fixture.workout,
            conflict: fixture.conflict, reviewer: fixture.deviceID)
        failWrites = true
        XCTAssertFalse(store.submitReviewedWorkoutOperation(operation))
        XCTAssertEqual(store.workouts.first, fixture.workout)
        XCTAssertEqual(try readWorkout(fixture.container), fixture.workout)
        let review = try XCTUnwrap(store.conflictReviews.history(sessionID: fixture.workout.id).first)
        XCTAssertEqual(review.choice, .preparedProposal)
        XCTAssertEqual(review.replacementOperation, operation)
        XCTAssertFalse(store.workouts.flatMap(\.operationReceipts).contains { $0.operation == operation })
    }

    func testUnavailableWatchDoesNotTurnPreparedProposalIntoAcceptance() throws {
        let fixture = try makeFixture(owner: "recording-watch")
        let store = try makeStore(fixture.container)
        let operation = try store.conflictReviews.prepareProposed(workout: fixture.workout,
            conflict: fixture.conflict, reviewer: fixture.deviceID)
        XCTAssertFalse(store.submitReviewedWorkoutOperation(operation))
        XCTAssertEqual(try readWorkout(fixture.container), fixture.workout)
        XCTAssertEqual(try store.conflictReviews.history(sessionID: fixture.workout.id).first?.choice, .preparedProposal)
    }

    func testRepeatedRejectedOperationIsNeverReportedAsApplied() throws {
        let fixture = try makeFixture()
        let store = try makeStore(fixture.container)
        let setID = try XCTUnwrap(fixture.workout.exercises.first?.sets.first?.id)
        let invalid = WorkoutOperation(session: fixture.workout,
            command: .updateSet(setID: setID, values: .init(reps: -1, load: .init(value: 15, unit: .kg))),
            originDeviceID: fixture.deviceID, at: Date())
        XCTAssertFalse(store.submitReviewedWorkoutOperation(invalid))
        XCTAssertFalse(store.submitReviewedWorkoutOperation(invalid))
        XCTAssertEqual(store.workouts.first?.operationReceipts.last?.status, .rejected)
        XCTAssertEqual(store.workouts.first?.exercises.first?.sets.first?.actual, fixture.workout.exercises.first?.sets.first?.actual)
    }

    func testStaleReviewMustBeComparedAgainBeforePreparingOrSubmitting() throws {
        let fixture = try makeFixture()
        let store = try makeStore(fixture.container)
        let prepared = try store.conflictReviews.prepareProposed(workout: fixture.workout,
            conflict: fixture.conflict, reviewer: fixture.deviceID)
        let setID = try XCTUnwrap(fixture.workout.exercises.first?.sets.first?.id)
        XCTAssertTrue(store.applyWorkoutCommand(.updateSet(setID: setID,
            values: .init(reps: 11, load: .init(value: 15, unit: .kg))), sessionID: fixture.workout.id))
        XCTAssertThrowsError(try store.conflictReviews.prepareProposed(workout: fixture.workout,
            conflict: fixture.conflict, reviewer: fixture.deviceID))
        XCTAssertFalse(store.submitReviewedWorkoutOperation(prepared))
        XCTAssertEqual(try store.conflictReviews.history(sessionID: fixture.workout.id).count, 1)
        XCTAssertFalse(store.workouts.flatMap(\.operationReceipts).contains { $0.operation == prepared })
    }

    func testBufferedPresentationUsesLaterExactOwnerReceipt() throws {
        let fixture = try makeFixture()
        let workout = fixture.workout
        let setID = try XCTUnwrap(workout.exercises.first?.sets.first?.id)
        let date = workout.lastAppliedAt.addingTimeInterval(1)
        let queued = WorkoutOperation(sessionID: workout.id, originDeviceID: "companion",
            syncGeneration: workout.syncGeneration, expectedRevision: workout.revision + 1,
            command: .updateSet(setID: setID, values: .init(reps: 9, load: .init(value: 15, unit: .kg))), createdAt: date)
        let buffered = WorkoutReducer.apply(queued, to: workout, at: date)
        let result = WorkoutProposalResult(operation: queued, status: .buffered, workout: buffered.session, issues: buffered.issues)
        XCTAssertEqual(WorkoutProposalPresentation.status(result, in: buffered.session), .buffered)
        let duplicate = WorkoutProposalResult(operation: queued, status: .duplicate, workout: buffered.session, issues: [])
        XCTAssertEqual(WorkoutProposalPresentation.status(duplicate, in: buffered.session), .buffered)
        let preceding = WorkoutOperation(session: buffered.session,
            command: .updateSet(setID: setID, values: .init(reps: 10, load: .init(value: 15, unit: .kg))), at: date)
        let drained = WorkoutReducer.apply(preceding, to: buffered.session, at: date)
        XCTAssertEqual(WorkoutProposalPresentation.status(result, in: drained.session), .applied)
    }

    func testExplicitLatestDraftUsesAcceptedActualsAndFreshOperationIdentity() throws {
        let fixture = try makeFixture()
        let set = try XCTUnwrap(fixture.workout.exercises.first?.sets.first)
        let first = try RemoteSetDraft.usingLatestAcceptedValues(workout: fixture.workout, setID: set.id)
        let second = try RemoteSetDraft.usingLatestAcceptedValues(workout: fixture.workout, setID: set.id)
        XCTAssertNotEqual(first.operationID, second.operationID)
        XCTAssertEqual(first.baseRevision, fixture.workout.revision)
        XCTAssertEqual(first.values, set.actual)
        XCTAssertFalse(first.markComplete)
    }

    private struct Fixture {
        let container: ModelContainer
        let workout: WorkoutSession
        let conflict: WorkoutConflict
        let deviceID: String
    }

    private func makeFixture(owner: String? = nil) throws -> Fixture {
        let schema = WorkspaceSchema.current
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let identity = RuntimeIdentityRecord()
        let plan = try XCTUnwrap(PlanImporter.importText(PlanContract.exampleJSON).plan)
        let session = try XCTUnwrap(plan.days.first?.sessions.first)
        let date = Date().addingTimeInterval(-10)
        let initial = try WorkoutSession.start(prescription: session, planID: plan.id,
            planRevisionID: "review-plan", ownerDeviceID: owner ?? identity.deviceID,
            at: date, timeZoneIdentifier: "Asia/Singapore", syncGeneration: identity.syncGeneration)
        let setID = try XCTUnwrap(initial.exercises.first?.sets.first?.id)
        let accepted = WorkoutOperation(session: initial,
            command: .logSet(setID: setID, values: .init(reps: 10, load: .init(value: 15, unit: .kg))),
            at: date.addingTimeInterval(1))
        let afterAccepted = WorkoutReducer.apply(accepted, to: initial, at: date.addingTimeInterval(1)).session
        let proposed = WorkoutOperation(session: initial,
            command: .logSet(setID: setID, values: .init(reps: 8, load: .init(value: 20, unit: .kg))),
            originDeviceID: "companion", at: date.addingTimeInterval(2))
        let conflicted = WorkoutReducer.apply(proposed, to: afterAccepted, at: date.addingTimeInterval(2)).session
        XCTAssertTrue(WorkoutSessionValidator.validate(conflicted).isEmpty)
        let context = ModelContext(container)
        context.insert(identity)
        context.insert(WorkoutRecord(id: conflicted.id, payload: try JSONEncoder().encode(conflicted)))
        try context.save()
        return Fixture(container: container, workout: conflicted, conflict: try XCTUnwrap(conflicted.conflicts.first), deviceID: identity.deviceID)
    }

    private func makeStore(_ container: ModelContainer) throws -> AppStore {
        try AppStore(context: ModelContext(container), bridge: PlanBridge(isEnabled: false), healthEnabled: false)
    }

    private func readWorkout(_ container: ModelContainer) throws -> WorkoutSession {
        let row = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<WorkoutRecord>()).first)
        return try JSONDecoder().decode(WorkoutSession.self, from: row.payload)
    }
}
