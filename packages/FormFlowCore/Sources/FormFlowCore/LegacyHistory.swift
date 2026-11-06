import Foundation

/// A readable projection of preserved web records; it does not fabricate native session timings.
public struct LegacyWorkoutSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let date: String
    public let planID: String
    public let notes: String?
    public let timeZoneAssumption: String?
    public let hasPendingDraft: Bool
    public let exercises: [LegacyExerciseSummary]
    public var completedSetCount: Int { exercises.reduce(0) { $0 + $1.sets.filter(\.completed).count } }

    public init?(record: BackupRecord) {
        guard record.category == .workouts, let log = record.payload["log"],
              log["nativeNormalizationVersion"] == .number(1),
              let date = log["date"]?.string, LocalTrainingDay.isValidDate(date),
              let exercises = log["exercises"]?.object else { return nil }
        id = record.key
        self.date = date
        planID = log["planId"]?.string ?? "form-flow"
        notes = log["notes"]?.string
        timeZoneAssumption = record.payload["legacyTimeZoneAssumption"]?.string
        hasPendingDraft = record.payload["pendingDraft"] != nil
        var rows = exercises.keys.sorted().compactMap { key in
            LegacyExerciseSummary(id: key, value: exercises[key]!)
        }
        for (index, activity) in (log["extraActivities"]?.array ?? []).enumerated() {
            if let row = LegacyExerciseSummary(id: "extra-\(index)", value: activity) { rows.append(row) }
        }
        self.exercises = rows
    }
}

public struct LegacyExerciseSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let measurement: MeasurementKind
    public let sets: [LegacySetSummary]
    init?(id: String, value: BackupJSONValue) {
        guard let kind = value["measurement"]?.string.flatMap(MeasurementKind.init(rawValue:)),
              let sets = value["sets"]?.array else { return nil }
        self.id = id
        name = value["name"]?.string ?? id.replacingOccurrences(of: "-", with: " ").capitalized
        measurement = kind
        self.sets = sets.enumerated().map { LegacySetSummary(index: $0.offset + 1, value: $0.element) }
    }
}

public struct LegacySetSummary: Identifiable, Equatable, Sendable {
    public var id: Int { index }
    public let index: Int
    public let completed: Bool
    public let actual: WorkoutSetValues
    init(index: Int, value: BackupJSONValue) {
        self.index = index
        completed = value["completed"] == .bool(true)
        func number(_ key: String, maximum: Double = 1_000_000) -> Double? {
            guard let result = value[key]?.number, result.isFinite, (0...maximum).contains(result) else { return nil }
            return result
        }
        func integer(_ key: String, maximum: Double) -> Int? {
            number(key, maximum: maximum).flatMap { $0.rounded() == $0 ? Int($0) : nil }
        }
        let reps = integer("reps", maximum: 10_000)
        let minutes = number("minutes", maximum: 1_440), seconds = number("seconds", maximum: 86_400)
        let duration = minutes == nil && seconds == nil ? nil : (minutes ?? 0) * 60 + (seconds ?? 0)
        // Migration stores canonical meter values once. Never reinterpret the original field here.
        let distance = number("nativeDistanceMeters").map { PlanQuantity(value: $0, unit: .m) }
        let load = value["nativeWeightUnit"] == .string("kg")
            ? number("weight").map { PlanQuantity(value: $0, unit: .kg) } : nil
        actual = .init(reps: reps, load: load, assistance: number("assistance").map { .init(value: $0, unit: .kg) },
                       durationSeconds: duration, distance: distance,
                       calories: number("calories"), rir: integer("rir", maximum: 10),
                       rpe: integer("rpe", maximum: 10),
                       averageRpm: number("averageRpm", maximum: 500),
                       averageHeartRate: number("averageHeartRate", maximum: 300))
    }
}
