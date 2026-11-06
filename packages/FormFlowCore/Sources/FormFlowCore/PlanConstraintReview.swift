import Foundation

/// Review only supplied, structured constraints. Free-text suitability is not inferred.
public enum PlanConstraintReview {
    public static func hasKnownSessionBudget(_ profile: TrainingProfile) -> Bool {
        (10...180).contains(profile.sessionMinutes)
            && (profile.hasReviewedAvailability || profile.canGeneratePrompt || profile.sessionMinutes != 45)
    }

    public static func issues(plan: WeeklyPlan, profile: TrainingProfile) -> [PlanIssue] {
        var issues: [PlanIssue] = []
        for day in plan.days where !day.sessions.isEmpty {
            if !profile.availableDays.isEmpty && !profile.availableDays.contains(day.weekday) {
                issues.append(.init(path: day.weekday.displayName,
                    message: "This plan schedules training on \(day.weekday.displayName), which was not an available day in your brief.", severity: .warning))
            }
            for session in day.sessions {
                let path = "\(day.weekday.displayName) · \(session.name)"
                if hasKnownSessionBudget(profile) && session.estimatedMinutes > profile.sessionMinutes {
                    issues.append(.init(path: path,
                        message: "The supplied estimate is \(session.estimatedMinutes) minutes; your brief allows about \(profile.sessionMinutes) minutes per session.", severity: .warning))
                }
                // This exact value is the explicit no-equipment choice in the profile form.
                // Other free-text equipment descriptions remain visible manual review context.
                if profile.equipment == "Bodyweight / no equipment" {
                    let noEquipmentLabels: Set<String> = ["bodyweight", "none", "no equipment", "floor"]
                    for exercise in session.exercises {
                        let listed = exercise.equipment.filter { !noEquipmentLabels.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
                        if !listed.isEmpty {
                            issues.append(.init(path: "\(path) · \(exercise.name)",
                                message: "This exercise lists \(listed.joined(separator: ", ")); your brief says bodyweight / no equipment. Review this choice before using the plan.", severity: .warning))
                        }
                    }
                }
            }
        }
        return issues
    }
}
