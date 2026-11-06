import SwiftUI

struct WorkspaceDeletionView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<WorkspaceDeletionCategory> = []
    @State private var preview: WorkspaceDeletionPreview?
    @State private var problem: String?
    @State private var confirming = false

    var body: some View {
        Form {
            if let preview {
                Section("Review deletion") {
                    ForEach(WorkspaceDeletionCategory.allCases.filter { preview.selection.contains($0) }) { category in
                        Label(category.title, systemImage: "checkmark")
                    }
                }
                Section("Records to remove") {
                    ForEach(preview.rows) { row in LabeledContent(row.title, value: row.count.formatted()) }
                    if preview.rows.isEmpty { Text("No saved records match this selection.") }
                }
                Section("What this includes") {
                    ForEach(preview.warnings, id: \.self) { Text($0).font(.subheadline) }
                    Text("Kept reviewed plans and historical notes are not searched for or rewritten to remove words. Choose their categories too if you want those records removed.")
                        .font(.subheadline)
                }
                Section {
                    Button("Delete reviewed data", role: .destructive) { confirming = true }
                        .accessibilityIdentifier("delete-reviewed-data")
                    Button("Change selection") { self.preview = nil }
                }
            } else {
                Section {
                    Text("Choose data to remove from this workspace. These choices are separate from backup export choices; nothing is selected automatically.")
                }
                Section("Delete from this app") {
                    ForEach(WorkspaceDeletionCategory.allCases) { category in
                        Toggle(isOn: Binding(get: { selection.contains(category) }, set: { enabled in
                            if enabled { selection.insert(category) } else { selection.remove(category) }
                        })) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(category.title)
                                Text(category.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("delete-category-\(category.rawValue)")
                    }
                }
                Section {
                    Button("Review deletion") {
                        do { preview = try store.previewDeletion(selection: selection); problem = nil }
                        catch { problem = error.localizedDescription }
                    }.disabled(selection.isEmpty)
                        .accessibilityIdentifier("review-deletion")
                }
            }
            if let problem { Section { Text(problem).foregroundStyle(.red) } }
            SaveErrorSection()
        }
        .formFlowBackground()
        .navigationTitle("Delete selected data")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete the reviewed data? This cannot be undone in the app.", isPresented: $confirming, titleVisibility: .visible) {
            Button("Delete reviewed data", role: .destructive) {
                if let preview, store.deleteSelectedData(preview) { dismiss() }
                else { self.preview = nil }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
