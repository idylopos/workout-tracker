import SwiftUI
import FormFlowCore

struct BuiltInProgramView: View {
    @Environment(AppStore.self) private var store
    @State private var block = 1
    @State private var pullUpStep = 1
    @State private var longRunStage = 1
    @State private var confirmReplacement = false
    var body: some View {
        Form {
            Section {
                Text("The existing Form / Flow program").font(.title2.bold())
                Text("This is the program from the web tracker. Choose its current block and roadmap positions, then review the full week. These settings are your choices; the app does not infer that the program suits your background.")
                    .foregroundStyle(.secondary)
            }
            Section("Program settings") {
                Picker("Block", selection: $block) {
                    Text("Block 1").tag(1)
                    Text("Block 2").tag(2)
                }
                Picker("Pull-up step", selection: $pullUpStep) {
                    ForEach(BuiltInProgression.pullUpSteps) { step in Text("\(step.id). \(step.name)").tag(step.id) }
                }
                Picker("Long-run stage", selection: $longRunStage) {
                    ForEach(BuiltInProgression.longRunStages) { stage in Text("\(stage.id). \(stage.label)").tag(stage.id) }
                }
                Text("Split-session spacing and source guidance remain visible in the plan. Unspecified component durations stay unknown. Progression policies require a separate explicit choice after activation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Load program for review") {
                    if store.importText.isEmpty { prepare() } else { confirmReplacement = true }
                }.buttonStyle(PrimaryActionStyle())
            }
            SaveErrorSection()
        }.navigationTitle("Existing program")
            .confirmationDialog("Replace the current import draft with this program? The previous draft will be retained, and your active plan stays in place until you activate a replacement.", isPresented: $confirmReplacement, titleVisibility: .visible) {
                Button("Load and review program") { prepare() }
                Button("Keep current draft", role: .cancel) {}
            }
    }
    private func prepare() {
        do {
            let plan = try BuiltInPlans.plan(block: block, pullUpStep: pullUpStep, longRunStage: longRunStage)
            if store.replaceImportedPlan(plan) { store.importPresented = true }
        } catch { store.errorMessage = error.localizedDescription }
    }
}
