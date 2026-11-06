import XCTest
@testable import FormFlowCore

final class RecoveryTests: XCTestCase {
    func testLegacyPainScaleParityAndUnknown() {
        XCTAssertEqual([0.0, 3, 5, 7, 10].map { LegacyRecovery.rating($0) }, [0, 1, 2, 3, 4])
        XCTAssertEqual(LegacyRecovery.rating(3, scaleVersion: 2), 3)
        XCTAssertNil(LegacyRecovery.rating(nil)); XCTAssertNil(LegacyRecovery.rating(.infinity))
        XCTAssertEqual(LegacyRecovery.readiness(rating: nil, explicit: nil), .unknown)
        XCTAssertEqual(LegacyRecovery.readiness(rating: 0, explicit: .unknown), .unknown)
        XCTAssertEqual(LegacyRecovery.readiness(rating: 3, explicit: .yes), .no)
    }
    func testRecoveryPromptsLinkToSessionAndRetainUnknownAnswers() throws {
        let sessionID = UUID()
        let ended = date("2026-09-17T08:00:00Z") // 16:00 in Singapore
        let anchor = RecoverySessionAnchor(sessionID: sessionID, endedAt: ended, timeZoneID: "Asia/Singapore")
        XCTAssertTrue(RecoverySchedule.due(sessions: [anchor], answers: [], now: date("2026-09-17T09:59:00Z")).isEmpty)
        XCTAssertEqual(RecoverySchedule.due(sessions: [anchor], answers: [], now: date("2026-09-17T10:00:00Z")).first?.phase, .evening)
        let next = date("2026-09-17T23:00:00Z")
        let prompts = RecoverySchedule.due(sessions: [anchor], answers: [], now: next)
        XCTAssertEqual(prompts.map(\.phase), [.nextMorning]); XCTAssertEqual(prompts.first?.sessionID, sessionID)
        let answer = try SessionRecoveryRecord(sessionID: sessionID, phase: .nextMorning,
                                              day: .init(instant: next, timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Singapore"))),
                                              rating: 0, readiness: .unknown)
        XCTAssertEqual(answer.effectiveReadiness, .unknown)
        XCTAssertTrue(RecoverySchedule.due(sessions: [anchor], answers: [answer], now: next).isEmpty)
    }
    func testRecoveryEditsKeepIdentityAndCannotInferNextMorningFromEvening() throws {
        let id = UUID(), sessionID = UUID()
        let day = try LocalTrainingDay(date: "2026-09-17", timeZoneID: "UTC")
        var record = try SessionRecoveryRecord(id: id, sessionID: sessionID, phase: .evening, day: day, rating: 0, readiness: .yes)
        try record.edit(day: day, rating: 3, readiness: .yes, notes: "Updated answer")
        XCTAssertEqual(record.id, id); XCTAssertEqual(record.effectiveReadiness, .no)
        let prompts = RecoverySchedule.due(sessions: [.init(sessionID: sessionID, endedAt: date("2026-09-17T15:00:00Z"), timeZoneID: "UTC")], answers: [record], now: date("2026-09-18T08:00:00Z"))
        XCTAssertEqual(prompts.map(\.phase), [.nextMorning])
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
}
