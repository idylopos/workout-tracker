import XCTest
import SwiftData
import FormFlowCore
@testable import FormFlowiOS

@MainActor
final class ProgressionStoreTests: XCTestCase {
    private struct Fixture {
        let plan: WeeklyPlan
        let revision: String
        let session: PlanSession
        let exercise: PlanExercise
        let workouts: [WorkoutSession]
        let recovery: [SessionRecoveryRecord]
        let configuration = ProgressionConfiguration(policy: BuiltInProgressionPolicy.strength.reference, optedIn: true)
    }
    private func container() throws -> ModelContainer {
        let schema = WorkspaceSchema.current
        return try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }
    private func fixture(revision: String = UUID().uuidString) throws -> Fixture {
        let plan = try XCTUnwrap(PlanImporter.importText(PlanContract.exampleJSON).plan)
        let session = plan.days[0].sessions[0], exercise = session.exercises[0]
        var workouts: [WorkoutSession] = [], recovery: [SessionRecoveryRecord] = []
        for daysAgo in [8, 4] {
            let start = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
            var workout = try WorkoutSession.start(prescription: session, planID: plan.id, planRevisionID: revision,
                                                   ownerDeviceID: "test", at: start, timeZoneIdentifier: "UTC")
            for set in workout.exercises[0].sets {
                let log = WorkoutOperation(session: workout, command: .logSet(setID: set.id,
                    values: .init(reps: exercise.target.reps!.max, load: .init(value: 20, unit: .kg), rir: 2)), at: start.addingTimeInterval(60))
                workout = WorkoutReducer.apply(log, to: workout, at: log.createdAt).session
            }
            let finish = WorkoutOperation(session: workout, command: .finish(allowPartial: true), at: start.addingTimeInterval(600))
            workout = WorkoutReducer.apply(finish, to: workout, at: finish.createdAt).session
            workouts.append(workout)
            recovery.append(try .init(sessionID: workout.id, phase: .nextMorning,
                                      day: LocalTrainingDay(instant: start.addingTimeInterval(86_400), timeZone: .gmt),
                                      readiness: .yes, updatedAt: start.addingTimeInterval(86_400)))
        }
        return Fixture(plan: plan, revision: revision, session: session, exercise: exercise, workouts: workouts, recovery: recovery)
    }
    private func enrollAndAnswer(_ store: ProgressionStore, fixture f: Fixture) {
        XCTAssertTrue(store.saveEnrollment(planID: f.plan.id, planRevisionID: f.revision, session: f.session,
                                            exercise: f.exercise, configuration: f.configuration))
        for workout in f.workouts {
            XCTAssertTrue(store.saveAnswers(workout: workout, exercise: workout.exercises[0], answers: .init(technique: .yes)))
        }
    }
    private func target(_ store: ProgressionStore, fixture f: Fixture) throws -> FutureProgressionTarget {
        let history = store.exposures(workouts: f.workouts, recovery: f.recovery, currentPlanRevisionID: f.revision,
                                      currentSessionID: f.session.id, currentExercise: f.exercise)
        let source = try XCTUnwrap(history.first { $0.session.id == f.workouts.last!.id })
        let advice = ProgressionEngine.advice(for: source, history: history, currentPlanRevisionID: f.revision, asOf: Date())
        XCTAssertEqual(advice.action, .increase)
        return try ProgressionEngine.accept(advice, currentPlanID: f.plan.id, currentPlanRevisionID: f.revision,
                                            currentExercise: f.exercise, configuration: f.configuration, history: history,
                                            enteredLoad: .init(value: 22.5, unit: .kg), availableEquipmentLoads: [.init(value: 22.5, unit: .kg)], at: Date())
    }

    func testExplicitEnrollmentAndUnknownAnswersSurviveRelaunch() throws {
        let c = try container(), f = try fixture()
        let store = try ProgressionStore(context: ModelContext(c))
        XCTAssertNil(store.configuration(planRevisionID: f.revision, sessionID: f.session.id, exerciseInstanceID: f.exercise.instanceId))
        XCTAssertTrue(store.saveEnrollment(planID: f.plan.id, planRevisionID: f.revision, session: f.session,
                                            exercise: f.exercise, configuration: f.configuration))
        XCTAssertTrue(store.saveAnswers(workout: f.workouts[0], exercise: f.workouts[0].exercises[0], answers: .init()))
        let reopened = try ProgressionStore(context: ModelContext(c))
        XCTAssertEqual(reopened.enrollments, store.enrollments)
        XCTAssertEqual(reopened.coaching, store.coaching)
        XCTAssertNil(reopened.answers(workoutID: f.workouts[0].id, exerciseID: f.workouts[0].exercises[0].id).reserve)
        XCTAssertEqual(reopened.answers(workoutID: f.workouts[0].id, exerciseID: f.workouts[0].exercises[0].id).technique, .unknown)
    }

    func testFailedSaveKeepsDurableEnrollmentAndObservableState() throws {
        let c = try container(), f = try fixture()
        let original = try ProgressionStore(context: ModelContext(c))
        enrollAndAnswer(original, fixture: f)
        let failing = try ProgressionStore(context: ModelContext(c)) { _ in throw NSError(domain: "Test", code: 1) }
        XCTAssertFalse(failing.saveEnrollment(planID: f.plan.id, planRevisionID: f.revision, session: f.session,
                                               exercise: f.exercise, configuration: .init()))
        XCTAssertEqual(failing.enrollments, original.enrollments)
        XCTAssertEqual(try ProgressionStore(context: ModelContext(c)).enrollments, original.enrollments)
    }

    func testValidatedAcceptanceStagesWithoutSavingAndRollsBack() throws {
        let c = try container(), context = ModelContext(c), f = try fixture()
        let store = try ProgressionStore(context: context)
        enrollAndAnswer(store, fixture: f)
        let target = try target(store, fixture: f)
        try store.validateAndStageAcceptance(target, currentPlan: f.plan, revision: f.revision, workouts: f.workouts, recovery: f.recovery, in: context)
        XCTAssertTrue(store.acceptedTargets.isEmpty)
        context.rollback()
        XCTAssertTrue(try ProgressionStore(context: ModelContext(c)).acceptedTargets.isEmpty)
        try store.validateAndStageAcceptance(target, currentPlan: f.plan, revision: f.revision, workouts: f.workouts, recovery: f.recovery, in: context)
        try context.save(); try store.reload()
        XCTAssertEqual(store.acceptedTargets, [target])
        XCTAssertThrowsError(try store.validateAndStageAcceptance(target, currentPlan: f.plan, revision: f.revision,
                                                                 workouts: f.workouts, recovery: f.recovery, in: context))
    }

    func testTransactionRevalidationRejectsStaleRecoveryAndPlan() throws {
        let c = try container(), context = ModelContext(c), f = try fixture()
        let store = try ProgressionStore(context: context)
        enrollAndAnswer(store, fixture: f)
        let accepted = try target(store, fixture: f)
        XCTAssertThrowsError(try store.validateAndStageAcceptance(accepted, currentPlan: f.plan, revision: UUID().uuidString,
                                                                 workouts: f.workouts, recovery: f.recovery, in: context))
        var revised = f.recovery
        try revised[1].edit(day: revised[1].day, rating: 3, readiness: .no, notes: "Changed answer")
        XCTAssertThrowsError(try store.validateAndStageAcceptance(accepted, currentPlan: f.plan, revision: f.revision,
                                                                 workouts: f.workouts, recovery: revised, in: context))
        XCTAssertTrue(store.acceptedTargets.isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProgressionRecord>()), 3)
    }

    func testEnrollmentCarryForwardKeepsHistoricalRevisionAndComparableHistory() throws {
        let c = try container(), context = ModelContext(c), f = try fixture(), nextRevision = UUID().uuidString
        let store = try ProgressionStore(context: context)
        enrollAndAnswer(store, fixture: f)
        var renamed = f.plan; renamed.name = "Unrelated display name change"
        try store.stageEnrollmentCarryForward(from: f.revision, to: nextRevision, plan: renamed, in: context)
        try context.save(); try store.reload()
        XCTAssertEqual(store.enrollments.count, 2)
        XCTAssertEqual(store.configuration(planRevisionID: nextRevision, sessionID: f.session.id, exerciseInstanceID: f.exercise.instanceId), f.configuration)
        let history = store.exposures(workouts: f.workouts, recovery: f.recovery, currentPlanRevisionID: nextRevision,
                                      currentSessionID: f.session.id, currentExercise: f.exercise)
        let current = try XCTUnwrap(history.first { $0.session.id == f.workouts[1].id })
        XCTAssertEqual(ProgressionEngine.advice(for: current, history: history, currentPlanRevisionID: nextRevision, asOf: Date()).action, .increase)
    }

    func testBackupRecordsRoundTripBySelectedCategoriesAndRejectUnknownFields() throws {
        let c = try container(), context = ModelContext(c), f = try fixture()
        let store = try ProgressionStore(context: context)
        enrollAndAnswer(store, fixture: f)
        let values = try ProgressionStore.backupRecords(context: context)
        XCTAssertEqual(values.filter { $0.category == .settings }.count, 1)
        XCTAssertEqual(values.filter { $0.category == .recovery }.count, 2)
        let destination = try container(), destinationContext = ModelContext(destination)
        for record in values {
            XCTAssertTrue(try ProgressionStore.validateBackupRecord(record))
            try ProgressionStore.applyBackupRecord(record, context: destinationContext)
        }
        try destinationContext.save()
        let restored = try ProgressionStore(context: destinationContext)
        XCTAssertEqual(restored.enrollments, store.enrollments)
        XCTAssertEqual(Set(restored.coaching.map(\.id)), Set(store.coaching.map(\.id)))
        var badPayload = try XCTUnwrap(values[0].payload.object); badPayload["futureUnsupportedField"] = .bool(true)
        let tampered = BackupRecord(id: values[0].id, category: values[0].category, payload: .object(badPayload), references: values[0].references)
        XCTAssertThrowsError(try ProgressionStore.validateBackupRecord(tampered))
        XCTAssertThrowsError(try ProgressionStore.validateBackupRelationships(values))
    }

    func testAppAcceptanceReducesUnassistedStepSixUsingAssistanceAndKeepsHistory() throws {
        let (c, app, target) = try pullUpApplication()
        let original = app.workouts[0], previousRevision = app.activePlanRevisionID
        XCTAssertTrue(app.applyFutureProgressionTarget(target), app.errorMessage ?? "")
        let next = try XCTUnwrap(app.activePlan?.days.first?.sessions.first?.exercises.first)
        XCTAssertEqual(next.measurement, .assistedReps)
        XCTAssertEqual(next.target.assistance, .init(value: 10, unit: .kg))
        XCTAssertEqual(app.workouts[0], original)
        XCTAssertEqual(original.exercises[0].prescription.measurement, .reps)
        XCTAssertNotEqual(app.activePlanRevisionID, previousRevision)
        XCTAssertEqual(app.progression.acceptedTargets, [target])
        XCTAssertEqual(try ModelContext(c).fetchCount(FetchDescriptor<ActivatedPlanRecord>()), 2)
        XCTAssertFalse(app.applyFutureProgressionTarget(target))
    }

    func testAppAcceptanceFailureRollsBackPlanAndAcceptedTargetTogether() throws {
        var fail = false
        let (c, app, target) = try pullUpApplication(failCommit: { fail })
        let oldPlan = app.activePlan, oldRevision = app.activePlanRevisionID
        fail = true
        XCTAssertFalse(app.applyFutureProgressionTarget(target))
        XCTAssertEqual(app.activePlan, oldPlan); XCTAssertEqual(app.activePlanRevisionID, oldRevision)
        XCTAssertTrue(app.progression.acceptedTargets.isEmpty)
        let reopened = try AppStore(context: ModelContext(c), bridge: PlanBridge(isEnabled: false), healthEnabled: false)
        XCTAssertEqual(reopened.activePlan, oldPlan)
        XCTAssertTrue(reopened.progression.acceptedTargets.isEmpty)
        XCTAssertEqual(try ModelContext(c).fetchCount(FetchDescriptor<ActivatedPlanRecord>()), 1)
    }

    private func pullUpApplication(failCommit: @escaping () -> Bool = { false }) throws -> (ModelContainer, AppStore, FutureProgressionTarget) {
        let c = try container()
        let commit: (ModelContext) throws -> Void = { context in
            if failCommit() { throw NSError(domain: "Test", code: 1) }
            try context.save()
        }
        let first = try AppStore(context: ModelContext(c), bridge: PlanBridge(isEnabled: false), healthEnabled: false, commit: commit)
        let exercise = PlanExercise(instanceId: "pull-up", exerciseId: "pull-up", name: "Pull-up", measurement: .reps,
                                    target: .init(sets: 3, restSeconds: 150, reps: .init(min: 3, max: 5), effort: .init(kind: .rir, min: 1, max: 1)))
        let session = PlanSession(id: "pull", name: "Pull", kind: "strength", estimatedMinutes: 30, exercises: [exercise])
        let plan = WeeklyPlan(id: "pull-program", name: "Pull program", days: [.init(weekday: .monday, sessions: [session])])
        first.importText = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
        first.inspectImport(); first.activatePlan(plan, startDate: Date())
        let revision = try XCTUnwrap(first.activePlanRevisionID)
        let start = Date().addingTimeInterval(-4 * 86_400)
        var workout = try WorkoutSession.start(prescription: session, planID: plan.id, planRevisionID: revision,
                                               ownerDeviceID: first.deviceID, at: start, timeZoneIdentifier: "UTC", syncGeneration: first.syncGeneration)
        for set in workout.exercises[0].sets {
            let operation = WorkoutOperation(session: workout, command: .logSet(setID: set.id, values: .init(reps: 3, rir: 1)), at: start.addingTimeInterval(60))
            workout = WorkoutReducer.apply(operation, to: workout, at: operation.createdAt).session
        }
        let finish = WorkoutOperation(session: workout, command: .finish(allowPartial: true), at: start.addingTimeInterval(600))
        workout = WorkoutReducer.apply(finish, to: workout, at: finish.createdAt).session
        let recovery = try SessionRecoveryRecord(sessionID: workout.id, phase: .nextMorning,
                                                 day: LocalTrainingDay(instant: start.addingTimeInterval(86_400), timeZone: .gmt),
                                                 readiness: .yes, updatedAt: start.addingTimeInterval(86_400))
        let context = ModelContext(c)
        context.insert(WorkoutRecord(id: workout.id, payload: try JSONEncoder().encode(workout)))
        context.insert(TrackingRecord(id: recovery.id, category: "recovery", payload: try JSONEncoder().encode(recovery)))
        try context.save()
        let app = try AppStore(context: ModelContext(c), bridge: PlanBridge(isEnabled: false), healthEnabled: false, commit: commit)
        let config = ProgressionConfiguration(policy: BuiltInProgressionPolicy.pullUp.reference, optedIn: true, pullUpStep: 6)
        XCTAssertTrue(app.progression.saveEnrollment(planID: plan.id, planRevisionID: revision, session: session, exercise: exercise, configuration: config))
        XCTAssertTrue(app.progression.saveAnswers(workout: workout, exercise: workout.exercises[0], answers: .init(technique: .difficult)))
        let history = app.progression.exposures(workouts: app.workouts, recovery: app.recoveryRecords,
                                                currentPlanRevisionID: revision, currentSessionID: session.id, currentExercise: exercise)
        let source = try XCTUnwrap(history.first)
        let advice = ProgressionEngine.advice(for: source, history: history, currentPlanRevisionID: revision, asOf: Date())
        XCTAssertEqual(advice.action, .reduce)
        let target = try ProgressionEngine.accept(advice, currentPlanID: plan.id, currentPlanRevisionID: revision,
                                                  currentExercise: exercise, configuration: config, history: history,
                                                  enteredLoad: .init(value: 10, unit: .kg), availableEquipmentLoads: [.init(value: 10, unit: .kg)], at: Date())
        return (c, app, target)
    }
}
