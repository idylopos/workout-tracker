import XCTest
@testable import FormFlowCore

final class ProgressionTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-20T12:00:00Z")!
    private func date(_ day: Int, hour: Int = 12) -> Date {
        ISO8601DateFormatter().date(from: String(format: "2026-09-%02dT%02d:00:00Z", day, hour))!
    }

    private func exposure(day: Int = 19, policy: BuiltInProgressionPolicy = .strength,
                          step: Int? = nil, stage: Int? = nil, answers: ProgressionAnswers = .init(technique: .yes),
                          values: [WorkoutSetValues]? = nil, completedCount: Int? = nil,
                          readiness: RecoveryReadiness = .yes, nextRating: Int? = nil, eveningRating: Int? = nil,
                          revision: String = "revision-1", planID: String = "form-flow", variant: String = "",
                          optedIn: Bool = true, timeZone: String = "UTC") throws -> ProgressionExposure {
        let target: ExerciseTarget
        let measurement: MeasurementKind
        if policy == .pullUp {
            let descriptor = BuiltInProgression.pullUpSteps[(step ?? 2) - 1]
            measurement = descriptor.measurement
            target = .init(sets: descriptor.sets, restSeconds: 90,
                           reps: .init(min: descriptor.minReps, max: descriptor.maxReps),
                           effort: .init(kind: .rir, min: descriptor.minimumRIR, max: 3))
        } else if policy == .longRun || policy == .easyRun {
            measurement = .distanceTime
            let km = stage.map { BuiltInProgression.longRunStages[$0 - 1].distanceKM } ?? 4.5
            target = .init(sets: 1, restSeconds: 0, distance: .init(min: km, max: km, unit: .km))
        } else {
            measurement = .weightReps
            target = .init(sets: 3, restSeconds: 90, reps: .init(min: 6, max: 10), effort: .init(kind: .rir, min: 2, max: 3))
        }
        let prescription = PlanExercise(instanceId: "main", exerciseId: "movement", name: "Movement",
                                        measurement: measurement, equipment: ["equipment"], target: target,
                                        progressionPolicy: policy.reference)
        let sessionPlan = PlanSession(id: "session", name: "Session", kind: "mixed", estimatedMinutes: 30, exercises: [prescription])
        var session = try WorkoutSession.start(prescription: sessionPlan, planID: planID, planRevisionID: revision,
                                               ownerDeviceID: "phone", at: date(day), timeZoneIdentifier: timeZone)
        for i in 0..<(completedCount ?? target.sets) {
            let actual: WorkoutSetValues
            if let values { actual = values[i] }
            else if policy == .pullUp {
                actual = .init(reps: target.reps!.max,
                               assistance: measurement == .reps ? nil : .init(value: (step ?? 2) >= 5 ? 0 : 23, unit: .kg),
                               rir: target.effort!.min)
            } else if policy == .longRun || policy == .easyRun {
                actual = .init(distance: .init(value: target.distance!.min, unit: .km), rpe: 4)
            } else { actual = .init(reps: 10, load: .init(value: 20, unit: .kg), rir: 2) }
            let command = WorkoutOperation(session: session, command: .logSet(setID: session.exercises[0].sets[i].id, values: actual), at: date(day).addingTimeInterval(Double(i + 1)))
            let result = WorkoutReducer.apply(command, to: session, at: command.createdAt)
            XCTAssertEqual(result.status, .applied, "\(result.issues)")
            session = result.session
        }
        let finish = WorkoutOperation(session: session, command: .finish(allowPartial: true), at: date(day, hour: 13))
        session = WorkoutReducer.apply(finish, to: session, at: finish.createdAt).session
        let zone = TimeZone(identifier: timeZone)!
        let morning = try SessionRecoveryRecord(sessionID: session.id, phase: .nextMorning,
                                                day: LocalTrainingDay(instant: date(day + 1), timeZone: zone),
                                                rating: nextRating, readiness: readiness, updatedAt: date(day + 1))
        var recovery = [morning]
        if let eveningRating {
            recovery.append(try SessionRecoveryRecord(sessionID: session.id, phase: .evening,
                                                       day: LocalTrainingDay(instant: date(day), timeZone: zone),
                                                       rating: eveningRating, updatedAt: date(day, hour: 19)))
        }
        return try .init(session: session, exerciseID: session.exercises[0].id,
                         configuration: .init(policy: policy.reference, optedIn: optedIn, variantID: variant,
                                              pullUpStep: policy == .pullUp ? (step ?? 2) : nil, longRunStage: stage),
                         answers: answers, recovery: recovery)
    }
    private func advice(_ source: ProgressionExposure, _ history: [ProgressionExposure] = [], at date: Date? = nil) -> ProgressionAdvice {
        ProgressionEngine.advice(for: source, history: history, currentPlanRevisionID: "current-plan", asOf: date ?? now)
    }
    private func rebuilt(_ source: ProgressionExposure, answers: ProgressionAnswers? = nil,
                         configuration: ProgressionConfiguration? = nil, recovery: [SessionRecoveryRecord]? = nil) throws -> ProgressionExposure {
        try .init(session: source.session, exerciseID: source.exerciseID, configuration: configuration ?? source.configuration,
                  answers: answers ?? source.answers, recovery: recovery ?? source.recovery)
    }
    private func accept(_ recommendation: ProgressionAdvice, history: [ProgressionExposure],
                        load: Double? = nil, equipment: [Double] = [22.5], revision: String = "current-plan") throws -> FutureProgressionTarget {
        try ProgressionEngine.accept(recommendation, currentPlanID: recommendation.source.session.planID,
                                     currentPlanRevisionID: revision, currentExercise: recommendation.source.exercise.prescription,
                                     configuration: recommendation.source.configuration, history: history,
                                     enteredLoad: load.map { .init(value: $0, unit: .kg) },
                                     availableEquipmentLoads: equipment.map { .init(value: $0, unit: .kg) }, at: now)
    }

    func testTwoMatchingRecoveredStrengthExposuresAndDifferentPlan() throws {
        let current = try exposure(), previous = try exposure(day: 15)
        XCTAssertEqual(advice(current).action, .repeatTarget)
        XCTAssertEqual(advice(current, [previous, current]).action, .increase)
        XCTAssertEqual(advice(current, [try exposure(day: 15, planID: "other")]).action, .repeatTarget)
        let lighter = Array(repeating: WorkoutSetValues(reps: 10, load: .init(value: 15, unit: .kg), rir: 2), count: 3)
        XCTAssertEqual(advice(current, [try exposure(day: 15, values: lighter)]).action, .repeatTarget)
    }

    func testUnrelatedRevisionPreservesComparableHistory() throws {
        let current = try exposure(revision: "renamed-plan"), prior = try exposure(day: 15, revision: "old-plan")
        XCTAssertEqual(advice(current, [prior]).action, .increase)
        let alternate = try exposure(day: 18, variant: "other-movement-variant")
        XCTAssertEqual(advice(current, [prior, alternate]).action, .increase)
    }

    func testIncompleteAndLatestNonqualifyingExposureBreakChain() throws {
        let prior = try exposure(day: 15), incomplete = try exposure(completedCount: 2)
        XCTAssertEqual(advice(incomplete, [prior]).action, .repeatTarget)
        let bad = try exposure(day: 18, answers: .init(technique: .no))
        XCTAssertEqual(advice(try exposure(), [prior, bad]).action, .repeatTarget)
    }

    func testMissingUnknownAndSameDayRecoveryNeverQualify() throws {
        let prior = try exposure(day: 15)
        XCTAssertEqual(advice(try exposure(readiness: .unknown), [prior]).action, .pending)
        XCTAssertEqual(advice(try rebuilt(exposure(), recovery: []), [prior]).action, .pending)
        XCTAssertEqual(advice(try exposure(), [prior], at: date(19, hour: 23)).action, .pending)
        XCTAssertEqual(advice(try exposure(readiness: .yes, nextRating: 2), [prior]).action, .reduce)
    }

    func testHardestLoggedRIRCannotBeOverriddenAndUnknownStaysUnknown() throws {
        let values = [WorkoutSetValues(reps: 10, load: .init(value: 20, unit: .kg), rir: 0),
                      .init(reps: 10, load: .init(value: 20, unit: .kg)),
                      .init(reps: 10, load: .init(value: 20, unit: .kg), rir: 2)]
        let current = try exposure(answers: .init(technique: .yes, reserve: 4), values: values)
        XCTAssertNil(ProgressionEngine.recordedReserve(current))
        XCTAssertEqual(advice(current).action, .reduce)
        XCTAssertEqual(advice(try rebuilt(current, answers: .init(technique: .yes))).action, .pending)
    }

    func testLimitingSymptomsPauseInsteadOfReducingLoad() throws {
        let source = try exposure(answers: .init(technique: .yes, duringRating: 3))
        XCTAssertEqual(advice(source).action, .pending)
        XCTAssertEqual(advice(source).title, "Pause the provoking exercise")
        XCTAssertFalse(ProgressionEngine.isQualified(source, asOf: now))
        XCTAssertEqual(advice(try exposure(eveningRating: 4)).action, .pending)
    }

    func testManualDefaultUnsupportedVersionAndIncompatiblePolicy() throws {
        XCTAssertEqual(advice(try exposure(optedIn: false)).action, .manual)
        let source = try exposure()
        for policy in [PlanPolicyReference(id: "ai-says-increase", version: 1), .init(id: BuiltInProgressionPolicy.strength.rawValue, version: 2)] {
            var configuration = source.configuration; configuration.policy = policy
            XCTAssertEqual(advice(try rebuilt(source, configuration: configuration)).action, .manual)
        }
        var invalid = source.exercise.prescription
        invalid.target.reps = nil
        XCTAssertFalse(ProgressionEngine.supports(configuration: source.configuration, exercise: invalid))
        invalid = source.exercise.prescription; invalid.target.duration = .init(min: 5, max: 10, unit: .s)
        XCTAssertFalse(ProgressionEngine.supports(configuration: source.configuration, exercise: invalid))
        var invalidStage = source.configuration; invalidStage.longRunStage = 999
        XCTAssertFalse(ProgressionEngine.supports(configuration: invalidStage, exercise: source.exercise.prescription))
    }

    func testPullUpTopRepsAndExplicitLowerAssistance() throws {
        let lowReps = Array(repeating: WorkoutSetValues(reps: 6, assistance: .init(value: 23, unit: .kg), rir: 1), count: 3)
        let prior = try exposure(day: 15, policy: .pullUp)
        XCTAssertEqual(advice(try exposure(policy: .pullUp, values: lowReps), [prior]).action, .repeatTarget)
        let current = try exposure(policy: .pullUp), suggestion = advice(current, [prior])
        XCTAssertEqual(suggestion.nextStep, 3)
        XCTAssertThrowsError(try accept(suggestion, history: [prior, current]))
        XCTAssertThrowsError(try accept(suggestion, history: [prior, current], load: 30, equipment: [30]))
        XCTAssertEqual(try accept(suggestion, history: [prior, current], load: 20, equipment: [20]).assistance?.value, 20)
    }

    func testPullUpBaseKeepsAssistanceAndSinglesRequireExplicitReadiness() throws {
        let base = try exposure(policy: .pullUp, step: 1), priorBase = try exposure(day: 15, policy: .pullUp, step: 1)
        let accepted = try accept(advice(base, [priorBase]), history: [priorBase, base])
        XCTAssertEqual(accepted.pullUpStep, 2); XCTAssertEqual(accepted.assistance?.value, 23)
        let current = try exposure(policy: .pullUp, step: 3), prior = try exposure(day: 15, policy: .pullUp, step: 3)
        XCTAssertEqual(advice(current, [prior]).action, .repeatTarget)
        let ready = try rebuilt(current, answers: .init(technique: .yes, readySingle: .yes))
        XCTAssertEqual(advice(ready, [prior]).nextStep, 4)
    }

    func testSinglesRequireThreeUnassistedAndTwoAssistedBackoffSets() throws {
        var values = Array(repeating: WorkoutSetValues(reps: 1, assistance: .init(value: 0, unit: .kg), rir: 1), count: 3)
        values += Array(repeating: .init(reps: 5, assistance: .init(value: 15, unit: .kg), rir: 1), count: 2)
        XCTAssertTrue(ProgressionEngine.isQualified(try exposure(policy: .pullUp, step: 4, values: values), asOf: now))
        values[2].assistance = .init(value: 5, unit: .kg)
        XCTAssertFalse(ProgressionEngine.isQualified(try exposure(policy: .pullUp, step: 4, values: values), asOf: now))
    }

    func testAssistedDoublesNeverCountAsUnassistedAndStepSixDoesNotAdvance() throws {
        let values = Array(repeating: WorkoutSetValues(reps: 2, assistance: .init(value: 5, unit: .kg), rir: 1), count: 4)
        XCTAssertFalse(ProgressionEngine.isQualified(try exposure(policy: .pullUp, step: 5, values: values), asOf: now))
        XCTAssertTrue(ProgressionEngine.isQualified(try exposure(policy: .pullUp, step: 5), asOf: now))
        let current = try exposure(policy: .pullUp, step: 6), prior = try exposure(day: 15, policy: .pullUp, step: 6)
        XCTAssertEqual(advice(current, [prior]).title, "Five clean reps achieved")
        XCTAssertNil(advice(current, [prior]).nextStep)
    }

    func testUnassistedReductionChangesOnlyFutureMeasurement() throws {
        let current = try exposure(policy: .pullUp, step: 6, answers: .init(technique: .difficult))
        let target = try accept(advice(current), history: [current], load: 10, equipment: [10])
        XCTAssertEqual(target.measurement, .assistedReps)
        XCTAssertEqual(target.assistance?.value, 10)
        XCTAssertEqual(current.exercise.prescription.measurement, .reps)
    }

    func testAllEighteenLongRunStagesMatchSourceAndAdvanceIndependently() throws {
        let labels = ["4.5 km", "4.8 km", "5.2 km", "4.5 km cutback", "5.6 km", "6.0 km", "6.5 km", "5.2 km cutback", "7.0 km", "7.6 km", "8.2 km", "6.5 km cutback", "8.8 km", "9.4 km", "10.0 km", "8.0 km cutback", "10.0 km repeat", "6–7 km recovery"]
        XCTAssertEqual(BuiltInProgression.longRunStages.map(\.label), labels)
        for stage in BuiltInProgression.longRunStages {
            let source = try exposure(policy: .longRun, stage: stage.id)
            let suggestion = advice(source)
            XCTAssertEqual(suggestion.action, stage.id == 18 ? .repeatTarget : .stage, "Stage \(stage.id)")
            XCTAssertEqual(suggestion.nextStage, stage.id == 18 ? nil : stage.id + 1)
            let target = try accept(suggestion, history: [source])
            XCTAssertEqual(target.longRunDistance?.value, BuiltInProgression.longRunStages[(suggestion.nextStage ?? stage.id) - 1].distanceKM)
        }
        XCTAssertEqual(BuiltInProgression.longRunStages[17].distanceKM, 6)
    }

    func testConversationalRunDoesNotFabricateRPEAndHardRPEOverridesAnswer() throws {
        var values = [WorkoutSetValues(distance: .init(value: 4.5, unit: .km))]
        let easy = try exposure(policy: .longRun, stage: 1, answers: .init(conversational: .yes), values: values)
        XCTAssertEqual(advice(easy).nextStage, 2)
        XCTAssertNil(easy.exercise.sets[0].actual.rpe)
        XCTAssertEqual(advice(try rebuilt(easy, answers: .init())).action, .pending)
        values[0].rpe = 5
        XCTAssertEqual(advice(try exposure(policy: .longRun, stage: 1, answers: .init(conversational: .yes), values: values)).action, .repeatTarget)
    }

    func testRunToleranceShortDistanceRecoveryAndEasyRunAreDistinct() throws {
        for (km, action) in [(4.45, ProgressionAction.stage), (4.44, .repeatTarget)] {
            let values = [WorkoutSetValues(distance: .init(value: km * 1_000, unit: .m), rpe: 4)]
            XCTAssertEqual(advice(try exposure(policy: .longRun, stage: 1, values: values)).action, action)
        }
        XCTAssertEqual(advice(try exposure(policy: .longRun, stage: 1, readiness: .no)).action, .reduce)
        XCTAssertEqual(advice(try exposure(policy: .easyRun)).action, .repeatTarget)
        XCTAssertNil(advice(try exposure(policy: .easyRun)).nextStage)
    }

    func testTwoSeparateTenKMRunsAndUnknownNotCounted() throws {
        let first = try exposure(day: 15, policy: .longRun, stage: 15)
        let second = try exposure(policy: .longRun, stage: 17)
        XCTAssertEqual(ProgressionEngine.qualifiedTenKMRunCount([first, first, second], asOf: now), 2)
        let unknown = try rebuilt(second, recovery: [])
        XCTAssertEqual(ProgressionEngine.qualifiedTenKMRunCount([first, unknown], asOf: now), 1)
    }

    func testAcceptanceDirectionEquipmentAndOriginalImmutability() throws {
        let current = try exposure(), prior = try exposure(day: 15), before = current
        let suggestion = advice(current, [prior])
        for value in [20.0, -1] { XCTAssertThrowsError(try accept(suggestion, history: [prior, current], load: value)) }
        XCTAssertThrowsError(try accept(suggestion, history: [prior, current], load: 22.5, equipment: [25])) {
            XCTAssertEqual($0 as? ProgressionError, .unavailableEquipmentLoad)
        }
        let target = try accept(suggestion, history: [prior, current], load: 22.5)
        XCTAssertEqual(target.restartReps, 6); XCTAssertEqual(target.load?.value, 22.5)
        XCTAssertEqual(current, before)
    }

    func testAcceptanceRejectsPlanRevisionNewerHistoryAndChangedRecovery() throws {
        let current = try exposure(), prior = try exposure(day: 15), suggestion = advice(current, [prior])
        XCTAssertThrowsError(try accept(suggestion, history: [prior, current], load: 22.5, revision: "edited")) {
            XCTAssertEqual($0 as? ProgressionError, .stalePlan)
        }
        let newer = try exposure(day: 20)
        XCTAssertThrowsError(try accept(suggestion, history: [prior, current, newer], load: 22.5)) {
            XCTAssertEqual($0 as? ProgressionError, .staleHistory)
        }
        let corrected = try rebuilt(prior, answers: .init(technique: .no))
        XCTAssertThrowsError(try accept(suggestion, history: [corrected, current], load: 22.5)) {
            XCTAssertEqual($0 as? ProgressionError, .staleHistory)
        }
    }

    func testCanonicalUnitsMatchDifficulty() throws {
        let pounds = Array(repeating: WorkoutSetValues(reps: 10, load: .init(value: 20 / 0.45359237, unit: .lb), rir: 2), count: 3)
        XCTAssertEqual(advice(try exposure(), [try exposure(day: 15, values: pounds)]).action, .increase)
    }

    func testCapturedTimezoneAndCompletionDayGuardFollowingMorning() throws {
        let source = try exposure(timeZone: "Asia/Singapore")
        let sameDay = try SessionRecoveryRecord(sessionID: source.session.id, phase: .nextMorning,
                                                day: source.completionDay, readiness: .yes, updatedAt: date(19, hour: 23))
        XCTAssertEqual(advice(try rebuilt(source, recovery: [sameDay])).action, .pending)
        let wrongZone = try SessionRecoveryRecord(sessionID: source.session.id, phase: .nextMorning,
                                                  day: .init(date: "2026-09-20", timeZoneID: "America/Los_Angeles"),
                                                  readiness: .yes, updatedAt: date(20))
        XCTAssertEqual(advice(try rebuilt(source, recovery: [wrongZone])).action, .pending)
        XCTAssertTrue(ProgressionEngine.isQualified(source, asOf: now))
    }

    func testOvernightWorkoutUsesCompletionDateInsteadOfStartDate() throws {
        let source = try exposure(day: 18)
        var overnight = source.session
        overnight.endedAt = date(19, hour: 1)
        overnight.lastAppliedAt = date(19, hour: 1)
        let sameCompletionDay = try SessionRecoveryRecord(sessionID: overnight.id, phase: .nextMorning,
                                                          day: .init(date: "2026-09-19", timeZoneID: "UTC"),
                                                          readiness: .yes, updatedAt: date(19))
        let record = try ProgressionExposure(session: overnight, exerciseID: source.exerciseID,
                                             configuration: source.configuration, answers: source.answers,
                                             recovery: [sameCompletionDay])
        XCTAssertEqual(record.completionDay.date, "2026-09-19")
        XCTAssertEqual(advice(record).action, .pending)
    }

    func testSameDayNewerFailedExposureInterruptsOlderQualification() throws {
        let prior = try exposure(day: 15), earlier = try exposure(day: 19, answers: .init(technique: .no))
        let original = try exposure(day: 19)
        var laterSession = original.session
        laterSession.endedAt = date(19, hour: 16); laterSession.lastAppliedAt = date(19, hour: 16)
        let later = try ProgressionExposure(session: laterSession, exerciseID: original.exerciseID,
                                            configuration: original.configuration, answers: original.answers, recovery: original.recovery)
        XCTAssertEqual(advice(later, [prior, earlier]).action, .repeatTarget)
    }

    func testExposureRoundTripValidatesFinishedSnapshots() throws {
        let source = try exposure(), data = try JSONEncoder().encode(source)
        XCTAssertEqual(try JSONDecoder().decode(ProgressionExposure.self, from: data), source)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["exerciseID"] = UUID().uuidString
        XCTAssertThrowsError(try JSONDecoder().decode(ProgressionExposure.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
