import Foundation

public enum TrackingError: Error, LocalizedError, Equatable {
    case invalidDay, invalidTimeZone, invalidValue(String), emptyBodyRecord
    public var errorDescription: String? {
        switch self {
        case .invalidDay: "Use a real calendar date in YYYY-MM-DD format."
        case .invalidTimeZone: "The record needs a valid time zone."
        case .invalidValue(let field): "The \(field) value is outside its supported range."
        case .emptyBodyRecord: "Enter at least one body measurement."
        }
    }
}

/// A user's calendar day is retained independently of later travel or time-zone changes.
public struct LocalTrainingDay: Codable, Equatable, Hashable, Sendable {
    public let date: String
    public let timeZoneID: String
    public init(date: String, timeZoneID: String) throws {
        guard TimeZone(identifier: timeZoneID) != nil else { throw TrackingError.invalidTimeZone }
        guard Self.isValidDate(date) else { throw TrackingError.invalidDay }
        self.date = date; self.timeZoneID = timeZoneID
    }
    public init(instant: Date, timeZone: TimeZone) {
        let formatter = Self.formatter(timeZone: timeZone)
        date = formatter.string(from: instant); timeZoneID = timeZone.identifier
    }
    public static func isValidDate(_ value: String) -> Bool {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let formatter = formatter(timeZone: .gmt)
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
    private static func formatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
    public func validate() throws { _ = try Self(date: date, timeZoneID: timeZoneID) }
}

public struct ManualSleepRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public private(set) var day: LocalTrainingDay
    /// Nil is an explicitly unknown night; no record means it has not been answered.
    public private(set) var hours: Double?
    public private(set) var updatedAt: Date
    public init(id: UUID = UUID(), day: LocalTrainingDay, hours: Double?, updatedAt: Date = Date()) throws {
        self.id = id; self.day = day; self.hours = hours; self.updatedAt = updatedAt
        try validate()
    }
    public mutating func edit(day: LocalTrainingDay, hours: Double?, at: Date = Date()) throws {
        let edited = try Self(id: id, day: day, hours: hours, updatedAt: at)
        self = edited
    }
    public func validate() throws {
        try day.validate()
        if let hours, !hours.isFinite || !(0...24).contains(hours) { throw TrackingError.invalidValue("sleep hours") }
    }
}

public struct BodyLength: Codable, Equatable, Sendable {
    public enum Unit: String, Codable, Sendable { case cm, inch }
    public var value: Double
    public var unit: Unit
    public var centimeters: Double { unit == .cm ? value : value * 2.54 }
    public init(value: Double, unit: Unit) { self.value = value; self.unit = unit }
}

public enum MeasurementEdit<Value: Sendable>: Sendable {
    case unchanged, set(Value), clear
    func applying(to current: Value?) -> Value? {
        switch self { case .unchanged: current; case .set(let value): value; case .clear: nil }
    }
}

public struct BodyMeasurementRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public private(set) var day: LocalTrainingDay
    public private(set) var weight: PlanQuantity?
    public private(set) var waist: BodyLength?
    public private(set) var updatedAt: Date
    public var weightKilograms: Double? { weight.map { $0.unit == .lb ? $0.value * 0.45359237 : $0.value } }
    public init(id: UUID = UUID(), day: LocalTrainingDay, weight: PlanQuantity? = nil,
                waist: BodyLength? = nil, updatedAt: Date = Date()) throws {
        self.id = id; self.day = day; self.weight = weight; self.waist = waist; self.updatedAt = updatedAt
        try validate()
    }
    public mutating func edit(day: LocalTrainingDay? = nil, weight: MeasurementEdit<PlanQuantity> = .unchanged,
                              waist: MeasurementEdit<BodyLength> = .unchanged, at: Date = Date()) throws {
        self = try Self(id: id, day: day ?? self.day, weight: weight.applying(to: self.weight),
                        waist: waist.applying(to: self.waist), updatedAt: at)
    }
    public func validate() throws {
        try day.validate()
        guard weight != nil || waist != nil else { throw TrackingError.emptyBodyRecord }
        if let weight, ![PlanUnit.kg, .lb].contains(weight.unit) || !weight.value.isFinite || weight.value < 0 {
            throw TrackingError.invalidValue("weight")
        }
        if let waist, !waist.value.isFinite || waist.value < 0 { throw TrackingError.invalidValue("waist") }
    }
}

public struct SleepWeekSummary: Equatable, Sendable {
    public let week: String
    public let meanHours: Double?
    public let recordedNights: Int
    public let unknownNights: Int
}

public enum TrackingSummary {
    /// One value per local day; an edit with the latest timestamp takes precedence.
    public static func sleepWeeks(_ records: [ManualSleepRecord]) -> [SleepWeekSummary] {
        let latest = Dictionary(grouping: records, by: { $0.day.date }).compactMapValues {
            $0.max { $0.updatedAt < $1.updatedAt }
        }
        let grouped = Dictionary(grouping: latest.values) { record -> String in
            var calendar = Calendar(identifier: .gregorian)
            calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
            calendar.timeZone = .gmt
            let parts = record.day.date.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
                  let start = calendar.dateInterval(of: .weekOfYear, for: day)?.start else { return record.day.date }
            return LocalTrainingDay(instant: start, timeZone: calendar.timeZone).date
        }
        return grouped.map { week, nights in
            let known = nights.compactMap(\.hours)
            return SleepWeekSummary(week: week, meanHours: known.isEmpty ? nil : known.reduce(0, +) / Double(known.count),
                                    recordedNights: known.count, unknownNights: nights.count - known.count)
        }.sorted { $0.week < $1.week }
    }
}
