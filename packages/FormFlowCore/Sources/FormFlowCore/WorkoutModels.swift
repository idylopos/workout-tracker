import Foundation

public enum WorkoutState: String, Codable, Sendable {
    case active, paused, finished, abandoned
    public var isTerminal: Bool { self == .finished || self == .abandoned }
}

public enum WorkoutSetStatus: String, Codable, Sendable {
    case planned, completed, skipped, unperformed
}

/// Actual observations only. A prescribed target never fills these automatically.
public struct WorkoutSetValues: Codable, Equatable, Sendable {
    public var reps: Int?
    public var load: PlanQuantity?
    public var assistance: PlanQuantity?
    public var durationSeconds: Double?
    public var distance: PlanQuantity?
    public var calories: Double?
    public var averageRpm: Double?
    public var averageHeartRate: Double?
    public var rir: Int?
    public var rpe: Int?

    public init(reps: Int? = nil, load: PlanQuantity? = nil, assistance: PlanQuantity? = nil,
                durationSeconds: Double? = nil, distance: PlanQuantity? = nil, calories: Double? = nil,
                rir: Int? = nil, rpe: Int? = nil, averageRpm: Double? = nil, averageHeartRate: Double? = nil) {
        self.reps = reps; self.load = load; self.assistance = assistance
        self.durationSeconds = durationSeconds; self.distance = distance; self.calories = calories
        self.rir = rir; self.rpe = rpe
        self.averageRpm = averageRpm; self.averageHeartRate = averageHeartRate
    }

    public var hasPrimaryValues: Bool {
        reps != nil || load != nil || assistance != nil || durationSeconds != nil || distance != nil || calories != nil
    }
    public var isEmpty: Bool { !hasPrimaryValues && rir == nil && rpe == nil && averageRpm == nil && averageHeartRate == nil }
    public var withoutEffort: Self {
        var result = self
        result.rir = nil; result.rpe = nil
        return result
    }

    /// Repeat the selected measurement's primary values, not supplementary machine results.
    public func reusableValues(for measurement: MeasurementKind) -> Self {
        switch measurement {
        case .completion: Self()
        case .weightReps: Self(reps: reps, load: load)
        case .reps: Self(reps: reps)
        case .assistedReps: Self(reps: reps, assistance: assistance)
        case .weightDistance: Self(load: load, distance: distance)
        case .duration: Self(durationSeconds: durationSeconds)
        case .durationCalories: Self(durationSeconds: durationSeconds, calories: calories)
        case .distanceTime: Self(durationSeconds: durationSeconds, distance: distance)
        case .distance: Self(distance: distance)
        }
    }

    public var summary: String {
        var parts: [String] = []
        if let load { parts.append("\(String(format: "%g", load.value)) \(load.unit.rawValue)") }
        if let assistance { parts.append("\(String(format: "%g", assistance.value)) \(assistance.unit.rawValue) assistance") }
        if let reps { parts.append("\(reps) reps") }
        if let durationSeconds { parts.append("\(String(format: "%g", durationSeconds)) seconds") }
        if let distance { parts.append("\(String(format: "%g", distance.value)) \(distance.unit.rawValue)") }
        if let calories { parts.append("\(String(format: "%g", calories)) kcal") }
        if let averageRpm { parts.append("\(String(format: "%g", averageRpm)) rpm avg") }
        if let averageHeartRate { parts.append("\(String(format: "%g", averageHeartRate)) bpm avg") }
        if let rir { parts.append("RIR \(rir)") }
        if let rpe { parts.append("RPE \(rpe)") }
        return parts.isEmpty ? "No values recorded" : parts.joined(separator: " · ")
    }
}

public struct WorkoutSet: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let target: ExerciseTarget
    public internal(set) var actual: WorkoutSetValues
    public internal(set) var status: WorkoutSetStatus
    public internal(set) var completedAt: Date?
    public internal(set) var skipReason: String?
    public internal(set) var revision: Int
    public internal(set) var intervals: [WorkoutInterval]?

    public init(id: UUID = UUID(), target: ExerciseTarget, actual: WorkoutSetValues = WorkoutSetValues(),
                status: WorkoutSetStatus = .planned, completedAt: Date? = nil, skipReason: String? = nil,
                revision: Int = 0, intervals: [WorkoutInterval]? = nil) {
        self.id = id; self.target = target; self.actual = actual; self.status = status
        self.completedAt = completedAt; self.skipReason = skipReason; self.revision = revision
        self.intervals = intervals
    }
}

public struct WorkoutInterval: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let blockID: String
    public let repetition: Int
    public let prescription: PlanIntervalStep
    public internal(set) var actual: WorkoutSetValues
    public internal(set) var status: WorkoutSetStatus
    public internal(set) var completedAt: Date?
    public internal(set) var skipReason: String?
    public internal(set) var revision: Int
    public init(id: UUID = UUID(), blockID: String, repetition: Int, prescription: PlanIntervalStep,
                actual: WorkoutSetValues = .init(), status: WorkoutSetStatus = .planned,
                completedAt: Date? = nil, skipReason: String? = nil, revision: Int = 0) {
        self.id = id; self.blockID = blockID; self.repetition = repetition; self.prescription = prescription
        self.actual = actual; self.status = status; self.completedAt = completedAt; self.skipReason = skipReason; self.revision = revision
    }
}

public struct WorkoutExercise: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let prescription: PlanExercise
    public internal(set) var sets: [WorkoutSet]
    public internal(set) var isEnabled: Bool
    public internal(set) var selectedAlternativeID: String?
    public let isExtra: Bool?
    public var isAdditional: Bool { isExtra == true }
    public var performedPrescription: PlanExercise {
        guard let selectedAlternativeID,
              let alternative = prescription.alternatives?.first(where: { $0.id == selectedAlternativeID }) else { return prescription }
        return alternative.prescription(instanceId: prescription.instanceId, optional: prescription.optional)
    }
    public var completedSetCount: Int { sets.filter { $0.status == .completed }.count }

    public init(id: UUID = UUID(), prescription: PlanExercise, sets: [WorkoutSet], isEnabled: Bool = true,
                selectedAlternativeID: String? = nil, isExtra: Bool? = nil) {
        self.id = id; self.prescription = prescription; self.sets = sets; self.isEnabled = isEnabled
        self.selectedAlternativeID = selectedAlternativeID; self.isExtra = isExtra
    }
}

public struct WorkoutRest: Codable, Equatable, Sendable {
    public let setID: UUID
    public let startedAt: Date
    public internal(set) var deadline: Date
    public func remaining(at date: Date) -> TimeInterval { max(0, deadline.timeIntervalSince(date)) }
    public func isExpired(at date: Date) -> Bool { remaining(at: date) == 0 }
}

public enum WorkoutCommand: Codable, Equatable, Sendable {
    case chooseAlternative(exerciseID: UUID, alternativeID: String?)
    case addExtraExercise(exercise: PlanExercise)
    case logInterval(setID: UUID, intervalID: UUID, values: WorkoutSetValues)
    case updateInterval(setID: UUID, intervalID: UUID, values: WorkoutSetValues)
    case skipInterval(setID: UUID, intervalID: UUID, reason: String?)
    case undoInterval(setID: UUID, intervalID: UUID)
    case updateSet(setID: UUID, values: WorkoutSetValues)
    case logSet(setID: UUID, values: WorkoutSetValues)
    case undoSet(setID: UUID)
    case skipSet(setID: UUID, reason: String?)
    case copyLast(exerciseID: UUID, previous: WorkoutExercise)
    case fillEmptySets(exerciseID: UUID)
    case setExerciseEnabled(exerciseID: UUID, enabled: Bool)
    case pause
    case resume
    case finish(allowPartial: Bool)
    case abandon
    case skipRest
    case extendRest(seconds: Int)
}

public struct WorkoutOperation: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let id: UUID
    public let sessionID: UUID
    public let originDeviceID: String
    public let syncGeneration: String
    public let expectedRevision: Int
    public let command: WorkoutCommand
    public let createdAt: Date

    public init(id: UUID = UUID(), sessionID: UUID, originDeviceID: String, syncGeneration: String,
                expectedRevision: Int, command: WorkoutCommand, createdAt: Date, schemaVersion: Int = currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.id = id; self.sessionID = sessionID; self.originDeviceID = originDeviceID
        self.syncGeneration = syncGeneration; self.expectedRevision = expectedRevision
        self.command = command; self.createdAt = createdAt
    }

    public init(session: WorkoutSession, command: WorkoutCommand, originDeviceID: String? = nil, at date: Date) {
        self.init(sessionID: session.id, originDeviceID: originDeviceID ?? session.ownerDeviceID,
                  syncGeneration: session.syncGeneration, expectedRevision: session.revision,
                  command: command, createdAt: date)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, sessionID, originDeviceID, syncGeneration, expectedRevision, command, createdAt
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Development builds before protocol versioning used this same v1 shape.
        let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version == Self.currentSchemaVersion else {
            throw WorkoutProtocolCompatibilityError(component: "workout operation", version: version)
        }
        schemaVersion = version
        id = try values.decode(UUID.self, forKey: .id)
        sessionID = try values.decode(UUID.self, forKey: .sessionID)
        originDeviceID = try values.decode(String.self, forKey: .originDeviceID)
        syncGeneration = try values.decode(String.self, forKey: .syncGeneration)
        expectedRevision = try values.decode(Int.self, forKey: .expectedRevision)
        command = try values.decode(WorkoutCommand.self, forKey: .command)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }
}

public struct WorkoutIssue: Codable, Equatable, Sendable, Identifiable {
    public let code: String
    public let message: String
    public var id: String { "\(code):\(message)" }
    public init(code: String, message: String) { self.code = code; self.message = message }
}

public enum WorkoutReductionStatus: String, Codable, Sendable {
    case applied, duplicate, buffered, conflict, rejected
}

public struct WorkoutOperationReceipt: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { operation.id }
    public let operation: WorkoutOperation
    public let status: WorkoutReductionStatus
    public let resultingRevision: Int
    public let processedAt: Date
    public let issues: [WorkoutIssue]
}

/// Retains both the proposed operation and affected accepted values for explicit review.
public struct WorkoutConflict: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(operation.id.uuidString):\(issue.code)" }
    public let operation: WorkoutOperation
    public let currentRevision: Int
    public let acceptedSets: [WorkoutSet]
    public let issue: WorkoutIssue
}

public struct WorkoutSession: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let planID: String
    public let planRevisionID: String
    public let scheduledSessionID: String?
    public let prescription: PlanSession
    public let ownerDeviceID: String
    public let syncGeneration: String
    public let timeZoneIdentifier: String
    public let startedAt: Date
    public internal(set) var endedAt: Date?
    public internal(set) var state: WorkoutState
    public internal(set) var exercises: [WorkoutExercise]
    public internal(set) var revision: Int
    public internal(set) var rest: WorkoutRest?
    public internal(set) var accumulatedActiveTime: TimeInterval
    public internal(set) var activeSegmentStartedAt: Date?
    public internal(set) var lastAppliedAt: Date
    public internal(set) var pendingOperations: [WorkoutOperation]
    public internal(set) var operationReceipts: [WorkoutOperationReceipt]
    public internal(set) var conflicts: [WorkoutConflict]

    public var completedSetCount: Int { exercises.reduce(0) { $0 + $1.completedSetCount } }
    public var completedIntervalCount: Int { exercises.flatMap(\.sets).flatMap { $0.intervals ?? [] }.filter { $0.status == .completed }.count }
    public var hasRecordedWork: Bool { completedSetCount > 0 || completedIntervalCount > 0 }
    public var usesThursdayLegCurl: Bool {
        planID == "form-flow" && prescription.id == "thursday-strength" && exercises.contains {
            !$0.isAdditional && $0.prescription.instanceId == "trap-bar-deadlift" && $0.selectedAlternativeID == "seated-leg-curl"
        }
    }

    public var recordingWarmup: [String] {
        guard usesThursdayLegCurl else { return prescription.warmup }
        return prescription.warmup.filter { step in
            !["Light kettlebell deadlift ·", "Light kettlebell swing ·", "Trap-bar ramp ·"].contains(where: step.hasPrefix)
        }
    }

    func replacesSwing(_ exercise: WorkoutExercise) -> Bool {
        !exercise.isAdditional && exercise.prescription.instanceId == "kettlebell-swing" && usesThursdayLegCurl
    }

    static let legCurlSkipReason = "Seated leg curl selected for this workout."
    static func omitsSwingSet(_ set: WorkoutSet) -> Bool {
        set.actual.isEmpty && (set.status == .planned || set.status == .unperformed ||
            (set.status == .skipped && set.skipReason == legCurlSkipReason))
    }

    public var recordingExercises: [WorkoutExercise] {
        guard usesThursdayLegCurl else { return exercises }
        return exercises.compactMap { exercise in
            guard !exercise.isAdditional, exercise.prescription.instanceId == "kettlebell-swing" else { return exercise }
            var recorded = exercise
            recorded.sets.removeAll(where: Self.omitsSwingSet)
            return recorded.sets.isEmpty ? nil : recorded
        }
    }
    public var plannedSetCount: Int { recordingExercises.filter(\.isEnabled).reduce(0) { $0 + $1.sets.count } }
    public var hasIncompleteWork: Bool {
        completedSetCount == 0 || recordingExercises.filter(\.isEnabled).contains { $0.sets.contains {
            $0.status != .completed || ($0.intervals?.contains { $0.status != .completed } ?? false)
        } }
    }
    public var isPartial: Bool { state == .finished && hasIncompleteWork }
    public func elapsed(at date: Date) -> TimeInterval {
        accumulatedActiveTime + (activeSegmentStartedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

    public static func start(prescription: PlanSession, planID: String, planRevisionID: String,
                             scheduledSessionID: String? = nil, ownerDeviceID: String, at date: Date,
                             timeZoneIdentifier: String, id: UUID = UUID(),
                             syncGeneration: String = UUID().uuidString,
                             makeID: () -> UUID = UUID.init) throws -> WorkoutSession {
        guard !prescription.exercises.isEmpty, prescription.exercises.count <= 1_000,
              PlanValidator.maximumExpandedIntervals(in: prescription) <= 2_000,
              prescription.exercises.allSatisfy({ !PlanValidator.validateExercise($0, legacy: true).contains { $0.severity == .error } }),
              Set(prescription.exercises.map(\.instanceId)).count == prescription.exercises.count,
              prescription.exercises.allSatisfy({ (1...20).contains($0.target.sets) && (0...900).contains($0.target.restSeconds) }),
              (try? JSONEncoder().encode(prescription)) != nil else {
            throw WorkoutStartError.invalidPrescription
        }
        guard !planID.isEmpty, !planRevisionID.isEmpty, !ownerDeviceID.isEmpty, !syncGeneration.isEmpty,
              TimeZone(identifier: timeZoneIdentifier) != nil, date.timeIntervalSinceReferenceDate.isFinite else {
            throw WorkoutStartError.invalidContext
        }
        let exercises = prescription.exercises.map { exercise in
            WorkoutExercise(id: makeID(), prescription: exercise,
                sets: WorkoutPreparation.sets(for: exercise, makeID: makeID),
                isEnabled: !exercise.optional)
        }
        let identities = [id] + exercises.map(\.id) + exercises.flatMap(\.sets).map(\.id)
            + exercises.flatMap(\.sets).flatMap { $0.intervals ?? [] }.map(\.id)
        guard Set(identities).count == identities.count else { throw WorkoutStartError.duplicateIdentity }
        return WorkoutSession(id: id, planID: planID, planRevisionID: planRevisionID,
            scheduledSessionID: scheduledSessionID, prescription: prescription, ownerDeviceID: ownerDeviceID,
            syncGeneration: syncGeneration, timeZoneIdentifier: timeZoneIdentifier, startedAt: date,
            state: .active, exercises: exercises, revision: 0, accumulatedActiveTime: 0,
            activeSegmentStartedAt: date, lastAppliedAt: date, pendingOperations: [], operationReceipts: [], conflicts: [])
    }
}

public enum WorkoutStartError: Error, LocalizedError, Equatable, Sendable {
    case invalidPrescription, invalidContext, duplicateIdentity
    public var errorDescription: String? {
        switch self {
        case .invalidPrescription: "This session has an invalid or unsupported prescription. Review the plan before starting."
        case .invalidContext: "The workout's plan, device, date, or timezone is unavailable. Try starting again."
        case .duplicateIdentity: "Workout identifiers could not be created uniquely. Try starting again."
        }
    }
}

public struct WorkoutReduction: Equatable, Sendable {
    public let session: WorkoutSession
    public let status: WorkoutReductionStatus
    public let issues: [WorkoutIssue]
    /// Includes operations drained from the durable pending queue during this reduction.
    public let appliedOperationIDs: [UUID]
}
