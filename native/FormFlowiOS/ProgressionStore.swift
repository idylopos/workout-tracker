import Foundation
import Observation
import SwiftData
import FormFlowCore

@Model
final class ProgressionRecord {
    @Attribute(.unique) var id: String
    var payload: Data
    init(id: String, payload: Data) { self.id = id; self.payload = payload }
}

struct ProgressionEnrollment: Codable, Equatable, Identifiable {
    let planID: String
    let planRevisionID: String
    let sessionID: String
    let exercise: PlanExercise
    let configuration: ProgressionConfiguration
    let updatedAt: Date
    var id: String { Self.key(planRevisionID: planRevisionID, sessionID: sessionID, instanceID: exercise.instanceId) }
    static func key(planRevisionID: String, sessionID: String, instanceID: String) -> String {
        "enrollment:\(planRevisionID):\(sessionID):\(instanceID)"
    }
}

struct ProgressionCoachingRecord: Codable, Equatable, Identifiable {
    let workoutID: UUID
    let exerciseID: UUID
    let answers: ProgressionAnswers
    let updatedAt: Date
    var id: String { "coaching:\(workoutID.uuidString):\(exerciseID.uuidString)" }
}

private enum SavedProgression: Codable, Equatable {
    case enrollment(ProgressionEnrollment), coaching(ProgressionCoachingRecord), accepted(FutureProgressionTarget)
    var id: String {
        switch self {
        case .enrollment(let value): value.id
        case .coaching(let value): value.id
        case .accepted(let value): "accepted:\(value.sourceSessionID.uuidString):\(value.sourceExerciseID.uuidString)"
        }
    }
}

@MainActor @Observable
final class ProgressionStore {
    private(set) var enrollments: [ProgressionEnrollment] = []
    private(set) var coaching: [ProgressionCoachingRecord] = []
    private(set) var acceptedTargets: [FutureProgressionTarget] = []
    var errorMessage: String?
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let commit: (ModelContext) throws -> Void

    init(context: ModelContext, commit: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws {
        self.context = context; self.commit = commit
        try reload()
    }

    func reload() throws {
        var enrollmentValues: [ProgressionEnrollment] = [], coachingValues: [ProgressionCoachingRecord] = []
        var targets: [FutureProgressionTarget] = []
        for row in try context.fetch(FetchDescriptor<ProgressionRecord>()) {
            let value = try JSONDecoder().decode(SavedProgression.self, from: row.payload)
            guard value.id == row.id else { throw invalid("Progression record identity is inconsistent.") }
            try Self.validate(value)
            switch value {
            case .enrollment(let entry): enrollmentValues.append(entry)
            case .coaching(let entry): coachingValues.append(entry)
            case .accepted(let entry): targets.append(entry)
            }
        }
        enrollments = enrollmentValues.sorted { $0.id < $1.id }
        coaching = coachingValues.sorted { $0.id < $1.id }
        acceptedTargets = targets.sorted { $0.acceptedAt < $1.acceptedAt }
    }

    func configuration(planRevisionID: String, sessionID: String, exerciseInstanceID: String) -> ProgressionConfiguration? {
        enrollments.first { $0.id == ProgressionEnrollment.key(planRevisionID: planRevisionID, sessionID: sessionID, instanceID: exerciseInstanceID) }?.configuration
    }
    func answers(workoutID: UUID, exerciseID: UUID) -> ProgressionAnswers {
        coaching.first { $0.workoutID == workoutID && $0.exerciseID == exerciseID }?.answers ?? .init()
    }
    func acceptedTarget(workoutID: UUID, exerciseID: UUID) -> FutureProgressionTarget? {
        acceptedTargets.first { $0.sourceSessionID == workoutID && $0.sourceExerciseID == exerciseID }
    }

    @discardableResult
    func saveEnrollment(planID: String, planRevisionID: String, session: PlanSession,
                        exercise: PlanExercise, configuration: ProgressionConfiguration, at date: Date = Date()) -> Bool {
        guard session.exercises.contains(exercise) else { errorMessage = "This exercise is no longer in the selected session."; return false }
        return save(.enrollment(.init(planID: planID, planRevisionID: planRevisionID, sessionID: session.id,
                                      exercise: exercise, configuration: configuration, updatedAt: date)))
    }

    @discardableResult
    func saveAnswers(workout: WorkoutSession, exercise: WorkoutExercise, answers: ProgressionAnswers, at date: Date = Date()) -> Bool {
        guard workout.state == .finished, workout.exercises.contains(where: { $0.id == exercise.id }),
              WorkoutSessionValidator.validate(workout).isEmpty else { errorMessage = "Review a saved, finished workout first."; return false }
        return save(.coaching(.init(workoutID: workout.id, exerciseID: exercise.id, answers: answers, updatedAt: date)))
    }

    /// Includes unsuccessful/unknown exposures so a newer failed attempt cannot be skipped.
    func exposures(workouts: [WorkoutSession], recovery: [SessionRecoveryRecord],
                   currentPlanRevisionID: String, currentSessionID: String,
                   currentExercise: PlanExercise) -> [ProgressionExposure] {
        let fallback = configuration(planRevisionID: currentPlanRevisionID, sessionID: currentSessionID,
                                     exerciseInstanceID: currentExercise.instanceId) ?? .init()
        return workouts.filter { $0.state == .finished }.flatMap { workout in
            workout.exercises.filter { $0.prescription.exerciseId == currentExercise.exerciseId }.compactMap { exercise in
                let original = configuration(planRevisionID: workout.planRevisionID, sessionID: workout.prescription.id,
                                             exerciseInstanceID: exercise.prescription.instanceId)
                let selected = original ?? fallback
                return try? ProgressionExposure(session: workout, exerciseID: exercise.id, configuration: selected,
                                                answers: answers(workoutID: workout.id, exerciseID: exercise.id), recovery: recovery)
            }
        }
    }

    /// Preserved completed web groupings can provide date-only evidence without invented session timings.
    func legacyEvidence(planID: String, exerciseID: String) throws -> [LegacyProgressionEvidence] {
        guard planID == "form-flow" else { return [] }
        return try context.fetch(FetchDescriptor<BackupArchiveRecord>()).compactMap { row in
            let record = try JSONDecoder().decode(BackupRecord.self, from: row.recordData)
            guard record.key == row.key else { throw invalid("An imported history identity is inconsistent. Review the archive before accepting progression.") }
            guard let evidence = LegacyProgressionEvidence(record: record, exerciseID: exerciseID), evidence.planID == planID else { return nil }
            return evidence
        }.sorted { $0.date == $1.date ? $0.recordKey < $1.recordKey : $0.date < $1.date }
    }

    /// Called inside AppStore's plan-revision transaction. No save and no observable success yet.
    func stageAcceptedTarget(_ target: FutureProgressionTarget, in transaction: ModelContext) throws {
        let value = SavedProgression.accepted(target)
        guard try transaction.fetch(FetchDescriptor<ProgressionRecord>()).contains(where: { $0.id == value.id }) == false else {
            throw invalid("A future target has already been accepted for this exercise result.")
        }
        try Self.stage(value, context: transaction)
    }

    /// Rebuild advice from authoritative current inputs inside the plan transaction.
    func validateAndStageAcceptance(_ target: FutureProgressionTarget, currentPlan: WeeklyPlan, revision: String,
                                    workouts: [WorkoutSession], recovery: [SessionRecoveryRecord],
                                    in transaction: ModelContext) throws {
        guard target.planRevisionID == revision, target.planID == currentPlan.id,
              let workout = workouts.first(where: { $0.id == target.sourceSessionID }),
              let sourceExercise = workout.exercises.first(where: { $0.id == target.sourceExerciseID }),
              let session = currentPlan.days.flatMap(\.sessions).first(where: { $0.id == workout.prescription.id }),
              let exercise = session.exercises.first(where: { $0.instanceId == sourceExercise.prescription.instanceId }),
              let config = configuration(planRevisionID: revision, sessionID: session.id, exerciseInstanceID: exercise.instanceId) else {
            throw ProgressionError.stalePlan
        }
        let history = exposures(workouts: workouts, recovery: recovery, currentPlanRevisionID: revision,
                                currentSessionID: session.id, currentExercise: exercise)
        guard let source = history.first(where: { $0.id == target.sourceExerciseID }) else { throw ProgressionError.staleHistory }
        let now = Date()
        let legacy = try legacyEvidence(planID: currentPlan.id, exerciseID: exercise.exerciseId)
        let advice = ProgressionEngine.advice(for: source, history: history, currentPlanRevisionID: revision, asOf: now, legacyHistory: legacy)
        let needsLoad = ![BuiltInProgressionPolicy.easyRun, .longRun].contains(config.implementedPolicy) &&
            ([ProgressionAction.increase, .reduce].contains(advice.action) || advice.nextStep == 3)
        let load = needsLoad ? target.load ?? target.assistance : nil
        let checked = try ProgressionEngine.accept(advice, currentPlanID: currentPlan.id, currentPlanRevisionID: revision,
                                                  currentExercise: exercise, configuration: config, history: history,
                                                  enteredLoad: load, availableEquipmentLoads: load.map { [$0] } ?? [], legacyHistory: legacy, at: now)
        var expected = try BackupJSONValue.encode(checked).object!, incoming = try BackupJSONValue.encode(target).object!
        expected.removeValue(forKey: "acceptedAt"); incoming.removeValue(forKey: "acceptedAt")
        guard expected == incoming else { throw ProgressionError.staleHistory }
        try stageAcceptedTarget(target, in: transaction)
    }

    /// Preserve consent through an unrelated plan edit, and update only the accepted occurrence's roadmap position.
    func stageEnrollmentCarryForward(from oldRevision: String, to newRevision: String, plan: WeeklyPlan,
                                     target: FutureProgressionTarget? = nil, sourceSessionID: String? = nil,
                                     sourceExerciseInstanceID: String? = nil, in transaction: ModelContext) throws {
        for enrollment in enrollments where enrollment.planRevisionID == oldRevision && enrollment.planID == plan.id {
            guard let session = plan.days.flatMap(\.sessions).first(where: { $0.id == enrollment.sessionID }),
                  let exercise = session.exercises.first(where: { $0.instanceId == enrollment.exercise.instanceId }) else { continue }
            var config = enrollment.configuration
            if enrollment.sessionID == sourceSessionID && enrollment.exercise.instanceId == sourceExerciseInstanceID, let target {
                config.pullUpStep = target.pullUpStep; config.longRunStage = target.longRunStage
            }
            guard !config.optedIn || ProgressionEngine.supports(configuration: config, exercise: exercise) else { continue }
            try Self.stage(.enrollment(.init(planID: plan.id, planRevisionID: newRevision, sessionID: session.id,
                                            exercise: exercise, configuration: config, updatedAt: Date())), context: transaction)
        }
    }

    private func save(_ value: SavedProgression) -> Bool {
        do {
            try Self.stage(value, context: context)
            try commit(context)
        } catch {
            context.rollback()
            errorMessage = "Changes were not saved. \(error.localizedDescription)"
            return false
        }
        do {
            try reload()
            errorMessage = nil
        } catch {
            errorMessage = "Your changes were saved. Progression information could not be refreshed; reopen the app before accepting another target. \(error.localizedDescription)"
        }
        return true
    }
    private static func stage(_ value: SavedProgression, context: ModelContext) throws {
        try validate(value)
        let data = try JSONEncoder().encode(value)
        if let row = try context.fetch(FetchDescriptor<ProgressionRecord>()).first(where: { $0.id == value.id }) { row.payload = data }
        else { context.insert(ProgressionRecord(id: value.id, payload: data)) }
    }

    static func backupRecords(context: ModelContext) throws -> [BackupRecord] {
        try context.fetch(FetchDescriptor<ProgressionRecord>()).map { row in
            let value = try JSONDecoder().decode(SavedProgression.self, from: row.payload)
            guard value.id == row.id else { throw invalid("Progression record identity is inconsistent.") }
            try validate(value)
            return try backupRecord(value)
        }
    }
    static func validateBackupRecord(_ record: BackupRecord) throws -> Bool {
        guard record.payload["nativeType"]?.string?.hasPrefix("progression-") == true else { return false }
        let value = try decodeBackup(record)
        try validate(value)
        guard try backupRecord(value) == record else { throw invalid("A progression backup record has unsupported fields or inconsistent dependencies.") }
        return true
    }
    static func applyBackupRecord(_ record: BackupRecord, context: ModelContext) throws {
        guard try validateBackupRecord(record) else { throw invalid("This is not a progression record.") }
        try stage(decodeBackup(record), context: context)
    }
    static func validateBackupRelationships(_ records: [BackupRecord]) throws {
        let workouts = try records.filter { $0.payload["nativeType"]?.string == "workout" }.map { try ($0.payload["value"] ?? .null).decode(WorkoutSession.self) }
        for record in records where record.payload["nativeType"]?.string?.hasPrefix("progression-") == true {
            switch try decodeBackup(record) {
            case .enrollment(let enrollment):
                guard let planRecord = records.first(where: { $0.category == .plans && $0.id == enrollment.planRevisionID && $0.payload["nativeType"]?.string == "plan" }),
                      let planValue = planRecord.payload["value"]?["plan"] else { throw invalid("Progression enrollment requires its native plan revision.") }
                let plan = try planValue.decode(WeeklyPlan.self)
                guard plan.id == enrollment.planID,
                      plan.days.flatMap(\.sessions).first(where: { $0.id == enrollment.sessionID })?.exercises.contains(enrollment.exercise) == true else {
                    throw invalid("Progression enrollment does not match its frozen plan occurrence.")
                }
            case .coaching(let coaching):
                guard let workout = workouts.first(where: { $0.id == coaching.workoutID }), workout.state == .finished, let ended = workout.endedAt,
                      workout.exercises.contains(where: { $0.id == coaching.exerciseID }),
                      coaching.updatedAt >= ended else {
                    throw invalid("Coaching answers require their finished workout and exercise.")
                }
            case .accepted(let target):
                guard let workout = workouts.first(where: { $0.id == target.sourceSessionID }), workout.state == .finished, let ended = workout.endedAt,
                      workout.planID == target.planID,
                      workout.exercises.contains(where: { $0.id == target.sourceExerciseID && $0.prescription.exerciseId == target.exerciseID }),
                      target.acceptedAt >= ended,
                      let planRecord = records.first(where: { $0.category == .plans && $0.id == target.planRevisionID && $0.payload["nativeType"]?.string == "plan" }),
                      let planValue = planRecord.payload["value"]?["plan"],
                      try planValue.decode(WeeklyPlan.self).id == target.planID else {
                    throw invalid("An accepted target must retain its source workout and reviewed plan revision.")
                }
                for reference in target.legacyEvidenceReferences ?? [] {
                    guard records.contains(where: {
                        $0.category == .workouts && $0.id == reference.recordID &&
                        $0.payload["log"]?["date"]?.string == reference.date &&
                        ($0.payload["log"]?["planId"]?.string ?? "form-flow") == target.planID &&
                        $0.payload["log"]?["exercises"]?[reference.exerciseID] != nil
                    }) else { throw invalid("An accepted target must retain its referenced legacy workout grouping.") }
                }
            }
        }
    }
    private static func backupRecord(_ value: SavedProgression) throws -> BackupRecord {
        let type: String, category: BackupCategory, payload: BackupJSONValue, references: [BackupReference]
        switch value {
        case .enrollment(let entry):
            type = "progression-enrollment"; category = .settings; payload = try .encode(entry)
            references = [.init(category: .plans, id: entry.planRevisionID)]
        case .coaching(let entry):
            type = "progression-coaching"; category = .recovery; payload = try .encode(entry)
            references = [.init(category: .workouts, id: entry.workoutID.uuidString)]
        case .accepted(let entry):
            type = "progression-accepted"; category = .settings; payload = try .encode(entry)
            references = [.init(category: .plans, id: entry.planRevisionID), .init(category: .workouts, id: entry.sourceSessionID.uuidString)] +
                (entry.legacyEvidenceReferences ?? []).map { .init(category: .workouts, id: $0.recordID) }
        }
        return .init(id: value.id, category: category,
                     payload: .object(["nativeType": .string(type), "version": .number(1), "value": payload]), references: references)
    }
    private static func decodeBackup(_ record: BackupRecord) throws -> SavedProgression {
        guard record.payload["version"] == .number(1), let value = record.payload["value"] else { throw invalid("Unsupported progression backup version.") }
        switch record.payload["nativeType"]?.string {
        case "progression-enrollment": return .enrollment(try value.decode(ProgressionEnrollment.self))
        case "progression-coaching": return .coaching(try value.decode(ProgressionCoachingRecord.self))
        case "progression-accepted": return .accepted(try value.decode(FutureProgressionTarget.self))
        default: throw invalid("Unsupported progression backup type.")
        }
    }
    private static func validate(_ value: SavedProgression) throws {
        switch value {
        case .enrollment(let entry):
            guard canonicalUUID(entry.planRevisionID), identifier(entry.planID), identifier(entry.sessionID),
                  entry.updatedAt.timeIntervalSinceReferenceDate.isFinite, entry.configuration.variantID.count <= 200,
                  entry.configuration.pullUpStep.map({ (1...6).contains($0) }) ?? true,
                  entry.configuration.longRunStage.map({ (1...18).contains($0) }) ?? true,
                  entry.configuration.policy.map({ identifier($0.id) && (1...10_000).contains($0.version) && ($0.notes?.count ?? 0) <= 500 }) ?? true,
                  !entry.configuration.optedIn || ProgressionEngine.supports(configuration: entry.configuration, exercise: entry.exercise) else {
                throw invalid("Progression enrollment has invalid identity or unsupported targets.")
            }
            let plan = WeeklyPlan(id: entry.planID, name: "Enrollment", days: [.init(weekday: .monday, sessions: [
                .init(id: entry.sessionID, name: "Enrollment", kind: "mixed", estimatedMinutes: 1, exercises: [entry.exercise])
            ])])
            guard !PlanValidator.validate(plan, legacy: true).contains(where: { $0.severity == .error }) else {
                throw invalid("An enrollment contains an invalid frozen prescription.")
            }
        case .coaching(let entry):
            guard entry.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                  entry.answers.reserve.map({ (0...10).contains($0) }) ?? true,
                  entry.answers.duringRating.map({ (0...4).contains($0) }) ?? true else {
                throw invalid("Coaching answers are outside the supported ranges.")
            }
        case .accepted(let entry):
            guard canonicalUUID(entry.planRevisionID), identifier(entry.planID), identifier(entry.exerciseID),
                  entry.variantID.count <= 200, entry.policy.version == 1,
                  BuiltInProgressionPolicy(rawValue: entry.policy.id) != nil,
                  ![ProgressionAction.manual, .pending].contains(entry.action),
                  entry.acceptedAt.timeIntervalSinceReferenceDate.isFinite,
                  entry.pullUpStep.map({ (1...6).contains($0) }) ?? true,
                  entry.longRunStage.map({ (1...18).contains($0) }) ?? true,
                  entry.restartReps.map({ (1...1_000).contains($0) }) ?? true else { throw invalid("An accepted target is invalid.") }
            guard (entry.legacyEvidenceReferences?.count ?? 0) <= 1 else { throw invalid("An accepted target has unsupported legacy evidence.") }
            for reference in entry.legacyEvidenceReferences ?? [] {
                guard entry.planID == "form-flow", reference.exerciseID == entry.exerciseID,
                      !reference.recordID.isEmpty, reference.recordID.count <= 300,
                      LocalTrainingDay.isValidDate(reference.date),
                      reference.fingerprint.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                    throw invalid("An accepted target has invalid legacy provenance.")
                }
            }
            for quantity in [entry.load, entry.assistance].compactMap({ $0 }) {
                guard [.kg, .lb].contains(quantity.unit), quantity.value.isFinite, (0...10_000).contains(quantity.value) else {
                    throw invalid("An accepted load has invalid units or values.")
                }
            }
            if let distance = entry.longRunDistance {
                guard distance.unit == .km, distance.value.isFinite, distance.value > 0,
                      let stage = entry.longRunStage, distance.value == BuiltInProgression.longRunStages[stage - 1].distanceKM else {
                    throw invalid("An accepted running target does not match its stage.")
                }
            }
            let policy = BuiltInProgressionPolicy(rawValue: entry.policy.id)!
            switch policy {
            case .strength:
                guard entry.pullUpStep == nil, entry.longRunStage == nil, entry.longRunDistance == nil, entry.assistance == nil,
                      entry.measurement == .weightReps, [.increase, .reduce, .repeatTarget].contains(entry.action),
                      entry.action == .repeatTarget || entry.load != nil,
                      (entry.action == .increase) == (entry.restartReps != nil) else { throw invalid("The accepted strength target is inconsistent.") }
            case .pullUp:
                guard entry.pullUpStep != nil, entry.longRunStage == nil, entry.longRunDistance == nil, entry.load == nil,
                      entry.restartReps == nil, [.assistedReps, .reps].contains(entry.measurement),
                      [.step, .reduce, .repeatTarget].contains(entry.action),
                      entry.action != .reduce || entry.assistance != nil else { throw invalid("The accepted pull-up target is inconsistent.") }
            case .easyRun, .longRun:
                guard entry.pullUpStep == nil, entry.load == nil, entry.assistance == nil, entry.restartReps == nil,
                      [.distanceTime, .distance, .duration].contains(entry.measurement), [.stage, .reduce, .repeatTarget].contains(entry.action),
                      (policy == .longRun) == (entry.longRunStage != nil), (policy == .longRun) == (entry.longRunDistance != nil),
                      policy == .longRun || entry.action != .stage else { throw invalid("The accepted running target is inconsistent.") }
            }
        }
    }
    private static func identifier(_ text: String) -> Bool {
        text.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil
    }
    private static func canonicalUUID(_ text: String) -> Bool { UUID(uuidString: text)?.uuidString == text }
    private static func invalid(_ text: String) -> BackupError { .invalid(text) }
    private func invalid(_ text: String) -> BackupError { Self.invalid(text) }
}
