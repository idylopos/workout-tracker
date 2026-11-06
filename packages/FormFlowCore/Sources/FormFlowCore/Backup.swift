import Foundation
import CryptoKit

/// A JSON tree keeps fields the native UI does not yet interpret.
public enum BackupJSONValue: Codable, Equatable, Sendable {
    case object([String: BackupJSONValue]), array([BackupJSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([String: Self].self) { self = .object(value) }
        else { self = .array(try c.decode([Self].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .bool(let value): try c.encode(value)
        case .null: try c.encodeNil()
        }
    }
    public var object: [String: Self]? { if case .object(let value) = self { value } else { nil } }
    public var array: [Self]? { if case .array(let value) = self { value } else { nil } }
    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var number: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Double(value)
        default: nil
        }
    }
    public subscript(_ key: String) -> Self? { object?[key] }
    public static func encode<T: Encodable>(_ value: T) throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: canonicalData()) }
    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum BackupCategory: String, Codable, CaseIterable, Sendable {
    case plans, workouts, drafts, sleep, body, recovery, activities, settings, legacyCheckIns
    case profile, promptHistory, rawAIResponses
    public var isPrivateOptional: Bool { [.profile, .promptHistory, .rawAIResponses].contains(self) }
    public static var defaultSelection: Set<Self> { Set(allCases.filter { !$0.isPrivateOptional }) }
}

public struct BackupReference: Codable, Equatable, Sendable {
    public let category: BackupCategory
    public let id: String
    /// Legacy history may legitimately outlive its plan definition; keep that fact visible.
    public let allowsMissing: Bool
    public var key: String { "\(category.rawValue):\(id)" }
    public init(category: BackupCategory, id: String, allowsMissing: Bool = false) {
        self.category = category; self.id = id; self.allowsMissing = allowsMissing
    }
}

public struct BackupRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let category: BackupCategory
    public let payload: BackupJSONValue
    public let references: [BackupReference]
    public var key: String { "\(category.rawValue):\(id)" }
    public init(id: String, category: BackupCategory, payload: BackupJSONValue, references: [BackupReference] = []) {
        self.id = id; self.category = category; self.payload = payload; self.references = references
    }
    public var fingerprint: String {
        // Valid records contain finite JSON numbers, so encoding is deterministic.
        let normalized = WorkoutBackupCompatibility.normalizedRecord(self)
        let data = (try? BackupJSONValue.encode(normalized).canonicalData()) ?? Data()
        return BackupDigest.hash(data)
    }
}

public struct NativeBackupArchive: Codable, Equatable, Sendable {
    public let format: String
    public let version: Int
    public let createdAt: Date
    public let records: [BackupRecord]
    public init(records: [BackupRecord], createdAt: Date = Date()) {
        format = "formflow-native-backup"; version = 1; self.createdAt = createdAt; self.records = records
    }
}

public enum BackupError: Error, LocalizedError, Equatable {
    case tooLarge, tooManyRecords, tooDeep, unsupportedFormat, invalid(String), missingReference(String), unresolvedConflict(String)
    public var errorDescription: String? {
        switch self {
        case .tooLarge: "This backup exceeds 32 MiB. Export a smaller selection or retain the original for a future larger-file importer."
        case .tooManyRecords: "This backup exceeds 50,000 records. Export fewer categories; no records were imported."
        case .tooDeep: "This backup contains overly nested data. The original file was not changed."
        case .unsupportedFormat: "This file is not a supported Form / Flow backup."
        case .invalid(let message): message
        case .missingReference(let key): "The backup is missing required data: \(key)."
        case .unresolvedConflict(let key): "Choose how to resolve the existing record: \(key)."
        }
    }
}

public struct BackupPreview: Equatable, Sendable {
    public let counts: [BackupCategory: Int]
    public let duplicates: [String]
    public let conflicts: [String]
    public let unresolvedReferences: [String]
    public let warnings: [String]
    public let pendingDraftCount: Int
}

public struct StagedBackup: Sendable {
    public let sourceFingerprint: String
    public let originalInput: Data
    public let isLegacy: Bool
    public let records: [BackupRecord]
    public let preview: BackupPreview
}

public enum BackupDigest {
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

public enum NativeBackupExporter {
    /// The caller supplies explicit category selections; private categories are excluded by default.
    /// Required prescription references are included automatically without broadening private selection.
    public static func export(records: [BackupRecord], categories: Set<BackupCategory> = .init(BackupCategory.defaultSelection),
                              createdAt: Date = Date()) throws -> Data {
        try BackupImporter.validate(records)
        let indexed = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
        var included = Dictionary(uniqueKeysWithValues: records.filter { categories.contains($0.category) }.map { ($0.key, $0) })
        var queue = Array(included.values)
        while let record = queue.popLast() {
            for reference in record.references where included[reference.key] == nil {
                guard let required = indexed[reference.key] else {
                    if reference.allowsMissing { continue }
                    throw BackupError.missingReference(reference.key)
                }
                guard !required.category.isPrivateOptional || categories.contains(required.category) else {
                    throw BackupError.invalid("A selected record depends on excluded private data. Review your export selection.")
                }
                included[required.key] = required; queue.append(required)
            }
        }
        let archive = NativeBackupArchive(records: included.values.sorted { $0.key < $1.key }, createdAt: createdAt)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(archive)
        guard data.count <= BackupImporter.maximumBytes else { throw BackupError.tooLarge }
        return data
    }
}

public enum BackupImporter {
    public static let maximumBytes = 32 * 1_024 * 1_024
    public static let maximumRecords = 50_000
    public static func stage(_ data: Data, existing: [BackupRecord] = [],
                             legacyTimeZoneID: String = TimeZone.current.identifier) throws -> StagedBackup {
        guard data.count <= maximumBytes else { throw BackupError.tooLarge }
        let value: BackupJSONValue
        do { value = try JSONDecoder().decode(BackupJSONValue.self, from: data) }
        catch { throw BackupError.invalid("The backup is not valid JSON. No existing data was changed.") }
        try checkDepth(value)
        guard let root = value.object else { throw BackupError.unsupportedFormat }
        let legacy: Bool
        let records: [BackupRecord]
        var warnings: [String] = []
        var pendingDrafts = 0
        if root["format"]?.string == "formflow-native-backup" {
            guard Set(root.keys).isSubset(of: ["format", "version", "createdAt", "records"]) else {
                throw BackupError.invalid("This backup contains unsupported archive fields. Preserve the original file for a compatible importer.")
            }
            for record in root["records"]?.array ?? [] {
                guard let object = record.object, Set(object.keys).isSubset(of: ["id", "category", "payload", "references"]) else {
                    throw BackupError.invalid("This backup contains unsupported record fields. No records were restored.")
                }
            }
            let archive = try value.decode(NativeBackupArchive.self)
            guard archive.version == 1 else { throw BackupError.unsupportedFormat }
            legacy = false; records = archive.records
        } else if root["version"]?.number == 1, root["workoutLogs"]?.object != nil {
            let migrated = try LegacyBackupMigration.records(root, timeZoneID: legacyTimeZoneID)
            legacy = true; records = migrated.records; warnings = migrated.warnings; pendingDrafts = migrated.pendingDrafts
        } else { throw BackupError.unsupportedFormat }
        try validate(records); try validate(existing)
        let existingByKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.key, $0) })
        let available = Set(records.map(\.key)).union(existingByKey.keys)
        let missing = Array(Set(records.flatMap(\.references).filter { !available.contains($0.key) }.map(\.key))).sorted()
        for reference in records.flatMap(\.references) where !available.contains(reference.key) && !reference.allowsMissing {
            throw BackupError.missingReference(reference.key)
        }
        let duplicates = records.filter { existingByKey[$0.key]?.fingerprint == $0.fingerprint }.map(\.key).sorted()
        let conflicts = records.filter { existingByKey[$0.key] != nil && existingByKey[$0.key]?.fingerprint != $0.fingerprint }.map(\.key).sorted()
        let counts = Dictionary(grouping: records, by: \.category).mapValues(\.count)
        return StagedBackup(sourceFingerprint: BackupDigest.hash(try value.canonicalData()), originalInput: data,
                            isLegacy: legacy, records: records,
                            preview: BackupPreview(counts: counts, duplicates: duplicates, conflicts: conflicts,
                                                   unresolvedReferences: missing, warnings: warnings, pendingDraftCount: pendingDrafts))
    }
    static func validate(_ records: [BackupRecord]) throws {
        guard records.count <= maximumRecords else { throw BackupError.tooManyRecords }
        var ids: Set<String> = []
        for record in records {
            guard !record.id.isEmpty, record.id.utf8.count <= 1_024, ids.insert(record.key).inserted else {
                throw BackupError.invalid("A backup record has a missing or duplicate identity.")
            }
            try checkDepth(record.payload)
            _ = try record.payload.canonicalData()
        }
    }
    private static func checkDepth(_ value: BackupJSONValue, depth: Int = 0) throws {
        guard depth <= 40 else { throw BackupError.tooDeep }
        switch value {
        case .object(let values): for child in values.values { try checkDepth(child, depth: depth + 1) }
        case .array(let values): for child in values { try checkDepth(child, depth: depth + 1) }
        default: break
        }
    }
}

public enum BackupConflictChoice: Sendable { case keepExisting, replaceExisting }
public struct BackupRestoreChanges: Sendable {
    public let insertions: [BackupRecord]
    public let replacements: [BackupRecord]
    public let skippedKeys: [String]
    /// Persist this provenance with the transaction, including uninterpreted legacy source fields.
    public let sourceFingerprint: String
    public let originalInput: Data
}

public enum BackupRestorePlanner {
    /// No mutation occurs here. Apply the complete returned batch in one storage transaction.
    /// Recomputing against the current store prevents a stale preview silently replacing new work.
    public static func changes(stage: StagedBackup, existing: [BackupRecord],
                               conflictChoices: [String: BackupConflictChoice] = [:]) throws -> BackupRestoreChanges {
        try BackupImporter.validate(existing)
        let indexed = Dictionary(uniqueKeysWithValues: existing.map { ($0.key, $0) })
        var inserts: [BackupRecord] = [], replacements: [BackupRecord] = [], skipped: [String] = []
        for incoming in stage.records {
            guard let current = indexed[incoming.key] else { inserts.append(incoming); continue }
            if current.fingerprint == incoming.fingerprint { skipped.append(incoming.key); continue }
            guard let choice = conflictChoices[incoming.key] else { throw BackupError.unresolvedConflict(incoming.key) }
            switch choice {
            case .keepExisting: skipped.append(incoming.key)
            case .replaceExisting: replacements.append(incoming)
            }
        }
        let available = Set(existing.map(\.key)).union(inserts.map(\.key))
        for record in inserts + replacements {
            for reference in record.references where !available.contains(reference.key) && !reference.allowsMissing {
                throw BackupError.missingReference(reference.key)
            }
        }
        return BackupRestoreChanges(insertions: inserts, replacements: replacements, skippedKeys: skipped,
                                    sourceFingerprint: stage.sourceFingerprint, originalInput: stage.originalInput)
    }
}
