import Foundation

public struct LegacyProgressionReference: Codable, Equatable, Sendable {
    public let recordID: String
    public let exerciseID: String
    public let date: String
    public let fingerprint: String
}

/// Date-only evidence from a preserved web workout. This is never a native recording or Health session.
public struct LegacyProgressionEvidence: Equatable, Sendable, Identifiable {
    public var id: String { "\(recordKey):\(exerciseID)" }
    public let recordKey: String
    public let sourceFingerprint: String
    public let date: String
    public let planID: String
    public let exerciseID: String
    public let variantID: String
    public let measurement: MeasurementKind?
    public let timeZoneAssumption: String?
    public let hasPendingDraft: Bool
    public let policy: BuiltInProgressionPolicy?
    public let pullUpStep: Int?
    public let targetSets: Int?
    public let minReps: Int?
    public let maxReps: Int?
    public let minimumRIR: Int?
    public let completedActuals: [WorkoutSetValues]
    public private(set) var qualificationIssues: [String] = []

    /// Unknown or unsuccessful entries remain evidence, so a newer failed attempt cannot be skipped.
    public init?(record: BackupRecord, exerciseID: String) {
        guard record.category == .workouts, let log = record.payload["log"],
              log["nativeNormalizationVersion"] == .number(1),
              let date = log["date"]?.string, LocalTrainingDay.isValidDate(date),
              let exercise = log["exercises"]?[exerciseID] else { return nil }
        recordKey = record.key; sourceFingerprint = record.fingerprint
        self.date = date; planID = log["planId"]?.string ?? "form-flow"; self.exerciseID = exerciseID
        variantID = exercise["variantId"]?.string ?? ""
        measurement = exercise["measurement"]?.string.flatMap(MeasurementKind.init(rawValue:))
        timeZoneAssumption = record.payload["legacyTimeZoneAssumption"]?.string
        hasPendingDraft = record.payload["pendingDraft"] != nil
        let plan = exercise["coachingPlan"]
        switch plan?["kind"]?.string {
        case "strength": policy = .strength
        case "pullup": policy = .pullUp
        default: policy = nil
        }
        targetSets = Self.integer(plan?["sets"], range: 1...20)
        minReps = Self.integer(plan?["minReps"], range: 1...1_000)
        maxReps = Self.integer(plan?["maxReps"], range: 1...1_000)
        minimumRIR = Self.integer(plan?["minRir"], range: 1...10)
        pullUpStep = Self.integer(exercise["progressionStep"], range: 1...6)
        let rawSets = exercise["sets"]?.array ?? []
        let completed = rawSets.filter { $0["completed"] == .bool(true) }
        completedActuals = completed.prefix(1_000).map { value in
            .init(reps: Self.integer(value["reps"], range: 0...10_000),
                  load: Self.quantity(value["weight"]), assistance: Self.quantity(value["assistance"]),
                  rir: Self.integer(value["rir"], range: 0...10))
        }
        var issues: [String] = []
        if planID != "form-flow" { issues.append("This record belongs to another plan; built-in progression does not use it.") }
        if !Self.builtInExerciseIDs.contains(exerciseID) { issues.append("The original exercise identity is not in the built-in program.") }
        if policy == nil { issues.append("No supported strength or pull-up target snapshot was recorded. Progression remains manual.") }
        if targetSets == nil || minReps == nil || maxReps == nil || minimumRIR == nil || (minReps ?? 0) > (maxReps ?? 0) {
            issues.append("The recorded target or required reserve is incomplete.")
        }
        if rawSets.count > 1_000 || completed.isEmpty || completed.count != targetSets {
            issues.append("The prescribed number of completed working sets is not available.")
        }
        if rawSets.contains(where: { $0["completed"] != nil && $0["completed"] != .bool(true) && $0["completed"] != .bool(false) }) {
            issues.append("A completion flag is not explicit.")
        }
        let coaching = exercise["coaching"]
        if coaching?["technique"]?.string != "yes" { issues.append("Clean technique was not explicitly confirmed.") }
        let knownRIR = completedActuals.compactMap(\.rir)
        let answer = Self.integer(coaching?["reserve"], range: 0...10)
        let reserve = knownRIR.count == completed.count ? knownRIR.min() : answer.map { ([ $0 ] + knownRIR).min() ?? $0 }
        if reserve == nil || (reserve ?? -1) < (minimumRIR ?? 11) { issues.append("The recorded effort does not establish the required reserve.") }
        let response = log["response"]
        func rating(_ key: String) -> Int? { Self.integer(response?[key], range: 0...4) }
        let readiness = response?["readiness"]?.string
        // Match normalized web recovery: an explicit unknown wins over an otherwise mild rating.
        let next = rating("painNext")
        let recovered = next.map { $0 <= 1 } != false &&
            (readiness == "yes" || (readiness == nil && next != nil))
        if response?["scaleVersion"] != .number(2) || !recovered || ["painDuring", "painLater", "painNext"].contains(where: {
            if let raw = response?[$0], raw != .string("") && raw != .null { return rating($0) == nil || (rating($0) ?? 0) > 1 }
            return false
        }) { issues.append("Following-morning recovery is missing, unknown or not back to normal.") }
        if policy == .strength {
            if measurement != .weightReps || !completedActuals.allSatisfy({ $0.load != nil && ($0.reps ?? -1) >= (maxReps ?? Int.max) }) {
                issues.append("Recorded strength sets do not meet the explicit target with known loads.")
            }
        } else if policy == .pullUp {
            guard let step = pullUpStep else {
                issues.append("The pull-up step is missing."); qualificationIssues = issues; return
            }
            let expected = BuiltInProgression.pullUpSteps[step - 1]
            if targetSets != expected.sets || minReps != expected.minReps || maxReps != expected.maxReps || minimumRIR != expected.minimumRIR {
                issues.append("The recorded pull-up target does not match its supported step.")
            }
            func reps(_ set: WorkoutSetValues, _ min: Int) -> Bool { (set.reps ?? -1) >= min }
            func unassisted(_ set: WorkoutSetValues) -> Bool { measurement == .reps || set.assistance?.value == 0 }
            let meets: Bool
            switch step {
            case 4:
                meets = completedActuals.count == 5 && completedActuals.prefix(3).allSatisfy { reps($0, 1) && unassisted($0) } &&
                    completedActuals.suffix(2).allSatisfy { reps($0, 5) && ($0.assistance?.value ?? 0) > 0 }
            case 5: meets = completedActuals.allSatisfy { reps($0, 2) && unassisted($0) }
            case 6: meets = completedActuals.first.map { reps($0, 5) } == true && completedActuals.allSatisfy { reps($0, 3) && unassisted($0) }
            default: meets = measurement == .assistedReps && completedActuals.allSatisfy { reps($0, expected.maxReps) && $0.assistance != nil }
            }
            if measurement.map({ ![MeasurementKind.assistedReps, .reps].contains($0) }) ?? true || !meets {
                issues.append("Recorded pull-up work does not satisfy the explicit step.")
            }
        }
        qualificationIssues = issues
    }

    public func isQualified(asOfDate: String) -> Bool { date < asOfDate && qualificationIssues.isEmpty }

    var reference: LegacyProgressionReference {
        .init(recordID: String(recordKey.dropFirst("workouts:".count)), exerciseID: exerciseID,
              date: date, fingerprint: sourceFingerprint)
    }

    func matchesDose(of source: ProgressionExposure) -> Bool {
        let exercise = source.exercise.prescription, config = source.configuration
        guard planID == source.session.planID, planID == "form-flow", exerciseID == exercise.exerciseId,
              variantID == config.variantID, measurement == exercise.measurement,
              policy == config.implementedPolicy, pullUpStep == config.pullUpStep,
              targetSets == exercise.target.sets, minReps == exercise.target.reps?.min,
              maxReps == exercise.target.reps?.max, minimumRIR == exercise.target.effort?.min,
              exercise.equipment.isEmpty else { return false }
        // Web records identify built-in variants but did not store equipment arrays. Changed native equipment cannot be assumed comparable.
        let native = source.exercise.sets.filter { $0.status == .completed }.map(\.actual)
        guard native.count == completedActuals.count else { return false }
        func difficulty(_ values: WorkoutSetValues) -> Double? {
            if policy == .pullUp { return measurement == .reps ? 0 : WorkoutTrends.kilograms(values.assistance) }
            return WorkoutTrends.kilograms(values.load)
        }
        return zip(native, completedActuals).allSatisfy { first, second in
            guard let a = difficulty(first), let b = difficulty(second) else { return false }
            return abs(a - b) <= max(1, max(abs(a), abs(b))) * 0.000_001
        }
    }

    private static let builtInExerciseIDs: Set<String> = {
        Set(((try? BuiltInPlans.plan())?.days.flatMap(\.sessions).flatMap(\.exercises) ?? []).map(\.exerciseId))
    }()
    private static func integer(_ value: BackupJSONValue?, range: ClosedRange<Int>) -> Int? {
        guard let number = value?.number, number.isFinite, number.rounded() == number,
              number >= Double(range.lowerBound), number <= Double(range.upperBound) else { return nil }
        return Int(number)
    }
    private static func quantity(_ value: BackupJSONValue?) -> PlanQuantity? {
        guard let number = value?.number, number.isFinite, (0...10_000).contains(number) else { return nil }
        return .init(value: number, unit: .kg)
    }
}
