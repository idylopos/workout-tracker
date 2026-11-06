import XCTest
import SwiftData
import FormFlowCore
@testable import FormFlowiOS

@MainActor
final class WorkoutAnnotationTests: XCTestCase {
    func testDuplicateExclusionIsReversibleAndNeverMutatesWorkoutAudit() throws {
        let fixture = try makeFixture()
        let annotations = WorkoutAnnotationStore(context: ModelContext(fixture.container))
        try annotations.markDuplicate(workout: fixture.copy, duplicateOf: fixture.original, reviewer: fixture.deviceID)
        XCTAssertTrue(annotations.isExcludedDuplicate(fixture.copy))
        XCTAssertEqual(annotations.includedWorkouts([fixture.original, fixture.copy]), [fixture.original])
        XCTAssertEqual(try workouts(fixture.container).first { $0.id == fixture.copy.id }, fixture.copy)
        try annotations.restoreIncluded(workout: fixture.copy, reviewer: fixture.deviceID)
        XCTAssertFalse(annotations.isExcludedDuplicate(fixture.copy))
        XCTAssertEqual(try annotations.history(workout: fixture.copy).map(\.decision), [.duplicate, .included])
    }

    func testActiveSelfAndChainedDuplicatesAreRejected() throws {
        let fixture = try makeFixture()
        let annotations = WorkoutAnnotationStore(context: ModelContext(fixture.container))
        XCTAssertThrowsError(try annotations.markDuplicate(workout: fixture.remote, duplicateOf: fixture.original, reviewer: fixture.deviceID))
        XCTAssertThrowsError(try annotations.markDuplicate(workout: fixture.copy, duplicateOf: fixture.copy, reviewer: fixture.deviceID))
        try annotations.markDuplicate(workout: fixture.copy, duplicateOf: fixture.original, reviewer: fixture.deviceID)
        XCTAssertThrowsError(try annotations.markDuplicate(workout: fixture.original, duplicateOf: fixture.copy, reviewer: fixture.deviceID))
        XCTAssertFalse(annotations.isExcludedDuplicate(fixture.original))
    }

    func testFailedAnnotationSaveDoesNotChangeInclusionOrInterruption() throws {
        let fixture = try makeFixture()
        let annotations = WorkoutAnnotationStore(context: ModelContext(fixture.container)) { _ in
            throw NSError(domain: "AnnotationDiskFailure", code: 1)
        }
        XCTAssertThrowsError(try annotations.markDuplicate(workout: fixture.copy, duplicateOf: fixture.original, reviewer: fixture.deviceID))
        XCTAssertFalse(annotations.isExcludedDuplicate(fixture.copy))
        XCTAssertThrowsError(try annotations.markOwnerUnavailable(workout: fixture.remote, reviewer: fixture.deviceID))
        XCTAssertFalse(annotations.isOwnerUnavailable(fixture.remote))
        XCTAssertTrue(try annotations.history(workout: fixture.remote).isEmpty)
    }

    func testWorkoutsOnlyBackupPreservesValidatedDuplicateExclusion() throws {
        let fixture = try makeFixture()
        let annotations = WorkoutAnnotationStore(context: ModelContext(fixture.container))
        try annotations.markDuplicate(workout: fixture.copy, duplicateOf: fixture.original, reviewer: fixture.deviceID)
        let data = try WorkspaceBackupStore(context: ModelContext(fixture.container)).export(categories: [.workouts])
        let destination = try makeContainer()
        let backups = WorkspaceBackupStore(context: ModelContext(destination))
        let staged = try backups.stage(data)
        try backups.restore(stage: staged)
        let restored = try workouts(destination)
        XCTAssertEqual(restored.count, 2) // The unfinished remote snapshot remains in the review archive.
        let restoredAnnotations = WorkoutAnnotationStore(context: ModelContext(destination))
        XCTAssertEqual(restoredAnnotations.includedWorkouts(restored).map(\.id), [fixture.original.id])
        XCTAssertEqual(try restoredAnnotations.history(workout: fixture.copy).count, 1)
    }

    func testOwnerUpdateChangesInterruptionToReviewWithoutMutatingRemoteRecord() throws {
        let fixture = try makeFixture()
        let context = ModelContext(fixture.container)
        let annotations = WorkoutAnnotationStore(context: context)
        try annotations.markOwnerUnavailable(workout: fixture.remote, reviewer: fixture.deviceID)
        XCTAssertTrue(annotations.isOwnerUnavailable(fixture.remote))
        XCTAssertEqual(try workouts(fixture.container).first { $0.id == fixture.remote.id }, fixture.remote)
        let operation = WorkoutOperation(session: fixture.remote, command: .pause, at: Date())
        let newer = WorkoutReducer.apply(operation, to: fixture.remote, at: Date()).session
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutRecord>()).first { $0.id == newer.id })
        row.payload = try JSONEncoder().encode(newer)
        try context.save()
        XCTAssertEqual(annotations.interruptionState(newer), .ownerUpdated)
        XCTAssertFalse(annotations.isOwnerUnavailable(newer))
        try annotations.clearOwnerUnavailable(workout: newer, reviewer: fixture.deviceID)
        XCTAssertEqual(annotations.interruptionState(newer), .none)
    }

    func testImportedInterruptionAndRetiredGenerationNeverActivateLocally() throws {
        let fixture = try makeFixture()
        let context = ModelContext(fixture.container)
        let annotations = WorkoutAnnotationStore(context: context)
        try annotations.markOwnerUnavailable(workout: fixture.remote, reviewer: fixture.deviceID)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<BackupArchiveRecord>()).first)
        row.sourceFingerprint = "restored-source"
        try context.save()
        XCTAssertFalse(annotations.isOwnerUnavailable(fixture.remote))
        row.sourceFingerprint = "local"
        let identity = try XCTUnwrap(context.fetch(FetchDescriptor<RuntimeIdentityRecord>()).first)
        identity.syncGeneration = UUID().uuidString
        try context.save()
        XCTAssertFalse(annotations.isOwnerUnavailable(fixture.remote))
        XCTAssertEqual(try annotations.history(workout: fixture.remote).count, 1)
    }

    func testSeparatePhoneRecordingRequiresReviewAndKeepsRemoteSnapshot() throws {
        let fixture = try makeFixture()
        let store = try AppStore(context: ModelContext(fixture.container), bridge: PlanBridge(isEnabled: false), healthEnabled: false)
        XCTAssertFalse(store.startSeparatePhoneWorkout(after: fixture.remote.id))
        try store.workoutAnnotations.markOwnerUnavailable(workout: fixture.remote, reviewer: store.deviceID)
        XCTAssertTrue(store.startSeparatePhoneWorkout(after: fixture.remote.id))
        let separate = try XCTUnwrap(store.currentWorkout)
        XCTAssertNotEqual(separate.id, fixture.remote.id)
        XCTAssertEqual(separate.ownerDeviceID, store.deviceID)
        XCTAssertNil(separate.scheduledSessionID)
        XCTAssertEqual(separate.completedSetCount, 0)
        XCTAssertTrue(separate.exercises.flatMap(\.sets).allSatisfy { $0.actual.isEmpty })
        XCTAssertEqual(store.workouts.first { $0.id == fixture.remote.id }, fixture.remote)
        XCTAssertFalse(store.health?.ownsActiveSession ?? true)
    }

    func testMalformedImportedAnnotationCannotExcludeWorkout() throws {
        let fixture = try makeFixture()
        let context = ModelContext(fixture.container)
        let record = BackupRecord(id: "annotation:\(UUID())", category: .workouts,
            payload: .object(["nativeWorkoutAnnotationVersion": .number(1), "annotation": .object(["decision": .string("duplicate")])]))
        context.insert(BackupArchiveRecord(key: record.key, recordData: try JSONEncoder().encode(record),
            sourceFingerprint: "untrusted-import", needsReview: true))
        try context.save()
        XCTAssertThrowsError(try WorkoutAnnotationStore.validateBackupRecord(record))
        let annotations = WorkoutAnnotationStore(context: context)
        XCTAssertEqual(annotations.includedWorkouts([fixture.original, fixture.copy]), [fixture.original, fixture.copy])
    }

    func testWrongGenerationAnnotationIsRejectedByBackupRelationshipValidation() throws {
        let fixture = try makeFixture()
        let annotations = WorkoutAnnotationStore(context: ModelContext(fixture.container))
        try annotations.markDuplicate(workout: fixture.copy, duplicateOf: fixture.original, reviewer: fixture.deviceID)
        var records = try WorkspaceBackupStore(context: ModelContext(fixture.container)).records()
        let index = try XCTUnwrap(records.firstIndex { $0.id.hasPrefix("annotation:") })
        let encoded = try JSONEncoder().encode(records[index])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var payload = try XCTUnwrap(object["payload"] as? [String: Any])
        var event = try XCTUnwrap(payload["annotation"] as? [String: Any])
        event["sessionGeneration"] = "retired-other-workout"
        payload["annotation"] = event
        object["payload"] = payload
        records[index] = try JSONDecoder().decode(BackupRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(try WorkoutAnnotationStore.validateBackupRecord(records[index]))
        XCTAssertThrowsError(try WorkoutAnnotationStore.validateBackupRelationships(records: records))
    }

    private struct Fixture {
        let container: ModelContainer
        let original: WorkoutSession
        let copy: WorkoutSession
        let remote: WorkoutSession
        let deviceID: String
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = WorkspaceSchema.current
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    }

    private func makeFixture() throws -> Fixture {
        let container = try makeContainer()
        let context = ModelContext(container)
        let identity = RuntimeIdentityRecord()
        context.insert(identity)
        let plan = try XCTUnwrap(PlanImporter.importText(PlanContract.exampleJSON).plan)
        let prescription = try XCTUnwrap(plan.days.first?.sessions.first)
        let date = Date().addingTimeInterval(-60)
        func session(_ owner: String, finished: Bool) throws -> WorkoutSession {
            let started = try WorkoutSession.start(prescription: prescription, planID: plan.id,
                planRevisionID: "annotation-plan", ownerDeviceID: owner, at: date,
                timeZoneIdentifier: "Asia/Singapore", syncGeneration: identity.syncGeneration)
            if !finished { return started }
            let operation = WorkoutOperation(session: started, command: .finish(allowPartial: true), at: date.addingTimeInterval(30))
            return WorkoutReducer.apply(operation, to: started, at: date.addingTimeInterval(30)).session
        }
        let original = try session(identity.deviceID, finished: true)
        let copy = try session(identity.deviceID, finished: true)
        let remote = try session("recording-watch", finished: false)
        for workout in [original, copy, remote] {
            context.insert(WorkoutRecord(id: workout.id, payload: try JSONEncoder().encode(workout)))
        }
        try context.save()
        return Fixture(container: container, original: original, copy: copy, remote: remote, deviceID: identity.deviceID)
    }

    private func workouts(_ container: ModelContainer) throws -> [WorkoutSession] {
        try ModelContext(container).fetch(FetchDescriptor<WorkoutRecord>()).map { try JSONDecoder().decode(WorkoutSession.self, from: $0.payload) }
    }
}
