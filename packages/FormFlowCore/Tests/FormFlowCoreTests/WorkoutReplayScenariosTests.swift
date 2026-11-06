import XCTest
@testable import FormFlowCore

final class WorkoutReplayScenariosTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testNinetyMinuteMixedLogEditRestPauseFinishReplaysInReorderedBatches() throws {
        let initial = try workout()
        var commands: [WorkoutCommand] = []
        for set in initial.exercises[0].sets {
            let values = WorkoutSetValues(reps: 8, load: .init(value: 20, unit: .kg))
            commands += [.updateSet(setID: set.id, values: values), .logSet(setID: set.id, values: values),
                         .extendRest(seconds: 30), .pause, .resume, .skipRest]
        }
        commands.append(.finish(allowPartial: false))
        let operations = commands.enumerated().map { index, command in
            WorkoutOperation(sessionID: initial.id, originDeviceID: initial.ownerDeviceID, syncGeneration: initial.syncGeneration,
                expectedRevision: index, command: command, createdAt: start.addingTimeInterval(Double(index) * 45))
        }
        XCTAssertEqual(operations.count, 121)
        let deliveryDate = start.addingTimeInterval(10_000)
        var ordered = initial
        for operation in operations {
            let result = WorkoutReducer.apply(operation, to: ordered, at: deliveryDate)
            XCTAssertEqual(result.status, .applied, "\(operation.command): \(result.issues)")
            ordered = result.session
        }
        XCTAssertEqual(ordered.endedAt, start.addingTimeInterval(90 * 60))
        XCTAssertEqual(ordered.elapsed(at: deliveryDate), 75 * 60) // Twenty 45-second pauses.
        XCTAssertEqual(ordered.completedSetCount, 20)
        XCTAssertNil(ordered.rest)
        for order in [Array(operations.reversed()), shuffled(operations, seed: 42), reorderedBatches(operations)] {
            var replayed = initial
            for (index, operation) in order.enumerated() {
                replayed = WorkoutReducer.apply(operation, to: replayed, at: deliveryDate).session
                let duplicate = WorkoutReducer.apply(operation, to: replayed, at: deliveryDate.addingTimeInterval(600))
                XCTAssertEqual(duplicate.status, .duplicate)
                XCTAssertEqual(duplicate.session, replayed, "Duplicate must not move a rest deadline or session timing")
                if index % 11 == 0 { replayed = try roundTrip(replayed) }
            }
            XCTAssertEqual(replayed, ordered)
            XCTAssertTrue(replayed.pendingOperations.isEmpty)
            XCTAssertTrue(WorkoutSessionValidator.validate(replayed).isEmpty)
        }
    }

    func testOneHundredOfflineConflictingProposalsRetainBothValuesAndExactReceipts() throws {
        let initial = try workout()
        let setID = initial.exercises[0].sets[0].id
        let accepted = WorkoutSetValues(reps: 8, load: .init(value: 20, unit: .kg))
        let owner = WorkoutOperation(session: initial, command: .updateSet(setID: setID, values: accepted), at: start)
        var session = WorkoutReducer.apply(owner, to: initial, at: start).session
        let proposals = (0..<100).map { index in
            WorkoutOperation(session: initial, command: .updateSet(setID: setID,
                values: .init(reps: index + 1, load: .init(value: 25, unit: .kg))), originDeviceID: "phone", at: start.addingTimeInterval(Double(index)))
        }
        for (index, operation) in shuffled(proposals, seed: 9).enumerated() {
            let received = try WorkoutTransportCodec.decode(WorkoutOperation.self,
                from: WorkoutTransportCodec.encode(operation, kind: .workoutProposal), kind: .workoutProposal)
            let result = WorkoutReducer.apply(received, to: session, at: start.addingTimeInterval(600))
            XCTAssertEqual(result.status, .conflict)
            session = result.session
            XCTAssertEqual(session.conflicts.last?.acceptedSets.first?.actual, accepted)
            XCTAssertEqual(session.conflicts.last?.operation, operation)
            let reply = WorkoutProposalResult(operation: operation, status: result.status, workout: session, issues: result.issues)
            XCTAssertTrue(RemoteWorkoutResultValidator.validate(reply).isEmpty)
            let duplicate = WorkoutReducer.apply(operation, to: session, at: start.addingTimeInterval(1_000))
            XCTAssertEqual(duplicate.session, session)
            if index % 10 == 0 { session = try roundTrip(session) }
        }
        XCTAssertEqual(session.revision, 1)
        XCTAssertEqual(session.conflicts.count, 100)
        XCTAssertEqual(Set(session.conflicts.map(\.operation.id)), Set(proposals.map(\.id)))
        XCTAssertEqual(session.exercises[0].sets[0].actual, accepted)
        XCTAssertTrue(WorkoutSessionValidator.validate(session).isEmpty)
    }

    func testOneHundredDuplicateStartIntentsAndLostRepliesResolveOneOwnerWorkout() throws {
        let plan = try XCTUnwrap(PlanImporter.importText(PlanContract.exampleJSON).plan)
        let prescription = try XCTUnwrap(plan.days.flatMap(\.sessions).first)
        let intents = (0..<100).map { _ in
            RemoteWorkoutStartIntent(syncGeneration: "generation", planID: plan.id, planRevisionID: "revision",
                prescriptionID: prescription.id, scheduledSessionID: "scheduled-occurrence",
                scheduledDay: .init(instant: start, timeZone: .gmt), requestedAt: start)
        }
        var stored: [WorkoutSession] = []
        var receipts: [UUID: RemoteWorkoutStartResult] = [:]
        for intent in shuffled(intents, seed: 32) {
            let received = try WorkoutTransportCodec.decode(RemoteWorkoutStartIntent.self,
                from: WorkoutTransportCodec.encode(intent, kind: .remoteStart), kind: .remoteStart)
            let result = resolve(received, plan: plan, workouts: stored, now: start)
            XCTAssertTrue([RemoteWorkoutStartStatus.started, .existing].contains(result.status))
            let record = try XCTUnwrap(result.workout)
            if !stored.contains(where: { $0.id == record.id }) { stored.append(record) }
            receipts[intent.id] = try roundTrip(result)
        }
        XCTAssertEqual(stored.count, 1)
        for intent in shuffled(intents, seed: 128) {
            let replay = resolve(intent, previous: receipts[intent.id], allowStart: false, plan: plan, workouts: stored,
                now: start.addingTimeInterval(90 * 60))
            XCTAssertEqual(replay, receipts[intent.id])
            XCTAssertEqual(replay.workout?.id, stored[0].id)
        }
    }

    func testOneHundredRetiredGenerationOperationsAndStartsCannotRepopulateResetWorkspace() throws {
        let old = try workout()
        let current = try WorkoutSession.start(prescription: old.prescription, planID: old.planID,
            planRevisionID: old.planRevisionID, ownerDeviceID: old.ownerDeviceID, at: start,
            timeZoneIdentifier: "UTC", id: old.id, syncGeneration: "replacement-generation")
        let plan = WeeklyPlan(id: old.planID, name: "Plan", days: [.init(weekday: .monday, sessions: [old.prescription])])
        let commands: [WorkoutCommand] = [.pause, .resume, .finish(allowPartial: true), .abandon, .skipRest]
        let operations = (0..<100).map { index in
            WorkoutOperation(sessionID: old.id, originDeviceID: old.ownerDeviceID, syncGeneration: old.syncGeneration,
                expectedRevision: index, command: commands[index % commands.count], createdAt: start.addingTimeInterval(Double(index)))
        }
        for operation in shuffled(operations, seed: 7) {
            let restored = try roundTrip(operation)
            for _ in 0..<2 {
                let reduction = WorkoutReducer.apply(restored, to: current, at: start.addingTimeInterval(600))
                XCTAssertEqual(reduction.status, .rejected)
                XCTAssertEqual(reduction.issues.first?.code, "wrongGeneration")
                XCTAssertEqual(reduction.session, current)
            }
            let intent = RemoteWorkoutStartIntent(syncGeneration: old.syncGeneration, planID: old.planID,
                planRevisionID: old.planRevisionID, prescriptionID: old.prescription.id, requestedAt: start)
            let result = resolve(intent, plan: plan, workouts: [], generation: current.syncGeneration, now: start)
            XCTAssertEqual(result.status, .rejected); XCTAssertNil(result.workout)
        }
    }

    private func workout() throws -> WorkoutSession {
        let exercise = PlanExercise(instanceId: "squat", exerciseId: "squat", name: "Squat", measurement: .weightReps,
            target: .init(sets: 20, restSeconds: 90, reps: .init(min: 8, max: 10), load: .init(value: 20, unit: .kg)))
        return try WorkoutSession.start(prescription: .init(id: "session", name: "Strength", kind: "strength", estimatedMinutes: 90, exercises: [exercise]),
            planID: "plan", planRevisionID: "revision", ownerDeviceID: "watch", at: start, timeZoneIdentifier: "UTC", syncGeneration: "generation")
    }
    private func roundTrip<T: Codable>(_ value: T) throws -> T { try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value)) }
    private func shuffled<T>(_ values: [T], seed: UInt64) -> [T] {
        var copy = values, state = seed
        for index in stride(from: copy.count - 1, through: 1, by: -1) {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            copy.swapAt(index, Int(state % UInt64(index + 1)))
        }
        return copy
    }
    private func reorderedBatches<T>(_ values: [T]) -> [T] {
        stride(from: 0, to: values.count, by: 11).reversed().flatMap { Array(values[$0..<min($0 + 11, values.count)]) }
    }
    private func resolve(_ intent: RemoteWorkoutStartIntent, previous: RemoteWorkoutStartResult? = nil, allowStart: Bool = true,
                         plan: WeeklyPlan, workouts: [WorkoutSession], generation: String = "generation", now: Date) -> RemoteWorkoutStartResult {
        RemoteWorkoutStartResolver.resolve(intent, previous: previous, allowStart: allowStart, plan: plan,
            planRevisionID: "revision", syncGeneration: generation, ownerDeviceID: "watch", workouts: workouts,
            now: now, timeZoneIdentifier: "UTC")
    }
}
