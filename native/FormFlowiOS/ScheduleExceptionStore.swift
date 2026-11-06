import Foundation
import Observation
import SwiftData
import FormFlowCore

@Model
final class ScheduleExceptionRecord {
    @Attribute(.unique) var id: String
    var payload: Data
    init(id: String, payload: Data) { self.id = id; self.payload = payload }
}

@MainActor @Observable
final class ScheduleExceptionStore {
    private(set) var exceptions: [ScheduleException] = []
    var errorMessage: String?
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let commit: (ModelContext) throws -> Void

    init(context: ModelContext, commit: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws {
        self.context = context; self.commit = commit
        try reload()
    }
    func reload() throws {
        let values = try context.fetch(FetchDescriptor<ScheduleExceptionRecord>()).map { row in
            let value = try JSONDecoder().decode(ScheduleException.self, from: row.payload)
            try value.validate()
            guard value.id == row.id else { throw ScheduleExceptionError.invalidException }
            return value
        }
        guard Set(values.map(\.id)).count == values.count else { throw ScheduleExceptionError.duplicateIdentity }
        exceptions = values.sorted { $0.id < $1.id }
    }
    func upcoming(plan: WeeklyPlan, activationDate: Date, from: Date, limit: Int, workouts: [WorkoutSession]) throws -> [ScheduledPlanSession] {
        try ScheduleExceptionSchedule.upcoming(plan: plan, activationDate: activationDate, from: from,
                                               limit: limit, exceptions: exceptions, workouts: workouts)
    }
    func canStart(occurrenceID: String, plan: WeeklyPlan, activationDate: Date, workouts: [WorkoutSession], at date: Date = Date()) throws -> Bool {
        try ScheduleExceptionSchedule.resolve(occurrenceID: occurrenceID, plan: plan, activationDate: activationDate,
                                              exceptions: exceptions, workouts: workouts, asOf: date)?.canStart == true
    }
    @discardableResult
    func save(_ occurrence: ScheduleOccurrence, action: ScheduleExceptionAction, destination: LocalTrainingDay? = nil,
              note: String = "", plan: WeeklyPlan, planRevisionID: String, activationDate: Date,
              workouts: [WorkoutSession], pendingWatchOccurrenceIDs: Set<String> = [], at now: Date = Date()) -> Bool {
        do {
            let change = try ScheduleExceptionSchedule.change(occurrence, action: action, destination: destination, note: note,
                                                              plan: plan, planRevisionID: planRevisionID, activationDate: activationDate,
                                                              exceptions: exceptions, workouts: workouts, pendingWatchOccurrenceIDs: pendingWatchOccurrenceIDs, at: now)
            try Self.stage(change, context: context)
            try commit(context)
            // Publish observable success only after durable save.
            exceptions.removeAll { $0.id == change.id }
            exceptions.append(change); exceptions.sort { $0.id < $1.id }
            errorMessage = nil
            return true
        } catch {
            context.rollback()
            errorMessage = "Schedule change was not saved. \(error.localizedDescription)"
            return false
        }
    }
    private static func stage(_ change: ScheduleException, context: ModelContext) throws {
        try change.validate()
        let payload = try JSONEncoder().encode(change)
        if let row = try context.fetch(FetchDescriptor<ScheduleExceptionRecord>()).first(where: { $0.id == change.id }) { row.payload = payload }
        else { context.insert(ScheduleExceptionRecord(id: change.id, payload: payload)) }
    }

    static func backupRecords(context: ModelContext) throws -> [BackupRecord] {
        try context.fetch(FetchDescriptor<ScheduleExceptionRecord>()).map { row in
            let change = try JSONDecoder().decode(ScheduleException.self, from: row.payload)
            guard row.id == change.id else { throw ScheduleExceptionError.invalidException }
            try change.validate()
            return try backupRecord(change)
        }
    }
    static func validateBackupRecord(_ record: BackupRecord) throws -> Bool {
        guard record.payload["nativeType"]?.string == "schedule-exception" else { return false }
        guard record.payload["version"] == .number(1), let value = record.payload["value"] else {
            throw BackupError.invalid("Unsupported schedule exception backup version.")
        }
        let change = try value.decode(ScheduleException.self)
        try change.validate()
        guard UUID(uuidString: change.planRevisionID)?.uuidString == change.planRevisionID,
              try backupRecord(change) == record else {
            throw BackupError.invalid("A schedule exception contains unknown fields or inconsistent identity/dependencies.")
        }
        return true
    }
    static func applyBackupRecord(_ record: BackupRecord, context: ModelContext) throws {
        guard try validateBackupRecord(record), let value = record.payload["value"] else {
            throw BackupError.invalid("This is not a supported schedule exception.")
        }
        try stage(value.decode(ScheduleException.self), context: context)
    }
    static func validateBackupRelationships(_ records: [BackupRecord]) throws {
        let changes = try records.filter { $0.payload["nativeType"]?.string == "schedule-exception" }.map { record in
            _ = try validateBackupRecord(record)
            return try record.payload["value"]!.decode(ScheduleException.self)
        }
        let workouts = try records.filter { $0.payload["nativeType"]?.string == "workout" }.map {
            try $0.payload["value"]!.decode(WorkoutSession.self)
        }
        for record in records where record.payload["nativeType"]?.string == "schedule-exception" {
            _ = try validateBackupRecord(record)
            let change = try record.payload["value"]!.decode(ScheduleException.self)
            guard let revision = records.first(where: { $0.category == .plans && $0.id == change.planRevisionID && $0.payload["nativeType"]?.string == "plan" }),
                  let planValue = revision.payload["value"]?["plan"],
                  let activationValue = revision.payload["value"]?["activationDate"] else {
                throw BackupError.invalid("A schedule exception requires its original native plan revision.")
            }
            let plan = try planValue.decode(WeeklyPlan.self), activation = try activationValue.decode(Date.self)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: change.originalDay.timeZoneID)!
            guard plan.id == change.planID, plan.days.flatMap(\.sessions).contains(where: { $0.id == change.sessionID }),
                  let occurrence = try ScheduleExceptionSchedule.resolve(occurrenceID: change.id, plan: plan, activationDate: activation,
                                                                         exceptions: changes, workouts: workouts, asOf: change.updatedAt, calendar: calendar),
                  occurrence.originalDay == change.originalDay else {
                throw BackupError.invalid("A schedule exception does not belong to its referenced plan and activation date.")
            }
            if change.action == .rescheduled || change.action == .restored {
                let slots = try ScheduleExceptionSchedule.occurrences(plan: plan, activationDate: activation,
                    from: occurrence.scheduled.date, through: occurrence.scheduled.date, exceptions: changes,
                    workouts: workouts, asOf: change.updatedAt, calendar: calendar)
                guard !slots.contains(where: { $0.id != change.id && $0.scheduled.session.id == change.sessionID && ![.skipped, .missed].contains($0.status) }) else {
                    throw BackupError.invalid("A restored schedule would place two occurrences of the same session on one date.")
                }
            }
        }
    }
    private static func backupRecord(_ change: ScheduleException) throws -> BackupRecord {
        .init(id: "schedule:\(change.id)", category: .settings,
              payload: .object(["nativeType": .string("schedule-exception"), "version": .number(1), "value": try .encode(change)]),
              references: [.init(category: .plans, id: change.planRevisionID)])
    }
}
