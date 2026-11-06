import SwiftUI
import UIKit
import FormFlowCore

struct PromptReviewView: View {
    @Environment(AppStore.self) private var store
    @State private var copied = false
    @State private var confirmRegeneration = false

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Text("Take your brief to your AI").font(.title2.bold())
                Text("Copy this prompt and paste it into your preferred AI. If it asks questions, answer there. Then copy its complete final response and return to import it.")
                Text("Pasting into another service shares everything in this prompt with that service. Review the text before copying.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            if store.isPromptOutdated {
                Section("Rebuild this saved prompt") {
                    Label("Your answers, privacy choices or the app’s prompt format have changed. Rebuild the prompt before copying.", systemImage: "exclamationmark.triangle")
                    Button("Rebuild from my latest profile") { confirmRegeneration = true }
                        .disabled(!store.profile.canGeneratePrompt)
                    if !store.profile.canGeneratePrompt {
                        Text("Complete the missing profile answers first.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                TextEditor(text: $store.promptDraft)
                    .font(.body.monospaced())
                    .frame(minHeight: 340)
                    .accessibilityLabel("Editable AI prompt")
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: { Text("Exact prompt · editable") }
            footer: { Text("Edits here change the copied prompt, not your profile or active plan. Your draft stays available when you leave the app.") }

            Section {
                Button(copied ? "Prompt copied" : "Copy prompt", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    store.saveDraft()
                    UIPasteboard.general.string = store.promptDraft
                    copied = true
                }
                .buttonStyle(PrimaryActionStyle())
                .disabled(store.promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isPromptOutdated)
                if copied {
                    Text("Paste into your AI, then return here when its plan is ready.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                NavigationLink { PlanImportView() } label: {
                    Label("Import AI response", systemImage: "square.and.arrow.down")
                }
            } header: { Text("Ready to import your plan") }

            if !store.isPromptOutdated {
                Section {
                    Button("Rebuild prompt from profile") { confirmRegeneration = true }
                        .disabled(!store.profile.canGeneratePrompt)
                } footer: { Text("Rebuilding replaces the current editable text with a fresh prompt from your saved answers.") }
            }
            SaveErrorSection()
        }
        .formFlowBackground()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("AI prompt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { ClosePlanFlowButton() } }
        .onChange(of: store.promptDraft) { copied = false }
        .confirmationDialog("Replace this prompt with one built from your latest profile?", isPresented: $confirmRegeneration, titleVisibility: .visible) {
            Button("Rebuild prompt") { store.generatePrompt(); copied = false }
            Button("Keep current draft", role: .cancel) {}
        }
    }
}

struct CorrectionPromptView: View {
    @State var prompt: String
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Text("Ask your AI to repair the response").font(.title2.bold())
                Text("This includes the response you imported and the format findings. Review it before copying into your AI, then bring the complete corrected plan back to the import screen.")
                    .foregroundStyle(.secondary)
            }
            Section("Correction prompt · editable") {
                TextEditor(text: $prompt)
                    .font(.body.monospaced())
                    .frame(minHeight: 360)
                    .accessibilityLabel("Correction prompt")
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            Section {
                Button(copied ? "Correction prompt copied" : "Copy correction prompt", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = prompt
                    copied = true
                }
                .buttonStyle(PrimaryActionStyle())
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                NavigationLink { PlanImportView() } label: {
                    Label("Import corrected response", systemImage: "square.and.arrow.down")
                }
            }
        }
        .formFlowBackground()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Repair response")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: prompt) { copied = false }
    }
}

struct ClosePlanFlowButton: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        Button("Close") {
            store.saveDraft()
            if store.errorMessage == nil {
                store.questionnairePresented = false
                store.promptPresented = false
                store.importPresented = false
            }
        }
    }
}
