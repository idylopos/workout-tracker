import XCTest
@testable import FormFlowCore

final class BuiltInPlanTests: XCTestCase {
    private func exercises(_ plan: WeeklyPlan, day: Weekday) -> [PlanExercise] {
        plan.days.first { $0.weekday == day }!.sessions.flatMap(\.exercises)
    }
    private func exercise(_ plan: WeeklyPlan, day: Weekday, id: String) -> PlanExercise {
        exercises(plan, day: day).first { $0.exerciseId == id }!
    }
    func testEverySourceExerciseRemainsOnItsWeekdayAndRestDayIsEmpty() throws {
        let expected: [Weekday: [String]] = [
            .monday: ["squat-jump", "box-squat", "bulgarian-split-squat", "assisted-nordic", "hip-abduction", "standing-calf-raise", "tibialis-raise", "copenhagen-plank", "bicycle-hiit"],
            .tuesday: ["half-kneeling-landmine-press", "neutral-db-bench", "cable-chest-fly", "cable-lateral-raise", "rope-pressdown", "cable-external-rotation", "kneeling-cable-crunch", "easy-run", "pelvic-floor"],
            .wednesday: ["pull-up-progression", "chest-supported-row", "face-pull", "hammer-curl", "pallof-press", "zone-2-cycle", "mobility-a-cat-cow", "mobility-a-frog", "mobility-a-lateral-lunge", "mobility-a-bridge-march", "mobility-a-seated-good-morning"],
            .thursday: ["kettlebell-swing", "trap-bar-deadlift", "barbell-hip-thrust", "controlled-step-down", "hip-abduction", "seated-calf-raise", "tibialis-raise", "run-2", "pelvic-floor"],
            .friday: ["neutral-incline-db-press", "one-arm-landmine-press", "cable-chest-fly", "cable-scaption", "cross-body-triceps", "cable-external-rotation", "suitcase-carry", "bird-dog", "mobility-b-chest", "mobility-b-shoulder", "mobility-b-adductor"],
            .saturday: ["long-run", "easy-swim", "pull-up-progression", "one-arm-cable-row", "db-pullover", "face-pull", "cable-curl", "pelvic-floor"],
            .sunday: []
        ]
        for block in 1...2 {
            let plan = try BuiltInPlans.plan(block: block)
            XCTAssertEqual(plan.days.map(\.weekday), Weekday.allCases)
            for day in Weekday.allCases { XCTAssertEqual(exercises(plan, day: day).map(\.exerciseId).sorted(), expected[day]!.sorted(), "\(day) block \(block)") }
            XCTAssertTrue(plan.days.last!.sessions.isEmpty)
            XCTAssertTrue(plan.days.flatMap(\.sessions).allSatisfy { $0.estimatedMinutes == 0 })
            XCTAssertEqual(Set(plan.days.flatMap(\.sessions).map(\.id)).count, plan.days.flatMap(\.sessions).count)
        }
    }
    func testBothBlocksAndAllEighteenStageSelectionsHaveValidNativeTargets() throws {
        for block in 1...2 {
            for stage in 1...18 {
                let plan = try BuiltInPlans.plan(block: block, longRunStage: stage)
                let errors = PlanValidator.validate(plan).filter { $0.severity == .error }
                XCTAssertTrue(errors.isEmpty, "Block \(block) stage \(stage): \(errors)")
                let run = exercise(plan, day: .saturday, id: "long-run")
                XCTAssertEqual(run.target.distance?.min, block == 1 ? BuiltInProgression.longRunStages[stage - 1].distanceKM : 8)
                XCTAssertEqual(run.target.distance?.max, block == 1 ? (stage == 18 ? 7 : BuiltInProgression.longRunStages[stage - 1].distanceKM) : 10)
                XCTAssertEqual(run.progressionPolicy, (block == 1 ? BuiltInProgressionPolicy.longRun : .easyRun).reference)
            }
        }
    }
    func testPullUpSelectionsMatchBothWeeklyOccurrencesWithoutInventedAssistance() throws {
        for step in 1...6 {
            let plan = try BuiltInPlans.plan(pullUpStep: step), source = BuiltInProgression.pullUpSteps[step - 1]
            for day in [Weekday.wednesday, .saturday] {
                let pullUp = exercise(plan, day: day, id: "pull-up-progression")
                XCTAssertEqual(pullUp.target.sets, source.sets)
                XCTAssertEqual(pullUp.target.reps, .init(min: source.minReps, max: source.maxReps))
                XCTAssertEqual(pullUp.measurement, source.measurement)
                XCTAssertEqual(pullUp.target.effort?.min, source.minimumRIR)
                XCTAssertNil(pullUp.target.assistance)
                XCTAssertTrue(ProgressionEngine.supports(configuration: .init(policy: BuiltInProgressionPolicy.pullUp.reference, pullUpStep: step), exercise: pullUp))
            }
        }
    }
    func testNoPrescribedLoadOrOptionalCompletionIsInvented() throws {
        for block in 1...2 {
            let plan = try BuiltInPlans.plan(block: block)
            for exercise in plan.days.flatMap(\.sessions).flatMap(\.exercises) {
                XCTAssertNil(exercise.target.load); XCTAssertNil(exercise.target.assistance)
                for alternative in exercise.alternatives ?? [] { XCTAssertNil(alternative.target.load); XCTAssertNil(alternative.target.assistance) }
            }
            for (day, id) in [(Weekday.wednesday, "zone-2-cycle"), (.saturday, "easy-swim"), (.saturday, "face-pull"), (.saturday, "cable-curl")] {
                XCTAssertTrue(exercise(plan, day: day, id: id).optional)
            }
            XCTAssertEqual(exercise(plan, day: .thursday, id: "kettlebell-swing").optional, block == 2)
        }
    }
    func testBlockTwoAdaptationsAndExplicitQualityChoiceMatchSource() throws {
        let blockOne = try BuiltInPlans.plan(), blockTwo = try BuiltInPlans.plan(block: 2)
        XCTAssertEqual(exercise(blockOne, day: .thursday, id: "barbell-hip-thrust").target.sets, 3)
        XCTAssertEqual(exercise(blockTwo, day: .thursday, id: "barbell-hip-thrust").target.sets, 2)
        for plan in [blockOne, blockTwo] {
            let sessions = plan.days.first { $0.weekday == .thursday }!.sessions
            XCTAssertEqual(sessions.map(\.id), ["thursday-run", "thursday-strength", "thursday-recovery"])
            XCTAssertTrue(sessions[1].warmup.contains { $0.contains("Trap-bar ramp") })
        }
        let quality = exercise(blockTwo, day: .thursday, id: "run-2")
        XCTAssertEqual(quality.measurement, .completion)
        XCTAssertNil(quality.progressionPolicy)
        XCTAssertEqual(quality.alternatives?.map(\.id), ["tempo", "intervals"])
        XCTAssertEqual(quality.alternatives?[0].intervals?[1].repeatCount, 3)
        XCTAssertEqual(quality.alternatives?[1].intervals?[1].repeatCount, 6)
        XCTAssertEqual(exercise(blockTwo, day: .tuesday, id: "easy-run").target.duration, .init(min: 30, max: 40, unit: .min))
        XCTAssertTrue(exercise(blockTwo, day: .tuesday, id: "easy-run").instructions!.contains("4 × 20-sec relaxed strides"))
    }
    func testExplicitIntervalsAlternativesGuidanceAndSeparationAreRetained() throws {
        let plan = try BuiltInPlans.plan()
        let hiit = exercise(plan, day: .monday, id: "bicycle-hiit")
        XCTAssertEqual(hiit.intervals?.count, 3)
        XCTAssertEqual(hiit.intervals?[1].repeatCount, 6)
        XCTAssertEqual(hiit.intervals?[1].steps.map(\.kind), [.work, .recovery])
        XCTAssertEqual(hiit.intervals?[1].steps[0].target.effort, .init(kind: .rpe, min: 8, max: 9))
        XCTAssertTrue(plan.days[0].sessions[1].instructions!.contains("at least 6 hours"))
        XCTAssertTrue(plan.days[5].sessions[0].instructions!.contains("at least 4 hours"))
        let nordic = exercise(plan, day: .monday, id: "assisted-nordic")
        XCTAssertEqual(nordic.alternatives?.map(\.id), ["seated-or-lying-leg-curl", "slider-or-ball-leg-curl", "bridge-hamstring-walkout"])
        XCTAssertTrue(nordic.instructions!.contains("not identical to Nordic eccentric exposure"))
        XCTAssertTrue(plan.instructions!.contains("weekly average sleep is at least 7 hours"))
        XCTAssertTrue(plan.instructions!.contains("missing entries do not establish recovery"))
        XCTAssertEqual(exercise(plan, day: .tuesday, id: "pelvic-floor").measurement, .completion)
        XCTAssertNil(exercise(plan, day: .tuesday, id: "pelvic-floor").target.duration)
    }
    func testThursdayLegCurlSkipsRemainingSwingsOnlyForThisWorkout() throws {
        for block in 1...2 {
            let plan = try BuiltInPlans.plan(block: block)
            let strength = try XCTUnwrap(plan.days.flatMap(\.sessions).first { $0.id == "thursday-strength" })
            let now = Date()
            var workout = try WorkoutSession.start(prescription: strength, planID: plan.id, planRevisionID: "v5",
                ownerDeviceID: "test", at: now, timeZoneIdentifier: "UTC")
            func apply(_ command: WorkoutCommand) {
                let reduction = WorkoutReducer.apply(.init(session: workout, command: command, at: now), to: workout, at: now)
                XCTAssertEqual(reduction.status, .applied)
                workout = reduction.session
            }
            let swing = try XCTUnwrap(workout.exercises.first { $0.prescription.exerciseId == "kettlebell-swing" })
            let trap = try XCTUnwrap(workout.exercises.first { $0.prescription.exerciseId == "trap-bar-deadlift" })
            let chooseCurl = WorkoutCommand.chooseAlternative(exerciseID: trap.id, alternativeID: "seated-leg-curl")
            let baseline = workout.plannedSetCount
            apply(chooseCurl)
            XCTAssertFalse(workout.recordingExercises.contains { $0.id == swing.id })
            XCTAssertFalse(workout.recordingWarmup.contains { $0.hasPrefix("Trap-bar ramp") || $0.hasPrefix("Light kettlebell") })
            XCTAssertEqual(workout.plannedSetCount, baseline - (swing.isEnabled ? swing.sets.count : 0) - 1)
            apply(.chooseAlternative(exerciseID: trap.id, alternativeID: nil))
            XCTAssertEqual(workout.recordingWarmup, strength.warmup)
            XCTAssertEqual(workout.plannedSetCount, baseline)
            if !swing.isEnabled { apply(.setExerciseEnabled(exerciseID: swing.id, enabled: true)) }
            apply(.logSet(setID: swing.sets[0].id, values: .init(reps: 8, load: .init(value: 12, unit: .kg))))
            apply(chooseCurl)
            XCTAssertEqual(workout.recordingExercises.first { $0.id == swing.id }?.sets.map(\.id), [swing.sets[0].id])
            apply(.finish(allowPartial: true))
            let saved = try XCTUnwrap(workout.exercises.first { $0.id == swing.id })
            XCTAssertEqual(saved.sets.first?.status, .completed)
            XCTAssertTrue(saved.sets.dropFirst().allSatisfy { $0.status == .skipped })
        }
    }
    func testOutOfRangeSelectionsThrowRatherThanClampToAnotherProgram() {
        XCTAssertThrowsError(try BuiltInPlans.plan(block: 0))
        XCTAssertThrowsError(try BuiltInPlans.plan(block: 3))
        XCTAssertThrowsError(try BuiltInPlans.plan(pullUpStep: 0))
        XCTAssertThrowsError(try BuiltInPlans.plan(pullUpStep: 7))
        XCTAssertThrowsError(try BuiltInPlans.plan(longRunStage: 0))
        XCTAssertThrowsError(try BuiltInPlans.plan(longRunStage: 19))
    }
}
