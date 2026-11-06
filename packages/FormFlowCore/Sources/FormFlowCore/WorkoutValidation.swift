import Foundation

public enum WorkoutValueValidator {
    /// Incomplete draft fields are allowed; supplied invalid or incompatible values never are.
    public static func validate(_ values: WorkoutSetValues, measurement: MeasurementKind,
                                requireComplete: Bool) -> [WorkoutIssue] {
        var issues: [WorkoutIssue] = []
        func issue(_ field: String, _ message: String) {
            issues.append(WorkoutIssue(code: "actual.\(field)", message: message))
        }
        if let reps = values.reps, !(0...1_000).contains(reps) {
            issue("reps", "Repetitions must be a whole number from 0 to 1000.")
        }
        for (field, quantity) in [("load", values.load), ("assistance", values.assistance)] {
            guard let quantity else { continue }
            if !quantity.value.isFinite || quantity.value < 0 || quantity.value > 10_000 {
                issue(field, "Load and assistance must be finite values from 0 to 10000.")
            }
            if ![PlanUnit.kg, .lb].contains(quantity.unit) { issue(field, "Use kg or lb for load and assistance.") }
        }
        if let duration = values.durationSeconds, !duration.isFinite || duration < 0 || duration > 1_000_000 {
            issue("durationSeconds", "Recorded time must be a finite value from 0 to 1000000 seconds.")
        }
        if let distance = values.distance {
            if !distance.value.isFinite || distance.value < 0 || distance.value > 1_000_000 {
                issue("distance", "Recorded distance must be a finite value from 0 to 1000000.")
            }
            if ![PlanUnit.m, .km, .mi].contains(distance.unit) { issue("distance", "Use m, km, or mi for distance.") }
        }
        if let calories = values.calories, !calories.isFinite || calories < 0 || calories > 1_000_000 {
            issue("calories", "Recorded calories must be a finite value from 0 to 1000000.")
        }
        if let rir = values.rir, !(0...10).contains(rir) { issue("rir", "Reps in reserve must be from 0 to 10, or left unanswered.") }
        if let rpe = values.rpe, !(0...10).contains(rpe) { issue("rpe", "Effort must be from 0 to 10, or left unanswered.") }
        if let rpm = values.averageRpm, !rpm.isFinite || rpm < 0 || rpm > 10_000 {
            issue("averageRpm", "Average RPM must be a finite value from 0 to 10000, or left unanswered.")
        }
        if let heartRate = values.averageHeartRate, !heartRate.isFinite || heartRate < 0 || heartRate > 1_000 {
            issue("averageHeartRate", "Average heart rate must be a finite value from 0 to 1000, or left unanswered.")
        }

        let allowed: Set<String>
        let required: Set<String>
        switch measurement {
        case .completion: allowed = []; required = []
        case .weightReps: allowed = ["reps", "load", "rir"]; required = ["reps", "load"]
        case .reps: allowed = ["reps", "rir"]; required = ["reps"]
        case .assistedReps: allowed = ["reps", "assistance", "rir"]; required = ["reps", "assistance"]
        case .weightDistance: allowed = ["load", "distance", "rir"]; required = ["load", "distance"]
        case .duration, .durationCalories:
            allowed = ["durationSeconds", "distance", "calories", "rpe", "averageRpm", "averageHeartRate"]; required = ["durationSeconds"]
        case .distanceTime:
            allowed = ["durationSeconds", "distance", "calories", "rpe", "averageRpm", "averageHeartRate"]; required = []
        case .distance:
            allowed = ["durationSeconds", "distance", "calories", "rpe", "averageRpm", "averageHeartRate"]; required = ["distance"]
        }
        let present: [(String, Bool)] = [("reps", values.reps != nil), ("load", values.load != nil),
            ("assistance", values.assistance != nil), ("durationSeconds", values.durationSeconds != nil),
            ("distance", values.distance != nil), ("calories", values.calories != nil),
            ("rir", values.rir != nil), ("rpe", values.rpe != nil),
            ("averageRpm", values.averageRpm != nil), ("averageHeartRate", values.averageHeartRate != nil)]
        for (field, exists) in present {
            if exists && !allowed.contains(field) { issue(field, "\(field) cannot be recorded for \(measurement.displayName.lowercased()).") }
            if requireComplete && required.contains(field) && !exists {
                issue(field, "Enter the actual \(field == "durationSeconds" ? "time in seconds" : field) before marking this set complete.")
            }
        }
        if requireComplete {
            if [.duration, .durationCalories].contains(measurement), let duration = values.durationSeconds, duration == 0 {
                issue("durationSeconds", "Record a positive duration before marking this activity complete.")
            }
            if [.distance, .weightDistance].contains(measurement), let distance = values.distance, distance.value == 0 {
                issue("distance", "Record a positive distance before marking this activity complete.")
            }
            if measurement == .distanceTime, (values.durationSeconds ?? 0) <= 0 && (values.distance?.value ?? 0) <= 0 {
                issue("distanceTime", "Record the actual time or distance before marking this activity complete. Unavailable readings may remain unanswered.")
            }
        }
        return issues
    }
}

/// Validates persisted/transferred values, not the identity or authorization of a sender.
/// The transport must still enforce its paired-device and generation policies.
public enum WorkoutSessionValidator {
    public static func validate(_ session: WorkoutSession) -> [WorkoutIssue] {
        var issues: [WorkoutIssue] = []
        func issue(_ code: String, _ message: String) { issues.append(WorkoutIssue(code: code, message: message)) }
        func finite(_ date: Date) -> Bool { date.timeIntervalSinceReferenceDate.isFinite }
        if session.planID.isEmpty || session.planRevisionID.isEmpty || session.ownerDeviceID.isEmpty || session.syncGeneration.isEmpty {
            issue("snapshot.context", "The workout needs a plan revision, recording owner, and synchronization generation.")
        }
        if TimeZone(identifier: session.timeZoneIdentifier) == nil { issue("snapshot.timeZone", "The workout timezone is invalid.") }
        if session.revision < 0 || session.revision == Int.max { issue("snapshot.revision", "The workout revision is outside the supported range.") }
        if !finite(session.startedAt) || !finite(session.lastAppliedAt) || session.lastAppliedAt < session.startedAt {
            issue("snapshot.time", "The workout contains invalid or inconsistent start/update times.")
        }
        if !session.accumulatedActiveTime.isFinite || session.accumulatedActiveTime < 0 {
            issue("snapshot.elapsed", "Active workout time must be finite and nonnegative.")
        }
        if let ended = session.endedAt, !finite(ended) || ended < session.startedAt || ended > session.lastAppliedAt {
            issue("snapshot.endTime", "The workout end time is inconsistent with its recorded timeline.")
        }
        if let segment = session.activeSegmentStartedAt, !finite(segment) || segment < session.startedAt || segment > session.lastAppliedAt {
            issue("snapshot.activeSegment", "The active time segment is invalid.")
        }
        switch session.state {
        case .active:
            if session.activeSegmentStartedAt == nil || session.endedAt != nil { issue("snapshot.lifecycle", "An active workout needs an active time segment and cannot have an end time.") }
        case .paused:
            if session.activeSegmentStartedAt != nil || session.endedAt != nil { issue("snapshot.lifecycle", "A paused workout cannot have an active time segment or an end time.") }
        case .finished, .abandoned:
            if session.activeSegmentStartedAt != nil || session.endedAt == nil || session.rest != nil {
                issue("snapshot.lifecycle", "An ended workout needs an end time and cannot retain active recording or rest.")
            }
        }
        let allSets = session.exercises.flatMap(\.sets)
        let allIntervals = allSets.flatMap { $0.intervals ?? [] }
        let IDs = [session.id] + session.exercises.map(\.id) + allSets.map(\.id) + allIntervals.map(\.id)
        if Set(IDs).count != IDs.count { issue("snapshot.duplicateIdentity", "Workout, exercise, and set identifiers must be unique.") }
        if session.exercises.isEmpty || session.exercises.count > 1_020 || session.exercises.filter(\.isAdditional).count > 20 ||
            session.exercises.filter({ !$0.isAdditional }).map(\.prescription) != session.prescription.exercises {
            issue("snapshot.prescription", "Recorded exercises must preserve the session's frozen prescription.")
        }
        if Set(session.exercises.map { $0.prescription.instanceId }).count != session.exercises.count {
            issue("snapshot.duplicateOccurrence", "The frozen prescription contains duplicate exercise occurrences.")
        }
        if allIntervals.count > 2_000 { issue("snapshot.intervalBudget", "A workout supports at most 2000 expanded interval steps.") }
        var completePrescription = session.prescription
        completePrescription.exercises = session.exercises.map(\.prescription)
        if PlanValidator.maximumExpandedIntervals(in: completePrescription) > 2_000 {
            issue("snapshot.intervalBudget", "The largest prescribed alternatives exceed the workout's interval budget.")
        }
        for exercise in session.exercises {
            let performed = exercise.performedPrescription
            if PlanValidator.validateExercise(exercise.prescription, legacy: !exercise.isAdditional).contains(where: { $0.severity == .error }) {
                issue("snapshot.exercisePrescription", "A frozen exercise prescription is invalid.")
            }
            if let alternative = exercise.selectedAlternativeID,
               exercise.prescription.alternatives?.contains(where: { $0.id == alternative }) != true {
                issue("snapshot.alternative", "The performed alternative must belong to the original frozen exercise.")
            }
            if exercise.isAdditional && (exercise.prescription.optional || exercise.prescription.progressionPolicy != nil) {
                issue("snapshot.extraExercise", "Additional exercises must be explicit manual work without an imported progression policy.")
            }
            if !exercise.prescription.optional && !exercise.isEnabled {
                issue("snapshot.requiredExercise", "A required exercise cannot be hidden as unselected optional work.")
            }
            if !exercise.isEnabled && exercise.completedSetCount > 0 {
                issue("snapshot.hiddenResults", "Recorded optional work must remain selected.")
            }
            if !(1...20).contains(performed.target.sets) || exercise.sets.count != performed.target.sets {
                issue("snapshot.setCount", "Set identities and count must match the frozen prescription.")
            }
            for set in exercise.sets {
                if set.target != performed.target || !(0...900).contains(set.target.restSeconds) {
                    issue("snapshot.target", "Each set must retain the exercise's prescribed target and valid rest duration.")
                }
                if set.revision < 0 || set.revision > session.revision {
                    issue("snapshot.setRevision", "A set revision is outside the session revision range.")
                }
                issues += WorkoutValueValidator.validate(set.actual, measurement: performed.measurement,
                    requireComplete: set.status == .completed)
                if let blocks = performed.intervals, PlanValidator.expandedIntervalCount(blocks) <= 400 {
                    let expected = blocks.flatMap { block in
                        (1...block.repeatCount).flatMap { repetition in block.steps.map { (block.id, repetition, $0) } }
                    }
                    if let intervals = set.intervals, intervals.count == expected.count {
                        for (index, interval) in intervals.enumerated() {
                            let planned = expected[index]
                            if interval.blockID != planned.0 || interval.repetition != planned.1 || interval.prescription != planned.2 {
                                issue("snapshot.intervalPrescription", "Each interval must retain its ordered frozen step and repetition.")
                            }
                            issues += WorkoutValueValidator.validate(interval.actual, measurement: interval.prescription.measurement,
                                requireComplete: interval.status == .completed)
                            if interval.revision < 0 || interval.revision > session.revision {
                                issue("snapshot.intervalRevision", "An interval revision is outside the session revision range.")
                            }
                            if interval.status == .completed {
                                if let completed = interval.completedAt {
                                    if !finite(completed) || completed < session.startedAt || completed > session.lastAppliedAt ||
                                        (session.endedAt.map { completed > $0 } ?? false) ||
                                        (set.completedAt.map { completed > $0 } ?? false) {
                                        issue("snapshot.intervalTime", "An interval completion must fit its session and outer set timeline.")
                                    }
                                } else { issue("snapshot.intervalTime", "A completed interval needs its actual completion time.") }
                            } else if interval.completedAt != nil { issue("snapshot.intervalState", "An incomplete interval cannot claim a completion time.") }
                            if interval.status != .skipped && interval.skipReason != nil || (interval.skipReason?.count ?? 0) > 500 {
                                issue("snapshot.intervalReason", "Only skipped intervals can have a reason, up to 500 characters.")
                            }
                            if session.state == .finished && interval.status == .planned ||
                                !session.state.isTerminal && interval.status == .unperformed ||
                                set.status == .completed && [.planned, .unperformed].contains(interval.status) {
                                issue("snapshot.intervalState", "Interval completion, unperformed work and parent set status must agree.")
                            }
                        }
                    } else { issue("snapshot.intervalCount", "The interval list must match the frozen block expansion.") }
                } else if set.intervals != nil {
                    issue("snapshot.unexpectedIntervals", "Interval results require a valid frozen interval prescription.")
                }
                if set.status == .completed {
                    if let completed = set.completedAt {
                        if !finite(completed) || completed < session.startedAt || completed > session.lastAppliedAt ||
                            (session.endedAt.map { completed > $0 } ?? false) {
                            issue("snapshot.completionTime", "A completed set has an inconsistent completion time.")
                        }
                    } else { issue("snapshot.completionTime", "A completed set needs its completion time.") }
                    if set.skipReason != nil { issue("snapshot.setState", "A completed set cannot retain a skip reason.") }
                } else if set.completedAt != nil { issue("snapshot.setState", "An incomplete set cannot claim a completion time.") }
                if set.status != .skipped && set.skipReason != nil { issue("snapshot.skipReason", "Only skipped sets can retain a skip reason.") }
                if (set.skipReason?.count ?? 0) > 500 { issue("snapshot.skipReason", "Skip reasons must be at most 500 characters.") }
                if session.state == .finished && set.status == .planned { issue("snapshot.unfinishedSet", "Finished workouts must distinguish unperformed work from planned work.") }
                if !session.state.isTerminal && set.status == .unperformed { issue("snapshot.prematureFinish", "Unperformed is assigned when a workout ends.") }
            }
        }
        if let rest = session.rest {
            if !finite(rest.startedAt) || !finite(rest.deadline) || rest.startedAt < session.startedAt || rest.deadline < rest.startedAt ||
                !allSets.contains(where: { $0.id == rest.setID && $0.status == .completed }) {
                issue("snapshot.rest", "The rest interval must reference a completed set and have a valid deadline.")
            }
        }
        let operations = session.operationReceipts.map(\.operation) + session.pendingOperations
        if Set(operations.map(\.id)).count != operations.count { issue("snapshot.operationIDs", "An operation can appear only once in pending or processed records.") }
        if session.pendingOperations.count > WorkoutReducer.maximumPendingOperations { issue("snapshot.pendingLimit", "Too many operations are pending.") }
        for operation in operations {
            if operation.schemaVersion != WorkoutOperation.currentSchemaVersion {
                issue("snapshot.operationVersion", "Update Form / Flow before reading these workout changes.")
            }
            if operation.sessionID != session.id || operation.syncGeneration != session.syncGeneration ||
                operation.originDeviceID.isEmpty || operation.expectedRevision < 0 || !finite(operation.createdAt) {
                issue("snapshot.operation", "An operation has inconsistent session, generation, revision, or device information.")
            }
        }
        for operation in session.pendingOperations where operation.expectedRevision <= session.revision {
            issue("snapshot.pendingRevision", "Pending operations must be waiting for a later revision.")
        }
        for receipt in session.operationReceipts {
            if ![WorkoutReductionStatus.applied, .conflict, .rejected].contains(receipt.status) ||
                receipt.resultingRevision < 0 || receipt.resultingRevision > session.revision || !finite(receipt.processedAt) {
                issue("snapshot.receipt", "An operation receipt is inconsistent with the recorded session.")
            }
            if receipt.status == .applied && (receipt.operation.expectedRevision == Int.max || receipt.resultingRevision != receipt.operation.expectedRevision + 1) {
                issue("snapshot.appliedRevision", "An accepted operation must advance its expected revision exactly once.")
            }
        }
        let acceptedRevisions = session.operationReceipts.filter { $0.status == .applied }.map(\.resultingRevision)
        if Set(acceptedRevisions).count != acceptedRevisions.count { issue("snapshot.reusedRevision", "Different accepted operations cannot claim the same revision.") }
        if Set(session.conflicts.map(\.id)).count != session.conflicts.count { issue("snapshot.conflictIDs", "The same conflict cannot be stored more than once.") }
        for conflict in session.conflicts {
            if conflict.currentRevision > session.revision || conflict.currentRevision <= conflict.operation.expectedRevision ||
                !session.operationReceipts.contains(where: { $0.operation == conflict.operation && $0.status == .conflict }) {
                issue("snapshot.conflict", "A conflict must reference a retained competing operation and accepted revision.")
            }
        }
        if (try? JSONEncoder().encode(session)) == nil { issue("snapshot.encoding", "The workout contains values that cannot be saved safely.") }
        return issues
    }
}

public enum WorkoutArchiveValidator {
    public static func validate(_ session: WorkoutSession) -> [WorkoutIssue] {
        WorkoutSessionValidator.validate(session)
    }
}
