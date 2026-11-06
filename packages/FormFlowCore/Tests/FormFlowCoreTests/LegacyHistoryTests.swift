import XCTest
@testable import FormFlowCore

final class LegacyHistoryTests: XCTestCase {
    func testMigratedMetersAndMissingActualsStayDistinct() throws {
        let record = BackupRecord(id: "day", category: .workouts, payload: .object([
            "legacyTimeZoneAssumption": .string("Asia/Singapore"),
            "pendingDraft": .object([:]),
            "log": .object(["date": .string("2026-09-18"), "nativeNormalizationVersion": .number(1),
                "planId": .string("unavailable-plan"), "exercises": .object([
                    "carry": .object(["measurement": .string("weight_distance"), "sets": .array([
                        .object(["completed": .bool(true), "distance": .number(25), "nativeDistanceMeters": .number(25)]),
                        .object(["completed": .bool(false)])
                    ])])])])]))
        let summary = try XCTUnwrap(LegacyWorkoutSummary(record: record))
        XCTAssertEqual(summary.completedSetCount, 1)
        XCTAssertTrue(summary.hasPendingDraft)
        XCTAssertEqual(summary.planID, "unavailable-plan")
        XCTAssertEqual(summary.exercises[0].sets[0].actual.distance, .init(value: 25, unit: .m))
        XCTAssertNil(summary.exercises[0].sets[0].actual.load)
        XCTAssertTrue(summary.exercises[0].sets[1].actual.isEmpty)
    }

    func testRawUnmigratedRecordsAreNotReinterpreted() {
        let record = BackupRecord(id: "day", category: .workouts, payload: .object([
            "log": .object(["date": .string("2026-09-18"), "exercises": .object([:])])]))
        XCTAssertNil(LegacyWorkoutSummary(record: record))
    }

    func testReadingSummaryNeverMarksDraftValuesCompleted() throws {
        let record = BackupRecord(id: "day", category: .workouts, payload: .object([
            "log": .object(["date": .string("2026-09-18"), "nativeNormalizationVersion": .number(1),
                "exercises": .object(["cycle": .object(["measurement": .string("duration"), "sets": .array([
                    .object(["minutes": .number(5), "seconds": .number(30), "averageHeartRate": .number(130)])
                ])])])])]))
        let summary = try XCTUnwrap(LegacyWorkoutSummary(record: record))
        XCTAssertEqual(summary.completedSetCount, 0)
        XCTAssertEqual(summary.exercises[0].sets[0].actual.durationSeconds, 330)
        XCTAssertEqual(summary.exercises[0].sets[0].actual.averageHeartRate, 130)
    }
}
