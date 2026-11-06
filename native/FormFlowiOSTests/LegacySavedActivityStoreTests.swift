import XCTest
import SwiftData
import FormFlowCore
@testable import FormFlowiOS

@MainActor
final class LegacySavedActivityStoreTests: XCTestCase {
    func testReviewedLegacyTemplateIsReusableAndRetainsOriginalWithoutRecordingAWorkout() throws {
        let (container, source) = try fixture()
        let store = try makeStore(container)
        let review = try XCTUnwrap(store.legacySavedActivities().first)
        var exercise = try XCTUnwrap(review.reviewDraft())
        exercise.target.duration = .init(min: 15, max: 20, unit: .min)
        XCTAssertTrue(store.saveExtraActivityTemplate(exercise, legacySource: review), store.errorMessage ?? "")
        XCTAssertEqual(try store.savedExtraActivities(), [exercise])
        XCTAssertEqual(try store.archivedBackupRecords().first { $0.key == source.key }, source)
        XCTAssertTrue(store.workouts.isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<WorkoutRecord>()).isEmpty)
        let export = try store.exportBackup(categories: [.activities])
        let records = try BackupImporter.stage(export).records
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first { $0.key == source.key }, source)
        XCTAssertEqual(records.first { $0.payload["nativeActivityVersion"] == .number(1) }?.references,
                       [.init(category: .activities, id: source.id)])
    }

    func testSavingEditedNativeCopyRetainsItsOriginalLegacyProvenance() throws {
        let (container, source) = try fixture()
        let store = try makeStore(container)
        let review = try XCTUnwrap(store.legacySavedActivities().first)
        var exercise = try XCTUnwrap(review.reviewDraft())
        exercise.target.duration = .init(min: 15, max: 20, unit: .min)
        XCTAssertTrue(store.saveExtraActivityTemplate(exercise, legacySource: review))
        let before = try XCTUnwrap(store.archivedBackupRecords().first { $0.payload["nativeActivityVersion"] != nil })
        exercise.target.duration = .init(min: 20, max: 25, unit: .min)
        XCTAssertTrue(store.saveExtraActivityTemplate(exercise))
        let after = try XCTUnwrap(store.archivedBackupRecords().first { $0.key == before.key })
        XCTAssertEqual(after.payload["legacyActivitySource"], before.payload["legacyActivitySource"])
        XCTAssertEqual(after.references, before.references)
        XCTAssertEqual(try store.archivedBackupRecords().first { $0.key == source.key }, source)
        XCTAssertEqual(try store.savedExtraActivities(), [exercise])
    }

    func testInvalidTargetsAndFailedSaveLeaveOriginalTemplateUntouched() throws {
        let (container, source) = try fixture()
        let store = try makeStore(container)
        let review = try XCTUnwrap(store.legacySavedActivities().first)
        var exercise = try XCTUnwrap(review.reviewDraft())
        XCTAssertFalse(store.saveExtraActivityTemplate(exercise, legacySource: review))
        XCTAssertEqual(try store.archivedBackupRecords(), [source])
        exercise.target.duration = .init(min: 15, max: 20, unit: .min)
        let failing = try AppStore(context: ModelContext(container), bridge: PlanBridge(isEnabled: false), healthEnabled: false,
                                  commit: { _ in throw NSError(domain: "DiskFull", code: 1) })
        XCTAssertFalse(failing.saveExtraActivityTemplate(exercise, legacySource: review))
        XCTAssertEqual(try makeStore(container).archivedBackupRecords(), [source])
        XCTAssertTrue(try makeStore(container).savedExtraActivities().isEmpty)
    }

    func testChangedArchivedSourceRequiresFreshReviewBeforeSavingCopy() throws {
        let (container, source) = try fixture()
        let store = try makeStore(container)
        let review = try XCTUnwrap(store.legacySavedActivities().first)
        var exercise = try XCTUnwrap(review.reviewDraft())
        exercise.target.duration = .init(min: 15, max: 20, unit: .min)
        let context = ModelContext(container)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<BackupArchiveRecord>()).first)
        var payload = try XCTUnwrap(source.payload.object)
        payload["name"] = .string("Changed walking template")
        let changed = BackupRecord(id: source.id, category: source.category, payload: .object(payload))
        row.recordData = try JSONEncoder().encode(changed)
        try context.save()
        let reopened = try makeStore(container)
        XCTAssertFalse(reopened.saveExtraActivityTemplate(exercise, legacySource: review))
        XCTAssertEqual(try reopened.archivedBackupRecords(), [changed])
    }

    func testUnsupportedArchivedActivityRemainsVisibleAndCanBeCorrectedManually() throws {
        let (container, source) = try fixture(measurement: "future_activity")
        let store = try makeStore(container)
        let review = try XCTUnwrap(store.legacySavedActivities().first)
        XCTAssertFalse(review.canPrepareDraft)
        XCTAssertNil(review.reviewDraft())
        XCTAssertFalse(review.issues.isEmpty)
        let manual = PlanExercise(instanceId: "manual-walk", exerciseId: "manual-walk", name: "Walking",
                                  measurement: .duration, target: .init(sets: 1, restSeconds: 0,
                                      duration: .init(min: 10, max: 10, unit: .min)))
        XCTAssertTrue(store.saveExtraActivityTemplate(manual, legacySource: review))
        XCTAssertEqual(try store.archivedBackupRecords().first { $0.key == source.key }, source)
        XCTAssertEqual(try store.savedExtraActivities(), [manual])
        XCTAssertTrue(store.workouts.isEmpty)
    }

    private func fixture(measurement: String = "duration") throws -> (ModelContainer, BackupRecord) {
        let schema = WorkspaceSchema.current
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let source = BackupRecord(id: "saved-walking", category: .activities, payload: .object([
            "id": .string("saved-walking"), "name": .string("Walking"),
            "type": .string("walking"), "measurement": .string(measurement)
        ]))
        let context = ModelContext(container)
        context.insert(RuntimeIdentityRecord())
        context.insert(BackupArchiveRecord(key: source.key, recordData: try JSONEncoder().encode(source),
                                           sourceFingerprint: "legacy-import", needsReview: true))
        try context.save()
        return (container, source)
    }

    private func makeStore(_ container: ModelContainer) throws -> AppStore {
        try AppStore(context: ModelContext(container), bridge: PlanBridge(isEnabled: false), healthEnabled: false)
    }
}
