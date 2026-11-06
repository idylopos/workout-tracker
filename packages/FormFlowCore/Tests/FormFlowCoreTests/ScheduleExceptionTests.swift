import XCTest
@testable import FormFlowCore

final class ScheduleExceptionTests: XCTestCase {
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = .gmt; return value }
    private func date(_ value: String) -> Date { ScheduleExceptionSchedule.date(value, calendar: calendar)! }
    private func day(_ value: String, zone: String = "GMT") throws -> LocalTrainingDay { try .init(date: value, timeZoneID: zone) }
    private var activation: Date { date("2026-09-14") }
    private var now: Date { date("2026-09-18") }
    private func plan() throws -> WeeklyPlan { try XCTUnwrap(PlanImporter.importText(PlanContract.exampleJSON).plan) }
    private func occurrence(_ iso: String = "2026-09-21", exceptions: [ScheduleException] = [], workouts: [WorkoutSession] = []) throws -> ScheduleOccurrence {
        let plan = try plan(), session = plan.days.first { $0.weekday == .monday }!.sessions[0]
        return try XCTUnwrap(ScheduleExceptionSchedule.resolve(
            occurrenceID: ScheduleExceptionSchedule.occurrenceID(planID: plan.id, originalDay: iso, sessionID: session.id),
            plan: plan, activationDate: activation, exceptions: exceptions, workouts: workouts, asOf: now, calendar: calendar))
    }
    private func change(_ entry: ScheduleOccurrence, action: ScheduleExceptionAction = .rescheduled,
                        to: String? = nil, exceptions: [ScheduleException] = [], workouts: [WorkoutSession] = [], pending: Set<String> = []) throws -> ScheduleException {
        try ScheduleExceptionSchedule.change(entry, action: action, destination: to.map { try day($0, zone: entry.originalDay.timeZoneID) },
            plan: plan(), planRevisionID: "revision-one", activationDate: activation, exceptions: exceptions, workouts: workouts,
            pendingWatchOccurrenceIDs: pending, at: now, calendar: calendar)
    }
    private func entries(_ from: String, _ through: String, exceptions: [ScheduleException] = [], workouts: [WorkoutSession] = []) throws -> [ScheduleOccurrence] {
        try ScheduleExceptionSchedule.occurrences(plan: plan(), activationDate: activation, from: date(from), through: date(through),
            exceptions: exceptions, workouts: workouts, asOf: now, calendar: calendar)
    }

    func testMoveRetainsIdentityAndAppearsOnlyOnDestination() throws {
        let original = try occurrence(), moved = try change(original, to: "2026-09-23")
        XCTAssertFalse(try entries("2026-09-21", "2026-09-21", exceptions: [moved]).contains { $0.id == original.id })
        let week = try entries("2026-09-18", "2026-09-25", exceptions: [moved])
        let slot = try XCTUnwrap(week.first { $0.id == original.id })
        XCTAssertEqual(week.filter { $0.id == original.id }.count, 1)
        XCTAssertEqual(slot.scheduled.date, date("2026-09-23"))
        XCTAssertEqual(slot.originalDay.date, "2026-09-21")
        XCTAssertTrue(slot.canStart)
    }

    func testMovedInOriginalOutsideVisibleWindowIsIncluded() throws {
        let distant = try occurrence("2026-10-19"), moved = try change(distant, to: "2026-09-20")
        let result = try entries("2026-09-18", "2026-09-20", exceptions: [moved])
        XCTAssertEqual(result.filter { $0.id == distant.id }.map(\.effectiveDay.date), ["2026-09-20"])
    }

    func testElapsedDateNeedsReviewAndMissedIsExplicit() throws {
        let past = try occurrence("2026-09-14")
        XCTAssertEqual(past.status, .needsReview)
        XCTAssertNil(past.exception)
        let missed = try change(past, action: .missed)
        XCTAssertEqual(try occurrence("2026-09-14", exceptions: [missed]).status, .missed)
        XCTAssertThrowsError(try change(occurrence(), action: .missed)) { XCTAssertEqual($0 as? ScheduleExceptionError, .notYetMissed) }
    }

    func testSkipMovedOccurrenceKeepsDestinationAndRestoreKeepsTombstone() throws {
        let original = try occurrence(), moved = try change(original, to: "2026-09-23")
        let skipped = try change(occurrence(exceptions: [moved]), action: .skipped, exceptions: [moved])
        XCTAssertEqual(skipped.destinationDay?.date, "2026-09-23")
        XCTAssertEqual(try occurrence(exceptions: [skipped]).status, .skipped)
        XCTAssertFalse(try ScheduleExceptionSchedule.upcoming(plan: plan(), activationDate: activation, from: now,
            exceptions: [skipped], calendar: calendar).contains { $0.id == original.id })
        let restored = try change(occurrence(exceptions: [skipped]), action: .restored, exceptions: [skipped])
        XCTAssertEqual(restored.action, .restored)
        XCTAssertNil(restored.destinationDay)
        XCTAssertEqual(try occurrence(exceptions: [restored]).scheduled.date, original.scheduled.date)
    }

    func testCollisionRejectsSameSessionButPermitsOtherSession() throws {
        let original = try occurrence()
        XCTAssertThrowsError(try change(original, to: "2026-09-28")) { XCTAssertEqual($0 as? ScheduleExceptionError, .collision) }
        let next = try occurrence("2026-09-28"), skipped = try change(next, action: .skipped)
        XCTAssertNoThrow(try change(original, to: "2026-09-28", exceptions: [skipped]))
        // The example has another session on Thursday. Different sessions may share a day.
        XCTAssertNoThrow(try change(original, to: "2026-09-24"))
    }

    func testStaleOpenOccurrenceAndPendingWatchStartCannotOverwriteSchedule() throws {
        let original = try occurrence(), moved = try change(original, to: "2026-09-23")
        XCTAssertThrowsError(try change(original, action: .skipped, exceptions: [moved])) { XCTAssertEqual($0 as? ScheduleExceptionError, .staleOccurrence) }
        XCTAssertThrowsError(try change(original, action: .skipped, pending: [original.id])) { XCTAssertEqual($0 as? ScheduleExceptionError, .pendingWatchStart) }
    }

    func testRecordedAndAbandonedWorkoutsBlockScheduleEditsWithoutChangingHistory() throws {
        let original = try occurrence(), plan = try plan()
        var workout = try WorkoutSession.start(prescription: original.scheduled.session, planID: plan.id, planRevisionID: "revision-one",
            scheduledSessionID: original.id, ownerDeviceID: "phone", at: now, timeZoneIdentifier: "GMT")
        let active = try occurrence(workouts: [workout])
        XCTAssertEqual(active.status, .inProgress)
        XCTAssertThrowsError(try change(active, action: .skipped, workouts: [workout])) { XCTAssertEqual($0 as? ScheduleExceptionError, .recordedOccurrence) }
        let operation = WorkoutOperation(session: workout, command: .abandon, at: now.addingTimeInterval(10))
        workout = WorkoutReducer.apply(operation, to: workout, at: operation.createdAt).session
        let abandoned = try occurrence(workouts: [workout])
        XCTAssertEqual(abandoned.status, .abandoned)
        XCTAssertFalse(abandoned.canStart)
        XCTAssertThrowsError(try change(abandoned, to: "2026-09-23", workouts: [workout]))
        XCTAssertEqual(workout.scheduledSessionID, original.id)
        XCTAssertEqual(workout.prescription, original.scheduled.session)
    }

    func testBadIdentityDuplicateRecordsAndInvalidRangesFailClosed() throws {
        let original = try occurrence(), skipped = try change(original, action: .skipped)
        XCTAssertNil(try ScheduleExceptionSchedule.resolve(occurrenceID: "same-session", plan: plan(), activationDate: activation, calendar: calendar))
        XCTAssertNil(try ScheduleExceptionSchedule.resolve(occurrenceID: original.id.replacingOccurrences(of: "9-21", with: "09-21"), plan: plan(), activationDate: activation, calendar: calendar))
        XCTAssertThrowsError(try entries("2026-09-18", "2026-09-25", exceptions: [skipped, skipped]))
        XCTAssertThrowsError(try entries("2026-09-18", "2027-09-19"))
        XCTAssertThrowsError(try change(original, to: "2026-09-17"))
        XCTAssertThrowsError(try change(original, to: "2027-09-19"))
    }

    func testNewActivationSuppressesOlderExceptionAndUnrelatedPlanRevisionRetainsIt() throws {
        let original = try occurrence(), moved = try change(original, to: "2026-09-23")
        XCTAssertNil(try ScheduleExceptionSchedule.resolve(occurrenceID: original.id, plan: plan(), activationDate: date("2026-09-22"), exceptions: [moved], calendar: calendar))
        var renamed = try plan(); renamed.name = "Renamed plan"
        XCTAssertEqual(try ScheduleExceptionSchedule.resolve(occurrenceID: original.id, plan: renamed, activationDate: activation,
            exceptions: [moved], calendar: calendar)?.effectiveDay.date, "2026-09-23")
    }

    func testTravelAndDaylightSavingPreserveSelectedLocalDateAndOriginalID() throws {
        var newYork = calendar; newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let plan = try plan(), session = plan.days.first { $0.weekday == .monday }!.sessions[0]
        let id = ScheduleExceptionSchedule.occurrenceID(planID: plan.id, originalDay: "2026-11-02", sessionID: session.id)
        let moved = try ScheduleException(occurrenceID: id, planID: plan.id, planRevisionID: "revision-one", sessionID: session.id,
            originalDay: day("2026-11-02", zone: "America/New_York"), destinationDay: day("2026-11-01", zone: "America/New_York"), action: .rescheduled)
        for zone in ["America/New_York", "Asia/Singapore"] {
            var local = calendar; local.timeZone = TimeZone(identifier: zone)!
            let entry = try XCTUnwrap(ScheduleExceptionSchedule.resolve(occurrenceID: id, plan: plan, activationDate: activation, exceptions: [moved], asOf: now, calendar: local))
            XCTAssertEqual(entry.id, id)
            XCTAssertEqual(LocalTrainingDay(instant: entry.scheduled.date, timeZone: local.timeZone).date, "2026-11-01")
            XCTAssertEqual(local.component(.hour, from: entry.scheduled.date), 0)
            XCTAssertEqual(entry.originalDay.timeZoneID, "America/New_York")
        }
    }

    func testUpcomingMatchesUnchangedScheduleAndSearchesPastSkippedWindows() throws {
        let plan = try plan()
        let baseline = PlanSchedule.upcoming(plan: plan, activationDate: activation, from: now, limit: 8, calendar: calendar)
        XCTAssertEqual(try ScheduleExceptionSchedule.upcoming(plan: plan, activationDate: activation, from: now, limit: 8, calendar: calendar), baseline.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date })
        let firstMonth = try entries("2026-09-18", "2026-10-16")
        let skips = try firstMonth.map { try change($0, action: .skipped) }
        let next = try ScheduleExceptionSchedule.upcoming(plan: plan, activationDate: activation, from: now, limit: 3, exceptions: skips, calendar: calendar)
        XCTAssertEqual(next.count, 3)
        XCTAssertTrue(next.allSatisfy { $0.date > date("2026-10-16") })
        XCTAssertEqual(Set(next.map(\.id)).count, 3)
    }
}
