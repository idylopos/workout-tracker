import Foundation
import SwiftData
import FormFlowCore

/// Lossless records that the live app cannot yet safely adopt, including unfinished restored workouts.
@Model
final class BackupArchiveRecord {
    @Attribute(.unique) var key: String
    var recordData: Data
    var sourceFingerprint: String
    var needsReview: Bool
    var importedAt: Date
    init(key: String, recordData: Data, sourceFingerprint: String, needsReview: Bool) {
        self.key = key; self.recordData = recordData; self.sourceFingerprint = sourceFingerprint
        self.needsReview = needsReview; importedAt = Date()
    }
}

/// Original files can contain additional private fields. Ordinary exports never include these bytes.
@Model
final class BackupProvenanceRecord {
    @Attribute(.unique) var sourceFingerprint: String
    var originalInput: Data
    var importedAt: Date
    var isLegacy: Bool
    init(sourceFingerprint: String, originalInput: Data, isLegacy: Bool) {
        self.sourceFingerprint = sourceFingerprint; self.originalInput = originalInput
        self.isLegacy = isLegacy; importedAt = Date()
    }
}

@MainActor
final class WorkspaceBackupStore {
    private let context: ModelContext
    private let commit: (ModelContext) throws -> Void
    init(context: ModelContext, commit: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.context = context; self.commit = commit
    }

    func archivedRecords() throws -> [BackupRecord] {
        try context.fetch(FetchDescriptor<BackupArchiveRecord>()).map {
            let record = try JSONDecoder().decode(BackupRecord.self, from: $0.recordData)
            guard record.key == $0.key else { throw invalid("An archived backup record has an inconsistent identity.") }
            return record
        }.sorted { $0.key < $1.key }
    }

    func records() throws -> [BackupRecord] {
        var result = try archivedRecords()
        result += try ProgressionStore.backupRecords(context: context)
        result += try ScheduleExceptionStore.backupRecords(context: context)
        for row in try context.fetch(FetchDescriptor<ActivatedPlanRecord>()) {
            let plan = try JSONDecoder().decode(WeeklyPlan.self, from: row.planData)
            let legacy = PlanValidator.validate(plan).contains { $0.severity == .error }
            let value = BackupPlanValue(sequence: row.sequence, createdAt: row.createdAt,
                activationDate: row.activationDate, plan: plan, legacyConverted: legacy)
            result.append(try record(id: row.id, category: .plans, type: "plan", value: value))
            if !row.sourceText.isEmpty {
                result.append(try record(id: "plan-source:\(row.id)", category: .rawAIResponses, type: "plan-source",
                    value: BackupPlanSourceValue(planRevisionID: row.id, sourceText: row.sourceText),
                    references: [BackupReference(category: .plans, id: row.id, allowsMissing: true)]))
            }
        }
        for row in try context.fetch(FetchDescriptor<WorkoutRecord>()) {
            let workout = try JSONDecoder().decode(WorkoutSession.self, from: row.payload)
            guard workout.id == row.id else { throw invalid("A saved workout identity is inconsistent.") }
            result.append(try record(id: row.id.uuidString, category: .workouts, type: "workout", value: workout,
                references: [BackupReference(category: .plans, id: workout.planRevisionID, allowsMissing: true)]))
        }
        for row in try context.fetch(FetchDescriptor<TrackingRecord>()) {
            guard let category = BackupCategory(rawValue: row.category), [.sleep, .body, .recovery].contains(category) else {
                throw invalid("An unsupported tracking category was found.")
            }
            let value = try JSONDecoder().decode(BackupJSONValue.self, from: row.payload)
            let references: [BackupReference]
            if category == .recovery {
                let recovery = try value.decode(SessionRecoveryRecord.self)
                references = [BackupReference(category: .workouts, id: recovery.sessionID.uuidString)]
            } else { references = [] }
            result.append(try record(id: row.id.uuidString, category: category, type: category.rawValue, value: value, references: references))
        }
        if let workspace = try workspace() {
            let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: workspace.payload)
            guard snapshot.storageVersion == 1 else { throw invalid("This workspace version is unsupported.") }
            result.append(try record(id: "workspace", category: .settings, type: "settings",
                value: BackupSettingsValue(activeRevisionID: snapshot.activeRevisionID, onboardingStep: snapshot.onboardingStep, units: snapshot.profile.units),
                references: snapshot.activeRevisionID.map { [BackupReference(category: .plans, id: $0)] } ?? []))
            result.append(try record(id: "profile", category: .profile, type: "profile", value: snapshot.profile))
            result.append(try record(id: "prompts", category: .promptHistory, type: "prompts",
                value: BackupPromptsValue(draft: snapshot.promptDraft, history: snapshot.previousPrompts)))
            result.append(try record(id: "response-draft", category: .rawAIResponses, type: "response-draft",
                value: BackupResponseValue(text: snapshot.importText, reviewedSource: snapshot.reviewedSource)))
        }
        for row in try context.fetch(FetchDescriptor<PlanDraftHistoryRecord>()) {
            result.append(try record(id: row.id.uuidString, category: .rawAIResponses, type: "response-history",
                value: BackupResponseHistoryValue(id: row.id, createdAt: row.createdAt, text: row.sourceText)))
        }
        try validate(result)
        return result.sorted { $0.key < $1.key }
    }

    func stage(_ data: Data) throws -> StagedBackup {
        let result = try BackupImporter.stage(data, existing: records())
        try validate(result.records)
        return result
    }

    func export(categories: Set<BackupCategory> = BackupCategory.defaultSelection) throws -> Data {
        try NativeBackupExporter.export(records: records(), categories: categories)
    }

    func restore(stage: StagedBackup, conflictChoices: [String: BackupConflictChoice] = [:]) throws {
        guard !context.hasChanges else { throw invalid("Save or discard pending changes before restoring a backup.") }
        let existing = try records()
        // Reparse the original and recompute conflicts against the current store, never a stale preview.
        let assumedZone = stage.records.compactMap { $0.payload["legacyTimeZoneAssumption"]?.string }.first ?? TimeZone.current.identifier
        let fresh = try BackupImporter.stage(stage.originalInput, existing: existing, legacyTimeZoneID: assumedZone)
        guard fresh.sourceFingerprint == stage.sourceFingerprint, fresh.records == stage.records else {
            throw invalid("The staged backup changed. Preview the original file again.")
        }
        try validate(fresh.records)
        let changes = try BackupRestorePlanner.changes(stage: fresh, existing: existing, conflictChoices: conflictChoices)
        let changed = changes.insertions + changes.replacements
        for incoming in changes.replacements where incoming.payload["nativeType"] == nil {
            if existing.contains(where: { $0.key == incoming.key && $0.payload["nativeType"] != nil }) {
                throw invalid("An opaque legacy record cannot replace a native record. Keep the existing record and retain the original import file.")
            }
        }
        let changedKeys = Set(changed.map(\.key))
        let finalRecords = existing.filter { !changedKeys.contains($0.key) } + changed
        try validate(finalRecords)
        try validateRelationships(finalRecords)
        for row in try context.fetch(FetchDescriptor<WorkoutRecord>()) where changedKeys.contains("workouts:\(row.id.uuidString)") {
            let current = try JSONDecoder().decode(WorkoutSession.self, from: row.payload)
            guard current.state.isTerminal else {
                throw invalid("Finish or abandon the live workout before replacing it from a backup.")
            }
        }
        if !changes.replacements.isEmpty {
            try WorkspaceStoreRecovery.captureBeforeRestore(context: context)
        }
        do {
            // Plans precede optional source text; settings/profile changes share a single workspace update.
            for incoming in changed.sorted(by: { priority($0) < priority($1) }) {
                try apply(incoming, sourceFingerprint: fresh.sourceFingerprint)
            }
            if try context.fetch(FetchDescriptor<BackupProvenanceRecord>()).contains(where: { $0.sourceFingerprint == fresh.sourceFingerprint }) == false {
                context.insert(BackupProvenanceRecord(sourceFingerprint: fresh.sourceFingerprint,
                    originalInput: fresh.originalInput, isLegacy: fresh.isLegacy))
            }
            try commit(context)
        } catch {
            context.rollback()
            throw error
        }
    }

    private func apply(_ incoming: BackupRecord, sourceFingerprint: String) throws {
        let kind = incoming.payload["nativeType"]?.string
        let value = incoming.payload["value"] ?? .null
        if kind == "workout" {
            let workout = try value.decode(WorkoutSession.self)
            if !workout.state.isTerminal {
                if let old = try context.fetch(FetchDescriptor<WorkoutRecord>()).first(where: { $0.id == workout.id }) { context.delete(old) }
                try archive(incoming, sourceFingerprint: sourceFingerprint, needsReview: true)
                return
            }
        }
        guard let kind else { try archive(incoming, sourceFingerprint: sourceFingerprint, needsReview: true); return }
        // A generic record with this key may have come from an earlier restore.
        if let old = try context.fetch(FetchDescriptor<BackupArchiveRecord>()).first(where: { $0.key == incoming.key }) { context.delete(old) }
        if try ScheduleExceptionStore.validateBackupRecord(incoming) {
            try ScheduleExceptionStore.applyBackupRecord(incoming, context: context)
            return
        }
        if try ProgressionStore.validateBackupRecord(incoming) {
            try ProgressionStore.applyBackupRecord(incoming, context: context)
            return
        }
        switch kind {
        case "plan":
            let plan = try value.decode(BackupPlanValue.self)
            if let row = try context.fetch(FetchDescriptor<ActivatedPlanRecord>()).first(where: { $0.id == incoming.id }) {
                row.sequence = plan.sequence; row.createdAt = plan.createdAt; row.activationDate = plan.activationDate
                row.planData = try JSONEncoder().encode(plan.plan)
            } else {
                let row = ActivatedPlanRecord(sequence: plan.sequence, activationDate: plan.activationDate,
                    planData: try JSONEncoder().encode(plan.plan), sourceText: "")
                row.id = incoming.id; row.createdAt = plan.createdAt; context.insert(row)
            }
        case "workout":
            let workout = try value.decode(WorkoutSession.self)
            let data = try JSONEncoder().encode(workout)
            if let row = try context.fetch(FetchDescriptor<WorkoutRecord>()).first(where: { $0.id == workout.id }) {
                row.payload = data; row.updatedAt = Date()
            } else { context.insert(WorkoutRecord(id: workout.id, payload: data)) }
        case "sleep", "body", "recovery":
            guard let id = UUID(uuidString: incoming.id) else { throw invalid("A tracking identity is invalid.") }
            let data = try value.canonicalData()
            if let row = try context.fetch(FetchDescriptor<TrackingRecord>()).first(where: { $0.id == id }) {
                row.category = incoming.category.rawValue; row.payload = data
            } else { context.insert(TrackingRecord(id: id, category: incoming.category.rawValue, payload: data)) }
        case "settings":
            let settings = try value.decode(BackupSettingsValue.self)
            try updateWorkspace {
                $0.activeRevisionID = settings.activeRevisionID; $0.onboardingStep = settings.onboardingStep
                $0.profile.units = settings.units
            }
        case "profile":
            let profile = try value.decode(TrainingProfile.self)
            try updateWorkspace { $0.profile = profile }
        case "prompts":
            let prompts = try value.decode(BackupPromptsValue.self)
            try updateWorkspace { $0.promptDraft = prompts.draft; $0.previousPrompts = prompts.history; $0.promptProfile = nil }
        case "response-draft":
            let response = try value.decode(BackupResponseValue.self)
            try updateWorkspace { $0.importText = response.text; $0.reviewedSource = response.reviewedSource }
        case "response-history":
            let response = try value.decode(BackupResponseHistoryValue.self)
            if let row = try context.fetch(FetchDescriptor<PlanDraftHistoryRecord>()).first(where: { $0.id == response.id }) {
                row.sourceText = response.text; row.createdAt = response.createdAt
            } else {
                let row = PlanDraftHistoryRecord(sourceText: response.text)
                row.id = response.id; row.createdAt = response.createdAt; context.insert(row)
            }
        case "plan-source":
            let source = try value.decode(BackupPlanSourceValue.self)
            if let row = try context.fetch(FetchDescriptor<ActivatedPlanRecord>()).first(where: { $0.id == source.planRevisionID }) {
                row.sourceText = source.sourceText
            } else { try archive(incoming, sourceFingerprint: sourceFingerprint, needsReview: true) }
        default: throw invalid("This backup payload version is unsupported.")
        }
    }

    private func validate(_ records: [BackupRecord]) throws {
        guard Set(records.map(\.key)).count == records.count else { throw invalid("Backup record identities collide.") }
        var trackingIDs = Set<String>()
        for record in records {
            if try ProgressionStore.validateBackupRecord(record) { continue }
            if try ScheduleExceptionStore.validateBackupRecord(record) { continue }
            if try WorkoutAnnotationStore.validateBackupRecord(record) { continue }
            guard let kind = record.payload["nativeType"]?.string else { continue } // Retained as opaque archived data only.
            guard record.payload.object.map({ Set($0.keys) == Set(["nativeType", "version", "value"]) }) == true,
                  record.payload["version"] == .number(1), let value = record.payload["value"] else {
                throw invalid("A native backup payload has unsupported fields or version.")
            }
            var expectedReferences: [BackupReference] = []
            let category: BackupCategory
            switch kind {
            case "plan":
                category = .plans
                let plan = try checked(BackupPlanValue.self, value)
                guard canonicalUUID(record.id), (1...1_000_000).contains(plan.sequence), finite(plan.createdAt), finite(plan.activationDate),
                      plan.legacyConverted == PlanValidator.validate(plan.plan).contains(where: { $0.severity == .error }),
                      !PlanValidator.validate(plan.plan, legacy: plan.legacyConverted).contains(where: { $0.severity == .error }) else {
                    throw invalid("An activated plan's identity, dates or prescription is invalid.")
                }
            case "workout":
                category = .workouts
                let workout = try checked(WorkoutSession.self, WorkoutBackupCompatibility.normalizedWorkoutValue(value))
                guard record.id == workout.id.uuidString, WorkoutArchiveValidator.validate(workout).isEmpty else {
                    throw invalid("A workout contains invalid identities, values or lifecycle data.")
                }
                expectedReferences = [BackupReference(category: .plans, id: workout.planRevisionID, allowsMissing: true)]
            case "sleep":
                category = .sleep; let sleep = try checked(ManualSleepRecord.self, value)
                try sleep.validate(); try validTracking(record, id: sleep.id, at: sleep.updatedAt, IDs: &trackingIDs)
            case "body":
                category = .body; let body = try checked(BodyMeasurementRecord.self, value)
                try body.validate(); try validTracking(record, id: body.id, at: body.updatedAt, IDs: &trackingIDs)
            case "recovery":
                category = .recovery; let recovery = try checked(SessionRecoveryRecord.self, value)
                try recovery.validate(); try validTracking(record, id: recovery.id, at: recovery.updatedAt, IDs: &trackingIDs)
                expectedReferences = [BackupReference(category: .workouts, id: recovery.sessionID.uuidString)]
            case "settings":
                category = .settings; let settings = try checked(BackupSettingsValue.self, value)
                guard record.id == "workspace", (0...7).contains(settings.onboardingStep),
                      settings.activeRevisionID.map(canonicalUUID) ?? true else { throw invalid("Workspace settings are invalid.") }
                expectedReferences = settings.activeRevisionID.map { [BackupReference(category: .plans, id: $0)] } ?? []
            case "profile":
                category = .profile; let profile = try checked(TrainingProfile.self, value)
                guard record.id == "profile", (10...180).contains(profile.sessionMinutes),
                      Set(profile.availableDays).count == profile.availableDays.count,
                      try value.canonicalData().count <= 256 * 1_024 else { throw invalid("Profile fields exceed their supported limits.") }
            case "prompts":
                category = .promptHistory; let prompts = try checked(BackupPromptsValue.self, value)
                guard record.id == "prompts", prompts.history.count <= 1_000,
                      prompts.draft.utf8.count <= 1_048_576,
                      prompts.history.allSatisfy({ finite($0.createdAt) && $0.text.utf8.count <= 1_048_576 }) else {
                    throw invalid("Prompt history is invalid or too large.")
                }
            case "response-draft":
                category = .rawAIResponses; let response = try checked(BackupResponseValue.self, value)
                guard record.id == "response-draft", response.text.utf8.count <= 1_048_576,
                      (response.reviewedSource?.utf8.count ?? 0) <= 1_048_576 else { throw invalid("The saved AI response is too large.") }
            case "response-history":
                category = .rawAIResponses; let response = try checked(BackupResponseHistoryValue.self, value)
                guard record.id == response.id.uuidString, finite(response.createdAt), response.text.utf8.count <= 1_048_576 else {
                    throw invalid("A saved AI response history entry is invalid.")
                }
            case "plan-source":
                category = .rawAIResponses; let source = try checked(BackupPlanSourceValue.self, value)
                guard canonicalUUID(source.planRevisionID), record.id == "plan-source:\(source.planRevisionID)",
                      source.sourceText.utf8.count <= 1_048_576 else { throw invalid("An optional plan source is invalid.") }
                expectedReferences = [BackupReference(category: .plans, id: source.planRevisionID, allowsMissing: true)]
            default: throw invalid("This native backup payload is unsupported. Preserve the original file.")
            }
            guard record.category == category, record.references.sorted(by: { $0.key < $1.key }) == expectedReferences.sorted(by: { $0.key < $1.key }) else {
                throw invalid("A backup record has inconsistent category or dependencies.")
            }
        }
    }

    private func validateRelationships(_ records: [BackupRecord]) throws {
        try ProgressionStore.validateBackupRelationships(records)
        try ScheduleExceptionStore.validateBackupRelationships(records)
        try WorkoutAnnotationStore.validateBackupRelationships(records: records)
        let native = records.filter { $0.payload["nativeType"] != nil }
        let workouts = try native.filter { $0.payload["nativeType"]?.string == "workout" }.map { try ($0.payload["value"] ?? .null).decode(WorkoutSession.self) }
        let plans = Set(native.filter { $0.payload["nativeType"]?.string == "plan" }.map(\.id))
        var recoveryKeys = Set<String>()
        for record in native {
            if record.payload["nativeType"]?.string == "settings" {
                let settings = try (record.payload["value"] ?? .null).decode(BackupSettingsValue.self)
                if let id = settings.activeRevisionID, !plans.contains(id) { throw invalid("The active revision must reference a validated native plan.") }
            }
            if record.payload["nativeType"]?.string == "recovery" {
                let recovery = try (record.payload["value"] ?? .null).decode(SessionRecoveryRecord.self)
                guard recoveryKeys.insert("\(recovery.sessionID):\(recovery.phase.rawValue)").inserted,
                      let workout = workouts.first(where: { $0.id == recovery.sessionID }), workout.state == .finished,
                      let ended = workout.endedAt, let zone = TimeZone(identifier: workout.timeZoneIdentifier) else {
                    throw invalid("Recovery must reference one finished native workout, with one answer per phase.")
                }
                let day = LocalTrainingDay(instant: ended, timeZone: zone)
                guard recovery.day.timeZoneID == workout.timeZoneIdentifier,
                      recovery.phase == .evening ? recovery.day.date == day.date : recovery.day.date > day.date else {
                    throw invalid("A recovery answer does not match its workout's local date and phase.")
                }
            }
        }
    }

    private func checked<T: Codable>(_ type: T.Type, _ value: BackupJSONValue) throws -> T {
        let decoded = try value.decode(type)
        guard try BackupJSONValue.encode(decoded) == value else { throw invalid("A native payload contains fields this version cannot preserve.") }
        return decoded
    }
    private func record<T: Encodable>(id: String, category: BackupCategory, type: String, value: T,
                                      references: [BackupReference] = []) throws -> BackupRecord {
        BackupRecord(id: id, category: category,
            payload: .object(["nativeType": .string(type), "version": .number(1), "value": try .encode(value)]), references: references)
    }
    private func archive(_ incoming: BackupRecord, sourceFingerprint: String, needsReview: Bool) throws {
        let data = try JSONEncoder().encode(incoming)
        if let row = try context.fetch(FetchDescriptor<BackupArchiveRecord>()).first(where: { $0.key == incoming.key }) {
            row.recordData = data; row.sourceFingerprint = sourceFingerprint; row.needsReview = needsReview
        } else { context.insert(BackupArchiveRecord(key: incoming.key, recordData: data, sourceFingerprint: sourceFingerprint, needsReview: needsReview)) }
    }
    private func workspace() throws -> WorkspaceRecord? {
        let rows = try context.fetch(FetchDescriptor<WorkspaceRecord>())
        guard rows.count <= 1 else { throw invalid("More than one workspace was found.") }
        return rows.first
    }
    private func updateWorkspace(_ change: (inout WorkspaceSnapshot) -> Void) throws {
        let row = try workspace()
        var snapshot = try row.map { try JSONDecoder().decode(WorkspaceSnapshot.self, from: $0.payload) } ?? WorkspaceSnapshot()
        change(&snapshot)
        let data = try JSONEncoder().encode(snapshot)
        if let row { row.payload = data } else { context.insert(WorkspaceRecord(payload: data)) }
    }
    private func validTracking(_ record: BackupRecord, id: UUID, at date: Date, IDs: inout Set<String>) throws {
        guard record.id == id.uuidString, finite(date), IDs.insert(record.id).inserted else { throw invalid("Tracking identities or timestamps are invalid.") }
    }
    private func canonicalUUID(_ text: String) -> Bool { UUID(uuidString: text)?.uuidString == text }
    private func finite(_ date: Date) -> Bool { date.timeIntervalSinceReferenceDate.isFinite }
    private func invalid(_ text: String) -> BackupError { .invalid(text) }
    private func priority(_ record: BackupRecord) -> Int { record.category == .plans ? 0 : record.category == .rawAIResponses ? 2 : 1 }
}

private struct BackupPlanValue: Codable {
    let sequence: Int
    let createdAt: Date
    let activationDate: Date
    let plan: WeeklyPlan
    let legacyConverted: Bool
}
private struct BackupSettingsValue: Codable { let activeRevisionID: String?; let onboardingStep: Int; let units: UnitPreference }
private struct BackupPromptsValue: Codable { let draft: String; let history: [PromptSnapshot] }
private struct BackupResponseValue: Codable { let text: String; let reviewedSource: String? }
private struct BackupResponseHistoryValue: Codable { let id: UUID; let createdAt: Date; let text: String }
private struct BackupPlanSourceValue: Codable { let planRevisionID: String; let sourceText: String }
