import XCTest
import SwiftData
import FormFlowCore
@testable import FormFlowiOS

@MainActor
final class BackupStoreTests: XCTestCase {
    func testFreshExportRestorePreservesTypedHistoryAndSafeSettings() throws {
        let source = try fixture(), destination = try container()
        let service = WorkspaceBackupStore(context: destination.mainContext)
        let stage = try service.stage(WorkspaceBackupStore(context: source.mainContext).export())
        try service.restore(stage: stage)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<ActivatedPlanRecord>()), 1)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<WorkoutRecord>()), 1)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<TrackingRecord>()), 3)
        let snapshot = try snapshot(destination)
        XCTAssertEqual(snapshot.onboardingStep, 4); XCTAssertEqual(snapshot.profile.units, .imperial)
        XCTAssertEqual(snapshot.profile.goal, ""); XCTAssertEqual(snapshot.promptDraft, ""); XCTAssertEqual(snapshot.importText, "")
        XCTAssertNotNil(snapshot.activeRevisionID)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<RuntimeIdentityRecord>()), 0)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<BackupProvenanceRecord>()), 1)
    }

    func testDefaultExportExcludesPrivateCategoriesAndPlanSource() throws {
        let source = try fixture()
        let data = try WorkspaceBackupStore(context: source.mainContext).export()
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["PRIVATE_PROFILE", "PRIVATE_PROMPT", "PRIVATE_RESPONSE", "PRIVATE_PLAN_SOURCE"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        let staged = try BackupImporter.stage(data)
        XCTAssertFalse(staged.records.contains { $0.category.isPrivateOptional })
        let plans = staged.records.filter { $0.category == .plans }
        XCTAssertTrue(plans.allSatisfy { $0.payload["value"]?["sourceText"] == nil })
        let settings = staged.records.filter { $0.category == .settings }
        XCTAssertTrue(settings.allSatisfy { $0.payload["value"]?["deviceID"] == nil && $0.payload["value"]?["syncGeneration"] == nil })
    }

    func testExplicitPrivateSelectionRoundTripsWithoutIdentityCloning() throws {
        let source = try fixture(), destination = try container()
        let identity = RuntimeIdentityRecord(); let localID = identity.deviceID
        destination.mainContext.insert(identity); try destination.mainContext.save()
        let data = try WorkspaceBackupStore(context: source.mainContext).export(categories: Set(BackupCategory.allCases))
        let service = WorkspaceBackupStore(context: destination.mainContext)
        try service.restore(stage: service.stage(data))
        let restored = try snapshot(destination)
        XCTAssertEqual(restored.profile.goal, "PRIVATE_PROFILE")
        XCTAssertEqual(restored.promptDraft, "PRIVATE_PROMPT")
        XCTAssertEqual(restored.importText, "PRIVATE_RESPONSE")
        XCTAssertNil(restored.promptProfile, "Copied prompt consent must be reviewed against this device's profile.")
        XCTAssertEqual(try destination.mainContext.fetch(FetchDescriptor<RuntimeIdentityRecord>()).first?.deviceID, localID)
        XCTAssertEqual(try destination.mainContext.fetch(FetchDescriptor<ActivatedPlanRecord>()).first?.sourceText, "PRIVATE_PLAN_SOURCE")
    }

    func testDuplicateRestoreIsIdempotentInPopulatedStore() throws {
        let source = try fixture(), destination = try container()
        let data = try WorkspaceBackupStore(context: source.mainContext).export()
        let service = WorkspaceBackupStore(context: destination.mainContext)
        try service.restore(stage: service.stage(data))
        let first = try service.records()
        let second = try service.stage(data)
        XCTAssertEqual(second.preview.duplicates.count, second.records.count)
        try service.restore(stage: second)
        XCTAssertEqual(try service.records(), first)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<BackupProvenanceRecord>()), 1)
    }

    func testFreshConflictCheckProtectsChangesMadeAfterPreview() throws {
        let source = try fixture(), destination = try container()
        let data = try WorkspaceBackupStore(context: source.mainContext).export()
        let service = WorkspaceBackupStore(context: destination.mainContext)
        try service.restore(stage: service.stage(data))
        let stalePreview = try service.stage(data)
        let row = try XCTUnwrap(destination.mainContext.fetch(FetchDescriptor<ActivatedPlanRecord>()).first)
        var plan = try JSONDecoder().decode(WeeklyPlan.self, from: row.planData)
        plan.name = "Changed after preview"
        row.planData = try JSONEncoder().encode(plan); try destination.mainContext.save()
        XCTAssertThrowsError(try service.restore(stage: stalePreview))
        XCTAssertEqual(try JSONDecoder().decode(WeeklyPlan.self, from: row.planData).name, "Changed after preview")
        try service.restore(stage: stalePreview, conflictChoices: ["plans:\(row.id)": .keepExisting])
        XCTAssertEqual(try JSONDecoder().decode(WeeklyPlan.self, from: row.planData).name, "Changed after preview")
        try service.restore(stage: stalePreview, conflictChoices: ["plans:\(row.id)": .replaceExisting])
        XCTAssertNotEqual(try JSONDecoder().decode(WeeklyPlan.self, from: row.planData).name, "Changed after preview")
    }

    func testInjectedCommitFailureRollsBackEveryCategoryAndProvenance() throws {
        let source = try fixture(), destination = try container()
        let data = try WorkspaceBackupStore(context: source.mainContext).export(categories: Set(BackupCategory.allCases))
        let identity = RuntimeIdentityRecord(); destination.mainContext.insert(identity); try destination.mainContext.save()
        let service = WorkspaceBackupStore(context: destination.mainContext) { _ in
            throw NSError(domain: "BackupTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Simulated full disk"])
        }
        XCTAssertThrowsError(try service.restore(stage: service.stage(data)))
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<ActivatedPlanRecord>()), 0)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<WorkoutRecord>()), 0)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<TrackingRecord>()), 0)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<WorkspaceRecord>()), 0)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<BackupProvenanceRecord>()), 0)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<RuntimeIdentityRecord>()), 1)
    }

    func testUnfinishedWorkoutIsQuarantinedAndRemainsReexportable() throws {
        let source = try fixture(finished: false), destination = try container()
        let data = try WorkspaceBackupStore(context: source.mainContext).export()
        let service = WorkspaceBackupStore(context: destination.mainContext)
        try service.restore(stage: service.stage(data))
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<WorkoutRecord>()), 0)
        let archives = try destination.mainContext.fetch(FetchDescriptor<BackupArchiveRecord>())
        XCTAssertEqual(archives.count, 1); XCTAssertTrue(try XCTUnwrap(archives.first).needsReview)
        let archived = try XCTUnwrap(service.archivedRecords().first)
        XCTAssertEqual(archived.payload["nativeType"]?.string, "workout")
        let reexported = try BackupImporter.stage(service.export())
        XCTAssertTrue(reexported.records.contains(archived))
        try service.restore(stage: service.stage(data))
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<BackupArchiveRecord>()), 1)
    }

    func testLegacyTwiceRetainsNormalizedRecordsAndOriginalSource() throws {
        let destination = try container(), service = WorkspaceBackupStore(context: destination.mainContext)
        let data = Data(#"{"version":1,"settings":{"block":1},"workoutLogs":{"form-flow|2026-09-17":{"date":"2026-09-17","planId":"form-flow","exercises":{"walk":{"measurement":"distance_time","sets":[{"done":true,"distance":"2.5","duration":"20"}]}}}},"bodyLogs":[],"sleepLogs":[],"uninterpretedOriginalField":{"note":"preserve me"}}"#.utf8)
        let stage = try service.stage(data)
        XCTAssertTrue(stage.isLegacy)
        try service.restore(stage: stage); try service.restore(stage: service.stage(data))
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<WorkoutRecord>()), 0)
        XCTAssertEqual(try service.archivedRecords().count, stage.records.count)
        let original = try XCTUnwrap(destination.mainContext.fetch(FetchDescriptor<BackupProvenanceRecord>()).first)
        XCTAssertEqual(original.originalInput, data)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<BackupProvenanceRecord>()), 1)
        XCTAssertEqual(try BackupImporter.stage(service.export()).records, stage.records.sorted { $0.key < $1.key })
    }

    func testInvalidDecodedWorkoutCannotReachPersistence() throws {
        let source = try fixture(), destination = try container()
        let original = try WorkspaceBackupStore(context: source.mainContext).export()
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var records = try XCTUnwrap(archive["records"] as? [[String: Any]])
        let index = try XCTUnwrap(records.firstIndex { $0["category"] as? String == "workouts" })
        var payload = try XCTUnwrap(records[index]["payload"] as? [String: Any])
        var value = try XCTUnwrap(payload["value"] as? [String: Any])
        value["revision"] = -1; payload["value"] = value; records[index]["payload"] = payload; archive["records"] = records
        let invalid = try JSONSerialization.data(withJSONObject: archive)
        XCTAssertThrowsError(try WorkspaceBackupStore(context: destination.mainContext).stage(invalid))
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<WorkoutRecord>()), 0)
    }

    func testUnknownSettingsCannotSmuggleProfileOrRuntimeIdentity() throws {
        let source = try fixture(), destination = try container()
        let original = try WorkspaceBackupStore(context: source.mainContext).export()
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var records = try XCTUnwrap(archive["records"] as? [[String: Any]])
        let index = try XCTUnwrap(records.firstIndex { $0["category"] as? String == "settings" })
        var payload = try XCTUnwrap(records[index]["payload"] as? [String: Any])
        var value = try XCTUnwrap(payload["value"] as? [String: Any])
        value["deviceID"] = "CLONED"; value["profile"] = ["goal": "HIDDEN_PRIVATE"]
        payload["value"] = value; records[index]["payload"] = payload; archive["records"] = records
        XCTAssertThrowsError(try WorkspaceBackupStore(context: destination.mainContext).stage(JSONSerialization.data(withJSONObject: archive)))
    }

    private func fixture(finished: Bool = true) throws -> ModelContainer {
        let container = try container(), context = container.mainContext
        let plan = try XCTUnwrap(PlanImporter.importText(PlanContract.exampleJSON).plan)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let revision = ActivatedPlanRecord(sequence: 1, activationDate: date, planData: try JSONEncoder().encode(plan), sourceText: "PRIVATE_PLAN_SOURCE")
        context.insert(revision)
        var snapshot = WorkspaceSnapshot()
        snapshot.activeRevisionID = revision.id; snapshot.onboardingStep = 4
        snapshot.profile.goal = "PRIVATE_PROFILE"; snapshot.profile.units = .imperial
        snapshot.promptDraft = "PRIVATE_PROMPT"; snapshot.promptProfile = snapshot.profile
        snapshot.previousPrompts = [PromptSnapshot(createdAt: date, text: "PRIVATE_PROMPT_HISTORY")]
        snapshot.importText = "PRIVATE_RESPONSE"; snapshot.reviewedSource = "PRIVATE_RESPONSE"
        context.insert(WorkspaceRecord(payload: try JSONEncoder().encode(snapshot)))
        let identity = RuntimeIdentityRecord(); identity.deviceID = "PRIVATE_DEVICE"; identity.syncGeneration = "PRIVATE_GENERATION"; context.insert(identity)
        let prescription = try XCTUnwrap(plan.days.first?.sessions.first)
        var workout = try WorkoutSession.start(prescription: prescription, planID: plan.id, planRevisionID: revision.id,
            ownerDeviceID: identity.deviceID, at: date, timeZoneIdentifier: "Asia/Singapore", syncGeneration: identity.syncGeneration)
        if finished {
            let setID = try XCTUnwrap(workout.exercises.first?.sets.first?.id)
            let log = WorkoutOperation(session: workout, command: .logSet(setID: setID, values: WorkoutSetValues(reps: 8, load: PlanQuantity(value: 10, unit: .kg))), at: date.addingTimeInterval(1))
            workout = WorkoutReducer.apply(log, to: workout, at: log.createdAt).session
            let finish = WorkoutOperation(session: workout, command: .finish(allowPartial: true), at: date.addingTimeInterval(2))
            workout = WorkoutReducer.apply(finish, to: workout, at: finish.createdAt).session
        }
        XCTAssertTrue(WorkoutArchiveValidator.validate(workout).isEmpty)
        context.insert(WorkoutRecord(id: workout.id, payload: try JSONEncoder().encode(workout)))
        let day = try LocalTrainingDay(date: "2027-01-16", timeZoneID: "Asia/Singapore")
        let sleep = try ManualSleepRecord(day: day, hours: 7, updatedAt: date)
        let body = try BodyMeasurementRecord(day: day, weight: PlanQuantity(value: 70, unit: .kg), updatedAt: date)
        context.insert(TrackingRecord(id: sleep.id, category: "sleep", payload: try JSONEncoder().encode(sleep)))
        context.insert(TrackingRecord(id: body.id, category: "body", payload: try JSONEncoder().encode(body)))
        if let ended = workout.endedAt {
            let recoveryDay = LocalTrainingDay(instant: ended, timeZone: try XCTUnwrap(TimeZone(identifier: workout.timeZoneIdentifier)))
            let recovery = try SessionRecoveryRecord(sessionID: workout.id, phase: .evening, day: recoveryDay, rating: 1, updatedAt: ended)
            context.insert(TrackingRecord(id: recovery.id, category: "recovery", payload: try JSONEncoder().encode(recovery)))
        }
        try context.save()
        return container
    }
    private func snapshot(_ container: ModelContainer) throws -> WorkspaceSnapshot {
        let row = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WorkspaceRecord>()).first)
        return try JSONDecoder().decode(WorkspaceSnapshot.self, from: row.payload)
    }
    private func container() throws -> ModelContainer {
        let schema = WorkspaceSchema.current
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }
}
