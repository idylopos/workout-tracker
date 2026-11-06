import Foundation

public struct RemoteWorkoutStartIntent: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let syncGeneration: String
    public let planID: String
    public let planRevisionID: String
    public let prescriptionID: String
    public let scheduledSessionID: String?
    public let scheduledDay: LocalTrainingDay?
    public let requestedAt: Date
    public let expiresAt: Date
    public let recordWithHealth: Bool
    public init(id: UUID = UUID(), syncGeneration: String, planID: String, planRevisionID: String,
                prescriptionID: String, scheduledSessionID: String? = nil, scheduledDay: LocalTrainingDay? = nil, requestedAt: Date = Date(),
                expiresAt: Date? = nil, recordWithHealth: Bool = false) {
        self.id = id; self.syncGeneration = syncGeneration; self.planID = planID
        self.planRevisionID = planRevisionID; self.prescriptionID = prescriptionID
        self.scheduledSessionID = scheduledSessionID; self.scheduledDay = scheduledDay; self.requestedAt = requestedAt
        self.expiresAt = expiresAt ?? requestedAt.addingTimeInterval(60); self.recordWithHealth = recordWithHealth
    }
}
public enum RemoteWorkoutStartStatus: String, Codable, Sendable { case started, existing, rejected, pending }
public struct RemoteWorkoutStartResult: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { intent.id }
    public let intent: RemoteWorkoutStartIntent
    public let status: RemoteWorkoutStartStatus
    public let workout: WorkoutSession?
    public let message: String
    public let resolvedAt: Date
    public var isDefinitive: Bool { status != .pending }
    public init(intent: RemoteWorkoutStartIntent, status: RemoteWorkoutStartStatus, workout: WorkoutSession? = nil,
                message: String, resolvedAt: Date) {
        self.intent = intent; self.status = status; self.workout = workout; self.message = message; self.resolvedAt = resolvedAt
    }
}
public struct WorkoutProposalResult: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { operation.id }
    public let operation: WorkoutOperation
    public let status: WorkoutReductionStatus
    public let workout: WorkoutSession?
    public let issues: [WorkoutIssue]
    public init(operation: WorkoutOperation, status: WorkoutReductionStatus, workout: WorkoutSession?, issues: [WorkoutIssue]) {
        self.operation = operation; self.status = status; self.workout = workout; self.issues = issues
    }
}

/// Transport receipts only clear an intent after its owner result matches the exact request.
public enum RemoteWorkoutResultValidator {
    public static func validate(_ result: WorkoutProposalResult) -> [WorkoutIssue] {
        func invalid(_ message: String) -> [WorkoutIssue] { [.init(code: "proposalResultMismatch", message: message)] }
        guard let workout = result.workout else {
            return result.status == .rejected && !result.issues.isEmpty ? [] : invalid("The owner result has no supporting workout.")
        }
        let shape = WorkoutSessionValidator.validate(workout)
        guard shape.isEmpty else { return shape }
        guard workout.id == result.operation.sessionID, workout.syncGeneration == result.operation.syncGeneration,
              workout.ownerDeviceID != result.operation.originDeviceID else {
            return invalid("The result belongs to a different workout, workspace or recording owner.")
        }
        let receipt = workout.operationReceipts.first { $0.operation == result.operation }
        let buffered = workout.pendingOperations.contains(result.operation)
        switch result.status {
        case .applied:
            guard receipt?.status == .applied else { return invalid("The accepted change has no matching owner receipt.") }
        case .conflict:
            guard receipt?.status == .conflict,
                  workout.conflicts.contains(where: { $0.operation == result.operation }) else {
                return invalid("The conflicting change has no matching retained conflict.")
            }
        case .buffered, .duplicate:
            guard buffered || receipt != nil else { return invalid("The owner has not retained or resolved this change.") }
        case .rejected:
            guard !result.issues.isEmpty, !buffered, receipt == nil || receipt?.status == .rejected else {
                return invalid("The rejection disagrees with the owner's stored result.")
            }
        }
        return []
    }

    public static func validate(_ result: RemoteWorkoutStartResult) -> [WorkoutIssue] {
        func invalid(_ message: String) -> [WorkoutIssue] { [.init(code: "startResultMismatch", message: message)] }
        guard result.resolvedAt.timeIntervalSinceReferenceDate.isFinite else { return invalid("The owner result has an invalid date.") }
        if let workout = result.workout {
            let shape = WorkoutSessionValidator.validate(workout)
            guard shape.isEmpty else { return shape }
            guard workout.syncGeneration == result.intent.syncGeneration else { return invalid("The returned workout belongs to another workspace.") }
        }
        switch result.status {
        case .started, .existing:
            guard let workout = result.workout, workout.planID == result.intent.planID,
                  workout.planRevisionID == result.intent.planRevisionID,
                  workout.prescription.id == result.intent.prescriptionID,
                  workout.scheduledSessionID == result.intent.scheduledSessionID else {
                return invalid("The returned workout does not match the requested plan and session.")
            }
        case .pending:
            guard result.workout == nil else { return invalid("An uncertain start cannot confirm a workout.") }
        case .rejected: break // Busy-owner rejections may include that owner's different current workout.
        }
        return []
    }
}

public enum WorkoutSnapshotMergeDecision: String, Sendable {
    case identical, newer, older, auditExtension, staleAudit, conflict
}

/// Accepted changes advance `revision`; rejected and buffered proposals only extend the audit.
/// Call after validating the snapshot and authenticating its owner and workspace generation.
public enum WorkoutSnapshotMerge {
    public static func classify(incoming: WorkoutSession, existing: WorkoutSession) -> WorkoutSnapshotMergeDecision {
        if incoming == existing { return .identical }
        guard incoming.id == existing.id, incoming.planID == existing.planID,
              incoming.planRevisionID == existing.planRevisionID,
              incoming.scheduledSessionID == existing.scheduledSessionID,
              incoming.prescription == existing.prescription,
              incoming.ownerDeviceID == existing.ownerDeviceID,
              incoming.syncGeneration == existing.syncGeneration,
              incoming.timeZoneIdentifier == existing.timeZoneIdentifier,
              incoming.startedAt == existing.startedAt else { return .conflict }
        if incoming.revision > existing.revision {
            return extendsAudit(incoming, existing) ? .newer : .conflict
        }
        if incoming.revision < existing.revision {
            return extendsAudit(existing, incoming) ? .older : .conflict
        }
        // Compare every accepted field, including new fields introduced by future model changes.
        var incomingAccepted = incoming, existingAccepted = existing
        incomingAccepted.pendingOperations = []; incomingAccepted.operationReceipts = []; incomingAccepted.conflicts = []
        existingAccepted.pendingOperations = []; existingAccepted.operationReceipts = []; existingAccepted.conflicts = []
        guard incomingAccepted == existingAccepted else { return .conflict }
        if extendsAudit(incoming, existing) { return .auditExtension }
        if extendsAudit(existing, incoming) { return .staleAudit }
        return .conflict
    }

    private static func extendsAudit(_ next: WorkoutSession, _ previous: WorkoutSession) -> Bool {
        guard next.operationReceipts.starts(with: previous.operationReceipts),
              next.conflicts.starts(with: previous.conflicts) else { return false }
        // A buffered operation may disappear only after its exact payload has an owner receipt.
        var retained: [WorkoutOperation] = []
        for operation in previous.pendingOperations {
            if next.pendingOperations.contains(operation) { retained.append(operation) }
            else if !next.operationReceipts.contains(where: { $0.operation == operation }) { return false }
        }
        return next.pendingOperations.starts(with: retained)
    }
}

/// Owner decisions are pure values. Persist the decision and new session together before replying.
public enum RemoteWorkoutStartResolver {
    /// A user may explicitly start a future occurrence early, but a moved/stale selection
    /// or a recorded occurrence must be reviewed again before a new intent can run.
    public static func matchesScheduledOccurrence(_ intent: RemoteWorkoutStartIntent, occurrence: ScheduleOccurrence,
                                                   occupiedIDs: Set<String> = []) -> Bool {
        guard intent.scheduledSessionID == occurrence.id, occurrence.id.hasPrefix(intent.planID + ":"),
              occurrence.canStart, !occupiedIDs.contains(occurrence.id),
              intent.prescriptionID == occurrence.scheduled.session.id,
              let selectedDay = intent.scheduledDay, (try? selectedDay.validate()) != nil else { return false }
        return selectedDay.date == occurrence.effectiveDay.date
    }

    public static func resolve(_ intent: RemoteWorkoutStartIntent, previous: RemoteWorkoutStartResult?,
        allowStart: Bool, plan: WeeklyPlan?, planRevisionID: String?, syncGeneration: String?,
        ownerDeviceID: String, workouts: [WorkoutSession], now: Date,
        timeZoneIdentifier: String = TimeZone.current.identifier) -> RemoteWorkoutStartResult {
        func result(_ status: RemoteWorkoutStartStatus, _ message: String, _ workout: WorkoutSession? = nil) -> RemoteWorkoutStartResult {
            .init(intent: intent, status: status, workout: workout, message: message, resolvedAt: now)
        }
        if let previous {
            guard previous.intent == intent else { return result(.rejected, "This start identifier was reused with different details.") }
            return previous
        }
        guard intent.requestedAt.timeIntervalSince1970.isFinite, intent.expiresAt.timeIntervalSince1970.isFinite,
              intent.expiresAt > intent.requestedAt, intent.expiresAt.timeIntervalSince(intent.requestedAt) <= 120,
              !intent.syncGeneration.isEmpty else { return result(.rejected, "The start request is malformed.") }
        if intent.scheduledSessionID != nil {
            guard let day = intent.scheduledDay, (try? day.validate()) != nil else {
                return result(.rejected, "The requested workout date needs review before starting on Watch.")
            }
        }
        guard intent.syncGeneration == syncGeneration else { return result(.rejected, "This request belongs to an older workspace.") }
        if !allowStart {
            return now > intent.expiresAt
                ? result(.rejected, "The request expired without starting a workout on this Watch.")
                : result(.pending, "The Watch has not confirmed this request. Keep it pending and check again.")
        }
        guard now <= intent.expiresAt, now >= intent.requestedAt.addingTimeInterval(-120) else {
            return result(.rejected, "The start request expired. No new workout was started.")
        }
        guard let plan, plan.id == intent.planID, planRevisionID == intent.planRevisionID,
              let prescription = plan.days.flatMap(\.sessions).first(where: { $0.id == intent.prescriptionID }) else {
            return result(.rejected, "The Watch needs the matching activated plan before starting.")
        }
        let current = workouts.filter { $0.syncGeneration == syncGeneration && $0.ownerDeviceID == ownerDeviceID }
        if let scheduled = intent.scheduledSessionID,
           let existing = current.first(where: { $0.scheduledSessionID == scheduled && $0.state != .abandoned }) {
            guard existing.planID == intent.planID, existing.planRevisionID == intent.planRevisionID,
                  existing.prescription.id == intent.prescriptionID else {
                return result(.rejected, "This scheduled workout already exists from a different plan revision. Review it before starting separately.", existing)
            }
            return result(.existing, "This scheduled workout already exists on Watch.", existing)
        }
        if let active = current.first(where: { !$0.state.isTerminal }) {
            return result(.rejected, "Finish or resume the Watch's current workout before starting another.", active)
        }
        do {
            let workout = try WorkoutSession.start(prescription: prescription, planID: plan.id,
                planRevisionID: intent.planRevisionID, scheduledSessionID: intent.scheduledSessionID,
                ownerDeviceID: ownerDeviceID, at: now, timeZoneIdentifier: timeZoneIdentifier,
                syncGeneration: intent.syncGeneration)
            return result(.started, "Workout started on Watch.", workout)
        } catch { return result(.rejected, "The Watch could not create this workout.") }
    }
}
