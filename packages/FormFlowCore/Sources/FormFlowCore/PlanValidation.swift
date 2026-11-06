import Foundation

public enum PlanValidator {
    public static func validateExercise(_ exercise: PlanExercise, legacy: Bool = false) -> [PlanIssue] {
        validate(WeeklyPlan(id: "validation", name: "Validation", days: [PlanDay(weekday: .monday,
            sessions: [PlanSession(id: "validation", name: "Validation", kind: "mixed", estimatedMinutes: 1,
                exercises: [exercise])])]), legacy: legacy)
    }

    /// Saturates at an invalid sentinel before multiplication/allocation can overflow.
    public static func expandedIntervalCount(_ blocks: [PlanIntervalBlock]?) -> Int {
        guard let blocks else { return 0 }
        guard blocks.count <= 40 else { return 2_001 }
        var total = 0
        for block in blocks {
            guard (1...100).contains(block.repeatCount), (1...40).contains(block.steps.count) else { return 2_001 }
            total += block.repeatCount * block.steps.count
            if total > 400 { return 2_001 }
        }
        return total
    }
    public static func maximumExpandedIntervals(in session: PlanSession) -> Int {
        var total = 0
        for exercise in session.exercises {
            let alternatives = (exercise.alternatives ?? []).map { expandedIntervalCount($0.intervals) }
            total += max(expandedIntervalCount(exercise.intervals), alternatives.max() ?? 0)
            if total > 2_000 { return 2_001 }
        }
        return total
    }
    public static func validate(_ plan: WeeklyPlan) -> [PlanIssue] {
        validate(plan, legacy: false)
    }

    public static func validate(_ plan: WeeklyPlan, legacy: Bool) -> [PlanIssue] {
        var issues: [PlanIssue] = []
        func error(_ path: String, _ message: String) { issues.append(PlanIssue(path: path, message: message)) }
        func text(_ value: String, _ path: String, max: Int = 500, empty: Bool = false) {
            if !empty && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                error(path, "Enter a non-empty value.")
            }
            if value.count > max { error(path, "Use at most \(max) characters.") }
        }
        func identifier(_ value: String, _ path: String) {
            if value.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) == nil {
                error(path, "Use 1–64 lowercase letters, numbers, or hyphens, starting with a letter or number.")
            }
        }
        if plan.schemaVersion != 2 { error("schemaVersion", "Only native plan version 2 can be validated here.") }
        identifier(plan.id, "id")
        text(plan.name, "name", max: 120)
        if plan.assumptions.count > 20 { error("assumptions", "Use at most 20 assumptions.") }
        for (index, value) in plan.assumptions.enumerated() { text(value, "assumptions[\(index)]") }
        if let value = plan.instructions { text(value, "instructions", max: legacy ? 50_000 : 3_000) }
        if plan.days.isEmpty || plan.days.count > 7 { error("days", "Include 1–7 distinct weekdays.") }
        var weekdays = Set<Weekday>()
        var sessionIDs = Set<String>()
        var hasExercise = false
        for (dayIndex, day) in plan.days.enumerated() {
            let dp = "days[\(dayIndex)]"
            if !weekdays.insert(day.weekday).inserted { error("\(dp).weekday", "This weekday already appears in the plan.") }
            if day.sessions.count > 3 { error("\(dp).sessions", "Use at most 3 sessions per day.") }
            for (sessionIndex, session) in day.sessions.enumerated() {
                let sp = "\(dp).sessions[\(sessionIndex)]"
                identifier(session.id, "\(sp).id")
                if !sessionIDs.insert(session.id).inserted { error("\(sp).id", "Session IDs must be unique across the week.") }
                text(session.name, "\(sp).name", max: 120)
                if !["strength", "cardio", "mobility", "mixed"].contains(session.kind) {
                    error("\(sp).kind", "Choose strength, cardio, mobility, or mixed.")
                }
                if !(0...1_440).contains(session.estimatedMinutes) {
                    error("\(sp).estimatedMinutes", "Use 0 when the duration is unknown, or an estimate from 1 to 1440 minutes.")
                }
                if session.warmup.count > 30 { error("\(sp).warmup", "Use at most 30 warm-up instructions.") }
                for (index, value) in session.warmup.enumerated() { text(value, "\(sp).warmup[\(index)]") }
                if let value = session.instructions { text(value, "\(sp).instructions", max: legacy ? 10_000 : 3_000) }
                if session.exercises.isEmpty { error("\(sp).exercises", "Add an exercise, or use an empty sessions list for a rest day.") }
                if !legacy && session.exercises.count > 30 { error("\(sp).exercises", "Use at most 30 exercise occurrences per session.") }
                if maximumExpandedIntervals(in: session) > 2_000 { error("\(sp).exercises", "Use at most 2000 expanded interval steps per session, including the largest alternative for each exercise.") }
                var occurrenceIDs = Set<String>()
                for (exerciseIndex, exercise) in session.exercises.enumerated() {
                    hasExercise = true
                    let ep = "\(sp).exercises[\(exerciseIndex)]"
                    identifier(exercise.instanceId, "\(ep).instanceId")
                    identifier(exercise.exerciseId, "\(ep).exerciseId")
                    if !occurrenceIDs.insert(exercise.instanceId).inserted {
                        error("\(ep).instanceId", "Exercise occurrence IDs must be unique within this session.")
                    }
                    text(exercise.name, "\(ep).name", max: 120)
                    if exercise.equipment.count > 20 { error("\(ep).equipment", "Use at most 20 equipment entries.") }
                    for (index, value) in exercise.equipment.enumerated() { text(value, "\(ep).equipment[\(index)]", max: 80) }
                    if let value = exercise.instructions { text(value, "\(ep).instructions", max: legacy ? 10_000 : 3_000) }
                    issues += validateTarget(exercise.target, measurement: exercise.measurement, path: "\(ep).target", legacy: legacy)
                    issues += validateIntervals(exercise.intervals, measurement: exercise.measurement, target: exercise.target, path: "\(ep).intervals")
                    if let alternatives = exercise.alternatives {
                        if alternatives.isEmpty || alternatives.count > 6 { error("\(ep).alternatives", "Include 1–6 flat alternatives, or omit this field.") }
                        if Set(alternatives.map(\.id)).count != alternatives.count { error("\(ep).alternatives", "Alternative IDs must be unique within the exercise.") }
                        for (index, alternative) in alternatives.enumerated() {
                            identifier(alternative.id, "\(ep).alternatives[\(index)].id")
                            for var issue in validateExercise(alternative.prescription(instanceId: exercise.instanceId)) {
                                issue.path = "\(ep).alternatives[\(index)]." + issue.path.replacingOccurrences(of: "days[0].sessions[0].exercises[0].", with: "")
                                issues.append(issue)
                            }
                        }
                    }
                    if let policy = exercise.progressionPolicy {
                        identifier(policy.id, "\(ep).progressionPolicy.id")
                        if !(1...10_000).contains(policy.version) { error("\(ep).progressionPolicy.version", "Use a positive integer version no larger than 10000.") }
                        if let notes = policy.notes { text(notes, "\(ep).progressionPolicy.notes") }
                        let known = policy.version == 1 && BuiltInProgressionPolicy(rawValue: policy.id) != nil
                        issues.append(PlanIssue(path: "\(ep).progressionPolicy", message: known
                            ? "This policy is available only after you opt in and its targets pass validation. Progression is manual until then."
                            : "This progression policy is not supported. Its reference is preserved; progression remains manual.", severity: .warning))
                    }
                }
            }
        }
        if !hasExercise { error("days", "Include at least one exercise in the weekly plan.") }
        return issues
    }

    private static func validateIntervals(_ blocks: [PlanIntervalBlock]?, measurement: MeasurementKind,
                                          target: ExerciseTarget, path: String) -> [PlanIssue] {
        guard let blocks else { return [] }
        var issues: [PlanIssue] = []
        func error(_ suffix: String, _ message: String) { issues.append(PlanIssue(path: path + suffix, message: message)) }
        let cardio: Set<MeasurementKind> = [.duration, .durationCalories, .distanceTime, .distance]
        if !cardio.contains(measurement) || target.sets != 1 {
            error("", "Interval activities use a cardio measurement and one outer set. Repeat work/recovery sequences inside blocks.")
        }
        if blocks.isEmpty || blocks.count > 40 || blocks.reduce(0, { min(41, $0 + min(41, $1.steps.count)) }) > 40 {
            error("", "Use 1–40 blocks with at most 40 template steps in total.")
        }
        if expandedIntervalCount(blocks) > 400 { error("", "Use at most 400 expanded interval steps per exercise.") }
        if Set(blocks.map(\.id)).count != blocks.count { error("", "Interval block IDs must be unique.") }
        for (bi, block) in blocks.enumerated() {
            let bp = "[\(bi)]"
            if block.id.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) == nil { error(bp + ".id", "Use a valid lowercase block identifier.") }
            if !(1...100).contains(block.repeatCount) { error(bp + ".repeatCount", "Repeat each block 1–100 times.") }
            if block.steps.isEmpty || Set(block.steps.map(\.id)).count != block.steps.count { error(bp + ".steps", "Include steps with distinct identifiers in each block.") }
            for (si, step) in block.steps.enumerated() {
                let sp = bp + ".steps[\(si)]"
                if step.id.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) == nil { error(sp + ".id", "Use a valid lowercase step identifier.") }
                if !cardio.contains(step.measurement) || step.target.sets != 1 || step.target.restSeconds != 0 {
                    error(sp + ".target", "Steps use cardio values, one set, and zero automatic rest. Add a recovery step for prescribed interval rest.")
                }
                issues += validateTarget(step.target, measurement: step.measurement, path: path + sp + ".target", legacy: false)
                if let instructions = step.instructions, instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || instructions.count > 3_000 {
                    error(sp + ".instructions", "Use 1–3000 characters for step instructions.")
                }
            }
        }
        return issues
    }

    private static func validateTarget(_ target: ExerciseTarget, measurement: MeasurementKind,
                                       path: String, legacy: Bool) -> [PlanIssue] {
        var issues: [PlanIssue] = []
        func error(_ field: String, _ message: String) { issues.append(PlanIssue(path: "\(path).\(field)", message: message)) }
        if !(1...20).contains(target.sets) { error("sets", "Use 1–20 sets.") }
        if !(0...900).contains(target.restSeconds) { error("restSeconds", "Use 0–900 rest seconds.") }
        if let reps = target.reps, !(1...1_000).contains(reps.min) || reps.max < reps.min || reps.max > 1_000 {
            error("reps", "Use an ordered integer rep range from 1 to 1000.")
        }
        for (field, value) in [("load", target.load), ("assistance", target.assistance)] {
            guard let value else { continue }
            if !value.value.isFinite || value.value < 0 || value.value > 10_000 {
                error(field, "Use a finite load from 0 to 10000.")
            }
            if ![PlanUnit.kg, .lb].contains(value.unit) { error(field, "Load and assistance must use kg or lb.") }
        }
        let ranges: [(String, QuantityRange?, [PlanUnit])] = [
            ("duration", target.duration, [.s, .min]), ("distance", target.distance, [.m, .km, .mi]),
            ("calories", target.calories, [.kcal])
        ]
        for (field, value, units) in ranges {
            guard let value else { continue }
            if !value.min.isFinite || !value.max.isFinite || value.min <= 0 || value.max < value.min || value.max > 1_000_000 {
                error(field, "Use a positive ordered range no larger than 1000000.")
            }
            if !units.contains(value.unit) { error(field, "Use \(units.map(\.rawValue).joined(separator: ", ")) for \(field).") }
        }
        if let effort = target.effort, effort.min < 0 || effort.max > 10 || effort.max < effort.min {
            error("effort", "Use an ordered effort range from 0 to 10.")
        }
        let allowed: Set<String>
        let required: String?
        let effortKind: EffortTarget.Kind?
        switch measurement {
        case .completion: allowed = []; required = nil; effortKind = nil
        case .weightReps: allowed = ["reps", "load", "effort"]; required = "reps"; effortKind = .rir
        case .reps: allowed = ["reps", "effort"]; required = "reps"; effortKind = .rir
        case .assistedReps: allowed = ["reps", "assistance", "effort"]; required = "reps"; effortKind = .rir
        case .weightDistance: allowed = ["load", "distance", "effort"]; required = "distance"; effortKind = .rir
        case .duration: allowed = ["duration", "effort"]; required = "duration"; effortKind = .rpe
        case .durationCalories: allowed = ["duration", "calories", "effort"]; required = "duration"; effortKind = .rpe
        case .distanceTime: allowed = ["distance", "duration", "effort"]; required = nil; effortKind = .rpe
        case .distance: allowed = ["distance", "effort"]; required = "distance"; effortKind = .rpe
        }
        let present: [String: Bool] = ["reps": target.reps != nil, "load": target.load != nil,
            "assistance": target.assistance != nil, "duration": target.duration != nil,
            "distance": target.distance != nil, "calories": target.calories != nil, "effort": target.effort != nil]
        for (field, exists) in present where exists && !allowed.contains(field) {
            error(field, "\(field.capitalized) is not compatible with \(measurement.rawValue). Change the measurement or prescription; nothing will be discarded automatically.")
        }
        if !legacy, let required, present[required] != true { error(required, "Add a typed \(required) target for \(measurement.rawValue).") }
        if !legacy, measurement == .distanceTime, target.distance == nil, target.duration == nil {
            error("distance", "Add a typed distance or duration target for distance and time activities.")
        }
        if let effort = target.effort, let effortKind, effort.kind != effortKind {
            error("effort.kind", "Use \(effortKind.rawValue.uppercased()) for this measurement.")
        }
        return issues.sorted { $0.path < $1.path }
    }
}
