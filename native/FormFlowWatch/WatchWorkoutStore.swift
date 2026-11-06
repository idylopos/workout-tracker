import Foundation
import Observation
import FormFlowCore
import WatchKit

@MainActor @Observable
final class WatchWorkoutStore {
    let bridge: PlanBridge
    private(set) var health: HealthRecording?
    private(set) var archive = WatchWorkoutArchive()
    private(set) var storageAvailable = true
    var errorMessage: String?
    var selectedWorkoutID: UUID?
    private var fileURL: URL?
    @ObservationIgnored private var healthActions: Set<UUID> = []
    @ObservationIgnored private var attemptedHealthRecovery: Set<UUID> = []

    var workouts: [WorkoutSession] { archive.workouts.sorted { $0.startedAt > $1.startedAt } }
    var deviceID: String { archive.deviceID }
    var activeWorkout: WorkoutSession? {
        workouts.first { !$0.state.isTerminal && $0.syncGeneration == bridge.receivedSyncGeneration }
    }
    var retainedCount: Int { workouts.filter { $0.syncGeneration != bridge.receivedSyncGeneration }.count }

    func upcomingSessions() throws -> [ScheduledPlanSession] {
        guard let plan = bridge.receivedPlan, let activation = bridge.receivedActivationDate else { return [] }
        let today = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 14, to: today) ?? today
        let occupied = Set(bridge.receivedRecordedOccurrences.map(\.id))
        return try Array(ScheduleExceptionSchedule.occurrences(plan: plan, activationDate: activation,
            from: today, through: end, exceptions: bridge.receivedScheduleExceptions,
            workouts: workouts.filter { $0.syncGeneration == bridge.receivedSyncGeneration })
            .filter { $0.status == .planned && !occupied.contains($0.id) }.prefix(10)).map(\.scheduled)
    }

    init(bridge: PlanBridge) {
        self.bridge = bridge
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            fileURL = root.appendingPathComponent("watch-workouts.json")
            if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 64 * 1_024 * 1_024 else { throw WatchStoreError.tooLarge }
                let loaded = try JSONDecoder().decode(WatchWorkoutArchive.self, from: Data(contentsOf: fileURL))
                guard loaded.version == 1, !loaded.deviceID.isEmpty,
                      Set(loaded.workouts.map(\.id)).count == loaded.workouts.count,
                      loaded.workouts.allSatisfy({ WorkoutSessionValidator.validate($0).isEmpty }) else { throw WatchStoreError.invalidArchive }
                archive = loaded
            } else {
                try save(archive)
            }
            syncCurrentWorkouts()
            health = HealthRecording(localDeviceID: archive.deviceID)
            health?.onSessionStateChanged = { [weak self] id, state, date in
                guard let self, let current = workouts.first(where: { $0.id == id }),
                      current.syncGeneration == bridge.receivedSyncGeneration,
                      current.ownerDeviceID == archive.deviceID, !current.state.isTerminal,
                      current.state != state, [.active, .paused].contains(state) else { return }
                _ = apply(state == .paused ? .pause : .resume, to: id, at: date)
            }
            bridge.onRemoteStartRequested = { [weak self] intent, allowStart in self?.handleRemoteStart(intent, allowStart: allowStart) }
            bridge.onWorkoutProposalReceived = { [weak self] operation in self?.handleProposal(operation) }
            reconcileHealth()
            if let health { Task { @MainActor in await health.reconcilePendingExports() } }
        } catch {
            storageAvailable = false
            errorMessage = "Watch storage could not be opened. Existing data has been retained. \(error.localizedDescription)"
        }
    }

    func syncCurrentWorkouts() {
        guard storageAvailable else { return }
        for workout in workouts { bridge.publishWorkout(workout) }
        reconcileHealth()
    }

    private func reconcileHealth() {
        guard let health else { return }
        if let id = health.activeWorkoutID, let workout = workouts.first(where: { $0.id == id }),
           workout.syncGeneration != bridge.receivedSyncGeneration {
            guard !healthActions.contains(id) else { return }
            healthActions.insert(id)
            Task { @MainActor in
                defer { healthActions.remove(id) }
                await health.discard(workout: workout)
                saveHealthMessage(for: id)
            }
            return
        }
        guard let workout = activeWorkout, archive.healthRequestedIDs?.contains(workout.id) == true,
              !health.ownsActiveSession, !healthActions.contains(workout.id),
              attemptedHealthRecovery.insert(workout.id).inserted else { return }
        healthActions.insert(workout.id)
        Task { @MainActor in
            defer { healthActions.remove(workout.id) }
            let recovered = await health.recover(workout: workout)
            if recovered, let current = workouts.first(where: { $0.id == workout.id }) {
                if current.syncGeneration != bridge.receivedSyncGeneration { await health.discard(workout: current) }
                else if current.state.isTerminal { await health.finish(workout: current) }
                else if current.state == .paused { health.pause() }
            }
            saveHealthMessage(for: workout.id)
            await health.reconcilePendingExports()
        }
    }

    func alertForExpiredRest(_ rest: WorkoutRest, workoutID: UUID) {
        guard storageAvailable, rest.isExpired(at: Date()),
              workouts.first(where: { $0.id == workoutID })?.syncGeneration == bridge.receivedSyncGeneration else { return }
        let key = "\(workoutID.uuidString):\(rest.setID.uuidString):\(rest.deadline.timeIntervalSince1970)"
        guard archive.alertedRestIDs?.contains(key) != true else { return }
        do {
            var next = archive
            next.alertedRestIDs = Array(((next.alertedRestIDs ?? []) + [key]).suffix(1_000))
            try save(next); archive = next
            WKInterfaceDevice.current().play(.notification)
        } catch { errorMessage = "Rest finished. The alert state could not be saved." }
    }

    func start(_ prescription: PlanSession, scheduledSessionID: String? = nil, scheduledDate: Date? = nil, recordWithHealth: Bool = false) {
        guard storageAvailable else { return }
        if let activeWorkout { selectedWorkoutID = activeWorkout.id; return }
        guard let plan = bridge.receivedPlan, let revision = bridge.receivedPlanRevision,
              let generation = bridge.receivedSyncGeneration,
              plan.days.flatMap(\.sessions).contains(prescription),
              let activation = bridge.receivedActivationDate else {
            errorMessage = "An activated plan from your iPhone is needed before starting."
            return
        }
        do {
            if let scheduledSessionID {
                guard !bridge.receivedRecordedOccurrences.contains(where: { $0.id == scheduledSessionID }) else {
                    errorMessage = "This occurrence is already recorded or in progress on iPhone. Open its history or start an extra, unscheduled workout."
                    return
                }
                guard let occurrence = try ScheduleExceptionSchedule.resolve(occurrenceID: scheduledSessionID, plan: plan,
                    activationDate: activation, exceptions: bridge.receivedScheduleExceptions,
                    workouts: workouts.filter { $0.syncGeneration == generation }), occurrence.canStart,
                      occurrence.scheduled.session == prescription,
                      let scheduledDate, occurrence.scheduled.date == Calendar.current.startOfDay(for: scheduledDate) else {
                    errorMessage = "This scheduled workout changed. Open its current date and prescription before starting."
                    return
                }
            }
            let workout = try WorkoutSession.start(prescription: prescription, planID: plan.id,
                planRevisionID: revision, scheduledSessionID: scheduledSessionID, ownerDeviceID: archive.deviceID, at: Date(),
                timeZoneIdentifier: TimeZone.current.identifier, syncGeneration: generation)
            var next = archive; next.workouts.append(workout)
            if recordWithHealth { next.healthRequestedIDs = (next.healthRequestedIDs ?? []) + [workout.id] }
            try save(next); archive = next
            selectedWorkoutID = workout.id
            bridge.publishWorkout(workout)
            if recordWithHealth { startHealth(workout) }
        } catch { errorMessage = "Couldn’t start the workout: \(error.localizedDescription)" }
    }

    @discardableResult func apply(_ command: WorkoutCommand, to id: UUID, at date: Date = Date()) -> Bool {
        guard storageAvailable, let index = archive.workouts.firstIndex(where: { $0.id == id }) else { return false }
        let original = archive.workouts[index]
        guard original.ownerDeviceID == archive.deviceID, original.syncGeneration == bridge.receivedSyncGeneration else {
            errorMessage = "This workout belongs to an older workspace and is retained for review."
            return false
        }
        let operation = WorkoutOperation(session: original, command: command, originDeviceID: archive.deviceID, at: date)
        let reduction = WorkoutReducer.apply(operation, to: original, at: Date())
        guard reduction.status == .applied || reduction.status == .duplicate else {
            errorMessage = reduction.issues.map(\.message).joined(separator: " ")
            return false
        }
        do {
            var next = archive; next.workouts[index] = reduction.session
            switch command {
            case .logSet(let id, _), .updateSet(let id, _): next.drafts.removeValue(forKey: id)
            case .logInterval(_, let intervalID, _), .updateInterval(_, let intervalID, _):
                next.drafts.removeValue(forKey: intervalID)
            case .chooseAlternative(let exerciseID, _):
                if let exercise = original.exercises.first(where: { $0.id == exerciseID }) {
                    for set in exercise.sets {
                        next.drafts.removeValue(forKey: set.id)
                        for interval in set.intervals ?? [] { next.drafts.removeValue(forKey: interval.id) }
                    }
                }
            default: break
            }
            try save(next); archive = next
            bridge.publishWorkout(reduction.session)
            updateHealth(from: original, to: reduction.session)
            return true
        } catch { errorMessage = "The change has not been saved. Try again before leaving. \(error.localizedDescription)"; return false }
    }

    private func handleRemoteStart(_ intent: RemoteWorkoutStartIntent, allowStart: Bool) -> RemoteWorkoutStartResult? {
        guard storageAvailable else { return nil }
        let previous = archive.remoteStarts?[intent.id]
        let result: RemoteWorkoutStartResult
        if previous == nil, allowStart, let scheduledID = intent.scheduledSessionID,
                  !workouts.contains(where: { $0.scheduledSessionID == scheduledID && $0.syncGeneration == intent.syncGeneration && $0.state != .abandoned }),
                  !canStartOccurrence(scheduledID, intent: intent) {
            result = .init(intent: intent, status: .rejected,
                message: "This occurrence is skipped, already recorded, moved to a different date, or no longer matches the Watch schedule.", resolvedAt: Date())
        } else {
            result = RemoteWorkoutStartResolver.resolve(intent, previous: previous, allowStart: allowStart,
                plan: bridge.receivedPlan, planRevisionID: bridge.receivedPlanRevision,
                syncGeneration: bridge.receivedSyncGeneration, ownerDeviceID: archive.deviceID,
                workouts: workouts, now: Date())
        }
        guard result.isDefinitive else { return result }
        // A reused identifier cannot replace the original accepted decision.
        if let previous { return previous.intent == intent ? previous : result }
        do {
            var next = archive
            var starts = next.remoteStarts ?? [:]; starts[intent.id] = result; next.remoteStarts = starts
            if result.status == .started, let workout = result.workout {
                next.workouts.append(workout)
                if intent.recordWithHealth { next.healthRequestedIDs = (next.healthRequestedIDs ?? []) + [workout.id] }
            }
            // This single write is the remote-start exactly-once boundary.
            try save(next); archive = next
            if let workout = result.workout, result.status == .started {
                selectedWorkoutID = workout.id
                bridge.publishWorkout(workout)
                if intent.recordWithHealth { startHealth(workout) }
            }
            return result
        } catch { errorMessage = "The iPhone start request has not been confirmed. Watch storage could not save it."; return nil }
    }

    private func canStartOccurrence(_ id: String, intent: RemoteWorkoutStartIntent) -> Bool {
        guard let plan = bridge.receivedPlan, plan.id == intent.planID,
              let activation = bridge.receivedActivationDate,
              let occurrence = try? ScheduleExceptionSchedule.resolve(occurrenceID: id, plan: plan, activationDate: activation,
                exceptions: bridge.receivedScheduleExceptions, workouts: workouts.filter { $0.syncGeneration == intent.syncGeneration }) else { return false }
        return RemoteWorkoutStartResolver.matchesScheduledOccurrence(intent, occurrence: occurrence,
            occupiedIDs: Set(bridge.receivedRecordedOccurrences.map(\.id)))
    }

    private func handleProposal(_ operation: WorkoutOperation) -> WorkoutProposalResult? {
        guard storageAvailable else { return nil }
        guard let index = archive.workouts.firstIndex(where: { $0.id == operation.sessionID }),
              archive.workouts[index].ownerDeviceID == archive.deviceID,
              operation.originDeviceID != archive.deviceID,
              operation.syncGeneration == bridge.receivedSyncGeneration else {
            return .init(operation: operation, status: .rejected, workout: nil,
                issues: [.init(code: "ownerUnavailable", message: "This Watch cannot apply the change to that workout or workspace.")])
        }
        let original = archive.workouts[index]
        if let receipt = original.operationReceipts.first(where: { $0.id == operation.id }), receipt.operation == operation {
            return .init(operation: operation, status: receipt.status, workout: original, issues: receipt.issues)
        }
        if original.pendingOperations.contains(operation) {
            return .init(operation: operation, status: .buffered, workout: original,
                issues: [.init(code: "waitingForRevision", message: "The owner is waiting for an earlier workout revision.")])
        }
        let reduction = WorkoutReducer.apply(operation, to: original, at: Date())
        do {
            var next = archive; next.workouts[index] = reduction.session
            try save(next); archive = next
            bridge.publishWorkout(reduction.session)
            updateHealth(from: original, to: reduction.session)
            return .init(operation: operation, status: reduction.status, workout: reduction.session, issues: reduction.issues)
        } catch { errorMessage = "The iPhone change remains pending. Watch storage could not save it."; return nil }
    }

    private func startHealth(_ workout: WorkoutSession) {
        guard let health else { return }
        healthActions.insert(workout.id)
        Task { @MainActor in
            defer { healthActions.remove(workout.id) }
            let started = await health.start(workout: workout)
            saveHealthMessage(for: workout.id)
            guard started, let current = workouts.first(where: { $0.id == workout.id }) else { return }
            if current.syncGeneration != bridge.receivedSyncGeneration {
                await health.discard(workout: current); saveHealthMessage(for: workout.id)
            } else if current.state.isTerminal {
                await health.finish(workout: current); saveHealthMessage(for: workout.id)
            } else if current.state == .paused { health.pause() }
        }
    }
    private func updateHealth(from previous: WorkoutSession, to current: WorkoutSession) {
        guard previous.state != current.state, let health,
              health.ownsActiveSession, health.activeWorkoutID == current.id else { return }
        switch current.state {
        case .active: health.resume()
        case .paused: health.pause()
        case .finished, .abandoned:
            Task { @MainActor in
                await health.finish(workout: current)
                saveHealthMessage(for: current.id)
            }
        }
    }

    func entry(for set: WorkoutSet) -> WatchSetEntry { archive.drafts[set.id] ?? WatchSetEntry(values: set.actual) }
    func entry(for interval: WorkoutInterval) -> WatchSetEntry { archive.drafts[interval.id] ?? WatchSetEntry(values: interval.actual) }
    func hasDrafts(for exercise: WorkoutExercise) -> Bool {
        exercise.sets.contains { archive.drafts[$0.id] != nil || ($0.intervals ?? []).contains { archive.drafts[$0.id] != nil } }
    }
    func healthMessage(for id: UUID) -> String? {
        if let health, health.activeWorkoutID == id { return health.status }
        if let health, let workout = workouts.first(where: { $0.id == id }) {
            _ = health.status // Observe asynchronous journal reconciliation updates.
            if let state = health.exportState(for: workout) {
                switch state {
                case .saved: return "Workout saved to Apple Health."
                case .saving, .pendingVerification: return "Apple Health save is pending verification. No duplicate export will be attempted."
                case .discarded: return "Health recording discarded. Your workout log remains saved."
                case .failedBeforeSave: return "Apple Health was not saved. Your workout log remains saved."
                case .prepared, .recording: return archive.healthMessages?[id] ?? "Health recording needs recovery. Manual logging remains available."
                }
            }
        }
        return archive.healthMessages?[id]
    }
    func retryHealthExport(for workout: WorkoutSession) {
        guard let health, health.ownsActiveSession, health.activeWorkoutID == workout.id,
              health.exportState(for: workout) == .failedBeforeSave else { return }
        Task { @MainActor in
            await health.retryFailedExport(workout: workout)
            saveHealthMessage(for: workout.id)
        }
    }
    func verifyHealthExports() {
        guard let health else { return }
        Task { @MainActor in await health.reconcilePendingExports() }
    }
    private func saveHealthMessage(for id: UUID) {
        guard let health, storageAvailable else { return }
        do {
            var next = archive
            var messages = next.healthMessages ?? [:]; messages[id] = health.status
            next.healthMessages = messages
            try save(next); archive = next
        } catch { errorMessage = "The workout is saved. Its latest Apple Health status could not be saved." }
    }
    func saveEntry(_ entry: WatchSetEntry, for id: UUID) {
        guard storageAvailable else { return }
        do {
            var next = archive; next.drafts[id] = entry
            try save(next); archive = next
        } catch { errorMessage = "Your latest input has not been saved. Try again before leaving." }
    }
    private func save(_ value: WatchWorkoutArchive) throws {
        guard let fileURL else { throw WatchStoreError.invalidArchive }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 64 * 1_024 * 1_024 else { throw WatchStoreError.tooLarge }
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

struct WatchWorkoutArchive: Codable {
    var version = 1
    var deviceID = "watch-" + UUID().uuidString
    var workouts: [WorkoutSession] = []
    var drafts: [UUID: WatchSetEntry] = [:]
    var alertedRestIDs: [String]?
    var healthRequestedIDs: [UUID]?
    var healthMessages: [UUID: String]?
    var remoteStarts: [UUID: RemoteWorkoutStartResult]?
}

struct WatchSetEntry: Codable, Equatable {
    var reps = "", load = "", assistance = "", seconds = "", distance = "", calories = ""
    var rir = "", rpe = "", averageRpm = "", averageHeartRate = ""
    var loadUnit: PlanUnit = .kg
    var distanceUnit: PlanUnit = .m
    init(values: WorkoutSetValues) {
        func text(_ value: Double?) -> String { value.map { String(format: "%g", $0) } ?? "" }
        reps = values.reps.map(String.init) ?? ""; load = text(values.load?.value)
        assistance = text(values.assistance?.value); seconds = text(values.durationSeconds)
        distance = text(values.distance?.value); calories = text(values.calories)
        rir = values.rir.map(String.init) ?? ""; rpe = values.rpe.map(String.init) ?? ""
        averageRpm = text(values.averageRpm); averageHeartRate = text(values.averageHeartRate)
        loadUnit = values.load?.unit ?? values.assistance?.unit ?? .kg
        distanceUnit = values.distance?.unit ?? .m
    }
    func values() throws -> WorkoutSetValues {
        func number(_ text: String, _ label: String) throws -> Double? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            guard let value = Double(trimmed), value.isFinite else { throw WatchStoreError.invalidField(label) }
            return value
        }
        func integer(_ text: String, _ label: String) throws -> Int? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            guard let value = Int(trimmed) else { throw WatchStoreError.invalidField(label) }; return value
        }
        return try WorkoutSetValues(reps: integer(reps, "reps"),
            load: number(load, "load").map { PlanQuantity(value: $0, unit: loadUnit) },
            assistance: number(assistance, "assistance").map { PlanQuantity(value: $0, unit: loadUnit) },
            durationSeconds: number(seconds, "seconds"),
            distance: number(distance, "distance").map { PlanQuantity(value: $0, unit: distanceUnit) },
            calories: number(calories, "calories"), rir: integer(rir, "RIR"), rpe: integer(rpe, "RPE"),
            averageRpm: number(averageRpm, "average RPM"), averageHeartRate: number(averageHeartRate, "average heart rate"))
    }
}
private enum WatchStoreError: LocalizedError {
    case tooLarge, invalidArchive, invalidField(String)
    var errorDescription: String? {
        switch self {
        case .tooLarge: "The local storage limit was reached. Existing data has been retained."
        case .invalidArchive: "The saved workout archive is not compatible with this build."
        case .invalidField(let name): "Enter a number for \(name), or leave it unanswered."
        }
    }
}
