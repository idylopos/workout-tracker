import XCTest
import SwiftData
import FormFlowCore
@testable import FormFlowiOS

@MainActor
final class LegacyProgressionStoreTests: XCTestCase {
    func testLegacyEvidenceSupportsFutureTargetWithoutCreatingHistoricalSessions() throws {
        let fixture = try fixture()
        let legacy = try fixture.store.progression.legacyEvidence(planID: "form-flow", exerciseID: "neutral-db-bench")
        XCTAssertEqual(legacy.count, 1)
        let target = try recommendation(fixture)
        XCTAssertEqual(target.legacyEvidenceReferences?.first?.fingerprint, legacy.first?.sourceFingerprint)
        XCTAssertTrue(fixture.store.applyFutureProgressionTarget(target), fixture.store.errorMessage ?? "")
        XCTAssertEqual(fixture.store.workouts.count, 1)
        XCTAssertEqual(fixture.store.workouts.first, fixture.workout)
        XCTAssertEqual(try fixture.store.progression.legacyEvidence(planID: "form-flow", exerciseID: "neutral-db-bench"), legacy)
        let saved = try XCTUnwrap(fixture.store.progression.acceptedTargets.first)
        XCTAssertEqual(saved.legacyEvidenceReferences, target.legacyEvidenceReferences)
        XCTAssertEqual(fixture.store.activePlan?.days.first?.sessions.first?.exercises.first?.target.load?.value, 22.5)
    }

    func testChangedLegacyEvidenceRejectsPreviouslyReviewedTargetBeforeMutation() throws {
        let fixture = try fixture()
        let target = try recommendation(fixture)
        let revision = fixture.store.activePlanRevisionID
        let context = ModelContext(fixture.container)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<BackupArchiveRecord>()).first { $0.key == fixture.legacy.key })
        var payload = fixture.legacy.payload.object!
        var log = payload["log"]!.object!, exercises = log["exercises"]!.object!, exercise = exercises["neutral-db-bench"]!.object!
        exercise["coaching"] = .object(["technique": .string("no")])
        exercises["neutral-db-bench"] = .object(exercise); log["exercises"] = .object(exercises); payload["log"] = .object(log)
        row.recordData = try JSONEncoder().encode(BackupRecord(id: fixture.legacy.id, category: .workouts,
            payload: .object(payload), references: fixture.legacy.references))
        try context.save()
        // Relaunch proves acceptance reads persisted evidence, including changes made after the advice was shown.
        let reopened = try AppStore(context: ModelContext(fixture.container), bridge: PlanBridge(isEnabled: false), healthEnabled: false)
        XCTAssertFalse(reopened.applyFutureProgressionTarget(target))
        XCTAssertEqual(reopened.activePlanRevisionID, revision)
        XCTAssertTrue(reopened.progression.acceptedTargets.isEmpty)
        XCTAssertEqual(reopened.workouts.first, fixture.workout)
    }

    func testAcceptedSettingsBackupIncludesReferencedLegacyGrouping() throws {
        let fixture = try fixture()
        let target = try recommendation(fixture)
        XCTAssertTrue(fixture.store.applyFutureProgressionTarget(target))
        let data = try WorkspaceBackupStore(context: ModelContext(fixture.container)).export(categories: [.settings])
        let stage = try BackupImporter.stage(data)
        XCTAssertTrue(stage.records.contains { $0.key == fixture.legacy.key })
        XCTAssertTrue(stage.records.contains { $0.id == fixture.workout.id.uuidString })
        try ProgressionStore.validateBackupRelationships(stage.records)
    }

    private struct Fixture {
        let container: ModelContainer
        let store: AppStore
        let workout: WorkoutSession
        let legacy: BackupRecord
    }

    private func fixture() throws -> Fixture {
        let schema = WorkspaceSchema.current
        let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let identity = RuntimeIdentityRecord()
        let exercise = try XCTUnwrap(BuiltInPlans.plan().days.flatMap(\.sessions).flatMap(\.exercises).first { $0.exerciseId == "neutral-db-bench" })
        let prescription = PlanSession(id: "bench-session", name: "Bench", kind: "strength", estimatedMinutes: 20, exercises: [exercise])
        let plan = WeeklyPlan(id: "form-flow", name: "Built-in evidence test", days: [.init(weekday: .monday, sessions: [prescription])])
        let started = Date().addingTimeInterval(-3 * 86_400)
        let revision = ActivatedPlanRecord(sequence: 1, activationDate: started, planData: try JSONEncoder().encode(plan), sourceText: "")
        var workspace = WorkspaceSnapshot(); workspace.activeRevisionID = revision.id
        context.insert(identity); context.insert(revision); context.insert(WorkspaceRecord(payload: try JSONEncoder().encode(workspace)))
        var workout = try WorkoutSession.start(prescription: prescription, planID: plan.id, planRevisionID: revision.id,
            ownerDeviceID: identity.deviceID, at: started, timeZoneIdentifier: TimeZone.gmt.identifier, syncGeneration: identity.syncGeneration)
        for set in workout.exercises[0].sets {
            let operation = WorkoutOperation(session: workout, command: .logSet(setID: set.id,
                values: .init(reps: 10, load: .init(value: 20, unit: .kg), rir: 2)), at: started.addingTimeInterval(60))
            workout = WorkoutReducer.apply(operation, to: workout, at: operation.createdAt).session
        }
        let finish = WorkoutOperation(session: workout, command: .finish(allowPartial: false), at: started.addingTimeInterval(600))
        workout = WorkoutReducer.apply(finish, to: workout, at: finish.createdAt).session
        context.insert(WorkoutRecord(id: workout.id, payload: try JSONEncoder().encode(workout)))
        let morning = try SessionRecoveryRecord(sessionID: workout.id, phase: .nextMorning,
            day: .init(instant: started.addingTimeInterval(86_400), timeZone: .gmt), readiness: .yes,
            updatedAt: started.addingTimeInterval(86_400))
        context.insert(TrackingRecord(id: morning.id, category: "recovery", payload: try JSONEncoder().encode(morning)))
        try context.save()
        let day = LocalTrainingDay(instant: started.addingTimeInterval(-5 * 86_400), timeZone: .gmt).date
        let raw: BackupJSONValue = .object(["version": .number(1), "settings": .object(["builtInPlanRevision": .number(2)]),
            "bodyLogs": .array([]), "sleepLogs": .array([]), "workoutLogs": .object(["form-flow|\(day)": .object([
                "date": .string(day), "planId": .string("form-flow"), "response": .object(["scaleVersion": .number(2), "readiness": .string("yes")]),
                "exercises": .object(["neutral-db-bench": .object([
                    "measurement": .string("weight_reps"), "coaching": .object(["technique": .string("yes")]),
                    "coachingPlan": .object(["kind": .string("strength"), "sets": .number(3), "minReps": .number(6), "maxReps": .number(10), "minRir": .number(2)]),
                    "sets": .array((0..<3).map { _ in .object(["weight": .number(20), "reps": .number(10), "rir": .number(2), "completed": .bool(true)]) })
                ])])
            ])])])
        let backups = WorkspaceBackupStore(context: context)
        let stage = try backups.stage(raw.canonicalData())
        try backups.restore(stage: stage)
        let store = try AppStore(context: ModelContext(container), bridge: PlanBridge(isEnabled: false), healthEnabled: false)
        XCTAssertTrue(store.progression.saveEnrollment(planID: plan.id, planRevisionID: revision.id, session: prescription,
            exercise: exercise, configuration: .init(policy: BuiltInProgressionPolicy.strength.reference, optedIn: true)))
        XCTAssertTrue(store.progression.saveAnswers(workout: workout, exercise: workout.exercises[0], answers: .init(technique: .yes)))
        return Fixture(container: container, store: store, workout: workout, legacy: try XCTUnwrap(stage.records.first { $0.category == .workouts }))
    }

    private func recommendation(_ fixture: Fixture) throws -> FutureProgressionTarget {
        let plan = try XCTUnwrap(fixture.store.activePlan), revision = try XCTUnwrap(fixture.store.activePlanRevisionID)
        let exercise = try XCTUnwrap(plan.days.first?.sessions.first?.exercises.first)
        let history = fixture.store.progression.exposures(workouts: fixture.store.includedWorkouts, recovery: fixture.store.recoveryRecords,
            currentPlanRevisionID: revision, currentSessionID: "bench-session", currentExercise: exercise)
        let source = try XCTUnwrap(history.first)
        let legacy = try fixture.store.progression.legacyEvidence(planID: plan.id, exerciseID: exercise.exerciseId)
        let advice = ProgressionEngine.advice(for: source, history: history, currentPlanRevisionID: revision, asOf: Date(), legacyHistory: legacy)
        XCTAssertEqual(advice.action, .increase)
        return try ProgressionEngine.accept(advice, currentPlanID: plan.id, currentPlanRevisionID: revision,
            currentExercise: exercise, configuration: source.configuration, history: history,
            enteredLoad: .init(value: 22.5, unit: .kg), availableEquipmentLoads: [.init(value: 22.5, unit: .kg)], legacyHistory: legacy, at: Date())
    }
}
