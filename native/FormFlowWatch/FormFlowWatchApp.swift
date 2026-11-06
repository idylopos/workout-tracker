import SwiftUI
import FormFlowCore

@main
struct FormFlowWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: WatchWorkoutStore
    init() {
        let bridge = PlanBridge()
        _store = State(initialValue: WatchWorkoutStore(bridge: bridge))
    }
    var body: some Scene {
        WindowGroup {
            NavigationStack { WatchHomeView() }
                .environment(store)
                .tint(.green)
                .onChange(of: store.bridge.receivedSyncGeneration) { _, _ in store.syncCurrentWorkouts() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.syncCurrentWorkouts(); store.bridge.retry() }
                }
                .alert("Couldn’t complete the change", isPresented: Binding(
                    get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }
                )) { Button("OK") { store.errorMessage = nil } } message: { Text(store.errorMessage ?? "") }
        }
    }
}

private struct WatchHomeView: View {
    @Environment(WatchWorkoutStore.self) private var store
    var body: some View {
        List {
            if !store.storageAvailable {
                Section { Text("Workout storage needs attention. Existing records have been retained.").foregroundStyle(.orange) }
            }
            if let current = store.activeWorkout {
                Section("In progress") {
                    Button { store.selectedWorkoutID = current.id } label: {
                        VStack(alignment: .leading) {
                            Text("Resume \(current.prescription.name)").font(.headline)
                            Text("\(current.completedSetCount) sets recorded").font(.caption)
                        }
                    }
                }
            }
            if let plan = store.bridge.receivedPlan {
                Section {
                    Text(plan.name).font(.headline)
                    if let revision = store.bridge.receivedPlanRevision {
                        Text("Cached revision \(revision.prefix(8))").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("Cached plan revision \(revision)")
                    }
                    if let date = store.bridge.receivedActivationDate, date > Calendar.current.startOfDay(for: Date()) {
                        Text("Starts \(date.formatted(date: .abbreviated, time: .omitted))").font(.caption)
                    }
                }
                Section("Upcoming schedule") {
                    if let upcoming = try? store.upcomingSessions() {
                        if upcoming.isEmpty { Text("No unrecorded sessions in the next two weeks.").font(.caption) }
                        ForEach(upcoming) { occurrence in
                            NavigationLink {
                                WatchSessionPreview(session: occurrence.session,
                                    weekday: Weekday.allCases.first { $0.calendarWeekday == Calendar.current.component(.weekday, from: occurrence.date) } ?? .monday,
                                    scheduled: occurrence)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(occurrence.date.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary)
                                    Text(occurrence.session.name)
                                }
                            }
                        }
                    } else { Text("The schedule needs attention. Sync the current plan from iPhone.").font(.caption).foregroundStyle(.orange) }
                }
                Section("Weekly prescriptions") {
                    ForEach(Weekday.allCases) { weekday in
                        if let day = plan.days.first(where: { $0.weekday == weekday }) {
                            ForEach(day.sessions) { session in
                                NavigationLink { WatchSessionPreview(session: session, weekday: weekday) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(weekday.displayName).font(.caption).foregroundStyle(.secondary)
                                        Text(session.name)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                Section {
                    Text("Your week, on hand").font(.headline)
                    Text("Build or import a plan on iPhone, then activate it to send it here.").font(.footnote)
                }
            }
            if !store.workouts.isEmpty {
                Section("History") {
                    ForEach(store.workouts) { workout in
                        NavigationLink { WatchWorkoutView(id: workout.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(workout.prescription.name)
                                Text(workout.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                                Text(workout.syncGeneration == store.bridge.receivedSyncGeneration ? workout.state.rawValue.capitalized : "Retained for review")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section {
                Text("Workouts are logged on this Watch. Apple Health recording is optional when you start a workout.")
                    .font(.caption2).foregroundStyle(.secondary)
                if store.retainedCount > 0 {
                    Text("\(store.retainedCount) records belong to an older workspace. They remain here for review and will not restore deleted iPhone data.")
                        .font(.caption2).foregroundStyle(.orange)
                }
                if store.bridge.receivedHistoryBaseline.omittedVariantCount > 0 {
                    Text("Previous results for some activities are available only on iPhone. Watch keeps a compact reference history.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(store.bridge.status).font(.caption2).foregroundStyle(.secondary)
                Button("Retry connection") { store.syncCurrentWorkouts(); store.bridge.retry() }
            }
        }
        .navigationTitle("Form / Flow")
        .sheet(isPresented: Binding(get: { store.selectedWorkoutID != nil }, set: { if !$0 { store.selectedWorkoutID = nil } })) {
            if let id = store.selectedWorkoutID { NavigationStack { WatchWorkoutView(id: id) } }
        }
    }
}

private struct WatchSessionPreview: View {
    @Environment(WatchWorkoutStore.self) private var store
    let session: PlanSession
    let weekday: Weekday
    var scheduled: ScheduledPlanSession? = nil
    @State private var recordWithHealth = false
    var body: some View {
        List {
            Section(weekday.displayName) {
                Text(session.name).font(.headline)
                if let scheduled {
                    Text(scheduled.date.formatted(date: .abbreviated, time: .omitted)).font(.caption)
                    Text("Starting now records today's actual workout time.").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Starting here records an extra, unscheduled workout. Use Upcoming schedule to record a planned occurrence.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if session.estimatedMinutes > 0 { Text("About \(session.estimatedMinutes) min").font(.caption) }
                if let instructions = session.instructions { Text(instructions).font(.footnote) }
                if store.activeWorkout == nil {
                    Toggle("Record with Apple Health", isOn: $recordWithHealth)
                    Text("When enabled, Watch requests permission to record this workout and available health metrics. Manual logging stays available.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("In manual mode, rest alerts occur while this app is open. The countdown uses its saved deadline when you return.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button(store.activeWorkout == nil ? (scheduled == nil ? "Start extra workout" : "Start on Watch") : "Resume workout") {
                    store.start(session, scheduledSessionID: scheduled?.id, scheduledDate: scheduled?.date, recordWithHealth: recordWithHealth)
                }
                    .disabled(!store.storageAvailable)
            }
            if !session.warmup.isEmpty {
                Section("Warm-up") {
                    ForEach(Array(session.warmup.enumerated()), id: \.offset) { _, item in Text(item).font(.footnote) }
                }
            }
            Section("Targets") {
                ForEach(session.exercises) { exercise in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(exercise.name).font(.headline)
                        Text(exercise.target.summary).font(.footnote).foregroundStyle(.secondary)
                        if exercise.optional { Text("Optional · off until selected").font(.caption2) }
                        if let instructions = exercise.instructions { Text(instructions).font(.footnote) }
                    }
                }
            }
        }.navigationTitle("Session plan")
    }
}

struct WatchWorkoutView: View {
    @Environment(WatchWorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var confirmFinish = false
    @State private var confirmAbandon = false
    private var workout: WorkoutSession? { store.workouts.first { $0.id == id } }
    var body: some View {
        Group {
            if let workout {
                let editable = workout.syncGeneration == store.bridge.receivedSyncGeneration && store.storageAvailable
                List {
                    Section {
                        Text(workout.prescription.name).font(.headline)
                        Text("Plan revision \(workout.planRevisionID.prefix(8))").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("This workout uses frozen plan revision \(workout.planRevisionID)")
                        Text("\(workout.completedSetCount) of \(workout.plannedSetCount) sets recorded").font(.caption)
                        if workout.exercises.contains(where: { $0.sets.contains { !($0.intervals ?? []).isEmpty } }) {
                            Text("\(workout.completedIntervalCount) intervals recorded separately").font(.caption2)
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            Text(duration(workout.elapsed(at: timeline.date))).monospacedDigit().font(.title3)
                        }
                        Text(workout.state.rawValue.capitalized).font(.caption)
                        if let healthMessage = store.healthMessage(for: workout.id) {
                            Text(healthMessage).font(.caption2).foregroundStyle(.secondary)
                        }
                        if let health = store.health, health.activeWorkoutID == workout.id {
                            if let heartRate = health.heartRate { Text("\(heartRate, format: .number.precision(.fractionLength(0))) bpm").font(.caption).monospacedDigit() }
                            else { Text("Heart rate unavailable").font(.caption).foregroundStyle(.secondary) }
                            if let energy = health.activeEnergyKilocalories { Text("\(energy, format: .number.precision(.fractionLength(0))) kcal active").font(.caption).monospacedDigit() }
                        } else if !workout.state.isTerminal {
                            Text("Heart rate unavailable · manual logging").font(.caption2).foregroundStyle(.secondary)
                        }
                        if !editable { Text("Older workspace · retained for review").font(.caption).foregroundStyle(.orange) }
                    }
                    if let rest = workout.rest, !workout.state.isTerminal {
                        Section("Rest") {
                            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                Text(rest.isExpired(at: timeline.date) ? "Ready for your next set" : duration(rest.remaining(at: timeline.date)))
                                    .monospacedDigit().font(.title3)
                                    .onChange(of: rest.isExpired(at: timeline.date), initial: true) { _, expired in
                                        if expired { store.alertForExpiredRest(rest, workoutID: id) }
                                    }
                            }
                            if let next = workout.recordingExercises.first(where: { $0.isEnabled && $0.sets.contains { $0.status == .planned } }) {
                                Text("Next: \(next.performedPrescription.name)").font(.caption)
                            }
                            if editable {
                                Button("+30 seconds") { store.apply(.extendRest(seconds: 30), to: id) }
                                Button("Skip rest") { store.apply(.skipRest, to: id) }
                                Button("Undo last set") { store.apply(.undoSet(setID: rest.setID), to: id) }
                            }
                        }
                    }
                    if workout.usesThursdayLegCurl && !workout.state.isTerminal {
                        Section("Warm-up") {
                            ForEach(Array(workout.recordingWarmup.enumerated()), id: \.offset) { _, step in Text(step) }
                        }
                    }
                    ForEach(workout.recordingExercises) { exercise in
                        Section(exercise.performedPrescription.name) {
                            Text("Target: \(exercise.performedPrescription.target.summary)").font(.caption2).foregroundStyle(.secondary)
                            if exercise.selectedAlternativeID != nil {
                                Text("Planned: \(exercise.prescription.name)").font(.caption2).foregroundStyle(.secondary)
                            }
                            if exercise.isAdditional { Text("Extra activity").font(.caption2).foregroundStyle(.secondary) }
                            if let instructions = exercise.performedPrescription.instructions {
                                Text(instructions).font(.caption2).foregroundStyle(.secondary)
                            }
                            let previous = store.bridge.receivedHistoryBaseline.previous(for: exercise, excluding: workout.id)
                            if !previous.isEmpty {
                                NavigationLink("Previous recorded results") { WatchPreviousResults(exposures: previous) }
                            }
                            if !(exercise.prescription.alternatives ?? []).isEmpty && editable && !workout.state.isTerminal {
                                NavigationLink("Choose activity") {
                                    WatchActivityChoice(sessionID: id, exerciseID: exercise.id)
                                }
                            }
                            if exercise.prescription.optional && !workout.state.isTerminal && editable {
                                Toggle("Include optional work", isOn: Binding(get: { exercise.isEnabled }, set: {
                                    store.apply(.setExerciseEnabled(exerciseID: exercise.id, enabled: $0), to: id)
                                }))
                            }
                            if exercise.isEnabled {
                                ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                                    NavigationLink {
                                        WatchSetEditor(sessionID: id, exerciseID: exercise.id, setID: set.id, number: index + 1)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Label("Set \(index + 1)", systemImage: set.status == .completed ? "checkmark.circle.fill" : "circle")
                                            Text(set.status == .planned ? (set.actual.isEmpty ? "Enter actual values" : set.actual.summary) : set.status.rawValue.capitalized)
                                                .font(.caption2).foregroundStyle(.secondary)
                                            if let intervals = set.intervals, !intervals.isEmpty {
                                                Text("\(intervals.filter { $0.status == .completed }.count) of \(intervals.count) intervals completed")
                                                    .font(.caption2).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if editable && !workout.state.isTerminal {
                        Section {
                            NavigationLink("Add extra activity") { WatchExtraActivityChoice(sessionID: id) }
                            Button(workout.state == .paused ? "Resume" : "Pause") {
                                store.apply(workout.state == .paused ? .resume : .pause, to: id)
                            }
                            Button("Finish workout") {
                                if workout.hasIncompleteWork { confirmFinish = true }
                                else { store.apply(.finish(allowPartial: false), to: id) }
                            }
                            Button("Abandon workout", role: .destructive) { confirmAbandon = true }
                        }
                    }
                    Section {
                        Text(store.bridge.workoutStatus(for: id)).font(.caption2).foregroundStyle(.secondary)
                        if let health = store.health, let state = health.exportState(for: workout) {
                            if state == .failedBeforeSave && health.ownsActiveSession && health.activeWorkoutID == id {
                                Button("Retry Apple Health save") { store.retryHealthExport(for: workout) }
                            } else if state == .pendingVerification || state == .saving {
                                Button("Verify Apple Health save") { store.verifyHealthExports() }
                            }
                        }
                        if editable { Button("Retry sync") { store.bridge.publishWorkout(workout); store.bridge.retry() } }
                        if workout.state.isTerminal { Button("Done") { dismiss() } }
                    }
                }
            } else { Text("Workout unavailable") }
        }
        .navigationTitle("Workout")
        .confirmationDialog("Finish with incomplete work?", isPresented: $confirmFinish) {
            Button("Finish recorded work") { store.apply(.finish(allowPartial: true), to: id) }
            Button("Continue workout", role: .cancel) {}
        } message: { Text("Completed sets and intervals stay recorded. Remaining work will be marked unperformed. Skipped intervals make this a partial workout.") }
        .confirmationDialog("Abandon this workout?", isPresented: $confirmAbandon) {
            Button("Abandon", role: .destructive) { store.apply(.abandon, to: id) }
            Button("Keep workout", role: .cancel) {}
        } message: { Text("Your recorded values remain in history.") }
    }
    private func duration(_ value: Double) -> String {
        let seconds = value.isFinite ? Int(min(Double(Int.max / 2), max(0, value))) : 0
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

private struct WatchSetEditor: View {
    @Environment(WatchWorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID
    let exerciseID: UUID
    let setID: UUID
    let number: Int
    var intervalID: UUID? = nil
    @State private var entry = WatchSetEntry(values: WorkoutSetValues())
    @State private var loaded = false
    @State private var skipReason = ""
    private var workout: WorkoutSession? { store.workouts.first { $0.id == sessionID } }
    private var exercise: WorkoutExercise? { workout?.exercises.first { $0.id == exerciseID } }
    private var set: WorkoutSet? { exercise?.sets.first { $0.id == setID } }
    private var interval: WorkoutInterval? { self.set?.intervals?.first { $0.id == intervalID } }
    var body: some View {
        Group {
            if let workout, let exercise, let set, intervalID == nil || interval != nil {
                let editable = workout.syncGeneration == store.bridge.receivedSyncGeneration && workout.state != .abandoned && store.storageAvailable
                let status = interval?.status ?? set.status
                let intervals = intervalID == nil ? (set.intervals ?? []) : []
                let actual = interval?.actual ?? set.actual
                List {
                    Section("Target") {
                        Text((interval?.prescription.target ?? set.target).summary).font(.caption).foregroundStyle(.secondary)
                        if let interval {
                            Text("\(interval.prescription.kind.rawValue.capitalized) · repeat \(interval.repetition)").font(.caption2)
                            if let cue = interval.prescription.instructions { Text(cue).font(.caption2) }
                        }
                    }
                    if !intervals.isEmpty {
                        Section("Intervals") {
                            ForEach(intervals) { interval in
                                NavigationLink {
                                    WatchSetEditor(sessionID: sessionID, exerciseID: exerciseID, setID: setID,
                                        number: number, intervalID: interval.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(interval.prescription.kind.rawValue.capitalized) · \(interval.repetition)")
                                        Text(interval.prescription.target.summary).font(.caption2)
                                        Text(interval.status == .completed ? interval.actual.summary : interval.status.rawValue.capitalized)
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Text("Complete or skip each interval, then record activity totals below. Totals remain separate from interval results.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Section(intervals.isEmpty ? "Actual" : "Activity totals · actual") {
                        if editable {
                            actualFields(interval?.prescription.measurement ?? exercise.performedPrescription.measurement)
                        } else { Text(actual.summary).font(.footnote) }
                    }
                    if editable {
                        Section {
                            if status == .planned && set.status == .planned && workout.state == .active {
                                Button(intervalID != nil ? "Log interval" : intervals.isEmpty ? "Log set" : "Log activity totals") {
                                    submit(complete: true)
                                }.tint(.green).disabled(intervals.contains { $0.status == .planned })
                            }
                            Button(status == .completed ? "Save correction" : "Save values") { submit(complete: false) }
                            if !workout.state.isTerminal && (intervalID == nil || set.status == .planned) {
                                if status == .planned {
                                    TextField("Skip reason (optional)", text: $skipReason)
                                    Button(intervalID == nil ? "Skip set" : "Skip interval") {
                                        let reason = skipReason.trimmingCharacters(in: .whitespacesAndNewlines)
                                        let command: WorkoutCommand = intervalID.map { .skipInterval(setID: setID, intervalID: $0, reason: reason) }
                                            ?? .skipSet(setID: setID, reason: reason)
                                        if store.apply(command, to: sessionID) { dismiss() }
                                    }
                                } else if [.completed, .skipped].contains(status) {
                                    Button(intervalID == nil ? "Undo set" : "Undo interval") {
                                        let command: WorkoutCommand = intervalID.map { .undoInterval(setID: setID, intervalID: $0) }
                                            ?? .undoSet(setID: setID)
                                        if store.apply(command, to: sessionID) { dismiss() }
                                    }
                                }
                            } else if intervalID != nil && !workout.state.isTerminal {
                                Text("Undo the outer activity before changing an interval's completion status.").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Blank means unanswered. Targets do not fill actual results.").font(.caption2).foregroundStyle(.secondary)
                }
                .onAppear {
                    guard !loaded else { return }
                    entry = interval.map { store.entry(for: $0) } ?? store.entry(for: set)
                    skipReason = interval?.skipReason ?? set.skipReason ?? ""
                    loaded = true
                }
                .onChange(of: entry) { _, value in if loaded { store.saveEntry(value, for: intervalID ?? setID) } }
            } else { Text("Set unavailable") }
        }.navigationTitle(interval?.prescription.kind.rawValue.capitalized ?? "Set \(number)")
    }
    @ViewBuilder private func actualFields(_ measurement: MeasurementKind) -> some View {
        if [.weightReps, .weightDistance].contains(measurement) { TextField("Load", text: $entry.load) }
        if measurement == .assistedReps { TextField("Assistance", text: $entry.assistance) }
        if [.weightReps, .weightDistance, .assistedReps].contains(measurement) {
            Picker("Load unit", selection: $entry.loadUnit) { Text("kg").tag(PlanUnit.kg); Text("lb").tag(PlanUnit.lb) }
        }
        if [.weightReps, .reps, .assistedReps].contains(measurement) { TextField("Reps", text: $entry.reps) }
        let cardio = [.duration, .durationCalories, .distanceTime, .distance].contains(measurement)
        if cardio { TextField("Seconds", text: $entry.seconds) }
        if cardio || measurement == .weightDistance {
            TextField("Distance", text: $entry.distance)
            Picker("Distance unit", selection: $entry.distanceUnit) {
                Text("m").tag(PlanUnit.m); Text("km").tag(PlanUnit.km); Text("mi").tag(PlanUnit.mi)
            }
        }
        if cardio {
            TextField("Calories (optional)", text: $entry.calories)
            TextField("RPE (optional)", text: $entry.rpe)
            TextField("Average RPM (optional)", text: $entry.averageRpm)
            TextField("Average heart rate (optional)", text: $entry.averageHeartRate)
        } else if measurement != .completion { TextField("RIR (optional)", text: $entry.rir) }
        if measurement == .completion { Text("Tap Log set when the activity is complete.").font(.footnote) }
    }
    private func submit(complete: Bool) {
        do {
            let values = try entry.values()
            let command: WorkoutCommand
            if let intervalID {
                command = complete ? .logInterval(setID: setID, intervalID: intervalID, values: values)
                    : .updateInterval(setID: setID, intervalID: intervalID, values: values)
            } else {
                command = complete ? .logSet(setID: setID, values: values) : .updateSet(setID: setID, values: values)
            }
            if store.apply(command, to: sessionID) { dismiss() }
        } catch { store.errorMessage = error.localizedDescription }
    }
}
