import XCTest
import SwiftData
import FormFlowCore
@testable import FormFlowiOS

@MainActor
final class WorkoutBackupCompatibilityStoreTests: XCTestCase {
    func testUnversionedOperationsRestoreReexportAndRepeatAsDuplicatesWithoutLosingAudit() throws {
        let fixture = try legacyBackup(), destination = try container()
        let service = WorkspaceBackupStore(context: destination.mainContext)
        let stage = try service.stage(fixture.data)
        XCTAssertEqual(stage.originalInput, fixture.data)
        try service.restore(stage: stage)

        let rows = try destination.mainContext.fetch(FetchDescriptor<WorkoutRecord>())
        XCTAssertEqual(rows.count, 1)
        let restored = try JSONDecoder().decode(WorkoutSession.self, from: XCTUnwrap(rows.first).payload)
        XCTAssertEqual(restored, fixture.finished)
        XCTAssertEqual(restored.conflicts.count, 1)
        XCTAssertEqual(restored.conflicts.first?.acceptedSets.first?.actual.reps, 8)
        let archived = try XCTUnwrap(service.archivedRecords().first)
        XCTAssertEqual(try XCTUnwrap(archived.payload["value"]).decode(WorkoutSession.self), fixture.pending)
        XCTAssertEqual(archived.payload["value"]?["pendingOperations"]?.array?.first?["schemaVersion"], nil)
        XCTAssertEqual(try destination.mainContext.fetch(FetchDescriptor<BackupProvenanceRecord>()).first?.originalInput, fixture.data)

        let exported = try service.export(categories: [.workouts])
        let exportStage = try BackupImporter.stage(exported)
        let exportedFinished = try XCTUnwrap(exportStage.records.first { $0.id == fixture.finished.id.uuidString })
        XCTAssertEqual(exportedFinished.payload["value"]?["operationReceipts"]?.array?.first?["operation"]?["schemaVersion"], .number(1))
        let repeated = try service.stage(fixture.data)
        XCTAssertEqual(Set(repeated.preview.duplicates), Set(stage.records.map(\.key)))
        XCTAssertTrue(repeated.preview.conflicts.isEmpty)
        try service.restore(stage: repeated)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<WorkoutRecord>()), 1)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<BackupArchiveRecord>()), 1)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<BackupProvenanceRecord>()), 1)

        let secondDestination = try container(), second = WorkspaceBackupStore(context: secondDestination.mainContext)
        try second.restore(stage: second.stage(exported))
        let secondRow = try XCTUnwrap(secondDestination.mainContext.fetch(FetchDescriptor<WorkoutRecord>()).first)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutSession.self, from: secondRow.payload), fixture.finished)
        let secondArchive = try XCTUnwrap(second.archivedRecords().first?.payload["value"])
        XCTAssertEqual(try secondArchive.decode(WorkoutSession.self), fixture.pending)
    }

    func testExplicitNullFutureVersionAndUnknownOperationFieldsRemainRejectedAtEveryAuditPath() throws {
        let fixture = try legacyBackup(), destination = try container()
        let service = WorkspaceBackupStore(context: destination.mainContext)
        for path in ["pendingOperations", "operationReceipts", "conflicts"] {
            for extra in [["schemaVersion": BackupJSONValue.null], ["schemaVersion": .number(2)], ["futurePolicy": .string("unsupported")]] {
                let bad = try changingFirstOperation(fixture.data, path: path, extra: extra)
                XCTAssertThrowsError(try service.stage(bad), "\(path): \(extra)")
                XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<WorkoutRecord>()), 0)
                XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<BackupArchiveRecord>()), 0)
                XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<BackupProvenanceRecord>()), 0)
            }
        }
    }

    func testLegacyFingerprintNormalizationStillDetectsNewerActualCorrections() throws {
        let fixture = try legacyBackup(), destination = try container()
        let service = WorkspaceBackupStore(context: destination.mainContext)
        try service.restore(stage: service.stage(fixture.data))
        let row = try XCTUnwrap(destination.mainContext.fetch(FetchDescriptor<WorkoutRecord>()).first)
        let previous = try JSONDecoder().decode(WorkoutSession.self, from: row.payload)
        let correction = WorkoutOperation(session: previous,
            command: .updateSet(setID: previous.exercises[0].sets[0].id, values: .init(reps: 9, load: .init(value: 20, unit: .kg))),
            at: previous.endedAt!.addingTimeInterval(60))
        let updated = WorkoutReducer.apply(correction, to: previous, at: correction.createdAt)
        XCTAssertEqual(updated.status, .applied)
        row.payload = try JSONEncoder().encode(updated.session); try destination.mainContext.save()
        let stage = try service.stage(fixture.data)
        XCTAssertEqual(stage.preview.conflicts, ["workouts:\(previous.id.uuidString)"])
        XCTAssertThrowsError(try service.restore(stage: stage))
        XCTAssertEqual(try JSONDecoder().decode(WorkoutSession.self, from: row.payload), updated.session)
    }

    private func legacyBackup() throws -> (data: Data, finished: WorkoutSession, pending: WorkoutSession) {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let exercise = PlanExercise(instanceId: "squat", exerciseId: "squat", name: "Squat", measurement: .weightReps,
            target: .init(sets: 1, restSeconds: 60, reps: .init(min: 8, max: 10), load: .init(value: 20, unit: .kg)))
        let prescription = PlanSession(id: "session", name: "Strength", kind: "strength", estimatedMinutes: 30, exercises: [exercise])
        func session() throws -> WorkoutSession {
            try WorkoutSession.start(prescription: prescription, planID: "plan", planRevisionID: "missing-revision",
                ownerDeviceID: "watch", at: start, timeZoneIdentifier: "UTC", syncGeneration: "generation")
        }
        let original = try session(), setID = original.exercises[0].sets[0].id
        let log = WorkoutOperation(session: original, command: .logSet(setID: setID, values: .init(reps: 8, load: .init(value: 20, unit: .kg))), at: start.addingTimeInterval(1))
        var finished = WorkoutReducer.apply(log, to: original, at: log.createdAt).session
        let conflict = WorkoutOperation(session: original, command: .updateSet(setID: setID, values: .init(reps: 12, load: .init(value: 25, unit: .kg))), originDeviceID: "phone", at: start.addingTimeInterval(2))
        finished = WorkoutReducer.apply(conflict, to: finished, at: conflict.createdAt).session
        let finish = WorkoutOperation(session: finished, command: .finish(allowPartial: false), at: start.addingTimeInterval(3))
        finished = WorkoutReducer.apply(finish, to: finished, at: finish.createdAt).session
        var pending = try session()
        let future = WorkoutOperation(sessionID: pending.id, originDeviceID: "phone", syncGeneration: pending.syncGeneration,
            expectedRevision: 4, command: .updateSet(setID: pending.exercises[0].sets[0].id, values: .init(reps: 10, load: .init(value: 22, unit: .kg))), createdAt: start)
        pending = WorkoutReducer.apply(future, to: pending, at: start).session
        for value in [finished, pending] { XCTAssertTrue(WorkoutArchiveValidator.validate(value).isEmpty) }
        let records = try [finished, pending].map { workout in
            BackupRecord(id: workout.id.uuidString, category: .workouts, payload: .object([
                "nativeType": .string("workout"), "version": .number(1), "value": removingVersions(try .encode(workout))
            ]), references: [.init(category: .plans, id: workout.planRevisionID, allowsMissing: true)])
        }
        return (try NativeBackupExporter.export(records: records, categories: [.workouts]), finished, pending)
    }
    private func removingVersions(_ value: BackupJSONValue) -> BackupJSONValue {
        switch value {
        case .object(var fields): fields.removeValue(forKey: "schemaVersion"); return .object(fields.mapValues(removingVersions))
        case .array(let values): return .array(values.map(removingVersions))
        default: return value
        }
    }
    private func changingFirstOperation(_ data: Data, path: String, extra: [String: BackupJSONValue]) throws -> Data {
        var root = try XCTUnwrap(JSONDecoder().decode(BackupJSONValue.self, from: data).object)
        var records = try XCTUnwrap(root["records"]?.array)
        for index in records.indices {
            var record = try XCTUnwrap(records[index].object), payload = try XCTUnwrap(record["payload"]?.object)
            var workout = try XCTUnwrap(payload["value"]?.object)
            guard var entries = workout[path]?.array, !entries.isEmpty else { continue }
            var entry = try XCTUnwrap(entries[0].object)
            if path == "pendingOperations" { entry.merge(extra) { _, new in new } }
            else {
                var operation = try XCTUnwrap(entry["operation"]?.object)
                operation.merge(extra) { _, new in new }; entry["operation"] = .object(operation)
            }
            entries[0] = .object(entry); workout[path] = .array(entries); payload["value"] = .object(workout)
            record["payload"] = .object(payload); records[index] = .object(record); root["records"] = .array(records)
            return try BackupJSONValue.object(root).canonicalData()
        }
        throw NSError(domain: "Missing audit fixture", code: 1)
    }
    private func container() throws -> ModelContainer {
        let schema = WorkspaceSchema.current
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }
}
