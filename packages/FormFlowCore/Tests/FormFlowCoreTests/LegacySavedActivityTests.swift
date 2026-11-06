import XCTest
@testable import FormFlowCore

final class LegacySavedActivityTests: XCTestCase {
    func testSupportedWebMeasurementsKeepTheirUnitsWithoutInventingTargets() throws {
        let cases: [(MeasurementKind, [PlanUnit])] = [
            (.duration, [.min, .s]), (.durationCalories, [.min, .s, .kcal]),
            (.distanceTime, [.km, .min, .s]), (.distance, [.km])
        ]
        for (measurement, units) in cases {
            let source = activity(measurement: measurement.rawValue)
            let review = try XCTUnwrap(LegacySavedActivityReview(record: source))
            XCTAssertTrue(review.canPrepareDraft)
            XCTAssertEqual(review.sourceUnits, units)
            let draft = try XCTUnwrap(review.reviewDraft())
            XCTAssertEqual(draft.measurement, measurement)
            XCTAssertEqual(draft.target.sets, 1)
            XCTAssertEqual(draft.target.restSeconds, 0)
            XCTAssertNil(draft.target.duration)
            XCTAssertNil(draft.target.distance)
            XCTAssertNil(draft.target.calories)
            XCTAssertNil(draft.target.effort)
            XCTAssertNil(draft.progressionPolicy)
            XCTAssertTrue(PlanValidator.validateExercise(draft).contains { $0.severity == .error })
            XCTAssertEqual(review.original, source.payload)
        }
    }

    func testLongLegacyIdentityGetsAStableBoundedNativeIdentity() throws {
        let source = activity(id: String(repeating: "a", count: 96))
        let first = try XCTUnwrap(LegacySavedActivityReview(record: source)?.reviewDraft())
        let second = try XCTUnwrap(LegacySavedActivityReview(record: source)?.reviewDraft())
        XCTAssertEqual(first, second)
        XCTAssertLessThanOrEqual(first.exerciseId.count, 64)
        XCTAssertFalse(PlanValidator.validateExercise(first).contains { $0.path.hasSuffix("exerciseId") || $0.path.hasSuffix("instanceId") })
    }

    func testUnknownOriginalFieldsArePreservedButNotInterpretedAsPrescription() throws {
        let source = activity(extra: ["targetMinutes": .number(40), "notes": .string("Original note"), "future": .object(["keep": .bool(true)])])
        let review = try XCTUnwrap(LegacySavedActivityReview(record: source))
        XCTAssertTrue(review.canPrepareDraft)
        XCTAssertTrue(review.issues.contains { $0.contains("Additional original fields") })
        XCTAssertEqual(review.original, source.payload)
        XCTAssertNil(review.reviewDraft()?.target.duration)
        XCTAssertNil(review.reviewDraft()?.instructions)
    }

    func testMalformedOrUnsupportedDefinitionsStayVisibleForManualCorrection() throws {
        let sources = [
            activity(measurement: "future_measurement"), activity(type: "unknown-machine"),
            activity(name: "   "), activity(id: "UPPERCASE"),
            BackupRecord(id: "source", category: .activities, payload: .array([])),
            BackupRecord(id: "wrong-id", category: .activities, payload: activity().payload)
        ]
        for source in sources {
            let review = try XCTUnwrap(LegacySavedActivityReview(record: source))
            XCTAssertFalse(review.canPrepareDraft)
            XCTAssertNil(review.reviewDraft())
            XCTAssertFalse(review.issues.isEmpty)
            XCTAssertEqual(review.original, source.payload)
        }
    }

    func testHistoricalSetsCannotBecomeTemplateTargetsOrCompletedWork() throws {
        let source = activity(extra: ["sets": .array([.object(["minutes": .number(20), "completed": .bool(true)])])])
        let review = try XCTUnwrap(LegacySavedActivityReview(record: source))
        XCTAssertFalse(review.canPrepareDraft)
        XCTAssertNil(review.reviewDraft())
        XCTAssertEqual(review.original["sets"], source.payload["sets"])
        var manual = PlanExercise(instanceId: "manual", exerciseId: "manual", name: "Corrected walking", measurement: .duration,
                                  target: .init(sets: 1, restSeconds: 0))
        manual.target.duration = .init(min: 15, max: 15, unit: .min)
        let copy = try review.nativeCopy(exercise: manual, currentSource: source)
        XCTAssertNil(copy.payload["sets"])
        XCTAssertEqual(try copy.payload["exercise"]?.decode(PlanExercise.self), manual)
    }

    func testNativeAndUnrelatedRecordsAreNotReinterpretedAsWebDefinitions() {
        XCTAssertNil(LegacySavedActivityReview(record: .init(id: "native", category: .activities,
            payload: .object(["nativeActivityVersion": .number(1)]))))
        XCTAssertNil(LegacySavedActivityReview(record: .init(id: "future", category: .activities,
            payload: .object(["nativeType": .string("future-activity")]))))
        XCTAssertNil(LegacySavedActivityReview(record: .init(id: "body", category: .body, payload: activity().payload)))
    }

    func testReviewedNativeCopyIncludesProvenanceAndSourceInActivityOnlyExport() throws {
        let source = activity()
        let review = try XCTUnwrap(LegacySavedActivityReview(record: source))
        var draft = try XCTUnwrap(review.reviewDraft())
        draft.target.duration = .init(min: 10, max: 20, unit: .min)
        let copy = try review.nativeCopy(exercise: draft, currentSource: source)
        XCTAssertNotEqual(copy.key, source.key)
        XCTAssertEqual(copy.payload["legacyActivitySource"]?["recordID"], .string(source.id))
        XCTAssertEqual(copy.payload["legacyActivitySource"]?["fingerprint"], .string(source.fingerprint))
        XCTAssertEqual(copy.references, [.init(category: .activities, id: source.id)])
        let data = try NativeBackupExporter.export(records: [source, copy], categories: [.activities])
        let restored = try BackupImporter.stage(data)
        XCTAssertEqual(Set(restored.records.map(\.key)), Set([source.key, copy.key]))
        XCTAssertEqual(restored.records.first { $0.key == source.key }, source)
        XCTAssertFalse(restored.records.contains { $0.category == .workouts })
    }

    func testNativeCopyRejectsChangedSourceAndInvalidTargets() throws {
        let source = activity()
        let review = try XCTUnwrap(LegacySavedActivityReview(record: source))
        var draft = try XCTUnwrap(review.reviewDraft())
        XCTAssertThrowsError(try review.nativeCopy(exercise: draft, currentSource: source))
        draft.target.duration = .init(min: 10, max: 20, unit: .kg)
        XCTAssertThrowsError(try review.nativeCopy(exercise: draft, currentSource: source))
        draft.target.duration = .init(min: 10, max: 20, unit: .min)
        XCTAssertThrowsError(try review.nativeCopy(exercise: draft, currentSource: activity(name: "Changed")))
        draft.target.sets = 21
        XCTAssertThrowsError(try review.nativeCopy(exercise: draft, currentSource: source))
    }

    func testLegacyBackupStagingRetainsReusableDefinitionsForReview() throws {
        let raw: BackupJSONValue = .object(["version": .number(1), "workoutLogs": .object([:]),
            "bodyLogs": .array([]), "sleepLogs": .array([]), "savedActivities": .array([activity().payload])])
        let stage = try BackupImporter.stage(raw.canonicalData())
        let source = try XCTUnwrap(stage.records.first { $0.category == .activities })
        XCTAssertEqual(source.payload, activity().payload)
        XCTAssertNotNil(LegacySavedActivityReview(record: source)?.reviewDraft())
    }

    private func activity(id: String = "saved-walk", name: String = "Walking", type: String = "walking",
                          measurement: String = "duration", extra: [String: BackupJSONValue] = [:]) -> BackupRecord {
        var value: [String: BackupJSONValue] = ["id": .string(id), "name": .string(name),
                                              "type": .string(type), "measurement": .string(measurement)]
        value.merge(extra) { _, new in new }
        return BackupRecord(id: id, category: .activities, payload: .object(value))
    }
}
