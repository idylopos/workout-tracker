import Foundation

private extension WorkoutCommand {
    var isHistoricalCorrection: Bool {
        switch self { case .updateSet, .updateInterval: true; default: false }
    }
}

public enum WorkoutReducer {
    public static let maximumPendingOperations = 1_000

    /// Call on the recording owner. Persist the returned value before acknowledging an operation.
    /// Ordering comes from revisions, not either device's wall clock.
    public static func apply(_ operation: WorkoutOperation, to original: WorkoutSession, at date: Date) -> WorkoutReduction {
        func result(_ session: WorkoutSession, _ status: WorkoutReductionStatus,
                    _ issues: [WorkoutIssue] = [], applied: [UUID] = []) -> WorkoutReduction {
            WorkoutReduction(session: session, status: status, issues: issues, appliedOperationIDs: applied)
        }
        guard operation.schemaVersion == WorkoutOperation.currentSchemaVersion else {
            return result(original, .rejected, [issue("updateRequired", "Update Form / Flow on both devices before applying this workout change.")])
        }
        guard operation.sessionID == original.id else {
            return result(original, .rejected, [issue("wrongSession", "This change belongs to another workout.")])
        }
        guard original.revision >= 0 && original.revision < Int.max else {
            return result(original, .rejected, [issue("invalidSessionRevision", "The stored workout revision is invalid. Restore or reconcile this record before editing.")])
        }
        guard operation.syncGeneration == original.syncGeneration else {
            return result(original, .rejected, [issue("wrongGeneration", "This change predates the current synchronized store and cannot restore erased data.")])
        }
        switch operation.command {
        case .chooseAlternative, .addExtraExercise:
            guard operation.originDeviceID == original.ownerDeviceID else {
                return result(original, .rejected, [issue("ownerOnly", "Only the recording device can select a variant or add an exercise.")])
            }
        default: break
        }
        guard operation.expectedRevision >= 0, !operation.originDeviceID.isEmpty,
              operation.originDeviceID.count <= 200, date.timeIntervalSinceReferenceDate.isFinite,
              operation.createdAt.timeIntervalSinceReferenceDate.isFinite else {
            return result(original, .rejected, [issue("invalidOperation", "The change has invalid revision, device, or timing information.")])
        }
        guard let encoded = try? JSONEncoder().encode(operation), encoded.count <= 1_048_576 else {
            return result(original, .rejected, [issue("unpersistableOperation", "This change contains invalid numerical data or exceeds the supported operation size. It has not been queued or applied.")])
        }
        let known = original.operationReceipts.first(where: { $0.id == operation.id })?.operation
            ?? original.pendingOperations.first(where: { $0.id == operation.id })
        if let known {
            guard known == operation else {
                return result(original, .rejected, [issue("operationIDReused", "An operation ID was reused for different data. Keep the accepted result and submit the correction with a new ID.")])
            }
            return result(original, .duplicate)
        }
        var session = original
        if operation.expectedRevision > session.revision {
            guard session.pendingOperations.count < maximumPendingOperations,
                  operation.expectedRevision - session.revision <= 10_000 else {
                return result(original, .rejected, [issue("pendingLimit", "Too many changes are awaiting earlier revisions. Reconcile the current workout before retrying.")])
            }
            session.pendingOperations.append(operation)
            return result(session, .buffered, [issue("waitingForRevision", "Saved as a pending change. Earlier workout changes must arrive before it can be confirmed.")])
        }

        var appliedIDs: [UUID] = []
        let initial = process(operation, session: &session, at: date, appliedIDs: &appliedIDs)
        // Each pass removes at least one pending operation. Competing edits at one revision
        // become explicit conflicts after the first accepted edit advances the revision.
        while let index = session.pendingOperations.firstIndex(where: { $0.expectedRevision <= session.revision }) {
            let pending = session.pendingOperations.remove(at: index)
            _ = process(pending, session: &session, at: date, appliedIDs: &appliedIDs)
        }
        return result(session, initial.status, initial.issues, applied: appliedIDs)
    }

    private static func process(_ operation: WorkoutOperation, session: inout WorkoutSession, at date: Date,
                                appliedIDs: inout [UUID]) -> (status: WorkoutReductionStatus, issues: [WorkoutIssue]) {
        if operation.expectedRevision < session.revision {
            let failure = issue("revisionConflict", "This change was based on revision \(operation.expectedRevision), but the workout is now at revision \(session.revision). Review both values before applying a correction.")
            session.conflicts.append(WorkoutConflict(operation: operation, currentRevision: session.revision,
                acceptedSets: affectedSets(operation.command, session: session), issue: failure))
            session.operationReceipts.append(WorkoutOperationReceipt(operation: operation, status: .conflict,
                resultingRevision: session.revision, processedAt: date, issues: [failure]))
            return (.conflict, [failure])
        }
        // Preserve owner event timestamps on replay. Companion commands take effect only when
        // the owner processes them. Clock changes never move the owner's effective time backward.
        let eventDate = operation.originDeviceID == session.ownerDeviceID
            ? max(session.lastAppliedAt, min(operation.createdAt, date)) : max(session.lastAppliedAt, date)
        do {
            var changed = try execute(operation.command, operationID: operation.id, on: session, at: eventDate)
            let sets = changed.exercises.flatMap(\.sets)
            let identities = [changed.id] + changed.exercises.map(\.id) + sets.map(\.id) + sets.flatMap { $0.intervals ?? [] }.map(\.id)
            guard Set(identities).count == identities.count else { throw failure("duplicateIdentity", "This change would reuse a saved workout identity. Submit it again with a new operation ID.") }
            changed.revision += 1
            changed.lastAppliedAt = eventDate
            changed.operationReceipts.append(WorkoutOperationReceipt(operation: operation, status: .applied,
                resultingRevision: changed.revision, processedAt: date, issues: []))
            session = changed
            appliedIDs.append(operation.id)
            return (.applied, [])
        } catch let failure as CommandFailure {
            session.operationReceipts.append(WorkoutOperationReceipt(operation: operation, status: .rejected,
                resultingRevision: session.revision, processedAt: date, issues: failure.issues))
            return (.rejected, failure.issues)
        } catch {
            let failure = issue("invalidCommand", "This workout change could not be applied.")
            session.operationReceipts.append(WorkoutOperationReceipt(operation: operation, status: .rejected,
                resultingRevision: session.revision, processedAt: date, issues: [failure]))
            return (.rejected, [failure])
        }
    }

    private static func execute(_ command: WorkoutCommand, operationID: UUID, on original: WorkoutSession, at date: Date) throws -> WorkoutSession {
        var session = original
        if original.state.isTerminal {
            if command.isHistoricalCorrection && original.state == .finished {
                // Later corrections retain lifecycle, finish time, and their operation audit.
            } else {
                throw failure("workoutEnded", "This workout has ended. Start another workout to record new work.")
            }
        }
        switch command {
        case .chooseAlternative(let exerciseID, let alternativeID):
            let index = try locateExercise(exerciseID, session: session)
            let originalExercise = session.exercises[index]
            guard originalExercise.sets.allSatisfy({ $0.status == .planned && $0.actual.isEmpty && $0.revision == 0 &&
                ($0.intervals?.allSatisfy { $0.status == .planned && $0.actual.isEmpty && $0.revision == 0 } ?? true) }) else {
                throw failure("variantHasResults", "Select an alternative before entering or recording any work for this exercise.")
            }
            guard alternativeID == nil || originalExercise.prescription.alternatives?.contains(where: { $0.id == alternativeID }) == true else {
                throw failure("missingAlternative", "This alternative is not part of the frozen prescription.")
            }
            session.exercises[index].selectedAlternativeID = alternativeID
            let performed = session.exercises[index].performedPrescription
            var ordinal = 0
            session.exercises[index].sets = WorkoutPreparation.sets(for: performed) {
                defer { ordinal += 1 }; return WorkoutPreparation.deterministicID(operationID: operationID, ordinal: ordinal)
            }

        case .addExtraExercise(let exercise):
            guard session.exercises.filter(\.isAdditional).count < 20,
                  !session.exercises.contains(where: { $0.prescription.instanceId == exercise.instanceId }),
                  !exercise.optional, exercise.progressionPolicy == nil,
                  !PlanValidator.validateExercise(exercise).contains(where: { $0.severity == .error }) else {
                throw failure("invalidExtraExercise", "Add at most 20 distinct valid manual exercises without imported progression policies.")
            }
            let existingIntervals = session.exercises.reduce(0) { $0 + max(PlanValidator.expandedIntervalCount($1.prescription.intervals), ($1.prescription.alternatives ?? []).map { PlanValidator.expandedIntervalCount($0.intervals) }.max() ?? 0) }
            let extraIntervals = max(PlanValidator.expandedIntervalCount(exercise.intervals), (exercise.alternatives ?? []).map { PlanValidator.expandedIntervalCount($0.intervals) }.max() ?? 0)
            guard existingIntervals + extraIntervals <= 2_000 else { throw failure("intervalBudget", "A workout supports at most 2000 expanded interval steps.") }
            var ordinal = 1
            let sets = WorkoutPreparation.sets(for: exercise) {
                defer { ordinal += 1 }; return WorkoutPreparation.deterministicID(operationID: operationID, ordinal: ordinal)
            }
            session.exercises.append(WorkoutExercise(id: WorkoutPreparation.deterministicID(operationID: operationID, ordinal: 0),
                prescription: exercise, sets: sets, isExtra: true))

        case .logInterval(let setID, let intervalID, let values), .updateInterval(let setID, let intervalID, let values):
            let location = try locate(setID, session: session)
            guard let intervalIndex = session.exercises[location.exercise].sets[location.set].intervals?.firstIndex(where: { $0.id == intervalID }),
                  var intervals = session.exercises[location.exercise].sets[location.set].intervals else {
                throw failure("missingInterval", "This interval does not belong to the selected set.")
            }
            let logging: Bool
            if case .logInterval = command { logging = true } else { logging = false }
            if logging {
                guard session.state == .active, session.exercises[location.exercise].isEnabled,
                      session.exercises[location.exercise].sets[location.set].status == .planned,
                      intervals[intervalIndex].status == .planned else {
                    throw failure("intervalAlreadyResolved", "Resume and select an unresolved interval before logging it.")
                }
            }
            try validate(values, measurement: intervals[intervalIndex].prescription.measurement,
                complete: logging || intervals[intervalIndex].status == .completed)
            intervals[intervalIndex].actual = values; intervals[intervalIndex].revision += 1
            if logging {
                intervals[intervalIndex].status = .completed; intervals[intervalIndex].completedAt = date; intervals[intervalIndex].skipReason = nil
                session.rest = nil
            }
            session.exercises[location.exercise].sets[location.set].intervals = intervals
            session.exercises[location.exercise].sets[location.set].revision += 1

        case .skipInterval(let setID, let intervalID, _), .undoInterval(let setID, let intervalID):
            let location = try locate(setID, session: session)
            guard var intervals = session.exercises[location.exercise].sets[location.set].intervals,
                  let index = intervals.firstIndex(where: { $0.id == intervalID }),
                  session.exercises[location.exercise].sets[location.set].status == .planned else {
                throw failure("missingInterval", "Undo the outer set before changing its interval status.")
            }
            if case .skipInterval(_, _, let reason) = command {
                guard intervals[index].status == .planned, (reason?.count ?? 0) <= 500 else { throw failure("intervalAlreadyResolved", "Only an unresolved interval can be skipped, with a reason of up to 500 characters.") }
                intervals[index].status = .skipped
                let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
                intervals[index].skipReason = trimmed?.isEmpty == false ? trimmed : nil
            } else {
                guard intervals[index].status == .completed || intervals[index].status == .skipped else { throw failure("nothingToUndo", "This interval has not been completed or skipped.") }
                intervals[index].status = .planned; intervals[index].skipReason = nil
            }
            intervals[index].completedAt = nil; intervals[index].revision += 1
            session.exercises[location.exercise].sets[location.set].intervals = intervals
            session.exercises[location.exercise].sets[location.set].revision += 1

        case .updateSet(let setID, let values):
            let location = try locate(setID, session: session)
            let exercise = session.exercises[location.exercise]
            let isComplete = exercise.sets[location.set].status == .completed
            try validate(values, measurement: exercise.performedPrescription.measurement, complete: isComplete)
            session.exercises[location.exercise].sets[location.set].actual = values
            session.exercises[location.exercise].sets[location.set].revision += 1

        case .logSet(let setID, let values):
            guard session.state == .active else { throw failure("workoutPaused", "Resume the workout before completing another set.") }
            let location = try locate(setID, session: session)
            let exercise = session.exercises[location.exercise]
            guard exercise.isEnabled else { throw failure("optionalNotSelected", "Select this optional exercise before logging it.") }
            guard exercise.sets[location.set].status == .planned else {
                throw failure("setAlreadyResolved", "This set is already completed or skipped. Edit its result or undo it first.")
            }
            guard exercise.sets[location.set].intervals?.contains(where: { $0.status == .planned }) != true else {
                throw failure("unresolvedIntervals", "Complete or skip each interval before logging the outer activity's actual totals.")
            }
            try validate(values, measurement: exercise.performedPrescription.measurement, complete: true)
            session.exercises[location.exercise].sets[location.set].actual = values
            session.exercises[location.exercise].sets[location.set].status = .completed
            session.exercises[location.exercise].sets[location.set].completedAt = date
            session.exercises[location.exercise].sets[location.set].skipReason = nil
            session.exercises[location.exercise].sets[location.set].revision += 1
            let rest = exercise.sets[location.set].target.restSeconds
            session.rest = rest > 0 ? WorkoutRest(setID: setID, startedAt: date, deadline: date.addingTimeInterval(Double(rest))) : nil

        case .undoSet(let setID):
            let location = try locate(setID, session: session)
            let status = session.exercises[location.exercise].sets[location.set].status
            guard status == .completed || status == .skipped else { throw failure("nothingToUndo", "This set has not been completed or skipped.") }
            session.exercises[location.exercise].sets[location.set].status = .planned
            session.exercises[location.exercise].sets[location.set].completedAt = nil
            session.exercises[location.exercise].sets[location.set].skipReason = nil
            session.exercises[location.exercise].sets[location.set].revision += 1
            if session.rest?.setID == setID { session.rest = nil }

        case .skipSet(let setID, let reason):
            let location = try locate(setID, session: session)
            guard session.exercises[location.exercise].sets[location.set].status == .planned else {
                throw failure("setAlreadyResolved", "Undo this set before changing it to skipped.")
            }
            guard (reason?.count ?? 0) <= 500 else { throw failure("skipReasonTooLong", "Keep the skip reason to 500 characters or fewer.") }
            let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            session.exercises[location.exercise].sets[location.set].status = .skipped
            session.exercises[location.exercise].sets[location.set].skipReason = trimmed?.isEmpty == false ? trimmed : nil
            session.exercises[location.exercise].sets[location.set].revision += 1

        case .copyLast(let exerciseID, let previous):
            let index = try locateExercise(exerciseID, session: session)
            let current = session.exercises[index]
            guard current.performedPrescription.exerciseId == previous.performedPrescription.exerciseId,
                  current.performedPrescription.measurement == previous.performedPrescription.measurement,
                  current.performedPrescription.equipment.sorted() == previous.performedPrescription.equipment.sorted(),
                  current.selectedAlternativeID == previous.selectedAlternativeID else {
                throw failure("incomparableHistory", "Choose previous values from the same exercise and measurement type.")
            }
            let measurement = current.performedPrescription.measurement
            let values = previous.sets.last(where: { $0.actual.reusableValues(for: measurement).hasPrimaryValues })?
                .actual.reusableValues(for: measurement) ?? WorkoutSetValues()
            try validate(values, measurement: current.performedPrescription.measurement, complete: false)
            for setIndex in session.exercises[index].sets.indices {
                session.exercises[index].sets[setIndex].actual = values
                session.exercises[index].sets[setIndex].status = .planned
                session.exercises[index].sets[setIndex].completedAt = nil
                session.exercises[index].sets[setIndex].skipReason = nil
                session.exercises[index].sets[setIndex].revision += 1
                if var intervals = session.exercises[index].sets[setIndex].intervals {
                    for i in intervals.indices {
                        intervals[i].actual = .init(); intervals[i].status = .planned; intervals[i].completedAt = nil
                        intervals[i].skipReason = nil; intervals[i].revision += 1
                    }
                    session.exercises[index].sets[setIndex].intervals = intervals
                }
            }
            if let rest = session.rest, current.sets.contains(where: { $0.id == rest.setID }) { session.rest = nil }

        case .fillEmptySets(let exerciseID):
            let index = try locateExercise(exerciseID, session: session)
            guard let first = session.exercises[index].sets.first else { throw failure("missingSet", "This exercise has no sets.") }
            let source = first.actual.reusableValues(for: session.exercises[index].performedPrescription.measurement)
            guard source.hasPrimaryValues else { throw failure("missingFirstSetValues", "Enter the first set's actual values before filling empty fields.") }
            for setIndex in session.exercises[index].sets.indices.dropFirst() {
                let originalSet = session.exercises[index].sets[setIndex]
                let values = fillingMissing(originalSet.actual, from: source)
                try validate(values, measurement: session.exercises[index].performedPrescription.measurement, complete: originalSet.status == .completed)
                if values != originalSet.actual {
                    session.exercises[index].sets[setIndex].actual = values
                    session.exercises[index].sets[setIndex].revision += 1
                }
            }

        case .setExerciseEnabled(let exerciseID, let enabled):
            let index = try locateExercise(exerciseID, session: session)
            guard session.exercises[index].prescription.optional else { throw failure("requiredExercise", "Required exercises can be skipped, but cannot be turned off as optional work.") }
            guard enabled || session.exercises[index].completedSetCount == 0 else {
                throw failure("exerciseHasResults", "Keep recorded optional work selected, or explicitly undo its sets first.")
            }
            session.exercises[index].isEnabled = enabled

        case .pause:
            guard session.state == .active else { throw failure("alreadyPaused", "This workout is already paused.") }
            stopActiveSegment(&session, at: date)
            session.state = .paused

        case .resume:
            guard session.state == .paused else { throw failure("alreadyActive", "This workout is already active.") }
            session.state = .active
            session.activeSegmentStartedAt = date

        case .finish(let allowPartial):
            guard allowPartial || !session.hasIncompleteWork else {
                throw failure("partialFinishConfirmation", "Some planned work is incomplete. Confirm that you want to finish with the recorded work.")
            }
            stopActiveSegment(&session, at: date)
            session.state = .finished
            session.endedAt = date
            session.rest = nil
            for exerciseIndex in session.exercises.indices {
                let skipSwing = session.replacesSwing(session.exercises[exerciseIndex])
                for setIndex in session.exercises[exerciseIndex].sets.indices {
                    if var intervals = session.exercises[exerciseIndex].sets[setIndex].intervals {
                        for i in intervals.indices where intervals[i].status == .planned { intervals[i].status = .unperformed; intervals[i].revision += 1 }
                        session.exercises[exerciseIndex].sets[setIndex].intervals = intervals
                    }
                }
                for setIndex in session.exercises[exerciseIndex].sets.indices
                    where session.exercises[exerciseIndex].sets[setIndex].status == .planned {
                    if skipSwing && session.exercises[exerciseIndex].sets[setIndex].actual.isEmpty {
                        session.exercises[exerciseIndex].sets[setIndex].status = .skipped
                        session.exercises[exerciseIndex].sets[setIndex].skipReason = WorkoutSession.legCurlSkipReason
                    } else {
                        session.exercises[exerciseIndex].sets[setIndex].status = .unperformed
                    }
                    session.exercises[exerciseIndex].sets[setIndex].revision += 1
                }
            }

        case .abandon:
            stopActiveSegment(&session, at: date)
            session.state = .abandoned
            session.endedAt = date
            session.rest = nil

        case .skipRest:
            guard session.rest != nil else { throw failure("noRest", "There is no rest interval to skip.") }
            session.rest = nil

        case .extendRest(let seconds):
            guard (1...900).contains(seconds) else { throw failure("restExtensionRange", "Extend rest by 1–900 seconds.") }
            guard var rest = session.rest else { throw failure("noRest", "There is no rest interval to extend.") }
            rest.deadline = max(rest.deadline, date).addingTimeInterval(Double(seconds))
            session.rest = rest
        }
        return session
    }

    private static func fillingMissing(_ destination: WorkoutSetValues, from source: WorkoutSetValues) -> WorkoutSetValues {
        var values = destination
        values.reps = values.reps ?? source.reps
        values.load = values.load ?? source.load
        values.assistance = values.assistance ?? source.assistance
        values.durationSeconds = values.durationSeconds ?? source.durationSeconds
        values.distance = values.distance ?? source.distance
        values.calories = values.calories ?? source.calories
        return values
    }

    private static func stopActiveSegment(_ session: inout WorkoutSession, at date: Date) {
        if let start = session.activeSegmentStartedAt {
            session.accumulatedActiveTime += max(0, date.timeIntervalSince(start))
            session.activeSegmentStartedAt = nil
        }
    }

    private static func locate(_ id: UUID, session: WorkoutSession) throws -> (exercise: Int, set: Int) {
        for exerciseIndex in session.exercises.indices {
            if let setIndex = session.exercises[exerciseIndex].sets.firstIndex(where: { $0.id == id }) {
                let exercise = session.exercises[exerciseIndex]
                if session.replacesSwing(exercise), WorkoutSession.omitsSwingSet(exercise.sets[setIndex]) {
                    throw failure("swingSkipped", WorkoutSession.legCurlSkipReason)
                }
                return (exerciseIndex, setIndex)
            }
        }
        throw failure("missingSet", "The requested set does not belong to this workout.")
    }

    private static func locateExercise(_ id: UUID, session: WorkoutSession) throws -> Int {
        guard let index = session.exercises.firstIndex(where: { $0.id == id }) else {
            throw failure("missingExercise", "The requested exercise does not belong to this workout.")
        }
        if session.replacesSwing(session.exercises[index]) {
            throw failure("swingSkipped", WorkoutSession.legCurlSkipReason)
        }
        return index
    }

    private static func validate(_ values: WorkoutSetValues, measurement: MeasurementKind, complete: Bool) throws {
        let issues = WorkoutValueValidator.validate(values, measurement: measurement, requireComplete: complete)
        if !issues.isEmpty { throw CommandFailure(issues: issues) }
    }

    private static func affectedSets(_ command: WorkoutCommand, session: WorkoutSession) -> [WorkoutSet] {
        switch command {
        case .updateSet(let id, _), .logSet(let id, _), .undoSet(let id), .skipSet(let id, _):
            return session.exercises.flatMap(\.sets).filter { $0.id == id }
        case .copyLast(let id, _), .fillEmptySets(let id), .setExerciseEnabled(let id, _):
            return session.exercises.first(where: { $0.id == id })?.sets ?? []
        default: return session.exercises.flatMap(\.sets)
        }
    }

    private struct CommandFailure: Error { let issues: [WorkoutIssue] }
    private static func issue(_ code: String, _ message: String) -> WorkoutIssue { WorkoutIssue(code: code, message: message) }
    private static func failure(_ code: String, _ message: String) -> CommandFailure { CommandFailure(issues: [issue(code, message)]) }
}
