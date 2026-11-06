import Foundation

/// These identifiers are executable only after a separate, explicit user enrollment.
public enum BuiltInProgressionPolicy: String, Codable, CaseIterable, Sendable {
    case strength = "form-flow-strength"
    case pullUp = "form-flow-pull-up"
    case easyRun = "form-flow-easy-run"
    case longRun = "form-flow-long-run"
    public var reference: PlanPolicyReference { .init(id: rawValue, version: 1) }
}

public struct LongRunStage: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let label: String
    public let distanceKM: Double
}

public struct PullUpStep: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let sets: Int
    public let minReps: Int
    public let maxReps: Int
    public let minimumRIR: Int
    public let measurement: MeasurementKind
}

public enum BuiltInProgression {
    /// Exact source stages from lib.js LONG_RUNS, including the final recovery stage.
    public static let longRunStages: [LongRunStage] = [
        ("4.5 km", 4.5), ("4.8 km", 4.8), ("5.2 km", 5.2), ("4.5 km cutback", 4.5),
        ("5.6 km", 5.6), ("6.0 km", 6.0), ("6.5 km", 6.5), ("5.2 km cutback", 5.2),
        ("7.0 km", 7.0), ("7.6 km", 7.6), ("8.2 km", 8.2), ("6.5 km cutback", 6.5),
        ("8.8 km", 8.8), ("9.4 km", 9.4), ("10.0 km", 10.0), ("8.0 km cutback", 8.0),
        ("10.0 km repeat", 10.0), ("6–7 km recovery", 6.0)
    ].enumerated().map { LongRunStage(id: $0.offset + 1, label: $0.element.0, distanceKM: $0.element.1) }

    public static let pullUpSteps: [PullUpStep] = [
        .init(id: 1, name: "Assisted base", sets: 3, minReps: 5, maxReps: 5, minimumRIR: 2, measurement: .assistedReps),
        .init(id: 2, name: "Build assisted reps", sets: 3, minReps: 6, maxReps: 8, minimumRIR: 1, measurement: .assistedReps),
        .init(id: 3, name: "Reduce assistance", sets: 3, minReps: 5, maxReps: 8, minimumRIR: 1, measurement: .assistedReps),
        .init(id: 4, name: "Clean singles and assisted back-off sets", sets: 5, minReps: 1, maxReps: 1, minimumRIR: 1, measurement: .assistedReps),
        .init(id: 5, name: "Repeatable doubles", sets: 4, minReps: 2, maxReps: 2, minimumRIR: 1, measurement: .assistedReps),
        .init(id: 6, name: "Build to five", sets: 3, minReps: 3, maxReps: 5, minimumRIR: 1, measurement: .reps)
    ]
}

public enum ProgressionAnswer: String, Codable, CaseIterable, Sendable { case yes, no, unknown, difficult }

/// User answers are separate from actual set values and are never inferred from sensors.
public struct ProgressionAnswers: Codable, Equatable, Sendable {
    public var technique: ProgressionAnswer
    public var reserve: Int?
    public var conversational: ProgressionAnswer
    public var readySingle: ProgressionAnswer
    public var duringRating: Int?
    public init(technique: ProgressionAnswer = .unknown, reserve: Int? = nil,
                conversational: ProgressionAnswer = .unknown, readySingle: ProgressionAnswer = .unknown,
                duringRating: Int? = nil) {
        self.technique = technique; self.reserve = reserve; self.conversational = conversational
        self.readySingle = readySingle; self.duringRating = duringRating
    }
}

public struct ProgressionConfiguration: Codable, Equatable, Sendable {
    public var policy: PlanPolicyReference?
    public var optedIn: Bool
    public var variantID: String
    public var pullUpStep: Int?
    public var longRunStage: Int?
    public init(policy: PlanPolicyReference? = nil, optedIn: Bool = false, variantID: String = "",
                pullUpStep: Int? = nil, longRunStage: Int? = nil) {
        self.policy = policy; self.optedIn = optedIn; self.variantID = variantID
        self.pullUpStep = pullUpStep; self.longRunStage = longRunStage
    }
    public var implementedPolicy: BuiltInProgressionPolicy? {
        guard policy?.version == 1, let id = policy?.id else { return nil }
        return BuiltInProgressionPolicy(rawValue: id)
    }
}

/// A frozen completed workout plus its explicitly associated coaching/recovery inputs.
public struct ProgressionExposure: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { exerciseID }
    public let session: WorkoutSession
    public let exerciseID: UUID
    public let configuration: ProgressionConfiguration
    public let answers: ProgressionAnswers
    public let recovery: [SessionRecoveryRecord]
    public init(session: WorkoutSession, exerciseID: UUID, configuration: ProgressionConfiguration,
                answers: ProgressionAnswers = .init(), recovery: [SessionRecoveryRecord] = []) throws {
        guard session.state == .finished, session.endedAt != nil,
              session.exercises.contains(where: { $0.id == exerciseID }),
              WorkoutSessionValidator.validate(session).isEmpty,
              answers.reserve.map({ (0...10).contains($0) }) ?? true,
              answers.duringRating.map({ (0...4).contains($0) }) ?? true else { throw ProgressionError.invalidExposure }
        self.session = session; self.exerciseID = exerciseID; self.configuration = configuration
        self.answers = answers; self.recovery = recovery.filter { $0.sessionID == session.id }
    }
    public var exercise: WorkoutExercise { session.exercises.first { $0.id == exerciseID }! }
    public var completionDay: LocalTrainingDay {
        LocalTrainingDay(instant: session.endedAt!, timeZone: TimeZone(identifier: session.timeZoneIdentifier)!)
    }
    private enum CodingKeys: String, CodingKey { case session, exerciseID, configuration, answers, recovery }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(session: c.decode(WorkoutSession.self, forKey: .session),
                      exerciseID: c.decode(UUID.self, forKey: .exerciseID),
                      configuration: c.decode(ProgressionConfiguration.self, forKey: .configuration),
                      answers: c.decode(ProgressionAnswers.self, forKey: .answers),
                      recovery: c.decode([SessionRecoveryRecord].self, forKey: .recovery))
    }
}

public enum ProgressionAction: String, Codable, Sendable { case manual, pending, reduce, repeatTarget, increase, step, stage }

public struct ProgressionAdvice: Equatable, Sendable {
    public let action: ProgressionAction
    public let title: String
    public let detail: String
    public let nextStep: Int?
    public let nextStage: Int?
    public let qualifyingSessions: Int
    public let planRevisionID: String
    public let source: ProgressionExposure
    public let legacyEvidence: [LegacyProgressionEvidence]
    public let usedLegacyRecordKey: String?
    fileprivate let evidence: [ProgressionExposure]
    public var canAccept: Bool { ![.manual, .pending].contains(action) }
}

/// An accepted future instruction. It deliberately cannot mutate a workout or plan.
public struct FutureProgressionTarget: Codable, Equatable, Sendable {
    public let sourceSessionID: UUID
    public let sourceExerciseID: UUID
    public let planID: String
    public let planRevisionID: String
    public let exerciseID: String
    public let variantID: String
    public let policy: PlanPolicyReference
    public let action: ProgressionAction
    public let measurement: MeasurementKind
    public let load: PlanQuantity?
    public let assistance: PlanQuantity?
    public let restartReps: Int?
    public let pullUpStep: Int?
    public let longRunStage: Int?
    public let longRunDistance: PlanQuantity?
    public let legacyEvidenceReferences: [LegacyProgressionReference]?
    public let acceptedAt: Date
}

public enum ProgressionError: Error, Equatable, LocalizedError, Sendable {
    case invalidExposure, notActionable, stalePlan, staleHistory, invalidLoad, unavailableEquipmentLoad
    public var errorDescription: String? {
        switch self {
        case .invalidExposure: "Review a valid finished workout before requesting progression."
        case .notActionable: "This recommendation does not authorize a future target change."
        case .stalePlan: "The current plan or progression changed. Review the recommendation again."
        case .staleHistory: "Relevant workout or recovery history changed. Review the latest result again."
        case .invalidLoad: "Enter a valid load in the suggested direction from every completed working set."
        case .unavailableEquipmentLoad: "Select a load or assistance setting confirmed available on your equipment."
        }
    }
}

public enum ProgressionEngine {
    /// Missing per-set RIR is retained as unknown, even when other sets have a value.
    public static func recordedReserve(_ exposure: ProgressionExposure) -> Int? {
        let sets = completed(exposure)
        guard !sets.isEmpty, sets.allSatisfy({ $0.actual.rir != nil }) else { return nil }
        return sets.compactMap(\.actual.rir).min()
    }

    public static func advice(for source: ProgressionExposure, history: [ProgressionExposure],
                              currentPlanRevisionID: String, asOf now: Date,
                              legacyHistory: [LegacyProgressionEvidence] = []) -> ProgressionAdvice {
        let evidence = relevant(source, history: history)
        let legacyEvidence = relevantLegacy(source, history: legacyHistory)
        var usedLegacyRecordKey: String?
        func result(_ action: ProgressionAction, _ title: String, _ detail: String,
                    step: Int? = nil, stage: Int? = nil, count: Int = 0) -> ProgressionAdvice {
            .init(action: action, title: title, detail: detail, nextStep: step, nextStage: stage,
                  qualifyingSessions: count, planRevisionID: currentPlanRevisionID, source: source,
                  legacyEvidence: legacyEvidence, usedLegacyRecordKey: usedLegacyRecordKey, evidence: evidence)
        }
        guard source.configuration.optedIn, let policy = source.configuration.implementedPolicy else {
            return result(.manual, "Progression is manual", "Choose a supported policy explicitly during plan review to enable suggestions.")
        }
        guard policyRequirementsMet(source), !currentPlanRevisionID.isEmpty else {
            return result(.manual, "Review the progression targets", "The selected policy needs compatible, valid typed targets. Continue manual logging.")
        }
        let recovery = recoveryState(source, asOf: now)
        if recovery.ratings.contains(where: { $0 >= 3 }) {
            return result(.pending, "Pause the provoking exercise", "Stop for sharp or limiting symptoms; seek assessment for persistent worsening or red flags. No increase is suggested.")
        }
        let sets = completed(source)
        guard !sets.isEmpty else { return result(.pending, "Log your result first", "Only completed sets count toward progression.") }
        let run = policy == .easyRun || policy == .longRun
        if recovery.readiness == .no || recovery.ratings.contains(where: { $0 > 1 }) ||
            [.difficult, .no].contains(source.answers.technique) || (!run && effort(source).map { $0 < minimumRIR(source) } == true) {
            return result(.reduce, run ? "Make the next run easier" : "Reduce the difficulty",
                          run ? "Run easily, shorten the distance or use walk breaks. Wait for your usual recovery before progressing." :
                            "Use less load or more pull-up assistance, and stop with the prescribed reps in reserve.")
        }
        if run {
            let rpes = sets.map(\.actual.rpe)
            if source.answers.conversational == .no || rpes.contains(where: { ($0 ?? 0) > 4 }) {
                return result(.repeatTarget, "Repeat at an easier pace", "Keep it conversational; walk breaks are fine. Do not extend the distance yet.")
            }
            let conversational = source.answers.conversational == .yes || rpes.allSatisfy { $0 != nil && $0! <= 4 }
            guard conversational, recovery.readiness != .unknown else {
                return result(.pending, "Keep the current run target", !conversational ?
                              "Confirm whether the run was conversational. Missing effort does not qualify for an increase." :
                                "Complete the following-morning recovery check before increasing distance.")
            }
            if policy == .longRun, let stage = source.configuration.longRunStage,
               distanceKM(source) + 0.05 >= BuiltInProgression.longRunStages[stage - 1].distanceKM,
               stage < BuiltInProgression.longRunStages.count {
                return result(.stage, "Ready for the next long-run stage", "The distance was completed at easy effort and recovery is back to normal.", stage: stage + 1, count: 1)
            }
            return result(.repeatTarget, "Keep the current run target", policy == .longRun ?
                          "Repeat until the planned distance is comfortable." : "Keep this run easy. Progress the long run separately, one lower-body stressor at a time.")
        }
        guard source.answers.technique == .yes, effort(source) != nil else {
            return result(.pending, "Keep your current plan", source.answers.technique != .yes ?
                          "Confirm clean technique before progressing." : "Add your reps in reserve, or choose Not sure and repeat.")
        }
        guard recovery.readiness != .unknown else {
            return result(.pending, "Recovery check pending", "Your answers are saved. Suggestions wait for the following-morning recovery check.")
        }
        guard performanceQualified(source) else {
            return result(.repeatTarget, "Keep the same difficulty", "Build toward all working sets at the target with clean technique; keep the current difficulty.")
        }
        // A newer nonqualifying exposure breaks the chain. An unrelated plan revision does not.
        let prior = evidence.filter { $0.session.id != source.session.id && $0.session.endedAt! < source.session.endedAt! }.last
        var priorQualified = prior.map { $0.completionDay.date < source.completionDay.date && matchingDose(source, $0) && isQualified($0, asOf: now) } ?? false
        if let latestLegacy = legacyEvidence.filter({ $0.date <= source.completionDay.date }).last,
           prior == nil || latestLegacy.date >= prior!.completionDay.date {
            // Date-only entries cannot be ordered within a native workout's day or each other.
            let today = LocalTrainingDay(instant: now, timeZone: TimeZone(identifier: source.session.timeZoneIdentifier)!).date
            priorQualified = latestLegacy.date < source.completionDay.date &&
                latestLegacy.date != prior?.completionDay.date &&
                legacyEvidence.filter({ $0.date == latestLegacy.date }).count == 1 &&
                latestLegacy.matchesDose(of: source) && latestLegacy.isQualified(asOfDate: today)
            if priorQualified { usedLegacyRecordKey = latestLegacy.recordKey }
        }
        let count = 1 + (priorQualified ? 1 : 0)
        guard count == 2 else {
            return result(.repeatTarget, "One qualifying session — repeat once more", "Meet the same target at the same difficulty, with clean technique and normal recovery, before increasing.", count: count)
        }
        if policy == .pullUp, let step = source.configuration.pullUpStep {
            if step == 3, source.answers.readySingle != .yes {
                return result(.repeatTarget, "Keep building with assistance", "Before singles, confirm low practical assistance and a clean unassisted rep with another in reserve.", count: count)
            }
            if step == 6 { return result(.repeatTarget, "Five clean reps achieved", "Keep this step and gradually build total clean repetitions.", count: count) }
            return result(.step, "Ready for pull-up Step \(step + 1)", "Two sessions met the target with reserve and stable recovery. Accept to change future sessions.", step: step + 1, count: count)
        }
        return result(.increase, "Add the smallest available load", "Two sessions met every set’s top rep target with enough reserve and normal recovery. Restart near the lower end of the rep range.", count: count)
    }

    public static func isQualified(_ exposure: ProgressionExposure, asOf now: Date) -> Bool {
        let recovery = recoveryState(exposure, asOf: now)
        guard exposure.configuration.optedIn && policyRequirementsMet(exposure) &&
            recovery.readiness == .yes && !recovery.ratings.contains(where: { $0 > 1 }) else { return false }
        if [.easyRun, .longRun].contains(exposure.configuration.implementedPolicy) {
            guard easyEffort(exposure), ![.no, .difficult].contains(exposure.answers.technique) else { return false }
            if let distance = exposure.exercise.prescription.target.distance {
                return distanceKM(exposure) + 0.05 >= (kilometers(.init(value: distance.min, unit: distance.unit)) ?? .infinity)
            }
            guard let duration = exposure.exercise.prescription.target.duration else { return false }
            let requiredSeconds = duration.min * (duration.unit == .min ? 60 : 1)
            return completed(exposure).contains { ($0.actual.durationSeconds ?? 0) >= requiredSeconds }
        }
        return performanceQualified(exposure)
    }

    /// Rechecks the latest stored snapshots and requires a concrete available equipment setting.
    /// The caller must persist the returned value before displaying it as accepted.
    public static func accept(_ recommendation: ProgressionAdvice, currentPlanID: String,
                              currentPlanRevisionID: String, currentExercise: PlanExercise,
                              configuration: ProgressionConfiguration, history: [ProgressionExposure],
                              enteredLoad: PlanQuantity? = nil, availableEquipmentLoads: [PlanQuantity] = [],
                              legacyHistory: [LegacyProgressionEvidence] = [],
                              at now: Date) throws -> FutureProgressionTarget {
        let source = recommendation.source
        guard recommendation.canAccept else { throw ProgressionError.notActionable }
        guard currentPlanID == source.session.planID, currentPlanRevisionID == recommendation.planRevisionID,
              configuration == source.configuration, currentExercise.exerciseId == source.exercise.prescription.exerciseId,
              currentExercise.measurement == source.exercise.prescription.measurement,
              currentExercise.target == source.exercise.prescription.target,
              currentExercise.equipment == source.exercise.prescription.equipment,
              (currentExercise.progressionPolicy == nil || samePolicy(currentExercise.progressionPolicy, source.configuration.policy)) else { throw ProgressionError.stalePlan }
        guard let currentSource = history.first(where: { $0.id == source.id }), currentSource == source,
              relevant(source, history: history) == recommendation.evidence,
              relevantLegacy(source, history: legacyHistory) == recommendation.legacyEvidence,
              !legacyHistory.contains(where: { $0.planID == source.session.planID && $0.exerciseID == source.exercise.prescription.exerciseId && $0.date > source.completionDay.date }),
              !history.contains(where: { sameExercise(source, $0) && $0.session.endedAt! > source.session.endedAt! }),
              advice(for: currentSource, history: history, currentPlanRevisionID: currentPlanRevisionID, asOf: now, legacyHistory: legacyHistory) == recommendation else {
            throw ProgressionError.staleHistory
        }
        let policy = configuration.implementedPolicy!
        let run = policy == .easyRun || policy == .longRun
        let assistance = policy == .pullUp
        let needsLoad = !run && ([ProgressionAction.increase, .reduce].contains(recommendation.action) || recommendation.nextStep == 3)
        var selected: PlanQuantity?
        if needsLoad {
            guard let enteredLoad, enteredLoad.value <= 10_000, let value = kilograms(enteredLoad), value >= 0, value <= 10_000 else { throw ProgressionError.invalidLoad }
            let values = difficultyValues(source)
            guard !values.isEmpty, values.allSatisfy({ $0 != nil }) else { throw ProgressionError.invalidLoad }
            let known = values.compactMap { $0 }
            let correctDirection = recommendation.action == .increase ? value > known.max()! :
                recommendation.nextStep == 3 ? value < known.min()! : assistance ? value > known.max()! : value < known.min()!
            guard correctDirection else { throw ProgressionError.invalidLoad }
            guard availableEquipmentLoads.contains(where: { kilograms($0).map { nearlyEqual($0, value) } == true }) else {
                throw ProgressionError.unavailableEquipmentLoad
            }
            selected = enteredLoad
        } else if enteredLoad != nil { throw ProgressionError.invalidLoad }
        if recommendation.nextStep == 2, selected == nil,
           let largest = completed(source).compactMap(\.actual.assistance).max(by: { kilograms($0)! < kilograms($1)! }) {
            selected = largest
        }
        let stage = recommendation.nextStage ?? configuration.longRunStage
        return .init(sourceSessionID: source.session.id, sourceExerciseID: source.exerciseID,
                     planID: currentPlanID, planRevisionID: currentPlanRevisionID,
                     exerciseID: source.exercise.prescription.exerciseId, variantID: configuration.variantID,
                     policy: configuration.policy!, action: recommendation.action,
                     measurement: assistance && selected != nil ? .assistedReps : source.exercise.prescription.measurement,
                     load: assistance ? nil : selected, assistance: assistance ? selected : nil,
                     restartReps: recommendation.action == .increase ? source.exercise.prescription.target.reps?.min : nil,
                     pullUpStep: recommendation.nextStep ?? configuration.pullUpStep, longRunStage: stage,
                     longRunDistance: stage.map { .init(value: BuiltInProgression.longRunStages[$0 - 1].distanceKM, unit: .km) },
                     legacyEvidenceReferences: recommendation.usedLegacyRecordKey.flatMap { key in
                         recommendation.legacyEvidence.first { $0.recordKey == key }.map { [$0.reference] }
                     }, acceptedAt: now)
    }

    /// Distinct finished sessions at easy effort and recovered next morning; used by the Block 2 gate.
    public static func qualifiedTenKMRunCount(_ history: [ProgressionExposure], asOf now: Date) -> Int {
        Set(history.filter { exposure in
            [.easyRun, .longRun].contains(exposure.configuration.implementedPolicy) &&
            exposure.configuration.optedIn && policyRequirementsMet(exposure) &&
            distanceKM(exposure) + 0.05 >= 10 && recoveryState(exposure, asOf: now).readiness == .yes &&
            !recoveryState(exposure, asOf: now).ratings.contains(where: { $0 > 1 }) && easyEffort(exposure)
        }.map(\.session.id)).count
    }

    private static func completed(_ exposure: ProgressionExposure) -> [WorkoutSet] { exposure.exercise.sets.filter { $0.status == .completed } }
    private static func effort(_ exposure: ProgressionExposure) -> Int? {
        if let logged = recordedReserve(exposure) { return logged }
        guard let answer = exposure.answers.reserve else { return nil }
        return ([answer] + completed(exposure).compactMap(\.actual.rir)).min()
    }
    private static func minimumRIR(_ exposure: ProgressionExposure) -> Int { exposure.exercise.prescription.target.effort?.min ?? 0 }
    private static func performanceQualified(_ exposure: ProgressionExposure) -> Bool {
        guard policyRequirementsMet(exposure), exposure.answers.technique == .yes,
              let reserve = effort(exposure), reserve >= minimumRIR(exposure) else { return false }
        let sets = completed(exposure), prescription = exposure.exercise.prescription
        guard !sets.isEmpty, sets.count == prescription.target.sets, let reps = prescription.target.reps else { return false }
        func meets(_ set: WorkoutSet, _ target: Int) -> Bool { (set.actual.reps ?? -1) >= target }
        func unassisted(_ set: WorkoutSet) -> Bool { prescription.measurement == .reps || set.actual.assistance?.value == 0 }
        if exposure.configuration.implementedPolicy == .pullUp {
            switch exposure.configuration.pullUpStep {
            case 4: return sets.count == 5 && sets.prefix(3).allSatisfy { meets($0, 1) && unassisted($0) } &&
                sets.suffix(2).allSatisfy { meets($0, 5) && ($0.actual.assistance?.value ?? 0) > 0 }
            case 5: return sets.allSatisfy { meets($0, reps.max) && unassisted($0) }
            case 6: return meets(sets[0], 5) && sets.allSatisfy { meets($0, 3) && unassisted($0) }
            default: return sets.allSatisfy { meets($0, reps.max) && kilograms($0.actual.assistance) != nil }
            }
        }
        return sets.allSatisfy { meets($0, reps.max) && kilograms($0.actual.load) != nil }
    }
    private static func policyRequirementsMet(_ exposure: ProgressionExposure) -> Bool {
        exposure.exercise.selectedAlternativeID == nil && !exposure.exercise.isAdditional &&
            supports(configuration: exposure.configuration, exercise: exposure.exercise.prescription)
    }
    /// Suitable for plan review. This reports capability, not consent; optedIn is checked separately.
    public static func supports(configuration config: ProgressionConfiguration, exercise p: PlanExercise) -> Bool {
        let t = p.target
        let validationPlan = WeeklyPlan(id: "progression-check", name: "Progression check", days: [
            .init(weekday: .monday, sessions: [.init(id: "check", name: "Check", kind: "mixed", estimatedMinutes: 1, exercises: [p])])
        ])
        guard let policy = config.implementedPolicy, (p.progressionPolicy == nil || samePolicy(p.progressionPolicy, config.policy)),
              (policy == .pullUp || config.pullUpStep == nil), (policy == .longRun || config.longRunStage == nil),
              !PlanValidator.validate(validationPlan).contains(where: { $0.severity == .error }) else { return false }
        switch policy {
        case .strength:
            return p.measurement == .weightReps && validReps(t.reps) && t.effort?.kind == .rir &&
                (1...10).contains(t.effort?.min ?? 0) && (t.effort!.min...10).contains(t.effort!.max)
        case .pullUp:
            guard let step = config.pullUpStep, (1...6).contains(step) else { return false }
            let expected = BuiltInProgression.pullUpSteps[step - 1]
            return [.assistedReps, .reps].contains(p.measurement) && (step >= 4 || p.measurement == .assistedReps) &&
                t.sets == expected.sets && t.reps == RepRange(min: expected.minReps, max: expected.maxReps) &&
                t.effort?.kind == .rir && t.effort?.min == expected.minimumRIR &&
                (expected.minimumRIR...10).contains(t.effort?.max ?? -1)
        case .easyRun, .longRun:
            if policy == .easyRun, [.distanceTime, .duration].contains(p.measurement), t.sets == 1, t.duration != nil {
                return config.longRunStage == nil
            }
            guard [.distanceTime, .distance].contains(p.measurement), t.sets == 1, let distance = t.distance,
                  distance.min > 0, distance.max >= distance.min, let km = kilometers(.init(value: distance.min, unit: distance.unit)) else { return false }
            if policy == .easyRun { return config.longRunStage == nil }
            guard let stage = config.longRunStage, (1...18).contains(stage) else { return false }
            return nearlyEqual(km, BuiltInProgression.longRunStages[stage - 1].distanceKM)
        }
    }
    private static func validReps(_ reps: RepRange?) -> Bool {
        guard let reps else { return false }; return reps.min > 0 && reps.max >= reps.min && reps.max <= 1_000
    }
    private static func recoveryState(_ exposure: ProgressionExposure, asOf now: Date) -> (readiness: RecoveryReadiness, ratings: [Int]) {
        let day = exposure.completionDay
        let today = LocalTrainingDay(instant: now, timeZone: TimeZone(identifier: day.timeZoneID)!).date
        let valid = exposure.recovery.filter {
            $0.sessionID == exposure.session.id && $0.day.timeZoneID == day.timeZoneID && $0.updatedAt <= now &&
            $0.day.date <= today && (try? $0.validate()) != nil &&
            ($0.phase == .evening ? $0.day.date == day.date : $0.day.date > day.date)
        }
        let evening = valid.filter { $0.phase == .evening }.max { $0.updatedAt < $1.updatedAt }
        let morning = today > day.date ? valid.filter { $0.phase == .nextMorning }.max { $0.updatedAt < $1.updatedAt } : nil
        return (morning?.effectiveReadiness ?? .unknown,
                [exposure.answers.duringRating, evening?.rating, morning?.rating].compactMap { $0 })
    }
    private static func samePolicy(_ a: PlanPolicyReference?, _ b: PlanPolicyReference?) -> Bool {
        a?.id == b?.id && a?.version == b?.version
    }
    private static func sameExercise(_ a: ProgressionExposure, _ b: ProgressionExposure) -> Bool {
        a.session.planID == b.session.planID && a.exercise.prescription.exerciseId == b.exercise.prescription.exerciseId &&
            a.configuration.variantID == b.configuration.variantID
    }
    private static func relevant(_ source: ProgressionExposure, history: [ProgressionExposure]) -> [ProgressionExposure] {
        var entries = history.filter { sameExercise(source, $0) && $0.id != source.id }
        entries.append(source)
        return entries.sorted {
            if $0.session.endedAt == $1.session.endedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.session.endedAt! < $1.session.endedAt!
        }
    }
    private static func relevantLegacy(_ source: ProgressionExposure, history: [LegacyProgressionEvidence]) -> [LegacyProgressionEvidence] {
        var unique: [String: LegacyProgressionEvidence] = [:]
        for item in history where item.planID == source.session.planID && item.exerciseID == source.exercise.prescription.exerciseId {
            // Identical delivery is deduplicated; conflicting copies remain same-day ambiguity.
            unique["\(item.id):\(item.sourceFingerprint)"] = item
        }
        return unique.values.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.recordKey != $1.recordKey { return $0.recordKey < $1.recordKey }
            return $0.sourceFingerprint < $1.sourceFingerprint
        }
    }
    private static func matchingDose(_ a: ProgressionExposure, _ b: ProgressionExposure) -> Bool {
        guard a.configuration.implementedPolicy == b.configuration.implementedPolicy,
              a.configuration.variantID == b.configuration.variantID,
              a.configuration.pullUpStep == b.configuration.pullUpStep,
              a.exercise.prescription.measurement == b.exercise.prescription.measurement,
              a.exercise.prescription.equipment == b.exercise.prescription.equipment,
              a.exercise.prescription.target == b.exercise.prescription.target else { return false }
        let av = difficultyValues(a), bv = difficultyValues(b)
        return av.count == bv.count && zip(av, bv).allSatisfy { x, y in
            if let x, let y { return nearlyEqual(x, y) }; return x == nil && y == nil
        }
    }
    private static func difficultyValues(_ exposure: ProgressionExposure) -> [Double?] {
        completed(exposure).map { set in
            exposure.configuration.implementedPolicy == .pullUp ?
                (exposure.exercise.prescription.measurement == .reps ? 0 : kilograms(set.actual.assistance)) : kilograms(set.actual.load)
        }
    }
    private static func easyEffort(_ exposure: ProgressionExposure) -> Bool {
        let sets = completed(exposure)
        return !sets.isEmpty && exposure.answers.conversational != .no &&
            !sets.contains { ($0.actual.rpe ?? 0) > 4 } &&
            (exposure.answers.conversational == .yes || sets.allSatisfy { $0.actual.rpe != nil && $0.actual.rpe! <= 4 })
    }
    private static func distanceKM(_ exposure: ProgressionExposure) -> Double {
        completed(exposure).compactMap { kilometers($0.actual.distance) }.max() ?? 0
    }
    private static func kilograms(_ quantity: PlanQuantity?) -> Double? {
        guard let quantity, quantity.value.isFinite, quantity.value >= 0 else { return nil }
        switch quantity.unit { case .kg: return quantity.value; case .lb: return quantity.value * 0.45359237; default: return nil }
    }
    private static func kilometers(_ quantity: PlanQuantity?) -> Double? {
        guard let quantity, quantity.value.isFinite, quantity.value >= 0 else { return nil }
        switch quantity.unit { case .km: return quantity.value; case .m: return quantity.value / 1_000; case .mi: return quantity.value * 1.609344; default: return nil }
    }
    private static func nearlyEqual(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= max(1, max(abs(a), abs(b))) * 0.000_001 }
}
