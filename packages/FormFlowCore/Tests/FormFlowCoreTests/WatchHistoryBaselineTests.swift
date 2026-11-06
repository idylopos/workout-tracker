import XCTest
@testable import FormFlowCore

final class WatchHistoryBaselineTests: XCTestCase {
    func testTwoRecentRelevantExposuresKeepActualUnitsAndExcludeOpenAbandonedOldWorkspace() throws {
        let plan = plan()
        let oldest = try workout(plan, offset: 0, load: 10)
        let middle = try workout(plan, offset: 100, load: 20)
        let newest = try workout(plan, offset: 200, load: 30)
        var abandoned = try workout(plan, offset: 300, load: 40); abandoned.state = .abandoned
        var open = try workout(plan, offset: 400, load: 50); open.state = .active
        let oldGeneration = try workout(plan, offset: 500, load: 60, generation: "old")
        let baseline = try WatchHistoryBaselineBuilder.build(plan: plan,
            workouts: [oldest, middle, newest, abandoned, open, oldGeneration], syncGeneration: "generation")
        XCTAssertEqual(baseline.exposures.map(\.workoutID), [newest.id, middle.id])
        XCTAssertEqual(baseline.exposures.first?.actuals.first?.values.load, .init(value: 30, unit: .lb))
        XCTAssertEqual(baseline.exposures.first?.actuals.first?.values.reps, 8)
        XCTAssertEqual(baseline.exposures.first?.actuals.first?.values.rir, 2)
        XCTAssertTrue(WatchHistoryBaselineBuilder.validate(baseline).isEmpty)
        let text = String(decoding: try JSONEncoder().encode(baseline), as: UTF8.self)
        XCTAssertFalse(text.contains("target")); XCTAssertFalse(text.contains("operationReceipts"))
        XCTAssertFalse(text.contains("ownerDeviceID")); XCTAssertFalse(text.contains("instructions"))
    }

    func testAlternativeIdentityAndEquipmentMustBothMatch() throws {
        var plan = plan()
        var exercise = plan.days[0].sessions[0].exercises[0]
        exercise.alternatives = [PlanAlternative(id: "dumbbells", exerciseId: exercise.exerciseId, name: exercise.name,
            measurement: .weightReps, equipment: ["dumbbells"], target: exercise.target)]
        plan.days[0].sessions[0].exercises[0] = exercise
        let original = try workout(plan, offset: 0)
        let alternative = try workout(plan, offset: 100, alternativeID: "dumbbells")
        let baseline = try WatchHistoryBaselineBuilder.build(plan: plan, workouts: [alternative, original], syncGeneration: "generation")
        XCTAssertEqual(baseline.exposures.count, 2)
        let matches = baseline.previous(for: alternative.exercises[0], excluding: UUID())
        XCTAssertEqual(matches.map(\.workoutID), [alternative.id])
        XCTAssertEqual(matches.first?.selectedAlternativeID, "dumbbells")
        XCTAssertEqual(matches.first?.equipment, ["dumbbells"])
        XCTAssertTrue(baseline.previous(for: alternative.exercises[0], excluding: alternative.id).isEmpty)
    }

    func testPartialHistoryIncludesOnlyCompletedActualsNeverRemainingTargets() throws {
        let plan = plan(sets: 2)
        let workout = try workout(plan)
        let baseline = try WatchHistoryBaselineBuilder.build(plan: plan, workouts: [workout], syncGeneration: "generation")
        XCTAssertTrue(try XCTUnwrap(baseline.exposures.first).wasPartial)
        XCTAssertEqual(baseline.exposures.first?.completedObservationCount, 1)
        XCTAssertEqual(baseline.exposures.first?.actuals.count, 1)
        XCTAssertEqual(baseline.exposures.first?.actuals.first?.values.load?.value, 10)
    }

    func testCompletedIntervalsStaySeparateAndSensitiveSupplementalMetricsAreOmitted() throws {
        let step = PlanIntervalStep(id: "work", kind: .work, measurement: .distanceTime,
            target: .init(sets: 1, restSeconds: 0, duration: .init(min: 60, max: 60, unit: .s)))
        let exercise = PlanExercise(instanceId: "run", exerciseId: "run", name: "Run", measurement: .distanceTime,
            target: .init(sets: 1, restSeconds: 0, duration: .init(min: 120, max: 120, unit: .s)),
            intervals: [.init(id: "rounds", repeatCount: 2, steps: [step])])
        let session = PlanSession(id: "session", name: "Run", kind: "cardio", estimatedMinutes: 5, exercises: [exercise])
        let plan = WeeklyPlan(id: "plan", name: "Plan", days: [.init(weekday: .monday, sessions: [session])])
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var workout = try WorkoutSession.start(prescription: session, planID: plan.id, planRevisionID: "revision",
            ownerDeviceID: "phone", at: date, timeZoneIdentifier: "UTC", syncGeneration: "generation")
        let set = try XCTUnwrap(workout.exercises.first?.sets.first)
        for interval in set.intervals ?? [] {
            workout = apply(.logInterval(setID: set.id, intervalID: interval.id,
                values: .init(durationSeconds: 60, distance: .init(value: 100, unit: .m), averageRpm: 90, averageHeartRate: 160)), to: workout)
        }
        workout = apply(.logSet(setID: set.id, values: .init(durationSeconds: 120, distance: .init(value: 200, unit: .m))), to: workout)
        workout = apply(.finish(allowPartial: false), to: workout)
        let baseline = try WatchHistoryBaselineBuilder.build(plan: plan, workouts: [workout], syncGeneration: "generation")
        let actuals = try XCTUnwrap(baseline.exposures.first?.actuals)
        XCTAssertEqual(actuals.count, 2)
        XCTAssertEqual(actuals.reduce(0) { $0 + ($1.values.distance?.value ?? 0) }, 200)
        XCTAssertTrue(actuals.allSatisfy { $0.values.averageHeartRate == nil && $0.values.averageRpm == nil })
        XCTAssertTrue(actuals.allSatisfy { $0.intervalKind == .work })
    }

    func testInvalidOrOversizedInputsFailBeforePublishing() throws {
        var invalidPlan = plan(); invalidPlan.days = Array(repeating: invalidPlan.days[0], count: 8)
        XCTAssertThrowsError(try WatchHistoryBaselineBuilder.build(plan: invalidPlan, workouts: [], syncGeneration: "generation"))
        let validPlan = plan()
        var invalid = try workout(validPlan)
        invalid.exercises[0].sets[0].actual.load = .init(value: .infinity, unit: .lb)
        XCTAssertThrowsError(try WatchHistoryBaselineBuilder.build(plan: validPlan, workouts: [invalid], syncGeneration: "generation"))
    }

    func testLongIntervalHistoryIsExplicitlyBoundedWithoutLosingSourceCount() throws {
        let step = PlanIntervalStep(id: "work", kind: .work, measurement: .duration,
            target: .init(sets: 1, restSeconds: 0, duration: .init(min: 60, max: 60, unit: .s)))
        let exercise = PlanExercise(instanceId: "run", exerciseId: "run", name: "Run", measurement: .duration,
            target: .init(sets: 1, restSeconds: 0, duration: .init(min: 6_000, max: 6_000, unit: .s)),
            intervals: [.init(id: "rounds", repeatCount: 100, steps: [step])])
        let session = PlanSession(id: "session", name: "Run", kind: "cardio", estimatedMinutes: 100, exercises: [exercise])
        let plan = WeeklyPlan(id: "plan", name: "Plan", days: [.init(weekday: .monday, sessions: [session])])
        var workout = try WorkoutSession.start(prescription: session, planID: plan.id, planRevisionID: "revision", ownerDeviceID: "phone",
            at: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "UTC", syncGeneration: "generation")
        let set = try XCTUnwrap(workout.exercises.first?.sets.first)
        for interval in set.intervals ?? [] {
            workout = apply(.logInterval(setID: set.id, intervalID: interval.id, values: .init(durationSeconds: 60)), to: workout)
        }
        workout = apply(.finish(allowPartial: true), to: workout)
        let baseline = try WatchHistoryBaselineBuilder.build(plan: plan, workouts: [workout], syncGeneration: "generation")
        XCTAssertEqual(baseline.exposures.first?.completedObservationCount, 100)
        XCTAssertEqual(baseline.exposures.first?.actuals.count, WatchHistoryBaselineBuilder.maximumActualsPerExposure)
        XCTAssertTrue(WatchHistoryBaselineBuilder.validate(baseline).isEmpty)
        XCTAssertEqual(workout.completedIntervalCount, 100)
    }

    private func plan(sets: Int = 1) -> WeeklyPlan {
        let exercise = PlanExercise(instanceId: "press", exerciseId: "press", name: "Press", measurement: .weightReps,
            equipment: ["barbell"], target: .init(sets: sets, restSeconds: 30, reps: .init(min: 8, max: 12), load: .init(value: 50, unit: .kg)))
        let session = PlanSession(id: "session", name: "Strength", kind: "strength", estimatedMinutes: 20, exercises: [exercise])
        return WeeklyPlan(id: "plan", name: "Plan", days: [.init(weekday: .monday, sessions: [session])])
    }
    private func workout(_ plan: WeeklyPlan, offset: Double = 0, load: Double = 10,
                         generation: String = "generation", alternativeID: String? = nil) throws -> WorkoutSession {
        var session = try WorkoutSession.start(prescription: plan.days[0].sessions[0], planID: plan.id, planRevisionID: "revision",
            ownerDeviceID: "phone", at: Date(timeIntervalSince1970: 1_800_000_000 + offset), timeZoneIdentifier: "UTC", syncGeneration: generation)
        if let alternativeID { session = apply(.chooseAlternative(exerciseID: session.exercises[0].id, alternativeID: alternativeID), to: session) }
        session = apply(.logSet(setID: session.exercises[0].sets[0].id, values: .init(reps: 8, load: .init(value: load, unit: .lb), rir: 2)), to: session)
        return apply(.finish(allowPartial: true), to: session)
    }
    private func apply(_ command: WorkoutCommand, to original: WorkoutSession) -> WorkoutSession {
        let date = original.lastAppliedAt.addingTimeInterval(1)
        let result = WorkoutReducer.apply(.init(session: original, command: command, at: date), to: original, at: date)
        XCTAssertEqual(result.status, .applied, result.issues.map(\.message).joined(separator: " "))
        return result.session
    }
}
