import Foundation
import Observation
import SwiftData
import FormFlowCore

struct WorkoutAnnotation: Codable, Identifiable, Equatable {
    enum Decision: String, Codable { case duplicate, included, ownerUnavailable, ownerAvailable }
    let id: UUID
    let sessionID: UUID
    let sessionGeneration: String
    let ownerDeviceID: String
    let ownerRevision: Int
    let workspaceGeneration: String
    let reviewerDeviceID: String
    let recordedAt: Date
    let decision: Decision
    let duplicateOfID: UUID?
}

enum WorkoutInterruptionState: Equatable {
    case none, ownerUnavailable, ownerUpdated
}

/// Local review metadata never finishes a remote workout or creates a Health export.
@MainActor @Observable
final class WorkoutAnnotationStore {
    private var changeCount = 0
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let commit: (ModelContext) throws -> Void

    init(context: ModelContext, commit: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.context = context; self.commit = commit
    }

    func isExcludedDuplicate(_ workout: WorkoutSession) -> Bool {
        _ = changeCount
        guard workout.state.isTerminal, let saved = try? savedWorkouts(), saved.contains(where: { $0.id == workout.id }) else { return false }
        return !includedWorkouts(saved).contains { $0.id == workout.id }
    }

    /// One archive scan for charts/progression regardless of the number of workouts.
    func includedWorkouts(_ workouts: [WorkoutSession]) -> [WorkoutSession] {
        _ = changeCount
        guard let records = try? records() else { return workouts }
        let byID = Dictionary(workouts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var latest: [UUID: WorkoutAnnotation] = [:]
        for record in records {
            guard (try? Self.validateBackupRecord(record)) == true, let event = try? Self.annotation(record),
                  event.decision == .duplicate || event.decision == .included,
                  let workout = byID[event.sessionID], workout.state.isTerminal,
                  workout.syncGeneration == event.sessionGeneration, workout.ownerDeviceID == event.ownerDeviceID,
                  event.ownerRevision <= workout.revision else { continue }
            if let existing = latest[event.sessionID], existing.recordedAt > event.recordedAt ||
                (existing.recordedAt == event.recordedAt && existing.id.uuidString > event.id.uuidString) { continue }
            latest[event.sessionID] = event
        }
        let excluded = Set(latest.values.compactMap { event -> UUID? in
            guard event.decision == .duplicate, let canonical = event.duplicateOfID,
                  byID[canonical]?.state.isTerminal == true, latest[canonical]?.decision != .duplicate else { return nil }
            return event.sessionID
        })
        return workouts.filter { !excluded.contains($0.id) }
    }

    func interruptionState(_ workout: WorkoutSession) -> WorkoutInterruptionState {
        _ = changeCount
        guard let identity = try? identity(), workout.ownerDeviceID != identity.deviceID,
              workout.syncGeneration == identity.syncGeneration,
              let locallyRecordedIDs = try? localAnnotationIDs(),
              let latest = try? history(workout: workout).last(where: {
                  ($0.decision == .ownerUnavailable || $0.decision == .ownerAvailable) &&
                  $0.reviewerDeviceID == identity.deviceID && $0.workspaceGeneration == identity.syncGeneration &&
                  locallyRecordedIDs.contains($0.id)
              }), latest.decision == .ownerUnavailable else { return .none }
        return workout.revision == latest.ownerRevision && !workout.state.isTerminal ? .ownerUnavailable : .ownerUpdated
    }

    func isOwnerUnavailable(_ workout: WorkoutSession) -> Bool { interruptionState(workout) == .ownerUnavailable }

    func history(workout: WorkoutSession) throws -> [WorkoutAnnotation] {
        _ = changeCount
        return try records().compactMap { record in
            guard (try? Self.validateBackupRecord(record)) == true,
                  let event = try? Self.annotation(record), event.sessionID == workout.id,
                  event.sessionGeneration == workout.syncGeneration, event.ownerDeviceID == workout.ownerDeviceID,
                  event.ownerRevision <= workout.revision else { return nil }
            return event
        }.sorted { $0.recordedAt == $1.recordedAt ? $0.id.uuidString < $1.id.uuidString : $0.recordedAt < $1.recordedAt }
    }

    func markDuplicate(workout: WorkoutSession, duplicateOf canonical: WorkoutSession, reviewer: String) throws {
        try verifyLatest(workout, reviewer: reviewer)
        guard workout.state.isTerminal, canonical.state.isTerminal, workout.id != canonical.id,
              try savedWorkout(canonical.id) == canonical, !isExcludedDuplicate(canonical) else {
            throw invalid("Choose a different saved terminal workout that is included in your totals.")
        }
        for other in try savedWorkouts() where other.id != workout.id && isExcludedDuplicate(other) {
            if try history(workout: other).last(where: { $0.decision == .duplicate || $0.decision == .included })?.duplicateOfID == workout.id {
                throw invalid("Another duplicate points to this workout. Restore that duplicate to totals before changing its reference.")
            }
        }
        try save(.duplicate, workout: workout, reviewer: reviewer, duplicateOf: canonical.id)
    }

    func restoreIncluded(workout: WorkoutSession, reviewer: String) throws {
        try verifyLatest(workout, reviewer: reviewer)
        guard workout.state.isTerminal else { throw invalid("Only terminal workouts can be reviewed for totals.") }
        try save(.included, workout: workout, reviewer: reviewer)
    }

    func markOwnerUnavailable(workout: WorkoutSession, reviewer: String) throws {
        try verifyLatest(workout, reviewer: reviewer)
        guard !workout.state.isTerminal, workout.ownerDeviceID != reviewer,
              workout.syncGeneration == (try identity()).syncGeneration else {
            throw invalid("Only a current workout on an unavailable recording device can be marked interrupted here.")
        }
        try save(.ownerUnavailable, workout: workout, reviewer: reviewer)
    }

    func clearOwnerUnavailable(workout: WorkoutSession, reviewer: String) throws {
        try verifyLatest(workout, reviewer: reviewer)
        try save(.ownerAvailable, workout: workout, reviewer: reviewer)
    }

    static func validateBackupRecord(_ record: BackupRecord) throws -> Bool {
        guard record.payload["nativeWorkoutAnnotationVersion"] != nil else { return false }
        guard record.category == .workouts, record.payload["nativeWorkoutAnnotationVersion"] == .number(1) else {
            throw BackupError.invalid("Unsupported workout annotation version or category.")
        }
        let event = try annotation(record)
        let references = references(for: event)
        let expected = BackupRecord(id: "annotation:\(event.id)", category: .workouts,
            payload: .object(["nativeWorkoutAnnotationVersion": .number(1), "annotation": try .encode(event)]),
            references: references)
        guard record == expected, event.ownerRevision >= 0, event.recordedAt.timeIntervalSinceReferenceDate.isFinite,
              [event.sessionGeneration, event.workspaceGeneration, event.ownerDeviceID, event.reviewerDeviceID]
                .allSatisfy({ !$0.isEmpty && $0.count <= 200 }),
              event.duplicateOfID != event.sessionID,
              (event.decision == .duplicate) == (event.duplicateOfID != nil) else {
            throw BackupError.invalid("A workout annotation has inconsistent identity, references or decision data.")
        }
        return true
    }

    static func validateBackupRelationships(records: [BackupRecord]) throws {
        var workouts: [UUID: WorkoutSession] = [:]
        for record in records where record.category == .workouts && record.payload["nativeType"] == .string("workout") {
            if let payload = record.payload["value"] {
                let workout = try payload.decode(WorkoutSession.self)
                guard record.id == workout.id.uuidString, WorkoutSessionValidator.validate(workout).isEmpty else {
                    throw BackupError.invalid("An annotation references an invalid native workout.")
                }
                workouts[workout.id] = workout
            }
        }
        var latest: [UUID: WorkoutAnnotation] = [:]
        for record in records where try validateBackupRecord(record) {
            let event = try annotation(record)
            guard let workout = workouts[event.sessionID], workout.syncGeneration == event.sessionGeneration,
                  workout.ownerDeviceID == event.ownerDeviceID, event.ownerRevision <= workout.revision else {
                throw BackupError.invalid("A workout annotation does not match its original workout.")
            }
            if event.decision == .duplicate || event.decision == .included {
                guard workout.state.isTerminal else { throw BackupError.invalid("An unfinished workout cannot be classified as a duplicate.") }
                if let otherID = event.duplicateOfID, workouts[otherID]?.state.isTerminal != true {
                    throw BackupError.invalid("A duplicate annotation needs its original terminal workout.")
                }
                if latest[event.sessionID].map({ $0.recordedAt < event.recordedAt || ($0.recordedAt == event.recordedAt && $0.id.uuidString < event.id.uuidString) }) ?? true {
                    latest[event.sessionID] = event
                }
            }
        }
        for event in latest.values where event.decision == .duplicate {
            if let canonical = event.duplicateOfID, latest[canonical]?.decision == .duplicate {
                throw BackupError.invalid("Duplicate annotations cannot form a chain or cycle. Choose one included original workout.")
            }
        }
    }

    private static func annotation(_ record: BackupRecord) throws -> WorkoutAnnotation {
        guard let payload = record.payload["annotation"] else { throw BackupError.invalid("The workout annotation is missing.") }
        return try payload.decode(WorkoutAnnotation.self)
    }

    private static func references(for event: WorkoutAnnotation) -> [BackupReference] {
        [.init(category: .workouts, id: event.sessionID.uuidString)] +
        (event.duplicateOfID.map { [.init(category: .workouts, id: $0.uuidString)] } ?? [])
    }

    private func records() throws -> [BackupRecord] {
        try context.fetch(FetchDescriptor<BackupArchiveRecord>()).compactMap { row in
            guard let record = try? JSONDecoder().decode(BackupRecord.self, from: row.recordData), record.key == row.key else { return nil }
            return record
        }
    }

    private func localAnnotationIDs() throws -> Set<UUID> {
        Set(try context.fetch(FetchDescriptor<BackupArchiveRecord>()).compactMap { row in
            guard row.sourceFingerprint == "local",
                  let record = try? JSONDecoder().decode(BackupRecord.self, from: row.recordData),
                  (try? Self.validateBackupRecord(record)) == true else { return nil }
            return try? Self.annotation(record).id
        })
    }

    private func savedWorkouts() throws -> [WorkoutSession] {
        try context.fetch(FetchDescriptor<WorkoutRecord>()).map { row in
            let workout = try JSONDecoder().decode(WorkoutSession.self, from: row.payload)
            guard workout.id == row.id, WorkoutSessionValidator.validate(workout).isEmpty else {
                throw invalid("A saved workout needs review before changing its annotations.")
            }
            return workout
        }
    }

    private func savedWorkout(_ id: UUID) throws -> WorkoutSession {
        guard let workout = try savedWorkouts().first(where: { $0.id == id }) else { throw invalid("This workout is no longer saved.") }
        return workout
    }

    private func identity() throws -> RuntimeIdentityRecord {
        let identities = try context.fetch(FetchDescriptor<RuntimeIdentityRecord>())
        guard identities.count == 1, let identity = identities.first else { throw invalid("The local workspace identity is unavailable.") }
        return identity
    }

    private func verifyLatest(_ workout: WorkoutSession, reviewer: String) throws {
        guard try identity().deviceID == reviewer, try savedWorkout(workout.id) == workout else {
            throw invalid("The workout changed. Review the latest saved copy before deciding.")
        }
    }

    private func save(_ decision: WorkoutAnnotation.Decision, workout: WorkoutSession, reviewer: String, duplicateOf: UUID? = nil) throws {
        let recordedAt = max(Date(), (try history(workout: workout).last?.recordedAt ?? .distantPast).addingTimeInterval(0.001))
        let event = WorkoutAnnotation(id: UUID(), sessionID: workout.id, sessionGeneration: workout.syncGeneration,
            ownerDeviceID: workout.ownerDeviceID, ownerRevision: workout.revision,
            workspaceGeneration: try identity().syncGeneration, reviewerDeviceID: reviewer,
            recordedAt: recordedAt, decision: decision, duplicateOfID: duplicateOf)
        let record = BackupRecord(id: "annotation:\(event.id)", category: .workouts,
            payload: .object(["nativeWorkoutAnnotationVersion": .number(1), "annotation": try .encode(event)]),
            references: Self.references(for: event))
        _ = try Self.validateBackupRecord(record)
        do {
            context.insert(BackupArchiveRecord(key: record.key, recordData: try JSONEncoder().encode(record),
                sourceFingerprint: "local", needsReview: false))
            try commit(context)
            changeCount += 1
        } catch { context.rollback(); throw error }
    }

    private func invalid(_ message: String) -> BackupError { .invalid(message) }
}
