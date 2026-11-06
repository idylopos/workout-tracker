import XCTest
import SwiftData
import FormFlowCore
@testable import FormFlowiOS

@MainActor
final class WorkoutStoreTests: XCTestCase {
    func testDraftsCompletedSetsAndRestSurviveReopening() throws {
        let container = try makeContainer()
        let store = try makeStore(container)
        let session = try activateSample(store)
        let start = Date()
        XCTAssertTrue(store.startWorkout(session, scheduledID: try occurrenceID(store, session: session), at: start))
        let workout = try XCTUnwrap(store.currentWorkout)
        let set = try XCTUnwrap(workout.exercises.first?.sets.first)
        XCTAssertTrue(set.actual.isEmpty)
        let actual = WorkoutSetValues(reps: 8, load: PlanQuantity(value: 12, unit: .kg), rir: 2)
        XCTAssertTrue(store.applyWorkoutCommand(.updateSet(setID: set.id, values: actual), sessionID: workout.id, at: start.addingTimeInterval(1)))
        XCTAssertEqual(store.currentWorkout?.completedSetCount, 0)
        let restored = try makeStore(container)
        XCTAssertEqual(restored.currentWorkout?.exercises.first?.sets.first?.actual, actual)
        XCTAssertTrue(restored.applyWorkoutCommand(.logSet(setID: set.id, values: actual), sessionID: workout.id, at: start.addingTimeInterval(10)))
        let reopened = try makeStore(container)
        XCTAssertEqual(reopened.currentWorkout?.completedSetCount, 1)
        XCTAssertEqual(reopened.currentWorkout?.rest, restored.currentWorkout?.rest)
        XCTAssertEqual(reopened.deviceID, store.deviceID)
        XCTAssertEqual(reopened.syncGeneration, store.syncGeneration)
    }

    func testExplicitSkipReasonSurvivesRelaunchAndUndoPreservesUnperformedDraft() throws {
        let container = try makeContainer(), store = try makeStore(container)
        let session = try activateSample(store)
        XCTAssertTrue(store.startWorkout(session))
        let workout = try XCTUnwrap(store.currentWorkout), set = workout.exercises[0].sets[0]
        let actual = WorkoutSetValues(reps: 8, load: .init(value: 12, unit: .kg))
        XCTAssertTrue(store.applyWorkoutCommand(.updateSet(setID: set.id, values: actual), sessionID: workout.id))
        XCTAssertTrue(store.applyWorkoutCommand(.skipSet(setID: set.id, reason: "Equipment was occupied"), sessionID: workout.id))
        let reopened = try makeStore(container)
        XCTAssertEqual(reopened.currentWorkout?.exercises[0].sets[0].skipReason, "Equipment was occupied")
        XCTAssertEqual(reopened.currentWorkout?.exercises[0].sets[0].status, .skipped)
        XCTAssertEqual(reopened.currentWorkout?.completedSetCount, 0)
        XCTAssertNil(reopened.currentWorkout?.rest)
        XCTAssertTrue(reopened.applyWorkoutCommand(.undoSet(setID: set.id), sessionID: workout.id))
        XCTAssertEqual(reopened.currentWorkout?.exercises[0].sets[0].actual, actual)
        XCTAssertEqual(reopened.currentWorkout?.exercises[0].sets[0].status, .planned)
        XCTAssertNil(reopened.currentWorkout?.exercises[0].sets[0].skipReason)
        XCTAssertTrue(reopened.applyWorkoutCommand(.skipSet(setID: set.id, reason: nil), sessionID: workout.id))
        XCTAssertNil(reopened.currentWorkout?.exercises[0].sets[0].skipReason, "A missing reason must not become fabricated user text.")
    }

    func testRepeatedStartResumesSameWorkout() throws {
        let container = try makeContainer()
        let store = try makeStore(container)
        let session = try activateSample(store)
        let occurrence = try occurrenceID(store, session: session)
        XCTAssertTrue(store.startWorkout(session, scheduledID: occurrence))
        let id = store.currentWorkout?.id
        XCTAssertTrue(store.startWorkout(session, scheduledID: occurrence))
        XCTAssertEqual(store.currentWorkout?.id, id)
        XCTAssertEqual(store.workouts.count, 1)
    }

    func testStaleOccurrenceDateCannotStartAfterReschedule() throws {
        let container = try makeContainer()
        let store = try makeStore(container)
        let session = try activateSample(store)
        let plan = try XCTUnwrap(store.activePlan), activation = try XCTUnwrap(store.activationDate)
        let id = try occurrenceID(store, session: session)
        let original = try XCTUnwrap(ScheduleExceptionSchedule.resolve(occurrenceID: id, plan: plan,
            activationDate: activation))
        let movedDate = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: original.scheduled.date))
        XCTAssertTrue(store.scheduleExceptions.save(original, action: .rescheduled,
            destination: LocalTrainingDay(instant: movedDate, timeZone: .current), note: "One-off change",
            plan: plan, planRevisionID: try XCTUnwrap(store.activePlanRevisionID), activationDate: activation,
            workouts: store.workouts, pendingWatchOccurrenceIDs: []))
        XCTAssertFalse(store.startWorkout(session, scheduledID: id, scheduledDate: original.scheduled.date))
        XCTAssertTrue(store.workouts.isEmpty)
        XCTAssertTrue(store.startWorkout(session, scheduledID: id, scheduledDate: movedDate))
        XCTAssertEqual(store.currentWorkout?.scheduledSessionID, id)
    }

    func testPlanRevisionDoesNotChangeActiveWorkoutPrescription() throws {
        let container = try makeContainer()
        let store = try makeStore(container)
        let session = try activateSample(store)
        XCTAssertTrue(store.startWorkout(session))
        let original = try XCTUnwrap(store.currentWorkout)
        var revised = try XCTUnwrap(store.activePlan)
        revised.days[0].sessions[0].exercises[0].target.reps = RepRange(min: 3, max: 5)
        XCTAssertTrue(store.replaceImportedPlan(revised))
        store.activatePlan(revised, startDate: Date(), decision: .init(review: try store.reviewPlanImport(revised), action: .newRevision))
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.currentWorkout?.prescription, original.prescription)
        XCTAssertEqual(store.currentWorkout?.planRevisionID, original.planRevisionID)
    }

    func testPartialFinishRetainsUnperformedAndCompletedWork() throws {
        let container = try makeContainer()
        let store = try makeStore(container)
        let session = try activateSample(store)
        let date = Date()
        XCTAssertTrue(store.startWorkout(session, at: date))
        let workout = try XCTUnwrap(store.currentWorkout)
        let setID = try XCTUnwrap(workout.exercises.first?.sets.first?.id)
        let values = WorkoutSetValues(reps: 8, load: PlanQuantity(value: 12, unit: .kg))
        XCTAssertTrue(store.applyWorkoutCommand(.logSet(setID: setID, values: values), sessionID: workout.id, at: date.addingTimeInterval(1)))
        XCTAssertFalse(store.applyWorkoutCommand(.finish(allowPartial: false), sessionID: workout.id, at: date.addingTimeInterval(2)))
        XCTAssertTrue(store.applyWorkoutCommand(.finish(allowPartial: true), sessionID: workout.id, at: date.addingTimeInterval(3)))
        let saved = try XCTUnwrap(try makeStore(container).workouts.first)
        XCTAssertTrue(saved.isPartial)
        XCTAssertEqual(saved.completedSetCount, 1)
        XCTAssertTrue(saved.exercises.flatMap(\.sets).contains { $0.status == .unperformed })
        XCTAssertNil(store.currentWorkout)
    }

    func testFailedSetSaveDoesNotAcknowledgeCompletionAndCanRetry() throws {
        let container = try makeContainer()
        var failWrites = false
        let store = try AppStore(context: ModelContext(container), bridge: PlanBridge(isEnabled: false), healthEnabled: false) { context in
            if failWrites { throw NSError(domain: "StorageTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Simulated full disk"]) }
            try context.save()
        }
        let session = try activateSample(store)
        let date = Date()
        XCTAssertTrue(store.startWorkout(session, at: date))
        let workout = try XCTUnwrap(store.currentWorkout)
        let setID = try XCTUnwrap(workout.exercises.first?.sets.first?.id)
        failWrites = true
        XCTAssertFalse(store.applyWorkoutCommand(.logSet(setID: setID, values: WorkoutSetValues(reps: 8, load: PlanQuantity(value: 10, unit: .kg))), sessionID: workout.id, at: date.addingTimeInterval(1)))
        XCTAssertEqual(store.currentWorkout?.completedSetCount, 0)
        XCTAssertEqual(try makeStore(container).currentWorkout?.completedSetCount, 0)
        XCTAssertNotNil(store.errorMessage)
        failWrites = false
        store.retryLastSave()
        XCTAssertEqual(store.currentWorkout?.completedSetCount, 1)
        XCTAssertEqual(try makeStore(container).currentWorkout?.completedSetCount, 1)
    }

    func testResetRotatesGenerationAndRejectsDisconnectedWatchHistory() throws {
        let container = try makeContainer()
        let store = try makeStore(container)
        let session = try activateSample(store)
        let originalGeneration = store.syncGeneration
        let watch = try WorkoutSession.start(prescription: session, planID: store.activePlan!.id,
            planRevisionID: "watch-plan", ownerDeviceID: "watch-device", at: Date(),
            timeZoneIdentifier: "Asia/Singapore", syncGeneration: originalGeneration)
        XCTAssertTrue(store.receiveWatchWorkout(watch))
        XCTAssertTrue(store.resetWorkspace())
        XCTAssertNotEqual(store.syncGeneration, originalGeneration)
        XCTAssertTrue(store.workouts.isEmpty)
        XCTAssertNil(store.activePlan)
        XCTAssertFalse(store.receiveWatchWorkout(watch))
        let reopened = try makeStore(container)
        XCTAssertEqual(reopened.syncGeneration, store.syncGeneration)
        XCTAssertTrue(reopened.workouts.isEmpty)
    }

    func testFailedResetPreservesPlanWorkoutsAndGeneration() throws {
        let container = try makeContainer()
        var failWrites = false
        let store = try AppStore(context: ModelContext(container), bridge: PlanBridge(isEnabled: false), healthEnabled: false) { context in
            if failWrites { throw NSError(domain: "StorageTest", code: 1) }
            try context.save()
        }
        let session = try activateSample(store)
        XCTAssertTrue(store.startWorkout(session))
        let original = try XCTUnwrap(store.currentWorkout)
        let generation = store.syncGeneration
        failWrites = true
        XCTAssertFalse(store.resetWorkspace())
        XCTAssertEqual(store.currentWorkout, original)
        XCTAssertEqual(store.syncGeneration, generation)
        let reopened = try makeStore(container)
        XCTAssertEqual(reopened.currentWorkout, original)
        XCTAssertEqual(reopened.syncGeneration, generation)
        XCTAssertNotNil(reopened.activePlan)
    }

    private func occurrenceID(_ store: AppStore, session: PlanSession) throws -> String {
        let plan = try XCTUnwrap(store.activePlan)
        let date = try XCTUnwrap(store.activationDate)
        return try XCTUnwrap(PlanSchedule.upcoming(plan: plan, activationDate: date, from: date,
            limit: 30).first { $0.session.id == session.id }?.id)
    }

    private func activateSample(_ store: AppStore) throws -> PlanSession {
        store.loadExample()
        let plan = try XCTUnwrap(store.importResult?.plan)
        store.activatePlan(plan, startDate: Date())
        XCTAssertNil(store.errorMessage)
        return try XCTUnwrap(plan.days.first?.sessions.first)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = WorkspaceSchema.current
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    }

    private func makeStore(_ container: ModelContainer) throws -> AppStore {
        try AppStore(context: ModelContext(container), bridge: PlanBridge(isEnabled: false), healthEnabled: false)
    }
}
