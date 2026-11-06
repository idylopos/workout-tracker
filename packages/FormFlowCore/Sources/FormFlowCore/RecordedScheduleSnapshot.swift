import Foundation

/// Minimal schedule occupancy, separate from recording-owner snapshots and previous actuals.
public struct RecordedScheduleOccurrence: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let state: WorkoutState
    public init(id: String, state: WorkoutState) { self.id = id; self.state = state }
}

public enum RecordedScheduleSnapshot {
    public static let maximumOccurrences = 50_000
    public static func build(workouts: [WorkoutSession], planID: String, syncGeneration: String) throws -> [RecordedScheduleOccurrence] {
        guard workouts.count <= maximumOccurrences else { throw WatchHistoryError.inputLimit }
        var records: [String: WorkoutState] = [:]
        for workout in workouts where workout.syncGeneration == syncGeneration && workout.planID == planID {
            guard let id = workout.scheduledSessionID else { continue }
            // Any recorded state occupies the slot. Prefer a nonterminal state for display if
            // legacy data contains more than one record, while preserving every full workout.
            if records[id].map({ priority(workout.state) > priority($0) }) ?? true { records[id] = workout.state }
        }
        let snapshot = records.map { RecordedScheduleOccurrence(id: $0.key, state: $0.value) }.sorted { $0.id < $1.id }
        guard validate(snapshot, planID: planID).isEmpty else { throw WatchHistoryError.invalidActuals }
        return snapshot
    }
    public static func validate(_ snapshot: [RecordedScheduleOccurrence], planID: String) -> [WorkoutIssue] {
        guard snapshot.count <= maximumOccurrences, Set(snapshot.map(\.id)).count == snapshot.count else {
            return [.init(code: "recordedScheduleInvalid", message: "Recorded schedule references are duplicated or exceed the supported size.")]
        }
        for record in snapshot {
            let parts = record.id.split(separator: ":", omittingEmptySubsequences: false)
            guard record.id.count <= 400, parts.count == 3, parts[0] == planID, !parts[2].isEmpty else {
                return [.init(code: "recordedScheduleInvalid", message: "A recorded occurrence belongs to another plan or has invalid identity.")]
            }
            let numbers = parts[1].split(separator: "-").compactMap { Int($0) }
            guard numbers.count == 3, (1...9999).contains(numbers[0]), (1...12).contains(numbers[1]), (1...31).contains(numbers[2]),
                  LocalTrainingDay.isValidDate(String(format: "%04d-%02d-%02d", numbers[0], numbers[1], numbers[2])) else {
                return [.init(code: "recordedScheduleInvalid", message: "A recorded occurrence has an invalid date.")]
            }
        }
        return []
    }
    private static func priority(_ state: WorkoutState) -> Int {
        switch state { case .active: 4; case .paused: 3; case .finished: 2; case .abandoned: 1 }
    }
}
