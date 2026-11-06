import SwiftUI
import FormFlowCore

struct WorkoutReadyView: View {
    @Environment(AppStore.self) private var store
    let scheduled: ScheduledPlanSession
    @State private var recordHealth = false
    @State private var separatePhoneConfirmation = false

    var body: some View {
        List {
            Section {
                Text(scheduled.session.name).font(.title2.bold())
                Text(scheduled.date.formatted(date: .complete, time: .omitted))
                Text(sessionDurationSummary(scheduled.session)).foregroundStyle(.secondary)
                Text("You can log your workout without granting Health access. Values you enter are saved on this iPhone.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if store.currentWorkout == nil {
                    Toggle("Record with Apple Health", isOn: $recordHealth)
                    Text("When enabled, request workout permissions and save this workout to Health. Available heart rate and energy readings appear during recording.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(store.currentWorkout == nil ? "Start on iPhone" : "Continue current workout") {
                    if store.bridge.remoteStartIntents.contains(where: { $0.scheduledSessionID == scheduled.id }) {
                        separatePhoneConfirmation = true
                    } else { startPhone() }
                }.buttonStyle(PrimaryActionStyle())
                    .accessibilityIdentifier("start-workout")
                if store.bridge.canRequestWatchStart && store.currentWorkout == nil {
                    Button("Start on Watch") { store.requestWatchStart(scheduled, recordHealth: recordHealth) }
                }
                ForEach(store.bridge.remoteStartIntents.filter { $0.scheduledSessionID == scheduled.id }) { intent in
                    Text(store.bridge.remoteStartStatus(for: intent.id)).font(.caption)
                    Button("Check Watch start request") { store.bridge.reconcileWatchStart(intent.id) }
                }
                if !Calendar.current.isDateInToday(scheduled.date) {
                    Text("Starting now records today's actual workout time and keeps its link to the scheduled session.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Warm-up") {
                if scheduled.session.warmup.isEmpty { Text("No warm-up supplied.").foregroundStyle(.secondary) }
                ForEach(Array(scheduled.session.warmup.enumerated()), id: \.offset) { _, step in Text(step) }
            }
            Section("Planned work") {
                ForEach(scheduled.session.exercises) { exercise in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(exercise.name).font(.headline)
                        Text(exercise.target.summary).foregroundStyle(.secondary)
                        if exercise.optional { Text("Optional · starts unselected").font(.caption) }
                    }
                }
            }
            NavigationLink("Full session instructions") { PlanSessionDetailView(session: scheduled.session) }
            NavigationLink("Change this occurrence’s date or status") { ScheduleOccurrenceView(occurrenceID: scheduled.id) }
            SaveErrorSection()
        }
        .navigationTitle("Before you begin")
        .formFlowBackground()
        .confirmationDialog("The Watch may already be recording. Start a separate iPhone workout only if you want a second record.", isPresented: $separatePhoneConfirmation, titleVisibility: .visible) {
            Button("Start a separate iPhone workout") { startPhone() }
            Button("Keep waiting for Watch", role: .cancel) {}
        }
    }

    private func startPhone() { store.startWorkout(scheduled.session, scheduledID: scheduled.id,
        scheduledDate: scheduled.date, recordHealth: recordHealth) }
}

struct WorkoutSessionView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID
    @State private var finishConfirmation = false
    @State private var abandonConfirmation = false
    @State private var skipSetID: UUID?

    private var workout: WorkoutSession? { store.workouts.first { $0.id == sessionID } }

    var body: some View {
        Group {
            if let workout {
                List {
                    overviewSection(workout)
                    if !store.isRetiredIncomplete(workout) { WorkoutAnnotationSection(workout: workout) }
                    if workout.usesThursdayLegCurl && !workout.state.isTerminal {
                        Section("Warm-up") {
                            ForEach(Array(workout.recordingWarmup.enumerated()), id: \.offset) { _, step in Text(step) }
                        }
                    }
                    ForEach(workout.recordingExercises) { exercise in
                        exerciseSection(exercise, workout: workout)
                    }
                    if workout.ownerDeviceID != store.deviceID && workout.syncGeneration == store.syncGeneration {
                        WorkoutProposalStatusSection(workout: workout)
                    }
                    controlsSection(workout)
                    conflictsSection(workout)
                    SaveErrorSection()
                }
            } else {
                ContentUnavailableView("Workout unavailable", systemImage: "figure.strengthtraining.traditional")
            }
        }
        .formFlowBackground()
        .safeAreaInset(edge: .bottom) { WorkoutRestBar(sessionID: sessionID) }
        .sheet(isPresented: Binding(get: { skipSetID != nil }, set: { if !$0 { skipSetID = nil } })) {
            if let skipSetID { NavigationStack { WorkoutSkipSetView(sessionID: sessionID, setID: skipSetID) } }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Close") { dismiss() }
                    .accessibilityIdentifier("workout-close")
            }
        }
        .confirmationDialog("Finish this partial workout? Unperformed sets will stay separate from completed work.", isPresented: $finishConfirmation, titleVisibility: .visible) {
            Button("Save partial workout") { command(.finish(allowPartial: true)) }
                .accessibilityIdentifier("save-partial-workout")
        }
        .confirmationDialog("Abandon this workout? Your recorded sets will remain in history, labeled abandoned.", isPresented: $abandonConfirmation, titleVisibility: .visible) {
            Button("Abandon workout", role: .destructive) { command(.abandon) }
        }
    }

    private var navigationTitle: String {
        guard let workout else { return "Your workout" }
        if store.isRetiredIncomplete(workout) { return "Archived workout" }
        return workout.state.isTerminal ? "Workout review" : "Your workout"
    }

    private func overviewSection(_ workout: WorkoutSession) -> some View {
        Section {
            Text(workout.prescription.name).font(.title2.bold())
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                let referenceDate = !store.isRetiredIncomplete(workout) && workout.ownerDeviceID == store.deviceID
                    ? context.date : workout.lastAppliedAt
                LabeledContent(workout.state == .paused ? "Paused · active time" : "Active time",
                               value: elapsedText(workout.elapsed(at: referenceDate)))
            }
            LabeledContent("Sets recorded", value: "\(workout.completedSetCount) of \(workout.plannedSetCount)")
            recordingStatus(workout)
            healthStatus(workout)
        }
    }

    @ViewBuilder private func recordingStatus(_ workout: WorkoutSession) -> some View {
        if store.isRetiredIncomplete(workout) {
            Label("Archived incomplete · older workspace", systemImage: "archivebox")
            Text("This is a read-only record of the last saved values. Its elapsed time is frozen at the last accepted change. It is not a current recording and does not block a new workout.")
                .font(.caption).foregroundStyle(.secondary)
        } else if workout.ownerDeviceID != store.deviceID {
            Text("Recorded on another device. This is the latest copy saved on iPhone. Proposed edits are confirmed by the recording Watch.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if workout.state.isTerminal {
            Label(workout.state == .abandoned ? "Abandoned" : workout.isPartial ? "Partial workout saved" : "Workout saved", systemImage: "checkmark.circle")
        } else if !store.isRetiredIncomplete(workout) && workout.ownerDeviceID == store.deviceID {
            Text(store.health?.activeWorkoutID == workout.id ? store.health?.status ?? "Manual recording" : "Saved on this iPhone. Recording sets manually.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func healthStatus(_ workout: WorkoutSession) -> some View {
        if !store.isRetiredIncomplete(workout), let health = store.health, health.activeWorkoutID == workout.id {
            LabeledContent("Heart rate", value: health.heartRate.map { "\(Int($0)) bpm" } ?? "Unavailable")
            LabeledContent("Active energy", value: health.activeEnergyKilocalories.map { "\(Int($0)) kcal" } ?? "Unavailable")
        }
        if workout.state.isTerminal, let state = store.health?.exportState(for: workout) {
            LabeledContent("Health export", value: state.rawValue)
            if state == .failedBeforeSave {
                Button("Retry Health export") { Task { await store.health?.retryFailedExport(workout: workout) } }
            }
        }
    }

    @ViewBuilder private func controlsSection(_ workout: WorkoutSession) -> some View {
        if !workout.state.isTerminal && !store.isRetiredIncomplete(workout) && workout.ownerDeviceID == store.deviceID {
            Section("Session controls") {
                NavigationLink("Add extra activity") { ExtraActivityView(sessionID: workout.id) }
                Button(workout.state == .paused ? "Resume workout" : "Pause workout") {
                    let action: WorkoutCommand = workout.state == .paused ? .resume : .pause
                    command(action)
                }
                Button("Finish workout") {
                    if workout.hasIncompleteWork { finishConfirmation = true }
                    else { command(.finish(allowPartial: false)) }
                }.buttonStyle(PrimaryActionStyle())
                    .accessibilityIdentifier("finish-workout")
                Button("Abandon workout", role: .destructive) { abandonConfirmation = true }
            }
        }
    }

    @ViewBuilder private func conflictsSection(_ workout: WorkoutSession) -> some View {
        if !workout.conflicts.isEmpty {
            if store.isRetiredIncomplete(workout) {
                Section("Retained competing values") {
                    ForEach(workout.conflicts) { conflict in
                        Text(conflict.operation.command.proposedSummary)
                        Text("Proposed \(conflict.operation.createdAt.formatted())").font(.caption)
                        ForEach(conflict.acceptedSets) { set in
                            Text("Accepted: \(set.actual.summary)").font(.caption)
                        }
                    }
                }
            } else { WorkoutConflictReviewSection(workout: workout) }
        }
    }

    @ViewBuilder private func exerciseSection(_ exercise: WorkoutExercise, workout: WorkoutSession) -> some View {
        Section(exercise.performedPrescription.name) {
            if exercise.selectedAlternativeID != nil {
                Text("Originally planned: \(exercise.prescription.name)").font(.caption).foregroundStyle(.secondary)
            }
            if let alternatives = exercise.prescription.alternatives, !alternatives.isEmpty,
               !workout.state.isTerminal && !store.isRetiredIncomplete(workout) && workout.ownerDeviceID == store.deviceID {
                Menu("Choose exercise alternative") {
                    Button(exercise.prescription.name) { command(.chooseAlternative(exerciseID: exercise.id, alternativeID: nil)) }
                    ForEach(alternatives) { alternative in
                        Button(alternative.name) { command(.chooseAlternative(exerciseID: exercise.id, alternativeID: alternative.id)) }
                    }
                }
                .disabled(exercise.sets.contains { !$0.actual.isEmpty || $0.status != .planned || ($0.intervals?.contains { !$0.actual.isEmpty || $0.status != .planned } ?? false) })
                Text("Choose an alternative before entering results. Each option keeps its own prescribed measurements.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Target: \(exercise.performedPrescription.target.summary)").font(.subheadline).foregroundStyle(.secondary)
            if let instructions = exercise.performedPrescription.instructions { Text(instructions).font(.subheadline) }
            if exercise.performedPrescription.optional && !workout.state.isTerminal && !store.isRetiredIncomplete(workout) && workout.ownerDeviceID == store.deviceID {
                Toggle("Include optional exercise", isOn: Binding(get: { exercise.isEnabled }, set: {
                    command(.setExerciseEnabled(exerciseID: exercise.id, enabled: $0))
                }))
            }
            if exercise.isEnabled || workout.state.isTerminal || store.isRetiredIncomplete(workout) {
                if let previous = store.previousExercise(for: exercise, before: workout) {
                    let last = previous.sets.last { $0.status == .completed }
                    Text("Previous: \(last?.actual.summary ?? "No comparable values")").font(.caption).foregroundStyle(.secondary)
                    if !workout.state.isTerminal && !store.isRetiredIncomplete(workout) && workout.ownerDeviceID == store.deviceID {
                        Button("Use last values") { command(.copyLast(exerciseID: exercise.id, previous: previous)) }
                        Text("Copies measurements into this session's planned rows and clears completion and effort. Existing entries will be replaced.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                    VStack(alignment: .leading, spacing: 8) {
                        NavigationLink {
                            WorkoutSetEntryView(sessionID: sessionID, exerciseID: exercise.id, setID: set.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Set \(index + 1) · \(set.status.rawValue.capitalized)").font(.headline)
                                Text(set.actual.summary).font(.subheadline).foregroundStyle(.secondary)
                                if let reason = set.skipReason { Text(reason).font(.caption) }
                            }
                        }.disabled(!store.isRetiredIncomplete(workout) && workout.ownerDeviceID != store.deviceID && workout.syncGeneration != store.syncGeneration)
                            .accessibilityIdentifier("workout-set-\(workout.exercises.firstIndex(where: { $0.id == exercise.id }) ?? 0)-\(index)")
                        if !workout.state.isTerminal && !store.isRetiredIncomplete(workout) && workout.state != .paused && workout.ownerDeviceID == store.deviceID {
                            if set.status == .planned && (set.actual.hasPrimaryValues || exercise.performedPrescription.measurement == .completion) {
                                Button("Log set") { command(.logSet(setID: set.id, values: set.actual)) }
                                    .buttonStyle(PrimaryActionStyle())
                            }
                            if set.status == .completed || set.status == .skipped {
                                Button(set.status == .skipped ? "Undo skip" : "Undo completion") { command(.undoSet(setID: set.id)) }
                                    .buttonStyle(.borderless)
                            } else if set.status == .planned {
                                Button("Skip set") { skipSetID = set.id }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }.padding(.vertical, 4)
                }
                if !workout.state.isTerminal && !store.isRetiredIncomplete(workout) && workout.ownerDeviceID == store.deviceID {
                    Button("Fill empty sets from my last entered values") { command(.fillEmptySets(exerciseID: exercise.id)) }
                }
            }
            if workout.state == .finished {
                NavigationLink("Review progression") { ProgressionReviewView(workout: workout, exercise: exercise) }
            }
        }
    }

    private func command(_ value: WorkoutCommand) { store.applyWorkoutCommand(value, sessionID: sessionID) }
}

struct WorkoutSetEntryView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID
    let exerciseID: UUID
    let setID: UUID
    @State private var values = WorkoutSetValues()
    @State private var loaded = false
    @State private var unitsByField: [String: PlanUnit] = [:]
    @State private var remoteDraft: RemoteSetDraft?
    @State private var replaceDraftConfirmation = false

    private var workout: WorkoutSession? { store.workouts.first { $0.id == sessionID } }
    private var exercise: WorkoutExercise? { workout?.exercises.first { $0.id == exerciseID } }
    private var currentSet: WorkoutSet? { exercise?.sets.first { $0.id == setID } }
    private var isCorrection: Bool { currentSet?.status == .completed || workout?.state.isTerminal == true }
    private var isRemote: Bool { workout.map { $0.ownerDeviceID != store.deviceID } ?? false }
    private var isRetired: Bool { workout.map { store.isRetiredIncomplete($0) } ?? false }

    var body: some View {
        Form {
            if let exercise, let set = currentSet {
                if isRetired {
                    ArchivedWorkoutSetResultView(exercise: exercise, set: set)
                } else {
                    Section {
                        Text(exercise.performedPrescription.name).font(.headline)
                        Text("Target: \(set.target.summary)").foregroundStyle(.secondary)
                        Text("Enter what you actually did. Missing values stay unknown.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if set.status == .skipped {
                        Section {
                            Text(set.skipReason.map { "Skipped · \($0)" } ?? "Skipped without a reason")
                            if !isRemote && workout?.state == .active {
                                Button("Undo skip") { store.applyWorkoutCommand(.undoSet(setID: setID), sessionID: sessionID) }
                            }
                        }
                    }
                    Section("Actual result") {
                        let kind = exercise.performedPrescription.measurement
                        if [.weightReps, .weightDistance].contains(kind) { quantityField("Load", value: $values.load, units: [.kg, .lb]) }
                        if kind == .assistedReps { quantityField("Assistance", value: $values.assistance, units: [.kg, .lb]) }
                        if [.weightReps, .reps, .assistedReps].contains(kind) {
                            TextField("Repetitions", value: $values.reps, format: .number).keyboardType(.numberPad)
                                .accessibilityIdentifier("actual-reps")
                        }
                        if [.duration, .durationCalories, .distanceTime, .distance].contains(kind) {
                            TextField("Duration in seconds", value: $values.durationSeconds, format: .number).keyboardType(.decimalPad)
                        }
                        if [.weightDistance, .distance, .distanceTime, .duration, .durationCalories].contains(kind) {
                            quantityField("Distance", value: $values.distance, units: [.m, .km, .mi])
                        }
                        if [.duration, .durationCalories, .distance, .distanceTime].contains(kind) {
                            TextField("Calories (optional)", value: $values.calories, format: .number).keyboardType(.decimalPad)
                            TextField("Average RPM (optional)", value: $values.averageRpm, format: .number).keyboardType(.decimalPad)
                            TextField("Average heart rate (optional)", value: $values.averageHeartRate, format: .number).keyboardType(.decimalPad)
                        }
                        if kind == .completion { Text("Log completion when this activity is done.") }
                    }
                    if let intervals = set.intervals, !intervals.isEmpty {
                        Section("Intervals") {
                            Text("Record each interval, then enter the overall result above and finish this set explicitly.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(intervals) { interval in
                                NavigationLink {
                                    WorkoutIntervalEntryView(sessionID: sessionID, setID: setID, intervalID: interval.id)
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text("\(interval.prescription.kind.rawValue.capitalized) · round \(interval.repetition)")
                                        Text(interval.prescription.target.summary).font(.caption)
                                        Text("\(interval.status.rawValue.capitalized) · \(interval.actual.summary)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }.disabled(isRemote)
                            }
                        }
                    }
                    if exercise.performedPrescription.measurement != .completion {
                        Section("Effort · optional") {
                            if [.weightReps, .weightDistance, .reps, .assistedReps].contains(exercise.performedPrescription.measurement) {
                                TextField("Reps left (RIR, 0–10)", value: $values.rir, format: .number).keyboardType(.numberPad)
                            } else {
                                EffortPicker(value: $values.rpe)
                            }
                        }
                    }
                    Section {
                        Button(isRemote ? "Send proposed result to Watch" : isCorrection ? "Save correction" : "Log set") {
                            if isRemote, var draft = remoteDraft {
                                draft.values = values
                                if store.submitRemoteSetDraft(draft) { dismiss() }
                                return
                            }
                            let command: WorkoutCommand = isCorrection ? .updateSet(setID: setID, values: values) : .logSet(setID: setID, values: values)
                            if store.applyWorkoutCommand(command, sessionID: sessionID) { dismiss() }
                        }.buttonStyle(PrimaryActionStyle())
                            .accessibilityIdentifier("log-set")
                            .disabled(workout?.state == .paused || workout?.state == .abandoned || (currentSet?.status == .skipped && !isCorrection))
                        if isRemote {
                            Text("This draft is saved on iPhone. The recording Watch checks its original revision before applying it. If the Watch has changed the set, both values remain available for review.")
                                .font(.caption).foregroundStyle(.secondary)
                            if let remoteDraft {
                                Text("Draft revision \(remoteDraft.baseRevision) · latest received revision \(workout?.revision ?? remoteDraft.baseRevision)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Use latest accepted values") { replaceDraftConfirmation = true }
                        } else if !isCorrection {
                            Text("Your entered values save as a draft. Log set marks the work complete and starts rest.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            SaveErrorSection()
        }
        .safeAreaInset(edge: .bottom) { WorkoutRestBar(sessionID: sessionID) }
        .navigationTitle(isRetired ? "Archived result" : isCorrection ? "Edit actual result" : "Record set")
        .formFlowBackground()
        .scrollDismissesKeyboard(.interactively)
        .confirmationDialog("Replace this draft with the latest accepted values? Earlier submitted proposals remain in the audit history.", isPresented: $replaceDraftConfirmation, titleVisibility: .visible) {
            Button("Use latest accepted values") {
                guard !isRetired, let workout else { return }
                do {
                    let fresh = try RemoteSetDraft.usingLatestAcceptedValues(workout: workout, setID: setID)
                    if store.saveRemoteSetDraft(fresh) {
                        remoteDraft = fresh
                        values = fresh.values
                    }
                } catch { store.errorMessage = error.localizedDescription }
            }
        }
        .task {
            if !loaded, !isRetired, let set = currentSet, let workout {
                if isRemote {
                    let draft = store.remoteSetDraft(sessionID: sessionID, setID: setID) ?? RemoteSetDraft(
                        sessionID: sessionID, setID: setID, syncGeneration: workout.syncGeneration,
                        baseRevision: workout.revision, markComplete: set.status == .planned,
                        values: set.actual, createdAt: Date())
                    remoteDraft = draft
                    values = draft.values
                } else { values = set.actual }
                loaded = true
            }
        }
        .onChange(of: values) {
            guard !isRetired else { return }
            if loaded && isRemote, var draft = remoteDraft {
                guard draft.values != values else { return }
                draft.values = values
                draft.operationID = UUID()
                draft.createdAt = Date()
                remoteDraft = draft
                store.saveRemoteSetDraft(draft)
            } else if loaded && !isCorrection && values != currentSet?.actual {
                store.applyWorkoutCommand(.updateSet(setID: setID, values: values), sessionID: sessionID)
            }
        }
    }

    private func quantityField(_ title: String, value: Binding<PlanQuantity?>, units: [PlanUnit]) -> some View {
        let preferred: PlanUnit = units.contains(.kg) ? (store.profile.units == .metric ? .kg : .lb) : (store.profile.units == .metric ? .km : .mi)
        return HStack {
            TextField(title, value: Binding<Double?>(get: { value.wrappedValue?.value }, set: { number in
                value.wrappedValue = number.map { PlanQuantity(value: $0, unit: value.wrappedValue?.unit ?? unitsByField[title] ?? preferred) }
            }), format: .number).keyboardType(.decimalPad)
                .accessibilityIdentifier("actual-\(title.lowercased())")
            Picker("\(title) unit", selection: Binding(get: { value.wrappedValue?.unit ?? unitsByField[title] ?? preferred }, set: { unit in
                unitsByField[title] = unit
                if let number = value.wrappedValue?.value { value.wrappedValue = PlanQuantity(value: number, unit: unit) }
            })) {
                ForEach(units, id: \.rawValue) { Text($0.rawValue).tag($0) }
            }.labelsHidden().fixedSize()
        }
    }
}

private struct ArchivedWorkoutSetResultView: View {
    let exercise: WorkoutExercise
    let set: WorkoutSet
    var body: some View {
        Section("Archived result · read only") {
            Text(exercise.performedPrescription.name).font(.headline)
            Text("Target: \(set.target.summary)").foregroundStyle(.secondary)
            Text(set.actual.summary)
            Text(set.status.rawValue.capitalized).font(.caption)
            if let date = set.completedAt { Text(date.formatted()).font(.caption) }
            if let reason = set.skipReason { Text(reason).font(.caption) }
            Text("This incomplete workout belongs to an older workspace. Saved values remain unchanged.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let intervals = set.intervals, !intervals.isEmpty {
            Section("Saved intervals") {
                ForEach(intervals) { interval in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(interval.prescription.kind.rawValue.capitalized) · round \(interval.repetition)")
                        Text(interval.prescription.target.summary).font(.caption)
                        Text("\(interval.status.rawValue.capitalized) · \(interval.actual.summary)").font(.caption)
                        if let reason = interval.skipReason { Text(reason).font(.caption) }
                    }
                }
            }
        }
    }
}

private extension WorkoutCommand {
    var proposedSummary: String {
        switch self {
        case .updateSet(_, let values), .logSet(_, let values): values.summary
        case .updateInterval(_, _, let values), .logInterval(_, _, let values): "Interval · \(values.summary)"
        case .skipSet(_, let reason): "Skip set · \(reason ?? "No reason supplied")"
        case .skipInterval(_, _, let reason): "Skip interval · \(reason ?? "No reason supplied")"
        case .undoSet, .undoInterval: "Undo completion or skip"
        case .pause: "Pause workout"
        case .resume: "Resume workout"
        case .finish(let partial): partial ? "Finish partial workout" : "Finish workout"
        case .abandon: "Abandon workout"
        case .skipRest: "Skip rest"
        case .extendRest(let seconds): "Extend rest by \(seconds) seconds"
        default: "A workout control change"
        }
    }
}

private func elapsedText(_ seconds: TimeInterval) -> String {
    let seconds = max(0, Int(seconds))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
