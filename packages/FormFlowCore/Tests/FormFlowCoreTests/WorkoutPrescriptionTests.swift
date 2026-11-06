import XCTest
@testable import FormFlowCore

final class WorkoutPrescriptionTests: XCTestCase {
    private func timed(_ seconds: Double = 60) -> ExerciseTarget {
        .init(sets: 1, restSeconds: 0, duration: .init(min: seconds, max: seconds, unit: .s))
    }
    private func intervalExercise(id: String = "intervals", repeats: Int = 2) -> PlanExercise {
        .init(instanceId: id, exerciseId: "walk-intervals", name: "Walk intervals", measurement: .duration,
            target: timed(360), intervals: [
                .init(id: "warmup", steps: [.init(id: "warmup", kind: .warmup, measurement: .duration, target: timed())]),
                .init(id: "pairs", repeatCount: repeats, steps: [
                    .init(id: "work", kind: .work, measurement: .duration, target: timed()),
                    .init(id: "easy", kind: .recovery, measurement: .duration, target: timed())]),
                .init(id: "cooldown", steps: [.init(id: "cooldown", kind: .cooldown, measurement: .duration, target: timed())])])
    }
    private func strength() -> PlanExercise {
        .init(instanceId: "squat", exerciseId: "squat", name: "Weighted squat", measurement: .weightReps,
            equipment: ["dumbbell"], target: .init(sets: 3, restSeconds: 90, reps: .init(min: 8, max: 10)),
            alternatives: [.init(id: "bodyweight", exerciseId: "bodyweight-squat", name: "Bodyweight squat", measurement: .reps,
                target: .init(sets: 2, restSeconds: 60, reps: .init(min: 10, max: 12)))])
    }
    private func start(_ exercises: [PlanExercise]) throws -> WorkoutSession {
        try .start(prescription: .init(id: "session", name: "Session", kind: "mixed", estimatedMinutes: 0, exercises: exercises),
            planID: "plan", planRevisionID: "revision", ownerDeviceID: "watch", at: Date(timeIntervalSince1970: 1_800_000_000),
            timeZoneIdentifier: "Asia/Singapore", syncGeneration: "workspace")
    }
    @discardableResult private func apply(_ command: WorkoutCommand, to workout: inout WorkoutSession) -> WorkoutReduction {
        let at = workout.lastAppliedAt.addingTimeInterval(1)
        let result = WorkoutReducer.apply(.init(session: workout, command: command, at: at), to: workout, at: at)
        workout = result.session
        return result
    }
    private func plan(_ exercise: PlanExercise) -> WeeklyPlan {
        .init(id: "plan", name: "Plan", days: [.init(weekday: .monday,
            sessions: [.init(id: "session", name: "Session", kind: "mixed", estimatedMinutes: 0, exercises: [exercise])])])
    }

    func testAlternativeRetainsOriginalAndUsesPerformedTypedValues() throws {
        var workout = try start([strength()]); let original = workout.prescription
        XCTAssertEqual(apply(.chooseAlternative(exerciseID: workout.exercises[0].id, alternativeID: "bodyweight"), to: &workout).status, .applied)
        XCTAssertEqual(workout.prescription, original)
        XCTAssertEqual(workout.exercises[0].prescription, strength())
        XCTAssertEqual(workout.exercises[0].performedPrescription.measurement, .reps)
        XCTAssertEqual(workout.exercises[0].sets.count, 2)
        XCTAssertEqual(workout.exercises[0].selectedAlternativeID, "bodyweight")
        let set = workout.exercises[0].sets[0].id
        XCTAssertEqual(apply(.logSet(setID: set, values: .init(reps: 10, load: .init(value: 5, unit: .kg))), to: &workout).status, .rejected)
        XCTAssertEqual(apply(.logSet(setID: set, values: .init(reps: 10)), to: &workout).status, .applied)
        XCTAssertTrue(WorkoutArchiveValidator.validate(workout).isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutSession.self, from: JSONEncoder().encode(workout)), workout)
    }
    func testVariantCannotRewriteEditedOrPreviouslyLoggedWork() throws {
        var workout = try start([strength()]); let exercise = workout.exercises[0].id, set = workout.exercises[0].sets[0].id
        apply(.logSet(setID: set, values: .init(reps: 8, load: .init(value: 10, unit: .kg))), to: &workout)
        apply(.undoSet(setID: set), to: &workout)
        apply(.updateSet(setID: set, values: .init()), to: &workout)
        XCTAssertEqual(apply(.chooseAlternative(exerciseID: exercise, alternativeID: "bodyweight"), to: &workout).status, .rejected)
        XCTAssertNil(workout.exercises[0].selectedAlternativeID)
    }
    func testOnlyOwnerCanSelectAlternativesOrAddWork() throws {
        let workout = try start([strength()])
        for command in [WorkoutCommand.chooseAlternative(exerciseID: workout.exercises[0].id, alternativeID: "bodyweight"), .addExtraExercise(exercise: intervalExercise())] {
            let operation = WorkoutOperation(session: workout, command: command, originDeviceID: "phone", at: workout.startedAt)
            XCTAssertEqual(WorkoutReducer.apply(operation, to: workout, at: workout.startedAt).status, .rejected)
        }
    }
    func testReplayAllocatesSameSetAndIntervalIdentities() throws {
        let workout = try start([strength()])
        let operation = WorkoutOperation(session: workout, command: .addExtraExercise(exercise: intervalExercise()), at: workout.startedAt)
        let one = WorkoutReducer.apply(operation, to: workout, at: workout.startedAt)
        let two = WorkoutReducer.apply(operation, to: workout, at: workout.startedAt)
        XCTAssertEqual(one, two); XCTAssertEqual(one.status, .applied)
        XCTAssertEqual(WorkoutReducer.apply(operation, to: one.session, at: workout.startedAt).status, .duplicate)
        XCTAssertEqual(one.session.prescription, workout.prescription)
        XCTAssertTrue(try XCTUnwrap(one.session.exercises.last).isAdditional)
        XCTAssertTrue(WorkoutArchiveValidator.validate(one.session).isEmpty)
    }
    func testIntervalExpansionPreservesWarmupRecoveryAndOrderedRepeats() throws {
        let workout = try start([intervalExercise()])
        let intervals = try XCTUnwrap(workout.exercises[0].sets[0].intervals)
        XCTAssertEqual(intervals.map(\.prescription.kind), [.warmup, .work, .recovery, .work, .recovery, .cooldown])
        XCTAssertEqual(intervals.map(\.repetition), [1, 1, 1, 2, 2, 1])
        XCTAssertEqual(Set(intervals.map(\.id)).count, 6)
        XCTAssertTrue(intervals.allSatisfy { $0.actual.isEmpty && $0.status == .planned })
        XCTAssertFalse(workout.hasRecordedWork)
        XCTAssertTrue(WorkoutArchiveValidator.validate(workout).isEmpty)
    }
    func testOuterSetCannotCompleteUntilIntervalsAreResolved() throws {
        var workout = try start([intervalExercise()]); let set = workout.exercises[0].sets[0].id
        XCTAssertEqual(apply(.logSet(setID: set, values: .init(durationSeconds: 360)), to: &workout).status, .rejected)
        for interval in try XCTUnwrap(workout.exercises[0].sets[0].intervals) {
            XCTAssertEqual(apply(.logInterval(setID: set, intervalID: interval.id, values: .init(durationSeconds: 55)), to: &workout).status, .applied)
        }
        XCTAssertTrue(workout.hasRecordedWork); XCTAssertEqual(workout.completedSetCount, 0)
        XCTAssertEqual(workout.completedIntervalCount, 6)
        XCTAssertEqual(apply(.logSet(setID: set, values: .init(durationSeconds: 330)), to: &workout).status, .applied)
        XCTAssertEqual(apply(.finish(allowPartial: false), to: &workout).status, .applied)
        XCTAssertFalse(workout.isPartial); XCTAssertTrue(WorkoutArchiveValidator.validate(workout).isEmpty)
    }
    func testSkippedIntervalRequiresExplicitPartialFinish() throws {
        var workout = try start([intervalExercise()]); let set = workout.exercises[0].sets[0].id
        let intervals = try XCTUnwrap(workout.exercises[0].sets[0].intervals)
        apply(.skipInterval(setID: set, intervalID: intervals[0].id, reason: "Changed today's warmup"), to: &workout)
        for interval in intervals.dropFirst() { apply(.logInterval(setID: set, intervalID: interval.id, values: .init(durationSeconds: 60)), to: &workout) }
        apply(.logSet(setID: set, values: .init(durationSeconds: 300)), to: &workout)
        XCTAssertEqual(apply(.finish(allowPartial: false), to: &workout).status, .rejected)
        XCTAssertEqual(apply(.finish(allowPartial: true), to: &workout).status, .applied)
        XCTAssertTrue(workout.isPartial); XCTAssertTrue(WorkoutArchiveValidator.validate(workout).isEmpty)
    }
    func testFinishedIntervalCorrectionPreservesLifecycleAndCompletionTime() throws {
        var workout = try start([intervalExercise()]); let set = workout.exercises[0].sets[0].id
        let interval = try XCTUnwrap(workout.exercises[0].sets[0].intervals?.first)
        apply(.logInterval(setID: set, intervalID: interval.id, values: .init(durationSeconds: 50)), to: &workout)
        let completion = workout.exercises[0].sets[0].intervals?.first?.completedAt
        apply(.finish(allowPartial: true), to: &workout); let end = workout.endedAt
        XCTAssertEqual(apply(.updateInterval(setID: set, intervalID: interval.id, values: .init(durationSeconds: 55)), to: &workout).status, .applied)
        XCTAssertEqual(workout.endedAt, end); XCTAssertEqual(workout.exercises[0].sets[0].intervals?.first?.completedAt, completion)
        XCTAssertNil(workout.rest); XCTAssertTrue(WorkoutArchiveValidator.validate(workout).isEmpty)
    }
    func testCopyLastClearsIntervalResultsAndPreservesPlannedStructure() throws {
        var previous = try start([intervalExercise()]); let set = previous.exercises[0].sets[0].id
        let interval = try XCTUnwrap(previous.exercises[0].sets[0].intervals?.first)
        apply(.logInterval(setID: set, intervalID: interval.id, values: .init(durationSeconds: 55, rpe: 5)), to: &previous)
        var next = try start([intervalExercise()]); let ids = next.exercises[0].sets[0].intervals?.map(\.id)
        apply(.copyLast(exerciseID: next.exercises[0].id, previous: previous.exercises[0]), to: &next)
        XCTAssertEqual(next.exercises[0].sets[0].intervals?.map(\.id), ids)
        XCTAssertTrue(next.exercises[0].sets[0].intervals?.allSatisfy { $0.actual.isEmpty && $0.status == .planned } == true)
    }
    func testBoundsRejectExcessiveAlternativesAndIntervalsBeforeAllocation() throws {
        var exercise = intervalExercise(repeats: Int.max)
        XCTAssertThrowsError(try start([exercise]))
        XCTAssertTrue(PlanValidator.validate(plan(exercise)).contains { $0.severity == .error })
        exercise = strength(); exercise.alternatives = Array(repeating: try XCTUnwrap(exercise.alternatives?.first), count: 7)
        XCTAssertTrue(PlanValidator.validate(plan(exercise)).contains { $0.path.contains("alternatives") && $0.severity == .error })
        var base = intervalExercise(repeats: 100)
        base.intervals = [.init(id: "large", repeatCount: 100, steps: (1...4).map {
            .init(id: "step-\($0)", kind: .work, measurement: .duration, target: timed())
        })]
        let exercises = (1...6).map { i -> PlanExercise in var value = base; value.instanceId = "activity-\(i)"; return value }
        XCTAssertThrowsError(try start(exercises))
        XCTAssertEqual(try start(Array(exercises.prefix(5))).exercises.flatMap(\.sets).flatMap { $0.intervals ?? [] }.count, 2_000)
    }
    func testTypedIntervalAndAlternativeImportRoundTripRejectsNestedUnknownFields() throws {
        let value = plan(intervalExercise())
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        XCTAssertTrue(PlanImporter.importText(json).canActivate)
        XCTAssertEqual(PlanImporter.importText(json).plan, value)
        let unsupported = json.replacingOccurrences(of: "\"repeatCount\":2", with: "\"repeatCount\":2,\"script\":\"arbitrary\"")
        XCTAssertFalse(PlanImporter.importText(unsupported).canActivate)
        let recursive = String(decoding: try JSONEncoder().encode(plan(strength())), as: UTF8.self)
            .replacingOccurrences(of: "\"id\":\"bodyweight\"", with: "\"id\":\"bodyweight\",\"alternatives\":[]")
        XCTAssertFalse(PlanImporter.importText(recursive).canActivate)
    }
    func testOldSnapshotsDecodeAbsentNewFieldsAndRejectForgedVariantOrInterval() throws {
        let old = try start([.init(instanceId: "walk", exerciseId: "walk", name: "Walk", measurement: .duration, target: timed())])
        let data = try JSONEncoder().encode(old)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutSession.self, from: data), old)
        var forged = try start([strength()]); forged.exercises[0].selectedAlternativeID = "not-prescribed"
        XCTAssertFalse(WorkoutArchiveValidator.validate(forged).isEmpty)
        var intervals = try start([intervalExercise()])
        intervals.exercises[0].sets[0].intervals?.removeLast()
        XCTAssertFalse(WorkoutArchiveValidator.validate(intervals).isEmpty)
    }
}
