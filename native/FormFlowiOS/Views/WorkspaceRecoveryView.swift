import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceRecoveryView: View {
    let message: String
    let recovery: WorkspaceStoreRecovery?
    let retry: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var lock: AppPrivacyLock
    @State private var document: WorkspaceRecoveryDocument?
    @State private var exporting = false
    @State private var exportError: String?

    init(message: String, recovery: WorkspaceStoreRecovery?, defaults: UserDefaults, retry: @escaping () -> Void) {
        self.message = message
        self.recovery = recovery
        self.retry = retry
        _lock = State(initialValue: AppPrivacyLock(defaults: defaults))
    }

    var body: some View {
        Group {
            if lock.isLocked {
                PrivacyLockView(lock: lock)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Label("Couldn’t open your saved data", systemImage: "externaldrive.badge.exclamationmark")
                            .font(.title2.bold())
                        Text("Your saved files have been preserved. \(message)")
                        Button("Try again", action: retry).buttonStyle(.borderedProminent)
                        if let recovery {
                            Text("You can export the database files for recovery. This unencrypted folder includes all saved categories, including any profile, prompts and health-related entries. Keep it private. It requires a compatible app or developer-assisted recovery; it is not a normal JSON backup.")
                                .font(.subheadline)
                            Button("Export recovery files", systemImage: "square.and.arrow.up") {
                                do {
                                    document = try WorkspaceRecoveryDocument(wrapper: recovery.recoveryFiles())
                                    exporting = true
                                } catch { exportError = error.localizedDescription }
                            }.buttonStyle(.bordered)
                        }
                        if let exportError { Text(exportError).foregroundStyle(.red) }
                    }.padding()
                }
            }
        }
        .onChange(of: scenePhase) { if scenePhase == .background { lock.lock() } }
        .fileExporter(isPresented: $exporting, document: document, contentType: .folder,
                      defaultFilename: "FormFlow-Recovery") { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
            document = nil
        }
    }
}

struct WorkspaceRecoveryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }
    private let serialized: Data
    init(wrapper: FileWrapper) throws {
        guard let data = wrapper.serializedRepresentation else { throw CocoaError(.fileReadCorruptFile) }
        serialized = data
    }
    init(configuration: ReadConfiguration) throws { try self.init(wrapper: configuration.file) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let wrapper = FileWrapper(serializedRepresentation: serialized) else { throw CocoaError(.fileReadCorruptFile) }
        return wrapper
    }
}
