import SwiftUI
import FormFlowCore

struct ScheduleCalendarView: View {
    @Environment(AppStore.self) private var store
    @State private var fromDate = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
    private var throughDate: Date { Calendar.current.date(byAdding: .day, value: 41, to: fromDate) ?? fromDate }
    private var entries: [ScheduleOccurrence] {
        guard let plan = store.activePlan, let start = store.activationDate else { return [] }
        return (try? ScheduleExceptionSchedule.occurrences(plan: plan, activationDate: start, from: fromDate, through: throughDate,
                                                          exceptions: store.scheduleExceptions.exceptions, workouts: store.workoutsForScheduling)) ?? []
    }
    var body: some View {
        List {
            Section {
                DatePicker("Show six weeks from", selection: $fromDate, displayedComponents: .date)
                Text("Move or skip one occurrence here. Recurring weekdays stay in your plan; recorded workouts keep their original history.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("A past date without a workout needs review. It is marked missed only when you choose that outcome.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if entries.isEmpty {
                ContentUnavailableView("No sessions in this range", systemImage: "calendar", description: Text("Choose dates on or after your plan’s activation."))
            }
            ForEach(entries) { entry in
                NavigationLink {
                    ScheduleOccurrenceView(occurrenceID: entry.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.scheduled.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(entry.scheduled.session.name).font(.headline)
                        Label(entry.status.label, systemImage: symbol(entry.status)).font(.subheadline)
                        if entry.isMoved { Text("Moved from \(entry.originalDay.date)").font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 3)
                }
            }
            if let error = store.scheduleExceptions.errorMessage { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Calendar")
        .formFlowBackground()
    }
    private func symbol(_ status: ScheduleOccurrenceStatus) -> String {
        switch status {
        case .planned: "calendar"
        case .needsReview: "questionmark.circle"
        case .skipped: "forward.end"
        case .missed: "calendar.badge.exclamationmark"
        case .inProgress: "figure.strengthtraining.traditional"
        case .finished: "checkmark.circle"
        case .abandoned: "stop.circle"
        }
    }
}

struct ScheduleOccurrenceView: View {
    @Environment(AppStore.self) private var store
    let occurrenceID: String
    @State private var selectedDate = Date()
    @State private var note = ""
    @State private var loaded = false
    @State private var savedMessage: String?
    private var occurrence: ScheduleOccurrence? {
        guard let plan = store.activePlan, let activation = store.activationDate else { return nil }
        return try? ScheduleExceptionSchedule.resolve(occurrenceID: occurrenceID, plan: plan, activationDate: activation,
                                                      exceptions: store.scheduleExceptions.exceptions, workouts: store.workoutsForScheduling)
    }
    private var pendingWatch: Bool { store.bridge.remoteStartIntents.contains { $0.scheduledSessionID == occurrenceID } }
    private var firstAllowedDate: Date { max(Calendar.current.startOfDay(for: Date()), Calendar.current.startOfDay(for: store.activationDate ?? Date())) }
    private var lastAllowedDate: Date { max(firstAllowedDate, Calendar.current.date(byAdding: .day, value: 365, to: Date()) ?? firstAllowedDate) }
    var body: some View {
        Form {
            if let occurrence {
                Section {
                    Text(occurrence.scheduled.session.name).font(.title2.bold())
                    LabeledContent("Scheduled", value: occurrence.scheduled.date.formatted(date: .complete, time: .omitted))
                    if occurrence.isMoved { LabeledContent("Original date", value: occurrence.originalDay.date) }
                    LabeledContent("Status", value: occurrence.status.label)
                    if let change = occurrence.exception, !change.note.isEmpty { Text(change.note).font(.subheadline).foregroundStyle(.secondary) }
                }
                if let workoutID = occurrence.workoutID, let workout = store.workouts.first(where: { $0.id == workoutID }) {
                    Section {
                        Text("This occurrence already has a recorded workout. Review its actual results in history.")
                        Button("Open workout") { store.presentWorkout(workout) }
                    }
                } else if pendingWatch {
                    Section("Watch start needs reconciliation") {
                        Text("The Watch may already be recording this occurrence. Check the request before moving or skipping it.")
                        ForEach(store.bridge.remoteStartIntents.filter { $0.scheduledSessionID == occurrenceID }) { intent in
                            Text(store.bridge.remoteStartStatus(for: intent.id)).font(.caption)
                            Button("Check Watch request") { store.bridge.reconcileWatchStart(intent.id) }
                        }
                    }
                } else {
                    if occurrence.canStart {
                        Section { NavigationLink("Start this occurrence") { WorkoutReadyView(scheduled: occurrence.scheduled) } }
                    }
                    Section("Move this occurrence") {
                        DatePicker("New date", selection: $selectedDate, in: firstAllowedDate...lastAllowedDate, displayedComponents: .date)
                        Button("Save new date") { save(occurrence, action: .rescheduled) }
                            .disabled(note.count > 1_000)
                        Text("Only this occurrence moves. Another occurrence of the same session on that date must be resolved first.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Decision note") {
                        TextField("Optional reason or reminder", text: $note, axis: .vertical).lineLimit(2...5)
                    }
                    Section("Other decisions") {
                        Button("Skip this occurrence") { save(occurrence, action: .skipped) }
                            .disabled(occurrence.status == .skipped || note.count > 1_000)
                        if occurrence.scheduled.date < Calendar.current.startOfDay(for: Date()) {
                            Button("Mark as missed") { save(occurrence, action: .missed) }
                                .disabled(occurrence.status == .missed || note.count > 1_000)
                        }
                        if occurrence.exception != nil && occurrence.exception?.action != .restored {
                            Button("Restore original occurrence") { save(occurrence, action: .restored) }
                                .disabled(note.count > 1_000)
                        }
                        Text("Skip and missed decisions do not create a completed workout or alter recorded results.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let savedMessage { Section { Label(savedMessage, systemImage: "checkmark.circle") } }
                if let error = store.scheduleExceptions.errorMessage { Section { Text(error).foregroundStyle(.red) } }
            } else {
                ContentUnavailableView("Occurrence unavailable", systemImage: "calendar.badge.exclamationmark", description: Text("Open an occurrence from the current plan’s calendar."))
            }
        }
        .navigationTitle("Scheduled session")
        .navigationBarTitleDisplayMode(.inline)
        .formFlowBackground()
        .task {
            guard !loaded else { return }; loaded = true
            if let occurrence {
                selectedDate = min(max(occurrence.scheduled.date, firstAllowedDate), lastAllowedDate)
                note = occurrence.exception?.note ?? ""
            }
        }
    }
    private func save(_ occurrence: ScheduleOccurrence, action: ScheduleExceptionAction) {
        guard let plan = store.activePlan, let revision = store.activePlanRevisionID, let activation = store.activationDate else { return }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let selectedISO = LocalTrainingDay(instant: selectedDate, timeZone: calendar.timeZone).date
        let destination = try? LocalTrainingDay(date: selectedISO, timeZoneID: occurrence.originalDay.timeZoneID)
        if store.scheduleExceptions.save(occurrence, action: action, destination: action == .rescheduled ? destination : nil, note: note,
                                         plan: plan, planRevisionID: revision, activationDate: activation, workouts: store.workoutsForScheduling,
                                         pendingWatchOccurrenceIDs: Set(store.bridge.remoteStartIntents.compactMap(\.scheduledSessionID))) {
            store.publishScheduleChanges()
            savedMessage = action == .rescheduled ? "New date saved" : action == .skipped ? "Skipped occurrence saved" : action == .missed ? "Missed occurrence saved" : "Original occurrence restored"
        } else { savedMessage = nil }
    }
}
