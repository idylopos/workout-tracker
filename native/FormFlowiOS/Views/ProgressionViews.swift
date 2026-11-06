import SwiftUI
import FormFlowCore

struct ProgressionEnrollmentView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let planRevisionID: String
    let session: PlanSession
    let exercise: PlanExercise
    @State private var choice: ProgressionChoice = .manual
    @State private var pullUpStep = 1
    @State private var longRunStage = 1
    @State private var variation = ""
    @State private var loaded = false
    @State private var localError: String?

    private var configuration: ProgressionConfiguration {
        .init(policy: choice.policy?.reference, optedIn: choice != .manual, variantID: variation.trimmingCharacters(in: .whitespacesAndNewlines),
              pullUpStep: choice == .pullUp ? pullUpStep : nil, longRunStage: choice == .longRun ? longRunStage : nil)
    }
    private var supported: Bool { choice == .manual || ProgressionEngine.supports(configuration: configuration, exercise: exercise) }
    var body: some View {
        Form {
            Section {
                Text(exercise.name).font(.title2.bold())
                Text(exercise.target.summary).foregroundStyle(.secondary)
                Text("Progression starts in manual mode. Choose a supported rule only after reviewing its targets and recovery requirements.")
                    .font(.subheadline)
            }
            Section("Future target suggestions") {
                Picker("Progression rule", selection: $choice) {
                    ForEach(ProgressionChoice.allCases) { choice in Text(choice.label).tag(choice) }
                }
                if choice == .pullUp {
                    Picker("Current pull-up step", selection: $pullUpStep) {
                        ForEach(BuiltInProgression.pullUpSteps) { Text("\($0.id) · \($0.name)").tag($0.id) }
                    }
                }
                if choice == .longRun {
                    Picker("Current long-run stage", selection: $longRunStage) {
                        ForEach(BuiltInProgression.longRunStages) { Text("\($0.id) · \($0.label)").tag($0.id) }
                    }
                }
                if choice != .manual {
                    TextField("Exercise variation, if needed", text: $variation)
                    Text("Use the same variation name for comparable workouts. A changed variation starts a separate comparison.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(choice.explanation).font(.subheadline).foregroundStyle(.secondary)
            }
            if !supported {
                Section {
                    Label("This rule does not match the typed targets", systemImage: "exclamationmark.circle")
                    Text("Review the exercise measurement, set count, rep range, effort target and roadmap step in the plan editor. An unsupported supplied policy remains manual.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let message = localError ?? store.progression.errorMessage { Section { Text(message).foregroundStyle(.red) } }
            Section {
                Button(choice == .manual ? "Save manual progression" : "Enable this rule") { save() }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(!supported || variation.count > 200)
                Text("Suggestions use recorded sets, your technique and effort answers, and recovery for each finished session. Every future target change requires your acceptance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Progression rule")
        .navigationBarTitleDisplayMode(.inline)
        .formFlowBackground()
        .task {
            guard !loaded else { return }; loaded = true
            if let config = store.progression.configuration(planRevisionID: planRevisionID, sessionID: session.id, exerciseInstanceID: exercise.instanceId) {
                choice = config.optedIn ? ProgressionChoice(policy: config.implementedPolicy) : .manual
                pullUpStep = config.pullUpStep ?? 1; longRunStage = config.longRunStage ?? 1; variation = config.variantID
            }
        }
    }
    private func save() {
        guard store.activePlanRevisionID == planRevisionID, let plan = store.activePlan,
              plan.days.flatMap(\.sessions).first(where: { $0.id == session.id })?.exercises.contains(exercise) == true else {
            localError = "The active plan changed. Open its current exercise before choosing a progression rule."; return
        }
        if store.progression.saveEnrollment(planID: plan.id, planRevisionID: planRevisionID, session: session,
                                            exercise: exercise, configuration: configuration) { dismiss() }
    }
}

struct ProgressionReviewView: View {
    @Environment(AppStore.self) private var store
    let workout: WorkoutSession
    let exercise: WorkoutExercise
    @State private var answers = ProgressionAnswers()
    @State private var loaded = false
    @State private var reviewedAdvice: ProgressionAdvice?
    @State private var loadText = ""
    @State private var loadUnit: PlanUnit = .kg
    @State private var availableOnEquipment = false
    @State private var localError: String?

    private var savedWorkout: WorkoutSession? { store.workouts.first { $0.id == workout.id } }
    private var savedExercise: WorkoutExercise? { savedWorkout?.exercises.first { $0.id == exercise.id } }
    private var activeContext: (String, PlanSession, PlanExercise)? {
        guard let revision = store.activePlanRevisionID, let plan = store.activePlan, plan.id == workout.planID,
              let session = plan.days.flatMap(\.sessions).first(where: { $0.id == workout.prescription.id }),
              let occurrence = session.exercises.first(where: { $0.instanceId == exercise.prescription.instanceId && $0.exerciseId == exercise.prescription.exerciseId }) else { return nil }
        return (revision, session, occurrence)
    }
    private var currentConfiguration: ProgressionConfiguration {
        guard let context = activeContext else { return .init() }
        return store.progression.configuration(planRevisionID: context.0, sessionID: context.1.id, exerciseInstanceID: context.2.instanceId) ?? .init()
    }
    private var isRun: Bool { [.easyRun, .longRun].contains(currentConfiguration.implementedPolicy) }
    private var history: [ProgressionExposure] {
        guard let context = activeContext else { return [] }
        return store.progression.exposures(workouts: store.includedWorkouts, recovery: store.recoveryRecords,
                                           currentPlanRevisionID: context.0, currentSessionID: context.1.id, currentExercise: context.2)
    }
    private var morningPrompt: RecoveryPrompt? {
        guard let savedWorkout, let ended = savedWorkout.endedAt else { return nil }
        return RecoverySchedule.due(sessions: [.init(sessionID: savedWorkout.id, endedAt: ended, timeZoneID: savedWorkout.timeZoneIdentifier)],
                                    answers: [], now: Date(), lookbackDays: 36_600).first { $0.phase == .nextMorning }
    }
    private var needsLoad: Bool {
        guard let reviewedAdvice else { return false }
        return !isRun && ([ProgressionAction.increase, .reduce].contains(reviewedAdvice.action) || reviewedAdvice.nextStep == 3)
    }
    private var enteredLoad: PlanQuantity? {
        guard let value = Double(loadText), value.isFinite, (0...10_000).contains(value) else { return nil }
        return .init(value: value, unit: loadUnit)
    }
    private var accepted: FutureProgressionTarget? { store.progression.acceptedTarget(workoutID: workout.id, exerciseID: exercise.id) }

    var body: some View {
        Form {
            Section {
                Text(exercise.prescription.name).font(.title2.bold())
                Text(workout.prescription.name).foregroundStyle(.secondary)
                if let ended = savedWorkout?.endedAt {
                    Text("Finished \(ended.formatted(date: .abbreviated, time: .shortened))")
                    Text("Recovery date uses \(workout.timeZoneIdentifier).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Completed sets", value: "\(savedExercise?.completedSetCount ?? 0) of \(exercise.prescription.target.sets)")
                Text("Recorded effort stays as entered. Unknown answers do not qualify an increase.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let accepted {
                Section("Accepted future target") {
                    Label("Saved for future sessions", systemImage: "checkmark.circle")
                    Text(futureSummary(accepted))
                    Text("Accepted \(accepted.acceptedAt.formatted(date: .abbreviated, time: .shortened)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                if let context = activeContext {
                    Section {
                        NavigationLink {
                            ProgressionEnrollmentView(planRevisionID: context.0, session: context.1, exercise: context.2)
                        } label: { Label(currentConfiguration.optedIn ? "Review progression rule" : "Choose a progression rule", systemImage: "slider.horizontal.3") }
                        if !currentConfiguration.optedIn { Text("This exercise currently uses manual progression.").foregroundStyle(.secondary) }
                    }
                } else {
                    Section { Text("This exercise is no longer part of the active plan. Its recorded results remain available; no future change can be applied here.") }
                }
                answersSection
                Section("Following-morning recovery") {
                    if let morningPrompt {
                        NavigationLink {
                            RecoveryEntryView(prompt: morningPrompt)
                        } label: { Label("Review this session’s recovery", systemImage: "heart.text.clipboard") }
                    } else {
                        Text("The following-morning answer becomes eligible on a later date in the workout’s captured timezone.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Save answers and review") { review() }
                        .buttonStyle(PrimaryActionStyle())
                        .disabled(savedWorkout?.state != .finished)
                }
                if let advice = reviewedAdvice {
                    Section(advice.title) {
                        Text(advice.detail)
                        if advice.qualifyingSessions > 0 && !isRun {
                            LabeledContent("Qualifying exposures", value: "\(advice.qualifyingSessions) of 2")
                        }
                    }
                    if !advice.legacyEvidence.isEmpty {
                        Section("Imported web history") {
                            Text("Original dates, targets, actuals and recovery answers are retained. No session time or Health workout has been invented. Only explicit comparable facts can support a second qualifying exposure.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(advice.legacyEvidence.suffix(3)) { evidence in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(evidence.date) · \(evidence.exerciseID)")
                                    Text(advice.usedLegacyRecordKey == evidence.recordKey ? "Used as the preceding qualifying exposure" : "Retained for comparison; not used to increase the qualifying count")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let issue = evidence.qualificationIssues.first { Text(issue).font(.caption) }
                                    if evidence.hasPendingDraft { Text("The newer draft remains separate and does not count as completed work.").font(.caption) }
                                }
                            }
                        }
                    }
                    if needsLoad {
                        Section(currentConfiguration.implementedPolicy == .pullUp ? "Next assistance" : "Next load") {
                            TextField("Enter an available setting", text: $loadText).keyboardType(.decimalPad)
                            Picker("Unit", selection: $loadUnit) { Text("kg").tag(PlanUnit.kg); Text("lb").tag(PlanUnit.lb) }
                            Toggle("This setting is available on my equipment", isOn: $availableOnEquipment)
                            Text("Choose the smallest suitable change available. The app checks its direction against all logged working sets.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if advice.canAccept {
                        Section {
                            Button("Use for future sessions") { accept(advice) }
                                .buttonStyle(PrimaryActionStyle())
                                .disabled(needsLoad && (enteredLoad == nil || !availableOnEquipment))
                            Text("Acceptance creates a new active plan revision. Your completed workout keeps its original prescription and results.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let message = localError ?? store.progression.errorMessage { Section { Text(message).foregroundStyle(.red) } }
            SaveErrorSection()
        }
        .navigationTitle("Next time")
        .navigationBarTitleDisplayMode(.inline)
        .formFlowBackground()
        .task {
            guard !loaded else { return }; loaded = true
            answers = store.progression.answers(workoutID: workout.id, exerciseID: exercise.id)
            loadUnit = store.profile.units == .imperial ? .lb : .kg
        }
        .onChange(of: answers) { _, _ in reviewedAdvice = nil }
        .onChange(of: loadText) { _, _ in availableOnEquipment = false }
        .onChange(of: loadUnit) { _, _ in availableOnEquipment = false }
    }

    private var answersSection: some View {
        Section("Your workout review") {
            if isRun {
                answerPicker("Was the run conversational?", selection: $answers.conversational)
            } else {
                answerPicker("Was technique clean throughout?", selection: $answers.technique, includeDifficult: true)
                Picker("Reps left at your hardest set", selection: $answers.reserve) {
                    Text("Not sure / use recorded RIR").tag(Int?.none)
                    ForEach(0...10, id: \.self) { Text("\($0) reps left").tag(Optional($0)) }
                }
                Text("A lower recorded RIR always takes priority. This answer can fill a missing review, without changing recorded sets.")
                    .font(.caption).foregroundStyle(.secondary)
                if currentConfiguration.pullUpStep == 3 {
                    answerPicker("Ready for a clean unassisted single with another rep left?", selection: $answers.readySingle)
                    Text("Confirm this only at your lowest practical assistance. The machine’s lowest setting alone does not establish readiness.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("Symptoms during the workout", selection: $answers.duringRating) {
                Text("Not sure / unanswered").tag(Int?.none)
                Text("0 · Comfortable").tag(Optional(0)); Text("1 · Mild").tag(Optional(1))
                Text("2 · Adjust").tag(Optional(2)); Text("3 · Stop").tag(Optional(3)); Text("4 · Red flag").tag(Optional(4))
            }
        }
    }
    private func answerPicker(_ title: String, selection: Binding<ProgressionAnswer>, includeDifficult: Bool = false) -> some View {
        Picker(title, selection: selection) {
            Text("Not sure").tag(ProgressionAnswer.unknown)
            Text("Yes").tag(ProgressionAnswer.yes)
            Text("No").tag(ProgressionAnswer.no)
            if includeDifficult { Text("Difficult to maintain").tag(ProgressionAnswer.difficult) }
        }
    }
    private func review() {
        guard let workout = savedWorkout, let exercise = savedExercise else { localError = "This workout is unavailable."; return }
        guard store.progression.saveAnswers(workout: workout, exercise: exercise, answers: answers) else { return }
        guard let context = activeContext, let source = history.first(where: { $0.exerciseID == exercise.id }) else {
            localError = "Answers saved. This exercise has no comparable active plan target."; return
        }
        do {
            let legacy = try store.progression.legacyEvidence(planID: source.session.planID, exerciseID: source.exercise.prescription.exerciseId)
            reviewedAdvice = ProgressionEngine.advice(for: source, history: history, currentPlanRevisionID: context.0, asOf: Date(), legacyHistory: legacy)
            loadText = ""; availableOnEquipment = false; localError = nil
        } catch { reviewedAdvice = nil; localError = error.localizedDescription }
    }
    private func accept(_ advice: ProgressionAdvice) {
        guard let context = activeContext, let plan = store.activePlan else { localError = "The active plan changed. Review again."; return }
        do {
            let selected = needsLoad ? enteredLoad : nil
            let legacy = try store.progression.legacyEvidence(planID: plan.id, exerciseID: context.2.exerciseId)
            let target = try ProgressionEngine.accept(advice, currentPlanID: plan.id, currentPlanRevisionID: context.0,
                                                      currentExercise: context.2, configuration: currentConfiguration, history: history,
                                                      enteredLoad: selected, availableEquipmentLoads: availableOnEquipment ? selected.map { [$0] } ?? [] : [],
                                                      legacyHistory: legacy, at: Date())
            if store.applyFutureProgressionTarget(target) { localError = nil; reviewedAdvice = nil }
        } catch { localError = error.localizedDescription }
    }
}

private enum ProgressionChoice: String, CaseIterable, Identifiable {
    case manual, strength, pullUp, easyRun, longRun
    var id: String { rawValue }
    var policy: BuiltInProgressionPolicy? {
        switch self { case .manual: nil; case .strength: .strength; case .pullUp: .pullUp; case .easyRun: .easyRun; case .longRun: .longRun }
    }
    init(policy: BuiltInProgressionPolicy?) {
        switch policy { case .strength: self = .strength; case .pullUp: self = .pullUp; case .easyRun: self = .easyRun; case .longRun: self = .longRun; case nil: self = .manual }
    }
    var label: String {
        switch self { case .manual: "Manual"; case .strength: "Strength: reps, then load"; case .pullUp: "Six-step pull-up roadmap"; case .easyRun: "Maintain an easy run"; case .longRun: "18-stage long-run roadmap" }
    }
    var explanation: String {
        switch self {
        case .manual: "Keep control of your own targets. Logging and history work without an automatic rule."
        case .strength: "Increase after two successive sessions meet every top rep target at matching load, with clean technique, enough reps in reserve and usual next-morning recovery."
        case .pullUp: "Each step has specific set, repetition and assistance requirements. Advancement needs two matching qualifying sessions; singles also require an explicit readiness answer."
        case .easyRun: "Keep this run easy and conversational. This rule does not increase its distance; long-run stages progress separately."
        case .longRun: "Advance one stage after the prescribed distance is completed at conversational effort and next-morning recovery is normal. Cutback stages remain part of the 18-stage sequence."
        }
    }
}

private func futureSummary(_ target: FutureProgressionTarget) -> String {
    var parts: [String] = []
    if let load = target.load { parts.append("Load \(load.value.formatted()) \(load.unit.rawValue)") }
    if let assistance = target.assistance { parts.append("Assistance \(assistance.value.formatted()) \(assistance.unit.rawValue)") }
    if let reps = target.restartReps { parts.append("Restart near \(reps) reps") }
    if let step = target.pullUpStep { parts.append("Pull-up step \(step)") }
    if let stage = target.longRunStage { parts.append("Long-run stage \(stage): \(BuiltInProgression.longRunStages[stage - 1].label)") }
    return parts.isEmpty ? "Keep the reviewed target and follow the effort and recovery guidance." : parts.joined(separator: " · ")
}
