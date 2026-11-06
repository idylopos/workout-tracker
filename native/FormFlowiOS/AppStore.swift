import Foundation
import Observation
import SwiftData
import FormFlowCore

@MainActor @Observable
final class AppStore {
    var profile = TrainingProfile()
    var onboardingStep = 0
    var promptDraft = ""
    var importText = ""
    var importResult: PlanImportResult?
    private(set) var activePlan: WeeklyPlan?
    private(set) var activationDate: Date?
    private(set) var planRevision = 0
    var errorMessage: String?
    var questionnairePresented = false
    var promptPresented = false
    var importPresented = false
    var workoutPresented = false
    var selectedWorkoutID: UUID?
    private(set) var workouts: [WorkoutSession] = []
    private(set) var deviceID = ""
    private(set) var syncGeneration = ""
    private(set) var lastWorkoutSave: Date?
    private(set) var sleepRecords: [ManualSleepRecord] = []
    private(set) var bodyRecords: [BodyMeasurementRecord] = []
    private(set) var recoveryRecords: [SessionRecoveryRecord] = []
    private(set) var health: HealthRecording?
    private(set) var requiresWorkspaceReload = false
    let bridge: PlanBridge
    let privacyLock: AppPrivacyLock
    let progression: ProgressionStore
    let scheduleExceptions: ScheduleExceptionStore
    let workoutAnnotations: WorkoutAnnotationStore
    let conflictReviews: WorkoutConflictReviewStore

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let commit: (ModelContext) throws -> Void
    @ObservationIgnored private var record: WorkspaceRecord?
    @ObservationIgnored private var activeRevisionID: String?
    @ObservationIgnored private var previousPrompts: [PromptSnapshot] = []
    private var promptProfile: TrainingProfile?
    private var promptTemplateVersion: Int?
    @ObservationIgnored private var reviewedSource: String?
    @ObservationIgnored private var pendingWorkoutSave: WorkoutSession?
    @ObservationIgnored private var disablePrivacyLockAfterReload = false
    @ObservationIgnored private var workoutRows: [UUID: WorkoutRecord] = [:]

    var isPromptOutdated: Bool {
        !promptDraft.isEmpty && (promptProfile != profile || promptTemplateVersion != PromptBuilder.templateVersion)
    }
    var activePlanRevisionID: String? { activeRevisionID }
    var savedPromptHistory: [PromptSnapshot] { previousPrompts }
    var includedWorkouts: [WorkoutSession] { workoutAnnotations.includedWorkouts(workouts) }
    func isRetiredIncomplete(_ workout: WorkoutSession) -> Bool {
        !workout.state.isTerminal && workout.syncGeneration != syncGeneration
    }
    var workoutsForScheduling: [WorkoutSession] { workouts.filter { !isRetiredIncomplete($0) } }

    func savedPlanDrafts() throws -> [PlanDraftHistoryRecord] {
        try context.fetch(FetchDescriptor<PlanDraftHistoryRecord>()).sorted { $0.createdAt > $1.createdAt }
    }

    func savedPlanRevisions() throws -> [SavedPlanRevision] {
        try context.fetch(FetchDescriptor<ActivatedPlanRecord>()).map { row in
            let plan = try JSONDecoder().decode(WeeklyPlan.self, from: row.planData)
            guard !PlanValidator.validate(plan, legacy: true).contains(where: { $0.severity == .error }) else {
                throw PlanRevisionReviewError.invalidSavedRevision
            }
            return SavedPlanRevision(id: row.id, sequence: row.sequence, createdAt: row.createdAt,
                                     activationDate: row.activationDate, plan: plan, sourceText: row.sourceText)
        }.sorted { $0.sequence > $1.sequence }
    }

    func reviewPlanImport(_ plan: WeeklyPlan) throws -> PlanImportReview {
        let result = PlanImporter.importText(importText)
        guard reviewedSource == importText, result.canActivate, result.plan == plan else { throw PlanRevisionReviewError.changed }
        let matches = try savedPlanRevisions().filter { $0.plan.id == plan.id || $0.plan == plan }
        return .init(sourceText: importText, candidate: plan, sourceVersion: result.sourceVersion,
                     matches: matches, activeRevisionID: activeRevisionID)
    }

    /// Load a frozen revision into the ordinary review flow. This never reactivates it implicitly.
    @discardableResult
    func reviewSavedPlanRevision(_ id: String) -> Bool {
        do {
            guard let revision = try savedPlanRevisions().first(where: { $0.id == id }) else { throw PlanRevisionReviewError.invalidSavedRevision }
            let source: String
            let original = PlanImporter.importText(revision.sourceText)
            if original.canActivate && original.plan == revision.plan { source = revision.sourceText }
            else {
                source = String(decoding: try JSONEncoder().encode(revision.plan), as: UTF8.self)
                guard PlanImporter.importText(source).canActivate else { throw PlanRevisionReviewError.invalidSavedRevision }
            }
            return restoreImportDraft(source)
        } catch { errorMessage = error.localizedDescription; return false }
    }

    @discardableResult
    func restoreImportDraft(_ source: String) -> Bool {
        let previous = importText
        let previousReview = reviewedSource
        let previousResult = importResult
        archiveCurrentDraft()
        importText = source
        reviewedSource = nil
        importResult = nil
        if saveDraft() { importPresented = true; return true }
        importText = previous
        reviewedSource = previousReview
        importResult = previousResult
        return false
    }

    @discardableResult
    func applyFutureProgressionTarget(_ target: FutureProgressionTarget) -> Bool {
        guard var plan = activePlan, let activeRevisionID, let activationDate,
              let source = workouts.first(where: { $0.id == target.sourceSessionID }),
              let exercise = source.exercises.first(where: { $0.id == target.sourceExerciseID }),
              let dayIndex = plan.days.firstIndex(where: { $0.sessions.contains { $0.id == source.prescription.id } }),
              let sessionIndex = plan.days[dayIndex].sessions.firstIndex(where: { $0.id == source.prescription.id }),
              let exerciseIndex = plan.days[dayIndex].sessions[sessionIndex].exercises.firstIndex(where: { $0.instanceId == exercise.prescription.instanceId }) else {
            errorMessage = "This recommendation no longer matches the active plan. Review the current plan first."
            return false
        }
        do {
            try progression.validateAndStageAcceptance(target, currentPlan: plan, revision: activeRevisionID,
                workouts: includedWorkouts, recovery: recoveryRecords, in: context)
            var next = plan.days[dayIndex].sessions[sessionIndex].exercises[exerciseIndex]
            next.measurement = target.measurement
            if let load = target.load { next.target.load = load }
            if let assistance = target.assistance { next.target.assistance = assistance }
            if let reps = target.restartReps {
                next.target.reps = RepRange(min: reps, max: max(reps, next.target.reps?.max ?? reps))
            }
            if target.action == .step, let step = target.pullUpStep, let prescription = BuiltInProgression.pullUpSteps.first(where: { $0.id == step }) {
                next.measurement = prescription.measurement
                next.target.sets = prescription.sets
                next.target.reps = .init(min: prescription.minReps, max: prescription.maxReps)
                next.target.effort = .init(kind: .rir, min: prescription.minimumRIR, max: prescription.minimumRIR)
                if prescription.measurement == .reps { next.target.assistance = nil }
            }
            if let distance = target.longRunDistance {
                let maximum = target.longRunStage == 18 && distance.unit == .km ? 7.0 : distance.value
                next.target.distance = .init(min: distance.value, max: maximum, unit: distance.unit)
            }
            plan.days[dayIndex].sessions[sessionIndex].exercises[exerciseIndex] = next
            let issues = PlanValidator.validate(plan).filter { $0.severity == .error }
            guard issues.isEmpty else { throw BackupError.invalid(issues.map(\.message).joined(separator: "\n")) }
            let data = try JSONEncoder().encode(plan)
            let revision = ActivatedPlanRecord(sequence: planRevision + 1, activationDate: activationDate,
                planData: data, sourceText: String(decoding: data, as: UTF8.self))
            context.insert(revision)
            try progression.stageEnrollmentCarryForward(from: activeRevisionID, to: revision.id, plan: plan,
                target: target, sourceSessionID: source.prescription.id,
                sourceExerciseInstanceID: exercise.prescription.instanceId, in: context)
            try writeSnapshot(activeRevisionID: revision.id)
            try commit(context)
            self.activeRevisionID = revision.id
            activePlan = plan
            planRevision = revision.sequence
            publishActivePlan()
            refreshProgressionAfterCommit()
            return true
        } catch {
            context.rollback()
            record = nil
            try? progression.reload()
            errorMessage = "The future target was not saved. \(error.localizedDescription)"
            return false
        }
    }

    func exportBackup(categories: Set<BackupCategory>) throws -> Data {
        guard pendingWorkoutSave == nil else { throw BackupError.invalid("Retry your unsaved workout change before exporting.") }
        guard saveDraft() else { throw BackupError.invalid(errorMessage ?? "The latest draft could not be saved.") }
        return try WorkspaceBackupStore(context: context, commit: commit).export(categories: categories)
    }

    func stageBackup(_ data: Data) throws -> StagedBackup {
        try WorkspaceBackupStore(context: context, commit: commit).stage(data)
    }

    func archivedBackupRecords() throws -> [BackupRecord] {
        try WorkspaceBackupStore(context: context, commit: commit).archivedRecords()
    }

    func savedExtraActivities() throws -> [PlanExercise] {
        try archivedBackupRecords().filter { $0.category == .activities && $0.payload["nativeActivityVersion"] == .number(1) }
            .map { record in
                guard let payload = record.payload["exercise"] else {
                    throw BackupError.invalid("A saved activity is missing its exercise prescription.")
                }
                let exercise = try payload.decode(PlanExercise.self)
                let issues = PlanValidator.validateExercise(exercise).filter { $0.severity == .error }
                guard issues.isEmpty else {
                    throw BackupError.invalid("A saved activity could not be used: \(issues.map(\.message).joined(separator: " "))")
                }
                return exercise
            }
    }

    func legacySavedActivities() throws -> [LegacySavedActivityReview] {
        try archivedBackupRecords().compactMap(LegacySavedActivityReview.init(record:))
    }

    @discardableResult
    func saveExtraActivityTemplate(_ exercise: PlanExercise, legacySource: LegacySavedActivityReview? = nil) -> Bool {
        do {
            let issues = PlanValidator.validateExercise(exercise).filter { $0.severity == .error }
            guard issues.isEmpty else { throw BackupError.invalid(issues.map(\.message).joined(separator: " ")) }
            let item: BackupRecord
            if let legacySource {
                guard let original = try archivedBackupRecords().first(where: { $0.key == legacySource.id }) else {
                    throw BackupError.invalid("The imported activity changed or was deleted. Review it again before saving a native copy.")
                }
                item = try legacySource.nativeCopy(exercise: exercise, currentSource: original)
            } else {
                let id = "native-activity:\(exercise.exerciseId)"
                var payload: [String: BackupJSONValue] = ["nativeActivityVersion": .number(1), "exercise": try .encode(exercise)]
                var references: [BackupReference] = []
                if let previous = try archivedBackupRecords().first(where: { $0.category == .activities && $0.id == id }),
                   let provenance = previous.payload["legacyActivitySource"] {
                    guard let sourceID = provenance["recordID"]?.string,
                          let fingerprint = provenance["fingerprint"]?.string, fingerprint.count == 64,
                          provenance.object.map({ Set($0.keys) == Set(["recordID", "fingerprint"]) }) == true,
                          previous.references == [.init(category: .activities, id: sourceID)] else {
                        throw BackupError.invalid("This activity's imported source reference needs review before editing.")
                    }
                    payload["legacyActivitySource"] = provenance
                    references = previous.references
                }
                item = BackupRecord(id: id, category: .activities, payload: .object(payload), references: references)
            }
            let data = try JSONEncoder().encode(item)
            if let existing = try context.fetch(FetchDescriptor<BackupArchiveRecord>()).first(where: { $0.key == item.key }) {
                existing.recordData = data
            } else {
                context.insert(BackupArchiveRecord(key: item.key, recordData: data, sourceFingerprint: "local", needsReview: false))
            }
            try commit(context)
            return true
        } catch {
            context.rollback()
            errorMessage = "The activity template was not saved. \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func startExtraActivity(_ exercise: PlanExercise) -> Bool {
        guard currentWorkout == nil else {
            errorMessage = "Add this activity to the current workout, or finish that workout before starting separately."
            return false
        }
        do {
            let session = PlanSession(id: "activity-\(UUID().uuidString.lowercased())", name: exercise.name,
                kind: "mixed", estimatedMinutes: 0, exercises: [exercise])
            let workout = try WorkoutSession.start(prescription: session, planID: "manual-activities",
                planRevisionID: "manual-\(UUID().uuidString)", ownerDeviceID: deviceID,
                at: Date(), timeZoneIdentifier: TimeZone.current.identifier, syncGeneration: syncGeneration)
            guard persistWorkout(workout) else { return false }
            presentWorkout(workout)
            return true
        } catch {
            errorMessage = "The activity could not start. Check its targets and measurements."
            return false
        }
    }

    func remoteSetDraft(sessionID: UUID, setID: UUID) -> RemoteSetDraft? {
        let key = RemoteSetDraft.key(sessionID: sessionID, setID: setID)
        guard let row = try? context.fetch(FetchDescriptor<BackupArchiveRecord>()).first(where: { $0.key == key }),
              let record = try? JSONDecoder().decode(BackupRecord.self, from: row.recordData),
              let value = try? record.payload.decode(RemoteSetDraft.self),
              value.syncGeneration == syncGeneration, value.setID == setID, value.sessionID == sessionID else { return nil }
        return value
    }

    @discardableResult
    func saveRemoteSetDraft(_ draft: RemoteSetDraft) -> Bool {
        do {
            let backup = BackupRecord(id: "proposed-set:\(draft.sessionID):\(draft.setID)", category: .drafts,
                                      payload: try .encode(draft))
            let data = try JSONEncoder().encode(backup)
            if let row = try context.fetch(FetchDescriptor<BackupArchiveRecord>()).first(where: { $0.key == backup.key }) {
                row.recordData = data
            } else {
                context.insert(BackupArchiveRecord(key: backup.key, recordData: data, sourceFingerprint: "local", needsReview: true))
            }
            try commit(context)
            return true
        } catch {
            context.rollback()
            errorMessage = "Your proposed edit was not saved. Keep this form open and retry. \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func submitRemoteSetDraft(_ draft: RemoteSetDraft) -> Bool {
        guard draft.syncGeneration == syncGeneration, saveRemoteSetDraft(draft) else { return false }
        let command: WorkoutCommand = draft.markComplete ? .logSet(setID: draft.setID, values: draft.values) : .updateSet(setID: draft.setID, values: draft.values)
        let operation = WorkoutOperation(id: draft.operationID, sessionID: draft.sessionID, originDeviceID: deviceID,
            syncGeneration: draft.syncGeneration, expectedRevision: draft.baseRevision, command: command, createdAt: draft.createdAt)
        guard bridge.proposeWorkoutChange(operation) else {
            errorMessage = "The proposed edit is saved here but could not be queued for Watch. Retry when connected."
            return false
        }
        return true
    }

    func restoreBackup(_ stage: StagedBackup, choices: [String: BackupConflictChoice]) throws {
        guard !requiresWorkspaceReload, pendingWorkoutSave == nil,
              !workouts.contains(where: { !$0.state.isTerminal && !isRetiredIncomplete($0) && !workoutAnnotations.isOwnerUnavailable($0) }) else {
            throw BackupError.invalid("Finish or abandon active workouts and save pending changes before restoring a backup.")
        }
        try WorkspaceBackupStore(context: context, commit: commit).restore(stage: stage, conflictChoices: choices)
        try reloadSavedWorkspace()
        publishActivePlan()
    }

    func previewDeletion(selection: Set<WorkspaceDeletionCategory>) throws -> WorkspaceDeletionPreview {
        try requireDeletionReady(rotating: selection.contains(.plans) || selection.contains(.workoutHistory))
        guard saveDraft() else { throw BackupError.invalid(errorMessage ?? "Save pending changes before reviewing deletion.") }
        return try WorkspaceDeletionStore(context: context, commit: commit).preview(selection: selection)
    }

    @discardableResult
    func deleteSelectedData(_ preview: WorkspaceDeletionPreview) -> Bool {
        var didCommit = false
        do {
            try requireDeletionReady(rotating: preview.rotatesGeneration)
            let result = try WorkspaceDeletionStore(context: context, commit: commit).delete(preview)
            didCommit = true
            requiresWorkspaceReload = true
            clearDisplayedWorkspace()
            syncGeneration = result.syncGeneration
            let transportCleaned = !result.rotatedGeneration || bridge.purgeForReset(syncGeneration: result.syncGeneration)
            try reloadSavedWorkspace()
            requiresWorkspaceReload = false
            publishActivePlan()
            errorMessage = transportCleaned ? nil : "The reviewed data was deleted. Some old transfer files could not be removed; cleanup will retry when the app opens."
            return true
        } catch {
            if didCommit {
                clearDisplayedWorkspace()
                errorMessage = "The reviewed data was deleted, but the remaining workspace could not be loaded. Retry loading or reopen the app. \(error.localizedDescription)"
            } else {
                context.rollback()
                record = nil
                workoutRows = [:]
                errorMessage = "No saved records were deleted. \(error.localizedDescription)"
            }
            return false
        }
    }

    private func requireDeletionReady(rotating: Bool) throws {
        guard !requiresWorkspaceReload, pendingWorkoutSave == nil, bridge.remoteStartIntents.isEmpty,
              !workouts.contains(where: { !$0.state.isTerminal && !isRetiredIncomplete($0) && !workoutAnnotations.isOwnerUnavailable($0) }) else {
            throw BackupError.invalid("Finish active recordings and resolve pending starts or unsaved changes before deleting data. Review an unavailable recording device explicitly if it cannot return.")
        }
        guard !rotating || bridge.pendingWorkoutProposals.isEmpty else {
            throw BackupError.invalid("Resolve pending Watch edits before deleting training records. Their values remain saved until the recording device acknowledges them.")
        }
    }

    @discardableResult
    func resetWorkspace() -> Bool {
        let priorWorkout = currentWorkout
        var didCommit = false
        do {
            // Remove private recovery copies before committing deletion. A cleanup failure leaves
            // the live records intact; a successful reset must not retain copies of deleted data.
            try WorkspaceStoreRecovery.purgeSnapshots(context: context)
            for item in try context.fetch(FetchDescriptor<WorkspaceRecord>()) { context.delete(item) }
            for item in try context.fetch(FetchDescriptor<ActivatedPlanRecord>()) { context.delete(item) }
            for item in try context.fetch(FetchDescriptor<PlanDraftHistoryRecord>()) { context.delete(item) }
            for item in try context.fetch(FetchDescriptor<WorkoutRecord>()) { context.delete(item) }
            for item in try context.fetch(FetchDescriptor<TrackingRecord>()) { context.delete(item) }
            for item in try context.fetch(FetchDescriptor<BackupArchiveRecord>()) { context.delete(item) }
            for item in try context.fetch(FetchDescriptor<BackupProvenanceRecord>()) { context.delete(item) }
            for item in try context.fetch(FetchDescriptor<ProgressionRecord>()) { context.delete(item) }
            for item in try context.fetch(FetchDescriptor<ScheduleExceptionRecord>()) { context.delete(item) }
            guard let identity = try context.fetch(FetchDescriptor<RuntimeIdentityRecord>()).first else {
                throw StorageError.ambiguousWorkspace
            }
            identity.syncGeneration = UUID().uuidString
            context.insert(WorkspaceRecord(payload: try JSONEncoder().encode(WorkspaceSnapshot())))
            try commit(context)
            didCommit = true
            disablePrivacyLockAfterReload = true
            requiresWorkspaceReload = true
            clearDisplayedWorkspace()
            syncGeneration = identity.syncGeneration
            if let priorWorkout, let health { Task { await health.discard(workout: priorWorkout) } }
            let cachesRemoved = bridge.purgeForReset(syncGeneration: syncGeneration)
            try reloadSavedWorkspace()
            requiresWorkspaceReload = false
            privacyLock.disable()
            disablePrivacyLockAfterReload = false
            errorMessage = cachesRemoved ? nil : "Your app records were deleted. Some device-transfer files could not be removed; cleanup will retry when the app opens."
            return true
        } catch {
            context.rollback()
            record = nil
            workoutRows = [:]
            if didCommit { clearDisplayedWorkspace() }
            errorMessage = didCommit
                ? "Your app records were deleted, but the empty workspace could not be reloaded. Reopen the app to finish resetting. \(error.localizedDescription)"
                : "Your data could not be reset. Existing records have been preserved. \(error.localizedDescription)"
            return false
        }
    }

    func retryWorkspaceReload() {
        guard requiresWorkspaceReload else { return }
        do {
            try reloadSavedWorkspace()
            requiresWorkspaceReload = false
            if disablePrivacyLockAfterReload { privacyLock.disable() }
            disablePrivacyLockAfterReload = false
            errorMessage = nil
            publishActivePlan()
        } catch {
            clearDisplayedWorkspace()
            errorMessage = "Your changes were saved, but the workspace could not be loaded. Reopen the app to retry or export its recovery files. \(error.localizedDescription)"
        }
    }

    private func clearDisplayedWorkspace() {
        profile = TrainingProfile(); onboardingStep = 0
        promptDraft = ""; promptProfile = nil; promptTemplateVersion = nil; previousPrompts = []
        importText = ""; importResult = nil; reviewedSource = nil
        activePlan = nil; activeRevisionID = nil; activationDate = nil; planRevision = 0
        workouts = []; workoutRows = [:]; pendingWorkoutSave = nil; lastWorkoutSave = nil
        sleepRecords = []; bodyRecords = []; recoveryRecords = []
        selectedWorkoutID = nil; workoutPresented = false; questionnairePresented = false
        promptPresented = false; importPresented = false; record = nil
    }

    private func reloadSavedWorkspace() throws {
        let saved = try context.fetch(FetchDescriptor<WorkspaceRecord>()).first
        let snapshot = try saved.map { try JSONDecoder().decode(WorkspaceSnapshot.self, from: $0.payload) } ?? WorkspaceSnapshot()
        guard snapshot.storageVersion == 1 else { throw StorageError.unsupportedVersion }
        let revisions = try context.fetch(FetchDescriptor<ActivatedPlanRecord>())
        let active = revisions.first { $0.id == snapshot.activeRevisionID }
        if snapshot.activeRevisionID != nil && active == nil { throw StorageError.missingActivePlan }
        let plan = try active.map { try JSONDecoder().decode(WeeklyPlan.self, from: $0.planData) }
        let rows = try context.fetch(FetchDescriptor<WorkoutRecord>())
        let loadedWorkouts = try rows.map { row -> WorkoutSession in
            let workout = try JSONDecoder().decode(WorkoutSession.self, from: row.payload)
            guard workout.id == row.id, WorkoutSessionValidator.validate(workout).isEmpty else { throw StorageError.unsupportedVersion }
            return workout
        }
        var sleep: [ManualSleepRecord] = []
        var body: [BodyMeasurementRecord] = []
        var recovery: [SessionRecoveryRecord] = []
        for row in try context.fetch(FetchDescriptor<TrackingRecord>()) {
            switch row.category {
            case "sleep":
                let value = try JSONDecoder().decode(ManualSleepRecord.self, from: row.payload)
                try value.validate(); sleep.append(value)
            case "body":
                let value = try JSONDecoder().decode(BodyMeasurementRecord.self, from: row.payload)
                try value.validate(); body.append(value)
            case "recovery":
                let value = try JSONDecoder().decode(SessionRecoveryRecord.self, from: row.payload)
                try value.validate(); recovery.append(value)
            default: throw StorageError.unsupportedVersion
            }
        }
        record = saved
        profile = snapshot.profile
        onboardingStep = min(max(snapshot.onboardingStep, 0), 7)
        promptDraft = snapshot.promptDraft
        promptProfile = snapshot.promptProfile
        promptTemplateVersion = snapshot.promptTemplateVersion
        previousPrompts = snapshot.previousPrompts
        importText = snapshot.importText
        reviewedSource = snapshot.reviewedSource
        importResult = reviewedSource == importText && !importText.isEmpty ? PlanImporter.importText(importText) : nil
        activeRevisionID = snapshot.activeRevisionID
        activePlan = plan
        activationDate = active?.activationDate
        planRevision = revisions.map(\.sequence).max() ?? 0
        workouts = loadedWorkouts.sorted { $0.startedAt > $1.startedAt }
        workoutRows = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        sleepRecords = sleep
        bodyRecords = body
        recoveryRecords = recovery
        try progression.reload()
        try scheduleExceptions.reload()
    }

    init(context: ModelContext, bridge: PlanBridge? = nil, healthEnabled: Bool = true,
         privacyDefaults: UserDefaults = .standard,
         commit: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws {
        self.context = context
        self.commit = commit
        self.bridge = bridge ?? PlanBridge()
        self.privacyLock = AppPrivacyLock(defaults: privacyDefaults)
        self.progression = try ProgressionStore(context: context, commit: commit)
        self.scheduleExceptions = try ScheduleExceptionStore(context: context, commit: commit)
        self.workoutAnnotations = WorkoutAnnotationStore(context: context, commit: commit)
        self.conflictReviews = WorkoutConflictReviewStore(context: context, commit: commit)
        context.autosaveEnabled = false
        let records = try context.fetch(FetchDescriptor<WorkspaceRecord>())
        guard records.count <= 1 else { throw StorageError.ambiguousWorkspace }
        if let record = records.first {
            let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: record.payload)
            guard snapshot.storageVersion == 1 else { throw StorageError.unsupportedVersion }
            self.record = record
            profile = snapshot.profile
            onboardingStep = min(max(snapshot.onboardingStep, 0), 7)
            promptDraft = snapshot.promptDraft
            promptProfile = snapshot.promptProfile
            promptTemplateVersion = snapshot.promptTemplateVersion
            previousPrompts = snapshot.previousPrompts
            importText = snapshot.importText
            reviewedSource = snapshot.reviewedSource
            activeRevisionID = snapshot.activeRevisionID
            if reviewedSource == importText && !importText.isEmpty {
                importResult = PlanImporter.importText(importText)
            }
        }
        let revisions = try context.fetch(FetchDescriptor<ActivatedPlanRecord>())
        planRevision = revisions.map(\.sequence).max() ?? 0
        if let activeRevisionID {
            guard let revision = revisions.first(where: { $0.id == activeRevisionID }) else {
                throw StorageError.missingActivePlan
            }
            activePlan = try JSONDecoder().decode(WeeklyPlan.self, from: revision.planData)
            activationDate = revision.activationDate
        }
        let identities = try context.fetch(FetchDescriptor<RuntimeIdentityRecord>())
        guard identities.count <= 1 else { throw StorageError.ambiguousWorkspace }
        let identity = identities.first ?? RuntimeIdentityRecord()
        if identities.isEmpty {
            context.insert(identity)
            try commit(context)
        }
        deviceID = identity.deviceID
        syncGeneration = identity.syncGeneration
        health = HealthRecording(localDeviceID: identity.deviceID, isEnabled: healthEnabled)
        let savedWorkouts = try context.fetch(FetchDescriptor<WorkoutRecord>())
        let loadedWorkouts = try savedWorkouts.map { row -> WorkoutSession in
            let workout = try JSONDecoder().decode(WorkoutSession.self, from: row.payload)
            guard workout.id == row.id, WorkoutSessionValidator.validate(workout).isEmpty else {
                throw StorageError.unsupportedVersion
            }
            return workout
        }
        workoutRows = Dictionary(uniqueKeysWithValues: savedWorkouts.map { ($0.id, $0) })
        workouts = loadedWorkouts.sorted { $0.startedAt > $1.startedAt }
        for row in try context.fetch(FetchDescriptor<TrackingRecord>()) {
            switch row.category {
            case "sleep":
                let value = try JSONDecoder().decode(ManualSleepRecord.self, from: row.payload)
                try value.validate()
                sleepRecords.append(value)
            case "body":
                let value = try JSONDecoder().decode(BodyMeasurementRecord.self, from: row.payload)
                try value.validate()
                bodyRecords.append(value)
            case "recovery":
                let value = try JSONDecoder().decode(SessionRecoveryRecord.self, from: row.payload)
                try value.validate()
                recoveryRecords.append(value)
            default: throw StorageError.unsupportedVersion
            }
        }
        self.bridge.configureSyncGeneration(syncGeneration)
        self.bridge.onWorkoutReceived = { [weak self] incoming in
            self?.receiveWatchWorkout(incoming) ?? false
        }
        self.bridge.onRemoteStartResult = { [weak self] result in
            guard let self, result.intent.syncGeneration == self.syncGeneration else { return false }
            if let workout = result.workout, !self.receiveWatchWorkout(workout) { return false }
            if let workout = result.workout, [.started, .existing].contains(result.status) {
                self.presentWorkout(self.workouts.first { $0.id == workout.id } ?? workout)
            }
            if result.status == .rejected { self.errorMessage = result.message }
            return true
        }
        self.bridge.onWorkoutProposalResult = { [weak self] result in
            guard let self, result.operation.syncGeneration == self.syncGeneration else { return false }
            if let workout = result.workout, !self.receiveWatchWorkout(workout) { return false }
            return true
        }
        health?.onSessionStateChanged = { [weak self] id, state, date in
            guard let self, let current = self.currentWorkout, current.id == id,
                  current.state != state else { return }
            self.applyWorkoutCommand(state == .paused ? .pause : .resume, sessionID: id, at: date)
        }
        publishActivePlan()
        if healthEnabled {
            Task { [weak self] in
                guard let self, let health = self.health else { return }
                await health.reconcilePendingExports()
                if let current = self.currentWorkout, await health.recover(workout: current) {
                    await self.reconcileHealthRecording(current, health: health)
                }
            }
        }
    }

    var currentWorkout: WorkoutSession? {
        workouts.first { !$0.state.isTerminal && $0.ownerDeviceID == deviceID && $0.syncGeneration == syncGeneration }
    }

    func presentWorkout(_ workout: WorkoutSession) {
        selectedWorkoutID = workout.id
        workoutPresented = true
    }

    @discardableResult
    func requestWatchStart(_ scheduled: ScheduledPlanSession, recordHealth: Bool = false) -> Bool {
        guard let activePlan, let activeRevisionID,
              activePlan.days.flatMap(\.sessions).contains(scheduled.session) else {
            errorMessage = "Open a session from the active plan before starting on Watch."
            return false
        }
        if let existing = bridge.remoteStartIntents.first(where: { $0.scheduledSessionID == scheduled.id }) {
            bridge.reconcileWatchStart(existing.id)
            return true
        }
        guard canStartScheduledOccurrence(scheduled.id, session: scheduled.session, expectedDate: scheduled.date, at: Date()) else { return false }
        let intent = RemoteWorkoutStartIntent(syncGeneration: syncGeneration, planID: activePlan.id,
            planRevisionID: activeRevisionID, prescriptionID: scheduled.session.id,
            scheduledSessionID: scheduled.id, scheduledDay: LocalTrainingDay(instant: scheduled.date, timeZone: .current),
            recordWithHealth: recordHealth)
        guard bridge.requestWatchStart(intent) else {
            errorMessage = "The Watch start request could not be saved. Reconnect your Watch and try again."
            return false
        }
        return true
    }

    @discardableResult
    func proposeWorkoutCommand(_ command: WorkoutCommand, basedOn workout: WorkoutSession) -> Bool {
        guard workout.ownerDeviceID != deviceID, workout.syncGeneration == syncGeneration else {
            errorMessage = "This workout cannot receive Watch changes in the current workspace."
            return false
        }
        let operation = WorkoutOperation(session: workout, command: command, originDeviceID: deviceID, at: Date())
        guard bridge.proposeWorkoutChange(operation) else {
            errorMessage = "This proposed change was not saved. Keep the form open and retry."
            return false
        }
        errorMessage = nil
        return true
    }

    @discardableResult
    func submitReviewedWorkoutOperation(_ operation: WorkoutOperation) -> Bool {
        guard pendingWorkoutSave == nil,
              operation.originDeviceID == deviceID, operation.syncGeneration == syncGeneration,
              let workout = workouts.first(where: { $0.id == operation.sessionID }),
              operation.expectedRevision == workout.revision else {
            errorMessage = "The workout changed or has an unsaved edit. Review its latest accepted values before submitting again."
            return false
        }
        if workout.ownerDeviceID != deviceID {
            guard bridge.proposeWorkoutChange(operation) else {
                errorMessage = "Your review was saved, but the new proposal could not be queued. Its values have not been applied."
                return false
            }
            errorMessage = nil
            return true
        }
        let result = WorkoutReducer.apply(operation, to: workout, at: Date())
        if result.session != workout, !persistWorkout(result.session) { return false }
        let acceptedDuplicate = result.status == .duplicate && result.session.operationReceipts.contains {
            $0.operation == operation && $0.status == .applied
        }
        guard result.status == .applied || acceptedDuplicate else {
            errorMessage = result.issues.isEmpty
                ? "This proposal was retained previously but has not been accepted. Review the latest workout before trying again."
                : result.issues.map(\.message).joined(separator: "\n")
            return false
        }
        errorMessage = nil
        return true
    }

    @discardableResult
    func startWorkout(_ session: PlanSession, scheduledID: String? = nil, scheduledDate: Date? = nil,
                      recordHealth: Bool = false, at date: Date = Date()) -> Bool {
        guard !requiresWorkspaceReload, pendingWorkoutSave == nil else {
            errorMessage = "Retry your unsaved workout change before starting another recording."
            return false
        }
        if let currentWorkout {
            presentWorkout(currentWorkout)
            return true
        }
        guard let activePlan, let activeRevisionID else {
            errorMessage = "Activate a plan before starting this workout."
            return false
        }
        if let scheduledID, let existing = workoutsForScheduling.first(where: { $0.scheduledSessionID == scheduledID && $0.state != .abandoned }) {
            presentWorkout(existing)
            return true
        }
        guard activePlan.days.flatMap(\.sessions).contains(session) else {
            errorMessage = "This session belongs to an older plan. Open a session from the current schedule."
            return false
        }
        if let scheduledID, !canStartScheduledOccurrence(scheduledID, session: session, expectedDate: scheduledDate, at: date) { return false }
        do {
            let workout = try WorkoutSession.start(prescription: session, planID: activePlan.id,
                planRevisionID: activeRevisionID, scheduledSessionID: scheduledID,
                ownerDeviceID: deviceID, at: date, timeZoneIdentifier: TimeZone.current.identifier,
                syncGeneration: syncGeneration)
            guard persistWorkout(workout) else { return false }
            if recordHealth, let health {
                Task { [weak self] in
                    guard await health.start(workout: workout) else { return }
                    guard let self else {
                        await health.discard(workout: workout)
                        return
                    }
                    await self.reconcileHealthRecording(workout, health: health)
                }
            }
            presentWorkout(workout)
            return true
        } catch {
            errorMessage = "The workout could not start. Review the session prescription."
            return false
        }
    }

    private func reconcileHealthRecording(_ original: WorkoutSession, health: HealthRecording) async {
        guard syncGeneration == original.syncGeneration,
              let latest = workouts.first(where: { $0.id == original.id }) else {
            await health.discard(workout: original)
            return
        }
        if latest.state == .abandoned { await health.discard(workout: latest) }
        else if latest.state == .finished { await health.finish(workout: latest) }
        else if latest.state == .paused { health.pause() }
        else { health.resume() }
    }

    @discardableResult
    func startSeparatePhoneWorkout(after sourceID: UUID) -> Bool {
        guard pendingWorkoutSave == nil, currentWorkout == nil,
              let source = workouts.first(where: { $0.id == sourceID }),
              source.syncGeneration == syncGeneration,
              workoutAnnotations.isOwnerUnavailable(source) else {
            errorMessage = "Review the latest unavailable-device record and finish any iPhone recording first."
            return false
        }
        do {
            let separate = try WorkoutSession.start(prescription: source.prescription,
                planID: source.planID, planRevisionID: source.planRevisionID,
                ownerDeviceID: deviceID, at: Date(), timeZoneIdentifier: TimeZone.current.identifier,
                syncGeneration: syncGeneration)
            guard persistWorkout(separate) else { return false }
            presentWorkout(separate)
            return true
        } catch {
            errorMessage = "The separate iPhone workout could not start. \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func applyWorkoutCommand(_ command: WorkoutCommand, sessionID: UUID, at date: Date = Date()) -> Bool {
        guard pendingWorkoutSave == nil else {
            errorMessage = "Retry the unsaved workout change before making another change."
            return false
        }
        guard let workout = workouts.first(where: { $0.id == sessionID }) else {
            errorMessage = "This workout could not be found."
            return false
        }
        guard !isRetiredIncomplete(workout) else {
            errorMessage = "This incomplete workout is an archived copy from an earlier workspace. Start a new workout to record more activity."
            return false
        }
        guard workout.ownerDeviceID == deviceID else {
            errorMessage = "Send a proposed change to the recording Watch instead of changing its saved copy."
            return false
        }
        let operation = WorkoutOperation(session: workout, command: command, originDeviceID: deviceID, at: date)
        let result = WorkoutReducer.apply(operation, to: workout, at: date)
        if result.session != workout, !persistWorkout(result.session) { return false }
        if result.status == .applied || result.status == .duplicate {
            errorMessage = nil
            return true
        }
        errorMessage = result.issues.map(\.message).joined(separator: "\n")
        return false
    }

    func previousExercise(for exercise: WorkoutExercise, before workout: WorkoutSession) -> WorkoutExercise? {
        includedWorkouts.filter { $0.id != workout.id && $0.planID == workout.planID && $0.state == .finished && $0.startedAt < workout.startedAt }
            .sorted { $0.startedAt > $1.startedAt }
            .compactMap { session in
                session.exercises.first {
                    $0.performedPrescription.exerciseId == exercise.performedPrescription.exerciseId &&
                    $0.performedPrescription.measurement == exercise.performedPrescription.measurement &&
                    $0.performedPrescription.equipment.sorted() == exercise.performedPrescription.equipment.sorted() &&
                    $0.selectedAlternativeID == exercise.selectedAlternativeID &&
                    $0.sets.contains { $0.status == .completed }
                }
            }.first
    }

    private func persistWorkout(_ workout: WorkoutSession) -> Bool {
        guard !requiresWorkspaceReload else { return false }
        let previous = workouts.first { $0.id == workout.id }
        do {
            let data = try JSONEncoder().encode(workout)
            if workoutRows.isEmpty {
                workoutRows = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<WorkoutRecord>()).map { ($0.id, $0) })
            }
            if let saved = workoutRows[workout.id] {
                saved.payload = data
                saved.updatedAt = Date()
            } else {
                let row = WorkoutRecord(id: workout.id, payload: data)
                context.insert(row)
                workoutRows[workout.id] = row
            }
            try commit(context)
            if let index = workouts.firstIndex(where: { $0.id == workout.id }) {
                workouts[index] = workout
            } else {
                workouts.insert(workout, at: 0)
            }
            lastWorkoutSave = Date()
            pendingWorkoutSave = nil
            errorMessage = nil
            if workout.state == .finished || previous?.state != workout.state { publishActivePlan() }
            if workout.ownerDeviceID == deviceID, previous?.state != workout.state,
               let health, health.activeWorkoutID == workout.id {
                switch workout.state {
                case .paused: health.pause()
                case .active: health.resume()
                case .finished: Task { await health.finish(workout: workout) }
                case .abandoned: Task { await health.discard(workout: workout) }
                }
            }
            return true
        } catch {
            context.rollback()
            record = nil
            pendingWorkoutSave = workout
            workoutRows = [:]
            errorMessage = "The workout change was not saved. Keep this screen open and retry. \(error.localizedDescription)"
            return false
        }
    }

    func receiveWatchWorkout(_ incoming: WorkoutSession) -> Bool {
        guard pendingWorkoutSave == nil else { return false }
        guard incoming.syncGeneration == syncGeneration,
              incoming.ownerDeviceID != deviceID,
              WorkoutSessionValidator.validate(incoming).isEmpty else {
            errorMessage = "An incoming Watch workout needs a compatible store and valid recording owner. It has not replaced your records."
            return false
        }
        if let existing = workouts.first(where: { $0.id == incoming.id }) {
            guard existing.ownerDeviceID == incoming.ownerDeviceID,
                  existing.planRevisionID == incoming.planRevisionID,
                  existing.planID == incoming.planID,
                  existing.startedAt == incoming.startedAt,
                  existing.timeZoneIdentifier == incoming.timeZoneIdentifier,
                  existing.scheduledSessionID == incoming.scheduledSessionID,
                  existing.prescription == incoming.prescription else {
                errorMessage = "The Watch sent a different prescription or owner for an existing workout. Both copies need review."
                return false
            }
            switch WorkoutSnapshotMerge.classify(incoming: incoming, existing: existing) {
            case .identical, .older, .staleAudit: return true
            case .newer, .auditExtension: break
            case .conflict:
                errorMessage = "The Watch and iPhone have different values for the same workout revision. The incoming copy is retained for review."
                return false
            }
        }
        return persistWorkout(incoming)
    }

    var recoveryDue: [RecoveryPrompt] {
        let anchors = includedWorkouts.filter { $0.state == .finished }.compactMap { workout -> RecoverySessionAnchor? in
            guard let endedAt = workout.endedAt else { return nil }
            return RecoverySessionAnchor(sessionID: workout.id, endedAt: endedAt, timeZoneID: workout.timeZoneIdentifier)
        }
        return RecoverySchedule.due(sessions: anchors, answers: recoveryRecords, now: Date())
    }

    @discardableResult
    func saveSleep(_ value: ManualSleepRecord) -> Bool {
        do {
            try value.validate()
            guard !sleepRecords.contains(where: { $0.day.date == value.day.date && $0.id != value.id }) else {
                errorMessage = "This date already has a sleep entry. Edit that entry to keep one answer per night."
                return false
            }
            guard saveTracking(value, id: value.id, category: "sleep") else { return false }
            sleepRecords.removeAll { $0.id == value.id }
            sleepRecords.append(value)
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    @discardableResult
    func saveBody(_ value: BodyMeasurementRecord) -> Bool {
        do {
            try value.validate()
            guard !bodyRecords.contains(where: { $0.day.date == value.day.date && $0.id != value.id }) else {
                errorMessage = "This date already has body measurements. Edit that entry to preserve both readings."
                return false
            }
            guard saveTracking(value, id: value.id, category: "body") else { return false }
            bodyRecords.removeAll { $0.id == value.id }
            bodyRecords.append(value)
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    @discardableResult
    func saveRecovery(_ value: SessionRecoveryRecord) -> Bool {
        do {
            try value.validate()
            guard let workout = workouts.first(where: { $0.id == value.sessionID && $0.state == .finished }),
                  let endedAt = workout.endedAt,
                  let zone = TimeZone(identifier: workout.timeZoneIdentifier) else {
                errorMessage = "Choose a finished workout for this recovery answer."
                return false
            }
            let completionDay = LocalTrainingDay(instant: endedAt, timeZone: zone)
            guard value.day.timeZoneID == workout.timeZoneIdentifier,
                  (value.phase == .evening ? value.day.date == completionDay.date : value.day.date > completionDay.date) else {
                errorMessage = "Use the workout's local date for evening recovery and a later local date for next-morning recovery."
                return false
            }
            if let existing = recoveryRecords.first(where: { $0.sessionID == value.sessionID && $0.phase == value.phase }), existing.id != value.id {
                errorMessage = "This question already has an answer. Edit the saved answer instead."
                return false
            }
            guard saveTracking(value, id: value.id, category: "recovery") else { return false }
            recoveryRecords.removeAll { $0.id == value.id }
            recoveryRecords.append(value)
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    private func saveTracking<T: Encodable>(_ value: T, id: UUID, category: String) -> Bool {
        do {
            let data = try JSONEncoder().encode(value)
            if let row = try context.fetch(FetchDescriptor<TrackingRecord>()).first(where: { $0.id == id }) {
                guard row.category == category else { throw StorageError.ambiguousWorkspace }
                row.payload = data
            } else {
                context.insert(TrackingRecord(id: id, category: category, payload: data))
            }
            try commit(context)
            if pendingWorkoutSave == nil { errorMessage = nil }
            return true
        } catch {
            context.rollback()
            record = nil
            workoutRows = [:]
            errorMessage = "This entry was not saved. Keep the form open and retry. \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func saveDraft() -> Bool {
        guard !requiresWorkspaceReload else { return false }
        do {
            try writeSnapshot(activeRevisionID: activeRevisionID)
            try commit(context)
            if pendingWorkoutSave == nil { errorMessage = nil }
            return true
        } catch {
            context.rollback()
            // A failed insertion is removed by rollback; fetch afresh on the next save.
            record = nil
            errorMessage = "Your latest changes could not be saved. Keep the app open and try again. \(error.localizedDescription)"
            return false
        }
    }

    func retryLastSave() {
        if let pendingWorkoutSave {
            if persistWorkout(pendingWorkoutSave) && !pendingWorkoutSave.state.isTerminal {
                presentWorkout(pendingWorkoutSave)
            }
            bridge.retry()
        } else {
            saveDraft()
        }
    }

    func generatePrompt() {
        guard profile.canGeneratePrompt else {
            errorMessage = "Complete the training brief first: \(profile.missingEssentials.joined(separator: ", "))."
            return
        }
        if !promptDraft.isEmpty {
            previousPrompts.append(PromptSnapshot(createdAt: Date(), text: promptDraft, templateVersion: promptTemplateVersion))
        }
        promptDraft = PromptBuilder.build(profile: profile)
        promptProfile = profile
        promptTemplateVersion = PromptBuilder.templateVersion
        saveDraft()
    }

    func inspectImport() {
        if let reviewedSource, reviewedSource != importText,
           !reviewedSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context.insert(PlanDraftHistoryRecord(sourceText: reviewedSource))
        }
        importResult = PlanImporter.importText(importText)
        reviewedSource = importText
        saveDraft()
    }

    func loadExample() {
        if importText != reviewedSource { archiveCurrentDraft() }
        importText = PlanContract.exampleJSON
        inspectImport()
    }

    @discardableResult
    func replaceImportedPlan(_ plan: WeeklyPlan) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let source = String(decoding: try encoder.encode(plan), as: UTF8.self)
            let result = PlanImporter.importText(source)
            guard result.canActivate else {
                errorMessage = result.issues.map(\.message).joined(separator: "\n")
                return false
            }
            let priorSource = importText
            let priorReview = reviewedSource
            let priorResult = importResult
            archiveCurrentDraft()
            importText = source
            reviewedSource = source
            importResult = result
            if saveDraft() { return true }
            importText = priorSource
            reviewedSource = priorReview
            importResult = priorResult
            return false
        } catch {
            errorMessage = "The edited plan could not be encoded: \(error.localizedDescription)"
            return false
        }
    }

    private func archiveCurrentDraft() {
        if !importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context.insert(PlanDraftHistoryRecord(sourceText: importText))
        }
    }

    func copyCorrectionPrompt() -> String {
        let result = PlanImporter.importText(importText)
        return PromptBuilder.correctionPrompt(issues: result.issues, response: importText)
    }

    @discardableResult
    func activatePlan(_ plan: WeeklyPlan, startDate: Date, decision: PlanImportDecision? = nil) -> Bool {
        let current = PlanImporter.importText(importText)
        guard reviewedSource == importText, current.canActivate, current.plan == plan else {
            importResult = current
            errorMessage = "The response changed after review. Validate and review it again before activation."
            return false
        }
        let startDate = Calendar.current.startOfDay(for: startDate)
        do {
            let review = try reviewPlanImport(plan)
            if let decision {
                guard decision.review == review else { throw PlanRevisionReviewError.changed }
                if decision.action == .keepExisting { errorMessage = nil; return true }
            } else if review.requiresChoice { throw PlanRevisionReviewError.choiceRequired }
            guard startDate >= Calendar.current.startOfDay(for: Date()) else {
                errorMessage = "Choose today or a future start date."
                return false
            }
            var activatedPlan = plan
            var sourceText = importText
            if let decision, decision.action == .independentCopy {
                guard review.canMakeIndependentCopy, let copyID = decision.copyPlanID,
                      !(try savedPlanRevisions()).contains(where: { $0.plan.id == copyID }) else { throw PlanRevisionReviewError.copyUnavailable }
                activatedPlan.id = copyID
                let encoded = try JSONEncoder().encode(activatedPlan)
                sourceText = String(decoding: encoded, as: UTF8.self)
                guard PlanImporter.importText(sourceText).canActivate else { throw PlanRevisionReviewError.copyUnavailable }
                // Keep the received source as well as the normalized independent prescription.
                archiveCurrentDraft()
            }
            let data = try JSONEncoder().encode(activatedPlan)
            let revision = ActivatedPlanRecord(sequence: planRevision + 1, activationDate: startDate,
                                               planData: data, sourceText: sourceText)
            context.insert(revision)
            if let activeRevisionID {
                try progression.stageEnrollmentCarryForward(from: activeRevisionID, to: revision.id, plan: activatedPlan, in: context)
            }
            try writeSnapshot(activeRevisionID: revision.id)
            try commit(context)
            activeRevisionID = revision.id
            planRevision = revision.sequence
            activePlan = activatedPlan
            activationDate = startDate
            publishActivePlan()
            refreshProgressionAfterCommit()
            return true
        } catch {
            context.rollback()
            record = nil
            errorMessage = "The plan was not activated. Your existing schedule is unchanged. \(error.localizedDescription)"
            return false
        }
    }

    func upcomingSessions(from date: Date, limit: Int) -> [ScheduledPlanSession] {
        guard let activePlan, let activationDate else { return [] }
        do {
            return try scheduleExceptions.upcoming(plan: activePlan, activationDate: activationDate,
                from: date, limit: limit, workouts: workoutsForScheduling)
        } catch { return [] }
    }

    func publishScheduleChanges() { publishActivePlan() }

    private func canStartScheduledOccurrence(_ id: String, session: PlanSession, expectedDate: Date?, at date: Date) -> Bool {
        guard let activePlan, let activationDate else { return false }
        do {
            guard let occurrence = try ScheduleExceptionSchedule.resolve(occurrenceID: id, plan: activePlan,
                activationDate: activationDate, exceptions: scheduleExceptions.exceptions, workouts: workoutsForScheduling, asOf: date),
                  occurrence.canStart, occurrence.scheduled.session == session,
                  expectedDate.map({ Calendar.current.isDate($0, inSameDayAs: occurrence.scheduled.date) }) ?? true else {
                errorMessage = "This scheduled session is no longer available to start. Review its latest date and status in the calendar."
                return false
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func publishActivePlan() {
        if let activePlan, let activationDate, let activeRevisionID {
            bridge.publish(plan: activePlan, activationDate: activationDate, revision: planRevision,
                           syncGeneration: syncGeneration, planRevisionID: activeRevisionID,
                           scheduleExceptions: scheduleExceptions.exceptions.filter { $0.planID == activePlan.id },
                           recentWorkouts: includedWorkouts, recordedWorkouts: workouts)
        }
    }

    private func refreshProgressionAfterCommit() {
        do {
            try progression.reload()
            errorMessage = nil
        } catch {
            errorMessage = "Your plan was saved. Progression information could not be refreshed; reopen the app before accepting another target. \(error.localizedDescription)"
        }
    }

    private func writeSnapshot(activeRevisionID: String?) throws {
        let snapshot = WorkspaceSnapshot(profile: profile, onboardingStep: onboardingStep,
                                         promptDraft: promptDraft, promptProfile: promptProfile,
                                         promptTemplateVersion: promptTemplateVersion,
                                         previousPrompts: previousPrompts, importText: importText,
                                         reviewedSource: reviewedSource, activeRevisionID: activeRevisionID)
        let data = try JSONEncoder().encode(snapshot)
        if record == nil { record = try context.fetch(FetchDescriptor<WorkspaceRecord>()).first }
        if let record {
            record.payload = data
        } else {
            let newRecord = WorkspaceRecord(payload: data)
            context.insert(newRecord)
            record = newRecord
        }
    }

    enum StorageError: LocalizedError {
        case ambiguousWorkspace, unsupportedVersion, missingActivePlan
        var errorDescription: String? {
            switch self {
            case .ambiguousWorkspace: "More than one workspace was found. Existing data has been preserved."
            case .unsupportedVersion: "This saved workspace needs a newer version of Form / Flow."
            case .missingActivePlan: "The active plan could not be found. Existing data has been preserved."
            }
        }
    }
}
