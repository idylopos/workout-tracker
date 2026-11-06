import Foundation
import SwiftData
import FormFlowCore

@Model
final class WorkspaceRecord {
    @Attribute(.unique) var id: String
    var payload: Data

    init(payload: Data) {
        self.id = "workspace"
        self.payload = payload
    }
}

/// New activations append a revision; they never mutate a prior prescription.
@Model
final class ActivatedPlanRecord {
    @Attribute(.unique) var id: String
    var sequence: Int
    var createdAt: Date
    var activationDate: Date
    var planData: Data
    var sourceText: String

    init(sequence: Int, activationDate: Date, planData: Data, sourceText: String) {
        self.id = UUID().uuidString
        self.sequence = sequence
        self.createdAt = Date()
        self.activationDate = activationDate
        self.planData = planData
        self.sourceText = sourceText
    }
}

struct PromptSnapshot: Codable {
    var createdAt: Date
    var text: String
    var templateVersion: Int? = nil
}

struct RemoteSetDraft: Codable {
    var operationID = UUID()
    var sessionID: UUID
    var setID: UUID
    var syncGeneration: String
    var baseRevision: Int
    var markComplete: Bool
    var values: WorkoutSetValues
    var createdAt: Date
    static func key(sessionID: UUID, setID: UUID) -> String { "drafts:proposed-set:\(sessionID):\(setID)" }
}

struct WorkspaceSnapshot: Codable {
    var storageVersion = 1
    var profile = TrainingProfile()
    var onboardingStep = 0
    var promptDraft = ""
    var promptProfile: TrainingProfile?
    var promptTemplateVersion: Int? = nil
    var previousPrompts: [PromptSnapshot] = []
    var importText = ""
    var reviewedSource: String?
    var activeRevisionID: String?
}

@Model
final class PlanDraftHistoryRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var sourceText: String

    init(sourceText: String) {
        id = UUID()
        createdAt = Date()
        self.sourceText = sourceText
    }
}

@Model
final class WorkoutRecord {
    @Attribute(.unique) var id: UUID
    var payload: Data
    var updatedAt: Date

    init(id: UUID, payload: Data) {
        self.id = id
        self.payload = payload
        updatedAt = Date()
    }
}

@Model
final class RuntimeIdentityRecord {
    @Attribute(.unique) var id: String
    var deviceID: String
    var syncGeneration: String

    init() {
        id = "identity"
        deviceID = UUID().uuidString
        syncGeneration = UUID().uuidString
    }
}

@Model
final class TrackingRecord {
    @Attribute(.unique) var id: UUID
    var category: String
    var payload: Data

    init(id: UUID, category: String, payload: Data) {
        self.id = id
        self.category = category
        self.payload = payload
    }
}

enum WorkspaceSchema {
    static var current: Schema {
        Schema(versionedSchema: WorkspaceSchemaV1.self)
    }
}

/// Freeze this model set when introducing a new schema; add a version and migration stage.
enum WorkspaceSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [WorkspaceRecord.self, ActivatedPlanRecord.self, PlanDraftHistoryRecord.self,
                WorkoutRecord.self, RuntimeIdentityRecord.self, TrackingRecord.self,
                BackupArchiveRecord.self, BackupProvenanceRecord.self, ProgressionRecord.self,
                ScheduleExceptionRecord.self]
    }
}

enum WorkspaceMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [WorkspaceSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
