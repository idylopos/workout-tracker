import Foundation
import Observation
import FormFlowCore
import WatchConnectivity
import CryptoKit

/// One transport delegate for plans, workspace generations, and durable owner snapshots.
@MainActor @Observable
final class PlanBridge: NSObject {
    private var transportStatus = "Connecting to Apple Watch…"
    private(set) var compatibilityMessage: String?
    var status: String { compatibilityMessage ?? transportStatus }
    private(set) var receivedPlan: WeeklyPlan?
    private(set) var receivedActivationDate: Date?
    private(set) var receivedPlanRevision: String?
    private(set) var receivedSyncGeneration: String?
    private(set) var receivedScheduleExceptions: [ScheduleException] = []
    private(set) var receivedHistoryBaseline = WatchHistoryBaseline.empty
    private(set) var receivedRecordedOccurrences: [RecordedScheduleOccurrence] = []
    private(set) var workoutStatuses: [UUID: String] = [:]
    private var connectionRevision = 0
    var canRequestWatchStart: Bool {
        _ = connectionRevision
        #if os(iOS)
        guard storageCompatible, let session else { return false }
        return session.activationState == .activated && session.isPaired && session.isWatchAppInstalled && session.isReachable
        #else
        return false
        #endif
    }
    var remoteStartIntents: [RemoteWorkoutStartIntent] {
        remote.starts.values.filter { $0.syncGeneration == generation?.value }.sorted { $0.requestedAt < $1.requestedAt }
    }
    var pendingWorkoutProposals: [WorkoutOperation] {
        remote.proposals.values.filter { $0.syncGeneration == generation?.value }.sorted { $0.createdAt < $1.createdAt }
    }
    var workoutProposalResults: [WorkoutProposalResult] {
        remote.proposalResults.values.map(\.result).filter { $0.operation.syncGeneration == generation?.value }
            .sorted { $0.operation.createdAt > $1.operation.createdAt }
    }
    @ObservationIgnored var onWorkoutReceived: ((WorkoutSession) -> Bool)? {
        didSet { drainWorkoutInbox() }
    }
    @ObservationIgnored var onRemoteStartResult: ((RemoteWorkoutStartResult) -> Bool)? { didSet { drainRemoteInbox() } }
    @ObservationIgnored var onWorkoutProposalResult: ((WorkoutProposalResult) -> Bool)? { didSet { drainRemoteInbox() } }
    @ObservationIgnored var onRemoteStartRequested: ((RemoteWorkoutStartIntent, Bool) -> RemoteWorkoutStartResult?)?
    @ObservationIgnored var onWorkoutProposalReceived: ((WorkoutOperation) -> WorkoutProposalResult?)? { didSet { drainProposals() } }
    private var remote = RemoteBridgeState()
    @ObservationIgnored private var pending: PlanEnvelope?
    @ObservationIgnored private var accepted: PlanEnvelope?
    @ObservationIgnored private var waitingPlan: PlanEnvelope?
    private var generation: BridgeGeneration?
    @ObservationIgnored private var outbox = WorkoutMailbox()
    @ObservationIgnored private var inbox: [UUID: WorkoutEnvelope] = [:]
    @ObservationIgnored private var resetCleanupPending = false
    @ObservationIgnored private var storageCompatible = true
    @ObservationIgnored private var drainingWorkoutInbox = false
    @ObservationIgnored private var drainingRemoteInbox = false
    @ObservationIgnored private let session: WCSession?
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()

    init(isEnabled: Bool = true) {
        session = isEnabled && WCSession.isSupported() ? .default : nil
        super.init()
        guard isEnabled else { transportStatus = "Watch transfer is disabled."; return }
        restore()
        guard let session else { transportStatus = "Apple Watch connection is unavailable."; return }
        session.delegate = self
        session.activate()
    }

    /// Call even when there is no active plan, especially after local deletion/reset.
    func configureSyncGeneration(_ value: String) {
        #if os(iOS)
        guard session != nil, !value.isEmpty else { return }
        do {
            if generation?.value != value {
                var retired = generation?.retired ?? []
                if let old = generation?.value { retired.insert(old) }
                let changed = max(Date(), (generation?.changedAt ?? .distantPast).addingTimeInterval(0.001))
                let next = BridgeGeneration(value: value, changedAt: changed, retired: retired)
                // A marker makes interrupted deletion retryable even after the new generation is saved.
                try write(value, "purge-pending.json")
                resetCleanupPending = true
                try write(next, "generation.json")
                generation = next
                transportStatus = "Waiting for a plan in this workspace."
            }
            if resetCleanupPending { try purgePhonePayloads() }
            sendGeneration()
            drainWorkoutInbox()
            drainRemoteInbox()
        } catch { transportStatus = "Couldn’t persist Watch workspace: \(error.localizedDescription)" }
        #endif
    }

    /// Call after the iPhone store commits its new generation. False means cleanup needs retry.
    @discardableResult func purgeForReset(syncGeneration: String) -> Bool {
        #if os(iOS)
        guard session != nil else { return true }
        configureSyncGeneration(syncGeneration)
        return generation?.value == syncGeneration && !resetCleanupPending
        #else
        return false
        #endif
    }

    private func purgePhonePayloads() throws {
        #if os(iOS)
        for transfer in session?.outstandingFileTransfers ?? [] { transfer.cancel() }
        for transfer in session?.outstandingUserInfoTransfers ?? [] { transfer.cancel() }
        pending = nil; inbox = [:]; remote = RemoteBridgeState(); workoutStatuses = [:]; compatibilityMessage = nil
        UserDefaults.standard.removeObject(forKey: "FormFlow.acknowledgedPlanID")
        let directory = try Self.fileURL("generation.json").deletingLastPathComponent()
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where !["generation.json", "purge-pending.json"].contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
        let marker = try Self.fileURL("purge-pending.json")
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
        resetCleanupPending = false
        #endif
    }

    func publish(plan: WeeklyPlan, activationDate: Date, revision: Int,
                 syncGeneration: String, planRevisionID: String,
                 scheduleExceptions: [ScheduleException] = [], recentWorkouts: [WorkoutSession] = [],
                 recordedWorkouts: [WorkoutSession]? = nil) {
        #if os(iOS)
        guard session != nil else { return }
        configureSyncGeneration(syncGeneration)
        guard generation?.value == syncGeneration, !resetCleanupPending else { return }
        do {
            guard scheduleExceptions.count <= 10_000, Set(scheduleExceptions.map(\.id)).count == scheduleExceptions.count else {
                throw BridgeError.unsupportedFormat
            }
            for exception in scheduleExceptions { try exception.validate() }
            let baseline = try WatchHistoryBaselineBuilder.build(plan: plan, workouts: recentWorkouts, syncGeneration: syncGeneration)
            let recorded = try RecordedScheduleSnapshot.build(workouts: recordedWorkouts ?? recentWorkouts,
                planID: plan.id, syncGeneration: syncGeneration)
            if pending?.revision != revision || pending?.plan != plan || pending?.activationDate != activationDate
                || pending?.syncGeneration != syncGeneration || pending?.planRevisionID != planRevisionID
                || (pending?.scheduleExceptions ?? []) != scheduleExceptions || (pending?.historyBaseline ?? .empty) != baseline
                || (pending?.recordedOccurrences ?? []) != recorded {
                let deliveryRevision = (pending?.deliveryRevision ?? pending?.revision ?? 0) + 1
                let next = PlanEnvelope(id: UUID(), sourceID: sourceID, revision: revision, createdAt: Date(),
                    activationDate: activationDate, plan: plan, syncGeneration: syncGeneration, planRevisionID: planRevisionID,
                    deliveryRevision: deliveryRevision, scheduleExceptions: scheduleExceptions, historyBaseline: baseline,
                    recordedOccurrences: recorded)
                try write(next, "pending-plan.json")
                pending = next
            }
            enqueuePendingPlan()
        } catch { transportStatus = "Plan saved on iPhone; Watch transfer failed: \(error.localizedDescription)" }
        #endif
    }

    func publishWorkout(_ workout: WorkoutSession) {
        #if os(watchOS)
        guard session != nil else { return }
        guard workout.syncGeneration == generation?.value else {
            workoutStatuses[workout.id] = "Retained for review — older workspace"
            return
        }
        guard Self.valid(workout) else { workoutStatuses[workout.id] = "Invalid workout; retained on Watch"; return }
        do {
            var next = outbox
            if let existing = next.pending[workout.id] {
                switch WorkoutSnapshotMerge.classify(incoming: workout, existing: existing.workout) {
                case .identical: break // Retry the same durable envelope after a lost receipt.
                case .newer, .auditExtension:
                    next.pending[workout.id] = WorkoutEnvelope(id: UUID(), workout: workout)
                case .older, .staleAudit: return
                case .conflict:
                    workoutStatuses[workout.id] = "Conflicting revision; retained for review"
                    return
                }
            } else if let confirmed = next.confirmedSnapshots?[workout.id] {
                switch WorkoutSnapshotMerge.classify(incoming: workout, existing: confirmed) {
                case .identical, .older, .staleAudit:
                    workoutStatuses[workout.id] = "Saved on iPhone"
                    return
                case .newer, .auditExtension:
                    next.pending[workout.id] = WorkoutEnvelope(id: UUID(), workout: workout)
                case .conflict:
                    workoutStatuses[workout.id] = "Conflicting revision; retained for review"
                    return
                }
            } else if let confirmed = next.confirmed[workout.id], confirmed > workout.revision {
                workoutStatuses[workout.id] = "Saved on iPhone"
                return
            } else {
                // Legacy revision-only receipts cannot prove equal-revision audit delivery.
                next.pending[workout.id] = WorkoutEnvelope(id: UUID(), workout: workout)
            }
            try write(next, "workout-outbox.json")
            outbox = next
            enqueueWorkouts()
        } catch { workoutStatuses[workout.id] = "Saved on Watch; transfer could not be queued" }
        #endif
    }

    func workoutStatus(for id: UUID) -> String { workoutStatuses[id] ?? "Saved on this device" }
    func remoteStartStatus(for id: UUID) -> String {
        if let result = remote.startResults[id] { return result.message }
        return remote.starts[id] == nil ? "No start request" : "Waiting for Watch confirmation. Check the request before starting separately."
    }
    func remoteStartResult(for id: UUID) -> RemoteWorkoutStartResult? { remote.startResults[id] }
    func proposalResult(for id: UUID) -> WorkoutProposalResult? { remote.proposalResults[id]?.result }

    /// The outbox is durable before a live message is attempted. Reconnection only probes it.
    @discardableResult func requestWatchStart(_ intent: RemoteWorkoutStartIntent) -> Bool {
        #if os(iOS)
        guard storageCompatible, !resetCleanupPending, intent.syncGeneration == generation?.value, let session else { return false }
        do {
            var next = remote
            if let existing = next.starts[intent.id], existing != intent { return false }
            if let result = next.startResults[intent.id], result.isDefinitive { return result.intent == intent }
            next.starts[intent.id] = intent
            try write(next, "remote-control.json"); remote = next
            guard session.activationState == .activated, session.isReachable else { return true }
            let payload = try WorkoutTransportCodec.encode(intent, kind: .remoteStart)
            // A failed/uncertain reply never triggers another start. The user can probe this exact ID.
            session.sendMessage(["kind": "remoteStart", "payload": payload], replyHandler: { _ in }, errorHandler: { _ in })
            return true
        } catch { transportStatus = "Couldn’t save the Watch start request: \(error.localizedDescription)"; return false }
        #else
        return false
        #endif
    }
    func reconcileWatchStart(_ id: UUID) {
        #if os(iOS)
        guard let intent = remote.starts[id], intent.syncGeneration == generation?.value,
              let session, session.activationState == .activated,
              let payload = try? WorkoutTransportCodec.encode(intent, kind: .remoteStartProbe) else { return }
        guard !session.outstandingUserInfoTransfers.contains(where: { $0.userInfo["probeID"] as? String == id.uuidString }) else { return }
        session.transferUserInfo(["kind": "remoteStartProbe", "probeID": id.uuidString, "payload": payload])
        #endif
    }
    @discardableResult func proposeWorkoutChange(_ operation: WorkoutOperation) -> Bool {
        #if os(iOS)
        guard !resetCleanupPending, operation.syncGeneration == generation?.value, session != nil else { return false }
        do {
            var next = remote
            if let previous = next.proposals[operation.id], previous != operation { return false }
            next.proposals[operation.id] = operation
            try write(next, "remote-control.json"); remote = next
            enqueueRemoteTransfers(); return true
        } catch { transportStatus = "Couldn’t save the proposed Watch change: \(error.localizedDescription)"; return false }
        #else
        return false
        #endif
    }
    func retry() {
        guard storageCompatible else { return }
        #if os(iOS)
        if let generation { configureSyncGeneration(generation.value) }
        guard !resetCleanupPending else { return }
        sendGeneration(); enqueuePendingPlan(); drainWorkoutInbox()
        #else
        requestPlan(); enqueueWorkouts()
        #endif
        enqueueRemoteTransfers(); drainRemoteInbox(); drainProposals()
    }

    private func restore() {
        do {
            compatibilityMessage = try readIfPresent(String.self, "compatibility-state.json")
            generation = try readIfPresent(BridgeGeneration.self, "generation.json")
            #if os(iOS)
            resetCleanupPending = try readIfPresent(String.self, "purge-pending.json") != nil
            if resetCleanupPending { return }
            #endif
            remote = try readIfPresent(RemoteBridgeState.self, "remote-control.json") ?? RemoteBridgeState()
            #if os(watchOS)
            accepted = try readIfPresent(PlanEnvelope.self, "accepted-plan.json")
            waitingPlan = try readIfPresent(PlanEnvelope.self, "waiting-plan.json")
            outbox = try readIfPresent(WorkoutMailbox.self, "workout-outbox.json") ?? WorkoutMailbox()
            showAcceptedPlan()
            refreshWorkoutStatuses()
            #else
            pending = try readIfPresent(PlanEnvelope.self, "pending-plan.json")
            inbox = try readIfPresent([UUID: WorkoutEnvelope].self, "workout-inbox.json") ?? [:]
            #endif
        } catch {
            if let compatibility = error as? WorkoutProtocolCompatibilityError {
                storageCompatible = false
                compatibilityMessage = compatibility.localizedDescription
            } else { transportStatus = "Couldn’t read saved transfer data: \(error.localizedDescription)" }
        }
    }

    private func showAcceptedPlan() {
        receivedSyncGeneration = generation?.value
        if let accepted, accepted.syncGeneration == generation?.value {
            receivedPlan = accepted.plan; receivedActivationDate = accepted.activationDate
            receivedPlanRevision = accepted.planRevisionID
            receivedScheduleExceptions = accepted.scheduleExceptions ?? []
            receivedHistoryBaseline = accepted.historyBaseline ?? .empty
            receivedRecordedOccurrences = accepted.recordedOccurrences ?? []
            transportStatus = "Plan saved on this Watch."
        } else {
            receivedPlan = nil; receivedActivationDate = nil; receivedPlanRevision = nil
            receivedScheduleExceptions = []; receivedHistoryBaseline = .empty
            receivedRecordedOccurrences = []
            transportStatus = "Activate a plan on your iPhone."
        }
    }

    private func refreshWorkoutStatuses() {
        for (id, _) in outbox.confirmed { workoutStatuses[id] = "Saved on iPhone" }
        for (id, envelope) in outbox.pending {
            workoutStatuses[id] = envelope.workout.syncGeneration == generation?.value
                ? "Saved on Watch; awaiting iPhone" : "Retained for review — older workspace"
        }
    }

    #if os(iOS)
    private var sourceID: UUID {
        let key = "FormFlow.planSourceID"
        if let value = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: value) { return id }
        let id = UUID(); UserDefaults.standard.set(id.uuidString, forKey: key); return id
    }
    private func sendGeneration() {
        guard let session, session.activationState == .activated, let generation else { return }
        do {
            try session.updateApplicationContext(["kind": "workspaceGeneration", "generation": generation.value,
                "changedAt": generation.changedAt.timeIntervalSince1970])
        } catch { transportStatus = "Workspace update is pending: \(error.localizedDescription)" }
    }
    private func enqueuePendingPlan() {
        guard let session, session.activationState == .activated else { transportStatus = "Waiting for Apple Watch connection."; return }
        guard session.isPaired else { transportStatus = "Pair an Apple Watch to view your plan there."; return }
        guard session.isWatchAppInstalled else { transportStatus = "Install Form / Flow on your Apple Watch."; return }
        guard let pending, pending.syncGeneration == generation?.value else { transportStatus = "Activate a plan to send it to Apple Watch."; return }
        if UserDefaults.standard.string(forKey: "FormFlow.acknowledgedPlanID") == pending.id.uuidString {
            transportStatus = "Plan confirmed on Apple Watch."; return
        }
        do {
            try queue(pending, kind: "activatedPlan", id: pending.id)
            transportStatus = "Plan queued for Apple Watch."
        } catch { transportStatus = "Couldn’t queue the Watch plan: \(error.localizedDescription)" }
    }
    #endif

    private func enqueueWorkouts() {
        #if os(watchOS)
        guard let session, session.activationState == .activated else { return }
        for envelope in outbox.pending.values where envelope.workout.syncGeneration == generation?.value {
            do {
                try queue(envelope, kind: "ownerWorkout", id: envelope.id)
                workoutStatuses[envelope.workout.id] = "Saved on Watch; awaiting iPhone"
            } catch { workoutStatuses[envelope.workout.id] = "Saved on Watch; transfer pending" }
        }
        #endif
    }

    private func queue<T: Encodable>(_ value: T, kind: String, id: UUID) throws {
        guard storageCompatible else { throw BridgeError.unsupportedFormat }
        guard let session else { return }
        // A reachable peer can update its UI immediately; the durable file/outbox remains authoritative.
        let data = try WorkoutTransportKind(rawValue: kind).map { try WorkoutTransportCodec.encode(value, kind: $0) } ?? encoder.encode(value)
        guard data.count <= Self.maximumEnvelopeBytes else { throw BridgeError.tooLarge }
        if session.isReachable, data.count <= 60_000 {
            session.sendMessage(["kind": kind, "payload": data], replyHandler: { _ in }, errorHandler: { _ in })
        }
        guard !session.outstandingFileTransfers.contains(where: { $0.file.metadata?["envelopeID"] as? String == id.uuidString }) else { return }
        let name = "outgoing-\(id.uuidString).json"
        try data.write(to: Self.fileURL(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        session.transferFile(try Self.fileURL(name), metadata: ["kind": kind, "envelopeID": id.uuidString])
    }

    private func receivePlan(_ data: Data) {
        #if os(watchOS)
        do {
            try checkSnapshotVersion(data, expected: 2)
            let incoming = try decoder.decode(PlanEnvelope.self, from: data)
            guard incoming.formatVersion == 2, incoming.revision > 0,
                  !incoming.syncGeneration.isEmpty, !incoming.planRevisionID.isEmpty,
                  (incoming.deliveryRevision ?? incoming.revision) > 0,
                  WatchHistoryBaselineBuilder.validate(incoming.historyBaseline ?? .empty).isEmpty,
                  RecordedScheduleSnapshot.validate(incoming.recordedOccurrences ?? [], planID: incoming.plan.id).isEmpty else { throw BridgeError.unsupportedFormat }
            let exceptions = incoming.scheduleExceptions ?? []
            guard exceptions.count <= 10_000, Set(exceptions.map(\.id)).count == exceptions.count else { throw BridgeError.unsupportedFormat }
            for exception in exceptions { try exception.validate() }
            // Only the latest application context can change workspace identity.
            guard incoming.syncGeneration == generation?.value else {
                if generation?.retired.contains(incoming.syncGeneration) != true {
                    try write(incoming, "waiting-plan.json")
                    waitingPlan = incoming
                }
                transportStatus = "Waiting for the current iPhone workspace."
                requestPlan(); return
            }
            if let accepted, accepted.syncGeneration == incoming.syncGeneration {
                if incoming.id == accepted.id { acknowledgePlan(accepted); return }
                if incoming.sourceID == accepted.sourceID {
                    guard incoming.revision >= accepted.revision,
                          (incoming.deliveryRevision ?? incoming.revision) > (accepted.deliveryRevision ?? accepted.revision) else { return }
                } else { guard incoming.createdAt > accepted.createdAt else { return } }
            }
            try data.write(to: Self.fileURL("accepted-plan.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            accepted = incoming; showAcceptedPlan(); acknowledgePlan(incoming)
        } catch {
            if !retainUnsupported(data, kind: "activatedPlan", error: error) { transportStatus = "Couldn’t save the incoming plan: \(error.localizedDescription)" }
        }
        #endif
    }

    private func receiveGeneration(_ value: String, changedAt: Date) {
        #if os(watchOS)
        guard !value.isEmpty, value.count <= 200, changedAt.timeIntervalSince1970.isFinite else { return }
        if let generation {
            if generation.value == value { return }
            guard !generation.retired.contains(value), changedAt > generation.changedAt else { return }
        }
        do {
            var retired = generation?.retired ?? []
            if let old = generation?.value { retired.insert(old) }
            let next = BridgeGeneration(value: value, changedAt: changedAt, retired: retired)
            try write(next, "generation.json")
            generation = next; showAcceptedPlan(); refreshWorkoutStatuses()
            if let waitingPlan, waitingPlan.syncGeneration == value {
                receivePlan(try encoder.encode(waitingPlan))
            }
            // In-flight old snapshots remain on disk but cannot be acknowledged into a reset phone store.
            for transfer in session?.outstandingFileTransfers ?? [] {
                if transfer.file.metadata?["kind"] as? String == "ownerWorkout" { transfer.cancel() }
            }
            requestPlan(); enqueueWorkouts()
        } catch { transportStatus = "Couldn’t save the new workspace. Existing Watch records were retained." }
        #endif
    }

    private func receiveWorkout(_ data: Data) {
        #if os(iOS)
        do {
            try checkSnapshotVersion(data, expected: 1)
            let incoming = try decoder.decode(WorkoutEnvelope.self, from: data)
            guard incoming.formatVersion == 1, Self.valid(incoming.workout) else { throw BridgeError.unsupportedFormat }
            guard !resetCleanupPending, incoming.workout.syncGeneration == generation?.value else { return }
            // Preserve an unconfirmed delivery before the temporary transport file disappears.
            var next = inbox
            next[incoming.id] = incoming
            try write(next, "workout-inbox.json")
            inbox = next; drainWorkoutInbox()
        } catch {
            if !retainUnsupported(data, kind: "ownerWorkout", error: error) { transportStatus = "Incoming Watch workout retained by Watch; iPhone save failed: \(error.localizedDescription)" }
        }
        #endif
    }

    private func drainWorkoutInbox() {
        #if os(iOS)
        guard !drainingWorkoutInbox, let onWorkoutReceived, let generation, session?.activationState == .activated else { return }
        drainingWorkoutInbox = true
        defer { drainingWorkoutInbox = false }
        for envelope in inbox.values.sorted(by: { $0.workout.revision < $1.workout.revision }) {
            guard envelope.workout.syncGeneration == generation.value else { continue }
            guard onWorkoutReceived(envelope.workout) else { continue }
            // Callback true means the owner's snapshot (or identical/newer revision) is durably saved.
            session?.transferUserInfo(["kind": "workoutReceipt", "envelopeID": envelope.id.uuidString,
                "sessionID": envelope.workout.id.uuidString, "revision": envelope.workout.revision,
                "generation": envelope.workout.syncGeneration])
            var next = inbox; next.removeValue(forKey: envelope.id)
            do { try write(next, "workout-inbox.json"); inbox = next }
            catch { transportStatus = "Workout saved; receipt cleanup pending." }
        }
        #endif
    }

    private func receiveWorkoutReceipt(id: UUID, sessionID: UUID, revision: Int, syncGeneration: String) {
        #if os(watchOS)
        guard syncGeneration == generation?.value,
              let pending = outbox.pending[sessionID], pending.id == id,
              pending.workout.revision == revision else { return }
        do {
            var next = outbox
            next.pending.removeValue(forKey: sessionID)
            next.confirmed[sessionID] = revision
            var snapshots = next.confirmedSnapshots ?? [:]
            snapshots[sessionID] = pending.workout
            next.confirmedSnapshots = snapshots
            try write(next, "workout-outbox.json")
            outbox = next; workoutStatuses[sessionID] = "Saved on iPhone"
        } catch { workoutStatuses[sessionID] = "iPhone received workout; local confirmation pending" }
        #endif
    }

    private func enqueueRemoteTransfers() {
        guard session?.activationState == .activated else { return }
        #if os(iOS)
        for id in remote.starts.keys { reconcileWatchStart(id) }
        for proposal in remote.proposals.values where proposal.syncGeneration == generation?.value {
            try? queue(proposal, kind: "workoutProposal", id: proposal.id)
        }
        #else
        for result in remote.startReplies.values where result.intent.syncGeneration == generation?.value {
            try? queue(result, kind: "remoteStartResult", id: result.id)
        }
        for envelope in remote.proposalReplies.values where envelope.result.operation.syncGeneration == generation?.value {
            try? queue(envelope, kind: "proposalResult", id: envelope.id)
        }
        #endif
    }
    private func receiveStartRequest(_ data: Data, allowStart: Bool) {
        #if os(watchOS)
        guard storageCompatible else { return }
        do {
            let intent = try WorkoutTransportCodec.decode(RemoteWorkoutStartIntent.self, from: data, kind: allowStart ? .remoteStart : .remoteStartProbe)
            guard let result = onRemoteStartRequested?(intent, allowStart) else { return }
            if !result.isDefinitive {
                session?.transferUserInfo(["kind": "remoteStartPending", "payload": try WorkoutTransportCodec.encode(result, kind: .remoteStartResult)])
                return
            }
            var next = remote; next.startReplies[result.id] = result
            try write(next, "remote-control.json"); remote = next
            enqueueRemoteTransfers()
        } catch {
            if !retainUnsupported(data, kind: allowStart ? "remoteStart" : "remoteStartProbe", error: error) { transportStatus = "Start request could not be confirmed. Check Watch before retrying." }
        }
        #endif
    }
    private func receiveProposal(_ data: Data) {
        #if os(watchOS)
        do {
            let proposal = try WorkoutTransportCodec.decode(WorkoutOperation.self, from: data, kind: .workoutProposal)
            var next = remote
            if let previous = next.proposalInbox[proposal.id], previous != proposal { return }
            next.proposalInbox[proposal.id] = proposal
            try write(next, "remote-control.json"); remote = next
            drainProposals()
        } catch {
            if !retainUnsupported(data, kind: "workoutProposal", error: error) { transportStatus = "Proposed change has not been accepted by Watch." }
        }
        #endif
    }
    private func drainProposals() {
        #if os(watchOS)
        guard let onWorkoutProposalReceived else { return }
        for proposal in remote.proposalInbox.values {
            guard let result = onWorkoutProposalReceived(proposal) else { continue }
            do {
                var next = remote
                if next.proposalReplies[proposal.id]?.result != result {
                    next.proposalReplies[proposal.id] = ProposalEnvelope(id: UUID(), result: result)
                }
                next.proposalInbox.removeValue(forKey: proposal.id)
                try write(next, "remote-control.json"); remote = next
            } catch { transportStatus = "Watch saved the change; its confirmation is pending." }
        }
        enqueueRemoteTransfers()
        #endif
    }
    private func receiveRemoteResult(_ data: Data, kind: String) {
        #if os(iOS)
        do {
            guard !resetCleanupPending else { return }
            var next = remote
            if kind == "remoteStartResult" {
                let result = try WorkoutTransportCodec.decode(RemoteWorkoutStartResult.self, from: data, kind: .remoteStartResult)
                guard RemoteWorkoutResultValidator.validate(result).isEmpty else { return }
                if next.starts[result.id] == nil, next.startResults[result.id] == result, result.isDefinitive {
                    session?.transferUserInfo(["kind": "remoteStartReceipt", "id": result.id.uuidString])
                    return
                }
                guard let intent = next.starts[result.id], result.intent == intent,
                      intent.syncGeneration == generation?.value else { return }
                next.startResults[result.id] = result
            } else {
                let envelope = try WorkoutTransportCodec.decode(ProposalEnvelope.self, from: data, kind: .proposalResult)
                guard RemoteWorkoutResultValidator.validate(envelope.result).isEmpty else { return }
                if next.proposals[envelope.result.id] == nil,
                   next.proposalResults[envelope.result.id]?.result.operation == envelope.result.operation {
                    if next.proposalResults[envelope.result.id]?.id == envelope.id {
                        session?.transferUserInfo(["kind": "proposalReceipt", "id": envelope.id.uuidString,
                            "operationID": envelope.result.id.uuidString])
                        return
                    }
                    next.proposals[envelope.result.id] = envelope.result.operation
                }
                guard next.proposals[envelope.result.id] == envelope.result.operation,
                      envelope.result.operation.syncGeneration == generation?.value else { return }
                next.proposalResults[envelope.result.id] = envelope
            }
            try write(next, "remote-control.json"); remote = next
            drainRemoteInbox()
        } catch {
            if !retainUnsupported(data, kind: kind, error: error) { transportStatus = "The Watch response needs another confirmation attempt." }
        }
        #endif
    }
    private func drainRemoteInbox() {
        #if os(iOS)
        guard !drainingRemoteInbox, session?.activationState == .activated else { return }
        drainingRemoteInbox = true
        defer { drainingRemoteInbox = false }
        for result in remote.startResults.values where result.isDefinitive && remote.starts[result.id] != nil {
            guard result.intent.syncGeneration == generation?.value,
                  RemoteWorkoutResultValidator.validate(result).isEmpty,
                  onRemoteStartResult?(result) == true else { continue }
            do {
                var next = remote; next.starts.removeValue(forKey: result.id)
                try write(next, "remote-control.json"); remote = next
                session?.transferUserInfo(["kind": "remoteStartReceipt", "id": result.id.uuidString])
            } catch { transportStatus = "Start result saved; confirmation cleanup pending." }
        }
        for envelope in remote.proposalResults.values where remote.proposals[envelope.result.id] != nil {
            guard envelope.result.operation.syncGeneration == generation?.value,
                  RemoteWorkoutResultValidator.validate(envelope.result).isEmpty,
                  onWorkoutProposalResult?(envelope.result) == true else { continue }
            do {
                var next = remote; next.proposals.removeValue(forKey: envelope.result.id)
                try write(next, "remote-control.json"); remote = next
                session?.transferUserInfo(["kind": "proposalReceipt", "id": envelope.id.uuidString,
                    "operationID": envelope.result.id.uuidString])
            } catch { transportStatus = "Watch result saved; confirmation cleanup pending." }
        }
        #endif
    }

    private func checkSnapshotVersion(_ data: Data, expected: Int) throws {
        struct Header: Decodable { let formatVersion: Int }
        let header = try decoder.decode(Header.self, from: data)
        guard header.formatVersion == expected else {
            throw WorkoutProtocolCompatibilityError(component: "device snapshot", version: header.formatVersion)
        }
    }

    /// Unknown versions are never acknowledged or interpreted as current records.
    /// Preserve exact bytes separately; the sender also keeps its durable outbox.
    @discardableResult private func retainUnsupported(_ data: Data, kind: String, error: Error) -> Bool {
        guard let compatibility = error as? WorkoutProtocolCompatibilityError else { return false }
        let message = compatibility.localizedDescription
        compatibilityMessage = message
        do {
            guard data.count <= Self.maximumEnvelopeBytes else { throw BridgeError.tooLarge }
            let digest = SHA256.hash(data: Data(kind.utf8) + data).map { String(format: "%02x", $0) }.joined()
            let url = try Self.fileURL("unsupported-\(digest).json")
            if !FileManager.default.fileExists(atPath: url.path) {
                let entries = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: [.fileSizeKey])
                    .filter { $0.lastPathComponent.hasPrefix("unsupported-") }
                let total = try entries.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
                guard entries.count < 100, total + data.count <= 128 * 1_024 * 1_024 else { throw BridgeError.tooLarge }
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            try write(message, "compatibility-state.json")
        } catch {
            compatibilityMessage = "Update Form / Flow on both devices. This message could not be retained locally; the sender has not received a save acknowledgement."
        }
        return true
    }

    private func acknowledgePlan(_ envelope: PlanEnvelope) {
        guard let session, session.activationState == .activated else { return }
        session.transferUserInfo(["kind": "planReceipt", "planID": envelope.id.uuidString])
    }
    private func requestPlan() {
        guard let session, session.activationState == .activated else { transportStatus = "Waiting for iPhone connection."; return }
        session.transferUserInfo(["kind": "planRequest"])
        if receivedPlan == nil { transportStatus = "Requested the latest plan from iPhone." }
    }
    private func write<T: Encodable>(_ value: T, _ name: String) throws {
        guard storageCompatible || name == "compatibility-state.json" else { throw BridgeError.unsupportedFormat }
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumEnvelopeBytes else { throw BridgeError.tooLarge }
        try data.write(to: Self.fileURL(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func readIfPresent<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
        let url = try Self.fileURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(type, from: Self.boundedData(at: url))
    }
    private static func valid(_ workout: WorkoutSession) -> Bool {
        workout.operationReceipts.count <= 100_000 && WorkoutSessionValidator.validate(workout).isEmpty
    }
    nonisolated private static let maximumEnvelopeBytes = 32 * 1_024 * 1_024
    nonisolated private static func fileURL(_ filename: String) throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = root.appendingPathComponent("WatchPlanTransfer", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(filename)
    }
    nonisolated private static func boundedData(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumEnvelopeBytes + 1) ?? Data()
        guard data.count <= maximumEnvelopeBytes else { throw BridgeError.tooLarge }; return data
    }
}

extension PlanBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        let message = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            connectionRevision += 1
            if let message { transportStatus = "Watch connection failed: \(message)"; return }
            #if os(iOS)
            sendGeneration(); enqueuePendingPlan(); drainWorkoutInbox()
            #else
            if let accepted, accepted.syncGeneration == generation?.value { acknowledgePlan(accepted) }
            requestPlan(); enqueueWorkouts()
            #endif
            enqueueRemoteTransfers(); drainRemoteInbox(); drainProposals()
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard applicationContext["kind"] as? String == "workspaceGeneration",
              let value = applicationContext["generation"] as? String,
              let changed = applicationContext["changedAt"] as? Double else { return }
        Task { @MainActor [weak self] in self?.receiveGeneration(value, changedAt: Date(timeIntervalSince1970: changed)) }
    }
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let kind = file.metadata?["kind"] as? String,
              ["activatedPlan", "ownerWorkout", "workoutProposal", "remoteStartResult", "proposalResult"].contains(kind) else { return }
        do {
            // The temporary URL ceases to exist after this callback returns.
            let data = try Self.boundedData(at: file.fileURL)
            Task { @MainActor [weak self] in
                switch kind {
                case "activatedPlan": self?.receivePlan(data)
                case "ownerWorkout": self?.receiveWorkout(data)
                case "workoutProposal": self?.receiveProposal(data)
                default: self?.receiveRemoteResult(data, kind: kind)
                }
            }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor [weak self] in self?.transportStatus = "Couldn’t receive data: \(message)" }
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        guard let kind = message["kind"] as? String,
              ["remoteStart", "activatedPlan", "ownerWorkout", "workoutProposal", "remoteStartResult", "proposalResult"].contains(kind),
              let data = message["payload"] as? Data, data.count <= 60_000 else { replyHandler(["received": false]); return }
        replyHandler(["received": true]) // Transport receipt is explicitly not an owner-start acknowledgement.
        Task { @MainActor [weak self] in
            switch kind {
            case "remoteStart": self?.receiveStartRequest(data, allowStart: true)
            case "activatedPlan": self?.receivePlan(data)
            case "ownerWorkout": self?.receiveWorkout(data)
            case "workoutProposal": self?.receiveProposal(data)
            default: self?.receiveRemoteResult(data, kind: kind)
            }
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let kind = userInfo["kind"] as? String else { return }
        #if os(iOS)
        if kind == "planRequest" {
            Task { @MainActor [weak self] in
                UserDefaults.standard.removeObject(forKey: "FormFlow.acknowledgedPlanID")
                self?.sendGeneration(); self?.enqueuePendingPlan()
            }
        } else if kind == "planReceipt", let id = userInfo["planID"] as? String {
            Task { @MainActor [weak self] in
                guard let self, pending?.id.uuidString == id, pending?.syncGeneration == generation?.value else { return }
                UserDefaults.standard.set(id, forKey: "FormFlow.acknowledgedPlanID")
                transportStatus = "Plan confirmed on Apple Watch."
            }
        } else if kind == "remoteStartPending", let data = userInfo["payload"] as? Data, data.count <= 16_384 {
            Task { @MainActor [weak self] in self?.receiveRemoteResult(data, kind: "remoteStartResult") }
        }
        #else
        if kind == "workoutReceipt", let id = (userInfo["envelopeID"] as? String).flatMap(UUID.init(uuidString:)),
           let workoutID = (userInfo["sessionID"] as? String).flatMap(UUID.init(uuidString:)),
           let revision = userInfo["revision"] as? Int, let generation = userInfo["generation"] as? String {
            Task { @MainActor [weak self] in self?.receiveWorkoutReceipt(id: id, sessionID: workoutID, revision: revision, syncGeneration: generation) }
        } else if kind == "remoteStartProbe", let data = userInfo["payload"] as? Data, data.count <= 16_384 {
            Task { @MainActor [weak self] in self?.receiveStartRequest(data, allowStart: false) }
        } else if kind == "remoteStartReceipt", let id = (userInfo["id"] as? String).flatMap(UUID.init(uuidString:)) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                var next = remote; next.startReplies.removeValue(forKey: id)
                do { try write(next, "remote-control.json"); remote = next } catch { transportStatus = "Start receipt cleanup pending." }
            }
        } else if kind == "proposalReceipt",
                  let id = (userInfo["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let operationID = (userInfo["operationID"] as? String).flatMap(UUID.init(uuidString:)) {
            Task { @MainActor [weak self] in
                guard let self, remote.proposalReplies[operationID]?.id == id else { return }
                var next = remote; next.proposalReplies.removeValue(forKey: operationID)
                do { try write(next, "remote-control.json"); remote = next } catch { transportStatus = "Change receipt cleanup pending." }
            }
        }
        #endif
    }
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        guard let text = fileTransfer.file.metadata?["envelopeID"] as? String, let id = UUID(uuidString: text) else { return }
        let message = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let url = try? Self.fileURL("outgoing-\(text).json") { try? FileManager.default.removeItem(at: url) }
            if let envelope = outbox.pending.values.first(where: { $0.id == id }) {
                workoutStatuses[envelope.workout.id] = envelope.workout.syncGeneration != generation?.value
                    ? "Retained for review — older workspace"
                    : (message == nil ? "Delivered; awaiting iPhone save" : "Saved on Watch; transfer failed")
            }
            if pending?.id == id, pending?.syncGeneration == generation?.value,
               UserDefaults.standard.string(forKey: "FormFlow.acknowledgedPlanID") != text {
                transportStatus = message.map { "Watch transfer failed: \($0)" } ?? "Delivered; awaiting Watch confirmation."
            }
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.connectionRevision += 1; self?.retry() }
    }
    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        UserDefaults.standard.removeObject(forKey: "FormFlow.acknowledgedPlanID"); session.activate()
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.connectionRevision += 1; self?.retry() }
    }
    #endif
}

private struct PlanEnvelope: Codable, Sendable {
    var formatVersion = 2
    let id: UUID
    let sourceID: UUID
    let revision: Int
    let createdAt: Date
    let activationDate: Date
    let plan: WeeklyPlan
    let syncGeneration: String
    let planRevisionID: String
    let deliveryRevision: Int?
    let scheduleExceptions: [ScheduleException]?
    let historyBaseline: WatchHistoryBaseline?
    let recordedOccurrences: [RecordedScheduleOccurrence]?
}
private struct BridgeGeneration: Codable { let value: String; let changedAt: Date; let retired: Set<String> }
private struct WorkoutEnvelope: Codable { var formatVersion = 1; let id: UUID; let workout: WorkoutSession }
private struct WorkoutMailbox: Codable {
    var pending: [UUID: WorkoutEnvelope] = [:]
    var confirmed: [UUID: Int] = [:]
    var confirmedSnapshots: [UUID: WorkoutSession]? // Optional to read existing revision-only receipts.
}
private struct ProposalEnvelope: Codable, Equatable { let id: UUID; let result: WorkoutProposalResult }
private struct RemoteBridgeState: Codable {
    var starts: [UUID: RemoteWorkoutStartIntent] = [:]
    var startResults: [UUID: RemoteWorkoutStartResult] = [:]
    var startReplies: [UUID: RemoteWorkoutStartResult] = [:]
    var proposals: [UUID: WorkoutOperation] = [:]
    var proposalResults: [UUID: ProposalEnvelope] = [:]
    var proposalReplies: [UUID: ProposalEnvelope] = [:]
    var proposalInbox: [UUID: WorkoutOperation] = [:]
}
private enum BridgeError: LocalizedError {
    case tooLarge, unsupportedFormat
    var errorDescription: String? {
        switch self {
        case .tooLarge: "Transfer data exceeds 32 MiB. The source records have been retained."
        case .unsupportedFormat: "This transfer needs a compatible app version."
        }
    }
}
