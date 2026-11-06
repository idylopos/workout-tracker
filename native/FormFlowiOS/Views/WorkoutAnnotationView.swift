import SwiftUI
import FormFlowCore

struct WorkoutAnnotationSection: View {
    @Environment(AppStore.self) private var store
    let workout: WorkoutSession
    var body: some View {
        Section("Record review") {
            WorkoutAnnotationLabel(workout: workout)
            NavigationLink("Review duplicate or interrupted recording") {
                WorkoutAnnotationView(sessionID: workout.id)
            }
        }
    }
}

struct WorkoutAnnotationLabel: View {
    @Environment(AppStore.self) private var store
    let workout: WorkoutSession
    var body: some View {
        if store.workoutAnnotations.isExcludedDuplicate(workout) {
            Label("Duplicate · excluded from app totals and coaching", systemImage: "doc.on.doc")
                .font(.caption).foregroundStyle(.secondary)
        }
        switch store.workoutAnnotations.interruptionState(workout) {
        case .ownerUnavailable:
            Label("Interrupted locally · recording device unavailable", systemImage: "applewatch.slash")
                .font(.caption).foregroundStyle(.orange)
        case .ownerUpdated:
            Label("Recording device sent an update · review interruption", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.orange)
        case .none: EmptyView()
        }
    }
}

struct WorkoutAnnotationView: View {
    @Environment(AppStore.self) private var store
    let sessionID: UUID
    @State private var selectedOriginalID: UUID?
    @State private var events: [WorkoutAnnotation] = []
    @State private var localError: String?
    @State private var separateConfirmation = false
    private var workout: WorkoutSession? { store.workouts.first { $0.id == sessionID } }
    private var originals: [WorkoutSession] {
        store.includedWorkouts.filter { $0.state.isTerminal && $0.id != sessionID }
    }

    var body: some View {
        Form {
            if let workout {
                Section {
                    Text(workout.prescription.name).font(.headline)
                    Text(workout.startedAt.formatted())
                    WorkoutAnnotationLabel(workout: workout)
                    Text("Review labels keep the original workout and all earlier decisions. They do not change Apple Health records.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if workout.state.isTerminal {
                    Section("Accidental duplicate") {
                        if store.workoutAnnotations.isExcludedDuplicate(workout) {
                            Text("This workout remains in history. Its results are excluded from app totals, progression comparisons, and recovery prompts.")
                            Button("Include this workout again") {
                                perform { try store.workoutAnnotations.restoreIncluded(workout: workout, reviewer: store.deviceID) }
                            }
                        } else {
                            Text("Choose the original saved workout. Marking this copy as a duplicate keeps its audit history and excludes its results from app totals and coaching.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Picker("Keep in totals", selection: $selectedOriginalID) {
                                Text("Choose original workout").tag(nil as UUID?)
                                ForEach(originals) { original in
                                    Text("\(original.prescription.name) · \(original.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .tag(Optional(original.id))
                                }
                            }
                            Button("Mark this copy as duplicate") {
                                guard let original = originals.first(where: { $0.id == selectedOriginalID }) else { return }
                                perform { try store.workoutAnnotations.markDuplicate(workout: workout, duplicateOf: original, reviewer: store.deviceID) }
                            }.disabled(selectedOriginalID == nil)
                            if originals.isEmpty { Text("A second terminal workout is needed before identifying a duplicate.").font(.caption) }
                        }
                    }
                }
                if workout.ownerDeviceID != store.deviceID && workout.syncGeneration == store.syncGeneration {
                    Section("Recording device unavailable") {
                        let state = store.workoutAnnotations.interruptionState(workout)
                        if state == .ownerUpdated {
                            Text("The recording device has sent newer workout data. The latest received record is shown; no completed work was discarded. Review both workouts if you started a separate recording.")
                            Button("Acknowledge the owner's update") {
                                perform { try store.workoutAnnotations.clearOwnerUnavailable(workout: workout, reviewer: store.deviceID) }
                            }
                        } else if state == .ownerUnavailable {
                            Text("The last received snapshot is retained as interrupted on this iPhone. It is not a finished workout or a new Health export. The original device may still be recording.")
                            Button("Recording device is available again") {
                                perform { try store.workoutAnnotations.clearOwnerUnavailable(workout: workout, reviewer: store.deviceID) }
                            }
                            Button("Start a separate iPhone workout") { separateConfirmation = true }
                        } else if !workout.state.isTerminal {
                            Text("Use this only when you cannot resume the original recording device. Keep its latest snapshot for review before choosing a separate iPhone recording.")
                            Button("Mark latest snapshot interrupted locally") {
                                perform { try store.workoutAnnotations.markOwnerUnavailable(workout: workout, reviewer: store.deviceID) }
                            }
                        }
                    }
                }
                if !events.isEmpty {
                    Section("Review history") {
                        ForEach(events) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(label(event.decision))
                                Text("Revision \(event.ownerRevision) · \(event.recordedAt.formatted())")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("Review device · \(event.reviewerDeviceID.suffix(8))").font(.caption)
                            }
                        }
                    }
                }
            }
            if let localError { Section { Text(localError).foregroundStyle(.orange) } }
            SaveErrorSection()
        }
        .navigationTitle("Review this record")
        .formFlowBackground()
        .task { reload() }
        .confirmationDialog("Start a separate recording? It gets its own workout identity and contains no sets copied from the interrupted device.", isPresented: $separateConfirmation, titleVisibility: .visible) {
            Button("Start a separate iPhone workout") { _ = store.startSeparatePhoneWorkout(after: sessionID) }
            Button("Keep reviewing", role: .cancel) {}
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); store.publishScheduleChanges(); localError = nil; reload() }
        catch { localError = error.localizedDescription }
    }
    private func reload() {
        guard let workout else { return }
        do { events = try store.workoutAnnotations.history(workout: workout) }
        catch { localError = error.localizedDescription }
    }
    private func label(_ decision: WorkoutAnnotation.Decision) -> String {
        switch decision {
        case .duplicate: "Marked duplicate; excluded from app totals"
        case .included: "Restored to app totals"
        case .ownerUnavailable: "Marked interrupted locally"
        case .ownerAvailable: "Acknowledged recording-device availability"
        }
    }
}
