import Foundation

/// The existing web program, offered for explicit review rather than assigned to a new profile.
public enum BuiltInPlans {
    public static let sourceRevision = 5

    public static func plan(block: Int = 1, pullUpStep: Int = 1, longRunStage: Int = 1) throws -> WeeklyPlan {
        guard (1...2).contains(block), (1...6).contains(pullUpStep), (1...18).contains(longRunStage) else {
            throw BuiltInPlanError.invalidSelection
        }
        let source = try Source.read()
        var days: [PlanDay] = []
        for weekday in Weekday.allCases {
            guard let day = source.week[weekday.rawValue] else { throw BuiltInPlanError.invalidSource }
            let groups = groups(for: weekday, day: day)
            let sessions = try groups.map { group in
                let exercises = try group.exercises.map {
                    try exercise($0, source: source, block: block, pullUpStep: pullUpStep, longRunStage: longRunStage)
                }
                return PlanSession(id: "\(weekday.rawValue)-\(group.id)", name: group.name, kind: group.kind,
                                   estimatedMinutes: 0, warmup: group.warmup, exercises: exercises,
                                   instructions: "Original day: \(day.focus).\nOriginal combined estimate: \(day.estimate).\n\(day.sequenceNote)")
            }
            days.append(.init(weekday: weekday, sessions: sessions))
        }
        let instructions = [
            "Strength effort: \(source.strengthProgression["effort"] ?? "")",
            "Strength load: \(source.strengthProgression["load"] ?? "")",
            "Strength volume: \(source.strengthProgression["volume"] ?? "")",
            "Optional work and recovery: \(source.optionalRecovery)",
            "Running quality: \(source.runQuality["base"] ?? ""). \(source.runQuality["progression"] ?? "")",
            "Sunday: \(source.week["sunday"]?.sequenceNote ?? "Complete rest.")"
        ].joined(separator: "\n\n")
        return WeeklyPlan(id: "form-flow", name: "Form / Flow · Block \(block)", assumptions: [
            "Existing Form / Flow program, source revision \(sourceRevision). Review its exercise choices, workload and recovery rules before activation; it is not generated from your training brief.",
            block == 1 ? "Block 1 uses the selected 18-stage long-run target and keeps other runs easy." :
                "Block 2 is recommended only after two qualified 10 km runs. Thursday alternates completed tempo and interval sessions; choose the appropriate variant explicitly.",
            "Separate sessions keep the source’s timing guidance. Component duration estimates are unknown because the source supplies combined daily ranges.",
            "Policy references make supported rules available for review. Progression remains manual until you explicitly opt in."
        ], days: days, instructions: instructions)
    }

    private struct Group {
        let id: String
        let name: String
        let kind: String
        let exercises: [SourceExercise]
        let warmup: [String]
    }
    private static func groups(for weekday: Weekday, day: SourceDay) -> [Group] {
        func group(_ id: String, _ name: String, _ kind: String, _ predicate: (SourceExercise) -> Bool,
                   warmup: [String] = []) -> Group {
            .init(id: id, name: name, kind: kind, exercises: day.exercises.filter(predicate), warmup: warmup)
        }
        switch weekday {
        case .monday:
            return [group("strength", "Legs A", "strength", { $0.id != "bicycle-hiit" }, warmup: day.warmup),
                    group("hiit", "Later bicycle HIIT", "cardio", { $0.id == "bicycle-hiit" })]
        case .tuesday:
            return [group("strength", "Push A", "strength", { $0.category == "Strength" }, warmup: day.warmup),
                    group("run", "Easy run", "cardio", { $0.id == "easy-run" }),
                    group("recovery", "Pelvic-floor routine", "mobility", { $0.category == "Recovery" })]
        case .wednesday:
            return [group("strength", "Pull A", "strength", { $0.category == "Strength" }, warmup: day.warmup),
                    group("cycle", "Optional Zone 2 cycling", "cardio", { $0.id == "zone-2-cycle" }),
                    group("mobility", "Mobility A", "mobility", { $0.category == "Mobility" })]
        case .thursday:
            let strength = group("strength", "Evening Legs B", "strength", { $0.category == "Strength" }, warmup: day.warmup)
            let run = group("run", "Morning run", "cardio", { $0.id == "run-2" })
            return [run, strength, group("recovery", "Pelvic-floor routine", "mobility", { $0.category == "Recovery" })]
        case .friday:
            return [group("strength", "Push B", "strength", { $0.category == "Strength" }, warmup: day.warmup),
                    group("mobility", "Mobility B", "mobility", { $0.category == "Mobility" })]
        case .saturday:
            return [group("run", "Long run", "cardio", { $0.id == "long-run" }, warmup: day.warmup.filter { $0.hasPrefix("Long run") }),
                    group("swim", "Optional technique swim", "cardio", { $0.id == "easy-swim" }, warmup: day.warmup.filter { $0.hasPrefix("Swim") }),
                    group("pull", "Pull B and pelvic-floor routine", "mixed", { $0.category == "Strength" || $0.category == "Recovery" }, warmup: day.warmup.filter { $0.hasPrefix("Pull B") })]
        case .sunday: return []
        }
    }

    private static let compounds: Set<String> = ["box-squat", "bulgarian-split-squat", "trap-bar-deadlift", "barbell-hip-thrust",
        "half-kneeling-landmine-press", "neutral-db-bench", "neutral-incline-db-press", "one-arm-landmine-press",
        "chest-supported-row", "one-arm-cable-row", "controlled-step-down"]

    private static func exercise(_ e: SourceExercise, source: Source, block: Int, pullUpStep: Int, longRunStage: Int) throws -> PlanExercise {
        guard var measurement = MeasurementKind(rawValue: e.measurement) else { throw BuiltInPlanError.invalidSource }
        var target = ExerciseTarget(sets: e.sets, restSeconds: e.rest)
        var policy: PlanPolicyReference?
        var intervals: [PlanIntervalBlock]?
        var alternatives: [PlanAlternative]?
        var currentGuidance: String?
        var optional = e.optional ?? false

        switch e.id {
        case "pull-up-progression":
            let step = BuiltInProgression.pullUpSteps[pullUpStep - 1], text = source.pullUpSteps[pullUpStep - 1]
            measurement = step.measurement
            target.sets = step.sets
            target.reps = .init(min: step.minReps, max: step.maxReps)
            target.effort = .init(kind: .rir, min: step.minimumRIR, max: step.minimumRIR)
            policy = BuiltInProgressionPolicy.pullUp.reference
            currentGuidance = "Selected Step \(pullUpStep): \(text.prescription)\nAdvance when: \(text.target)\nThen: \(text.next)"
        case "long-run":
            let low = block == 1 ? BuiltInProgression.longRunStages[longRunStage - 1].distanceKM : 8
            let high = block == 1 ? (longRunStage == 18 ? 7 : low) : 10
            target.distance = .init(min: low, max: high, unit: .km)
            policy = (block == 1 ? BuiltInProgressionPolicy.longRun : .easyRun).reference
            currentGuidance = block == 1 ? "Selected Stage \(longRunStage): \(source.longRuns[longRunStage - 1]) easy · walk breaks allowed" :
                "8–10 km easy · conversational pace · walk breaks allowed"
        case "easy-run":
            target.duration = .init(min: 30, max: block == 1 ? 30 : 40, unit: .min)
            if block == 1 {
                target.effort = .init(kind: .rpe, min: 2, max: 4)
                policy = BuiltInProgressionPolicy.easyRun.reference
                currentGuidance = "30 min easy · RPE 2–4 · conversational pace"
            } else {
                currentGuidance = "30–40 min easy · then 4 × 20-sec relaxed strides with full easy recovery. Recovery duration is not specified; manage the strides manually."
            }
        case "run-2":
            if block == 1 {
                target.duration = .init(min: 25, max: 35, unit: .min)
                target.effort = .init(kind: .rpe, min: 2, max: 4)
                policy = BuiltInProgressionPolicy.easyRun.reference
                currentGuidance = "25–35 min easy · RPE 2–4 · morning run · lift in the evening about 6 hours or more later"
            } else {
                // The source leaves the alternating quality choice to completed history. Never pick it silently.
                measurement = .completion
                alternatives = [qualityRun(tempo: true), qualityRun(tempo: false)]
                currentGuidance = "Choose Tempo or Intervals explicitly before recording, alternating completed quality sessions. The original instructions remain below. No quality variant is selected automatically."
            }
        case "bicycle-hiit":
            target.duration = .init(min: 36, max: 38, unit: .min)
            intervals = [timedBlock("warmup", kind: .warmup, min: 10, max: 10),
                         .init(id: "repeats", repeatCount: 6, steps: [timedStep("hard", kind: .work, min: 1, max: 1, effort: .init(kind: .rpe, min: 8, max: 9)),
                                                                      timedStep("easy", kind: .recovery, min: 2, max: 2)]),
                         timedBlock("cooldown", kind: .cooldown, min: 8, max: 10)]
        case "zone-2-cycle", "easy-swim":
            target.duration = .init(min: 25, max: 40, unit: .min)
            target.effort = .init(kind: .rpe, min: 2, max: 3)
        case "pelvic-floor":
            // Breath and relaxation durations are unspecified; their sum is not a timed target.
            measurement = .completion
            currentGuidance = "Complete the source routine manually. Its total duration is unspecified."
        case "copenhagen-plank": target.duration = .init(min: 15, max: 25, unit: .s)
        case "suitcase-carry": target.distance = .init(min: 20, max: 30, unit: .m)
        default:
            if measurement != .completion {
                guard let reps = repRange(e.prescription) else { throw BuiltInPlanError.invalidSource }
                target.reps = reps
                if e.category == "Strength", measurement == .weightReps, e.id != "kettlebell-swing" {
                    target.effort = .init(kind: .rir, min: compounds.contains(e.id) ? 2 : 1, max: 3)
                    policy = BuiltInProgressionPolicy.strength.reference
                }
            }
        }
        if block == 2, e.id == "barbell-hip-thrust" { target.sets = 2 }
        if block == 2, e.id == "kettlebell-swing" { optional = true }
        if let variants = source.alternatives[e.id] {
            alternatives = try variants.map { variant in
                guard let kind = MeasurementKind(rawValue: variant.measurement), let reps = repRange(variant.prescription) else { throw BuiltInPlanError.invalidSource }
                return PlanAlternative(id: variant.id, exerciseId: variant.id, name: variant.name, measurement: kind,
                                       target: .init(sets: variant.sets, restSeconds: e.rest, reps: reps),
                                       instructions: guidance(prescription: variant.prescription, guide: source.guidance[variant.id]))
            }
        }
        let instructions = [currentGuidance, guidance(prescription: e.prescription, guide: source.guidance[e.id])].compactMap { $0 }.joined(separator: "\n\n")
        return PlanExercise(instanceId: e.id, exerciseId: e.id, name: e.name, measurement: measurement,
                            target: target, optional: optional, instructions: instructions,
                            progressionPolicy: policy, alternatives: alternatives, intervals: intervals)
    }

    private static func qualityRun(tempo: Bool) -> PlanAlternative {
        let work = tempo ? 6.0 : 2.0, count = tempo ? 3 : 6, cooldown = tempo ? 5.0 : 8.0
        let blocks = [timedBlock("warmup", kind: .warmup, min: 10, max: 10),
                      PlanIntervalBlock(id: "repeats", repeatCount: count, steps: [
                        timedStep("work", kind: .work, min: work, max: work, effort: .init(kind: .rpe, min: tempo ? 6 : 8, max: tempo ? 7 : 8)),
                        timedStep("easy", kind: .recovery, min: 2, max: 2)]),
                      timedBlock("cooldown", kind: .cooldown, min: cooldown, max: 10)]
        return .init(id: tempo ? "tempo" : "intervals", exerciseId: tempo ? "tempo-run" : "interval-run",
                     name: tempo ? "Tempo run" : "Interval run", measurement: .distanceTime,
                     target: .init(sets: 1, restSeconds: 0, duration: .init(min: 10 + Double(count) * (work + 2) + cooldown,
                                                                         max: 10 + Double(count) * (work + 2) + 10, unit: .min)),
                     instructions: tempo ? "10 min easy, 3 × 6 min at RPE 6–7 with 2 min easy, then 5–10 min easy." :
                        "10 min easy, 6 × 2 min at RPE 8 with 2 min easy, then 8–10 min easy.", intervals: blocks)
    }
    private static func timedBlock(_ id: String, kind: PlanIntervalKind, min: Double, max: Double) -> PlanIntervalBlock {
        .init(id: id, steps: [timedStep(id, kind: kind, min: min, max: max)])
    }
    private static func timedStep(_ id: String, kind: PlanIntervalKind, min: Double, max: Double, effort: EffortTarget? = nil) -> PlanIntervalStep {
        .init(id: id, kind: kind, measurement: .duration, target: .init(sets: 1, restSeconds: 0,
                                                                     duration: .init(min: min, max: max, unit: .min), effort: effort))
    }
    private static func repRange(_ text: String) -> RepRange? {
        guard let pattern = try? NSRegularExpression(pattern: "×\\s*(\\d+)(?:[–-](\\d+))?"),
              let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let minimumRange = Range(match.range(at: 1), in: text), let minimum = Int(text[minimumRange]) else { return nil }
        let maximum = Range(match.range(at: 2), in: text).flatMap { Int(text[$0]) } ?? minimum
        return .init(min: minimum, max: maximum)
    }
    private static func guidance(prescription: String, guide: SourceGuide?) -> String {
        var parts = ["Prescription: \(prescription)"]
        if let guide {
            parts += ["Setup: \(guide.setup)", "Action: \(guide.action)", "Watch for: \(guide.watch)"]
            if !guide.option.isEmpty { parts.append("Option: \(guide.option)") }
        }
        return parts.joined(separator: "\n\n")
    }

    private struct Source: Decodable {
        let version: Int
        let week: [String: SourceDay]
        let guidance: [String: SourceGuide]
        let alternatives: [String: [SourceAlternative]]
        let pullUpSteps: [SourcePullStep]
        let longRuns: [String]
        let strengthProgression: [String: String]
        let optionalRecovery: String
        let runQuality: [String: String]
        static func read() throws -> Self {
            guard let url = Bundle.module.url(forResource: "built-in-source-v1", withExtension: "json") else { throw BuiltInPlanError.missingSource }
            let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            guard value.version == 1, value.week.count == 7, value.pullUpSteps.count == 6, value.longRuns.count == 18 else { throw BuiltInPlanError.invalidSource }
            return value
        }
    }
    private struct SourceDay: Decodable {
        let focus: String
        let estimate: String
        let sequenceNote: String
        let warmup: [String]
        let exercises: [SourceExercise]
    }
    private struct SourceExercise: Decodable {
        let id: String
        let name: String
        let prescription: String
        let sets: Int
        let rest: Int
        let measurement: String
        let category: String
        let optional: Bool?
    }
    private struct SourceGuide: Decodable { let setup: String; let action: String; let watch: String; let option: String }
    private struct SourceAlternative: Decodable { let id: String; let name: String; let prescription: String; let sets: Int; let measurement: String }
    private struct SourcePullStep: Decodable { let prescription: String; let target: String; let next: String }
}

public enum BuiltInPlanError: Error, LocalizedError, Equatable {
    case invalidSelection, missingSource, invalidSource
    public var errorDescription: String? {
        switch self {
        case .invalidSelection: "Choose block 1 or 2, pull-up step 1–6 and long-run stage 1–18."
        case .missingSource: "The existing program source is unavailable in this build."
        case .invalidSource: "The bundled program source is incomplete. No plan was created."
        }
    }
}
