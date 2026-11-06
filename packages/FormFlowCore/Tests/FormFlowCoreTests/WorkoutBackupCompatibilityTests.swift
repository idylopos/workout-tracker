import XCTest
@testable import FormFlowCore

final class WorkoutBackupCompatibilityTests: XCTestCase {
    func testOnlyKnownMissingOperationVersionsNormalize() {
        let operation: BackupJSONValue = .object(["id": .string("operation"), "futureField": .bool(true)])
        let original: BackupJSONValue = .object([
            "pendingOperations": .array([operation]),
            "operationReceipts": .array([.object(["operation": operation, "futureReceiptField": .number(9)])]),
            "conflicts": .array([.object(["operation": operation])]),
            "unrelated": .object(["operation": operation])
        ])
        let normalized = WorkoutBackupCompatibility.normalizedWorkoutValue(original)
        XCTAssertNil(original["pendingOperations"]?.array?.first?["schemaVersion"])
        XCTAssertEqual(normalized["pendingOperations"]?.array?.first?["schemaVersion"], .number(1))
        XCTAssertEqual(normalized["operationReceipts"]?.array?.first?["operation"]?["schemaVersion"], .number(1))
        XCTAssertEqual(normalized["conflicts"]?.array?.first?["operation"]?["schemaVersion"], .number(1))
        XCTAssertEqual(normalized["operationReceipts"]?.array?.first?["futureReceiptField"], .number(9))
        XCTAssertEqual(normalized["pendingOperations"]?.array?.first?["futureField"], .bool(true))
        XCTAssertEqual(normalized["unrelated"], original["unrelated"])
    }

    func testExplicitNullAndFutureVersionsAreNotReinterpreted() {
        for version in [BackupJSONValue.null, .number(2), .string("1")] {
            let value: BackupJSONValue = .object(["pendingOperations": .array([.object(["schemaVersion": version])])])
            XCTAssertEqual(WorkoutBackupCompatibility.normalizedWorkoutValue(value), value)
        }
    }

    func testSemanticFingerprintsMatchOnlyKnownVersionOneDefault() {
        func record(version: BackupJSONValue?, category: BackupCategory = .workouts, nativeType: String = "workout") -> BackupRecord {
            var operation: [String: BackupJSONValue] = ["id": .string("operation")]
            operation["schemaVersion"] = version
            return BackupRecord(id: "session", category: category, payload: .object([
                "nativeType": .string(nativeType), "version": .number(1),
                "value": .object(["pendingOperations": .array([.object(operation)])])]))
        }
        XCTAssertEqual(record(version: nil).fingerprint, record(version: .number(1)).fingerprint)
        XCTAssertNotEqual(record(version: nil).fingerprint, record(version: .null).fingerprint)
        XCTAssertNotEqual(record(version: nil).fingerprint, record(version: .number(2)).fingerprint)
        XCTAssertNotEqual(record(version: nil, nativeType: "unknown").fingerprint, record(version: .number(1), nativeType: "unknown").fingerprint)
        XCTAssertNotEqual(record(version: nil, category: .drafts).fingerprint, record(version: .number(1), category: .drafts).fingerprint)
    }
}
