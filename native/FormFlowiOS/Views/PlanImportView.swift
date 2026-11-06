import SwiftUI
import UniformTypeIdentifiers
import FormFlowCore

struct PlanImportView: View {
    @Environment(AppStore.self) private var store
    @State private var showFilePicker = false
    @State private var fileError: String?
    @State private var correctionPrompt = ""
    @State private var showCorrection = false
    @State private var editorCandidate: WeeklyPlan?
    @State private var backupCandidate: StagedBackup?
    @State private var savedPlanMatch: PlanImportReview?
    private let maximumBytes = 1_048_576

    private var isSample: Bool {
        store.importText.trimmingCharacters(in: .whitespacesAndNewlines) == PlanContract.exampleJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Text(isSample ? "Explore a sample week" : "Bring your plan back").font(.title2.bold())
                Text(isSample
                     ? "This example shows the supported plan format. Review its exercises and schedule before choosing to use it; it was not personalized for you."
                     : "Paste your AI's complete response, or choose a JSON plan file. A plan is reviewed before it becomes your schedule.")
                    .foregroundStyle(.secondary)
            }
            Section {
                TextEditor(text: Binding(get: { store.importText }, set: { store.importText = $0; store.importResult = nil }))
                    .font(.body.monospaced())
                    .frame(minHeight: 260)
                    .accessibilityLabel("Paste AI response or plan JSON")
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Choose a plan file", systemImage: "doc") { showFilePicker = true }
            } header: { Text("AI response or plan JSON") }
            footer: { Text("Use the text field's Paste action. The app does not read your clipboard automatically. Supported plan files must be UTF-8 text and at most 1 MiB.") }
            if store.importText.utf8.count > maximumBytes {
                Section {
                    Label("This response is larger than 1 MiB. Ask your AI for a smaller supported weekly plan.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            Section {
                Button("Check plan", systemImage: "checkmark.doc") {
                    let data = Data(store.importText.utf8)
                    if Self.isBackup(data) {
                        do { backupCandidate = try store.stageBackup(data) }
                        catch { fileError = error.localizedDescription }
                    } else {
                        store.inspectImport()
                        store.saveDraft()
                    }
                }
                .buttonStyle(PrimaryActionStyle())
                .disabled(store.importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.importText.utf8.count > BackupImporter.maximumBytes)
            }

            if let result = store.importResult {
                Section(result.canActivate ? "Format checks passed" : "This response needs attention") {
                    Text(result.canActivate
                         ? "The app can read this plan. Review its schedule, exercises, and assumptions before using it."
                         : "Your active plan has not changed. These findings explain what needs to be corrected.")
                        .foregroundStyle(.secondary)
                    ForEach(Array(result.issues.enumerated()), id: \.offset) { _, issue in
                        PlanIssueRow(issue: issue)
                    }
                    if let savedPlanMatch, savedPlanMatch.requiresChoice {
                        Label(savedPlanMatch.exactMatches.isEmpty ? "This plan identity has saved revisions" : "This prescription is already saved", systemImage: "doc.on.doc")
                        Text("Choose whether to keep your existing schedule, use a new revision, or make an independent copy during week review.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let plan = result.plan, result.canActivate {
                        NavigationLink {
                            PlanWeekReviewView(plan: plan, issues: result.issues, isSample: isSample)
                        } label: {
                            Label("Review the week", systemImage: "calendar")
                                .font(.headline)
                        }
                        .accessibilityIdentifier("import-review-week")
                    }
                    if let plan = result.plan, result.sourceVersion == 2 {
                        Button(result.canActivate ? "Edit plan before review" : "Fix in the plan editor", systemImage: "square.and.pencil") {
                            editorCandidate = plan
                        }
                    }
                    if !result.issues.isEmpty || !result.canActivate {
                        Button("Review correction prompt", systemImage: "text.bubble") {
                            correctionPrompt = store.copyCorrectionPrompt()
                            showCorrection = true
                        }
                    }
                }
            }
            SaveErrorSection()
        }
        .formFlowBackground()
        .scrollDismissesKeyboard(.interactively)
        .task { updateSavedPlanMatch() }
        .onChange(of: store.importResult?.plan) { updateSavedPlanMatch() }
        .onChange(of: store.planRevision) { updateSavedPlanMatch() }
        .navigationTitle(isSample ? "Sample plan" : "Import plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { ClosePlanFlowButton() } }
        .navigationDestination(isPresented: $showCorrection) { CorrectionPromptView(prompt: correctionPrompt) }
        .sheet(item: $editorCandidate) { candidate in
            NavigationStack { PlanEditorView(plan: candidate) { _ in } }
        }
        .sheet(isPresented: Binding(get: { backupCandidate != nil }, set: { if !$0 { backupCandidate = nil } })) {
            if let backupCandidate { NavigationStack { BackupRestoreView(staged: backupCandidate) } }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.json, .plainText], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let data = try BackupDocument.read(url)
                if Self.isBackup(data) { backupCandidate = try store.stageBackup(data); return }
                guard data.count <= maximumBytes else { throw PlanFileError.tooLarge }
                guard let text = String(data: data, encoding: .utf8) else { throw PlanFileError.invalidEncoding }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PlanFileError.empty }
                store.importText = text
                store.importResult = nil
                store.saveDraft()
            } catch { fileError = error.localizedDescription }
        }
        .alert("Couldn't open plan file", isPresented: Binding(get: { fileError != nil }, set: { if !$0 { fileError = nil } })) {
            Button("OK", role: .cancel) { fileError = nil }
        } message: { Text(fileError ?? "Please choose another file.") }
    }

    private func updateSavedPlanMatch() {
        guard let result = store.importResult, result.canActivate, let plan = result.plan else { savedPlanMatch = nil; return }
        savedPlanMatch = try? store.reviewPlanImport(plan)
    }

    private static func isBackup(_ data: Data) -> Bool {
        guard data.count <= BackupImporter.maximumBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return root["workoutLogs"] != nil || root["format"] as? String == "formflow-native-backup"
    }
}

struct PlanIssueRow: View {
    let issue: PlanIssue
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(issue.severity == .error ? "Needs correction" : "Review this note", systemImage: issue.severity == .error ? "exclamationmark.circle" : "info.circle")
                .font(.subheadline.bold())
                .foregroundStyle(issue.severity == .error ? Color.red : Color.primary)
            Text(issue.message)
            Text(issue.path).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
        }.padding(.vertical, 4)
    }
}

private enum PlanFileError: LocalizedError {
    case tooLarge, invalidEncoding, empty
    var errorDescription: String? {
        switch self {
        case .tooLarge: "This plan is larger than the supported 1 MiB limit. Your existing data has not changed."
        case .invalidEncoding: "This file is not readable UTF-8 text. Choose the JSON plan itself rather than a screenshot or document."
        case .empty: "This file is empty. Choose a file containing the complete plan response."
        }
    }
}
