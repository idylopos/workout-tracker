import SwiftUI
import FormFlowCore

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        TabView {
            NavigationStack { TodayView().toolbar { settingsToolbar } }
                .tabItem { Label("Today", systemImage: "sun.max") }
            NavigationStack { PlanHomeView().toolbar { settingsToolbar } }
                .tabItem { Label("Plan", systemImage: "calendar") }
            NavigationStack { ProgressHomeView().toolbar { settingsToolbar } }
                .tabItem { Label("Progress", systemImage: "chart.xyaxis.line") }
        }
        .tint(FormFlowTheme.accent)
        .sheet(isPresented: $store.questionnairePresented) {
            NavigationStack { TrainingProfileView() }
        }
        .sheet(isPresented: $store.promptPresented) {
            NavigationStack { PromptReviewView() }
        }
        .sheet(isPresented: $store.importPresented) {
            NavigationStack { PlanImportView() }
        }
        .sheet(isPresented: $store.workoutPresented) {
            if let id = store.selectedWorkoutID {
                NavigationStack { WorkoutSessionView(sessionID: id) }
            }
        }
    }

    private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink { SettingsView() } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }
}

private struct TodayView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        List {
            if !store.recoveryDue.isEmpty {
                Section("Recovery check-in") {
                    ForEach(store.recoveryDue) { prompt in
                        NavigationLink {
                            RecoveryEntryView(prompt: prompt)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(prompt.phase == .nextMorning ? "Following-morning recovery" : "Evening recovery")
                                Text("\(store.workouts.first { $0.id == prompt.sessionID }?.prescription.name ?? "Workout") · \(prompt.sessionDay.date)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let workout = store.currentWorkout {
                Section("Workout in progress") {
                    Text(workout.prescription.name).font(.headline)
                    Text("\(workout.completedSetCount) of \(workout.plannedSetCount) sets recorded")
                        .foregroundStyle(.secondary)
                    Button(workout.state == .paused ? "Resume workout" : "Continue workout") {
                        store.presentWorkout(workout)
                    }.buttonStyle(PrimaryActionStyle())
                }
            }
            let watchWorkouts = store.workouts.filter {
                !$0.state.isTerminal && !store.isRetiredIncomplete($0) && $0.ownerDeviceID != store.deviceID && !store.workoutAnnotations.isOwnerUnavailable($0)
            }
            if !watchWorkouts.isEmpty {
                Section("Recording on Watch") {
                    ForEach(watchWorkouts) { workout in
                        Button { store.presentWorkout(workout) } label: {
                            VStack(alignment: .leading) {
                                Text(workout.prescription.name).font(.headline)
                                Text("\(workout.completedSetCount) saved sets · latest received Watch record")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            let retired = store.workouts.filter { store.isRetiredIncomplete($0) }
            if !retired.isEmpty {
                Section("Archived incomplete records") {
                    ForEach(Array(retired.prefix(3))) { workout in
                        Button { store.presentWorkout(workout) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(workout.prescription.name)
                                Text("Older workspace · read-only saved values").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("These records do not block a new workout. Find all retained records in Progress.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let plan = store.activePlan {
                Section {
                    Text(plan.name).font(.title2.bold())
                    if let start = store.activationDate {
                        LabeledContent("Schedule begins", value: start.formatted(date: .abbreviated, time: .omitted))
                    }
                } header: { Text("Your active plan") }

                let sessions = store.upcomingSessions(from: Date(), limit: 8)
                Section("Upcoming sessions") {
                    if sessions.isEmpty {
                        Text("No upcoming sessions in this plan.").foregroundStyle(.secondary)
                    } else {
                        ForEach(sessions) { item in
                            NavigationLink {
                                WorkoutReadyView(scheduled: item)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(item.session.name).font(.headline)
                                    Text("\(sessionDurationSummary(item.session)) · \(item.session.exercises.count) exercises")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }.padding(.vertical, 4)
                            }
                            .accessibilityIdentifier("scheduled-session-\(item.session.id)")
                        }
                    }
                }
                Section {
                    NavigationLink { ExtraActivityView() } label: { Label("Log an extra activity", systemImage: "plus") }
                    NavigationLink("Training calendar") { ScheduleCalendarView() }
                }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .font(.largeTitle).foregroundStyle(FormFlowTheme.accent)
                        Text("Make room for your training.").font(.title2.bold())
                        Text("Describe your goals and routine, build a prompt for your AI, then bring its plan back to review.")
                            .foregroundStyle(.secondary)
                        Button(store.onboardingStep > 0 ? "Continue my profile" : "Build my training profile") {
                            store.questionnairePresented = true
                        }.buttonStyle(PrimaryActionStyle())
                            .accessibilityIdentifier("build-profile")
                    }.padding(.vertical, 8)
                }
                if !store.promptDraft.isEmpty {
                    Section("Your draft is saved") {
                        Button("Review my AI prompt", systemImage: "doc.text") { store.promptPresented = true }
                        Button("Import an AI response", systemImage: "square.and.arrow.down") { store.importPresented = true }
                    }
                }
                Section("Other ways to begin") {
                    Button("Import an existing plan", systemImage: "doc.badge.arrow.up") { store.importPresented = true }
                    SamplePlanButton()
                    Text("The sample is an example to review, not a personalized prescription.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Label("You choose which profile details to include in prompts and backups.", systemImage: "lock")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            SaveErrorSection()
        }
        .formFlowBackground()
        .navigationTitle("Today")
    }
}

private struct PlanHomeView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        List {
            if let plan = store.activePlan {
                Section {
                    Text(plan.name).font(.title2.bold())
                    Text("Your weekly schedule").foregroundStyle(.secondary)
                }
                Section("Apple Watch") {
                    Text(store.bridge.status).font(.subheadline)
                    Button("Retry plan transfer", systemImage: "arrow.clockwise") { store.bridge.retry() }
                }
                WeeklyPlanSections(plan: plan)
                if let revision = store.activePlanRevisionID {
                    Section("Progression choices") {
                        Text("Exercises use manual progression unless you explicitly choose a supported policy.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(plan.days.flatMap(\.sessions)) { session in
                            ForEach(session.exercises) { exercise in
                                NavigationLink("\(session.name) · \(exercise.name)") {
                                    ProgressionEnrollmentView(planRevisionID: revision, session: session, exercise: exercise)
                                }
                            }
                        }
                    }
                }
            } else {
                Section {
                    ContentUnavailableView("Your week starts here", systemImage: "calendar", description: Text("Create a profile or import a plan to review your week."))
                }
            }
            Section("Plan tools") {
                if let activePlan = store.activePlan {
                    NavigationLink("Training calendar") { ScheduleCalendarView() }
                    NavigationLink("Edit future plan and targets") {
                        PlanEditorView(plan: activePlan) { _ in store.importPresented = true }
                    }
                }
                Button("Training profile", systemImage: "person.text.rectangle") { store.questionnairePresented = true }
                if !store.promptDraft.isEmpty {
                    Button("Review saved AI prompt", systemImage: "doc.text") { store.promptPresented = true }
                }
                Button("Import a plan", systemImage: "square.and.arrow.down") { store.importPresented = true }
                NavigationLink("Saved plan revisions") { SavedPlanRevisionsView() }
                NavigationLink("Saved prompts and plan drafts") { SavedDraftsView() }
                NavigationLink("Review the existing Form / Flow program") { BuiltInProgramView() }
                SamplePlanButton()
            }
            SaveErrorSection()
        }
        .formFlowBackground()
        .navigationTitle("Plan")
    }
}

private struct ProgressHomeView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        List {
            let history = store.workouts.filter { $0.state.isTerminal || store.isRetiredIncomplete($0) || store.workoutAnnotations.interruptionState($0) != .none }
            Section {
                NavigationLink("Sleep, body measurements and recovery") { TrackingHomeView() }
                NavigationLink("Workout trends") { WorkoutTrendsView() }
                NavigationLink("Imported web history") { ImportedHistoryView() }
            }
            if history.isEmpty {
                ContentUnavailableView("No recorded workouts", systemImage: "chart.xyaxis.line", description: Text("Completed and partial workouts appear here. Choose a session from Today to begin."))
            } else {
                Section("Training history") {
                    ForEach(history) { workout in
                        Button { store.presentWorkout(workout) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(workout.prescription.name).font(.headline)
                                Text(workout.startedAt.formatted(date: .abbreviated, time: .shortened))
                                if workout.state.isTerminal {
                                    Text("\(workout.completedSetCount) sets · \(workout.state == .abandoned ? "Abandoned" : workout.isPartial ? "Partial workout" : "Finished")")
                                }
                                if store.isRetiredIncomplete(workout) {
                                    Label("Archived incomplete · older workspace", systemImage: "archivebox").font(.caption)
                                }
                                if store.workoutAnnotations.isExcludedDuplicate(workout) {
                                    Label("Duplicate · excluded from totals", systemImage: "doc.on.doc").font(.caption)
                                }
                                if store.workoutAnnotations.interruptionState(workout) != .none {
                                    Label(store.workoutAnnotations.isOwnerUnavailable(workout)
                                        ? "Recording device unavailable · latest received copy"
                                        : "Recording device sent an update · review needed", systemImage: "applewatch.slash")
                                        .font(.caption)
                                }
                            }
                        }.foregroundStyle(.primary)
                    }
                }
            }
        }
        .formFlowBackground()
        .navigationTitle("Progress")
    }
}

struct SaveErrorSection: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        if let message = store.errorMessage {
            Section("Something needs attention") {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("Try saving again") { store.retryLastSave() }
            }
        }
    }
}

private struct SamplePlanButton: View {
    @Environment(AppStore.self) private var store
    @State private var confirmDraftReplacement = false
    var body: some View {
        Button("Explore a sample plan", systemImage: "sparkles.rectangle.stack") {
            let current = store.importText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !current.isEmpty && current != PlanContract.exampleJSON.trimmingCharacters(in: .whitespacesAndNewlines) {
                confirmDraftReplacement = true
            } else { showSample() }
        }
        .accessibilityIdentifier("sample-plan")
        .confirmationDialog("Replace the response in your import draft with the sample? Your active plan will stay unchanged.", isPresented: $confirmDraftReplacement, titleVisibility: .visible) {
            Button("Load sample into import draft") { showSample() }
            Button("Keep my draft", role: .cancel) {}
        }
    }

    private func showSample() {
        store.loadExample()
        store.importPresented = true
    }
}
