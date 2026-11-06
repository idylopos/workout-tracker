import Foundation

public struct WorkoutWeekTrend: Identifiable, Equatable, Sendable {
    public var id: Date { start }
    public let start: Date
    public let finished: Int
    public let partial: Int
    public let abandoned: Int
}

/// A missing actual is not zero. Counts expose incomplete coverage alongside known totals.
public struct RecordedActualTotal: Equatable, Sendable {
    public internal(set) var value: Double?
    public internal(set) var knownCount = 0
    public internal(set) var missingCount = 0
    mutating func include(_ actual: Double?) {
        guard let actual, actual.isFinite, actual >= 0 else { missingCount += 1; return }
        value = (value ?? 0) + actual; knownCount += 1
    }
}

public struct WorkoutCardioTotals: Equatable, Sendable {
    public internal(set) var distanceMeters = RecordedActualTotal()
    public internal(set) var durationSeconds = RecordedActualTotal()
    public internal(set) var calories = RecordedActualTotal()
    public internal(set) var completedObservations = 0
}

public enum WorkoutTrendMetric: String, CaseIterable, Sendable {
    case loadKilograms, assistanceKilograms, repetitions, distanceMeters, durationSeconds, calories
}

public struct WorkoutTrendSample: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let workoutID: UUID
    public let date: Date
    public let partialWorkout: Bool
    public let intervalKind: PlanIntervalKind?
    public let actual: WorkoutSetValues
    public func value(for metric: WorkoutTrendMetric) -> Double? {
        let result: Double?
        switch metric {
        case .loadKilograms: result = WorkoutTrends.kilograms(actual.load)
        case .assistanceKilograms: result = WorkoutTrends.kilograms(actual.assistance)
        case .repetitions: result = actual.reps.map(Double.init)
        case .distanceMeters: result = WorkoutTrends.meters(actual.distance)
        case .durationSeconds: result = actual.durationSeconds
        case .calories: result = actual.calories
        }
        guard let result, result.isFinite, result >= 0 else { return nil }
        return result
    }
}

public struct WorkoutExerciseTrend: Identifiable, Equatable, Sendable {
    public let id: String
    public let exerciseID: String
    public let name: String
    public let measurement: MeasurementKind
    public let equipment: [String]
    public internal(set) var samples: [WorkoutTrendSample]
    public var availableMetrics: [WorkoutTrendMetric] {
        WorkoutTrendMetric.allCases.filter { metric in samples.contains { $0.value(for: metric) != nil } }
    }
}

public struct WorkoutTrendsReport: Sendable {
    public let weeks: [WorkoutWeekTrend]
    public let windowStart: Date
    public let timeZoneIdentifier: String
    public let finishedCount: Int
    public let partialCount: Int
    public let abandonedCount: Int
    public let inProgressCount: Int
    public let cardio: WorkoutCardioTotals
    public let exercises: [WorkoutExerciseTrend]
}

public enum WorkoutTrends {
    /// Weekly totals use the selected display timezone. Exercise history keeps actuals from
    /// finished sessions, including partial finishes; abandoned and open sessions are separate.
    public static func report(workouts: [WorkoutSession], now: Date = Date(),
                              timeZoneIdentifier: String = TimeZone.current.identifier,
                              weeks count: Int = 8) -> WorkoutTrendsReport {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
        let count = min(52, max(1, count))
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let starts = (0..<count).reversed().map { calendar.date(byAdding: .weekOfYear, value: -$0, to: thisWeek)! }
        let windowStart = starts[0]
        // Sources normally guarantee unique IDs. A repeated snapshot must not double totals.
        var unique: [UUID: WorkoutSession] = [:]
        for workout in workouts {
            if let previous = unique[workout.id] {
                switch WorkoutSnapshotMerge.classify(incoming: workout, existing: previous) {
                case .newer, .auditExtension: unique[workout.id] = workout
                default: break
                }
            } else { unique[workout.id] = workout }
        }
        let all = unique.values.sorted { $0.startedAt < $1.startedAt }
        let inWindow = all.filter {
            let date = $0.endedAt ?? $0.startedAt
            return date >= windowStart && date <= now
        }
        let weeks = starts.map { start in
            let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start)!
            let sessions = inWindow.filter { let date = $0.endedAt ?? $0.startedAt; return date >= start && date < end }
            return WorkoutWeekTrend(start: start,
                finished: sessions.filter { $0.state == .finished && !$0.isPartial }.count,
                partial: sessions.filter { $0.state == .finished && $0.isPartial }.count,
                abandoned: sessions.filter { $0.state == .abandoned }.count)
        }
        var cardio = WorkoutCardioTotals()
        var exercises: [String: WorkoutExerciseTrend] = [:]
        for workout in all where workout.state == .finished && (workout.endedAt ?? workout.startedAt) <= now {
            let inTotalsWindow = (workout.endedAt ?? workout.startedAt) >= windowStart
            for exercise in workout.exercises where exercise.isEnabled {
                let prescription = exercise.performedPrescription
                let equipment = prescription.equipment.sorted()
                for set in exercise.sets {
                    let observations: [(UUID, MeasurementKind, PlanIntervalKind?, WorkoutSetValues, Date?)]
                    if let intervals = set.intervals, !intervals.isEmpty {
                        // Interval actuals are the source of truth; parent totals cannot be added again.
                        observations = intervals.filter { $0.status == .completed }.map {
                            ($0.id, $0.prescription.measurement, $0.prescription.kind, $0.actual, $0.completedAt)
                        }
                    } else if set.status == .completed {
                        observations = [(set.id, prescription.measurement, nil, set.actual, set.completedAt)]
                    } else { observations = [] }
                    for (id, measurement, intervalKind, actual, date) in observations {
                        let components = [prescription.exerciseId, measurement.rawValue] + equipment
                        let key = components.map { "\($0.utf8.count):\($0)" }.joined()
                        var trend = exercises[key] ?? WorkoutExerciseTrend(id: key, exerciseID: prescription.exerciseId,
                            name: prescription.name, measurement: measurement, equipment: equipment, samples: [])
                        trend.samples.append(WorkoutTrendSample(id: id, workoutID: workout.id,
                            date: date ?? workout.endedAt ?? workout.startedAt, partialWorkout: workout.isPartial,
                            intervalKind: intervalKind, actual: actual))
                        exercises[key] = trend
                        if inTotalsWindow && isCardio(measurement, sessionKind: workout.prescription.kind) {
                            cardio.completedObservations += 1
                            if [.distance, .distanceTime].contains(measurement) || actual.distance != nil {
                                cardio.distanceMeters.include(meters(actual.distance))
                            }
                            if [.duration, .durationCalories, .distanceTime].contains(measurement) || actual.durationSeconds != nil {
                                cardio.durationSeconds.include(actual.durationSeconds)
                            }
                            if measurement == .durationCalories || actual.calories != nil { cardio.calories.include(actual.calories) }
                        }
                    }
                }
            }
        }
        var sorted: [WorkoutExerciseTrend] = []
        for var value in exercises.values {
            value.samples.sort { (first: WorkoutTrendSample, second: WorkoutTrendSample) -> Bool in
                if first.date == second.date { return first.id.uuidString < second.id.uuidString }
                return first.date < second.date
            }
            sorted.append(value)
        }
        sorted.sort { first, second in
            if first.name == second.name { return first.id < second.id }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
        return WorkoutTrendsReport(weeks: weeks, windowStart: windowStart, timeZoneIdentifier: calendar.timeZone.identifier,
            finishedCount: weeks.reduce(0) { $0 + $1.finished }, partialCount: weeks.reduce(0) { $0 + $1.partial },
            abandonedCount: weeks.reduce(0) { $0 + $1.abandoned },
            inProgressCount: inWindow.filter { !$0.state.isTerminal }.count, cardio: cardio, exercises: sorted)
    }

    public static func kilograms(_ quantity: PlanQuantity?) -> Double? {
        guard let quantity, quantity.value.isFinite, quantity.value >= 0 else { return nil }
        switch quantity.unit { case .kg: return quantity.value; case .lb: return quantity.value * 0.45359237; default: return nil }
    }
    public static func meters(_ quantity: PlanQuantity?) -> Double? {
        guard let quantity, quantity.value.isFinite, quantity.value >= 0 else { return nil }
        switch quantity.unit {
        case .m: return quantity.value
        case .km: return quantity.value * 1_000
        case .mi: return quantity.value * 1_609.344
        default: return nil
        }
    }
    private static func isCardio(_ measurement: MeasurementKind, sessionKind: String) -> Bool {
        if [.distanceTime, .durationCalories, .distance].contains(measurement) { return true }
        return measurement == .duration && ["cardio", "conditioning", "endurance"].contains(sessionKind.lowercased())
    }
}
