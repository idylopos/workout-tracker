import XCTest
import SwiftData
import FormFlowCore
@testable import FormFlowiOS

@MainActor
final class StoreBoundaryTests: XCTestCase {
    func testRecoveryRejectsInvalidWorkoutWithoutChangingStoredPayload() throws {
        let container = try makeContainer()
        let workout = try makeWorkout()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(workout)) as? [String: Any])
        object["revision"] = -1
        let corruptPayload = try JSONSerialization.data(withJSONObject: object)
        // The payload still decodes: this exercises domain validation, not a JSON syntax failure.
        XCTAssertNoThrow(try JSONDecoder().decode(WorkoutSession.self, from: corruptPayload))
        try insertWorkout(id: workout.id, payload: corruptPayload, into: container)

        XCTAssertThrowsError(try makeStore(container))
        let persisted = try ModelContext(container).fetch(FetchDescriptor<WorkoutRecord>())
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.payload, corruptPayload)
    }

    func testRecoveryRejectsMismatchedWorkoutIdentity() throws {
        let container = try makeContainer()
        let workout = try makeWorkout()
        let rowID = UUID()
        let payload = try JSONEncoder().encode(workout)
        try insertWorkout(id: rowID, payload: payload, into: container)

        XCTAssertThrowsError(try makeStore(container))
        let persisted = try ModelContext(container).fetch(FetchDescriptor<WorkoutRecord>())
        XCTAssertEqual(persisted.first?.id, rowID)
        XCTAssertEqual(persisted.first?.payload, payload)
    }

    func testRecoveryAcceptsValidatedWorkout() throws {
        let container = try makeContainer()
        let workout = try makeWorkout()
        try insertWorkout(id: workout.id, payload: JSONEncoder().encode(workout), into: container)
        XCTAssertEqual(try makeStore(container).workouts, [workout])
    }

    func testImportedActivityIsValidatedBeforeBeingOfferedAsTemplate() throws {
        let container = try makeContainer()
        var exercise = try makeExercise()
        exercise.target.sets = 21
        let archive = try insertActivity(exercise, into: container)
        let store = try makeStore(container)

        XCTAssertThrowsError(try store.savedExtraActivities())
        // Rejected activity remains available for lossless archive export and manual inspection.
        XCTAssertEqual(try store.archivedBackupRecords(), [archive])
    }

    func testValidImportedActivityCanBeOfferedAsTemplate() throws {
        let container = try makeContainer()
        let exercise = try makeExercise()
        _ = try insertActivity(exercise, into: container)
        XCTAssertEqual(try makeStore(container).savedExtraActivities(), [exercise])
    }

    func testInvalidTemplateEditCannotReplaceReusableSavedActivity() throws {
        let container = try makeContainer()
        let original = try makeExercise()
        let store = try makeStore(container)
        XCTAssertTrue(store.saveExtraActivityTemplate(original))
        var invalid = original
        invalid.target.sets = 0
        XCTAssertFalse(store.saveExtraActivityTemplate(invalid))
        XCTAssertEqual(try store.savedExtraActivities(), [original])
        XCTAssertEqual(try store.archivedBackupRecords().filter { $0.category == .activities }.count, 1)
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

    private func makeWorkout() throws -> WorkoutSession {
        let plan = try XCTUnwrap(PlanImporter.importText(PlanContract.exampleJSON).plan)
        let session = try XCTUnwrap(plan.days.first?.sessions.first)
        return try WorkoutSession.start(prescription: session, planID: plan.id,
            planRevisionID: "boundary-test-plan", ownerDeviceID: "test-phone", at: Date(),
            timeZoneIdentifier: "Asia/Singapore", syncGeneration: "boundary-test-generation")
    }

    private func makeExercise() throws -> PlanExercise {
        let plan = try XCTUnwrap(PlanImporter.importText(PlanContract.exampleJSON).plan)
        return try XCTUnwrap(plan.days.first?.sessions.first?.exercises.first)
    }

    private func insertWorkout(id: UUID, payload: Data, into container: ModelContainer) throws {
        let context = ModelContext(container)
        context.insert(RuntimeIdentityRecord())
        context.insert(WorkoutRecord(id: id, payload: payload))
        try context.save()
    }

    private func insertActivity(_ exercise: PlanExercise, into container: ModelContainer) throws -> BackupRecord {
        let record = BackupRecord(id: "native-activity:\(exercise.exerciseId)", category: .activities,
            payload: .object(["nativeActivityVersion": .number(1), "exercise": try .encode(exercise)]))
        let context = ModelContext(container)
        context.insert(BackupArchiveRecord(key: record.key, recordData: try JSONEncoder().encode(record),
            sourceFingerprint: "imported-test", needsReview: true))
        try context.save()
        return record
    }
}
