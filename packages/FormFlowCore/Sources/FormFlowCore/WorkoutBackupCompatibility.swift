import Foundation

/// Development backups preceded explicit operation versions. Only that known absent
/// field is normalized; unknown fields and explicitly supplied versions remain intact.
public enum WorkoutBackupCompatibility {
    public static func normalizedWorkoutValue(_ value: BackupJSONValue) -> BackupJSONValue {
        guard var workout = value.object else { return value }
        func operation(_ value: BackupJSONValue) -> BackupJSONValue {
            guard var fields = value.object else { return value }
            if fields["schemaVersion"] == nil { fields["schemaVersion"] = .number(1) }
            return .object(fields)
        }
        if let pending = workout["pendingOperations"]?.array {
            workout["pendingOperations"] = .array(pending.map(operation))
        }
        for key in ["operationReceipts", "conflicts"] {
            if let entries = workout[key]?.array {
                workout[key] = .array(entries.map { entry in
                    guard var fields = entry.object, let original = fields["operation"] else { return entry }
                    fields["operation"] = operation(original)
                    return .object(fields)
                })
            }
        }
        return .object(workout)
    }

    /// Used only for semantic duplicate detection; never rewrites source/provenance bytes.
    public static func normalizedRecord(_ record: BackupRecord) -> BackupRecord {
        guard record.category == .workouts, var payload = record.payload.object,
              payload["nativeType"] == .string("workout"), payload["version"] == .number(1),
              let value = payload["value"] else { return record }
        payload["value"] = normalizedWorkoutValue(value)
        return BackupRecord(id: record.id, category: record.category, payload: .object(payload), references: record.references)
    }
}
