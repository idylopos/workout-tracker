import Foundation
import CryptoKit

enum WorkoutPreparation {
    static func sets(for exercise: PlanExercise, makeID: () -> UUID) -> [WorkoutSet] {
        (0..<exercise.target.sets).map { _ in
            let setID = makeID()
            let intervals: [WorkoutInterval]? = exercise.intervals.map { blocks in
                blocks.flatMap { block in
                    (1...block.repeatCount).flatMap { repetition in
                        block.steps.map { WorkoutInterval(id: makeID(), blockID: block.id,
                            repetition: repetition, prescription: $0) }
                    }
                }
            }
            return WorkoutSet(id: setID, target: exercise.target, intervals: intervals)
        }
    }

    /// Replay of a durable operation must allocate exactly the same identities on every device.
    static func deterministicID(operationID: UUID, ordinal: Int) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("formflow:\(operationID.uuidString):\(ordinal)".utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
            (bytes[6] & 0x0f) | 0x80, bytes[7], (bytes[8] & 0x3f) | 0x80,
            bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
