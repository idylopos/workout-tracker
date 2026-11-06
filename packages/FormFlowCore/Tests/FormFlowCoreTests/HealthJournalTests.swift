import XCTest
@testable import FormFlowCore

final class HealthJournalTests: XCTestCase {
    let workoutID = UUID()
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    func prepared() throws -> HealthJournal {
        var journal = HealthJournal()
        try journal.prepare(workoutID: workoutID, generation: "workspace", ownerDeviceID: "watch",
                            localDeviceID: "watch", at: date)
        return journal
    }
    func move(_ journal: inout HealthJournal, to state: HealthExportState, id: UUID? = nil) throws {
        try journal.transition(workoutID: workoutID, generation: "workspace", localDeviceID: "watch",
                               to: state, at: date, healthWorkoutID: id)
    }
    func saving() throws -> HealthJournal {
        var journal = try prepared()
        try move(&journal, to: .recording); try move(&journal, to: .saving)
        return journal
    }

    func testSuccessfulExportRetainsHealthIdentityAcrossCoding() throws {
        var journal = try saving(); let healthID = UUID()
        try move(&journal, to: .saved, id: healthID)
        let restored = try JSONDecoder().decode(HealthJournal.self, from: JSONEncoder().encode(journal))
        XCTAssertEqual(restored, journal); XCTAssertTrue(restored.validate())
        XCTAssertEqual(restored.entries.first?.healthWorkoutID, healthID)
    }
    func testPhoneCannotPrepareWatchExport() {
        var journal = HealthJournal()
        XCTAssertThrowsError(try journal.prepare(workoutID: workoutID, generation: "workspace", ownerDeviceID: "watch", localDeviceID: "phone", at: date))
        XCTAssertTrue(journal.entries.isEmpty)
    }
    func testPhoneCannotChangeWatchExport() throws {
        var journal = try prepared(); let previous = journal
        XCTAssertThrowsError(try journal.transition(workoutID: workoutID, generation: "workspace", localDeviceID: "phone", to: .recording, at: date))
        XCTAssertEqual(journal, previous)
    }
    func testSavingRequiresDurableRecordingIntent() throws {
        var journal = try prepared()
        XCTAssertThrowsError(try move(&journal, to: .saving))
        XCTAssertThrowsError(try move(&journal, to: .saved, id: UUID()))
    }
    func testCrashAfterSaveCannotBlindlyRetry() throws {
        var journal = try saving()
        try move(&journal, to: .pendingVerification)
        XCTAssertThrowsError(try move(&journal, to: .prepared))
        XCTAssertThrowsError(try move(&journal, to: .failedBeforeSave))
        XCTAssertThrowsError(try journal.prepare(workoutID: workoutID, generation: "workspace", ownerDeviceID: "watch", localDeviceID: "watch", at: date))
    }
    func testEmptyQueryDoesNotProveNoSave() throws {
        var journal = try saving()
        for _ in 0..<100 {
            try journal.reconcile(workoutID: workoutID, generation: "workspace", localDeviceID: "watch", matches: [], at: date)
        }
        XCTAssertEqual(journal.entries.first?.state, .pendingVerification)
        XCTAssertNil(journal.entries.first?.healthWorkoutID)
    }
    func testMatchingQueryReconcilesCrashWindow() throws {
        var journal = try saving(); let healthID = UUID()
        try journal.reconcile(workoutID: workoutID, generation: "workspace", localDeviceID: "watch", matches: [healthID], at: date)
        XCTAssertEqual(journal.entries.first?.state, .saved)
        XCTAssertEqual(journal.entries.first?.healthWorkoutID, healthID)
    }
    func testConflictingQueryRemainsUnresolved() throws {
        var journal = try saving()
        try journal.reconcile(workoutID: workoutID, generation: "workspace", localDeviceID: "watch", matches: [UUID(), UUID()], at: date)
        XCTAssertEqual(journal.entries.first?.state, .pendingVerification)
    }
    func testKnownPreSaveFailureCanRetrySameCorrelation() throws {
        var journal = try prepared(); let id = journal.entries.first?.correlationID
        try move(&journal, to: .failedBeforeSave)
        try journal.prepare(workoutID: workoutID, generation: "workspace", ownerDeviceID: "watch", localDeviceID: "watch", at: date)
        XCTAssertEqual(journal.entries.count, 1); XCTAssertEqual(journal.entries.first?.correlationID, id)
        XCTAssertEqual(journal.entries.first?.state, .prepared)
    }
    func testSavedAndDiscardedAreTerminal() throws {
        var journal = try saving()
        try move(&journal, to: .saved, id: UUID())
        for state in [HealthExportState.prepared, .recording, .saving, .discarded, .pendingVerification, .saved] {
            XCTAssertThrowsError(try move(&journal, to: state, id: state == .saved ? UUID() : nil))
        }
        var discarded = try prepared(); try move(&discarded, to: .discarded)
        XCTAssertThrowsError(try move(&discarded, to: .prepared))
    }
    func testGenerationCannotMutateAnotherJournalEntry() throws {
        var journal = try prepared()
        XCTAssertThrowsError(try journal.transition(workoutID: workoutID, generation: "reset", localDeviceID: "watch", to: .recording, at: date))
    }
    func testUntrustedUnknownVersionAndDuplicateEntryRejected() throws {
        let journal = try prepared()
        let data = try JSONEncoder().encode(journal)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 999
        XCTAssertFalse(try JSONDecoder().decode(HealthJournal.self, from: JSONSerialization.data(withJSONObject: object)).validate())
        object["version"] = 1
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        object["entries"] = entries + entries
        XCTAssertFalse(try JSONDecoder().decode(HealthJournal.self, from: JSONSerialization.data(withJSONObject: object)).validate())
    }
}
