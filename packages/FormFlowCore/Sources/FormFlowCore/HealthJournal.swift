import Foundation

/// A local, single-writer ledger. Persist a returned mutation before performing its external action.
/// A missing Health query result never proves that a previous write failed: read access is opaque.
public struct HealthJournal: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public private(set) var entries: [HealthExportEntry]

    public init() { version = Self.currentVersion; entries = [] }

    public func entry(workoutID: UUID, generation: String) -> HealthExportEntry? {
        entries.first { $0.workoutID == workoutID && $0.syncGeneration == generation }
    }

    @discardableResult
    public mutating func prepare(workoutID: UUID, generation: String, ownerDeviceID: String,
                                 localDeviceID: String, at date: Date) throws -> HealthExportEntry {
        guard version == Self.currentVersion, !generation.isEmpty, !localDeviceID.isEmpty,
              ownerDeviceID == localDeviceID, date.timeIntervalSinceReferenceDate.isFinite else {
            throw HealthJournalError.invalidIdentity
        }
        if let existing = entry(workoutID: workoutID, generation: generation) {
            guard existing.ownerDeviceID == localDeviceID else { throw HealthJournalError.wrongOwner }
            guard existing.state == .failedBeforeSave else { throw HealthJournalError.alreadyPrepared }
            try transition(workoutID: workoutID, generation: generation, localDeviceID: localDeviceID,
                           to: .prepared, at: date)
            guard let updated = entry(workoutID: workoutID, generation: generation) else { throw HealthJournalError.invalidIdentity }
            return updated
        }
        let result = HealthExportEntry(workoutID: workoutID, syncGeneration: generation,
            ownerDeviceID: localDeviceID, correlationID: UUID(), state: .prepared,
            createdAt: date, updatedAt: date, healthWorkoutID: nil, message: nil)
        entries.append(result)
        return result
    }

    public mutating func transition(workoutID: UUID, generation: String, localDeviceID: String,
                                    to next: HealthExportState, at date: Date,
                                    healthWorkoutID: UUID? = nil, message: String? = nil) throws {
        guard version == Self.currentVersion,
              let index = entries.firstIndex(where: { $0.workoutID == workoutID && $0.syncGeneration == generation }) else {
            throw HealthJournalError.invalidIdentity
        }
        var entry = entries[index]
        guard entry.ownerDeviceID == localDeviceID else { throw HealthJournalError.wrongOwner }
        guard date.timeIntervalSinceReferenceDate.isFinite, date >= entry.updatedAt else { throw HealthJournalError.invalidDate }
        let allowed: Set<HealthExportState>
        switch entry.state {
        case .prepared: allowed = [.recording, .failedBeforeSave, .discarded]
        case .recording: allowed = [.saving, .failedBeforeSave, .discarded]
        case .failedBeforeSave: allowed = [.prepared, .discarded]
        case .saving: allowed = [.saved, .pendingVerification]
        case .pendingVerification: allowed = [.saved, .pendingVerification]
        case .saved, .discarded: allowed = []
        }
        guard allowed.contains(next), (next == .saved) == (healthWorkoutID != nil) else { throw HealthJournalError.invalidTransition }
        entry.state = next; entry.updatedAt = date; entry.healthWorkoutID = healthWorkoutID; entry.message = message
        entries[index] = entry
    }

    /// An empty query remains unresolved; a positive matching UUID is the only successful reconciliation.
    public mutating func reconcile(workoutID: UUID, generation: String, localDeviceID: String,
                                   matches: [UUID], at date: Date) throws {
        let unique = Set(matches)
        try transition(workoutID: workoutID, generation: generation, localDeviceID: localDeviceID,
            to: unique.count == 1 ? .saved : .pendingVerification, at: date,
            healthWorkoutID: unique.count == 1 ? unique.first : nil,
            message: unique.isEmpty ? "Health save cannot be verified. No automatic retry will be made." :
                (unique.count > 1 ? "More than one Health workout matches. Review the records in Health." : nil))
    }

    public func validate() -> Bool {
        guard version == Self.currentVersion,
              Set(entries.map { "\($0.syncGeneration):\($0.workoutID)" }).count == entries.count,
              Set(entries.map(\.correlationID)).count == entries.count else { return false }
        return entries.allSatisfy {
            !$0.ownerDeviceID.isEmpty && !$0.syncGeneration.isEmpty &&
            $0.createdAt.timeIntervalSinceReferenceDate.isFinite && $0.updatedAt.timeIntervalSinceReferenceDate.isFinite &&
            $0.updatedAt >= $0.createdAt && (($0.state == .saved) == ($0.healthWorkoutID != nil))
        }
    }
}

public enum HealthExportState: String, Codable, Sendable {
    case prepared, recording, failedBeforeSave, saving, pendingVerification, saved, discarded
}

public struct HealthExportEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { correlationID }
    public let workoutID: UUID
    public let syncGeneration: String
    public let ownerDeviceID: String
    public let correlationID: UUID
    public fileprivate(set) var state: HealthExportState
    public let createdAt: Date
    public fileprivate(set) var updatedAt: Date
    public fileprivate(set) var healthWorkoutID: UUID?
    public fileprivate(set) var message: String?
}

public enum HealthJournalError: Error, Equatable, Sendable {
    case invalidIdentity, wrongOwner, invalidDate, alreadyPrepared, invalidTransition
}
