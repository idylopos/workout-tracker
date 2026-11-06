import Foundation
import SwiftData
import FormFlowCore

struct WorkoutConflictReview: Codable, Identifiable, Equatable {
    enum Choice: String, Codable { case keptAccepted, preparedProposal }
    let id: UUID
    let sessionID: UUID
    let conflictID: String
    let syncGeneration: String
    let reviewedRevision: Int
    let reviewerDeviceID: String
    let reviewedAt: Date
    let choice: Choice
    let originalOperation: WorkoutOperation
    let replacementOperation: WorkoutOperation?
}

/// Review records supplement the owner's immutable conflict history; they never erase it.
@MainActor
final class WorkoutConflictReviewStore {
    private let context: ModelContext
    private let commit: (ModelContext) throws -> Void

    init(context: ModelContext, commit: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.context = context; self.commit = commit
    }

    func history(sessionID: UUID) throws -> [WorkoutConflictReview] {
        try context.fetch(FetchDescriptor<BackupArchiveRecord>()).compactMap { row in
            let record = try JSONDecoder().decode(BackupRecord.self, from: row.recordData)
            guard record.category == .drafts, record.payload["nativeConflictReviewVersion"] == .number(1) else { return nil }
            guard let payload = record.payload["review"] else { throw invalid("A saved conflict review is incomplete.") }
            let review = try payload.decode(WorkoutConflictReview.self)
            guard record.key == row.key, record.id == "conflict-review:\(review.id)",
                  review.reviewedRevision >= 0, review.reviewedAt.timeIntervalSinceReferenceDate.isFinite,
                  review.originalOperation.sessionID == review.sessionID,
                  review.originalOperation.syncGeneration == review.syncGeneration else {
                throw invalid("A saved conflict review needs manual inspection.")
            }
            return review.sessionID == sessionID ? review : nil
        }.sorted { $0.reviewedAt < $1.reviewedAt }
    }

    func keepAccepted(workout: WorkoutSession, conflict: WorkoutConflict, reviewer: String, at date: Date = Date()) throws {
        try verifyCurrent(workout, conflict: conflict, reviewer: reviewer)
        try save(workout: workout, conflict: conflict, reviewer: reviewer, date: date,
                 choice: .keptAccepted, replacement: nil)
    }

    /// This only prepares a new proposal. Its owner must still durably apply or reject it.
    func prepareProposed(workout: WorkoutSession, conflict: WorkoutConflict, reviewer: String,
                         values: WorkoutSetValues? = nil, at date: Date = Date()) throws -> WorkoutOperation {
        try verifyCurrent(workout, conflict: conflict, reviewer: reviewer)
        let command = try Self.reviewedCommand(conflict.operation.command, workout: workout, values: values)
        let operation = WorkoutOperation(session: workout, command: command, originDeviceID: reviewer, at: date)
        let preview = WorkoutReducer.apply(operation, to: workout, at: date)
        guard preview.status == .applied else {
            throw invalid(preview.issues.map(\.message).joined(separator: " "))
        }
        try save(workout: workout, conflict: conflict, reviewer: reviewer, date: date,
                 choice: .preparedProposal, replacement: operation)
        return operation
    }

    static func reviewedCommand(_ original: WorkoutCommand, workout: WorkoutSession,
                                values: WorkoutSetValues?) throws -> WorkoutCommand {
        switch original {
        case .logSet(let id, let proposed), .updateSet(let id, let proposed):
            guard let set = workout.exercises.flatMap(\.sets).first(where: { $0.id == id }) else {
                throw BackupError.invalid("This set no longer exists. Review the current exercise.")
            }
            if case .logSet = original, set.status == .planned, !workout.state.isTerminal {
                return .logSet(setID: id, values: values ?? proposed)
            }
            return .updateSet(setID: id, values: values ?? proposed)
        case .logInterval(let setID, let id, let proposed), .updateInterval(let setID, let id, let proposed):
            guard let interval = workout.exercises.flatMap(\.sets).first(where: { $0.id == setID })?
                .intervals?.first(where: { $0.id == id }) else {
                throw BackupError.invalid("This interval no longer exists. Review the current exercise.")
            }
            if case .logInterval = original, interval.status == .planned, !workout.state.isTerminal {
                return .logInterval(setID: setID, intervalID: id, values: values ?? proposed)
            }
            return .updateInterval(setID: setID, intervalID: id, values: values ?? proposed)
        default: return original
        }
    }

    private func verifyCurrent(_ workout: WorkoutSession, conflict: WorkoutConflict, reviewer: String) throws {
        let identities = try context.fetch(FetchDescriptor<RuntimeIdentityRecord>())
        guard identities.count == 1, identities.first?.deviceID == reviewer,
              identities.first?.syncGeneration == workout.syncGeneration,
              let row = try context.fetch(FetchDescriptor<WorkoutRecord>()).first(where: { $0.id == workout.id }),
              let latest = try? JSONDecoder().decode(WorkoutSession.self, from: row.payload),
              latest == workout, WorkoutSessionValidator.validate(latest).isEmpty,
              latest.conflicts.contains(conflict) else {
            throw invalid("The saved workout changed. Review its latest accepted values before making a new decision.")
        }
    }

    private func save(workout: WorkoutSession, conflict: WorkoutConflict, reviewer: String, date: Date,
                      choice: WorkoutConflictReview.Choice, replacement: WorkoutOperation?) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw invalid("The review date is invalid.") }
        let review = WorkoutConflictReview(id: UUID(), sessionID: workout.id, conflictID: conflict.id,
            syncGeneration: workout.syncGeneration, reviewedRevision: workout.revision,
            reviewerDeviceID: reviewer, reviewedAt: date, choice: choice,
            originalOperation: conflict.operation, replacementOperation: replacement)
        let record = BackupRecord(id: "conflict-review:\(review.id)", category: .drafts,
            payload: .object(["nativeConflictReviewVersion": .number(1), "review": try .encode(review)]))
        do {
            context.insert(BackupArchiveRecord(key: record.key, recordData: try JSONEncoder().encode(record),
                sourceFingerprint: "local", needsReview: choice == .preparedProposal))
            try commit(context)
        } catch { context.rollback(); throw error }
    }

    private func invalid(_ message: String) -> BackupError { .invalid(message) }
}

enum WorkoutProposalPresentation {
    static func status(_ result: WorkoutProposalResult, in workout: WorkoutSession) -> WorkoutReductionStatus {
        guard result.operation.sessionID == workout.id, result.operation.syncGeneration == workout.syncGeneration else {
            return .rejected
        }
        if let receipt = workout.operationReceipts.last(where: { $0.operation == result.operation }) {
            return receipt.status
        }
        if workout.pendingOperations.contains(result.operation) { return .buffered }
        // A duplicate acknowledgement alone does not say whether the original was accepted.
        if result.status == .duplicate {
            return result.workout?.operationReceipts.last(where: { $0.operation == result.operation })?.status ?? .buffered
        }
        return result.status
    }
}

extension RemoteSetDraft {
    static func usingLatestAcceptedValues(workout: WorkoutSession, setID: UUID, at date: Date = Date()) throws -> RemoteSetDraft {
        guard WorkoutSessionValidator.validate(workout).isEmpty,
              let set = workout.exercises.flatMap(\.sets).first(where: { $0.id == setID }) else {
            throw BackupError.invalid("The latest accepted workout is unavailable. Reconnect and review it before replacing this draft.")
        }
        return RemoteSetDraft(sessionID: workout.id, setID: setID, syncGeneration: workout.syncGeneration,
            baseRevision: workout.revision, markComplete: set.status == .planned && !workout.state.isTerminal,
            values: set.actual, createdAt: date)
    }
}
