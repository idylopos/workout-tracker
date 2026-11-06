import Foundation

public enum Weekday: String, Codable, CaseIterable, Identifiable, Sendable {
    case monday, tuesday, wednesday, thursday, friday, saturday, sunday
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
    public var calendarWeekday: Int {
        switch self {
        case .sunday: 1
        case .monday: 2
        case .tuesday: 3
        case .wednesday: 4
        case .thursday: 5
        case .friday: 6
        case .saturday: 7
        }
    }
}

public enum MeasurementKind: String, Codable, CaseIterable, Sendable {
    case completion
    case weightReps = "weight_reps"
    case reps
    case assistedReps = "assisted_reps"
    case weightDistance = "weight_distance"
    case duration
    case durationCalories = "duration_calories"
    case distanceTime = "distance_time"
    case distance

    public var displayName: String {
        switch self {
        case .completion: "Completion"
        case .weightReps: "Weight and reps"
        case .reps: "Reps"
        case .assistedReps: "Assistance and reps"
        case .weightDistance: "Weight and distance"
        case .duration: "Duration"
        case .durationCalories: "Duration and calories"
        case .distanceTime: "Distance and time"
        case .distance: "Distance"
        }
    }
}

public enum PlanUnit: String, Codable, CaseIterable, Sendable {
    case kg, lb, s, min, m, km, mi, kcal
}

public struct RepRange: Codable, Equatable, Sendable {
    public var min: Int
    public var max: Int
    public init(min: Int, max: Int) { self.min = min; self.max = max }
}

public struct PlanQuantity: Codable, Equatable, Sendable {
    public var value: Double
    public var unit: PlanUnit
    public init(value: Double, unit: PlanUnit) { self.value = value; self.unit = unit }
}

public struct QuantityRange: Codable, Equatable, Sendable {
    public var min: Double
    public var max: Double
    public var unit: PlanUnit
    public init(min: Double, max: Double, unit: PlanUnit) {
        self.min = min; self.max = max; self.unit = unit
    }
}

public struct EffortTarget: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case rir, rpe }
    public var kind: Kind
    public var min: Int
    public var max: Int
    public init(kind: Kind, min: Int, max: Int) {
        self.kind = kind; self.min = min; self.max = max
    }
}

public struct ExerciseTarget: Codable, Equatable, Sendable {
    public var sets: Int
    public var restSeconds: Int
    public var reps: RepRange?
    public var load: PlanQuantity?
    public var assistance: PlanQuantity?
    public var duration: QuantityRange?
    public var distance: QuantityRange?
    public var calories: QuantityRange?
    public var effort: EffortTarget?

    public init(sets: Int, restSeconds: Int, reps: RepRange? = nil,
                load: PlanQuantity? = nil, assistance: PlanQuantity? = nil,
                duration: QuantityRange? = nil, distance: QuantityRange? = nil,
                calories: QuantityRange? = nil, effort: EffortTarget? = nil) {
        self.sets = sets; self.restSeconds = restSeconds; self.reps = reps
        self.load = load; self.assistance = assistance; self.duration = duration
        self.distance = distance; self.calories = calories; self.effort = effort
    }

    public var summary: String {
        var parts = ["\(sets) \(sets == 1 ? "set" : "sets")"]
        if let reps { parts.append("\(rangeText(Double(reps.min), Double(reps.max))) reps") }
        if let load { parts.append("\(numberText(load.value)) \(load.unit.rawValue)") }
        if let assistance { parts.append("\(numberText(assistance.value)) \(assistance.unit.rawValue) assistance") }
        for value in [duration, distance, calories].compactMap({ $0 }) {
            parts.append("\(rangeText(value.min, value.max)) \(value.unit.rawValue)")
        }
        if let effort { parts.append("\(effort.kind.rawValue.uppercased()) \(rangeText(Double(effort.min), Double(effort.max)))") }
        if restSeconds > 0 { parts.append("\(restSeconds)s rest") }
        return parts.joined(separator: " · ")
    }
}

private func numberText(_ value: Double) -> String { String(format: "%g", value) }
private func rangeText(_ min: Double, _ max: Double) -> String {
    min == max ? numberText(min) : "\(numberText(min))–\(numberText(max))"
}

/// A reference is retained for review, never executed by the importer.
public struct PlanPolicyReference: Codable, Equatable, Sendable {
    public var id: String
    public var version: Int
    public var notes: String?
    public init(id: String, version: Int, notes: String? = nil) {
        self.id = id; self.version = version; self.notes = notes
    }
}

public enum PlanIntervalKind: String, Codable, CaseIterable, Sendable {
    case warmup, work, recovery, cooldown
}

/// A flat step; a recovery step is an explicit timed/distance prescription, never an inferred rest.
public struct PlanIntervalStep: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: PlanIntervalKind
    public var measurement: MeasurementKind
    public var target: ExerciseTarget
    public var instructions: String?
    public init(id: String, kind: PlanIntervalKind, measurement: MeasurementKind,
                target: ExerciseTarget, instructions: String? = nil) {
        self.id = id; self.kind = kind; self.measurement = measurement; self.target = target; self.instructions = instructions
    }
}

/// Repeats the entire ordered sequence, so work/recovery pairs remain paired. Blocks cannot nest.
public struct PlanIntervalBlock: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var repeatCount: Int
    public var steps: [PlanIntervalStep]
    public init(id: String, repeatCount: Int = 1, steps: [PlanIntervalStep]) {
        self.id = id; self.repeatCount = repeatCount; self.steps = steps
    }
}

/// Alternatives are flat prescriptions, not nested exercises or executable rules.
public struct PlanAlternative: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var exerciseId: String
    public var name: String
    public var measurement: MeasurementKind
    public var equipment: [String]
    public var target: ExerciseTarget
    public var instructions: String?
    public var intervals: [PlanIntervalBlock]?
    public init(id: String, exerciseId: String, name: String, measurement: MeasurementKind,
                equipment: [String] = [], target: ExerciseTarget, instructions: String? = nil,
                intervals: [PlanIntervalBlock]? = nil) {
        self.id = id; self.exerciseId = exerciseId; self.name = name; self.measurement = measurement
        self.equipment = equipment; self.target = target; self.instructions = instructions; self.intervals = intervals
    }
    public func prescription(instanceId: String, optional: Bool = false) -> PlanExercise {
        PlanExercise(instanceId: instanceId, exerciseId: exerciseId, name: name, measurement: measurement,
            equipment: equipment, target: target, optional: optional, instructions: instructions, intervals: intervals)
    }
}

public struct PlanExercise: Codable, Equatable, Sendable, Identifiable {
    public var id: String { instanceId }
    public var instanceId: String
    public var exerciseId: String
    public var name: String
    public var measurement: MeasurementKind
    public var equipment: [String]
    public var target: ExerciseTarget
    public var optional: Bool
    public var instructions: String?
    public var progressionPolicy: PlanPolicyReference?
    public var alternatives: [PlanAlternative]?
    public var intervals: [PlanIntervalBlock]?
    public init(instanceId: String, exerciseId: String, name: String, measurement: MeasurementKind,
                equipment: [String] = [], target: ExerciseTarget, optional: Bool = false,
                instructions: String? = nil, progressionPolicy: PlanPolicyReference? = nil,
                alternatives: [PlanAlternative]? = nil, intervals: [PlanIntervalBlock]? = nil) {
        self.instanceId = instanceId; self.exerciseId = exerciseId; self.name = name
        self.measurement = measurement; self.equipment = equipment; self.target = target
        self.optional = optional; self.instructions = instructions; self.progressionPolicy = progressionPolicy
        self.alternatives = alternatives; self.intervals = intervals
    }
}

public struct PlanSession: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: String
    /// Zero means no duration estimate was supplied; the UI displays this as unknown.
    public var estimatedMinutes: Int
    public var warmup: [String]
    public var exercises: [PlanExercise]
    public var instructions: String?
    public init(id: String, name: String, kind: String, estimatedMinutes: Int,
                warmup: [String] = [], exercises: [PlanExercise], instructions: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.estimatedMinutes = estimatedMinutes
        self.warmup = warmup; self.exercises = exercises; self.instructions = instructions
    }
}

public struct PlanDay: Codable, Equatable, Sendable, Identifiable {
    public var id: String { weekday.id }
    public var weekday: Weekday
    public var sessions: [PlanSession]
    public init(weekday: Weekday, sessions: [PlanSession]) {
        self.weekday = weekday; self.sessions = sessions
    }
}

public struct WeeklyPlan: Codable, Equatable, Sendable, Identifiable {
    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var assumptions: [String]
    public var days: [PlanDay]
    /// Original human-readable guidance, including legacy long-run schedules.
    public var instructions: String?
    public init(schemaVersion: Int = 2, id: String, name: String, assumptions: [String] = [],
                days: [PlanDay], instructions: String? = nil) {
        self.schemaVersion = schemaVersion; self.id = id; self.name = name
        self.assumptions = assumptions; self.days = days; self.instructions = instructions
    }
}

public struct PlanIssue: Codable, Equatable, Sendable, Identifiable {
    public enum Severity: String, Codable, Sendable { case error, warning }
    public var id: String { "\(severity.rawValue):\(path):\(message)" }
    public var path: String
    public var message: String
    public var severity: Severity
    public init(path: String, message: String, severity: Severity = .error) {
        self.path = path; self.message = message; self.severity = severity
    }
}

public struct PlanImportResult: Equatable, Sendable {
    public var plan: WeeklyPlan?
    public var issues: [PlanIssue]
    public var sourceVersion: Int?
    public var canActivate: Bool { plan != nil && !issues.contains { $0.severity == .error } }
    public init(plan: WeeklyPlan?, issues: [PlanIssue], sourceVersion: Int? = nil) {
        self.plan = plan; self.issues = issues; self.sourceVersion = sourceVersion
    }
}
