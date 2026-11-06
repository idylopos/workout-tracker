import Foundation

/// A review of the web's reusable activity definition. Web templates did not contain target values.
/// Even an incomplete archive remains visible; only a reviewed, valid native copy can be used.
public struct LegacySavedActivityReview: Identifiable, Equatable, Sendable {
    public let id: String
    public let recordID: String
    public let sourceFingerprint: String
    public let name: String
    public let activityType: String?
    public let originalMeasurement: String?
    public let measurement: MeasurementKind?
    public let sourceUnits: [PlanUnit]
    public let issues: [String]
    public let original: BackupJSONValue
    public let canPrepareDraft: Bool

    public init?(record: BackupRecord) {
        guard record.category == .activities, record.payload["nativeActivityVersion"] == nil,
              record.payload["nativeType"] == nil else { return nil }
        id = record.key; recordID = record.id; sourceFingerprint = record.fingerprint; original = record.payload
        let storedName = record.payload["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        name = storedName.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) } ?? "Imported activity needing review"
        activityType = record.payload["type"]?.string
        originalMeasurement = record.payload["measurement"]?.string
        let supported: Set<MeasurementKind> = [.duration, .durationCalories, .distanceTime, .distance]
        measurement = originalMeasurement.flatMap(MeasurementKind.init(rawValue:)).flatMap { supported.contains($0) ? $0 : nil }
        switch measurement {
        case .duration: sourceUnits = [.min, .s]
        case .durationCalories: sourceUnits = [.min, .s, .kcal]
        case .distanceTime: sourceUnits = [.km, .min, .s]
        case .distance: sourceUnits = [.km]
        default: sourceUnits = []
        }
        var findings: [String] = []
        let sourceID = record.payload["id"]?.string
        if sourceID != record.id || sourceID?.range(of: "^[a-z0-9][a-z0-9-]{0,95}$", options: .regularExpression) == nil {
            findings.append("The saved activity identity is incomplete or inconsistent. Create a corrected native activity manually.")
        }
        if storedName == nil || storedName?.isEmpty == true || (storedName?.count ?? 0) > 80 {
            findings.append("The saved name is missing or too long. Enter a corrected activity name.")
        }
        if !["walking", "cycling", "elliptical", "swimming", "running", "hiit", "custom"].contains(activityType ?? "") {
            findings.append("The saved activity type is unsupported. Choose how to record a new activity manually.")
        }
        if measurement == nil { findings.append("The saved measurement is unsupported or missing. Choose a supported measurement manually.") }
        if record.payload["sets"] != nil { findings.append("This record contains workout sets. They are preserved and will never be copied into a reusable prescription or completed workout.") }
        canPrepareDraft = findings.isEmpty
        let recognized: Set<String> = ["id", "name", "type", "measurement", "reusableId"]
        if let fields = record.payload.object, !Set(fields.keys).subtracting(recognized).isEmpty {
            findings.append("Additional original fields are retained for inspection; they are not interpreted as targets or actual results.")
        }
        issues = findings
    }

    /// One blank recording row and no between-set rest are new draft choices, not recovered source targets.
    /// A timed or distance draft intentionally fails strict plan validation until the user enters a target.
    public func reviewDraft() -> PlanExercise? {
        guard canPrepareDraft, let measurement else { return nil }
        let stableID = "web-activity-" + String(BackupDigest.hash(Data(id.utf8)).prefix(32))
        return .init(instanceId: stableID, exerciseId: stableID, name: name, measurement: measurement,
                     target: .init(sets: 1, restSeconds: 0))
    }

    /// Copy only after review; retain both the original archive and a fingerprint of the reviewed source.
    public func nativeCopy(exercise: PlanExercise, currentSource: BackupRecord) throws -> BackupRecord {
        guard currentSource.key == id, currentSource.fingerprint == sourceFingerprint,
              LegacySavedActivityReview(record: currentSource) != nil else {
            throw BackupError.invalid("The imported activity changed. Review its latest saved version before making a native copy.")
        }
        let errors = PlanValidator.validateExercise(exercise).filter { $0.severity == .error }
        guard errors.isEmpty else { throw BackupError.invalid("Review the native activity targets: \(errors.map(\.message).joined(separator: " "))") }
        let copy = BackupRecord(id: "native-activity:\(exercise.exerciseId)", category: .activities,
            payload: .object([
                "nativeActivityVersion": .number(1), "exercise": try .encode(exercise),
                "legacyActivitySource": .object(["recordID": .string(recordID), "fingerprint": .string(sourceFingerprint)])
            ]), references: [.init(category: .activities, id: recordID)])
        guard copy.key != currentSource.key else { throw BackupError.invalid("A native copy must retain a separate original activity record.") }
        return copy
    }
}
