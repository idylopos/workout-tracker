import SwiftUI
import FormFlowCore

struct PlanWeekReviewView: View {
    @Environment(AppStore.self) private var store
    @State private var plan: WeeklyPlan
    @State private var issues: [PlanIssue]
    let isSample: Bool
    @State private var startDate = Calendar.current.startOfDay(for: Date())
    @State private var keepReviewNotes = false
    @State private var correctionPrompt = ""
    @State private var showCorrection = false
    @State private var showEditor = false
    @State private var importReview: PlanImportReview?
    @State private var importDecision: PlanImportDecision?
    @State private var importReviewError: String?

    init(plan: WeeklyPlan, issues: [PlanIssue], isSample: Bool) {
        _plan = State(initialValue: plan)
        _issues = State(initialValue: issues)
        self.isSample = isSample
    }

    private var warnings: [PlanIssue] {
        issues.filter { $0.severity == .warning } + PlanConstraintReview.issues(plan: plan, profile: store.profile)
    }
    private var firstWeek: [Date] {
        (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: Calendar.current.startOfDay(for: startDate)) }
    }

    var body: some View {
        List {
            Section {
                Text(plan.name).font(.title2.bold())
                Text("\(plan.days.flatMap(\.sessions).count) sessions per week")
                    .foregroundStyle(.secondary)
                if isSample {
                    Label("Sample plan · not personalized", systemImage: "info.circle")
                        .font(.subheadline.bold())
                    Text("This is an example of the supported format. Review the exercise choices and targets against your own needs before using it.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Text("Format checks confirm that the app can read the plan. They do not assess exercise suitability.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let review = importReview, review.requiresChoice {
                Section(review.exactMatches.isEmpty ? "A saved plan uses this identity" : "This plan is already saved") {
                    Text(review.exactMatches.isEmpty
                         ? "This response shares a plan identity with \(review.matches.count) saved revision(s). Choose how it should be used."
                         : "The same prescription is already saved in revision(s) \(review.exactMatches.map { String($0.sequence) }.joined(separator: ", ")). Formatting or code fences do not make it a different plan.")
                        .font(.subheadline)
                    Picker("Import choice", selection: Binding<PlanImportAction?>(
                        get: { importDecision?.action },
                        set: { action in importDecision = action.map { PlanImportDecision(review: review, action: $0) } }
                    )) {
                        Text("Choose what to do").tag(PlanImportAction?.none)
                        Text(PlanImportAction.keepExisting.label).tag(PlanImportAction?.some(.keepExisting))
                        Text(PlanImportAction.newRevision.label).tag(PlanImportAction?.some(.newRevision))
                        if review.canMakeIndependentCopy {
                            Text(PlanImportAction.independentCopy.label).tag(PlanImportAction?.some(.independentCopy))
                        }
                    }
                    Text("Keeping the existing schedule creates nothing. A new revision retains the plan identity and earlier history. An independent copy starts a separate plan identity with manual progression.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !review.canMakeIndependentCopy {
                        Text("An independent copy is available after converting this legacy source to the current format.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let importReviewError {
                Section { Text(importReviewError).foregroundStyle(.red); Button("Refresh saved-plan matches") { refreshImportReview() } }
            }
            if !warnings.isEmpty {
                Section("Notes to review") {
                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, issue in PlanIssueRow(issue: issue) }
                    Button("Review correction prompt", systemImage: "text.bubble") {
                        correctionPrompt = PromptBuilder.correctionPrompt(issues: warnings, response: store.importText)
                        showCorrection = true
                    }
                    Toggle("Keep this plan with these notes", isOn: $keepReviewNotes)
                }
            }
            if !store.profile.availableDays.isEmpty || !store.profile.equipment.isEmpty || PlanConstraintReview.hasKnownSessionBudget(store.profile) {
                Section {
                    if !store.profile.availableDays.isEmpty {
                        LabeledContent("Your available days", value: Weekday.allCases.filter { store.profile.availableDays.contains($0) }.map(\.displayName).joined(separator: ", "))
                    }
                    if PlanConstraintReview.hasKnownSessionBudget(store.profile) {
                        LabeledContent("Your session budget", value: "About \(store.profile.sessionMinutes) minutes")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your equipment").font(.caption).foregroundStyle(.secondary)
                        Text(store.profile.equipment.isEmpty ? "Not supplied" : store.profile.equipment)
                    }
                } header: { Text("Compare with your brief") }
                footer: { Text("Review the exercise equipment and any supplied restrictions yourself. The format checker cannot judge free-text constraints.") }
            }
            if !plan.assumptions.isEmpty {
                Section("Assumptions supplied with the plan") {
                    ForEach(Array(plan.assumptions.enumerated()), id: \.offset) { _, assumption in Text(assumption) }
                }
            }
            if let instructions = plan.instructions, !instructions.isEmpty {
                Section("Plan guidance") { Text(instructions).textSelection(.enabled) }
            }
            WeeklyPlanSections(plan: plan)
            Section {
                if store.importResult?.sourceVersion == 2 {
                    Button("Edit this plan", systemImage: "square.and.pencil") { showEditor = true }
                    Text("Change days, sessions, exercises, and supported targets here. Saving edits returns you to this review; it does not activate the plan.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("This legacy plan preserves its original prose prescriptions. To create editable numeric targets, ask your AI to convert it to the current format, then import and review the result.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Review a conversion prompt", systemImage: "text.bubble") {
                        correctionPrompt = store.copyCorrectionPrompt()
                        showCorrection = true
                    }
                }
            }
            Section {
                DatePicker("Begin schedule", selection: $startDate, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
            } header: { Text("Choose your start date") }
            footer: { Text("Weekdays stay fixed. Earlier days are not backfilled or counted as missed; the plan repeats weekly from your start date.") }

            Section("Your first seven days") {
                ForEach(firstWeek, id: \.self) { date in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                            .font(.subheadline.bold())
                        let sessions = plan.days.filter { $0.weekday.calendarWeekday == Calendar.current.component(.weekday, from: date) }.flatMap(\.sessions)
                        if sessions.isEmpty {
                            Text("Rest day").foregroundStyle(.secondary)
                        } else {
                            ForEach(sessions) { session in
                                Text("\(session.name) · \(sessionDurationSummary(session))")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(.vertical, 3)
                }
            }

            Section {
                if store.activePlan != nil {
                    Text("Using this plan replaces the current upcoming schedule. It does not record any completed workouts.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Button(importDecision?.action == .keepExisting ? "Keep existing schedule" : importDecision?.action == .independentCopy ? "Use independent copy" : isSample ? "Use this sample plan" : "Use this plan") {
                    if store.activatePlan(plan, startDate: Calendar.current.startOfDay(for: startDate), decision: importDecision) {
                        store.questionnairePresented = false
                        store.promptPresented = false
                        store.importPresented = false
                    }
                }
                .buttonStyle(PrimaryActionStyle())
                .accessibilityIdentifier("activate-plan")
                .disabled(importReview == nil || (importReview?.requiresChoice == true && importDecision == nil)
                          || (importDecision?.action != .keepExisting && !warnings.isEmpty && !keepReviewNotes))
            }
            SaveErrorSection()
        }
        .formFlowBackground()
        .navigationTitle("Review your week")
        .navigationBarTitleDisplayMode(.inline)
        .task { refreshImportReview() }
        .onChange(of: store.importText) { refreshImportReview() }
        .onChange(of: store.planRevision) { refreshImportReview() }
        .onChange(of: warnings) { keepReviewNotes = false }
        .navigationDestination(isPresented: $showCorrection) { CorrectionPromptView(prompt: correctionPrompt) }
        .sheet(isPresented: $showEditor) {
            NavigationStack {
                PlanEditorView(plan: plan) { updated in
                    plan = updated
                    issues = store.importResult?.issues ?? PlanValidator.validate(updated)
                    keepReviewNotes = false
                    refreshImportReview()
                }
            }
        }
    }

    private func refreshImportReview() {
        importDecision = nil
        do { importReview = try store.reviewPlanImport(plan); importReviewError = nil }
        catch { importReview = nil; importReviewError = error.localizedDescription }
    }
}

struct WeeklyPlanSections: View {
    let plan: WeeklyPlan
    var body: some View {
        ForEach(Weekday.allCases) { weekday in
            Section(weekday.displayName) {
                let sessions = plan.days.filter { $0.weekday == weekday }.flatMap(\.sessions)
                if sessions.isEmpty {
                    Text("Rest day").foregroundStyle(.secondary)
                } else {
                    ForEach(sessions) { session in
                        NavigationLink {
                            PlanSessionDetailView(session: session)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(session.name).font(.headline)
                                Text("\(sessionDurationSummary(session)) · \(session.exercises.count) exercises")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }.padding(.vertical, 3)
                        }
                    }
                }
            }
        }
    }
}

struct PlanSessionDetailView: View {
    let session: PlanSession

    var body: some View {
        List {
            Section {
                Text(session.name).font(.title2.bold())
                Text("\(session.kind.capitalized) · \(sessionDurationSummary(session))")
                    .foregroundStyle(.secondary)
                Text("These are planned targets, not recorded results.").font(.caption).foregroundStyle(.secondary)
            }
            if let instructions = session.instructions, !instructions.isEmpty {
                Section("Session guidance") { Text(instructions).textSelection(.enabled) }
            }
            Section("Warm-up") {
                if session.warmup.isEmpty {
                    Text("No warm-up instructions supplied.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(session.warmup.enumerated()), id: \.offset) { _, instruction in Text(instruction) }
                }
            }
            ForEach(Array(session.exercises.enumerated()), id: \.element.id) { index, exercise in
                Section("\(index + 1). \(exercise.name)") {
                    if exercise.optional { Label("Optional exercise", systemImage: "plus.circle").font(.subheadline) }
                    Text(exercise.target.summary).font(.headline)
                    if let intervals = exercise.intervals { PlanIntervalSummaryView(blocks: intervals) }
                    if let alternatives = exercise.alternatives {
                        ForEach(alternatives) { alternative in
                            DisclosureGroup("Alternative: \(alternative.name)") {
                                Text(alternative.target.summary)
                                Text(alternative.equipment.joined(separator: ", ")).font(.caption)
                                if let instructions = alternative.instructions { Text(instructions) }
                                if let intervals = alternative.intervals { PlanIntervalSummaryView(blocks: intervals) }
                            }
                        }
                    }
                    if (exercise.measurement == .weightReps || exercise.measurement == .weightDistance) && exercise.target.load == nil {
                        Text("Starting weight not specified.").foregroundStyle(.secondary)
                    }
                    if !exercise.equipment.isEmpty {
                        LabeledContent("Equipment", value: exercise.equipment.joined(separator: ", "))
                    }
                    if let instructions = exercise.instructions, !instructions.isEmpty {
                        Text(instructions).textSelection(.enabled)
                    } else {
                        Text("No exercise instructions supplied.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let effort = exercise.target.effort {
                        Text(effort.kind == .rir
                             ? "Reps in reserve (RIR) means how many more repetitions you estimate you could do at the end of a set."
                             : "Rating of perceived exertion (RPE) describes how hard a set feels on a scale of 0 to 10.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let policy = exercise.progressionPolicy {
                        Text("Progression reference: \(policy.id), version \(policy.version). This version of the app does not automatically change targets.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formFlowBackground()
        .navigationTitle("Session details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

func sessionDurationSummary(_ session: PlanSession) -> String {
    session.estimatedMinutes > 0 ? "About \(session.estimatedMinutes) min" : "Duration not specified"
}
