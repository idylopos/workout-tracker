import SwiftUI
import FormFlowCore

struct WorkoutConflictReviewSection: View {
    let workout: WorkoutSession
    var body: some View {
        Section("Changes needing review") {
            ForEach(workout.conflicts) { conflict in
                NavigationLink {
                    WorkoutConflictReviewView(sessionID: workout.id, conflictID: conflict.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(conflict.operation.command.conflictSummary)
                        Text("Compare accepted and proposed values").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct WorkoutProposalStatusSection: View {
    @Environment(AppStore.self) private var store
    let workout: WorkoutSession
    var body: some View {
        Section("Proposed Watch changes") {
            ForEach(store.bridge.pendingWorkoutProposals.filter { $0.sessionID == workout.id }) { operation in
                VStack(alignment: .leading) {
                    Text("Change saved on iPhone · awaiting recording Watch")
                    Text(operation.createdAt.formatted()).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(store.bridge.workoutProposalResults.filter { $0.operation.sessionID == workout.id }) { result in
                let status = WorkoutProposalPresentation.status(result, in: workout)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(status))
                    Text(result.operation.command.conflictSummary).font(.caption)
                    Text(result.operation.createdAt.formatted()).font(.caption).foregroundStyle(.secondary)
                    if status == .conflict || status == .rejected {
                        ForEach(result.issues) { Text($0.message).font(.caption) }
                    }
                }
            }
            Button("Retry pending changes") { store.bridge.retry() }
        }
    }

    private func title(_ status: WorkoutReductionStatus) -> String {
        switch status {
        case .applied: "Watch confirmed the change"
        case .buffered, .duplicate: "Saved by Watch · waiting for earlier changes"
        case .conflict: "Change conflicts with accepted values · review below"
        case .rejected: "Change was not applied"
        }
    }
}

struct WorkoutConflictReviewView: View {
    @Environment(AppStore.self) private var store
    let sessionID: UUID
    let conflictID: String
    @State private var history: [WorkoutConflictReview] = []
    @State private var reviewedWorkout: WorkoutSession?
    @State private var values = WorkoutSetValues()
    @State private var localError: String?
    @State private var resultMessage: String?

    private var workout: WorkoutSession? { store.workouts.first { $0.id == sessionID } }
    private var conflict: WorkoutConflict? { workout?.conflicts.first { $0.id == conflictID } }

    var body: some View {
        Form {
            if let workout, let conflict {
                Section("Accepted when the conflict was recorded") {
                    Text(deviceLabel(workout.ownerDeviceID, owner: workout.ownerDeviceID))
                    if let receipt = workout.operationReceipts.first(where: { $0.operation == conflict.operation }) {
                        Text(receipt.processedAt.formatted()).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(conflict.acceptedSets) { set in
                        Text("\(set.status.rawValue.capitalized) · \(set.actual.summary)")
                        if let date = set.completedAt { Text("Completed \(date.formatted())").font(.caption) }
                        ForEach(set.intervals ?? []) { interval in
                            Text("\(interval.prescription.kind.rawValue.capitalized): \(interval.actual.summary)").font(.caption)
                        }
                    }
                    if conflict.acceptedSets.isEmpty { Text("Workout state at revision \(conflict.currentRevision)") }
                }
                Section("Proposed change") {
                    Text(conflict.operation.command.conflictSummary)
                    Text(deviceLabel(conflict.operation.originDeviceID, owner: workout.ownerDeviceID))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(conflict.operation.createdAt.formatted()).font(.caption)
                    Text("Based on revision \(conflict.operation.expectedRevision)").font(.caption)
                }
                Section("Latest accepted workout · revision \(workout.revision)") {
                    Text("\(workout.state.rawValue.capitalized) · updated \(workout.lastAppliedAt.formatted())")
                    ForEach(workout.exercises.flatMap(\.sets).filter { current in conflict.acceptedSets.contains { $0.id == current.id } }) { set in
                        Text("\(set.status.rawValue.capitalized) · \(set.actual.summary)")
                    }
                    Text("Keeping accepted values records your review. A new proposal uses the latest revision and still needs the recording device to confirm it. All earlier values remain in history.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Keep accepted") {
                        do {
                            try store.conflictReviews.keepAccepted(workout: workout, conflict: conflict, reviewer: store.deviceID)
                            reviewedWorkout = nil
                            resultMessage = "Accepted values kept. Your review was saved."
                            localError = nil
                            reloadHistory()
                        } catch { localError = error.localizedDescription }
                    }
                    Button(reviewedWorkout == nil ? "Review proposed" : "Review against latest accepted revision") {
                        values = conflict.operation.command.proposedValues ?? .init()
                        reviewedWorkout = workout
                        resultMessage = nil
                    }
                }
                if let reviewedWorkout {
                    Section("Review before submitting") {
                        if let measurement = conflict.operation.command.measurement(in: reviewedWorkout) {
                            ConflictActualValuesEditor(values: $values, measurement: measurement)
                        } else { Text(conflict.operation.command.conflictSummary) }
                        if reviewedWorkout != workout {
                            Text("The recording device has updated this workout. Review the latest accepted revision before submitting.")
                                .foregroundStyle(.orange)
                        }
                        Button(workout.ownerDeviceID == store.deviceID ? "Save as a new correction" : "Send as a new proposal") {
                            submit(reviewedWorkout, conflict: conflict)
                        }.disabled(reviewedWorkout != workout)
                    }
                }
                if !history.isEmpty {
                    Section("Review history") {
                        ForEach(history) { review in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(review.choice == .keptAccepted ? "Kept accepted values" : reviewStatus(review, workout: workout))
                                Text("Revision \(review.reviewedRevision) · \(review.reviewedAt.formatted())").font(.caption)
                                Text(deviceLabel(review.reviewerDeviceID, owner: workout.ownerDeviceID)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let resultMessage { Section { Text(resultMessage) } }
            if let localError { Section { Text(localError).foregroundStyle(.orange) } }
            SaveErrorSection()
        }
        .navigationTitle("Review a conflict")
        .formFlowBackground()
        .task { reloadHistory() }
    }

    private func submit(_ reviewed: WorkoutSession, conflict: WorkoutConflict) {
        do {
            let operation = try store.conflictReviews.prepareProposed(workout: reviewed, conflict: conflict,
                reviewer: store.deviceID, values: conflict.operation.command.proposedValues == nil ? nil : values)
            guard store.submitReviewedWorkoutOperation(operation) else {
                reloadHistory()
                resultMessage = "The review is saved, but the proposal has not been applied. Review the latest values before trying again."
                return
            }
            resultMessage = reviewed.ownerDeviceID == store.deviceID
                ? "Correction saved. The original conflict remains in history."
                : "New proposal saved on iPhone. Awaiting the recording Watch."
            reviewedWorkout = nil
            localError = nil
            reloadHistory()
        } catch { localError = error.localizedDescription }
    }

    private func reloadHistory() {
        do { history = try store.conflictReviews.history(sessionID: sessionID).filter { $0.conflictID == conflictID } }
        catch { localError = error.localizedDescription }
    }

    private func reviewStatus(_ review: WorkoutConflictReview, workout: WorkoutSession) -> String {
        guard let operation = review.replacementOperation else { return "Prepared a new proposal" }
        if let receipt = workout.operationReceipts.first(where: { $0.operation == operation }) {
            return receipt.status == .applied ? "New proposal accepted by recording device" : "New proposal was not applied · \(receipt.status.rawValue)"
        }
        if store.bridge.pendingWorkoutProposals.contains(operation) || workout.pendingOperations.contains(operation) {
            return "New proposal awaiting recording device"
        }
        return "Prepared a new proposal · acceptance not confirmed"
    }

    private func deviceLabel(_ id: String, owner: String) -> String {
        let name = id == store.deviceID ? "This iPhone" : id == owner ? "Recording Watch" : "Companion device"
        return "\(name) · \(id.suffix(8))"
    }
}

private struct ConflictActualValuesEditor: View {
    @Environment(AppStore.self) private var store
    @Binding var values: WorkoutSetValues
    let measurement: MeasurementKind
    var body: some View {
        if [.weightReps, .weightDistance].contains(measurement) { quantity("Load", value: $values.load, units: [.kg, .lb]) }
        if measurement == .assistedReps { quantity("Assistance", value: $values.assistance, units: [.kg, .lb]) }
        if [.weightReps, .reps, .assistedReps].contains(measurement) {
            TextField("Repetitions", value: $values.reps, format: .number).keyboardType(.numberPad)
            TextField("Reps left (RIR)", value: $values.rir, format: .number).keyboardType(.numberPad)
        }
        if [.duration, .durationCalories, .distanceTime, .distance].contains(measurement) {
            TextField("Duration in seconds", value: $values.durationSeconds, format: .number).keyboardType(.decimalPad)
            quantity("Distance", value: $values.distance, units: [.m, .km, .mi])
            TextField("Calories (optional)", value: $values.calories, format: .number).keyboardType(.decimalPad)
            TextField("Average RPM (optional)", value: $values.averageRpm, format: .number).keyboardType(.decimalPad)
            TextField("Average heart rate (optional)", value: $values.averageHeartRate, format: .number).keyboardType(.decimalPad)
            EffortPicker(value: $values.rpe)
        }
        if measurement == .weightDistance { quantity("Distance", value: $values.distance, units: [.m, .km, .mi]) }
        if measurement == .completion { Text("Confirm only work you actually completed.") }
    }

    private func quantity(_ label: String, value: Binding<PlanQuantity?>, units: [PlanUnit]) -> some View {
        let defaultUnit: PlanUnit = units.contains(.kg) ? (store.profile.units == .metric ? .kg : .lb) : .m
        return HStack {
            TextField(label, value: Binding<Double?>(get: { value.wrappedValue?.value }, set: { number in
                value.wrappedValue = number.map { .init(value: $0, unit: value.wrappedValue?.unit ?? defaultUnit) }
            }), format: .number).keyboardType(.decimalPad)
            Picker("\(label) unit", selection: Binding(get: { value.wrappedValue?.unit ?? defaultUnit }, set: { unit in
                if let number = value.wrappedValue?.value { value.wrappedValue = .init(value: number, unit: unit) }
            })) { ForEach(units, id: \.rawValue) { Text($0.rawValue).tag($0) } }
            .labelsHidden()
        }
    }
}

private extension WorkoutCommand {
    var proposedValues: WorkoutSetValues? {
        switch self {
        case .updateSet(_, let values), .logSet(_, let values), .updateInterval(_, _, let values), .logInterval(_, _, let values): values
        default: nil
        }
    }
    var conflictSummary: String {
        switch self {
        case .updateSet(_, let values), .logSet(_, let values): values.summary
        case .updateInterval(_, _, let values), .logInterval(_, _, let values): "Interval · \(values.summary)"
        case .skipSet(_, let reason), .skipInterval(_, _, let reason): "Skip · \(reason ?? "No reason supplied")"
        case .undoSet, .undoInterval: "Undo completion or skip"
        case .pause: "Pause workout"
        case .resume: "Resume workout"
        case .finish(let partial): partial ? "Finish partial workout" : "Finish workout"
        case .abandon: "Abandon workout"
        case .skipRest: "Skip rest"
        case .extendRest(let seconds): "Extend rest by \(seconds) seconds"
        case .chooseAlternative: "Choose exercise alternative"
        case .addExtraExercise(let exercise): "Add \(exercise.name)"
        case .copyLast: "Copy previous exercise values"
        case .fillEmptySets: "Fill empty sets from entered values"
        case .setExerciseEnabled(_, let enabled): enabled ? "Include optional exercise" : "Exclude optional exercise"
        }
    }
    func measurement(in workout: WorkoutSession) -> MeasurementKind? {
        switch self {
        case .updateSet(let setID, _), .logSet(let setID, _):
            return workout.exercises.first { $0.sets.contains { $0.id == setID } }?.performedPrescription.measurement
        case .updateInterval(let setID, let id, _), .logInterval(let setID, let id, _):
            return workout.exercises.flatMap(\.sets).first { $0.id == setID }?.intervals?.first { $0.id == id }?.prescription.measurement
        default: return nil
        }
    }
}
