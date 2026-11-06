import Foundation
import Observation
import HealthKit
import FormFlowCore

/// Optional sensor recording. The workout domain remains usable when Health is unavailable.
/// Persist the domain change before calling this adapter. Only the domain's designated owner saves.
@MainActor @Observable
final class HealthRecording: NSObject {
    private(set) var status = "Health recording is optional."
    private(set) var lastError: String?
    private(set) var heartRate: Double?
    private(set) var activeEnergyKilocalories: Double?
    private(set) var activeWorkoutID: UUID?
    private(set) var mirroredWorkoutID: UUID?
    private(set) var mirroredOwnerDeviceID: String?
    private(set) var mirroredSyncGeneration: String?
    private(set) var mirroredHeartRate: Double?
    private(set) var mirroredActiveEnergyKilocalories: Double?
    private(set) var hasMirroredSession = false
    private(set) var mirroredStatus = "No mirrored workout."
    var ownsActiveSession: Bool { session != nil && activeWorkoutID != nil }
    /// The host may persist matching domain pause/resume operations when Health changes state itself.
    @ObservationIgnored var onSessionStateChanged: ((UUID, WorkoutState, Date) -> Void)?

    @ObservationIgnored private let localDeviceID: String
    @ObservationIgnored private let store: HKHealthStore?
    @ObservationIgnored private let journalURL: URL
    @ObservationIgnored private var journal = HealthJournal()
    @ObservationIgnored private var journalAvailable = true
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var mirroredSession: HKWorkoutSession?
    @ObservationIgnored private var activeGeneration: String?
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var isFinishing = false
    @ObservationIgnored private var collectionEnded = false
    @ObservationIgnored private var lastMirrorSentAt = Date.distantPast
    @ObservationIgnored private var mirroringStarted = false
    nonisolated private static let correlationKey = "com.formflow.exportCorrelationID"
    nonisolated private static let workoutKey = "com.formflow.workoutID"
    nonisolated private static let generationKey = "com.formflow.syncGeneration"
    nonisolated private static let ownerKey = "com.formflow.ownerDeviceID"

    init(localDeviceID: String, journalURL: URL? = nil, isEnabled: Bool = true) {
        self.localDeviceID = localDeviceID
        self.journalURL = journalURL ?? URL.applicationSupportDirectory
            .appending(path: "FormFlow/health-journal-v1.json")
        store = isEnabled && HKHealthStore.isHealthDataAvailable() ? HKHealthStore() : nil
        super.init()
        guard isEnabled else { status = "Health recording is disabled."; return }
        do {
            if FileManager.default.fileExists(atPath: self.journalURL.path) {
                let loaded = try JSONDecoder().decode(HealthJournal.self, from: Data(contentsOf: self.journalURL))
                guard loaded.validate() else { throw HealthJournalError.invalidIdentity }
                journal = loaded
            }
        } catch {
            journalAvailable = false
            report("Health export history could not be read. Manual recording remains available.", error: error)
        }
        guard let store else { status = "Health is unavailable. You can record sets manually."; return }
        #if os(iOS)
        store.workoutSessionMirroringStartHandler = { [weak self] incoming in
            Task { @MainActor in self?.adoptMirroredSession(incoming) }
        }
        #endif
    }

    /// Permission is requested only after the user chooses Health recording for this live workout.
    func start(workout: WorkoutSession) async -> Bool {
        guard !isStarting, !isFinishing else { return false }
        guard validOwner(workout), !workout.state.isTerminal else {
            status = "Only this device's live workout can start Health recording."; return false
        }
        if matchesActive(workout) { return true }
        guard session == nil, !hasMirroredSession else {
            status = "Another Health workout is active. This workout can still be logged manually."; return false
        }
        guard journalAvailable, let store else {
            status = "Health recording is unavailable. Continue recording sets manually."; return false
        }
        if let prior = journal.entry(workoutID: workout.id, generation: workout.syncGeneration), prior.state != .failedBeforeSave {
            status = "This workout already has a Health recording intent. Recover or verify it before retrying."; return false
        }
        isStarting = true; defer { isStarting = false }
        do {
            let energy = HKQuantityType(.activeEnergyBurned)
            try await store.requestAuthorization(toShare: [HKObjectType.workoutType(), energy],
                read: [HKObjectType.workoutType(), HKQuantityType(.heartRate), energy])
            guard store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
                status = "Health saving was not allowed. Continue recording sets manually."; return false
            }
            // Authorization suspends this method. A mirrored workout may have arrived meanwhile.
            guard session == nil, !hasMirroredSession else { status = "Another Health workout became active."; return false }
            var next = journal
            let intent = try next.prepare(workoutID: workout.id, generation: workout.syncGeneration,
                ownerDeviceID: workout.ownerDeviceID, localDeviceID: localDeviceID, at: Date())
            try persist(next)
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = Self.activity(for: workout.prescription.kind)
            configuration.locationType = .unknown
            let recording = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let liveBuilder = recording.associatedWorkoutBuilder()
            liveBuilder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            attach(recording, builder: liveBuilder, workout: workout)
            try await liveBuilder.addMetadata([
                Self.correlationKey: intent.correlationID.uuidString,
                Self.workoutKey: workout.id.uuidString,
                Self.generationKey: workout.syncGeneration,
                Self.ownerKey: localDeviceID,
                HKMetadataKeySyncIdentifier: intent.correlationID.uuidString,
                HKMetadataKeySyncVersion: 1
            ])
            let now = Date() // Never fabricate sensor coverage before recording actually began.
            recording.startActivity(with: now)
            try await liveBuilder.beginCollection(at: now)
            try transition(workout, to: .recording)
            if workout.state == .paused { recording.pause() }
            lastError = nil; status = workout.state == .paused ? "Health recording paused." : "Recording with Health."
            await startMirroringIfAvailable()
            return true
        } catch {
            session?.end(); builder?.discardWorkout(); clearOwnedSession()
            try? transition(workout, to: .failedBeforeSave, message: error.localizedDescription)
            report("Health recording could not start. Continue recording sets manually.", error: error)
            return false
        }
    }

    /// Recovers the system session only if its durable correlation metadata matches this owner and workout.
    /// Failure never starts another sensor session or recreates a past workout.
    @discardableResult
    func recover(workout: WorkoutSession) async -> Bool {
        guard validOwner(workout), !workout.state.isTerminal, !isStarting, !isFinishing else { return false }
        if matchesActive(workout) { return true }
        guard session == nil, journalAvailable, let store,
              let intent = journal.entry(workoutID: workout.id, generation: workout.syncGeneration),
              [.prepared, .recording].contains(intent.state) else { return false }
        isStarting = true; defer { isStarting = false }
        do {
            guard let recovered = try await store.recoverActiveWorkoutSession() else {
                status = "The Health session could not be recovered. Your manually recorded sets remain saved."; return false
            }
            let liveBuilder = recovered.associatedWorkoutBuilder()
            guard liveBuilder.metadata[Self.correlationKey] as? String == intent.correlationID.uuidString,
                  liveBuilder.metadata[Self.ownerKey] as? String == localDeviceID,
                  liveBuilder.metadata[Self.generationKey] as? String == workout.syncGeneration,
                  liveBuilder.metadata[Self.workoutKey] as? String == workout.id.uuidString,
                  ![HKWorkoutSessionState.ended, .stopped].contains(recovered.state) else {
                status = "A different Health session was recovered. It has not been adopted."; return false
            }
            attach(recovered, builder: liveBuilder, workout: workout)
            if intent.state == .prepared { try transition(workout, to: .recording) }
            if workout.state == .paused && recovered.state == .running { recovered.pause() }
            else if recovered.state == .paused { recovered.resume() }
            readMetrics(liveBuilder)
            status = "Health recording recovered."; lastError = nil
            await startMirroringIfAvailable()
            return true
        } catch { report("Health recovery failed. Manual recording remains available.", error: error); return false }
    }

    func pause() {
        guard !isFinishing, let session, session.state == .running else { return }
        session.pause(); heartRate = nil; status = "Health recording paused."
    }

    func resume() {
        guard !isFinishing, let session, session.state == .paused else { return }
        session.resume(); status = "Recording with Health."
    }

    func finish(workout: WorkoutSession) async {
        if workout.state == .abandoned { await discard(workout: workout); return }
        guard validOwner(workout), workout.state == .finished, !isStarting, !isFinishing else { return }
        guard matchesActive(workout), let builder, let session else {
            await reconcilePendingExports(); return
        }
        guard workout.hasRecordedWork else { await discard(workout: workout); return }
        guard journal.entry(workoutID: workout.id, generation: workout.syncGeneration)?.state == .recording else { return }
        isFinishing = true; defer { isFinishing = false }
        session.end()
        do {
            if !collectionEnded { try await builder.endCollection(at: Date()); collectionEnded = true }
            // The write-ahead barrier: no external save may run unless its ambiguous intent is durable.
            try transition(workout, to: .saving)
        } catch {
            try? transition(workout, to: .failedBeforeSave, message: error.localizedDescription)
            report("Health was not saved. You can retry this export while the app remains open.", error: error)
            return
        }
        do {
            let saved = try await builder.finishWorkout()
            if let saved {
                try transition(workout, to: .saved, healthWorkoutID: saved.uuid)
                status = "Workout saved to Health."; lastError = nil
            } else {
                // HealthKit permits a successful nil result while the device is locked.
                try transition(workout, to: .pendingVerification, message: "Health returned no workout identifier.")
                status = "Health save is pending verification. No duplicate export will be attempted."
            }
        } catch {
            try? transition(workout, to: .pendingVerification, message: error.localizedDescription)
            report("Health save is pending verification. No duplicate export will be attempted.", error: error)
        }
        clearOwnedSession()
    }

    /// Only retries a failure before finishWorkout was called, using the original in-memory builder.
    func retryFailedExport(workout: WorkoutSession) async {
        guard matchesActive(workout), workout.state == .finished, !isFinishing,
              journal.entry(workoutID: workout.id, generation: workout.syncGeneration)?.state == .failedBeforeSave else { return }
        do {
            try transition(workout, to: .prepared)
            try transition(workout, to: .recording)
            await finish(workout: workout)
        } catch { report("Health export could not be retried.", error: error) }
    }

    /// Discard is also available during a workspace reset, without rewriting the domain history.
    func discard(workout: WorkoutSession) async {
        guard validOwner(workout), matchesActive(workout), !isStarting, !isFinishing else { return }
        session?.end(); builder?.discardWorkout()
        do {
            try transition(workout, to: .discarded)
            status = "Health recording discarded. Your workout log is retained."
        } catch { report("Health recording stopped; its export history could not be updated.", error: error) }
        clearOwnedSession()
    }

    /// Read authorization is intentionally unknowable. Empty results remain pending, never retryable.
    func reconcilePendingExports() async {
        guard journalAvailable, let store, !isFinishing else { return }
        let pending = journal.entries.filter { $0.ownerDeviceID == localDeviceID && [.saving, .pendingVerification].contains($0.state) }
        for intent in pending {
            do {
                let matches: [UUID] = try await withCheckedThrowingContinuation { continuation in
                    let predicate = HKQuery.predicateForObjects(withMetadataKey: Self.correlationKey, allowedValues: [intent.correlationID.uuidString])
                    let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: 10, sortDescriptors: nil) { _, samples, error in
                        if let error { continuation.resume(throwing: error); return }
                        let identifiers = (samples ?? []).compactMap { sample -> UUID? in
                            guard let workout = sample as? HKWorkout,
                                  workout.metadata?[Self.workoutKey] as? String == intent.workoutID.uuidString,
                                  workout.metadata?[Self.generationKey] as? String == intent.syncGeneration,
                                  workout.metadata?[Self.ownerKey] as? String == intent.ownerDeviceID else { return nil }
                            return workout.uuid
                        }
                        continuation.resume(returning: identifiers)
                    }
                    store.execute(query)
                }
                // Another reconciliation may have completed while the query was in flight.
                guard let current = journal.entry(workoutID: intent.workoutID, generation: intent.syncGeneration),
                      [.saving, .pendingVerification].contains(current.state) else { continue }
                var next = journal
                try next.reconcile(workoutID: intent.workoutID, generation: intent.syncGeneration,
                                   localDeviceID: localDeviceID, matches: matches, at: max(Date(), current.updatedAt))
                try persist(next)
                status = next.entry(workoutID: intent.workoutID, generation: intent.syncGeneration)?.state == .saved
                    ? "Health save verified." : "Health save is pending verification. No duplicate export will be attempted."
            } catch { report("Health save could not be verified yet. No duplicate export will be attempted.", error: error) }
        }
    }

    func exportState(for workout: WorkoutSession) -> HealthExportState? {
        journal.entry(workoutID: workout.id, generation: workout.syncGeneration)?.state
    }

    /// The mirrored session never receives a builder and never exports from this device.
    func adoptMirroredSession(_ incoming: HKWorkoutSession) {
        guard store != nil, incoming.type == .mirrored else { return }
        mirroredSession = incoming; incoming.delegate = self
        hasMirroredSession = true; mirroredStatus = "Watch Health session connected; waiting for its workout identity."
        mirroredWorkoutID = nil; mirroredOwnerDeviceID = nil; mirroredSyncGeneration = nil
        mirroredHeartRate = nil; mirroredActiveEnergyKilocalories = nil
    }

    private func validOwner(_ workout: WorkoutSession) -> Bool {
        workout.ownerDeviceID == localDeviceID && WorkoutArchiveValidator.validate(workout).isEmpty
    }
    private func matchesActive(_ workout: WorkoutSession) -> Bool {
        workout.id == activeWorkoutID && workout.syncGeneration == activeGeneration && workout.ownerDeviceID == localDeviceID
    }
    private func attach(_ recording: HKWorkoutSession, builder: HKLiveWorkoutBuilder, workout: WorkoutSession) {
        session = recording; self.builder = builder
        activeWorkoutID = workout.id; activeGeneration = workout.syncGeneration
        collectionEnded = false; heartRate = nil; activeEnergyKilocalories = nil
        recording.delegate = self; builder.delegate = self
    }
    private func clearOwnedSession() {
        session?.delegate = nil; builder?.delegate = nil
        session = nil; builder = nil; activeWorkoutID = nil; activeGeneration = nil
        heartRate = nil; activeEnergyKilocalories = nil; collectionEnded = false; mirroringStarted = false
    }
    private func transition(_ workout: WorkoutSession, to state: HealthExportState,
                            healthWorkoutID: UUID? = nil, message: String? = nil) throws {
        var next = journal
        let date = max(Date(), next.entry(workoutID: workout.id, generation: workout.syncGeneration)?.updatedAt ?? .distantPast)
        try next.transition(workoutID: workout.id, generation: workout.syncGeneration,
            localDeviceID: localDeviceID, to: state, at: date, healthWorkoutID: healthWorkoutID, message: message)
        try persist(next)
    }
    private func persist(_ next: HealthJournal) throws {
        guard journalAvailable, next.validate() else { throw HealthJournalError.invalidIdentity }
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        journal = next
    }
    private func report(_ message: String, error: Error) { status = message; lastError = error.localizedDescription }
    private static func activity(for kind: String) -> HKWorkoutActivityType {
        switch kind.lowercased() {
        case "strength": .traditionalStrengthTraining
        case "walking": .walking
        case "running": .running
        case "cycling": .cycling
        case "mobility", "flexibility": .flexibility
        case "mixed": .crossTraining
        default: .other
        }
    }
    private func readMetrics(_ source: HKLiveWorkoutBuilder) {
        guard source === builder else { return }
        let statistics = source.statistics(for: HKQuantityType(.heartRate))
        let bpm = statistics?.mostRecentQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        let recent = statistics?.mostRecentQuantityDateInterval().map { Date().timeIntervalSince($0.end) <= 30 } ?? false
        heartRate = session?.state == .running && recent ? bpm.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } : nil
        let energy = source.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        activeEnergyKilocalories = energy.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        Task { await sendMirrorContext() }
    }
    private func startMirroringIfAvailable() async {
        #if os(watchOS)
        guard let session else { return }
        do { try await session.startMirroringToCompanionDevice(); mirroringStarted = true; await sendMirrorContext(force: true) }
        catch { lastError = "Recording on Watch; live iPhone mirroring is unavailable: \(error.localizedDescription)" }
        #endif
    }
    private func sendMirrorContext(force: Bool = false) async {
        #if os(watchOS)
        guard mirroringStarted, let session, let activeWorkoutID, let activeGeneration,
              force || Date().timeIntervalSince(lastMirrorSentAt) >= 1 else { return }
        let packet = HealthMirrorContext(version: 1, workoutID: activeWorkoutID, ownerDeviceID: localDeviceID,
            syncGeneration: activeGeneration, heartRate: heartRate, activeEnergyKilocalories: activeEnergyKilocalories)
        do {
            let data = try JSONEncoder().encode(packet); lastMirrorSentAt = Date()
            try await session.sendToRemoteWorkoutSession(data: data)
        } catch { lastError = "Watch recording continues; live iPhone metrics are temporarily unavailable." }
        #endif
    }
}

private struct HealthMirrorContext: Codable, Sendable {
    let version: Int
    let workoutID: UUID
    let ownerDeviceID: String
    let syncGeneration: String
    let heartRate: Double?
    let activeEnergyKilocalories: Double?
}

extension HealthRecording: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                   from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if workoutSession === self.mirroredSession {
                self.mirroredStatus = toState == .paused ? "Watch Health recording paused." : "Watch Health recording connected."
                if toState == .ended || toState == .stopped {
                    self.hasMirroredSession = false; self.mirroredHeartRate = nil
                    self.mirroredStatus = "Watch Health recording ended. The Watch owns its Health export."
                }
            } else if workoutSession === self.session, !self.isFinishing {
                if toState == .paused { self.heartRate = nil; self.status = "Health recording paused." }
                if toState == .running { self.status = "Recording with Health." }
                if let id = self.activeWorkoutID, toState == .paused || toState == .running {
                    self.onSessionStateChanged?(id, toState == .paused ? .paused : .active, date)
                }
                await self.sendMirrorContext(force: true)
            }
        }
    }
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if workoutSession === self.session {
                self.heartRate = nil
                self.report("Health recording was interrupted. Continue recording sets manually.", error: error)
            } else if workoutSession === self.mirroredSession {
                self.mirroredStatus = "Watch Health connection was interrupted."
                self.mirroredHeartRate = nil; self.hasMirroredSession = false
            }
        }
    }
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        Task { @MainActor [weak self] in
            guard let self, workoutSession === self.mirroredSession else { return }
            for bytes in data where bytes.count <= 4_096 {
                guard let packet = try? JSONDecoder().decode(HealthMirrorContext.self, from: bytes), packet.version == 1,
                      !packet.ownerDeviceID.isEmpty, packet.ownerDeviceID != self.localDeviceID, !packet.syncGeneration.isEmpty,
                      packet.heartRate.map({ $0.isFinite && $0 > 0 && $0 <= 1_000 }) ?? true,
                      packet.activeEnergyKilocalories.map({ $0.isFinite && $0 >= 0 }) ?? true else { continue }
                if let known = self.mirroredWorkoutID, known != packet.workoutID { continue }
                if let owner = self.mirroredOwnerDeviceID, owner != packet.ownerDeviceID { continue }
                if let generation = self.mirroredSyncGeneration, generation != packet.syncGeneration { continue }
                self.mirroredWorkoutID = packet.workoutID; self.mirroredOwnerDeviceID = packet.ownerDeviceID
                self.mirroredSyncGeneration = packet.syncGeneration; self.mirroredHeartRate = packet.heartRate
                self.mirroredActiveEnergyKilocalories = packet.activeEnergyKilocalories
                self.mirroredStatus = "Live Health recording on Watch."
            }
        }
    }
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, workoutSession === self.mirroredSession else { return }
            self.mirroredHeartRate = nil; self.hasMirroredSession = false
            self.mirroredStatus = "Watch connection lost. The Watch remains the Health recording owner."
        }
    }
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        Task { @MainActor [weak self] in self?.readMetrics(workoutBuilder) }
    }
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
