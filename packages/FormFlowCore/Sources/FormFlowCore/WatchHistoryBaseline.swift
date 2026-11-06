import Foundation

public struct WatchHistoryActual: Codable, Equatable, Sendable {
    public let measurement: MeasurementKind
    public let intervalKind: PlanIntervalKind?
    public let values: WorkoutSetValues
}

public struct WatchExerciseHistory: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { exerciseOccurrenceID }
    public let workoutID: UUID
    public let exerciseOccurrenceID: UUID
    public let sourceRevision: Int
    public let exerciseID: String
    public let selectedAlternativeID: String?
    public let measurement: MeasurementKind
    public let equipment: [String]
    public let name: String
    public let recordedAt: Date
    public let wasPartial: Bool
    public let completedObservationCount: Int
    public let actuals: [WatchHistoryActual]

    public func matches(_ exercise: WorkoutExercise) -> Bool {
        let performed = exercise.performedPrescription
        return exerciseID == performed.exerciseId && selectedAlternativeID == exercise.selectedAlternativeID &&
            measurement == performed.measurement && equipment == performed.equipment.sorted()
    }
}

/// A bounded, read-only reference snapshot. It carries no workout commands or recording ownership.
public struct WatchHistoryBaseline: Codable, Equatable, Sendable {
    public var formatVersion = 1
    public let exposures: [WatchExerciseHistory]
    public let omittedVariantCount: Int
    public static let empty = WatchHistoryBaseline(exposures: [], omittedVariantCount: 0)

    public func previous(for exercise: WorkoutExercise, excluding workoutID: UUID) -> [WatchExerciseHistory] {
        exposures.filter { $0.workoutID != workoutID && $0.matches(exercise) }.sorted { $0.recordedAt > $1.recordedAt }
    }
}

public enum WatchHistoryBaselineBuilder {
    public static let maximumVariants = 120
    public static let maximumExposuresPerVariant = 2
    public static let maximumActualsPerExposure = 80
    public static let maximumEncodedBytes = 4 * 1_024 * 1_024

    public static func build(plan: WeeklyPlan, workouts: [WorkoutSession], syncGeneration: String) throws -> WatchHistoryBaseline {
        guard workouts.count <= 50_000, !syncGeneration.isEmpty, syncGeneration.count <= 200,
              plan.days.count <= 7, plan.days.flatMap(\.sessions).count <= 21,
              plan.days.flatMap(\.sessions).flatMap(\.exercises).count <= 630 else { throw WatchHistoryError.inputLimit }
        var relevant: [String] = []
        var seen = Set<String>()
        for exercise in plan.days.flatMap(\.sessions).flatMap(\.exercises) {
            guard (exercise.alternatives?.count ?? 0) <= 20 else { throw WatchHistoryError.inputLimit }
            for (performed, alternativeID) in [(exercise, Optional<String>.none)] + (exercise.alternatives ?? []).map({
                ($0.prescription(instanceId: exercise.instanceId), Optional($0.id))
            }) {
                let value = key(performed.exerciseId, alternativeID, performed.measurement, performed.equipment)
                if seen.insert(value).inserted { relevant.append(value) }
            }
        }
        let wanted = Set(relevant.prefix(maximumVariants))
        var counts: [String: Int] = [:]
        var exposures: [WatchExerciseHistory] = []
        var seenWorkouts = Set<UUID>()
        for workout in workouts.sorted(by: { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) })
            where workout.state == .finished && workout.syncGeneration == syncGeneration {
            guard seenWorkouts.insert(workout.id).inserted else { continue }
            guard workout.exercises.count <= 1_020 else { throw WatchHistoryError.inputLimit }
            for exercise in workout.exercises where exercise.isEnabled {
                let performed = exercise.performedPrescription
                let variant = key(performed.exerciseId, exercise.selectedAlternativeID, performed.measurement, performed.equipment)
                guard wanted.contains(variant), counts[variant, default: 0] < maximumExposuresPerVariant else { continue }
                guard exercise.sets.count <= 20,
                      exercise.sets.reduce(0, { $0 + ($1.intervals?.count ?? 0) }) <= 2_000 else { throw WatchHistoryError.inputLimit }
                var actuals: [WatchHistoryActual] = []
                for set in exercise.sets {
                    if let intervals = set.intervals, !intervals.isEmpty {
                        for interval in intervals where interval.status == .completed {
                            actuals.append(observation(interval.actual, measurement: interval.prescription.measurement,
                                intervalKind: interval.prescription.kind))
                        }
                    } else if set.status == .completed {
                        actuals.append(observation(set.actual, measurement: performed.measurement, intervalKind: nil))
                    }
                }
                guard !actuals.isEmpty else { continue }
                counts[variant, default: 0] += 1
                exposures.append(WatchExerciseHistory(workoutID: workout.id, exerciseOccurrenceID: exercise.id,
                    sourceRevision: workout.revision, exerciseID: performed.exerciseId,
                    selectedAlternativeID: exercise.selectedAlternativeID, measurement: performed.measurement,
                    equipment: performed.equipment.sorted(), name: performed.name,
                    recordedAt: workout.endedAt ?? workout.startedAt, wasPartial: workout.isPartial,
                    completedObservationCount: actuals.count, actuals: Array(actuals.prefix(maximumActualsPerExposure))))
            }
            if wanted.allSatisfy({ counts[$0, default: 0] >= maximumExposuresPerVariant }) { break }
        }
        let baseline = WatchHistoryBaseline(exposures: exposures, omittedVariantCount: max(0, relevant.count - wanted.count))
        guard validate(baseline).isEmpty else { throw WatchHistoryError.invalidActuals }
        return baseline
    }

    public static func validate(_ baseline: WatchHistoryBaseline) -> [WorkoutIssue] {
        func invalid(_ message: String) -> [WorkoutIssue] { [.init(code: "watchHistoryInvalid", message: message)] }
        guard baseline.formatVersion == 1, baseline.omittedVariantCount >= 0,
              baseline.exposures.count <= maximumVariants * maximumExposuresPerVariant,
              Set(baseline.exposures.map(\.id)).count == baseline.exposures.count else {
            return invalid("The previous-results snapshot is too large or has duplicate records.")
        }
        var counts: [String: Int] = [:]
        for exposure in baseline.exposures {
            guard !exposure.exerciseID.isEmpty, exposure.exerciseID.count <= 200,
                  !exposure.name.isEmpty, exposure.name.count <= 500,
                  exposure.selectedAlternativeID.map({ !$0.isEmpty && $0.count <= 200 }) ?? true,
                  exposure.equipment.count <= 20, exposure.equipment.allSatisfy({ $0.count <= 200 }),
                  exposure.equipment == exposure.equipment.sorted(), exposure.sourceRevision >= 0,
                  exposure.recordedAt.timeIntervalSinceReferenceDate.isFinite,
                  (1...2_000).contains(exposure.completedObservationCount),
                  !exposure.actuals.isEmpty, exposure.actuals.count <= maximumActualsPerExposure,
                  exposure.actuals.count <= exposure.completedObservationCount else {
                return invalid("The previous-results snapshot contains invalid record metadata.")
            }
            let variant = key(exposure.exerciseID, exposure.selectedAlternativeID, exposure.measurement, exposure.equipment)
            counts[variant, default: 0] += 1
            guard counts[variant, default: 0] <= maximumExposuresPerVariant else { return invalid("Too many previous results were sent for one activity.") }
            for actual in exposure.actuals {
                guard actual.values.averageHeartRate == nil, actual.values.averageRpm == nil,
                      WorkoutValueValidator.validate(actual.values, measurement: actual.measurement, requireComplete: false).isEmpty else {
                    return invalid("The previous-results snapshot contains invalid or unsupported actuals.")
                }
            }
        }
        guard counts.count <= maximumVariants, let data = try? JSONEncoder().encode(baseline), data.count <= maximumEncodedBytes else {
            return invalid("The previous-results snapshot exceeds the supported size.")
        }
        return []
    }
    private static func observation(_ values: WorkoutSetValues, measurement: MeasurementKind,
                                    intervalKind: PlanIntervalKind?) -> WatchHistoryActual {
        var values = values
        values.averageHeartRate = nil; values.averageRpm = nil
        return WatchHistoryActual(measurement: measurement, intervalKind: intervalKind, values: values)
    }
    private static func key(_ exerciseID: String, _ alternativeID: String?, _ measurement: MeasurementKind, _ equipment: [String]) -> String {
        ([exerciseID, alternativeID ?? "", measurement.rawValue] + equipment.sorted()).map { "\($0.utf8.count):\($0)" }.joined()
    }
}

public enum WatchHistoryError: Error, LocalizedError {
    case inputLimit, invalidActuals
    public var errorDescription: String? {
        switch self {
        case .inputLimit: "Previous workout results exceed the supported Watch history bounds. Your full history remains on iPhone."
        case .invalidActuals: "Previous workout results could not be prepared for Watch. Your full history remains on iPhone."
        }
    }
}
