import SwiftUI
import FormFlowCore

/// The deadline remains visible outside the scrolling workout/result forms.
struct WorkoutRestBar: View {
    @Environment(AppStore.self) private var store
    let sessionID: UUID
    private var workout: WorkoutSession? { store.workouts.first { $0.id == sessionID } }

    var body: some View {
        if let workout, !workout.state.isTerminal, !store.isRetiredIncomplete(workout), let rest = workout.rest {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 12) {
                    TimelineView(.periodic(from: Date(), by: 1)) { context in
                        Text(rest.isExpired(at: context.date) ? "Rest complete" : "Rest · \(remaining(rest.remaining(at: context.date)))")
                            .font(.headline.monospacedDigit())
                            .accessibilityIdentifier("workout-rest-status")
                    }
                    Spacer(minLength: 0)
                    if workout.ownerDeviceID == store.deviceID {
                        Menu {
                            Button("Skip rest") { command(.skipRest) }
                            Button("Add 30 seconds") { command(.extendRest(seconds: 30)) }
                            Button("Undo logged set") { command(.undoSet(setID: rest.setID)) }
                                .disabled(workout.state == .paused)
                        } label: {
                            Label("Rest actions", systemImage: "ellipsis.circle")
                                .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("workout-rest-actions")
                    }
                }
                if workout.state == .paused {
                    Text("Rest continues while paused.").font(.caption).foregroundStyle(.secondary)
                }
                if workout.ownerDeviceID != store.deviceID {
                    Text("Latest rest deadline received from Watch.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(.regularMaterial)
        }
    }
    private func remaining(_ seconds: TimeInterval) -> String {
        let value = Int(ceil(seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
    private func command(_ value: WorkoutCommand) { store.applyWorkoutCommand(value, sessionID: sessionID) }
}

struct WorkoutSkipSetView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID
    let setID: UUID
    @State private var reason = ""
    private var workout: WorkoutSession? { store.workouts.first { $0.id == sessionID } }
    private var exercise: WorkoutExercise? { workout?.exercises.first { $0.sets.contains { $0.id == setID } } }
    private var set: WorkoutSet? { exercise?.sets.first { $0.id == setID } }
    private var canSkip: Bool {
        workout.map { !store.isRetiredIncomplete($0) } == true && workout?.ownerDeviceID == store.deviceID && workout?.state == .active && set?.status == .planned && reason.count <= 500
    }
    var body: some View {
        Form {
            if let exercise, let set {
                Section {
                    Text(exercise.performedPrescription.name).font(.headline)
                    Text("Set \((exercise.sets.firstIndex { $0.id == setID } ?? 0) + 1) · \(set.target.summary)")
                    Text("Skipping keeps any entered measurements and marks this set as unperformed. You can undo the skip from the workout.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Reason · optional") {
                    TextField("Anything you want to remember", text: $reason, axis: .vertical).lineLimit(2...5)
                        .accessibilityIdentifier("skip-set-reason")
                    if reason.count > 500 { Text("Keep the reason to 500 characters or fewer.").foregroundStyle(.red) }
                }
                Section {
                    Button("Skip this set") {
                        let supplied = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                        if store.applyWorkoutCommand(.skipSet(setID: setID, reason: supplied.isEmpty ? nil : supplied), sessionID: sessionID) { dismiss() }
                    }.buttonStyle(PrimaryActionStyle()).disabled(!canSkip)
                        .accessibilityIdentifier("confirm-skip-set")
                }
            } else {
                ContentUnavailableView("Set unavailable", systemImage: "exclamationmark.circle")
            }
            SaveErrorSection()
        }
        .navigationTitle("Skip set")
        .formFlowBackground()
        .scrollDismissesKeyboard(.interactively)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .safeAreaInset(edge: .bottom) { WorkoutRestBar(sessionID: sessionID) }
    }
}
