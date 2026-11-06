import XCTest
import SwiftData
import FormFlowCore
@testable import FormFlowiOS

@MainActor
final class ScheduleExceptionStoreTests: XCTestCase {
    private struct Fixture {
        let container: ModelContainer
        let plan: WeeklyPlan
        let revision: ActivatedPlanRecord
        let occurrence: ScheduleOccurrence
    }
    private func date(_ iso: String) -> Date { ScheduleExceptionSchedule.date(iso)! }
    private var now: Date { date("2026-09-18") }
    private var activation: Date { date("2026-09-14") }
    private func day(_ iso: String) throws -> LocalTrainingDay { try .init(date: iso, timeZoneID: TimeZone.current.identifier) }
    private func container() throws -> ModelContainer {
        let schema = WorkspaceSchema.current
        return try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }
    private func fixture() throws -> Fixture {
        let container = try container(), plan = try XCTUnwrap(PlanImporter.importText(PlanContract.exampleJSON).plan)
        let row = ActivatedPlanRecord(sequence: 1, activationDate: activation, planData: try JSONEncoder().encode(plan), sourceText: "")
        container.mainContext.insert(row); try container.mainContext.save()
        let session = plan.days.first { $0.weekday == .monday }!.sessions[0]
        let id = ScheduleExceptionSchedule.occurrenceID(planID: plan.id, originalDay: "2026-09-21", sessionID: session.id)
        let occurrence = try XCTUnwrap(ScheduleExceptionSchedule.resolve(occurrenceID: id, plan: plan, activationDate: activation, asOf: now))
        return .init(container: container, plan: plan, revision: row, occurrence: occurrence)
    }
    private func moved(_ f: Fixture) throws -> ScheduleExceptionStore {
        let store = try ScheduleExceptionStore(context: f.container.mainContext)
        XCTAssertTrue(store.save(f.occurrence, action: .rescheduled, destination: try day("2026-09-23"), note: "Travel day",
            plan: f.plan, planRevisionID: f.revision.id, activationDate: activation, workouts: [], at: now), store.errorMessage ?? "")
        return store
    }
    private func resolve(_ f: Fixture, store: ScheduleExceptionStore) throws -> ScheduleOccurrence {
        try XCTUnwrap(ScheduleExceptionSchedule.resolve(occurrenceID: f.occurrence.id, plan: f.plan, activationDate: activation,
            exceptions: store.exceptions, asOf: now))
    }

    func testRescheduleSurvivesRelaunchAndSkipUpdatesSameIdentity() throws {
        let f = try fixture(), store = try moved(f)
        let reopened = try ScheduleExceptionStore(context: ModelContext(f.container))
        XCTAssertEqual(reopened.exceptions, store.exceptions)
        XCTAssertEqual(try resolve(f, store: reopened).effectiveDay.date, "2026-09-23")
        XCTAssertTrue(reopened.save(try resolve(f, store: reopened), action: .skipped, plan: f.plan, planRevisionID: f.revision.id,
            activationDate: activation, workouts: [], at: now))
        XCTAssertEqual(reopened.exceptions.count, 1)
        XCTAssertEqual(try ModelContext(f.container).fetchCount(FetchDescriptor<ScheduleExceptionRecord>()), 1)
        XCTAssertEqual(try ModelContext(f.container).fetchCount(FetchDescriptor<WorkoutRecord>()), 0)
        XCTAssertFalse(try reopened.canStart(occurrenceID: f.occurrence.id, plan: f.plan, activationDate: activation, workouts: [], at: now))
    }

    func testFailedSavePreservesPreviousDurableAndObservableSchedule() throws {
        let f = try fixture(), original = try moved(f)
        let failing = try ScheduleExceptionStore(context: ModelContext(f.container)) { _ in throw NSError(domain: "ScheduleTest", code: 1) }
        XCTAssertFalse(failing.save(try resolve(f, store: failing), action: .skipped, plan: f.plan, planRevisionID: f.revision.id,
            activationDate: activation, workouts: [], at: now))
        XCTAssertNotNil(failing.errorMessage)
        XCTAssertEqual(failing.exceptions, original.exceptions)
        XCTAssertEqual(try ScheduleExceptionStore(context: ModelContext(f.container)).exceptions, original.exceptions)
    }

    func testPendingWatchStartAndInvalidOccurrenceCannotBeSaved() throws {
        let f = try fixture(), store = try ScheduleExceptionStore(context: f.container.mainContext)
        XCTAssertFalse(store.save(f.occurrence, action: .skipped, plan: f.plan, planRevisionID: f.revision.id,
            activationDate: activation, workouts: [], pendingWatchOccurrenceIDs: [f.occurrence.id], at: now))
        XCTAssertTrue(store.exceptions.isEmpty)
        XCTAssertFalse(try store.canStart(occurrenceID: "made-up-session", plan: f.plan, activationDate: activation, workouts: [], at: now))
        XCTAssertEqual(try f.container.mainContext.fetchCount(FetchDescriptor<ScheduleExceptionRecord>()), 0)
    }

    func testSelectedSettingsBackupIncludesPlanAndRestoresScheduleExactly() throws {
        let f = try fixture(), original = try moved(f), destination = try container()
        let data = try WorkspaceBackupStore(context: f.container.mainContext).export(categories: [.settings])
        let staged = try BackupImporter.stage(data)
        XCTAssertEqual(Set(staged.records.map(\.category)), [.plans, .settings])
        let service = WorkspaceBackupStore(context: destination.mainContext)
        try service.restore(stage: service.stage(data))
        let restored = try ScheduleExceptionStore(context: destination.mainContext)
        XCTAssertEqual(restored.exceptions, original.exceptions)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<ActivatedPlanRecord>()), 1)
        try service.restore(stage: service.stage(data))
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<ScheduleExceptionRecord>()), 1)
        XCTAssertEqual(try restored.upcoming(plan: f.plan, activationDate: activation, from: now, limit: 4, workouts: []).filter { $0.id == f.occurrence.id }.first?.date, date("2026-09-23"))
    }

    func testBackupFailureRollsBackScheduleAndRequiredPlan() throws {
        let f = try fixture(); _ = try moved(f)
        let data = try WorkspaceBackupStore(context: f.container.mainContext).export(categories: [.settings])
        let destination = try container()
        let service = WorkspaceBackupStore(context: destination.mainContext) { _ in throw NSError(domain: "BackupTest", code: 2) }
        XCTAssertThrowsError(try service.restore(stage: service.stage(data)))
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<ScheduleExceptionRecord>()), 0)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<ActivatedPlanRecord>()), 0)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<BackupProvenanceRecord>()), 0)
    }

    func testBackupRejectsUnknownFieldsMissingPlanAndCollidingMove() throws {
        let f = try fixture(), store = try moved(f)
        let record = try XCTUnwrap(ScheduleExceptionStore.backupRecords(context: f.container.mainContext).first)
        var payload = try XCTUnwrap(record.payload.object); payload["unsupported"] = .bool(true)
        let unknown = BackupRecord(id: record.id, category: record.category, payload: .object(payload), references: record.references)
        XCTAssertThrowsError(try ScheduleExceptionStore.validateBackupRecord(unknown))
        XCTAssertThrowsError(try ScheduleExceptionStore.validateBackupRelationships([record]))
        let change = try XCTUnwrap(store.exceptions.first)
        let collision = try ScheduleException(occurrenceID: change.id, planID: change.planID, planRevisionID: change.planRevisionID,
            sessionID: change.sessionID, originalDay: change.originalDay, destinationDay: day("2026-09-28"), action: .rescheduled, updatedAt: now)
        let invalid = BackupRecord(id: record.id, category: .settings,
            payload: .object(["nativeType": .string("schedule-exception"), "version": .number(1), "value": try .encode(collision)]), references: record.references)
        let plans = try WorkspaceBackupStore(context: f.container.mainContext).records().filter { $0.category == .plans }
        XCTAssertThrowsError(try ScheduleExceptionStore.validateBackupRelationships(plans + [invalid]))
    }
}
