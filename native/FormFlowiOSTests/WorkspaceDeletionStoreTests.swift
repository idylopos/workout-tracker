import XCTest
import SwiftData
import FormFlowCore
@testable import FormFlowiOS

@MainActor
final class WorkspaceDeletionStoreTests: XCTestCase {
    func testProfileDeletionRemovesEveryKnownCopyAndKeepsParsedTraining() throws {
        let f = try fixture(), context = f.container.mainContext
        let originalWorkout = try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutRecord>()).first?.payload)
        let service = WorkspaceDeletionStore(context: context)
        let preview = try service.preview(selection: [.profile])
        XCTAssertFalse(preview.rotatesGeneration)
        XCTAssertTrue(preview.rows.contains { $0.id == "original-files" })
        let result = try service.delete(preview)
        XCTAssertEqual(result.syncGeneration, f.generation)
        let saved = try snapshot(context)
        XCTAssertEqual(saved.profile.goal, "")
        XCTAssertEqual(saved.profile.units, .imperial)
        XCTAssertEqual(saved.onboardingStep, 0)
        XCTAssertNil(saved.promptProfile)
        XCTAssertNil(saved.promptTemplateVersion)
        XCTAssertTrue(saved.promptDraft.isEmpty && saved.previousPrompts.isEmpty)
        XCTAssertTrue(saved.importText.isEmpty); XCTAssertNil(saved.reviewedSource)
        XCTAssertEqual(saved.activeRevisionID, f.revisionID)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkoutRecord>()).first?.payload, originalWorkout)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ActivatedPlanRecord>()).first?.planData, f.planData)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ActivatedPlanRecord>()).first?.sourceText, "")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanDraftHistoryRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BackupProvenanceRecord>()), 0)
        let exported = try WorkspaceBackupStore(context: context).export(categories: Set(BackupCategory.allCases))
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("PRIVATE_PROFILE"))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TrackingRecord>()), 3)
        XCTAssertEqual(try WorkspaceBackupStore(context: context).archivedRecords().filter { $0.category == .activities }.count, 1)
    }

    func testAIDeletionKeepsQuestionnaireAndWorkoutPayloadsWithoutRotation() throws {
        let f = try fixture(), context = f.container.mainContext
        let profile = try snapshot(context).profile
        let workout = try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutRecord>()).first?.payload)
        let service = WorkspaceDeletionStore(context: context)
        let result = try service.delete(service.preview(selection: [.aiDrafts]))
        XCTAssertFalse(result.rotatedGeneration)
        XCTAssertEqual(try snapshot(context).profile, profile)
        XCTAssertEqual(try snapshot(context).onboardingStep, 5)
        XCTAssertNil(try snapshot(context).promptProfile)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkoutRecord>()).first?.payload, workout)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ActivatedPlanRecord>()), 1)
    }

    func testPlanDeletionClearsDependenciesAndKeepsFrozenWorkoutAndCoaching() throws {
        let f = try fixture(), context = f.container.mainContext
        let progression = try addProgression(f)
        let originalWorkout = try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutRecord>()).first?.payload)
        let service = WorkspaceDeletionStore(context: context)
        let result = try service.delete(service.preview(selection: [.plans]))
        XCTAssertTrue(result.rotatedGeneration)
        XCTAssertNotEqual(result.syncGeneration, f.generation)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RuntimeIdentityRecord>()).first?.syncGeneration, result.syncGeneration)
        XCTAssertNil(try snapshot(context).activeRevisionID)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ActivatedPlanRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanDraftHistoryRecord>()), 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkoutRecord>()).first?.payload, originalWorkout)
        try progression.reload()
        XCTAssertTrue(progression.enrollments.isEmpty)
        XCTAssertEqual(progression.coaching.count, 1)
        XCTAssertNoThrow(try WorkspaceBackupStore(context: context).export())
    }

    func testWorkoutDeletionRemovesLegacyCoachingAndDependentRecoveryButKeepsPlanAndSleep() throws {
        let f = try fixture(), context = f.container.mainContext
        let progression = try addProgression(f)
        let legacy = BackupRecord(id: "legacy-day", category: .workouts,
            payload: .object(["date": .string("2026-09-18"), "coaching": .object(["technique": .string("yes")]), "nextTarget": .number(22)]))
        try archive(legacy, context: context)
        let draft = BackupRecord(id: "legacy-day", category: .drafts, payload: legacy.payload)
        try archive(draft, context: context)
        let checkIn = BackupRecord(id: "2026-09-18", category: .legacyCheckIns,
            payload: .object(["sleepUnknown": .bool(true), "recoveryUnknown": .array([.string("legacy-day")])]))
        try archive(checkIn, context: context)
        try archive(.init(id: "legacy-web-settings", category: .settings,
            payload: .object(["settings": .object(["nextSessionTargets": .object(["squat": .number(22)])])])), context: context)
        try context.save()
        let service = WorkspaceDeletionStore(context: context)
        let result = try service.delete(service.preview(selection: [.workoutHistory]))
        XCTAssertTrue(result.rotatedGeneration)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutRecord>()), 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TrackingRecord>()).map(\.category).sorted(), ["body", "sleep"])
        let archives = try WorkspaceBackupStore(context: context).archivedRecords()
        XCTAssertFalse(archives.contains { [.workouts, .drafts, .recovery, .legacyCheckIns].contains($0.category) })
        XCTAssertFalse(archives.contains { $0.id == "legacy-web-settings" }, "Legacy accepted coaching targets have no explicit references and must be removed with their source history.")
        XCTAssertEqual(try context.fetch(FetchDescriptor<ActivatedPlanRecord>()).first?.planData, f.planData)
        XCTAssertEqual(try snapshot(context).activeRevisionID, f.revisionID)
        XCTAssertEqual(try snapshot(context).profile.goal, "PRIVATE_PROFILE")
        try progression.reload()
        XCTAssertTrue(progression.coaching.isEmpty)
        XCTAssertEqual(progression.enrollments.count, 1)
    }

    func testTemplateIDCollisionCannotDeleteUnrelatedProgression() throws {
        let f = try fixture(), context = f.container.mainContext
        let progression = try addProgression(f)
        let enrollment = try XCTUnwrap(progression.enrollments.first)
        let collision = BackupRecord(id: enrollment.id, category: .activities,
            payload: .object(["nativeActivityVersion": .number(1), "exercise": try .encode(f.workout.prescription.exercises[0])]))
        try archive(collision, context: context); try context.save()
        let before = try context.fetch(FetchDescriptor<ProgressionRecord>()).map(\.payload).sorted { $0.lexicographicallyPrecedes($1) }
        let originalWorkout = try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutRecord>()).first?.payload)
        let service = WorkspaceDeletionStore(context: context)
        let result = try service.delete(service.preview(selection: [.activities]))
        XCTAssertFalse(result.rotatedGeneration)
        let after = try context.fetch(FetchDescriptor<ProgressionRecord>()).map(\.payload).sorted { $0.lexicographicallyPrecedes($1) }
        XCTAssertEqual(before, after)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkoutRecord>()).first?.payload, originalWorkout)
        XCTAssertFalse(try WorkspaceBackupStore(context: context).archivedRecords().contains { $0.category == .activities })
    }

    func testSleepAndBodyDeletionKeepsRecoveryAndExplicitlyIncludesSharedLegacyCheckIn() throws {
        let f = try fixture(), context = f.container.mainContext
        try archive(.init(id: "2026-09-18", category: .legacyCheckIns, payload: .object(["sleepUnknown": .bool(true)])), context: context)
        try context.save()
        let service = WorkspaceDeletionStore(context: context)
        let preview = try service.preview(selection: [.sleepAndBody])
        XCTAssertTrue(preview.rows.contains { $0.id == BackupCategory.legacyCheckIns.rawValue && $0.count == 1 })
        XCTAssertTrue(preview.warnings.contains { $0.contains("Shared legacy daily check-in") })
        XCTAssertFalse(try service.delete(preview).rotatedGeneration)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TrackingRecord>()).map(\.category), ["recovery"])
        XCTAssertEqual(try snapshot(context).profile.goal, "PRIVATE_PROFILE")
    }

    func testPrivateCategoryDeletionAlsoRemovesBackupPastedIntoRawDrafts() throws {
        let f = try fixture(), context = f.container.mainContext
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<WorkspaceRecord>()).first)
        var saved = try snapshot(context)
        let originalPrompt = saved.promptDraft
        saved.importText = #"{"bodyLogs":[{"weight":70}],"copiedValue":"PRIVATE_BODY_BACKUP"}"#
        saved.reviewedSource = saved.importText
        row.payload = try JSONEncoder().encode(saved)
        context.insert(PlanDraftHistoryRecord(sourceText: saved.importText))
        try context.save()
        let service = WorkspaceDeletionStore(context: context)
        let preview = try service.preview(selection: [.sleepAndBody])
        XCTAssertTrue(preview.rows.contains { $0.id == BackupCategory.rawAIResponses.rawValue })
        _ = try service.delete(preview)
        XCTAssertEqual(try snapshot(context).promptDraft, originalPrompt)
        XCTAssertEqual(try snapshot(context).profile, saved.profile)
        XCTAssertTrue(try snapshot(context).importText.isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanDraftHistoryRecord>()), 0)
        let exported = try WorkspaceBackupStore(context: context).export(categories: Set(BackupCategory.allCases))
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("PRIVATE_BODY_BACKUP"))
    }

    func testStaleProfileOrOriginalSourceRejectsDeletionBeforeCleanup() throws {
        let f = try fixture(), context = f.container.mainContext
        var cleanups = 0
        let service = WorkspaceDeletionStore(context: context, purgeRecoveryCopies: { _ in cleanups += 1 })
        let preview = try service.preview(selection: [.profile])
        let source = try XCTUnwrap(context.fetch(FetchDescriptor<BackupProvenanceRecord>()).first)
        source.originalInput = Data("new private original source".utf8); try context.save()
        XCTAssertThrowsError(try service.delete(preview))
        XCTAssertEqual(cleanups, 0)
        XCTAssertEqual(try snapshot(context).profile.goal, "PRIVATE_PROFILE")
        let next = try service.preview(selection: [.profile])
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<WorkspaceRecord>()).first)
        var saved = try snapshot(context); saved.promptProfile?.weight = "A newly copied value"
        row.payload = try JSONEncoder().encode(saved); try context.save()
        XCTAssertThrowsError(try service.delete(next))
        XCTAssertEqual(cleanups, 0)
    }

    func testSaveFailureRollsBackSelectedRecordsSourcesAndGeneration() throws {
        let f = try fixture(), context = f.container.mainContext
        let records = try WorkspaceBackupStore(context: context).records()
        let service = WorkspaceDeletionStore(context: context, commit: { _ in throw NSError(domain: "DeletionTest", code: 1) })
        let preview = try service.preview(selection: Set(WorkspaceDeletionCategory.allCases))
        XCTAssertThrowsError(try service.delete(preview))
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try WorkspaceBackupStore(context: context).records(), records)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RuntimeIdentityRecord>()).first?.syncGeneration, f.generation)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BackupProvenanceRecord>()), 1)
    }

    func testRecoveryCleanupFailurePreventsAnyDeletion() throws {
        let f = try fixture(), context = f.container.mainContext
        var committed = false
        let service = WorkspaceDeletionStore(context: context, commit: { _ in committed = true },
            purgeRecoveryCopies: { _ in throw NSError(domain: "DeletionTest", code: 2) })
        let preview = try service.preview(selection: [.profile])
        XCTAssertThrowsError(try service.delete(preview))
        XCTAssertFalse(committed)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try snapshot(context).profile.goal, "PRIVATE_PROFILE")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BackupProvenanceRecord>()), 1)
    }

    func testSuccessfulPrivateDeletionRemovesActualRecoverySnapshots() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("workspace.store"), schema = WorkspaceSchema.current
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration("deletion-test", schema: schema, url: url, cloudKitDatabase: .none)])
        let context = container.mainContext
        var snapshot = WorkspaceSnapshot(); snapshot.profile.goal = "PRIVATE_PROFILE"
        context.insert(WorkspaceRecord(payload: try JSONEncoder().encode(snapshot)))
        context.insert(RuntimeIdentityRecord()); try context.save()
        let recovery = WorkspaceStoreRecovery(storeURL: url)
        try recovery.capture(reason: "before-deletion")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.snapshotsURL.path))
        let service = WorkspaceDeletionStore(context: context)
        _ = try service.delete(service.preview(selection: [.profile]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.snapshotsURL.path))
        XCTAssertEqual(try self.snapshot(context).profile.goal, "")
        // The synthetic live SQLite store may still be open; the test app owns its temporary directory.
    }

    func testActiveRecordingBlocksPrivateDeletionUntilExplicitUnavailableOwnerReview() throws {
        let f = try fixture(finished: false, owner: "watch"), context = f.container.mainContext
        let service = WorkspaceDeletionStore(context: context)
        XCTAssertThrowsError(try service.preview(selection: [.profile]))
        let identity = try XCTUnwrap(context.fetch(FetchDescriptor<RuntimeIdentityRecord>()).first)
        try WorkoutAnnotationStore(context: context).markOwnerUnavailable(workout: f.workout, reviewer: identity.deviceID)
        XCTAssertNoThrow(try service.delete(service.preview(selection: [.profile])))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutRecord>()), 1)
    }

    func testKeptRetiredUnavailableWorkoutCannotBlockLaterDeletion() throws {
        let f = try fixture(finished: false, owner: "watch"), context = f.container.mainContext
        let identity = try XCTUnwrap(context.fetch(FetchDescriptor<RuntimeIdentityRecord>()).first)
        let original = try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutRecord>()).first?.payload)
        try WorkoutAnnotationStore(context: context).markOwnerUnavailable(workout: f.workout, reviewer: identity.deviceID)
        let service = WorkspaceDeletionStore(context: context)
        XCTAssertTrue(try service.delete(service.preview(selection: [.plans])).rotatedGeneration)
        XCTAssertNoThrow(try service.delete(service.preview(selection: [.profile])))
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkoutRecord>()).first?.payload, original)
    }

    private struct Fixture {
        let container: ModelContainer
        let workout: WorkoutSession
        let revisionID: String
        let planData: Data
        let generation: String
    }
    private func fixture(finished: Bool = true, owner: String = "phone") throws -> Fixture {
        let schema = WorkspaceSchema.current
        let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = container.mainContext
        let plan = try XCTUnwrap(PlanImporter.importText(PlanContract.exampleJSON).plan)
        let planData = try JSONEncoder().encode(plan), date = Date(timeIntervalSince1970: 1_800_000_000)
        let revision = ActivatedPlanRecord(sequence: 1, activationDate: date, planData: planData, sourceText: "PRIVATE_PROFILE in raw response")
        context.insert(revision)
        let identity = RuntimeIdentityRecord(); identity.deviceID = "phone"; context.insert(identity)
        var snapshot = WorkspaceSnapshot(); snapshot.profile.goal = "PRIVATE_PROFILE"; snapshot.profile.units = .imperial
        snapshot.onboardingStep = 5; snapshot.activeRevisionID = revision.id
        snapshot.promptDraft = "PRIVATE_PROFILE in prompt"; snapshot.promptProfile = snapshot.profile; snapshot.promptTemplateVersion = 1
        snapshot.previousPrompts = [.init(createdAt: date, text: "PRIVATE_PROFILE in history")]
        snapshot.importText = "PRIVATE_PROFILE in current response"; snapshot.reviewedSource = snapshot.importText
        context.insert(WorkspaceRecord(payload: try JSONEncoder().encode(snapshot)))
        context.insert(PlanDraftHistoryRecord(sourceText: "PRIVATE_PROFILE in old response"))
        context.insert(BackupProvenanceRecord(sourceFingerprint: "original", originalInput: Data("PRIVATE_PROFILE in original input".utf8), isLegacy: true))
        var workout = try WorkoutSession.start(prescription: plan.days[0].sessions[0], planID: plan.id,
            planRevisionID: revision.id, ownerDeviceID: owner, at: date, timeZoneIdentifier: "UTC", syncGeneration: identity.syncGeneration)
        if finished {
            workout = WorkoutReducer.apply(WorkoutOperation(session: workout, command: .finish(allowPartial: true), at: date.addingTimeInterval(60)),
                to: workout, at: date.addingTimeInterval(60)).session
        }
        context.insert(WorkoutRecord(id: workout.id, payload: try JSONEncoder().encode(workout)))
        let day = LocalTrainingDay(instant: date, timeZone: .gmt)
        let sleep = try ManualSleepRecord(day: day, hours: 7), body = try BodyMeasurementRecord(day: day, weight: .init(value: 70, unit: .kg))
        context.insert(TrackingRecord(id: sleep.id, category: "sleep", payload: try JSONEncoder().encode(sleep)))
        context.insert(TrackingRecord(id: body.id, category: "body", payload: try JSONEncoder().encode(body)))
        if finished {
            let recovery = try SessionRecoveryRecord(sessionID: workout.id, phase: .evening, day: day, readiness: .unknown)
            context.insert(TrackingRecord(id: recovery.id, category: "recovery", payload: try JSONEncoder().encode(recovery)))
        }
        try archive(.init(id: "saved-activity", category: .activities,
            payload: .object(["nativeActivityVersion": .number(1), "exercise": try .encode(plan.days[0].sessions[0].exercises[0])])), context: context)
        try context.save()
        return .init(container: container, workout: workout, revisionID: revision.id, planData: planData, generation: identity.syncGeneration)
    }
    private func addProgression(_ fixture: Fixture) throws -> ProgressionStore {
        let store = try ProgressionStore(context: fixture.container.mainContext)
        let session = fixture.workout.prescription
        XCTAssertTrue(store.saveEnrollment(planID: fixture.workout.planID, planRevisionID: fixture.revisionID, session: session,
            exercise: session.exercises[0], configuration: .init(policy: BuiltInProgressionPolicy.strength.reference, optedIn: true)))
        XCTAssertTrue(store.saveAnswers(workout: fixture.workout, exercise: fixture.workout.exercises[0], answers: .init()))
        return store
    }
    private func snapshot(_ context: ModelContext) throws -> WorkspaceSnapshot {
        try JSONDecoder().decode(WorkspaceSnapshot.self, from: XCTUnwrap(context.fetch(FetchDescriptor<WorkspaceRecord>()).first).payload)
    }
    private func archive(_ record: BackupRecord, context: ModelContext) throws {
        context.insert(BackupArchiveRecord(key: record.key, recordData: try JSONEncoder().encode(record), sourceFingerprint: "original", needsReview: false))
    }
}
