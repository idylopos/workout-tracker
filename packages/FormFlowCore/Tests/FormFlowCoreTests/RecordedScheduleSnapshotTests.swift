import XCTest
@testable import FormFlowCore

final class RecordedScheduleSnapshotTests: XCTestCase {
    func testAllRecordedStatesOccupyTheirSlotAcrossBothOwnersAndExcludeOldGeneration() throws {
        var sessions: [WorkoutSession] = []
        for (index, state) in [WorkoutState.active, .paused, .finished, .abandoned].enumerated() {
            var session = try workout(day: 14 + index, owner: index.isMultiple(of: 2) ? "phone" : "watch")
            session.state = state; sessions.append(session)
        }
        let old = try workout(day: 18, owner: "watch", generation: "old")
        let snapshot = try RecordedScheduleSnapshot.build(workouts: sessions + [old], planID: "plan", syncGeneration: "generation")
        XCTAssertEqual(snapshot.count, 4)
        XCTAssertEqual(Set(snapshot.map(\.state)), [.active, .paused, .finished, .abandoned])
        XCTAssertFalse(snapshot.contains { $0.id == old.scheduledSessionID })
        XCTAssertTrue(RecordedScheduleSnapshot.validate(snapshot, planID: "plan").isEmpty)
    }
    func testDuplicateRecordsStillOccupyOneStableSlotRegardlessOfInputOrder() throws {
        var finished = try workout(day: 14, owner: "phone"); finished.state = .finished
        let active = try workout(day: 14, owner: "watch")
        let first = try RecordedScheduleSnapshot.build(workouts: [finished, active], planID: "plan", syncGeneration: "generation")
        let second = try RecordedScheduleSnapshot.build(workouts: [active, finished], planID: "plan", syncGeneration: "generation")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, [.init(id: "plan:2026-9-14:session", state: .active)])
    }
    func testMalformedAndWrongPlanSnapshotsAreRejected() {
        XCTAssertFalse(RecordedScheduleSnapshot.validate([.init(id: "other:2026-9-14:session", state: .finished)], planID: "plan").isEmpty)
        XCTAssertFalse(RecordedScheduleSnapshot.validate([.init(id: "plan:2026-2-31:session", state: .finished)], planID: "plan").isEmpty)
        let duplicated = RecordedScheduleOccurrence(id: "plan:2026-9-14:session", state: .finished)
        XCTAssertFalse(RecordedScheduleSnapshot.validate([duplicated, duplicated], planID: "plan").isEmpty)
    }
    func testExplicitFutureSelectionCanStartButMovedOrOccupiedSelectionCannot() throws {
        let prescription = PlanSession(id: "session", name: "Session", kind: "strength", estimatedMinutes: 20,
            exercises: [.init(instanceId: "exercise", exerciseId: "exercise", name: "Exercise", measurement: .reps,
                target: .init(sets: 1, restSeconds: 0, reps: .init(min: 8, max: 8)))])
        let plan = WeeklyPlan(id: "plan", name: "Plan", days: [.init(weekday: .monday, sessions: [prescription])])
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = try XCTUnwrap(ScheduleExceptionSchedule.date("2026-09-11", calendar: calendar))
        let slot = try XCTUnwrap(PlanSchedule.upcoming(plan: plan, activationDate: today, from: today, limit: 1, calendar: calendar).first)
        let occurrence = try XCTUnwrap(ScheduleExceptionSchedule.resolve(occurrenceID: slot.id, plan: plan, activationDate: today, asOf: today, calendar: calendar))
        let intent = RemoteWorkoutStartIntent(syncGeneration: "generation", planID: plan.id, planRevisionID: "revision", prescriptionID: prescription.id,
            scheduledSessionID: slot.id, scheduledDay: LocalTrainingDay(instant: slot.date, timeZone: calendar.timeZone), requestedAt: today)
        XCTAssertGreaterThan(slot.date, today)
        XCTAssertTrue(RemoteWorkoutStartResolver.matchesScheduledOccurrence(intent, occurrence: occurrence))
        XCTAssertFalse(RemoteWorkoutStartResolver.matchesScheduledOccurrence(intent, occurrence: occurrence, occupiedIDs: [slot.id]))
        let moved = try ScheduleExceptionSchedule.change(occurrence, action: .rescheduled,
            destination: LocalTrainingDay(date: "2026-09-15", timeZoneID: "GMT"), plan: plan, planRevisionID: "revision",
            activationDate: today, exceptions: [], workouts: [], at: today, calendar: calendar)
        let newOccurrence = try XCTUnwrap(ScheduleExceptionSchedule.resolve(occurrenceID: slot.id, plan: plan, activationDate: today,
            exceptions: [moved], asOf: today, calendar: calendar))
        XCTAssertFalse(RemoteWorkoutStartResolver.matchesScheduledOccurrence(intent, occurrence: newOccurrence))
        let missingDate = RemoteWorkoutStartIntent(syncGeneration: "generation", planID: plan.id, planRevisionID: "revision",
            prescriptionID: prescription.id, scheduledSessionID: slot.id, requestedAt: today)
        XCTAssertFalse(RemoteWorkoutStartResolver.matchesScheduledOccurrence(missingDate, occurrence: occurrence))
    }
    private func workout(day: Int, owner: String, generation: String = "generation") throws -> WorkoutSession {
        let exercise = PlanExercise(instanceId: "exercise", exerciseId: "exercise", name: "Exercise", measurement: .reps,
            target: .init(sets: 1, restSeconds: 0, reps: .init(min: 8, max: 8)))
        let session = PlanSession(id: "session", name: "Session", kind: "strength", estimatedMinutes: 20, exercises: [exercise])
        return try WorkoutSession.start(prescription: session, planID: "plan", planRevisionID: "revision",
            scheduledSessionID: "plan:2026-9-\(day):session", ownerDeviceID: owner,
            at: Date(timeIntervalSince1970: 1_789_344_000), timeZoneIdentifier: "UTC", syncGeneration: generation)
    }
}
