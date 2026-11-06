import Foundation
import SwiftData
import SQLite3

/// SQLite's backup API includes committed WAL contents without copying a changing database file.
/// No model has externalStorage, so the database contains every persisted model payload.
struct WorkspaceStoreRecovery {
    static let schemaVersion = 1
    let storeURL: URL
    private let files = FileManager.default

    var versionURL: URL { storeURL.appendingPathExtension("version.json") }
    var snapshotsURL: URL { storeURL.appendingPathExtension("recovery") }

    struct Version: Codable {
        var schemaVersion: Int
        var pendingSnapshot: String?
    }

    /// Must run before ModelContainer can attempt automatic/staged migration.
    func prepareToOpen() throws {
        let version = try readVersion()
        guard version.schemaVersion <= Self.schemaVersion else {
            throw Failure("This workspace was opened by a newer app. Update Form / Flow to open it; its files have not been changed.")
        }
        guard files.fileExists(atPath: storeURL.path) else {
            let existingFiles = [versionURL, snapshotsURL, URL(fileURLWithPath: storeURL.path + "-wal"),
                                 URL(fileURLWithPath: storeURL.path + "-shm")]
            guard !existingFiles.contains(where: { files.fileExists(atPath: $0.path) }) else {
                throw Failure("The main database file is missing, but existing workspace files remain. Export them for recovery; a new empty workspace has not been created.")
            }
            return
        }
        guard version.schemaVersion < Self.schemaVersion else { return }
        if let pending = version.pendingSnapshot {
            guard pending == URL(fileURLWithPath: pending).lastPathComponent,
                  files.fileExists(atPath: snapshotsURL.appendingPathComponent(pending).path) else {
                throw Failure("The saved recovery copy is missing. Preserve an export before repairing this workspace.")
            }
            return // A failed retry must never replace the original pre-migration copy.
        }
        let snapshot = try capture(reason: "before-schema-\(Self.schemaVersion)")
        try writeVersion(Version(schemaVersion: version.schemaVersion, pendingSnapshot: snapshot.lastPathComponent))
    }

    /// Called only after both SwiftData and the app's payload validation succeed.
    func didOpenSuccessfully() throws {
        try writeVersion(Version(schemaVersion: Self.schemaVersion))
    }

    @discardableResult
    func capture(reason: String) throws -> URL {
        guard files.fileExists(atPath: storeURL.path) else {
            throw Failure("The saved database is missing. No recovery copy was created.")
        }
        try files.createDirectory(at: snapshotsURL, withIntermediateDirectories: true,
                                  attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let name = "\(reason)-\(UUID().uuidString).sqlite"
        let completed = snapshotsURL.appendingPathComponent(name)
        let temporary = snapshotsURL.appendingPathComponent(".\(name).partial")
        defer { try? files.removeItem(at: temporary) }
        try consistentCopy(from: storeURL, to: temporary)
        try files.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)
        try files.moveItem(at: temporary, to: completed)
        return completed
    }

    /// The startup error screen calls this only while the workspace is closed.
    /// Include the untouched original files even when SQLite cannot interpret them.
    func recoveryFiles() throws -> FileWrapper {
        var children: [String: FileWrapper] = [:]
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            if files.fileExists(atPath: url.path) {
                let wrapper = FileWrapper(regularFileWithContents: try Data(contentsOf: url))
                wrapper.preferredFilename = "original.sqlite" + suffix
                children["original.sqlite" + suffix] = wrapper
            }
        }
        if files.fileExists(atPath: versionURL.path) {
            children["store-version.json"] = FileWrapper(regularFileWithContents: try Data(contentsOf: versionURL))
        }
        if files.fileExists(atPath: snapshotsURL.path) {
            let wrapper = try FileWrapper(url: snapshotsURL, options: .immediate)
            wrapper.preferredFilename = "prior-copies"
            children["prior-copies"] = wrapper
        }
        guard !children.isEmpty else { throw Failure("No saved database files are available to export.") }
        children["READ-ME.txt"] = FileWrapper(regularFileWithContents: Data("""
        Form / Flow database recovery files

        This is an unencrypted recovery export containing all locally saved categories, including any private profile, prompts and health-related entries. Keep it private.

        This folder is not a portable plan or JSON backup. Keep all files together. The original database and its WAL/SHM companions may be needed together. Files in prior-copies are consistent SQLite snapshots taken before a schema change or a backup restore. Do not overwrite the live workspace with these files while the app is running. Use a compatible app version or developer-assisted recovery, then export a normal JSON backup.
        """.utf8))
        return FileWrapper(directoryWithFileWrappers: children)
    }

    func purgeSnapshots() throws {
        if files.fileExists(atPath: snapshotsURL.path) { try files.removeItem(at: snapshotsURL) }
    }

    @MainActor static func captureBeforeRestore(context: ModelContext) throws {
        for configuration in context.container.configurations where !configuration.isStoredInMemoryOnly {
            try WorkspaceStoreRecovery(storeURL: configuration.url).capture(reason: "before-restore")
        }
    }

    @MainActor static func purgeSnapshots(context: ModelContext) throws {
        for configuration in context.container.configurations where !configuration.isStoredInMemoryOnly {
            try WorkspaceStoreRecovery(storeURL: configuration.url).purgeSnapshots()
        }
    }

    private func readVersion() throws -> Version {
        guard files.fileExists(atPath: versionURL.path) else { return Version(schemaVersion: 0) }
        let value = try JSONDecoder().decode(Version.self, from: Data(contentsOf: versionURL))
        guard value.schemaVersion >= 0 else { throw Failure("The database version record could not be read. Preserve a recovery export before repairing it.") }
        return value
    }

    private func writeVersion(_ value: Version) throws {
        try files.createDirectory(at: versionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: versionURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func consistentCopy(from source: URL, to destination: URL) throws {
        var sourceDB: OpaquePointer?
        var destinationDB: OpaquePointer?
        defer { if let sourceDB { sqlite3_close(sourceDB) }; if let destinationDB { sqlite3_close(destinationDB) } }
        guard sqlite3_open_v2(source.path, &sourceDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_open_v2(destination.path, &destinationDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let backup = sqlite3_backup_init(destinationDB, "main", sourceDB, "main") else {
            throw Failure("A recovery copy could not be created. The original database has been kept; free storage or export its files before retrying.")
        }
        let result = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finished == SQLITE_OK else {
            throw Failure("The database is busy or unreadable, so a recovery copy could not be completed. The original has been kept. Retry or export its files.")
        }
    }

    struct Failure: LocalizedError {
        var errorDescription: String? { message }
        let message: String
        init(_ message: String) { self.message = message }
    }
}
