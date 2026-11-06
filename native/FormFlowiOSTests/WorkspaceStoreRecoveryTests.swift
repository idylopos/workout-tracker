import XCTest
import SwiftData
import SQLite3
import FormFlowCore
@testable import FormFlowiOS

@MainActor
final class WorkspaceStoreRecoveryTests: XCTestCase {
    func testUnversionedDevelopmentStoreAdoptsVersionWithoutLosingData() throws {
        let url = try temporaryStore()
        let legacySchema = Schema(WorkspaceSchemaV1.models)
        try autoreleasepool {
            let container = try ModelContainer(for: legacySchema, configurations: [configuration(url, schema: legacySchema)])
            var profile = TrainingProfile(); profile.goal = "Saved private goal"
            let snapshot = WorkspaceSnapshot(profile: profile)
            container.mainContext.insert(WorkspaceRecord(payload: try JSONEncoder().encode(snapshot)))
            try container.mainContext.save()
        }
        let recovery = WorkspaceStoreRecovery(storeURL: url)
        try recovery.prepareToOpen()
        let container = try ModelContainer(for: WorkspaceSchema.current, migrationPlan: WorkspaceMigrationPlan.self,
                                           configurations: [configuration(url)])
        let row = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WorkspaceRecord>()).first)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceSnapshot.self, from: row.payload).profile.goal, "Saved private goal")
        try recovery.didOpenSuccessfully()
        let version = try JSONDecoder().decode(WorkspaceStoreRecovery.Version.self, from: Data(contentsOf: recovery.versionURL))
        XCTAssertEqual(version.schemaVersion, 1)
        XCTAssertNil(version.pendingSnapshot)
        XCTAssertEqual(try snapshots(recovery).count, 1)
        try recovery.prepareToOpen()
        XCTAssertEqual(try snapshots(recovery).count, 1, "Opening the same schema must not duplicate recovery copies.")
    }

    func testSnapshotIncludesCommittedWALAndCanBeReadIndependently() throws {
        let url = try temporaryStore()
        let database = try openSQLite(url)
        defer { sqlite3_close(database) }
        try execute(database, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE entries(value INTEGER); INSERT INTO entries VALUES(42);")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-wal"))
        let snapshot = try WorkspaceStoreRecovery(storeURL: url).capture(reason: "test")
        let copied = try openSQLite(snapshot)
        defer { sqlite3_close(copied) }
        XCTAssertEqual(try integer(copied, "SELECT value FROM entries"), 42)
        try execute(database, "UPDATE entries SET value=99")
        XCTAssertEqual(try integer(copied, "SELECT value FROM entries"), 42)
    }

    func testFailedOpenRetriesKeepOriginalPreMigrationSnapshot() throws {
        let url = try temporaryStore()
        let database = try openSQLite(url)
        defer { sqlite3_close(database) }
        try execute(database, "CREATE TABLE entries(value INTEGER); INSERT INTO entries VALUES(1)")
        let recovery = WorkspaceStoreRecovery(storeURL: url)
        try recovery.prepareToOpen()
        let first = try XCTUnwrap(snapshots(recovery).first)
        let original = try Data(contentsOf: first)
        try execute(database, "UPDATE entries SET value=2")
        try recovery.prepareToOpen()
        XCTAssertEqual(try snapshots(recovery), [first])
        XCTAssertEqual(try Data(contentsOf: first), original)
        let version = try JSONDecoder().decode(WorkspaceStoreRecovery.Version.self, from: Data(contentsOf: recovery.versionURL))
        XCTAssertEqual(version.schemaVersion, 0, "A failed open never claims the upgrade completed.")
    }

    func testFutureVersionIsRefusedBeforeDatabaseMutation() throws {
        let url = try temporaryStore()
        let original = Data("future format payload".utf8)
        try original.write(to: url)
        let recovery = WorkspaceStoreRecovery(storeURL: url)
        try JSONEncoder().encode(WorkspaceStoreRecovery.Version(schemaVersion: 2)).write(to: recovery.versionURL)
        XCTAssertThrowsError(try recovery.prepareToOpen())
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.snapshotsURL.path))
    }

    func testMissingDatabaseWithRecoveryEvidenceNeverCreatesEmptyWorkspace() throws {
        let url = try temporaryStore()
        let recovery = WorkspaceStoreRecovery(storeURL: url)
        try FileManager.default.createDirectory(at: recovery.snapshotsURL, withIntermediateDirectories: true)
        let prior = recovery.snapshotsURL.appendingPathComponent("before-schema-1.sqlite")
        try Data("retained original".utf8).write(to: prior)
        let marker = try JSONEncoder().encode(WorkspaceStoreRecovery.Version(schemaVersion: 0, pendingSnapshot: prior.lastPathComponent))
        try marker.write(to: recovery.versionURL)
        XCTAssertThrowsError(try recovery.prepareToOpen())
        XCTAssertEqual(try Data(contentsOf: recovery.versionURL), marker)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let exported = try recovery.recoveryFiles()
        XCTAssertTrue(exported.fileWrappers?.values.contains(where: { $0.isDirectory }) == true)
    }

    func testUnreadableStoreCanBeExportedWithoutDeletingOriginal() throws {
        let url = try temporaryStore()
        let original = Data("unreadable database bytes".utf8)
        let wal = Data("preserved WAL".utf8)
        try original.write(to: url)
        try wal.write(to: URL(fileURLWithPath: url.path + "-wal"))
        let recovery = WorkspaceStoreRecovery(storeURL: url)
        XCTAssertThrowsError(try recovery.prepareToOpen())
        let exported = try recovery.recoveryFiles()
        XCTAssertEqual(exported.fileWrappers?["original.sqlite"]?.regularFileContents, original)
        XCTAssertEqual(exported.fileWrappers?["original.sqlite-wal"]?.regularFileContents, wal)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testReplacementRestoreHasReadableBeforeImage() throws {
        let url = try temporaryStore()
        let container = try ModelContainer(for: WorkspaceSchema.current, configurations: [configuration(url)])
        var profile = TrainingProfile(); profile.goal = "Original goal"
        container.mainContext.insert(WorkspaceRecord(payload: try JSONEncoder().encode(WorkspaceSnapshot(profile: profile))))
        try container.mainContext.save()
        let service = WorkspaceBackupStore(context: container.mainContext)
        var replacement = profile; replacement.goal = "Imported goal"
        let record = BackupRecord(id: "profile", category: .profile, payload: .object([
            "nativeType": .string("profile"), "version": .number(1),
            "value": try BackupJSONValue.encode(replacement)
        ]))
        let data = try NativeBackupExporter.export(records: [record], categories: [.profile])
        try service.restore(stage: service.stage(data), conflictChoices: ["profile:profile": .replaceExisting])
        let recovery = WorkspaceStoreRecovery(storeURL: url)
        let copiedURL = try XCTUnwrap(snapshots(recovery).first)
        let copied = try ModelContainer(for: WorkspaceSchema.current, configurations: [configuration(copiedURL)])
        let before = try XCTUnwrap(copied.mainContext.fetch(FetchDescriptor<WorkspaceRecord>()).first)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceSnapshot.self, from: before.payload).profile.goal, "Original goal")
        let after = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WorkspaceRecord>()).first)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceSnapshot.self, from: after.payload).profile.goal, "Imported goal")
    }

    func testRecoveryCopyFailurePreventsDestructiveRestore() throws {
        let url = try temporaryStore()
        let container = try ModelContainer(for: WorkspaceSchema.current, configurations: [configuration(url)])
        var profile = TrainingProfile(); profile.goal = "Original goal"
        container.mainContext.insert(WorkspaceRecord(payload: try JSONEncoder().encode(WorkspaceSnapshot(profile: profile))))
        try container.mainContext.save()
        let service = WorkspaceBackupStore(context: container.mainContext)
        let exported = try service.export(categories: [.profile])
        profile.goal = "Keep this newer value"
        let row = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WorkspaceRecord>()).first)
        row.payload = try JSONEncoder().encode(WorkspaceSnapshot(profile: profile))
        try container.mainContext.save()
        try Data("blocks snapshot directory creation".utf8).write(to: WorkspaceStoreRecovery(storeURL: url).snapshotsURL)
        XCTAssertThrowsError(try service.restore(stage: service.stage(exported), conflictChoices: ["profile:profile": .replaceExisting]))
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceSnapshot.self, from: row.payload).profile.goal, "Keep this newer value")
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testWorkspaceResetPurgesPrivateRecoveryCopies() throws {
        let url = try temporaryStore()
        let container = try ModelContainer(for: WorkspaceSchema.current, configurations: [configuration(url)])
        let store = try AppStore(context: container.mainContext, bridge: PlanBridge(isEnabled: false), healthEnabled: false)
        store.profile.goal = "Private history"; XCTAssertTrue(store.saveDraft())
        let recovery = WorkspaceStoreRecovery(storeURL: url)
        try recovery.capture(reason: "before-restore")
        XCTAssertTrue(store.resetWorkspace())
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.snapshotsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.profile.goal, "")
    }

    func testPostCommitResetReloadFailureCannotResaveDeletedProfile() throws {
        let schema = WorkspaceSchema.current
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        var failNextReload = false
        let store = try AppStore(context: container.mainContext, bridge: PlanBridge(isEnabled: false), healthEnabled: false,
            commit: { context in
                try context.save()
                if failNextReload {
                    failNextReload = false
                    let row = try XCTUnwrap(context.fetch(FetchDescriptor<WorkspaceRecord>()).first)
                    row.payload = Data("unreadable after durable reset".utf8)
                    try context.save()
                }
            })
        store.profile.goal = "Must remain deleted"
        XCTAssertTrue(store.saveDraft())
        let originalGeneration = store.syncGeneration
        failNextReload = true
        XCTAssertFalse(store.resetWorkspace())
        XCTAssertTrue(store.requiresWorkspaceReload)
        XCTAssertNotEqual(store.syncGeneration, originalGeneration)
        XCTAssertEqual(store.profile.goal, "")
        XCTAssertTrue(store.workouts.isEmpty)
        XCTAssertNil(store.activePlan)
        XCTAssertFalse(store.saveDraft(), "View change callbacks cannot overwrite the failed store with old displayed data.")
        let row = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WorkspaceRecord>()).first)
        XCTAssertEqual(row.payload, Data("unreadable after durable reset".utf8))
        row.payload = try JSONEncoder().encode(WorkspaceSnapshot())
        try container.mainContext.save()
        store.retryWorkspaceReload()
        XCTAssertFalse(store.requiresWorkspaceReload)
        XCTAssertEqual(store.profile.goal, "")
        XCTAssertTrue(store.saveDraft())
    }

    func testSelectedDeletionReloadFailureCannotResavePrivateData() throws {
        let schema = WorkspaceSchema.current
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let suite = "selected-deletion-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "FormFlow.requireDeviceAuthentication")
        var failNextReload = false
        var savedAfterDeletion: Data?
        let store = try AppStore(context: container.mainContext, bridge: PlanBridge(isEnabled: false), healthEnabled: false,
            privacyDefaults: defaults, commit: { context in
                try context.save()
                if failNextReload {
                    failNextReload = false
                    let row = try XCTUnwrap(context.fetch(FetchDescriptor<WorkspaceRecord>()).first)
                    savedAfterDeletion = row.payload
                    row.payload = Data("unreadable after selected deletion".utf8)
                    try context.save()
                }
            })
        store.profile.goal = "Private goal to remove"
        XCTAssertTrue(store.saveDraft())
        let originalGeneration = store.syncGeneration
        let preview = try store.previewDeletion(selection: [.profile])
        failNextReload = true
        XCTAssertFalse(store.deleteSelectedData(preview))
        XCTAssertTrue(store.requiresWorkspaceReload)
        XCTAssertEqual(store.syncGeneration, originalGeneration)
        XCTAssertEqual(store.profile.goal, "")
        XCTAssertFalse(store.saveDraft())
        XCTAssertThrowsError(try store.previewDeletion(selection: [.plans]))
        let row = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WorkspaceRecord>()).first)
        XCTAssertEqual(row.payload, Data("unreadable after selected deletion".utf8))
        row.payload = try XCTUnwrap(savedAfterDeletion)
        try container.mainContext.save()
        store.retryWorkspaceReload()
        XCTAssertFalse(store.requiresWorkspaceReload)
        XCTAssertEqual(store.profile.goal, "")
        XCTAssertTrue(store.privacyLock.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: "FormFlow.requireDeviceAuthentication"))
        XCTAssertTrue(store.saveDraft())
        XCTAssertEqual(try AppStore(context: container.mainContext, bridge: PlanBridge(isEnabled: false), healthEnabled: false,
            privacyDefaults: defaults).profile.goal, "")
    }

    private func temporaryStore() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // SwiftData may retain SQLite handles past a test's teardown. Leave these synthetic
        // fixtures in the test app's temporary directory rather than unlinking an open store.
        return directory.appendingPathComponent("workspace.store")
    }

    private func configuration(_ url: URL, schema: Schema = WorkspaceSchema.current) -> ModelConfiguration {
        ModelConfiguration("test", schema: schema, url: url, cloudKitDatabase: .none)
    }

    private func snapshots(_ recovery: WorkspaceStoreRecovery) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: recovery.snapshotsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sqlite" }.sorted { $0.path < $1.path }
    }

    private func openSQLite(_ url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { throw WorkspaceStoreRecovery.Failure("Fixture open failed") }
        return database
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw WorkspaceStoreRecovery.Failure(String(cString: sqlite3_errmsg(database))) }
    }

    private func integer(_ database: OpaquePointer, _ sql: String) throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else {
            throw WorkspaceStoreRecovery.Failure("Fixture query failed")
        }
        return Int(sqlite3_column_int(statement, 0))
    }
}
