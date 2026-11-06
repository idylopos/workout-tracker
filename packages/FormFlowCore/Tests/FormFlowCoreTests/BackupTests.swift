import XCTest
@testable import FormFlowCore

final class BackupTests: XCTestCase {
    func testDefaultExportExcludesPrivateCategoriesAndIncludesPrescription() throws {
        let plan = BackupRecord(id: "plan", category: .plans, payload: .object(["name": .string("Week")]))
        let workout = BackupRecord(id: "session", category: .workouts, payload: .object(["actual": .number(25)]), references: [.init(category: .plans, id: "plan")])
        let profile = BackupRecord(id: "profile", category: .profile, payload: .string("private injury detail"))
        let raw = BackupRecord(id: "raw", category: .rawAIResponses, payload: .string("private original response"))
        let output = try NativeBackupExporter.export(records: [plan, workout, profile, raw], categories: [.workouts])
        let staged = try BackupImporter.stage(output)
        XCTAssertEqual(Set(staged.records.map(\.category)), [.plans, .workouts])
        XCTAssertFalse(String(decoding: output, as: UTF8.self).contains("private"))
        let all = try NativeBackupExporter.export(records: [plan, workout, profile, raw], categories: Set(BackupCategory.allCases))
        XCTAssertEqual(Set(try BackupImporter.stage(all).records.map(\.category)), [.plans, .workouts, .profile, .rawAIResponses])
    }
    func testDuplicateImportsAreIdempotentAndConflictsNeedExplicitChoice() throws {
        let original = BackupRecord(id: "body", category: .body, payload: .object(["weight": .number(72)]))
        let corrected = BackupRecord(id: "body", category: .body, payload: .object(["weight": .number(73)]))
        let data = try NativeBackupExporter.export(records: [original])
        let duplicate = try BackupImporter.stage(data, existing: [original])
        XCTAssertEqual(duplicate.preview.duplicates, [original.key])
        let changes = try BackupRestorePlanner.changes(stage: duplicate, existing: [original])
        XCTAssertTrue(changes.insertions.isEmpty); XCTAssertTrue(changes.replacements.isEmpty)
        let conflict = try BackupImporter.stage(data, existing: [corrected])
        XCTAssertEqual(conflict.preview.conflicts, [original.key])
        XCTAssertThrowsError(try BackupRestorePlanner.changes(stage: conflict, existing: [corrected]))
        let keep = try BackupRestorePlanner.changes(stage: conflict, existing: [corrected], conflictChoices: [original.key: .keepExisting])
        XCTAssertEqual(keep.skippedKeys, [original.key]); XCTAssertTrue(keep.replacements.isEmpty)
        let replace = try BackupRestorePlanner.changes(stage: conflict, existing: [corrected], conflictChoices: [original.key: .replaceExisting])
        XCTAssertEqual(replace.replacements, [original])
        // A preview that saw an empty store does not authorize overwriting a later edit.
        let emptyPreview = try BackupImporter.stage(data)
        XCTAssertThrowsError(try BackupRestorePlanner.changes(stage: emptyPreview, existing: [corrected]))
    }
    func testMissingRequiredPlanAndDuplicateIdentitiesFailBeforeRestore() throws {
        let workout = BackupRecord(id: "session", category: .workouts, payload: .object([:]), references: [.init(category: .plans, id: "missing")])
        XCTAssertThrowsError(try NativeBackupExporter.export(records: [workout]))
        let duplicate = NativeBackupArchive(records: [workout, workout])
        XCTAssertThrowsError(try BackupImporter.stage(JSONEncoder().encode(duplicate)))
        XCTAssertThrowsError(try BackupImporter.stage(Data(repeating: 0, count: BackupImporter.maximumBytes + 1)))
    }
    func testReferenceRemovedAfterPreviewBlocksCommitPlan() throws {
        let plan = BackupRecord(id: "plan", category: .plans, payload: .object([:]))
        let workout = BackupRecord(id: "session", category: .workouts, payload: .object([:]), references: [.init(category: .plans, id: "plan")])
        let data = try JSONEncoder().encode(NativeBackupArchive(records: [workout]))
        let stage = try BackupImporter.stage(data, existing: [plan])
        XCTAssertThrowsError(try BackupRestorePlanner.changes(stage: stage, existing: []))
    }
    func testLegacyCarryCardioPainAndPendingDraftPreservedAcrossNativeRoundTrip() throws {
        let input = Data(legacyFixture.utf8)
        let stage = try BackupImporter.stage(input, legacyTimeZoneID: "Asia/Singapore")
        XCTAssertTrue(stage.isLegacy); XCTAssertEqual(stage.originalInput, input)
        XCTAssertEqual(stage.preview.counts[.workouts], 1)
        XCTAssertNil(stage.preview.counts[.drafts])
        XCTAssertEqual(stage.preview.pendingDraftCount, 1)
        XCTAssertEqual(stage.preview.unresolvedReferences, ["plans:missing-plan"])
        let workout = try XCTUnwrap(stage.records.first { $0.category == .workouts })
        let log = try XCTUnwrap(workout.payload["log"])
        let carry = try XCTUnwrap(log["exercises"]?["suitcase-carry"])
        XCTAssertEqual(carry["measurement"]?.string, "weight_distance")
        XCTAssertNil(carry["sets"]?.array?.first?["reps"])
        XCTAssertEqual(carry["sets"]?.array?.first?["nativeDistanceMeters"]?.number, 30)
        XCTAssertEqual(log["exercises"]?["cycle"]?["sets"]?.array?.first?["nativeDistanceMeters"]?.number, 8_250)
        XCTAssertEqual(log["exercises"]?["cycle"]?["sets"]?.array?.first?["averageHeartRate"]?.number, 151)
        XCTAssertEqual(log["response"]?["painNext"]?.number, 2)
        XCTAssertEqual(log["response"]?["readiness"]?.string, "unknown")
        XCTAssertEqual(log["coaching"]?["acceptedTarget"]?.number, 22.5)
        XCTAssertNotNil(workout.payload["pendingDraft"])
        let exported = try NativeBackupExporter.export(records: stage.records)
        let restored = try BackupImporter.stage(exported, existing: stage.records)
        XCTAssertEqual(restored.preview.duplicates.count, stage.records.count)
        XCTAssertEqual(restored.records.first { $0.category == .workouts }?.fingerprint, workout.fingerprint)
        let repeated = try BackupImporter.stage(input, existing: stage.records, legacyTimeZoneID: "Asia/Singapore")
        XCTAssertEqual(repeated.preview.duplicates.count, stage.records.count)
    }
    func testLegacyPartialBodyAndWeeklyNightlySleepRemainSeparate() throws {
        let stage = try BackupImporter.stage(Data(legacyFixture.utf8), legacyTimeZoneID: "UTC")
        let body = try XCTUnwrap(stage.records.first { $0.category == .body })
        XCTAssertEqual(body.payload["weight"], .null)
        XCTAssertEqual(body.payload["waist"]?.number, 83)
        XCTAssertEqual(stage.preview.counts[.sleep], 2)
        XCTAssertEqual(Set(stage.records.filter { $0.category == .sleep }.compactMap { $0.payload["legacyFrequency"]?.string }), ["weekly", "nightly"])
        var value = try JSONDecoder().decode(BackupJSONValue.self, from: Data(legacyFixture.utf8)).object!
        value["bodyLogs"] = .array([.object(["date": .string("2026-09-17"), "weight": .bool(false)])])
        XCTAssertThrowsError(try BackupImporter.stage(BackupJSONValue.object(value).canonicalData()))
    }
    private let legacyFixture = #"""
    {"version":1,"settings":{"builtInPlanRevision":1},"exerciseConfigs":{},
     "workoutLogs":{"day":{"date":"2026-09-16","planId":"missing-plan","savedAt":"2026-09-16T10:00:00Z",
       "exercises":{"suitcase-carry":{"measurement":"weight_reps","sets":[{"completed":true,"weight":20,"reps":30,"rir":2}]},
                    "cycle":{"measurement":"duration","sets":[{"completed":true,"minutes":24,"seconds":30,"distance":8.25,"calories":285,"averageHeartRate":151,"averageRpm":82.5,"rpe":7}]}},
       "response":{"painNext":5,"readiness":"unknown"},"coaching":{"acceptedTarget":22.5},"notes":"Keep source notes"}},
     "workoutDrafts":{"day":{"date":"2026-09-16","planId":"missing-plan","savedAt":"2026-09-16T11:00:00Z","exercises":{}}},
     "bodyLogs":[{"date":"2026-09-17","weight":null,"waist":83}],
     "sleepLogs":[{"week":"2026-09-14","hours":7}],"dailySleepLogs":[{"date":"2026-09-17","hours":7.5}],
     "savedActivities":[{"id":"saved-hiit","name":"Bike HIIT","type":"hiit","measurement":"duration"}],
     "dailyCheckIns":{"2026-09-17":{"status":"completed","recoveryUnknown":["day"]}}}
    """#
}
