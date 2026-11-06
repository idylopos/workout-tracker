import Foundation
import XCTest
@testable import FormFlowCore

final class WorkoutDomainTests: XCTestCase {
    private let beginning = Date(timeIntervalSince1970: 1_780_000_000)

    private func prescription(measurement: MeasurementKind = .weightReps, sets: Int = 3,
                              optional: Bool = false, rest: Int = 90) -> PlanSession {
        var target = ExerciseTarget(sets: sets, restSeconds: rest)
        switch measurement {
        case .weightReps: target.reps = RepRange(min: 8, max: 10); target.load = PlanQuantity(value: 20, unit: .kg)
        case .reps, .assistedReps: target.reps = RepRange(min: 8, max: 10)
        case .duration, .durationCalories: target.duration = QuantityRange(min: 10, max: 10, unit: .min)
        case .distance, .distanceTime, .weightDistance: target.distance = QuantityRange(min: 20, max: 20, unit: .m)
        case .completion: break
        }
        return PlanSession(id: "strength-a", name: "Strength A", kind: "strength", estimatedMinutes: 45,
            exercises: [PlanExercise(instanceId: "squat-1", exerciseId: "squat", name: "Squat",
                measurement: measurement, target: target, optional: optional)])
    }

    private func session(measurement: MeasurementKind = .weightReps, sets: Int = 3,
                         optional: Bool = false, rest: Int = 90) throws -> WorkoutSession {
        try WorkoutSession.start(prescription: prescription(measurement: measurement, sets: sets, optional: optional, rest: rest),
            planID: "my-plan", planRevisionID: "revision-1", ownerDeviceID: "watch-1", at: beginning,
            timeZoneIdentifier: "Asia/Singapore", syncGeneration: "workspace-1")
    }

    @discardableResult
    private func apply(_ command: WorkoutCommand, to session: inout WorkoutSession,
                       seconds: Double = 10) -> WorkoutReduction {
        let date = beginning.addingTimeInterval(seconds)
        let operation = WorkoutOperation(session: session, command: command, at: date)
        let reduction = WorkoutReducer.apply(operation, to: session, at: date)
        session = reduction.session
        return reduction
    }

    private func values(for measurement: MeasurementKind = .weightReps) -> WorkoutSetValues {
        switch measurement {
        case .completion: WorkoutSetValues()
        case .weightReps: WorkoutSetValues(reps: 8, load: PlanQuantity(value: 20, unit: .kg), rir: 2)
        case .reps: WorkoutSetValues(reps: 8, rir: 2)
        case .assistedReps: WorkoutSetValues(reps: 8, assistance: PlanQuantity(value: 15, unit: .kg), rir: 1)
        case .weightDistance: WorkoutSetValues(load: PlanQuantity(value: 20, unit: .kg), distance: PlanQuantity(value: 25, unit: .m), rir: 2)
        case .duration: WorkoutSetValues(durationSeconds: 600, rpe: 3)
        case .durationCalories: WorkoutSetValues(durationSeconds: 600, calories: 50, rpe: 3)
        case .distanceTime: WorkoutSetValues(durationSeconds: 1_800, distance: PlanQuantity(value: 4.5, unit: .km), rpe: 3)
        case .distance: WorkoutSetValues(distance: PlanQuantity(value: 2, unit: .mi), rpe: 3)
        }
    }

    func testStartFreezesPrescriptionWithoutCountingTargetsAsActuals() throws {
        var plan = prescription()
        let workout = try WorkoutSession.start(prescription: plan, planID: "plan", planRevisionID: "v1",
            ownerDeviceID: "phone", at: beginning, timeZoneIdentifier: "Asia/Singapore")
        plan.exercises[0].target.load = PlanQuantity(value: 50, unit: .kg)
        XCTAssertEqual(workout.prescription.exercises[0].target.load?.value, 20)
        XCTAssertEqual(workout.exercises[0].sets[0].target.load?.value, 20)
        XCTAssertTrue(workout.exercises[0].sets.allSatisfy { $0.actual.isEmpty && $0.status == .planned })
        XCTAssertEqual(workout.completedSetCount, 0)
        XCTAssertEqual(workout.plannedSetCount, 3)
        XCTAssertEqual(workout.revision, 0)
    }

    func testSeparateSessionsOnSameDayHaveIndependentStableIdentities() throws {
        let morning = try session()
        let evening = try session()
        XCTAssertNotEqual(morning.id, evening.id)
        XCTAssertNotEqual(morning.exercises[0].id, evening.exercises[0].id)
        let morningIDs = Set(morning.exercises.flatMap(\.sets).map(\.id))
        let eveningIDs = Set(evening.exercises.flatMap(\.sets).map(\.id))
        XCTAssertTrue(morningIDs.isDisjoint(with: eveningIDs))
        let restored = try JSONDecoder().decode(WorkoutSession.self, from: JSONEncoder().encode(morning))
        XCTAssertEqual(restored, morning)
    }

    func testFactoryRejectsInvalidContextAndDuplicateInjectedIDs() throws {
        let fixedID = UUID()
        XCTAssertThrowsError(try WorkoutSession.start(prescription: prescription(), planID: "plan", planRevisionID: "v1",
            ownerDeviceID: "watch", at: beginning, timeZoneIdentifier: "Asia/Singapore", makeID: { fixedID }))
        XCTAssertThrowsError(try WorkoutSession.start(prescription: prescription(), planID: "plan", planRevisionID: "v1",
            ownerDeviceID: "watch", at: beginning, timeZoneIdentifier: "not-a-timezone"))
        XCTAssertThrowsError(try WorkoutSession.start(prescription: prescription(sets: 21), planID: "plan", planRevisionID: "v1",
            ownerDeviceID: "watch", at: beginning, timeZoneIdentifier: "Asia/Singapore"))
    }

    func testEveryMeasurementLogsOnlyValidActualValues() throws {
        for measurement in MeasurementKind.allCases {
            var workout = try session(measurement: measurement)
            let setID = workout.exercises[0].sets[0].id
            let result = apply(.logSet(setID: setID, values: values(for: measurement)), to: &workout)
            XCTAssertEqual(result.status, .applied, "\(measurement): \(result.issues)")
            XCTAssertEqual(workout.completedSetCount, 1)
            XCTAssertEqual(workout.exercises[0].sets[0].actual, values(for: measurement))
        }
    }

    func testActualValidationRejectsWrongUnitsNegativeNonfiniteAndWrongEffort() {
        let cases: [(MeasurementKind, WorkoutSetValues)] = [
            (.weightReps, WorkoutSetValues(reps: 8, load: PlanQuantity(value: 20, unit: .km))),
            (.weightReps, WorkoutSetValues(reps: -1, load: PlanQuantity(value: 20, unit: .kg))),
            (.weightReps, WorkoutSetValues(reps: 8, load: PlanQuantity(value: .nan, unit: .kg))),
            (.weightReps, WorkoutSetValues(reps: 8, load: PlanQuantity(value: 20, unit: .kg), rpe: 3)),
            (.duration, WorkoutSetValues(durationSeconds: .infinity)),
            (.duration, WorkoutSetValues(durationSeconds: 0)),
            (.distance, WorkoutSetValues(distance: PlanQuantity(value: 2, unit: .kg))),
            (.distance, WorkoutSetValues(distance: PlanQuantity(value: -2, unit: .km))),
            (.durationCalories, WorkoutSetValues(durationSeconds: 100, calories: -1)),
            (.reps, WorkoutSetValues(reps: 5, rir: 11)),
            (.completion, WorkoutSetValues(reps: 5))
        ]
        for (measurement, value) in cases {
            XCTAssertFalse(WorkoutValueValidator.validate(value, measurement: measurement, requireComplete: true).isEmpty)
        }
        XCTAssertTrue(WorkoutValueValidator.validate(WorkoutSetValues(reps: 0, load: PlanQuantity(value: 0, unit: .kg), rir: 0),
            measurement: .weightReps, requireComplete: true).isEmpty, "Explicit zero is distinct from a missing observation.")
    }

    func testDraftFieldsCanBePartialButCompletionCannotUseTargetInstead() throws {
        var workout = try session()
        let id = workout.exercises[0].sets[0].id
        let partial = WorkoutSetValues(reps: 8)
        XCTAssertEqual(apply(.updateSet(setID: id, values: partial), to: &workout).status, .applied)
        let revision = workout.revision
        XCTAssertEqual(apply(.logSet(setID: id, values: partial), to: &workout).status, .rejected)
        XCTAssertEqual(workout.revision, revision)
        XCTAssertEqual(workout.completedSetCount, 0)
        XCTAssertNil(workout.exercises[0].sets[0].actual.load)
        XCTAssertNil(workout.rest)
    }

    func testCompletedSetStartsDeadlineAndDuplicateDoesNotRestartIt() throws {
        var workout = try session()
        let id = workout.exercises[0].sets[0].id
        let operation = WorkoutOperation(session: workout, command: .logSet(setID: id, values: values()), at: beginning.addingTimeInterval(10))
        workout = WorkoutReducer.apply(operation, to: workout, at: beginning.addingTimeInterval(10)).session
        XCTAssertEqual(workout.rest?.deadline, beginning.addingTimeInterval(100))
        let saved = workout
        let duplicate = WorkoutReducer.apply(operation, to: workout, at: beginning.addingTimeInterval(500))
        XCTAssertEqual(duplicate.status, .duplicate)
        XCTAssertEqual(duplicate.session, saved)
        XCTAssertEqual(duplicate.session.completedSetCount, 1)
        XCTAssertEqual(duplicate.session.rest?.remaining(at: beginning.addingTimeInterval(500)), 0)
    }

    func testRepeatedCompleteWithNewIDDoesNotDoubleCountSet() throws {
        var workout = try session()
        let id = workout.exercises[0].sets[0].id
        apply(.logSet(setID: id, values: values()), to: &workout)
        let revision = workout.revision
        XCTAssertEqual(apply(.logSet(setID: id, values: values()), to: &workout, seconds: 20).status, .rejected)
        XCTAssertEqual(workout.completedSetCount, 1)
        XCTAssertEqual(workout.revision, revision)
        XCTAssertEqual(workout.rest?.deadline, beginning.addingTimeInterval(100))
    }

    func testPauseStopsActiveTimeWhileRestContinuesAcrossRelaunch() throws {
        var workout = try session()
        let id = workout.exercises[0].sets[0].id
        apply(.logSet(setID: id, values: values()), to: &workout, seconds: 10)
        apply(.pause, to: &workout, seconds: 30)
        workout = try JSONDecoder().decode(WorkoutSession.self, from: JSONEncoder().encode(workout))
        XCTAssertEqual(workout.elapsed(at: beginning.addingTimeInterval(110)), 30)
        XCTAssertEqual(workout.rest?.remaining(at: beginning.addingTimeInterval(110)), 0)
        XCTAssertEqual(apply(.logSet(setID: workout.exercises[0].sets[1].id, values: values()), to: &workout, seconds: 110).status, .rejected)
        apply(.resume, to: &workout, seconds: 120)
        apply(.finish(allowPartial: true), to: &workout, seconds: 150)
        XCTAssertEqual(workout.elapsed(at: beginning.addingTimeInterval(1_000)), 60)
        XCTAssertEqual(workout.state, .finished)
    }

    func testPartialFinishRequiresConfirmationAndPreservesSkippedVersusUnperformed() throws {
        var workout = try session()
        let sets = workout.exercises[0].sets
        apply(.logSet(setID: sets[0].id, values: values()), to: &workout)
        apply(.skipSet(setID: sets[1].id, reason: "Equipment unavailable"), to: &workout, seconds: 20)
        let rejected = apply(.finish(allowPartial: false), to: &workout, seconds: 30)
        XCTAssertEqual(rejected.status, .rejected)
        XCTAssertTrue(rejected.issues.contains { $0.code == "partialFinishConfirmation" })
        XCTAssertEqual(workout.state, .active)
        XCTAssertEqual(apply(.finish(allowPartial: true), to: &workout, seconds: 40).status, .applied)
        XCTAssertEqual(workout.exercises[0].sets.map(\.status), [.completed, .skipped, .unperformed])
        XCTAssertEqual(workout.exercises[0].sets[1].skipReason, "Equipment unavailable")
        XCTAssertTrue(workout.isPartial)
        XCTAssertEqual(workout.completedSetCount, 1)
        XCTAssertNil(workout.rest)
    }

    func testCompleteFinishWithoutConfirmationAndHistoricalCorrectionPreserveLifecycle() throws {
        var workout = try session(sets: 1)
        let id = workout.exercises[0].sets[0].id
        apply(.logSet(setID: id, values: values()), to: &workout, seconds: 10)
        XCTAssertEqual(apply(.finish(allowPartial: false), to: &workout, seconds: 100).status, .applied)
        let endedAt = workout.endedAt
        let completedAt = workout.exercises[0].sets[0].completedAt
        let correction = WorkoutSetValues(reps: 7, load: PlanQuantity(value: 22.5, unit: .kg), rir: 1)
        XCTAssertEqual(apply(.updateSet(setID: id, values: correction), to: &workout, seconds: 1_000).status, .applied)
        XCTAssertEqual(workout.exercises[0].sets[0].actual, correction)
        XCTAssertEqual(workout.exercises[0].sets[0].completedAt, completedAt)
        XCTAssertEqual(workout.endedAt, endedAt)
        XCTAssertEqual(workout.elapsed(at: beginning.addingTimeInterval(2_000)), 100)
        XCTAssertEqual(workout.state, .finished)
        XCTAssertFalse(workout.isPartial)
        XCTAssertNil(workout.rest)
        XCTAssertEqual(workout.operationReceipts.count, 3)
        XCTAssertEqual(apply(.resume, to: &workout, seconds: 2_000).status, .rejected)
    }

    func testInvalidFinishedCorrectionDoesNotEraseCompletedValues() throws {
        var workout = try session(sets: 1)
        let id = workout.exercises[0].sets[0].id
        apply(.logSet(setID: id, values: values()), to: &workout)
        apply(.finish(allowPartial: false), to: &workout, seconds: 50)
        XCTAssertEqual(apply(.updateSet(setID: id, values: WorkoutSetValues()), to: &workout, seconds: 60).status, .rejected)
        XCTAssertEqual(workout.exercises[0].sets[0].actual, values())
        XCTAssertEqual(workout.state, .finished)
    }

    func testAbandonRetainsRecordedWorkWithoutPretendingItFinished() throws {
        var workout = try session()
        let id = workout.exercises[0].sets[0].id
        apply(.logSet(setID: id, values: values()), to: &workout)
        apply(.abandon, to: &workout, seconds: 20)
        XCTAssertEqual(workout.state, .abandoned)
        XCTAssertEqual(workout.completedSetCount, 1)
        XCTAssertEqual(workout.elapsed(at: beginning.addingTimeInterval(100)), 20)
        XCTAssertNil(workout.rest)
        XCTAssertEqual(apply(.updateSet(setID: id, values: values()), to: &workout).status, .rejected)
    }

    func testCopyLastUsesFinalEnteredSetKeepsPlannedCountAndClearsEffortAndCompletion() throws {
        var workout = try session(sets: 2)
        let exercise = workout.exercises[0]
        let later = WorkoutSetValues(reps: 9, load: PlanQuantity(value: 22.5, unit: .kg), rir: 0)
        let prior = WorkoutExercise(prescription: exercise.prescription, sets: [
            WorkoutSet(target: exercise.prescription.target, actual: values(), status: .completed),
            WorkoutSet(target: exercise.prescription.target, actual: later, status: .completed),
            WorkoutSet(target: exercise.prescription.target)
        ])
        apply(.logSet(setID: exercise.sets[0].id, values: values()), to: &workout)
        XCTAssertEqual(apply(.copyLast(exerciseID: exercise.id, previous: prior), to: &workout, seconds: 30).status, .applied)
        XCTAssertEqual(workout.exercises[0].sets.count, 2)
        XCTAssertEqual(workout.exercises[0].sets.map(\.id), exercise.sets.map(\.id))
        XCTAssertTrue(workout.exercises[0].sets.allSatisfy { $0.status == .planned && $0.actual == later.withoutEffort && $0.completedAt == nil })
        XCTAssertEqual(workout.completedSetCount, 0)
        XCTAssertNil(workout.rest)
        XCTAssertEqual(prior.sets[1].actual.rir, 0)
    }

    func testCopyLastRejectsDifferentExerciseOrMeasurement() throws {
        var workout = try session()
        var plan = workout.exercises[0].prescription
        plan.exerciseId = "different-squat"
        let prior = WorkoutExercise(prescription: plan, sets: [WorkoutSet(target: plan.target, actual: values())])
        XCTAssertEqual(apply(.copyLast(exerciseID: workout.exercises[0].id, previous: prior), to: &workout).status, .rejected)
        XCTAssertTrue(workout.exercises[0].sets.allSatisfy { $0.actual.isEmpty })
    }

    func testFillEmptySetsPreservesEnteredZeroAndEffortAndNeverCompletes() throws {
        var workout = try session()
        let sets = workout.exercises[0].sets
        apply(.updateSet(setID: sets[0].id, values: values()), to: &workout)
        apply(.updateSet(setID: sets[1].id, values: WorkoutSetValues(load: PlanQuantity(value: 0, unit: .kg), rir: 4)), to: &workout, seconds: 20)
        apply(.fillEmptySets(exerciseID: workout.exercises[0].id), to: &workout, seconds: 30)
        XCTAssertEqual(workout.exercises[0].sets[1].actual.load?.value, 0)
        XCTAssertEqual(workout.exercises[0].sets[1].actual.reps, 8)
        XCTAssertEqual(workout.exercises[0].sets[1].actual.rir, 4)
        XCTAssertNil(workout.exercises[0].sets[2].actual.rir)
        XCTAssertTrue(workout.exercises[0].sets.allSatisfy { $0.status == .planned })
        XCTAssertEqual(workout.completedSetCount, 0)
    }

    func testOptionalExerciseStartsOffAndCannotHideRecordedResults() throws {
        var workout = try session(optional: true)
        let exerciseID = workout.exercises[0].id
        let setID = workout.exercises[0].sets[0].id
        XCTAssertFalse(workout.exercises[0].isEnabled)
        XCTAssertEqual(workout.plannedSetCount, 0)
        XCTAssertEqual(apply(.logSet(setID: setID, values: values()), to: &workout).status, .rejected)
        apply(.setExerciseEnabled(exerciseID: exerciseID, enabled: true), to: &workout, seconds: 20)
        XCTAssertEqual(workout.plannedSetCount, 3)
        apply(.logSet(setID: setID, values: values()), to: &workout, seconds: 30)
        XCTAssertEqual(apply(.setExerciseEnabled(exerciseID: exerciseID, enabled: false), to: &workout, seconds: 40).status, .rejected)
        XCTAssertTrue(workout.exercises[0].isEnabled)
        XCTAssertEqual(workout.completedSetCount, 1)
    }

    func testUndoCompletionClearsItsRestButRetainsEditableValues() throws {
        var workout = try session()
        let id = workout.exercises[0].sets[0].id
        apply(.logSet(setID: id, values: values()), to: &workout)
        apply(.undoSet(setID: id), to: &workout, seconds: 20)
        XCTAssertEqual(workout.exercises[0].sets[0].status, .planned)
        XCTAssertEqual(workout.exercises[0].sets[0].actual, values())
        XCTAssertNil(workout.exercises[0].sets[0].completedAt)
        XCTAssertNil(workout.rest)
        apply(.skipSet(setID: id, reason: "Skipped"), to: &workout, seconds: 30)
        apply(.undoSet(setID: id), to: &workout, seconds: 40)
        XCTAssertNil(workout.exercises[0].sets[0].skipReason)
    }

    func testRestExtensionIsReplaySafeAndExplicitExpiredExtensionUsesCurrentTime() throws {
        var workout = try session()
        apply(.logSet(setID: workout.exercises[0].sets[0].id, values: values()), to: &workout)
        let op = WorkoutOperation(session: workout, command: .extendRest(seconds: 30), at: beginning.addingTimeInterval(20))
        workout = WorkoutReducer.apply(op, to: workout, at: beginning.addingTimeInterval(20)).session
        XCTAssertEqual(workout.rest?.deadline, beginning.addingTimeInterval(130))
        let duplicate = WorkoutReducer.apply(op, to: workout, at: beginning.addingTimeInterval(200))
        XCTAssertEqual(duplicate.session.rest?.deadline, beginning.addingTimeInterval(130))
        apply(.extendRest(seconds: 30), to: &workout, seconds: 200)
        XCTAssertEqual(workout.rest?.deadline, beginning.addingTimeInterval(230))
        apply(.skipRest, to: &workout, seconds: 210)
        XCTAssertNil(workout.rest)
    }

    func testConcurrentEditPreservesAcceptedAndProposedValuesAndReplaysOnce() throws {
        var workout = try session()
        let setID = workout.exercises[0].sets[0].id
        let original = workout
        let watch = WorkoutOperation(session: original, command: .updateSet(setID: setID, values: values()), at: beginning.addingTimeInterval(10))
        let proposed = WorkoutSetValues(reps: 7, load: PlanQuantity(value: 25, unit: .kg))
        let phone = WorkoutOperation(session: original, command: .updateSet(setID: setID, values: proposed), originDeviceID: "phone-1", at: beginning.addingTimeInterval(11))
        workout = WorkoutReducer.apply(watch, to: workout, at: beginning.addingTimeInterval(10)).session
        let conflict = WorkoutReducer.apply(phone, to: workout, at: beginning.addingTimeInterval(12))
        XCTAssertEqual(conflict.status, .conflict)
        XCTAssertEqual(conflict.session.revision, 1)
        XCTAssertEqual(conflict.session.conflicts.count, 1)
        XCTAssertEqual(conflict.session.conflicts[0].operation.command, phone.command)
        XCTAssertEqual(conflict.session.conflicts[0].acceptedSets[0].actual, values())
        XCTAssertEqual(conflict.session.exercises[0].sets[0].actual, values())
        let restored = try JSONDecoder().decode(WorkoutSession.self, from: JSONEncoder().encode(conflict.session))
        let duplicate = WorkoutReducer.apply(phone, to: restored, at: beginning.addingTimeInterval(100))
        XCTAssertEqual(duplicate.status, .duplicate)
        XCTAssertEqual(duplicate.session, restored)
    }

    func testOneHundredReorderedDuplicatedOperationsSurvivePersistenceAndDrainExactlyOnce() throws {
        var workout = try session()
        let id = workout.exercises[0].sets[0].id
        let operations = (0..<100).map { index in
            WorkoutOperation(sessionID: workout.id, originDeviceID: workout.ownerDeviceID,
                syncGeneration: workout.syncGeneration, expectedRevision: index,
                command: .updateSet(setID: id, values: WorkoutSetValues(reps: index, load: PlanQuantity(value: 20, unit: .kg))),
                createdAt: beginning.addingTimeInterval(Double(index + 1)))
        }
        for index in (0..<100).reversed() {
            let result = WorkoutReducer.apply(operations[index], to: workout, at: beginning.addingTimeInterval(1_000))
            workout = result.session
            XCTAssertEqual(result.status, index == 0 ? .applied : .buffered)
            let repeated = WorkoutReducer.apply(operations[index], to: workout, at: beginning.addingTimeInterval(2_000))
            XCTAssertEqual(repeated.status, .duplicate)
            XCTAssertEqual(repeated.session, workout)
            if index == 50 {
                workout = try JSONDecoder().decode(WorkoutSession.self, from: JSONEncoder().encode(workout))
            }
        }
        XCTAssertEqual(workout.revision, 100)
        XCTAssertEqual(workout.operationReceipts.count, 100)
        XCTAssertEqual(Set(workout.operationReceipts.map(\.id)).count, 100)
        XCTAssertEqual(workout.exercises[0].sets[0].actual.reps, 99)
        XCTAssertTrue(workout.pendingOperations.isEmpty)
        XCTAssertTrue(workout.conflicts.isEmpty)
        XCTAssertEqual(workout.completedSetCount, 0)
        XCTAssertEqual(workout.lastAppliedAt, beginning.addingTimeInterval(100))
    }

    func testOutOfOrderLogAndPausePreserveOwnerTimingAndRestDeadline() throws {
        var workout = try session()
        let log = WorkoutOperation(sessionID: workout.id, originDeviceID: workout.ownerDeviceID, syncGeneration: workout.syncGeneration,
            expectedRevision: 0, command: .logSet(setID: workout.exercises[0].sets[0].id, values: values()), createdAt: beginning.addingTimeInterval(10))
        let pause = WorkoutOperation(sessionID: workout.id, originDeviceID: workout.ownerDeviceID, syncGeneration: workout.syncGeneration,
            expectedRevision: 1, command: .pause, createdAt: beginning.addingTimeInterval(20))
        workout = WorkoutReducer.apply(pause, to: workout, at: beginning.addingTimeInterval(200)).session
        let drained = WorkoutReducer.apply(log, to: workout, at: beginning.addingTimeInterval(200))
        XCTAssertEqual(drained.appliedOperationIDs, [log.id, pause.id])
        XCTAssertEqual(drained.session.state, .paused)
        XCTAssertEqual(drained.session.elapsed(at: beginning.addingTimeInterval(500)), 20)
        XCTAssertEqual(drained.session.rest?.deadline, beginning.addingTimeInterval(100))
    }

    func testGenerationAndSessionGuardsCannotResurrectOldData() throws {
        let workout = try session()
        for operation in [
            WorkoutOperation(sessionID: workout.id, originDeviceID: "watch-1", syncGeneration: "erased-store", expectedRevision: 0, command: .pause, createdAt: beginning),
            WorkoutOperation(sessionID: UUID(), originDeviceID: "watch-1", syncGeneration: workout.syncGeneration, expectedRevision: 0, command: .pause, createdAt: beginning)
        ] {
            let result = WorkoutReducer.apply(operation, to: workout, at: beginning)
            XCTAssertEqual(result.status, .rejected)
            XCTAssertEqual(result.session, workout)
        }
    }

    func testReusingOperationIDForChangedPayloadIsRejectedWithoutChangingAcceptedData() throws {
        let initial = try session()
        let operation = WorkoutOperation(session: initial, command: .pause, at: beginning.addingTimeInterval(10))
        let paused = WorkoutReducer.apply(operation, to: initial, at: beginning.addingTimeInterval(10)).session
        let reused = WorkoutOperation(id: operation.id, sessionID: operation.sessionID, originDeviceID: operation.originDeviceID,
            syncGeneration: operation.syncGeneration, expectedRevision: operation.expectedRevision, command: .abandon, createdAt: operation.createdAt)
        let result = WorkoutReducer.apply(reused, to: paused, at: beginning.addingTimeInterval(20))
        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.session, paused)
        XCTAssertTrue(result.issues.contains { $0.code == "operationIDReused" })
    }

    func testUnknownSetDoesNotPartiallyMutateSessionAndClockRegressionDoesNotLoseElapsedTime() throws {
        var workout = try session()
        XCTAssertEqual(apply(.logSet(setID: UUID(), values: values()), to: &workout).status, .rejected)
        XCTAssertEqual(workout.revision, 0)
        XCTAssertEqual(workout.completedSetCount, 0)
        apply(.logSet(setID: workout.exercises[0].sets[0].id, values: values()), to: &workout, seconds: 20)
        apply(.pause, to: &workout, seconds: 10)
        XCTAssertEqual(workout.elapsed(at: beginning.addingTimeInterval(100)), 20)
        XCTAssertEqual(workout.lastAppliedAt, beginning.addingTimeInterval(20))
    }

    func testEveryCardioModeRetainsSupplementaryMachineReadingsIncludingZeros() throws {
        let readout = WorkoutSetValues(durationSeconds: 1_470, distance: PlanQuantity(value: 8.25, unit: .km),
            calories: 0, rpe: 7, averageRpm: 82.5, averageHeartRate: 151)
        for measurement in [MeasurementKind.duration, .durationCalories, .distanceTime, .distance] {
            var workout = try session(measurement: measurement)
            let result = apply(.logSet(setID: workout.exercises[0].sets[0].id, values: readout), to: &workout)
            XCTAssertEqual(result.status, .applied, "\(measurement): \(result.issues)")
            let restored = try JSONDecoder().decode(WorkoutSession.self, from: JSONEncoder().encode(workout))
            XCTAssertEqual(restored.exercises[0].sets[0].actual, readout)
            XCTAssertTrue(WorkoutArchiveValidator.validate(restored).isEmpty)
        }
        XCTAssertFalse(WorkoutValueValidator.validate(readout, measurement: .weightDistance, requireComplete: false).isEmpty)
    }

    func testMissingMachineCaloriesAndPartialTimeDistanceReadoutsRemainUnknown() {
        XCTAssertTrue(WorkoutValueValidator.validate(WorkoutSetValues(durationSeconds: 1_200), measurement: .durationCalories, requireComplete: true).isEmpty)
        XCTAssertTrue(WorkoutValueValidator.validate(WorkoutSetValues(durationSeconds: 1_200), measurement: .distanceTime, requireComplete: true).isEmpty)
        XCTAssertTrue(WorkoutValueValidator.validate(WorkoutSetValues(distance: PlanQuantity(value: 5, unit: .km)), measurement: .distanceTime, requireComplete: true).isEmpty)
        XCTAssertTrue(WorkoutValueValidator.validate(WorkoutSetValues(durationSeconds: 1_200, distance: PlanQuantity(value: 0, unit: .km), calories: 0), measurement: .duration, requireComplete: true).isEmpty)
        XCTAssertFalse(WorkoutValueValidator.validate(WorkoutSetValues(rpe: 5), measurement: .distanceTime, requireComplete: true).isEmpty)
    }

    func testCardioCopyLastExcludesSupplementalReadingsAndEffort() throws {
        var workout = try session(measurement: .duration, sets: 2)
        let exercise = workout.exercises[0]
        let readout = WorkoutSetValues(durationSeconds: 1_470, distance: PlanQuantity(value: 8.25, unit: .km),
            calories: 285, rpe: 7, averageRpm: 82.5, averageHeartRate: 151)
        let old = WorkoutExercise(prescription: exercise.prescription, sets: [
            WorkoutSet(target: exercise.prescription.target, actual: readout, status: .completed),
            WorkoutSet(target: exercise.prescription.target, actual: WorkoutSetValues(calories: 300, averageHeartRate: 130))
        ])
        XCTAssertEqual(apply(.copyLast(exerciseID: exercise.id, previous: old), to: &workout).status, .applied)
        XCTAssertTrue(workout.exercises[0].sets.allSatisfy {
            $0.actual == WorkoutSetValues(durationSeconds: 1_470) && $0.status == .planned
        })
    }

    func testSnapshotsValidateAfterFinishAndHistoricalCorrection() throws {
        var workout = try session(sets: 1)
        XCTAssertTrue(WorkoutSessionValidator.validate(workout).isEmpty)
        let id = workout.exercises[0].sets[0].id
        apply(.logSet(setID: id, values: values()), to: &workout)
        XCTAssertTrue(WorkoutSessionValidator.validate(workout).isEmpty)
        apply(.pause, to: &workout, seconds: 20)
        XCTAssertTrue(WorkoutSessionValidator.validate(workout).isEmpty)
        apply(.finish(allowPartial: false), to: &workout, seconds: 30)
        apply(.updateSet(setID: id, values: WorkoutSetValues(reps: 7, load: PlanQuantity(value: 20, unit: .kg))), to: &workout, seconds: 100)
        XCTAssertTrue(WorkoutArchiveValidator.validate(workout).isEmpty)
    }

    func testDecodedMalformedSnapshotCannotBypassIdentityLifecycleAndActualChecks() throws {
        var workout = try session()
        let first = workout.exercises[0].sets[0]
        workout.exercises[0].sets[1] = WorkoutSet(id: first.id, target: first.target)
        workout.exercises[0].sets[0] = WorkoutSet(id: first.id, target: first.target,
            actual: WorkoutSetValues(reps: -1, load: PlanQuantity(value: 20, unit: .km)), status: .completed)
        workout.state = .finished
        let restored = try JSONDecoder().decode(WorkoutSession.self, from: JSONEncoder().encode(workout))
        let issues = WorkoutArchiveValidator.validate(restored)
        for code in ["snapshot.duplicateIdentity", "snapshot.lifecycle", "snapshot.completionTime", "actual.reps", "actual.load"] {
            XCTAssertTrue(issues.contains { $0.code == code }, code)
        }
    }

    func testSnapshotCannotSubstituteFrozenTargetsOrWrongGenerationInQueue() throws {
        var workout = try session()
        let set = workout.exercises[0].sets[0]
        workout.exercises[0].sets[0] = WorkoutSet(id: set.id, target: ExerciseTarget(sets: 1, restSeconds: 1))
        workout.pendingOperations = [WorkoutOperation(sessionID: workout.id, originDeviceID: "phone-1",
            syncGeneration: "old-generation", expectedRevision: 2, command: .pause, createdAt: beginning)]
        let issues = WorkoutArchiveValidator.validate(workout)
        XCTAssertTrue(issues.contains { $0.code == "snapshot.target" })
        XCTAssertTrue(issues.contains { $0.code == "snapshot.operation" })
    }

    func testNonfiniteFutureOperationIsRejectedBeforeItCanPoisonDurableQueue() throws {
        let workout = try session()
        let operation = WorkoutOperation(sessionID: workout.id, originDeviceID: "phone-1", syncGeneration: workout.syncGeneration,
            expectedRevision: 2, command: .updateSet(setID: workout.exercises[0].sets[0].id,
                values: WorkoutSetValues(reps: 8, load: PlanQuantity(value: .nan, unit: .kg))), createdAt: beginning)
        let result = WorkoutReducer.apply(operation, to: workout, at: beginning)
        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.session, workout)
        XCTAssertTrue(result.issues.contains { $0.code == "unpersistableOperation" })
    }

    func testUntrustedRevisionExtremesAreRejectedWithoutOverflow() throws {
        var workout = try session()
        let operation = WorkoutOperation(sessionID: workout.id, originDeviceID: workout.ownerDeviceID,
            syncGeneration: workout.syncGeneration, expectedRevision: Int.max, command: .pause, createdAt: beginning)
        workout.operationReceipts = [WorkoutOperationReceipt(operation: operation, status: .applied,
            resultingRevision: 1, processedAt: beginning, issues: [])]
        XCTAssertTrue(WorkoutArchiveValidator.validate(workout).contains { $0.code == "snapshot.appliedRevision" })
        workout.revision = Int.max
        let result = WorkoutReducer.apply(WorkoutOperation(session: workout, command: .pause, at: beginning), to: workout, at: beginning)
        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.session, workout)
    }
}
