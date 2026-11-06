import Foundation
import SwiftData
import FormFlowCore

enum WorkspaceDeletionCategory: String, CaseIterable, Identifiable, Hashable {
    case profile, aiDrafts, plans, workoutHistory, sleepAndBody, activities
    var id: String { rawValue }
    var title: String {
        switch self {
        case .profile: "Training profile"
        case .aiDrafts: "Prompts and AI responses"
        case .plans: "Saved plans and plan drafts"
        case .workoutHistory: "Workout history and recovery"
        case .sleepAndBody: "Sleep and body measurements"
        case .activities: "Reusable activity templates"
        }
    }
    var detail: String {
        switch self {
        case .profile: "Also removes copied profile snapshots, prompts and AI responses. Reviewed training instructions in kept plans and workouts remain."
        case .aiDrafts: "Removes prompt history, response drafts and original plan-response text. Keeps your questionnaire and reviewed plans."
        case .plans: "Removes active and saved plans, plan drafts, schedule changes and plan coaching settings. Kept workouts retain their frozen prescriptions."
        case .workoutHistory: "Removes recorded workouts, workout drafts, recovery, coaching answers and history-review decisions. Keeps your saved plans."
        case .sleepAndBody: "Removes recorded sleep, weight and waist entries. Your questionnaire answers remain unless you select Training profile."
        case .activities: "Removes reusable templates. Activities already recorded inside kept workouts remain."
        }
    }
}

struct WorkspaceDeletionCount: Identifiable, Equatable {
    let id: String
    let title: String
    let count: Int
}

struct WorkspaceDeletionPreview: Identifiable {
    let id = UUID()
    let selection: Set<WorkspaceDeletionCategory>
    let rows: [WorkspaceDeletionCount]
    let warnings: [String]
    let rotatesGeneration: Bool
    fileprivate let fingerprint: String
    fileprivate let removedKeys: Set<String>
}

struct WorkspaceDeletionResult {
    let syncGeneration: String
    let rotatedGeneration: Bool
}

/// Deletion choices are independent of export choices. Mutations commit together; opaque
/// original files and recovery copies are removed because they can retain selected values.
@MainActor
final class WorkspaceDeletionStore {
    private let context: ModelContext
    private let commit: (ModelContext) throws -> Void
    private let purgeRecoveryCopies: (ModelContext) throws -> Void

    init(context: ModelContext, commit: @escaping (ModelContext) throws -> Void = { try $0.save() },
         purgeRecoveryCopies: @escaping (ModelContext) throws -> Void = { try WorkspaceStoreRecovery.purgeSnapshots(context: $0) }) {
        self.context = context; self.commit = commit; self.purgeRecoveryCopies = purgeRecoveryCopies
    }

    func preview(selection: Set<WorkspaceDeletionCategory>) throws -> WorkspaceDeletionPreview {
        let inventory = try inspect()
        guard !selection.isEmpty else { throw invalid("Choose what to delete before reviewing.") }
        let clearAI = selection.contains(.profile) || selection.contains(.aiDrafts) || selection.contains(.plans)
        let rotate = selection.contains(.plans) || selection.contains(.workoutHistory)
        var keys = Set(inventory.records.filter { record in
            // A backup pasted into the plan importer is a raw response draft before routing.
            // Any selected category may therefore also exist in these uninterpreted sources.
            if record.category == .rawAIResponses { return true }
            if selection.contains(.profile), record.category == .profile { return true }
            if clearAI, record.category == .promptHistory { return true }
            if selection.contains(.plans), record.category == .plans { return true }
            if selection.contains(.workoutHistory), [.workouts, .drafts, .recovery, .legacyCheckIns].contains(record.category) { return true }
            if selection.contains(.sleepAndBody), [.sleep, .body, .legacyCheckIns].contains(record.category) { return true }
            if selection.contains(.activities), record.category == .activities { return true }
            // Old operation drafts may carry deleted plan prescriptions or become unapplicable
            // after generation retirement. Do not leave retryable copies behind.
            if rotate, record.category == .drafts { return true }
            if selection.contains(.plans), record.payload["nativeType"] == .string("schedule-exception") { return true }
            if rotate, record.category == .settings, record.payload["nativeType"] == nil { return true }
            return false
        }.map(\.key))
        // Required references are cascading dependencies; optional frozen prescription
        // references let an unrelated historical workout outlive its original plan.
        var changed = true
        while changed {
            changed = false
            for record in inventory.records where !keys.contains(record.key) && record.key != "settings:workspace" {
                if record.references.contains(where: { !$0.allowsMissing && keys.contains($0.key) }) {
                    keys.insert(record.key); changed = true
                }
            }
        }
        var rows: [WorkspaceDeletionCount] = []
        for category in BackupCategory.allCases {
            let count = inventory.records.filter { $0.category == category && keys.contains($0.key) }.count
            if count > 0 { rows.append(.init(id: category.rawValue, title: title(category), count: count)) }
        }
        if !inventory.provenance.isEmpty {
            rows.append(.init(id: "original-files", title: "Original imported backup files", count: inventory.provenance.count))
        }
        var warnings = [
            "All original imported backup files, raw response drafts, original plan-response text and private database recovery copies are removed. They can contain another copy of selected data, including backups pasted into the plan importer. Parsed records outside this selection and its listed dependencies are kept.",
            "Files you exported, text copied to another app, system backups and workouts already saved in Apple Health are outside this deletion. Remove Health workouts in Health if desired. Minimal local Health export receipts remain to prevent duplicate exports."
        ]
        if clearAI { warnings.append("Prompt history, copied profile snapshots and raw plan-response text are removed together so deleted details cannot remain in a previous draft.") }
        if selection.contains(.plans) { warnings.append("The active plan is cleared. Kept workout history retains its original prescribed instructions and targets; deleting plan sources does not rewrite performed history.") }
        if selection.contains(.sleepAndBody), inventory.records.contains(where: { $0.category == .legacyCheckIns }) {
            warnings.append("Shared legacy daily check-in records are also removed because they can contain sleep answers. Separate workout recovery records remain unless Workout history and recovery is selected.")
        }
        if rotate { warnings.append("Pending workout drafts are removed. The Watch workspace is retired to prevent disconnected records returning; any remaining active plan will be sent again. Kept historical workouts are not rewritten.") }
        return .init(selection: selection, rows: rows, warnings: warnings, rotatesGeneration: rotate,
                     fingerprint: inventory.fingerprint, removedKeys: keys)
    }

    /// Caller must additionally guard live transport requests and unsaved in-memory changes.
    /// The preview is rechecked before cleanup or mutation; stale approvals cannot delete new data.
    func delete(_ preview: WorkspaceDeletionPreview) throws -> WorkspaceDeletionResult {
        let fresh = try self.preview(selection: preview.selection)
        guard fresh.fingerprint == preview.fingerprint, fresh.removedKeys == preview.removedKeys else {
            throw invalid("Your saved data changed after this preview. Review the deletion again.")
        }
        let inventory = try inspect()
        let clearAI = preview.selection.contains(.profile) || preview.selection.contains(.aiDrafts) || preview.selection.contains(.plans)
        let generation = preview.rotatesGeneration ? UUID().uuidString : inventory.identity.syncGeneration
        // Cleanup is intentionally before commit: failure leaves the live store intact. A later
        // failed save can lose old recovery copies, but never the original current records.
        try purgeRecoveryCopies(context)
        do {
            var snapshot = inventory.snapshot
            if preview.selection.contains(.profile) {
                let units = snapshot.profile.units
                snapshot.profile = TrainingProfile(); snapshot.profile.units = units
                snapshot.onboardingStep = 0
            }
            if clearAI {
                snapshot.promptDraft = ""; snapshot.promptProfile = nil; snapshot.promptTemplateVersion = nil
                snapshot.previousPrompts = []
            }
            snapshot.importText = ""; snapshot.reviewedSource = nil
            for row in inventory.drafts { context.delete(row) }
            if preview.selection.contains(.plans) { snapshot.activeRevisionID = nil }
            let payload = try JSONEncoder().encode(snapshot)
            if let row = inventory.workspace { row.payload = payload }
            else { context.insert(WorkspaceRecord(payload: payload)) }
            for row in inventory.plans {
                if preview.removedKeys.contains("plans:\(row.id)") { context.delete(row) }
                else { row.sourceText = "" }
            }
            for row in inventory.workouts where preview.removedKeys.contains("workouts:\(row.id.uuidString)") { context.delete(row) }
            for row in inventory.tracking where preview.removedKeys.contains("\(row.category):\(row.id.uuidString)") { context.delete(row) }
            for row in inventory.archives where preview.removedKeys.contains(row.key) { context.delete(row) }
            for row in inventory.progression {
                if inventory.records.contains(where: {
                    $0.id == row.id && $0.payload["nativeType"]?.string?.hasPrefix("progression-") == true && preview.removedKeys.contains($0.key)
                }) { context.delete(row) }
            }
            for row in inventory.schedule where preview.removedKeys.contains("settings:schedule:\(row.id)") { context.delete(row) }
            for row in inventory.provenance { context.delete(row) }
            inventory.identity.syncGeneration = generation
            try commit(context)
            return .init(syncGeneration: generation, rotatedGeneration: preview.rotatesGeneration)
        } catch {
            context.rollback()
            throw error
        }
    }

    private struct Inventory {
        let workspace: WorkspaceRecord?
        let snapshot: WorkspaceSnapshot
        let identity: RuntimeIdentityRecord
        let plans: [ActivatedPlanRecord]
        let drafts: [PlanDraftHistoryRecord]
        let workouts: [WorkoutRecord]
        let tracking: [TrackingRecord]
        let archives: [BackupArchiveRecord]
        let provenance: [BackupProvenanceRecord]
        let progression: [ProgressionRecord]
        let schedule: [ScheduleExceptionRecord]
        let records: [BackupRecord]
        let fingerprint: String
    }

    private func inspect() throws -> Inventory {
        guard !context.hasChanges else { throw invalid("Save pending changes before reviewing deletion.") }
        let workspaces = try context.fetch(FetchDescriptor<WorkspaceRecord>())
        let identities = try context.fetch(FetchDescriptor<RuntimeIdentityRecord>())
        guard workspaces.count <= 1, identities.count == 1, let identity = identities.first else {
            throw invalid("The workspace identity could not be verified. No data was deleted.")
        }
        let snapshot = try workspaces.first.map { try JSONDecoder().decode(WorkspaceSnapshot.self, from: $0.payload) } ?? WorkspaceSnapshot()
        guard snapshot.storageVersion == 1 else { throw invalid("This workspace version cannot be changed here.") }
        let workouts = try context.fetch(FetchDescriptor<WorkoutRecord>())
        let annotations = WorkoutAnnotationStore(context: context)
        for row in workouts {
            let workout = try JSONDecoder().decode(WorkoutSession.self, from: row.payload)
            guard workout.id == row.id, WorkoutSessionValidator.validate(workout).isEmpty else { throw invalid("A saved workout needs recovery before deletion can be reviewed.") }
            guard workout.syncGeneration != identity.syncGeneration || workout.state.isTerminal || annotations.isOwnerUnavailable(workout) else {
                throw invalid("Finish or abandon active recordings before deleting data. Review an unavailable recording device explicitly if it cannot return.")
            }
        }
        let records = try WorkspaceBackupStore(context: context).records()
        let archives = try context.fetch(FetchDescriptor<BackupArchiveRecord>())
        let provenance = try context.fetch(FetchDescriptor<BackupProvenanceRecord>())
        // Raw workspace bytes include promptProfile, which is deliberately absent from portable
        // exports. Source bytes and archive metadata also participate in stale-preview detection.
        var fingerprints = records.map { "record:\($0.key):\($0.fingerprint)" }
        let workspaceData = try workspaces.first.map {
            try JSONDecoder().decode(BackupJSONValue.self, from: $0.payload).canonicalData()
        } ?? Data()
        fingerprints.append("workspace:\(BackupDigest.hash(workspaceData))")
        fingerprints.append("identity:\(identity.deviceID):\(identity.syncGeneration)")
        fingerprints += provenance.map { "source:\($0.sourceFingerprint):\(BackupDigest.hash($0.originalInput))" }
        fingerprints += archives.map { "archive:\($0.key):\($0.sourceFingerprint):\($0.needsReview):\($0.importedAt.timeIntervalSinceReferenceDate)" }
        let fingerprint = BackupDigest.hash(try JSONEncoder().encode(fingerprints.sorted()))
        return Inventory(workspace: workspaces.first, snapshot: snapshot, identity: identity,
            plans: try context.fetch(FetchDescriptor<ActivatedPlanRecord>()),
            drafts: try context.fetch(FetchDescriptor<PlanDraftHistoryRecord>()), workouts: workouts,
            tracking: try context.fetch(FetchDescriptor<TrackingRecord>()), archives: archives, provenance: provenance,
            progression: try context.fetch(FetchDescriptor<ProgressionRecord>()),
            schedule: try context.fetch(FetchDescriptor<ScheduleExceptionRecord>()), records: records, fingerprint: fingerprint)
    }

    private func title(_ category: BackupCategory) -> String {
        switch category {
        case .plans: "Saved plan revisions"
        case .workouts: "Workout records and review decisions"
        case .drafts: "Workout drafts and conflict reviews"
        case .sleep: "Sleep entries"
        case .body: "Body measurements"
        case .recovery: "Recovery and coaching answers"
        case .activities: "Reusable activities"
        case .settings: "Dependent plan settings and accepted advice"
        case .legacyCheckIns: "Shared legacy daily check-ins"
        case .profile: "Training profile"
        case .promptHistory: "Prompt collection"
        case .rawAIResponses: "AI response drafts and plan sources"
        }
    }
    private func invalid(_ message: String) -> BackupError { .invalid(message) }
}
