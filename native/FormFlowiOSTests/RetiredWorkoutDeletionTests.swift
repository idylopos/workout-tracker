import XCTest
import SwiftData
import FormFlowCore
@testable import FormFlowiOS

@MainActor
final class RetiredWorkoutDeletionTests: XCTestCase {
    func testDeletingPlansRetainsUnavailableWatchBytesWithoutBlockingLaterDeletionOrScheduledStart() throws {
        let schema = WorkspaceSchema.current
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let store = try AppStore(context: context, bridge: PlanBridge(isEnabled: false), healthEnabled: false)
        let activation = Calendar.current.startOfDay(for: Date())
        store.loadExample()
        let plan = try XCTUnwrap(store.importResult?.plan)
        XCTAssertTrue(store.activatePlan(plan, startDate: activation))
        let occurrence = try XCTUnwrap(store.upcomingSessions(from: activation, limit: 1).first)
        var remote = try WorkoutSession.start(prescription: occurrence.session, planID: plan.id,
            planRevisionID: XCTUnwrap(store.activePlanRevisionID), scheduledSessionID: occurrence.id,
            ownerDeviceID: "unavailable-recording-watch", at: Date().addingTimeInterval(-120),
            timeZoneIdentifier: "UTC", syncGeneration: store.syncGeneration)
        let log = WorkoutOperation(session: remote,
            command: .logSet(setID: remote.exercises[0].sets[0].id, values: .init(reps: 8, load: .init(value: 20, unit: .kg))),
            at: remote.startedAt.addingTimeInterval(30))
        let reduction = WorkoutReducer.apply(log, to: remote, at: log.createdAt)
        XCTAssertEqual(reduction.status, .applied)
        remote = reduction.session
        XCTAssertTrue(store.receiveWatchWorkout(remote))
        try store.workoutAnnotations.markOwnerUnavailable(workout: remote, reviewer: store.deviceID)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutRecord>()).first { $0.id == remote.id })
        let originalBytes = row.payload, originalGeneration = store.syncGeneration

        let preview = try store.previewDeletion(selection: [.plans])
        XCTAssertTrue(store.deleteSelectedData(preview), store.errorMessage ?? "Deletion failed")
        XCTAssertNotEqual(store.syncGeneration, originalGeneration)
        XCTAssertTrue(store.isRetiredIncomplete(remote))
        XCTAssertNil(store.currentWorkout)
        XCTAssertNil(store.activePlan)
        XCTAssertFalse(store.workoutsForScheduling.contains { $0.id == remote.id })
        XCTAssertEqual(store.workouts.first { $0.id == remote.id }, remote)
        XCTAssertEqual(row.payload, originalBytes)
        XCTAssertFalse(store.receiveWatchWorkout(remote), "Retired Watch deliveries cannot enter the new workspace")

        let retiredGeneration = store.syncGeneration
        let secondPreview = try store.previewDeletion(selection: [.profile])
        XCTAssertTrue(store.deleteSelectedData(secondPreview), store.errorMessage ?? "Second deletion was blocked")
        XCTAssertEqual(store.syncGeneration, retiredGeneration)
        XCTAssertEqual(row.payload, originalBytes)
        store.loadExample()
        let restoredPlan = try XCTUnwrap(store.importResult?.plan)
        XCTAssertTrue(store.activatePlan(restoredPlan, startDate: activation))
        let currentOccurrence = try XCTUnwrap(store.upcomingSessions(from: activation, limit: 1).first)
        XCTAssertEqual(currentOccurrence.id, occurrence.id)
        XCTAssertTrue(store.startWorkout(currentOccurrence.session, scheduledID: currentOccurrence.id,
                                         scheduledDate: currentOccurrence.date), store.errorMessage ?? "New start was blocked")
        let current = try XCTUnwrap(store.currentWorkout)
        XCTAssertNotEqual(current.id, remote.id)
        XCTAssertEqual(current.ownerDeviceID, store.deviceID)
        XCTAssertEqual(current.syncGeneration, retiredGeneration)
        XCTAssertEqual(row.payload, originalBytes)
        XCTAssertEqual(store.workouts.first { $0.id == remote.id }, remote)
    }

    func testRetiredIncompleteCannotBeEditedWhileTerminalHistoricalCorrectionStillWorks() throws {
        let schema = WorkspaceSchema.current
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let identity = RuntimeIdentityRecord()
        context.insert(identity)
        let plan = try XCTUnwrap(PlanImporter.importText(PlanContract.exampleJSON).plan)
        let prescription = try XCTUnwrap(plan.days.flatMap(\.sessions).first)
        let start = Date().addingTimeInterval(-300)
        func session() throws -> WorkoutSession {
            try WorkoutSession.start(prescription: prescription, planID: plan.id, planRevisionID: "historical-revision",
                ownerDeviceID: identity.deviceID, at: start, timeZoneIdentifier: "UTC", syncGeneration: "retired-generation")
        }
        let incomplete = try session()
        var terminal = try session()
        let log = WorkoutOperation(session: terminal,
            command: .logSet(setID: terminal.exercises[0].sets[0].id, values: .init(reps: 8, load: .init(value: 20, unit: .kg))),
            at: start.addingTimeInterval(30))
        terminal = WorkoutReducer.apply(log, to: terminal, at: log.createdAt).session
        let finish = WorkoutOperation(session: terminal, command: .finish(allowPartial: true), at: start.addingTimeInterval(60))
        terminal = WorkoutReducer.apply(finish, to: terminal, at: finish.createdAt).session
        for workout in [incomplete, terminal] { context.insert(WorkoutRecord(id: workout.id, payload: try JSONEncoder().encode(workout))) }
        try context.save()
        let store = try AppStore(context: context, bridge: PlanBridge(isEnabled: false), healthEnabled: false)
        XCTAssertNil(store.currentWorkout)
        XCTAssertTrue(store.isRetiredIncomplete(incomplete))
        XCTAssertFalse(store.isRetiredIncomplete(terminal))
        XCTAssertFalse(store.applyWorkoutCommand(.pause, sessionID: incomplete.id))
        XCTAssertEqual(store.workouts.first { $0.id == incomplete.id }, incomplete)
        XCTAssertTrue(store.applyWorkoutCommand(.updateSet(setID: terminal.exercises[0].sets[0].id,
            values: .init(reps: 9, load: .init(value: 20, unit: .kg))), sessionID: terminal.id))
        XCTAssertEqual(store.workouts.first { $0.id == terminal.id }?.endedAt, terminal.endedAt)
        XCTAssertEqual(store.workoutsForScheduling.map(\.id), [terminal.id])
    }
}
