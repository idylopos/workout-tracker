import SwiftUI
import FormFlowCore

struct SavedDraftsView: View {
    @Environment(AppStore.self) private var store
    @State private var drafts: [PlanDraftHistoryRecord] = []
    @State private var problem: String?
    var body: some View {
        List {
            Section("Previous plan responses") {
                if drafts.isEmpty { Text("Earlier responses appear here when you replace a reviewed draft.").foregroundStyle(.secondary) }
                ForEach(drafts, id: \.id) { draft in
                    NavigationLink(draft.createdAt.formatted(date: .abbreviated, time: .shortened)) {
                        List {
                            Section {
                                Text("Load this response into the import draft, then check and review it. Your active plan changes only after activation.")
                                Button("Load as import draft") { store.restoreImportDraft(draft.sourceText) }
                            }
                            Section("Saved response") {
                                Text(draft.sourceText).font(.body.monospaced()).textSelection(.enabled)
                            }
                        }.navigationTitle("Saved plan draft")
                    }
                }
            }
            Section("Previous prompts") {
                if store.savedPromptHistory.isEmpty { Text("Rebuilding a prompt preserves its previous version here.").foregroundStyle(.secondary) }
                ForEach(Array(store.savedPromptHistory.enumerated()), id: \.offset) { _, prompt in
                    NavigationLink(prompt.createdAt.formatted(date: .abbreviated, time: .shortened)) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("This is an earlier prompt. Its profile and sharing choices may differ from your current answers.").foregroundStyle(.secondary)
                                Text(prompt.text).font(.body.monospaced()).textSelection(.enabled)
                            }.padding()
                        }.navigationTitle("Saved prompt")
                    }
                }
            }
            if let problem { Text(problem).foregroundStyle(.red) }
        }.navigationTitle("Saved drafts")
            .task {
                do { drafts = try store.savedPlanDrafts() }
                catch { problem = error.localizedDescription }
            }
    }
}


struct SavedPlanRevisionsView: View {
    @Environment(AppStore.self) private var store
    @State private var revisions: [SavedPlanRevision] = []
    @State private var problem: String?

    var body: some View {
        List {
            Section {
                Text("Every activation keeps its prescription here. Viewing or loading a revision does not change the current schedule or recorded workouts.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if revisions.isEmpty && problem == nil {
                ContentUnavailableView("No saved revisions", systemImage: "clock.arrow.circlepath",
                    description: Text("Review and activate a plan to create its first saved revision."))
            }
            ForEach(revisions) { revision in
                NavigationLink {
                    SavedPlanRevisionDetailView(revision: revision)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(revision.plan.name).font(.headline)
                        Text("Revision \(revision.sequence) · saved \(revision.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        if revision.id == store.activePlanRevisionID { Label("Current schedule", systemImage: "checkmark.circle").font(.caption) }
                        else { Text("Archived prescription").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if let problem { Section { Text(problem).foregroundStyle(.red); Button("Reload revisions") { reload() } } }
            SaveErrorSection()
        }
        .navigationTitle("Plan revisions")
        .formFlowBackground()
        .task { reload() }
        .onChange(of: store.planRevision) { reload() }
    }
    private func reload() {
        do { revisions = try store.savedPlanRevisions(); problem = nil }
        catch { problem = error.localizedDescription }
    }
}

private struct SavedPlanRevisionDetailView: View {
    @Environment(AppStore.self) private var store
    let revision: SavedPlanRevision
    var body: some View {
        List {
            Section {
                Text(revision.plan.name).font(.title2.bold())
                LabeledContent("Saved revision", value: String(revision.sequence))
                LabeledContent("Original schedule began", value: revision.activationDate.formatted(date: .abbreviated, time: .omitted))
                Text("This is an immutable prescription. Reusing it creates a reviewed draft; an activation appends a new revision.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Review for reuse") { store.reviewSavedPlanRevision(revision.id) }
            }
            if !revision.plan.assumptions.isEmpty {
                Section("Original assumptions") { ForEach(Array(revision.plan.assumptions.enumerated()), id: \.offset) { _, text in Text(text) } }
            }
            if let instructions = revision.plan.instructions { Section("Original guidance") { Text(instructions) } }
            WeeklyPlanSections(plan: revision.plan)
            let workouts = store.workouts.filter { $0.planRevisionID == revision.id }
            Section("Workouts recorded with this revision") {
                if workouts.isEmpty { Text("No workouts use this revision.").foregroundStyle(.secondary) }
                ForEach(workouts) { workout in
                    Button { store.presentWorkout(workout) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(workout.prescription.name)
                            Text("\(workout.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(workout.state.rawValue.capitalized)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            SaveErrorSection()
        }
        .formFlowBackground()
        .navigationTitle("Revision \(revision.sequence)")
        .navigationBarTitleDisplayMode(.inline)
    }
}
