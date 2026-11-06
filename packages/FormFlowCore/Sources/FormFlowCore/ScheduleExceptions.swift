import Foundation

public enum ScheduleExceptionAction: String, Codable, CaseIterable, Sendable {
    case rescheduled, skipped, missed, restored
}

/// One exception per original weekly occurrence. Moving it never changes its identity.
public struct ScheduleException: Codable, Equatable, Sendable, Identifiable {
    public var id: String { occurrenceID }
    public let occurrenceID: String
    public let planID: String
    public let planRevisionID: String
    public let sessionID: String
    public let originalDay: LocalTrainingDay
    public let destinationDay: LocalTrainingDay?
    public let action: ScheduleExceptionAction
    public let note: String
    public let updatedAt: Date
    public init(occurrenceID: String, planID: String, planRevisionID: String, sessionID: String,
                originalDay: LocalTrainingDay, destinationDay: LocalTrainingDay? = nil,
                action: ScheduleExceptionAction, note: String = "", updatedAt: Date = Date()) throws {
        self.occurrenceID = occurrenceID; self.planID = planID; self.planRevisionID = planRevisionID
        self.sessionID = sessionID; self.originalDay = originalDay; self.destinationDay = destinationDay
        self.action = action; self.note = note; self.updatedAt = updatedAt
        try validate()
    }
    public var effectiveDay: LocalTrainingDay { destinationDay ?? originalDay }
    public func validate() throws {
        try originalDay.validate(); try destinationDay?.validate()
        guard occurrenceID == ScheduleExceptionSchedule.occurrenceID(planID: planID, originalDay: originalDay.date, sessionID: sessionID),
              Self.validIdentifier(planID), Self.validIdentifier(sessionID), !planRevisionID.isEmpty, planRevisionID.count <= 200,
              note.count <= 1_000, updatedAt.timeIntervalSinceReferenceDate.isFinite,
              destinationDay.map({ $0.timeZoneID == originalDay.timeZoneID }) ?? true,
              action != .rescheduled || (destinationDay != nil && destinationDay?.date != originalDay.date),
              action != .restored || destinationDay == nil else { throw ScheduleExceptionError.invalidException }
    }
    private static func validIdentifier(_ value: String) -> Bool {
        value.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil
    }
}

public enum ScheduleOccurrenceStatus: String, Codable, Sendable {
    case planned, needsReview, skipped, missed, inProgress, finished, abandoned
    public var label: String {
        switch self {
        case .planned: "Planned"
        case .needsReview: "Needs review"
        case .skipped: "Skipped"
        case .missed: "Marked missed"
        case .inProgress: "Workout in progress"
        case .finished: "Workout recorded"
        case .abandoned: "Abandoned workout recorded"
        }
    }
}

public struct ScheduleOccurrence: Equatable, Sendable, Identifiable {
    public var id: String { scheduled.id }
    public let scheduled: ScheduledPlanSession
    public let originalDay: LocalTrainingDay
    public let effectiveDay: LocalTrainingDay
    public let exception: ScheduleException?
    public let status: ScheduleOccurrenceStatus
    public let workoutID: UUID?
    public var isMoved: Bool { originalDay.date != effectiveDay.date }
    public var canStart: Bool { status == .planned || status == .needsReview }
}

public enum ScheduleExceptionError: Error, LocalizedError, Equatable, Sendable {
    case invalidException, duplicateIdentity, invalidRange, staleOccurrence, recordedOccurrence, pendingWatchStart, collision, invalidDestination, notYetMissed
    public var errorDescription: String? {
        switch self {
        case .invalidException: "This schedule change has invalid dates or identity. Nothing was changed."
        case .duplicateIdentity: "More than one exception claims the same scheduled occurrence. Review the conflicting records."
        case .invalidRange: "Choose a calendar range of at most one year."
        case .staleOccurrence: "This scheduled occurrence changed or is no longer in the active plan. Open the current schedule again."
        case .recordedOccurrence: "A workout is already linked to this occurrence. Its schedule and recorded history cannot be moved or skipped."
        case .pendingWatchStart: "A Watch start request may already be recording this occurrence. Reconcile that request before changing its schedule."
        case .collision: "This session already has another occurrence on that date. Choose a different date or resolve that occurrence first."
        case .invalidDestination: "Choose a date from today through the next year, on or after the plan begins."
        case .notYetMissed: "Only an earlier, unrecorded occurrence can be marked missed."
        }
    }
}

public enum ScheduleExceptionSchedule {
    public static func occurrenceID(planID: String, originalDay: String, sessionID: String) -> String {
        let pieces = originalDay.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return "" }
        // Preserve the existing PlanSchedule ID format (unpadded month/day).
        return "\(planID):\(pieces[0])-\(pieces[1])-\(pieces[2]):\(sessionID)"
    }

    /// Schedule dates remain date-only local calendar selections across travel. The recorded
    /// exception timezone is provenance; workout/recovery timezones retain their separate semantics.
    public static func occurrences(plan: WeeklyPlan, activationDate: Date, from: Date, through: Date,
                                   exceptions: [ScheduleException] = [], workouts: [WorkoutSession] = [],
                                   asOf now: Date = Date(), calendar: Calendar = .current) throws -> [ScheduleOccurrence] {
        let index = try Index(plan: plan, activationDate: activationDate, exceptions: exceptions, workouts: workouts, now: now, calendar: calendar)
        return try occurrences(from: from, through: through, index: index)
    }

    public static func upcoming(plan: WeeklyPlan, activationDate: Date, from: Date, limit: Int = 10,
                                exceptions: [ScheduleException] = [], workouts: [WorkoutSession] = [],
                                calendar: Calendar = .current) throws -> [ScheduledPlanSession] {
        guard limit > 0 else { return [] }
        let index = try Index(plan: plan, activationDate: activationDate, exceptions: exceptions, workouts: workouts, now: from, calendar: calendar)
        let first = max(index.calendar.startOfDay(for: from), index.activationStart)
        guard let last = index.calendar.date(byAdding: .day, value: 365, to: first) else { throw ScheduleExceptionError.invalidRange }
        var cursor = first, result: [ScheduledPlanSession] = []
        let maximum = min(limit, 7_686)
        // Typical Today requests stop after one or two windows. All windows share one
        // validated exception/session/history index, including moved-in occurrences.
        while cursor <= last && result.count < maximum {
            guard let windowEnd = index.calendar.date(byAdding: .day, value: 13, to: cursor),
                  let next = index.calendar.date(byAdding: .day, value: 14, to: cursor) else { throw ScheduleExceptionError.invalidRange }
            let window = try occurrences(from: cursor, through: min(windowEnd, last), index: index)
            result += window.filter { $0.status == .planned }.prefix(maximum - result.count).map(\.scheduled)
            cursor = next
        }
        return result
    }

    public static func resolve(occurrenceID id: String, plan: WeeklyPlan, activationDate: Date,
                               exceptions: [ScheduleException] = [], workouts: [WorkoutSession] = [],
                               asOf now: Date = Date(), calendar: Calendar = .current) throws -> ScheduleOccurrence? {
        let index = try Index(plan: plan, activationDate: activationDate, exceptions: exceptions, workouts: workouts, now: now, calendar: calendar)
        return try resolve(id, index: index)
    }

    private struct Index {
        let planID: String
        let calendar: Calendar
        let activationStart: Date
        let today: Date
        let sessions: [String: PlanSession]
        let weekdays: [String: Int]
        let sessionsByWeekday: [Int: [PlanSession]]
        let exceptions: [String: ScheduleException]
        let movedIDsByDay: [Date: [String]]
        let workouts: [String: WorkoutSession]

        init(plan: WeeklyPlan, activationDate: Date, exceptions: [ScheduleException], workouts: [WorkoutSession], now: Date, calendar: Calendar) throws {
            guard activationDate.timeIntervalSinceReferenceDate.isFinite, now.timeIntervalSinceReferenceDate.isFinite else { throw ScheduleExceptionError.invalidRange }
            let cal = gregorian(calendar)
            self.planID = plan.id; self.calendar = cal
            self.activationStart = cal.startOfDay(for: activationDate); self.today = cal.startOfDay(for: now)
            var byID: [String: PlanSession] = [:], byWeekday: [Int: [PlanSession]] = [:], weekdays: [String: Int] = [:]
            for day in plan.days {
                for session in day.sessions {
                    guard byID[session.id] == nil else { throw ScheduleExceptionError.duplicateIdentity }
                    byID[session.id] = session; weekdays[session.id] = day.weekday.calendarWeekday
                    byWeekday[day.weekday.calendarWeekday, default: []].append(session)
                }
            }
            self.sessions = byID; self.sessionsByWeekday = byWeekday; self.weekdays = weekdays
            self.exceptions = try validated(exceptions)
            var moved: [Date: [String]] = [:]
            for change in exceptions where change.planID == plan.id {
                guard let effective = date(change.effectiveDay.date, calendar: cal) else { throw ScheduleExceptionError.invalidException }
                moved[effective, default: []].append(change.id)
            }
            self.movedIDsByDay = moved
            var linked: [String: WorkoutSession] = [:]
            for workout in workouts {
                guard let id = workout.scheduledSessionID else { continue }
                if let existing = linked[id] {
                    let replacesAbandoned = existing.state == .abandoned && workout.state != .abandoned
                    let samePriority = (existing.state == .abandoned) == (workout.state == .abandoned)
                    if replacesAbandoned || (samePriority && workout.startedAt < existing.startedAt) { linked[id] = workout }
                } else { linked[id] = workout }
            }
            self.workouts = linked
        }
    }

    private static func occurrences(from: Date, through: Date, index: Index) throws -> [ScheduleOccurrence] {
        guard from.timeIntervalSinceReferenceDate.isFinite, through.timeIntervalSinceReferenceDate.isFinite else { throw ScheduleExceptionError.invalidRange }
        let cal = index.calendar, start = cal.startOfDay(for: from), end = cal.startOfDay(for: through)
        guard let span = cal.dateComponents([.day], from: start, to: end).day, (0...365).contains(span) else { throw ScheduleExceptionError.invalidRange }
        var ids = Set<String>(), cursor = start
        while cursor <= end {
            if cursor >= index.activationStart {
                let day = LocalTrainingDay(instant: cursor, timeZone: cal.timeZone).date
                for session in index.sessionsByWeekday[cal.component(.weekday, from: cursor)] ?? [] {
                    ids.insert(occurrenceID(planID: index.planID, originalDay: day, sessionID: session.id))
                }
            }
            // An occurrence can move into this range from any original week.
            ids.formUnion(index.movedIDsByDay[cursor] ?? [])
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { throw ScheduleExceptionError.invalidRange }
            cursor = next
        }
        return try ids.compactMap { try resolve($0, index: index) }
            .filter { $0.scheduled.date >= start && $0.scheduled.date <= end }
            .sorted { $0.scheduled.date == $1.scheduled.date ? $0.id < $1.id : $0.scheduled.date < $1.scheduled.date }
    }

    private static func resolve(_ id: String, index: Index) throws -> ScheduleOccurrence? {
        let cal = index.calendar, parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == index.planID, let session = index.sessions[String(parts[2])] else { return nil }
        let numbers = parts[1].split(separator: "-").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        let iso = String(format: "%04d-%02d-%02d", numbers[0], numbers[1], numbers[2])
        guard LocalTrainingDay.isValidDate(iso), id == occurrenceID(planID: index.planID, originalDay: iso, sessionID: session.id),
              let originalDate = date(iso, calendar: cal), originalDate >= index.activationStart else { return nil }
        let change = index.exceptions[id]
        if change == nil && index.weekdays[session.id] != cal.component(.weekday, from: originalDate) { return nil }
        let original = change?.originalDay ?? LocalTrainingDay(instant: originalDate, timeZone: cal.timeZone)
        let effective = change?.effectiveDay ?? original
        guard let effectiveDate = date(effective.date, calendar: cal) else { throw ScheduleExceptionError.invalidException }
        guard effectiveDate >= index.activationStart else { return nil }
        let recorded = index.workouts[id]
        let status: ScheduleOccurrenceStatus
        if let recorded {
            status = recorded.state == .finished ? .finished : recorded.state == .abandoned ? .abandoned : .inProgress
        } else if change?.action == .skipped { status = .skipped }
        else if change?.action == .missed { status = .missed }
        else { status = effectiveDate < index.today ? .needsReview : .planned }
        return .init(scheduled: .init(id: id, date: effectiveDate, session: session), originalDay: original,
                     effectiveDay: effective, exception: change, status: status, workoutID: recorded?.id)
    }

    /// Validate the user's one-off decision against authoritative history immediately before saving.
    public static func change(_ expected: ScheduleOccurrence, action: ScheduleExceptionAction, destination: LocalTrainingDay? = nil,
                              note: String = "", plan: WeeklyPlan, planRevisionID: String, activationDate: Date,
                              exceptions: [ScheduleException], workouts: [WorkoutSession], pendingWatchOccurrenceIDs: Set<String> = [],
                              at now: Date = Date(), calendar: Calendar = .current) throws -> ScheduleException {
        let cal = gregorian(calendar)
        guard let current = try resolve(occurrenceID: expected.id, plan: plan, activationDate: activationDate,
                                        exceptions: exceptions, workouts: workouts, asOf: now, calendar: cal),
              current == expected else { throw ScheduleExceptionError.staleOccurrence }
        guard current.workoutID == nil else { throw ScheduleExceptionError.recordedOccurrence }
        guard !pendingWatchOccurrenceIDs.contains(expected.id) else { throw ScheduleExceptionError.pendingWatchStart }
        if action == .missed && current.scheduled.date >= cal.startOfDay(for: now) { throw ScheduleExceptionError.notYetMissed }
        var destination = destination
        if action == .restored { destination = nil }
        else if action != .rescheduled { destination = current.isMoved ? current.effectiveDay : nil }
        if action == .rescheduled {
            guard let selected = destination, let proposed = date(selected.date, calendar: cal),
                  selected.timeZoneID == current.originalDay.timeZoneID,
                  proposed >= max(cal.startOfDay(for: now), cal.startOfDay(for: activationDate)),
                  let upper = cal.date(byAdding: .day, value: 365, to: cal.startOfDay(for: now)), proposed <= upper else { throw ScheduleExceptionError.invalidDestination }
            if selected.date == current.originalDay.date { destination = nil }
        }
        let resolvedAction: ScheduleExceptionAction = action == .rescheduled && destination == nil ? .restored : action
        let change = try ScheduleException(occurrenceID: current.id, planID: plan.id, planRevisionID: planRevisionID,
                                          sessionID: current.scheduled.session.id, originalDay: current.originalDay,
                                          destinationDay: destination, action: resolvedAction, note: note, updatedAt: now)
        if action == .rescheduled || action == .restored {
            guard let day = date(change.effectiveDay.date, calendar: cal) else { throw ScheduleExceptionError.invalidDestination }
            let others = try occurrences(plan: plan, activationDate: activationDate, from: day, through: day,
                                         exceptions: exceptions.filter { $0.id != current.id } + [change], workouts: workouts, asOf: now, calendar: cal)
            guard !others.contains(where: { $0.id != current.id && $0.scheduled.session.id == current.scheduled.session.id && ![.skipped, .missed].contains($0.status) }) else {
                throw ScheduleExceptionError.collision
            }
        }
        return change
    }

    public static func date(_ iso: String, calendar: Calendar = .current) -> Date? {
        guard LocalTrainingDay.isValidDate(iso) else { return nil }
        let values = iso.split(separator: "-").compactMap { Int($0) }
        let cal = gregorian(calendar)
        return cal.date(from: DateComponents(timeZone: cal.timeZone, year: values[0], month: values[1], day: values[2]))
    }
    private static func validated(_ exceptions: [ScheduleException]) throws -> [String: ScheduleException] {
        guard Set(exceptions.map(\.id)).count == exceptions.count else { throw ScheduleExceptionError.duplicateIdentity }
        for change in exceptions { try change.validate() }
        return Dictionary(uniqueKeysWithValues: exceptions.map { ($0.id, $0) })
    }
    private static func gregorian(_ calendar: Calendar) -> Calendar {
        var result = Calendar(identifier: .gregorian); result.timeZone = calendar.timeZone; return result
    }
}
