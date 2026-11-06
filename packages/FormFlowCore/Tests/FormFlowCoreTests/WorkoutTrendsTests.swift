import XCTest
@testable import FormFlowCore

final class WorkoutTrendsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFinishedPartialAbandonedAndOpenStayDistinct() throws {
        let finished = try workout(values: [.init(reps: 8)])
        var partial = try workout(values: [.init(reps: 5)])
        partial.exercises[0].sets.append(WorkoutSet(target: partial.prescription.exercises[0].target))
        var abandoned = try workout(values: [.init(reps: 100)]); abandoned.state = .abandoned
        var open = try workout(values: [.init(reps: 200)]); open.state = .active; open.endedAt = nil
        let report = WorkoutTrends.report(workouts: [finished, partial, abandoned, open, finished], now: now, timeZoneIdentifier: "UTC")
        XCTAssertEqual(report.finishedCount, 1)
        XCTAssertEqual(report.partialCount, 1)
        XCTAssertEqual(report.abandonedCount, 1)
        XCTAssertEqual(report.inProgressCount, 1)
        XCTAssertEqual(report.exercises.flatMap(\.samples).count, 2)
        XCTAssertEqual(report.weeks.reduce(0) { $0 + $1.finished + $1.partial }, 2)
    }

    func testCardioConvertsActualUnitsAndNeverFillsMissingFromTargets() throws {
        let first = try workout(measurement: .distanceTime,
            values: [.init(durationSeconds: 600, distance: .init(value: 1, unit: .mi))])
        let second = try workout(measurement: .distanceTime,
            values: [.init(durationSeconds: 300, distance: .init(value: 1, unit: .km)),
                     .init(durationSeconds: 0, distance: .init(value: 0, unit: .m)), .init()])
        let report = WorkoutTrends.report(workouts: [first, second], now: now, timeZoneIdentifier: "UTC")
        XCTAssertEqual(try XCTUnwrap(report.cardio.distanceMeters.value), 2_609.344, accuracy: 0.0001)
        XCTAssertEqual(report.cardio.distanceMeters.knownCount, 3)
        XCTAssertEqual(report.cardio.distanceMeters.missingCount, 1)
        XCTAssertEqual(report.cardio.durationSeconds.value, 900)
        XCTAssertEqual(report.cardio.durationSeconds.missingCount, 1)
        XCTAssertNil(report.cardio.calories.value)
        XCTAssertTrue(report.exercises.flatMap(\.samples).contains { $0.actual.distance?.value == 0 })
    }

    func testAllMissingActualsStayUnknownAndZeroStaysRecorded() throws {
        let unknown = try workout(measurement: .durationCalories, values: [.init()])
        let unknownReport = WorkoutTrends.report(workouts: [unknown], now: now, timeZoneIdentifier: "UTC")
        XCTAssertNil(unknownReport.cardio.durationSeconds.value)
        XCTAssertNil(unknownReport.cardio.calories.value)
        XCTAssertEqual(unknownReport.cardio.calories.missingCount, 1)
        XCTAssertTrue(unknownReport.exercises.first?.availableMetrics.isEmpty == true)
        let zero = try workout(measurement: .durationCalories, values: [.init(durationSeconds: 0, calories: 0)])
        let zeroReport = WorkoutTrends.report(workouts: [zero], now: now, timeZoneIdentifier: "UTC")
        XCTAssertEqual(zeroReport.cardio.durationSeconds.value, 0)
        XCTAssertEqual(zeroReport.cardio.calories.value, 0)
        XCTAssertEqual(zeroReport.cardio.calories.knownCount, 1)
    }

    func testCompletedIntervalsCountOnceEvenInsidePartialSet() throws {
        var session = try workout(measurement: .distanceTime,
            values: [.init(durationSeconds: 999, distance: .init(value: 999, unit: .km))])
        let step = PlanIntervalStep(id: "work", kind: .work, measurement: .distanceTime,
            target: .init(sets: 1, restSeconds: 0, duration: .init(min: 300, max: 300, unit: .s), distance: .init(min: 1, max: 1, unit: .km)))
        session.exercises[0].sets[0].intervals = [
            WorkoutInterval(blockID: "block", repetition: 1, prescription: step,
                actual: .init(durationSeconds: 60, distance: .init(value: 100, unit: .m)), status: .completed, completedAt: now),
            WorkoutInterval(blockID: "block", repetition: 2, prescription: step,
                actual: .init(durationSeconds: 500, distance: .init(value: 500, unit: .m)), status: .skipped)
        ]
        session.exercises[0].sets[0].status = .unperformed
        let report = WorkoutTrends.report(workouts: [session], now: now, timeZoneIdentifier: "UTC")
        XCTAssertEqual(report.partialCount, 1)
        XCTAssertEqual(report.cardio.distanceMeters.value, 100)
        XCTAssertEqual(report.cardio.durationSeconds.value, 60)
        XCTAssertEqual(report.exercises.flatMap(\.samples).count, 1)
    }

    func testPerformedAlternativeAndEquipmentKeepSeparateVariantHistories() throws {
        var base = try workout(measurement: .assistedReps, values: [.init(reps: 8, assistance: .init(value: 20, unit: .kg))])
        let target = base.prescription.exercises[0].target
        var frozen = base.prescription.exercises[0]
        frozen.alternatives = [PlanAlternative(id: "alt", exerciseId: "other-movement", name: frozen.name,
            measurement: .assistedReps, equipment: ["bands"], target: target)]
        var alternative = try workout(measurement: .assistedReps,
            values: [.init(reps: 8, assistance: .init(value: 22.0462262185, unit: .lb))])
        base.exercises[0] = WorkoutExercise(id: base.exercises[0].id, prescription: frozen, sets: base.exercises[0].sets)
        alternative.exercises[0] = WorkoutExercise(id: alternative.exercises[0].id, prescription: frozen,
            sets: alternative.exercises[0].sets, selectedAlternativeID: "alt")
        let report = WorkoutTrends.report(workouts: [base, alternative], now: now, timeZoneIdentifier: "UTC")
        XCTAssertEqual(report.exercises.count, 2)
        XCTAssertEqual(Set(report.exercises.map(\.exerciseID)), ["movement", "other-movement"])
        let other = try XCTUnwrap(report.exercises.first { $0.exerciseID == "other-movement" })
        XCTAssertEqual(try XCTUnwrap(other.samples.first?.value(for: .assistanceKilograms)), 10, accuracy: 0.0001)
        XCTAssertEqual(other.samples.first?.value(for: .repetitions), 8)
        XCTAssertNil(other.samples.first?.value(for: .loadKilograms))
    }

    func testWeeklyBucketsUseFinishDateAndExplicitTimezone() throws {
        let formatter = ISO8601DateFormatter()
        let boundary = try XCTUnwrap(formatter.date(from: "2026-09-13T16:30:00Z"))
        let session = try workout(values: [.init(reps: 8)], at: boundary)
        let utc = WorkoutTrends.report(workouts: [session], now: boundary.addingTimeInterval(86_400), timeZoneIdentifier: "UTC", weeks: 2)
        let singapore = WorkoutTrends.report(workouts: [session], now: boundary.addingTimeInterval(86_400), timeZoneIdentifier: "Asia/Singapore", weeks: 2)
        XCTAssertEqual(utc.weeks.first?.finished, 1)
        XCTAssertEqual(singapore.weeks.last?.finished, 1)
    }

    private func workout(measurement: MeasurementKind = .reps, values: [WorkoutSetValues], at date: Date? = nil) throws -> WorkoutSession {
        let date = date ?? now
        var target = ExerciseTarget(sets: max(1, values.count), restSeconds: 60)
        switch measurement {
        case .reps, .weightReps, .assistedReps: target.reps = .init(min: 8, max: 12)
        case .duration, .durationCalories: target.duration = .init(min: 3_600, max: 3_600, unit: .s)
        case .distance, .distanceTime, .weightDistance: target.distance = .init(min: 100, max: 100, unit: .km)
        case .completion: break
        }
        let exercise = PlanExercise(instanceId: "movement-occurrence", exerciseId: "movement", name: "Movement",
            measurement: measurement, equipment: ["machine"], target: target)
        let prescription = PlanSession(id: "session", name: "Training", kind: "cardio", estimatedMinutes: 30, exercises: [exercise])
        var session = try WorkoutSession.start(prescription: prescription, planID: "plan", planRevisionID: "revision",
            ownerDeviceID: "phone", at: date.addingTimeInterval(-3_600), timeZoneIdentifier: "UTC", syncGeneration: "generation")
        session.exercises[0].sets = values.map { WorkoutSet(target: target, actual: $0, status: .completed, completedAt: date) }
        session.state = .finished; session.endedAt = date; session.activeSegmentStartedAt = nil
        return session
    }
}
