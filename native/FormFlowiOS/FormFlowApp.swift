import SwiftUI
import SwiftData

@main
struct FormFlowApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: AppStore?
    @State private var container: ModelContainer?
    @State private var startupError: String?
    @State private var recovery: WorkspaceStoreRecovery?
    @State private var recoveryDefaults = UserDefaults.standard

    var body: some Scene {
        WindowGroup {
            Group {
                if let store {
                    Group {
                        if store.requiresWorkspaceReload {
                            ContentUnavailableView {
                                Label("Reload your workspace", systemImage: "externaldrive.badge.exclamationmark")
                            } description: {
                                Text(store.errorMessage ?? "Your changes were saved, but the workspace could not be loaded. Retry before making another change.")
                            } actions: {
                                Button("Retry loading", action: store.retryWorkspaceReload).buttonStyle(.borderedProminent)
                            }
                        } else if store.privacyLock.isLocked {
                            PrivacyLockView(lock: store.privacyLock)
                        } else {
                            RootView()
                        }
                    }
                        .environment(store)
                        .onChange(of: store.profile) { store.saveDraft() }
                        .onChange(of: store.onboardingStep) { store.saveDraft() }
                        .onChange(of: store.promptDraft) { store.saveDraft() }
                        .onChange(of: store.importText) { store.saveDraft() }
                        .onChange(of: scenePhase) {
                            if scenePhase == .background { store.privacyLock.lock() }
                        }
                } else if let startupError {
                    WorkspaceRecoveryView(message: startupError, recovery: recovery,
                                          defaults: recoveryDefaults, retry: openWorkspace)
                } else {
                    ProgressView("Opening your workspace…")
                }
            }
            .task { if store == nil && startupError == nil { openWorkspace() } }
        }
    }

    @MainActor private func openWorkspace() {
        do {
            let schema = WorkspaceSchema.current
            var storeName = "FormFlow"
            #if DEBUG
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                storeName = "FormFlowHostedTests"
            }
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--ui-testing-workspace"), arguments.indices.contains(index + 1),
               let id = UUID(uuidString: arguments[index + 1]) {
                storeName = "FormFlowUITests-\(id.uuidString)"
            }
            #endif
            let configuration = ModelConfiguration(storeName, schema: schema, cloudKitDatabase: .none)
            let isTesting = storeName != "FormFlow"
            let defaults = isTesting ? UserDefaults(suiteName: storeName) ?? .standard : .standard
            recoveryDefaults = defaults
            let recovery = WorkspaceStoreRecovery(storeURL: configuration.url)
            self.recovery = recovery
            try recovery.prepareToOpen()
            let container = try ModelContainer(for: schema, migrationPlan: WorkspaceMigrationPlan.self,
                                               configurations: [configuration])
            let store = try AppStore(context: container.mainContext,
                                     bridge: PlanBridge(isEnabled: !isTesting), healthEnabled: !isTesting,
                                     privacyDefaults: defaults)
            try recovery.didOpenSuccessfully()
            self.container = container
            self.store = store
            startupError = nil
        } catch {
            startupError = error.localizedDescription
        }
    }
}
