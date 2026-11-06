import SwiftUI
import FormFlowCore

struct ExtraActivityView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var sessionID: UUID?
    @State private var exercise = PlanExercise(instanceId: "extra-\(UUID().uuidString.lowercased())",
        exerciseId: "activity-\(UUID().uuidString.lowercased())", name: "", measurement: .completion,
        target: .init(sets: 1, restSeconds: 0))
    @State private var editing = false
    @State private var saveTemplate = false
    @State private var templates: [PlanExercise] = []
    @State private var legacyActivities: [LegacySavedActivityReview] = []
    @State private var reviewingLegacy: LegacySavedActivityReview?
    @State private var selectedLegacy: LegacySavedActivityReview?
    private var destination: UUID? { sessionID ?? store.currentWorkout?.id }
    private var issues: [PlanIssue] {
        PlanValidator.validate(.init(id: "extra-review", name: "Activity review", days: [
            .init(weekday: .monday, sessions: [.init(id: "extra", name: "Extra activity", kind: "mixed",
                estimatedMinutes: 0, exercises: [exercise])])
        ])).filter { $0.severity == .error }
    }
    var body: some View {
        Form {
            Section {
                Text(destination == nil ? "Record an activity outside your plan" : "Add activity to your current workout").font(.headline)
                Text("Enter your own activity and intended measurements. Actual results begin empty and are recorded separately.").foregroundStyle(.secondary)
                Button(exercise.name.isEmpty ? "Describe activity" : "Edit activity") { editing = true }
                if !exercise.name.isEmpty {
                    Text(exercise.name)
                    Text(exercise.target.summary).font(.subheadline)
                }
                if let selectedLegacy {
                    Label("Reviewed from web activity: \(selectedLegacy.name)", systemImage: "archivebox")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("The original web record is retained. Only your reviewed native targets will be used; actual results still begin empty.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(selectedLegacy == nil ? "Save as a reusable activity" : "Save a native reusable copy", isOn: $saveTemplate)
            }
            if !templates.isEmpty {
                Section("Saved activities") {
                    ForEach(templates) { template in
                        Button(template.name) {
                            exercise = template
                            exercise.instanceId = "extra-\(UUID().uuidString.lowercased())"
                            selectedLegacy = nil
                        }
                    }
                }
            }
            if !legacyActivities.isEmpty {
                Section {
                    ForEach(legacyActivities) { activity in
                        Button { reviewingLegacy = activity } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(activity.name).foregroundStyle(.primary)
                                Text(activity.measurement?.displayName ?? "Measurement needs correction")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Text(activity.canPrepareDraft ? "Review and add intended targets" : "Review preserved fields and create a corrected activity")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("Saved web activities") }
                footer: { Text("Web templates saved a name and measurement type, without numeric targets. Add your intended targets before recording or saving a native copy.") }
            }
            if !exercise.name.isEmpty {
                ForEach(issues) { issue in Text(issue.message).foregroundStyle(.red) }
            }
            Section {
                Button(destination == nil ? "Start this activity" : "Add to workout") {
                    guard issues.isEmpty else { return }
                    if saveTemplate && !store.saveExtraActivityTemplate(exercise, legacySource: selectedLegacy) { return }
                    if let destination {
                        if store.applyWorkoutCommand(.addExtraExercise(exercise: exercise), sessionID: destination) { dismiss() }
                    } else if store.startExtraActivity(exercise) { dismiss() }
                }.buttonStyle(PrimaryActionStyle()).disabled(!issues.isEmpty)
            }
            SaveErrorSection()
        }.navigationTitle("Extra activity")
            .sheet(isPresented: $editing) {
                NavigationStack { ExercisePlanEditorView(exercise: exercise) { exercise = $0 } }
            }
            .sheet(item: $reviewingLegacy) { activity in
                NavigationStack {
                    LegacySavedActivityReviewView(activity: activity) { reviewed in
                        exercise = reviewed
                        exercise.instanceId = "extra-\(UUID().uuidString.lowercased())"
                        selectedLegacy = activity
                    }
                }
            }
            .task {
                do { templates = try store.savedExtraActivities() }
                catch { store.errorMessage = error.localizedDescription }
                do { legacyActivities = try store.legacySavedActivities().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
                catch { store.errorMessage = error.localizedDescription }
            }
    }
}

private struct LegacySavedActivityReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let activity: LegacySavedActivityReview
    let onApply: (PlanExercise) -> Void
    @State private var draft: PlanExercise
    init(activity: LegacySavedActivityReview, onApply: @escaping (PlanExercise) -> Void) {
        self.activity = activity; self.onApply = onApply
        let value = activity.reviewDraft() ?? PlanExercise(instanceId: "extra-\(UUID().uuidString.lowercased())",
            exerciseId: "activity-\(UUID().uuidString.lowercased())",
            name: activity.name.count <= 80 && activity.original["name"]?.string != nil ? activity.name : "",
            measurement: .completion, target: .init(sets: 1, restSeconds: 0))
        _draft = State(initialValue: value)
    }
    var body: some View {
        List {
            Section("Preserved web activity") {
                Text(activity.name).font(.headline)
                LabeledContent("Saved activity type", value: activity.activityType ?? "Unknown")
                LabeledContent("Saved measurement", value: activity.originalMeasurement ?? "Unknown")
                if !activity.sourceUnits.isEmpty {
                    LabeledContent("Web measurement units", value: activity.sourceUnits.map(\.rawValue).joined(separator: ", "))
                }
                Text("No target duration, distance, calories or effort was saved in this template. These remain blank. The new draft begins with one recording row and no between-set rest; review these choices too.")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(Array(activity.issues.enumerated()), id: \.offset) { item in
                    Text(item.element).font(.subheadline).foregroundStyle(.secondary)
                }
                NavigationLink("Inspect original fields") {
                    List { BackupValueRows(value: activity.original) }.navigationTitle("Original activity")
                }
            }
            Section {
                NavigationLink(activity.canPrepareDraft ? "Review activity targets" : "Create corrected activity manually") {
                    ExercisePlanEditorView(exercise: draft, allowsAlternatives: false) { exercise in
                        onApply(exercise)
                        dismiss()
                    }
                }
                Text("Preparing a draft does not record a workout or change your original archive. Supported targets must validate before you can start or save the native activity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Review web activity")
            .formFlowBackground()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}
