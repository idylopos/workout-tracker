import Foundation

public enum RecoveryPhase: String, Codable, CaseIterable, Sendable { case evening, nextMorning }
public enum RecoveryReadiness: String, Codable, Sendable { case yes, no, unknown }

public struct SessionRecoveryRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sessionID: UUID
    public let phase: RecoveryPhase
    public private(set) var day: LocalTrainingDay
    public private(set) var rating: Int?
    public private(set) var readiness: RecoveryReadiness
    public private(set) var notes: String
    public private(set) var updatedAt: Date
    /// Ratings above 1 cannot establish recovery. Unknown is retained even with a low rating.
    public var effectiveReadiness: RecoveryReadiness { (rating ?? 0) > 1 ? .no : readiness }
    public init(id: UUID = UUID(), sessionID: UUID, phase: RecoveryPhase, day: LocalTrainingDay,
                rating: Int? = nil, readiness: RecoveryReadiness = .unknown, notes: String = "", updatedAt: Date = Date()) throws {
        self.id = id; self.sessionID = sessionID; self.phase = phase; self.day = day
        self.rating = rating; self.readiness = readiness; self.notes = notes; self.updatedAt = updatedAt
        try validate()
    }
    public mutating func edit(day: LocalTrainingDay, rating: Int?, readiness: RecoveryReadiness,
                              notes: String, at: Date = Date()) throws {
        self = try Self(id: id, sessionID: sessionID, phase: phase, day: day, rating: rating,
                        readiness: readiness, notes: notes, updatedAt: at)
    }
    public func validate() throws {
        try day.validate()
        if let rating, !(0...4).contains(rating) { throw TrackingError.invalidValue("recovery rating") }
        guard notes.count <= 10_000 else { throw TrackingError.invalidValue("recovery notes length") }
    }
}

public enum LegacyRecovery {
    /// Matches lib.js normalizeResponseRating; missing input remains missing.
    public static func rating(_ value: Double?, scaleVersion: Int = 1) -> Int? {
        guard let value, value.isFinite else { return nil }
        if scaleVersion >= 2 { return Int(min(4, max(0, value.rounded(.toNearestOrAwayFromZero)))) }
        if value <= 0 { return 0 }; if value <= 3 { return 1 }; if value <= 5 { return 2 }
        if value <= 7 { return 3 }; return 4
    }
    public static func readiness(rating: Int?, explicit: RecoveryReadiness?) -> RecoveryReadiness {
        if let rating, rating > 1 { return .no }
        if let explicit { return explicit }
        return rating == nil ? .unknown : .yes
    }
}

public struct RecoverySessionAnchor: Sendable {
    public let sessionID: UUID
    public let endedAt: Date
    public let timeZoneID: String
    public init(sessionID: UUID, endedAt: Date, timeZoneID: String) {
        self.sessionID = sessionID; self.endedAt = endedAt; self.timeZoneID = timeZoneID
    }
}

public struct RecoveryPrompt: Equatable, Sendable, Identifiable {
    public var id: String { "\(sessionID.uuidString):\(phase.rawValue)" }
    public let sessionID: UUID
    public let phase: RecoveryPhase
    public let sessionDay: LocalTrainingDay
    public let dueAt: Date
}

public enum RecoverySchedule {
    public static func due(sessions: [RecoverySessionAnchor], answers: [SessionRecoveryRecord],
                           now: Date, lookbackDays: Int = 2) -> [RecoveryPrompt] {
        var prompts: [RecoveryPrompt] = []
        for session in sessions {
            guard let zone = TimeZone(identifier: session.timeZoneID) else { continue }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let sessionStart = calendar.startOfDay(for: session.endedAt)
            let today = calendar.startOfDay(for: now)
            let answered = Set(answers.filter { $0.sessionID == session.sessionID }.map(\.phase))
            let sessionDay = LocalTrainingDay(instant: session.endedAt, timeZone: zone)
            if sessionStart == today, !answered.contains(.evening),
               let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: session.endedAt) {
                let due = max(evening, session.endedAt.addingTimeInterval(3_600))
                if now >= due { prompts.append(RecoveryPrompt(sessionID: session.sessionID, phase: .evening, sessionDay: sessionDay, dueAt: due)) }
            }
            if !answered.contains(.nextMorning), let tomorrow = calendar.date(byAdding: .day, value: 1, to: sessionStart),
               let oldest = calendar.date(byAdding: .day, value: -max(1, lookbackDays), to: today),
               sessionStart >= oldest, now >= tomorrow {
                prompts.append(RecoveryPrompt(sessionID: session.sessionID, phase: .nextMorning, sessionDay: sessionDay, dueAt: tomorrow))
            }
        }
        return prompts.sorted { $0.dueAt < $1.dueAt }
    }
}
