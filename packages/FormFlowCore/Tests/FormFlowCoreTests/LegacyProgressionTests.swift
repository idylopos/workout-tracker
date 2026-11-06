import XCTest
@testable import FormFlowCore

final class LegacyProgressionTests: XCTestCase {
    private struct Fixture: Decodable {
        let name: String
        let today: String
        let exerciseID: String
        let log: BackupJSONValue
        let expectedQualified: Bool
    }
    private let exerciseID = "neutral-db-bench"
    private var now: Date { Date(timeIntervalSince1970: 1_789_905_600) } // 2026-09-20 12:00 UTC

    func testSharedWebQualificationFixtures() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("tests/fixtures/legacy-progression-parity.json"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: data)
        XCTAssertEqual(fixtures.count, 27)
        for fixture in fixtures {
            let record = try record(fixture.log)
            let evidence = try XCTUnwrap(LegacyProgressionEvidence(record: record, exerciseID: fixture.exerciseID))
            XCTAssertEqual(evidence.isQualified(asOfDate: fixture.today), fixture.expectedQualified,
                "\(fixture.name): \(evidence.qualificationIssues)")
            XCTAssertEqual(evidence.recordKey, record.key)
            XCTAssertEqual(evidence.sourceFingerprint, record.fingerprint)
        }
    }

    func testLegacyPriorCanCompleteNativeStrengthPairWithoutCreatingSession() throws {
        let source = try exposure(day: 19)
        let legacy = try evidence()
        let advice = advise(source, legacy: [legacy])
        XCTAssertEqual(advice.action, .increase)
        XCTAssertEqual(advice.qualifyingSessions, 2)
        XCTAssertEqual(advice.usedLegacyRecordKey, legacy.recordKey)
        XCTAssertEqual(advice.source.session, source.session)
        let target = try accept(advice, legacy: [legacy])
        XCTAssertEqual(target.legacyEvidenceReferences?.first?.recordID, String(legacy.recordKey.dropFirst("workouts:".count)))
        XCTAssertEqual(target.legacyEvidenceReferences?.first?.fingerprint, legacy.sourceFingerprint)
    }

    func testLatestUnknownLegacyExposureBreaksOlderNativeQualification() throws {
        let source = try exposure(day: 19), nativePrior = try exposure(day: 14)
        var log = try log().object!
        var exercises = log["exercises"]!.object!, exercise = exercises[exerciseID]!.object!
        exercise["coaching"] = .object(["technique": .string("unknown")])
        exercises[exerciseID] = .object(exercise); log["exercises"] = .object(exercises)
        let unknown = try evidence(.object(log))
        let advice = advise(source, native: [nativePrior], legacy: [unknown])
        XCTAssertEqual(advice.action, .repeatTarget)
        XCTAssertEqual(advice.qualifyingSessions, 1)
        XCTAssertNil(advice.usedLegacyRecordKey)
    }

    func testMoreRecentNativeExposureTakesPriorityOverEarlierLegacyFailure() throws {
        let source = try exposure(day: 19), nativePrior = try exposure(day: 18)
        let failed = try evidence(load: 10)
        XCTAssertEqual(advise(source, native: [nativePrior], legacy: [failed]).action, .increase)
        XCTAssertNil(advise(source, native: [nativePrior], legacy: [failed]).usedLegacyRecordKey)
    }

    func testDifferentDifficultyDoseVariantAndEquipmentStayNoncomparable() throws {
        let source = try exposure(day: 19)
        XCTAssertEqual(advise(source, legacy: [try evidence(load: 15)]).action, .repeatTarget)
        var object = try log().object!
        var exercises = object["exercises"]!.object!, exercise = exercises[exerciseID]!.object!
        exercise["variantId"] = .string("other-variant")
        exercises[exerciseID] = .object(exercise); object["exercises"] = .object(exercises)
        XCTAssertEqual(advise(source, legacy: [try evidence(.object(object))]).action, .repeatTarget)
        XCTAssertEqual(advise(try exposure(day: 19, equipment: ["different-machine"]), legacy: [try evidence()]).action, .repeatTarget)
    }

    func testSameDayAndMultipleLegacyGroupingsAreAmbiguous() throws {
        let source = try exposure(day: 19)
        XCTAssertEqual(advise(source, legacy: [try evidence(day: 19)]).qualifyingSessions, 1)
        let first = try evidence(), secondRecord = try record(log(), key: "another-record-same-day")
        let second = try XCTUnwrap(LegacyProgressionEvidence(record: secondRecord, exerciseID: exerciseID))
        XCTAssertEqual(advise(source, legacy: [first, second]).qualifyingSessions, 1)
        XCTAssertEqual(advise(source, native: [try exposure(day: 15)], legacy: [first]).qualifyingSessions, 1)
        XCTAssertEqual(advise(source, legacy: [first, first]).qualifyingSessions, 2)
    }

    func testChangedLegacyFingerprintInvalidatesReviewedAdvice() throws {
        let source = try exposure(day: 19), original = try evidence()
        let advice = advise(source, legacy: [original])
        let changed = try evidence(load: 15)
        XCTAssertThrowsError(try accept(advice, legacy: [changed])) { XCTAssertEqual($0 as? ProgressionError, .staleHistory) }
    }

    func testNewerLegacyResultPreventsAcceptingOlderAdvice() throws {
        let source = try exposure(day: 19), original = try evidence()
        let advice = advise(source, legacy: [original])
        XCTAssertThrowsError(try accept(advice, legacy: [original, evidence(day: 20)])) {
            XCTAssertEqual($0 as? ProgressionError, .staleHistory)
        }
    }

    func testMissingTargetAndUnsupportedIdentityRemainManualEvidence() throws {
        var object = try log().object!
        var exercises = object["exercises"]!.object!, exercise = exercises[exerciseID]!.object!
        exercise.removeValue(forKey: "coachingPlan")
        exercises[exerciseID] = .object(exercise); object["exercises"] = .object(exercises)
        let missing = try evidence(.object(object))
        XCTAssertFalse(missing.isQualified(asOfDate: "2026-09-20"))
        XCTAssertTrue(missing.qualificationIssues.contains { $0.contains("target snapshot") })
        object["planId"] = .string("another-plan")
        let foreign = try evidence(.object(object))
        XCTAssertFalse(foreign.isQualified(asOfDate: "2026-09-20"))
        XCTAssertTrue(advise(try exposure(day: 19), legacy: [foreign]).legacyEvidence.isEmpty)
    }

    func testPendingDraftIsNotASecondCompletedExposure() throws {
        let raw = try log()
        let root: BackupJSONValue = .object([
            "version": .number(1), "settings": .object(["builtInPlanRevision": .number(2)]),
            "workoutLogs": .object(["saved": raw]), "workoutDrafts": .object(["saved": raw]),
            "bodyLogs": .array([]), "sleepLogs": .array([])
        ])
        let stage = try BackupImporter.stage(root.canonicalData(), legacyTimeZoneID: "UTC")
        let entries = stage.records.compactMap { LegacyProgressionEvidence(record: $0, exerciseID: exerciseID) }
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(try XCTUnwrap(entries.first).hasPendingDraft)
        XCTAssertEqual(advise(try exposure(day: 19), legacy: entries).qualifyingSessions, 2)
    }

    func testLegacyEvidenceSurvivesNativeBackupWithoutRenormalization() throws {
        let original = try record(log())
        let roundTrip = try BackupImporter.stage(NativeBackupExporter.export(records: [original])).records
        XCTAssertEqual(try XCTUnwrap(roundTrip.first).fingerprint, original.fingerprint)
        XCTAssertEqual(roundTrip.compactMap { LegacyProgressionEvidence(record: $0, exerciseID: exerciseID) },
                       [try XCTUnwrap(LegacyProgressionEvidence(record: original, exerciseID: exerciseID))])
    }

    private func advise(_ source: ProgressionExposure, native: [ProgressionExposure] = [], legacy: [LegacyProgressionEvidence]) -> ProgressionAdvice {
        ProgressionEngine.advice(for: source, history: native + [source], currentPlanRevisionID: "revision", asOf: now, legacyHistory: legacy)
    }
    private func accept(_ advice: ProgressionAdvice, legacy: [LegacyProgressionEvidence]) throws -> FutureProgressionTarget {
        try ProgressionEngine.accept(advice, currentPlanID: "form-flow", currentPlanRevisionID: "revision",
            currentExercise: advice.source.exercise.prescription, configuration: advice.source.configuration,
            history: [advice.source], enteredLoad: .init(value: 22.5, unit: .kg),
            availableEquipmentLoads: [.init(value: 22.5, unit: .kg)], legacyHistory: legacy, at: now)
    }
    private func log(day: Int = 15, load: Double = 20) throws -> BackupJSONValue {
        .object(["date": .string(String(format: "2026-09-%02d", day)), "planId": .string("form-flow"),
            "response": .object(["scaleVersion": .number(2), "readiness": .string("yes")]),
            "exercises": .object([exerciseID: .object([
                "measurement": .string("weight_reps"),
                "coachingPlan": .object(["kind": .string("strength"), "sets": .number(3), "minReps": .number(6), "maxReps": .number(10), "minRir": .number(2)]),
                "coaching": .object(["technique": .string("yes")]),
                "sets": .array((0..<3).map { _ in .object(["weight": .number(load), "reps": .number(10), "rir": .number(2), "completed": .bool(true)]) })
            ])])])
    }
    private func record(_ log: BackupJSONValue, key: String = "form-flow|2026-09-15") throws -> BackupRecord {
        let root: BackupJSONValue = .object(["version": .number(1), "settings": .object(["builtInPlanRevision": .number(2)]),
            "workoutLogs": .object([key: log]), "bodyLogs": .array([]), "sleepLogs": .array([])])
        return try XCTUnwrap(BackupImporter.stage(root.canonicalData(), legacyTimeZoneID: "UTC").records.first { $0.category == .workouts })
    }
    private func evidence(_ value: BackupJSONValue? = nil, day: Int = 15, load: Double = 20) throws -> LegacyProgressionEvidence {
        try XCTUnwrap(LegacyProgressionEvidence(record: record(value ?? log(day: day, load: load)), exerciseID: exerciseID))
    }
    private func exposure(day: Int, equipment: [String] = []) throws -> ProgressionExposure {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: String(format: "2026-09-%02dT12:00:00Z", day)))
        var exercise = try XCTUnwrap(BuiltInPlans.plan().days.flatMap(\.sessions).flatMap(\.exercises).first { $0.exerciseId == exerciseID })
        exercise.equipment = equipment
        let plan = PlanSession(id: "bench-session", name: "Bench", kind: "strength", estimatedMinutes: 20, exercises: [exercise])
        var session = try WorkoutSession.start(prescription: plan, planID: "form-flow", planRevisionID: "revision",
            ownerDeviceID: "phone", at: start, timeZoneIdentifier: "UTC")
        for set in session.exercises[0].sets {
            let op = WorkoutOperation(session: session, command: .logSet(setID: set.id,
                values: .init(reps: 10, load: .init(value: 20, unit: .kg), rir: 2)), at: start.addingTimeInterval(10))
            session = WorkoutReducer.apply(op, to: session, at: op.createdAt).session
        }
        let finish = WorkoutOperation(session: session, command: .finish(allowPartial: false), at: start.addingTimeInterval(600))
        session = WorkoutReducer.apply(finish, to: session, at: finish.createdAt).session
        let recovery = try SessionRecoveryRecord(sessionID: session.id, phase: .nextMorning,
            day: .init(instant: start.addingTimeInterval(86_400), timeZone: .gmt), readiness: .yes,
            updatedAt: start.addingTimeInterval(86_400))
        return try .init(session: session, exerciseID: session.exercises[0].id,
            configuration: .init(policy: BuiltInProgressionPolicy.strength.reference, optedIn: true),
            answers: .init(technique: .yes), recovery: [recovery])
    }
}
