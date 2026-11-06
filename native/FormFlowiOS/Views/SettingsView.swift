import SwiftUI
import UniformTypeIdentifiers
import FormFlowCore

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var categories = BackupCategory.defaultSelection
    @State private var exportedFile: BackupDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var staged: StagedBackup?
    @State private var problem: String?
    @State private var resetConfirmation = false

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Preferences") {
                Picker("Units", selection: $store.profile.units) {
                    Text("Metric").tag(UnitPreference.metric)
                    Text("Imperial").tag(UnitPreference.imperial)
                }
                Toggle("Require device authentication", isOn: Binding(get: { store.privacyLock.isEnabled }, set: { enabled in
                    if enabled { Task { await store.privacyLock.enable() } }
                    else { store.privacyLock.disable() }
                }))
                Text("Locks access when you leave the app. Active workout recording continues.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = store.privacyLock.errorMessage { Text(error).foregroundStyle(.red) }
            }
            Section("Your data") {
                Text("Your profile, prompts and training records are stored in the app. Copying prompts or saving a backup shares the selected content with the destination you choose. Device backups follow your system settings.")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(BackupCategory.allCases, id: \.self) { category in
                    Toggle(category.displayName, isOn: Binding(get: { categories.contains(category) }, set: { enabled in
                        if enabled { categories.insert(category) } else { categories.remove(category) }
                    }))
                }
                Text("Profile answers, prompt history and raw AI responses are excluded by default. Required plan prescriptions are included with workout records.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("JSON backups are unencrypted. Anyone with the file can read the included records; choose where you save or share it carefully.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Before an upgrade or a restore that replaces records, the app keeps a private database recovery copy on this device. These copies contain all saved categories and are removed by Reset local workspace.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Export selected data", systemImage: "square.and.arrow.up") {
                    do {
                        exportedFile = BackupDocument(data: try store.exportBackup(categories: categories))
                        exporting = true
                    } catch { problem = error.localizedDescription }
                }.disabled(categories.isEmpty)
                Button("Restore a backup", systemImage: "square.and.arrow.down") { importing = true }
                NavigationLink("Imported history and drafts") { ImportedHistoryView() }
            }
            Section("Apple Health") {
                Text(store.health?.status ?? "Health recording is optional.")
                Text("Choose Health recording before starting a workout. Manual logging works without permission. Imported history is never written to Health automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Check pending Health exports") { Task { await store.health?.reconcilePendingExports() } }
            }
            Section("Reset") {
                NavigationLink("Delete selected data") { WorkspaceDeletionView() }
                    .accessibilityIdentifier("delete-selected-data")
                Button("Reset local workspace", role: .destructive) { resetConfirmation = true }
                Text("Deletes this app's local plans, profile, prompts and logs. An offline Watch cannot restore these records after reconnecting. Backup files and workouts already saved in Apple Health remain where you saved them. Minimal Health export receipts are retained to prevent duplicate exports.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SaveErrorSection()
        }
        .navigationTitle("Settings")
        .formFlowBackground()
        .fileExporter(isPresented: $exporting, document: exportedFile, contentType: .json,
                      defaultFilename: "FormFlow-backup-\(Date().formatted(.iso8601.year().month().day()))") { result in
            if case .failure(let error) = result { problem = error.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText]) { result in
            do { staged = try store.stageBackup(try BackupDocument.read(result.get())) }
            catch { problem = error.localizedDescription }
        }
        .sheet(isPresented: Binding(get: { staged != nil }, set: { if !$0 { staged = nil } })) {
            if let staged { NavigationStack { BackupRestoreView(staged: staged) } }
        }
        .alert("Data action could not finish", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) { problem = nil }
        } message: { Text(problem ?? "Your original data has been preserved.") }
        .confirmationDialog("Reset this workspace? Export a backup first if you want to keep your records.", isPresented: $resetConfirmation, titleVisibility: .visible) {
            Button("Delete local data and reset", role: .destructive) { store.resetWorkspace() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct BackupRestoreView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let staged: StagedBackup
    @State private var choices: [String: BackupConflictChoice] = [:]
    @State private var problem: String?

    var body: some View {
        List {
            Section("Preview") {
                Text(staged.isLegacy ? "Existing web tracker backup" : "Native Form / Flow backup").font(.headline)
                ForEach(BackupCategory.allCases, id: \.self) { category in
                    if let count = staged.preview.counts[category] {
                        LabeledContent(category.displayName, value: "\(count)")
                    }
                }
                LabeledContent("Already saved duplicates", value: "\(staged.preview.duplicates.count)")
                LabeledContent("Drafts needing review", value: "\(staged.preview.pendingDraftCount)")
                Text("Only the categories in this file will be restored. Identical records are skipped. Active or paused workouts in a backup remain archived for review; restoring never starts recording or writes to Health.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !staged.preview.warnings.isEmpty || !staged.preview.unresolvedReferences.isEmpty {
                Section("Review notes") {
                    ForEach(staged.preview.warnings, id: \.self) { Text($0) }
                    ForEach(staged.preview.unresolvedReferences, id: \.self) { key in
                        Text("Missing plan reference: \(key). The imported record is retained for review.")
                    }
                }
            }
            if !staged.preview.conflicts.isEmpty {
                Section("Choose for each changed record") {
                    ForEach(staged.preview.conflicts, id: \.self) { key in
                        VStack(alignment: .leading) {
                            Text(key).font(.caption).textSelection(.enabled)
                            Picker("Saved record", selection: Binding<Int>(get: {
                                switch choices[key] { case .keepExisting: 1; case .replaceExisting: 2; case nil: 0 }
                            }, set: { value in
                                choices[key] = value == 1 ? .keepExisting : value == 2 ? .replaceExisting : nil
                            })) {
                                Text("Choose…").tag(0)
                                Text("Keep existing").tag(1)
                                Text("Replace from backup").tag(2)
                            }
                        }
                    }
                }
            }
            Section {
                Button("Restore reviewed backup") {
                    do { try store.restoreBackup(staged, choices: choices); dismiss() }
                    catch { problem = error.localizedDescription }
                }.buttonStyle(PrimaryActionStyle())
                    .disabled(staged.preview.conflicts.contains { choices[$0] == nil })
                if let problem { Text(problem).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Review backup")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .formFlowBackground()
    }
}

struct ArchivedBackupRecordsView: View {
    @Environment(AppStore.self) private var store
    @State private var records: [BackupRecord] = []
    @State private var problem: String?
    var body: some View {
        List {
            if records.isEmpty {
                ContentUnavailableView("No imported archives", systemImage: "archivebox", description: Text(problem ?? "Legacy records and restored workout drafts appear here for review."))
            }
            ForEach(records, id: \.key) { record in
                NavigationLink {
                    List {
                        Section {
                            Text("This imported record is preserved for review. Missing dates, timings and plan definitions have not been invented.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        BackupValueRows(value: record.payload)
                    }.navigationTitle(record.category.displayName)
                } label: {
                    VStack(alignment: .leading) {
                        Text(record.category.displayName).font(.headline)
                        Text(record.id).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.navigationTitle("Imported records")
            .task {
                do { records = try store.archivedBackupRecords() }
                catch { problem = error.localizedDescription }
            }
    }
}

struct BackupValueRows: View {
    let value: BackupJSONValue
    var body: some View {
        switch value {
        case .object(let object):
            ForEach(object.keys.sorted(), id: \.self) { key in
                if let child = object[key] {
                    DisclosureGroup(key) { AnyView(BackupValueRows(value: child)) }
                }
            }
        case .array(let values):
            ForEach(Array(values.enumerated()), id: \.offset) { index, child in
                DisclosureGroup("Item \(index + 1)") { AnyView(BackupValueRows(value: child)) }
            }
        case .string(let text): Text(text.isEmpty ? "Not supplied" : text).textSelection(.enabled)
        case .number(let number): Text(number.formatted())
        case .bool(let value): Text(value ? "Yes" : "No")
        case .null: Text("Unknown").foregroundStyle(.secondary)
        }
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
    static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= BackupImporter.maximumBytes {
            let chunk = try handle.read(upToCount: min(65_536, BackupImporter.maximumBytes + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= BackupImporter.maximumBytes else { throw BackupError.tooLarge }
        return data
    }
}

extension BackupCategory {
    var displayName: String {
        switch self {
        case .plans: "Plans"
        case .workouts: "Workouts"
        case .drafts: "Workout drafts"
        case .sleep: "Sleep"
        case .body: "Body measurements"
        case .recovery: "Recovery answers"
        case .activities: "Saved activities"
        case .settings: "Settings"
        case .legacyCheckIns: "Legacy check-ins"
        case .profile: "Profile answers · private"
        case .promptHistory: "Prompt history · private"
        case .rawAIResponses: "Raw AI responses · private"
        }
    }
}
