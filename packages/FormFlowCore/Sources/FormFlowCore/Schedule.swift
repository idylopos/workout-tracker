import Foundation

public struct ScheduledPlanSession: Identifiable, Equatable, Sendable {
    public var id: String
    public var date: Date
    public var session: PlanSession
}

public enum PlanSchedule {
    /// A start date never rotates weekdays: a Monday prescription remains on Monday.
    public static func upcoming(plan: WeeklyPlan, activationDate: Date, from date: Date,
                                limit: Int = 10, calendar: Calendar = .current) -> [ScheduledPlanSession] {
        guard limit > 0, plan.days.contains(where: { !$0.sessions.isEmpty }) else { return [] }
        let firstDay = max(calendar.startOfDay(for: activationDate), calendar.startOfDay(for: date))
        var result: [ScheduledPlanSession] = []
        // Bounded to a year even when supplied a malformed plan directly.
        for offset in 0..<366 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else { break }
            let weekday = calendar.component(.weekday, from: day)
            for session in plan.days.filter({ $0.weekday.calendarWeekday == weekday }).flatMap(\.sessions) {
                let parts = calendar.dateComponents([.year, .month, .day], from: day)
                let dateID = "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
                result.append(ScheduledPlanSession(id: "\(plan.id):\(dateID):\(session.id)", date: day, session: session))
                if result.count >= limit { return result }
            }
        }
        return result
    }
}
