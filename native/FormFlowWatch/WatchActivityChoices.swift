import SwiftUI
import FormFlowCore

struct WatchActivityChoice: View {
    @Environment(WatchWorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID
    let exerciseID: UUID
    @State private var confirmingDraftReplacement = false
    @State private var pendingAlternativeID: String?
    private var exercise: WorkoutExercise? {
        store.workouts.first { $0.id == sessionID }?.exercises.first { $0.id == exerciseID }
    }
    private var canChoose: Bool {
        exercise?.sets.allSatisfy { set in
            set.status == .planned && set.actual.isEmpty && set.revision == 0 &&
            (set.intervals?.allSatisfy { $0.status == .planned && $0.actual.isEmpty && $0.revision == 0 } ?? true)
        } ?? false
    }
    var body: some View {
        List {
            if let exercise {
                Section {
                    Text("Planned: \(exercise.prescription.name)").font(.caption)
                    Text("Current: \(exercise.performedPrescription.name)").font(.headline)
                    Text(canChoose ? "Choose before recording any values. History keeps both the planned and performed activity."
                        : "An activity with saved values or recorded work cannot change variant.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section("Planned activity") {
                    Button { choose(nil) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(exercise.prescription.name)
                            Text(exercise.prescription.target.summary).font(.caption2)
                            if exercise.selectedAlternativeID == nil { Text("Selected").font(.caption2).foregroundStyle(.green) }
                        }
                    }.disabled(!canChoose || exercise.selectedAlternativeID == nil)
                }
                Section("Alternatives") {
                    ForEach(exercise.prescription.alternatives ?? []) { alternative in
                        Button { choose(alternative.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(alternative.name)
                                Text(alternative.target.summary).font(.caption2)
                                if exercise.selectedAlternativeID == alternative.id { Text("Selected").font(.caption2).foregroundStyle(.green) }
                            }
                        }.disabled(!canChoose || exercise.selectedAlternativeID == alternative.id)
                    }
                }
            } else { Text("Activity unavailable") }
        }
        .navigationTitle("Choose activity")
        .confirmationDialog("Replace input drafts?", isPresented: $confirmingDraftReplacement) {
            Button("Change activity") { saveChoice(pendingAlternativeID) }
            Button("Keep current activity", role: .cancel) {}
        } message: { Text("Unsubmitted inputs for the previous activity will be cleared. Completed results cannot be replaced this way.") }
    }
    private func choose(_ id: String?) {
        guard let exercise else { return }
        pendingAlternativeID = id
        if store.hasDrafts(for: exercise) { confirmingDraftReplacement = true }
        else { saveChoice(id) }
    }
    private func saveChoice(_ id: String?) {
        if store.apply(.chooseAlternative(exerciseID: exerciseID, alternativeID: id), to: sessionID) { dismiss() }
    }
}

struct WatchExtraActivityChoice: View {
    @Environment(WatchWorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID
    var body: some View {
        List {
            Section {
                Text("Add a saved activity").font(.headline)
                Text("Uses an activity and its targets from your cached plan. Adding it affects only this workout and creates no completed results.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let plan = store.bridge.receivedPlan {
                ForEach(Array(plan.days.flatMap(\.sessions).enumerated()), id: \.offset) { _, session in
                    Section(session.name) {
                        ForEach(session.exercises) { exercise in
                            Button { add(exercise) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(exercise.name)
                                    Text(exercise.target.summary).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Text("If a legacy activity has no typed targets, add or edit that activity on iPhone first.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else { Text("Sync a plan from iPhone to choose an extra activity.").font(.footnote) }
        }
        .navigationTitle("Extra activity")
    }
    private func add(_ exercise: PlanExercise) {
        var added = exercise
        added.instanceId = "extra-" + UUID().uuidString
        added.optional = false
        added.progressionPolicy = nil
        if store.apply(.addExtraExercise(exercise: added), to: sessionID) { dismiss() }
    }
}

struct WatchPreviousResults: View {
    let exposures: [WatchExerciseHistory]
    var body: some View {
        List {
            Section {
                Text("Observed actuals").font(.headline)
                Text("Recent comparable results cached from iPhone, in their original units. These are references, not today's targets or automatic entries.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(exposures) { exposure in
                Section(exposure.recordedAt.formatted(date: .abbreviated, time: .omitted)) {
                    Text(exposure.name).font(.headline)
                    if exposure.wasPartial { Text("Partial workout").font(.caption2).foregroundStyle(.orange) }
                    ForEach(Array(exposure.actuals.enumerated()), id: \.offset) { index, observation in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(observation.intervalKind.map { $0.rawValue.capitalized + " interval" } ?? "Set \(index + 1)").font(.caption2)
                            Text(observation.values.summary).font(.footnote)
                        }
                    }
                    if exposure.completedObservationCount > exposure.actuals.count {
                        Text("Showing \(exposure.actuals.count) of \(exposure.completedObservationCount) recorded results. Full details remain on iPhone.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }.navigationTitle("Previous results")
    }
}
