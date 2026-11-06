import SwiftUI
import FormFlowCore

/// Edits a value copy. Only an explicitly validated save replaces the import draft.
struct PlanEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WeeklyPlan
    @State private var findings: [PlanIssue] = []
    @State private var editingSession: SessionEditSelection?
    @State private var confirmDiscard = false
    private let original: WeeklyPlan
    private let onSaved: (WeeklyPlan) -> Void

    init(plan: WeeklyPlan, onSaved: @escaping (WeeklyPlan) -> Void) {
        original = plan
        _draft = State(initialValue: plan)
        self.onSaved = onSaved
    }

    var body: some View {
        List {
            Section("Plan details") {
                TextField("Plan name", text: $draft.name)
                TextField("Plan instructions", text: optionalText($draft.instructions), axis: .vertical)
                    .lineLimit(2...6)
                TextField("Assumptions · one per line", text: linesText($draft.assumptions), axis: .vertical)
                    .lineLimit(2...6)
            }
            ForEach(Weekday.allCases) { weekday in
                Section(weekday.displayName) {
                    let sessions = draft.days.first(where: { $0.weekday == weekday })?.sessions ?? []
                    if sessions.isEmpty { Text("Rest day").foregroundStyle(.secondary) }
                    ForEach(sessions) { session in
                        Button {
                            editingSession = SessionEditSelection(session: session, weekday: weekday)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.name.isEmpty ? "Untitled session" : session.name).foregroundStyle(.primary)
                                Text("\(sessionDurationSummary(session)) · \(session.exercises.count) exercises")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { removeSession(session.id) }
                        }
                    }
                    if sessions.count < 3 {
                        Button("Add session", systemImage: "plus") {
                            let session = PlanSession(id: newEditorID("session"), name: "", kind: "strength", estimatedMinutes: 0, exercises: [])
                            editingSession = SessionEditSelection(session: session, weekday: weekday)
                        }
                    }
                }
            }
            Section {
                NavigationLink("Preview the edited week") {
                    List { WeeklyPlanSections(plan: draft) }
                        .formFlowBackground().navigationTitle("Draft preview")
                }
                Text("New items start with draft values. Review all prescriptions before saving. Your active plan and recorded workouts stay unchanged until you review and activate this draft.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !findings.isEmpty {
                Section("Review these findings") {
                    ForEach(Array(findings.enumerated()), id: \.offset) { _, issue in PlanIssueRow(issue: issue) }
                }
            }
            SaveErrorSection()
        }
        .formFlowBackground()
        .navigationTitle("Edit plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { if draft == original { dismiss() } else { confirmDiscard = true } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save draft") {
                    draft.assumptions = normalizedLines(draft.assumptions)
                    findings = PlanValidator.validate(draft)
                    guard !findings.contains(where: { $0.severity == .error }) else { return }
                    if store.replaceImportedPlan(draft) {
                        onSaved(draft)
                        dismiss()
                    }
                }.fontWeight(.semibold)
            }
        }
        .interactiveDismissDisabled(draft != original)
        .confirmationDialog("Discard these unsaved plan edits?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard edits", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .sheet(item: $editingSession) { selection in
            NavigationStack {
                SessionPlanEditorView(session: selection.session, weekday: selection.weekday) { session, weekday in
                    if let index = draft.days.firstIndex(where: { $0.weekday == weekday }),
                       let sessionIndex = draft.days[index].sessions.firstIndex(where: { $0.id == session.id }) {
                        draft.days[index].sessions[sessionIndex] = session
                    } else if let index = draft.days.firstIndex(where: { $0.weekday == weekday }) {
                        removeSession(session.id)
                        draft.days[index].sessions.append(session)
                    } else {
                        removeSession(session.id)
                        draft.days.append(PlanDay(weekday: weekday, sessions: [session]))
                    }
                    findings = []
                }
            }
        }
    }

    private func removeSession(_ id: String) {
        for index in draft.days.indices { draft.days[index].sessions.removeAll { $0.id == id } }
    }
}

private struct SessionEditSelection: Identifiable {
    let session: PlanSession
    let weekday: Weekday
    var id: String { session.id }
}

private struct SessionPlanEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session: PlanSession
    @State private var weekday: Weekday
    @State private var editingExercise: PlanExercise?
    @State private var confirmDiscard = false
    private let original: PlanSession
    private let originalDay: Weekday
    private let onApply: (PlanSession, Weekday) -> Void

    init(session: PlanSession, weekday: Weekday, onApply: @escaping (PlanSession, Weekday) -> Void) {
        _session = State(initialValue: session); _weekday = State(initialValue: weekday)
        original = session; originalDay = weekday; self.onApply = onApply
    }

    private var changed: Bool { session != original || weekday != originalDay }
    var body: some View {
        Form {
            Section("Session") {
                TextField("Session name", text: $session.name)
                Picker("Day", selection: $weekday) {
                    ForEach(Weekday.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Training type", selection: $session.kind) {
                    ForEach(["strength", "cardio", "mobility", "mixed"], id: \.self) { Text($0.capitalized).tag($0) }
                }
                EditorNumberRow("Estimated minutes", value: integerNumber($session.estimatedMinutes), limits: 1...1440, whole: true)
            }
            Section("Guidance") {
                TextField("Warm-up · one step per line", text: linesText($session.warmup), axis: .vertical).lineLimit(3...8)
                TextField("Session instructions", text: optionalText($session.instructions), axis: .vertical).lineLimit(2...6)
            }
            Section {
                ForEach(session.exercises) { exercise in
                    Button {
                        editingExercise = exercise
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(exercise.name.isEmpty ? "Untitled exercise" : exercise.name).foregroundStyle(.primary)
                            Text(exercise.target.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { session.exercises.removeAll { $0.id == exercise.id } }
                    }
                }
                .onMove { session.exercises.move(fromOffsets: $0, toOffset: $1) }
                if session.exercises.count < 30 {
                    Button("Add exercise", systemImage: "plus") {
                        editingExercise = PlanExercise(instanceId: newEditorID("item"), exerciseId: newEditorID("exercise"), name: "", measurement: .completion,
                                                       target: ExerciseTarget(sets: 1, restSeconds: 0))
                    }
                }
            } header: { Text("Exercises") }
            footer: { Text("A session needs at least one exercise. To make a rest day, remove its sessions from the week editor.") }
        }
        .formFlowBackground()
        .navigationTitle("Edit session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if changed { confirmDiscard = true } else { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") {
                    session.warmup = normalizedLines(session.warmup)
                    onApply(session, weekday)
                    dismiss()
                }
            }
            ToolbarItem(placement: .bottomBar) { EditButton() }
        }
        .interactiveDismissDisabled(changed)
        .confirmationDialog("Discard these session edits?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard edits", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .sheet(item: $editingExercise) { exercise in
            NavigationStack {
                ExercisePlanEditorView(exercise: exercise) { updated in
                    if let index = session.exercises.firstIndex(where: { $0.id == updated.id }) { session.exercises[index] = updated }
                    else { session.exercises.append(updated) }
                }
            }
        }
    }
}

struct ExercisePlanEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var exercise: PlanExercise
    @State private var confirmDiscard = false
    @State private var addReps = false
    @State private var addEffort = false
    private let original: PlanExercise
    private let onApply: (PlanExercise) -> Void
    private let allowsAlternatives: Bool

    init(exercise: PlanExercise, allowsAlternatives: Bool = true, onApply: @escaping (PlanExercise) -> Void) {
        _exercise = State(initialValue: exercise); original = exercise; self.onApply = onApply
        self.allowsAlternatives = allowsAlternatives
    }

    private var repKind: Bool { [.weightReps, .reps, .assistedReps].contains(exercise.measurement) }
    private var distanceKind: Bool { [.weightDistance, .distanceTime, .distance].contains(exercise.measurement) }
    private var durationKind: Bool { [.duration, .durationCalories, .distanceTime].contains(exercise.measurement) }

    var body: some View {
        Form {
            Section {
                TextField("Exercise name", text: $exercise.name)
                Picker("Record using", selection: $exercise.measurement) {
                    ForEach(MeasurementKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Optional exercise", isOn: $exercise.optional)
                TextField("Equipment · one item per line", text: linesText($exercise.equipment), axis: .vertical).lineLimit(2...5)
                TextField("Exercise instructions", text: optionalText($exercise.instructions), axis: .vertical).lineLimit(3...8)
            } header: { Text("Exercise") }
            footer: { Text("Renaming updates the label of this exercise. To prescribe a different movement with separate history, add a new exercise and remove this one.") }
            Section("Sets and rest") {
                EditorNumberRow("Sets", value: integerNumber($exercise.target.sets), limits: 1...20, whole: true)
                EditorNumberRow("Rest seconds", value: integerNumber($exercise.target.restSeconds), limits: 0...900, whole: true)
            }
            if repKind || exercise.target.reps != nil {
                Section("Repetitions") {
                    if exercise.target.reps != nil {
                        EditorNumberRow("Minimum reps", value: optionalRepBound(minimum: true), limits: 1...1000, whole: true)
                        EditorNumberRow("Maximum reps", value: optionalRepBound(minimum: false), limits: 1...1000, whole: true)
                        Button("Remove repetition target", role: .destructive) { exercise.target.reps = nil }
                    } else {
                        Button("Add repetition target", systemImage: "plus") { addReps = true }
                    }
                    if !repKind { incompatibleNote }
                }
            }
            if [.weightReps, .weightDistance].contains(exercise.measurement) || exercise.target.load != nil {
                QuantityTargetSection(title: "Planned load", quantity: $exercise.target.load, allowed: [.kg, .lb])
            }
            if exercise.measurement == .assistedReps || exercise.target.assistance != nil {
                QuantityTargetSection(title: "Planned assistance", quantity: $exercise.target.assistance, allowed: [.kg, .lb])
            }
            if durationKind || exercise.target.duration != nil {
                RangeTargetSection(title: "Duration", range: $exercise.target.duration, allowed: [.s, .min])
            }
            if distanceKind || exercise.target.distance != nil {
                RangeTargetSection(title: "Distance", range: $exercise.target.distance, allowed: [.m, .km, .mi])
            }
            if exercise.measurement == .durationCalories || exercise.target.calories != nil {
                RangeTargetSection(title: "Calories", range: $exercise.target.calories, allowed: [.kcal])
            }
            if exercise.measurement != .completion || exercise.target.effort != nil {
                Section {
                    if exercise.target.effort != nil {
                        Picker("Effort scale", selection: Binding(get: { exercise.target.effort?.kind ?? .rir }, set: { exercise.target.effort?.kind = $0 })) {
                            Text("Reps in reserve (RIR)").tag(EffortTarget.Kind.rir)
                            Text("Perceived exertion (RPE)").tag(EffortTarget.Kind.rpe)
                        }
                        EditorNumberRow("Minimum effort", value: optionalEffortBound(minimum: true), limits: 0...10, whole: true)
                        EditorNumberRow("Maximum effort", value: optionalEffortBound(minimum: false), limits: 0...10, whole: true)
                        Button("Remove effort target", role: .destructive) { exercise.target.effort = nil }
                    } else {
                        Button("Add effort target", systemImage: "plus") { addEffort = true }
                    }
                } header: { Text("Effort · optional") }
                footer: { Text("RIR is how many more repetitions you estimate you could do. RPE is perceived exertion from 0 to 10. These are planned targets, not a report of how a set felt.") }
            }
            Section("Target preview") { Text(exercise.target.summary) }
            Section("Options and intervals") {
                if allowsAlternatives {
                    NavigationLink("Exercise alternatives") { AlternativesPlanEditorView(alternatives: $exercise.alternatives) }
                }
                if [.duration, .durationCalories, .distance, .distanceTime].contains(exercise.measurement) {
                    NavigationLink("Interval sequence") { IntervalBlocksEditorView(blocks: $exercise.intervals) }
                }
            }
            if let policy = exercise.progressionPolicy {
                Section("Progression reference") {
                    Text("\(policy.id) · version \(policy.version)")
                    Text("This reference is preserved. Editing does not enable unsupported progression rules.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formFlowBackground()
        .navigationTitle("Edit exercise")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if exercise != original { confirmDiscard = true } else { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") {
                    exercise.equipment = normalizedLines(exercise.equipment)
                    onApply(exercise)
                    dismiss()
                }
            }
        }
        .interactiveDismissDisabled(exercise != original)
        .confirmationDialog("Discard these exercise edits?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard edits", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .sheet(isPresented: $addReps) {
            NavigationStack {
                EditorRangeEntry(title: "Repetition target", limits: 1...1000, whole: true) { lower, upper in
                    exercise.target.reps = RepRange(min: Int(lower), max: Int(upper))
                }
            }
        }
        .sheet(isPresented: $addEffort) {
            NavigationStack {
                EditorRangeEntry(title: repKind || exercise.measurement == .weightDistance ? "Reps in reserve" : "Perceived exertion", limits: 0...10, whole: true) { lower, upper in
                    exercise.target.effort = EffortTarget(kind: repKind || exercise.measurement == .weightDistance ? .rir : .rpe, min: Int(lower), max: Int(upper))
                }
            }
        }
    }

    private var incompatibleNote: some View { Text("This target is incompatible with the selected measurement. Remove it or change the measurement before saving the plan.").font(.caption).foregroundStyle(.red) }
    private func optionalRepBound(minimum: Bool) -> Binding<Double> {
        Binding(get: { Double(minimum ? exercise.target.reps?.min ?? 1 : exercise.target.reps?.max ?? 1) }, set: {
            if minimum { exercise.target.reps?.min = Int($0) } else { exercise.target.reps?.max = Int($0) }
        })
    }
    private func optionalEffortBound(minimum: Bool) -> Binding<Double> {
        Binding(get: { Double(minimum ? exercise.target.effort?.min ?? 0 : exercise.target.effort?.max ?? 0) }, set: {
            if minimum { exercise.target.effort?.min = Int($0) } else { exercise.target.effort?.max = Int($0) }
        })
    }
}

private struct QuantityTargetSection: View {
    let title: String
    @Binding var quantity: PlanQuantity?
    let allowed: [PlanUnit]
    @State private var adding = false
    var body: some View {
        Section {
            if quantity != nil {
                EditorNumberRow("Value", value: Binding(get: { quantity?.value ?? 0 }, set: { quantity?.value = $0 }), limits: 0...10000)
                Picker("Unit", selection: Binding(get: { quantity?.unit ?? allowed[0] }, set: { quantity?.unit = $0 })) {
                    ForEach(allowed, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Button("Remove \(title.lowercased())", role: .destructive) { quantity = nil }
            } else {
                Button("Add \(title.lowercased())", systemImage: "plus") { adding = true }
            }
        } header: { Text(title) }
        footer: { Text("Leave unspecified when the starting value is unknown. Changing the unit keeps the number; review and edit the value too.") }
        .sheet(isPresented: $adding) {
            NavigationStack {
                EditorNumberEntry(title: "\(title) (\(allowed[0].rawValue))", value: nil, limits: 0...10000, whole: false) {
                    quantity = PlanQuantity(value: $0, unit: allowed[0])
                }
            }
        }
    }
}

struct RangeTargetSection: View {
    let title: String
    @Binding var range: QuantityRange?
    let allowed: [PlanUnit]
    @State private var adding = false
    var body: some View {
        Section {
            if range != nil {
                EditorNumberRow("Minimum", value: Binding(get: { range?.min ?? 1 }, set: { range?.min = $0 }), limits: Double.leastNonzeroMagnitude...1_000_000)
                EditorNumberRow("Maximum", value: Binding(get: { range?.max ?? 1 }, set: { range?.max = $0 }), limits: Double.leastNonzeroMagnitude...1_000_000)
                Picker("Unit", selection: Binding(get: { range?.unit ?? allowed[0] }, set: { range?.unit = $0 })) {
                    ForEach(allowed, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Button("Remove \(title.lowercased()) target", role: .destructive) { range = nil }
            } else {
                Button("Add \(title.lowercased()) target", systemImage: "plus") { adding = true }
            }
        } header: { Text(title) }
        footer: { Text("Use equal minimum and maximum values for a fixed target. Changing the unit does not convert the numbers.") }
        .sheet(isPresented: $adding) {
            NavigationStack {
                EditorRangeEntry(title: "\(title) (\(allowed[0].rawValue))", limits: Double.leastNonzeroMagnitude...1_000_000) { lower, upper in
                    range = QuantityRange(min: lower, max: upper, unit: allowed[0])
                }
            }
        }
    }
}

/// A separate, validated value editor keeps incomplete or invalid text out of the typed draft.
private struct EditorNumberRow: View {
    let title: String
    @Binding var value: Double
    let limits: ClosedRange<Double>
    var whole = false
    @State private var showEditor = false
    init(_ title: String, value: Binding<Double>, limits: ClosedRange<Double>, whole: Bool = false) {
        self.title = title; _value = value; self.limits = limits; self.whole = whole
    }
    var body: some View {
        Button { showEditor = true } label: {
            LabeledContent(title, value: String(value))
                .foregroundStyle(.primary)
        }
        .sheet(isPresented: $showEditor) {
            NavigationStack {
                EditorNumberEntry(title: title, value: value, limits: limits, whole: whole) { value = $0 }
            }.presentationDetents([.medium])
        }
    }
}

private struct EditorNumberEntry: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let limits: ClosedRange<Double>
    let whole: Bool
    let onApply: (Double) -> Void
    @State private var text: String
    init(title: String, value: Double?, limits: ClosedRange<Double>, whole: Bool, onApply: @escaping (Double) -> Void) {
        self.title = title; self.limits = limits; self.whole = whole; self.onApply = onApply
        _text = State(initialValue: value.map { String($0) } ?? "")
    }
    private var parsed: Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")), value.isFinite,
              limits.contains(value), !whole || value.rounded() == value else { return nil }
        return value
    }
    var body: some View {
        Form {
            TextField(title, text: $text).keyboardType(whole ? .numberPad : .decimalPad)
                .accessibilityLabel(title)
            if parsed == nil {
                Text("Enter \(whole ? "a whole number" : "a number") \(editorLimitDescription(limits)).")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Apply") { if let parsed { onApply(parsed); dismiss() } }.disabled(parsed == nil) }
        }
    }
}

private struct EditorRangeEntry: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let limits: ClosedRange<Double>
    var whole = false
    let onApply: (Double, Double) -> Void
    @State private var minimum = ""
    @State private var maximum = ""
    private var parsed: (Double, Double)? {
        guard let lower = number(minimum), let upper = maximum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? lower : number(maximum),
              limits.contains(lower), limits.contains(upper), upper >= lower,
              !whole || (lower.rounded() == lower && upper.rounded() == upper) else { return nil }
        return (lower, upper)
    }
    var body: some View {
        Form {
            Section {
                TextField("Minimum or fixed target", text: $minimum).keyboardType(whole ? .numberPad : .decimalPad)
                TextField("Maximum, if different", text: $maximum).keyboardType(whole ? .numberPad : .decimalPad)
            } footer: { Text("Leave maximum blank for a fixed target. Enter \(whole ? "whole numbers" : "numbers") \(editorLimitDescription(limits)).") }
            if !minimum.isEmpty && parsed == nil { Text("Enter an ordered, valid range before applying.").foregroundStyle(.red) }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Apply") { if let parsed { onApply(parsed.0, parsed.1); dismiss() } }.disabled(parsed == nil) }
        }
    }
    private func number(_ text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")), value.isFinite else { return nil }
        return value
    }
}

private func newEditorID(_ prefix: String) -> String { "\(prefix)-\(UUID().uuidString.lowercased())" }
private func integerNumber(_ source: Binding<Int>) -> Binding<Double> {
    Binding(get: { Double(source.wrappedValue) }, set: { source.wrappedValue = Int($0) })
}
private func optionalText(_ source: Binding<String?>) -> Binding<String> {
    Binding(get: { source.wrappedValue ?? "" }, set: { source.wrappedValue = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 })
}
private func linesText(_ source: Binding<[String]>) -> Binding<String> {
    Binding(get: { source.wrappedValue.joined(separator: "\n") }, set: {
        source.wrappedValue = $0.components(separatedBy: .newlines)
    })
}
private func normalizedLines(_ values: [String]) -> [String] {
    values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}
private func editorLimitDescription(_ limits: ClosedRange<Double>) -> String {
    limits.lowerBound == Double.leastNonzeroMagnitude
        ? "greater than zero and no larger than \(limits.upperBound.formatted())"
        : "between \(limits.lowerBound.formatted()) and \(limits.upperBound.formatted())"
}
