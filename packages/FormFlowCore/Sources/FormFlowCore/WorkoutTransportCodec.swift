import Foundation

public struct WorkoutProtocolCompatibilityError: Error, LocalizedError, Equatable, Sendable {
    public let component: String
    public let version: Int
    public init(component: String, version: Int) { self.component = component; self.version = version }
    public var errorDescription: String? {
        "Update Form / Flow on both devices. This \(component) uses unsupported version \(version); its data remains pending."
    }
}

public enum WorkoutTransportKind: String, Codable, Sendable, CaseIterable {
    case remoteStart, remoteStartProbe, workoutProposal, remoteStartResult, proposalResult
}

/// Checks the wire header before decoding its body. Unversioned development payloads
/// use the original v1 shape; a declared unsupported version never takes that fallback.
public enum WorkoutTransportCodec {
    public static let currentSchemaVersion = 1
    public static func encode<T: Encodable>(_ value: T, kind: WorkoutTransportKind) throws -> Data {
        try JSONEncoder().encode(Outgoing(schemaVersion: currentSchemaVersion, kind: kind, payload: value))
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data, kind: WorkoutTransportKind) throws -> T {
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data)
        if let version = header.schemaVersion, version != currentSchemaVersion {
            throw WorkoutProtocolCompatibilityError(component: "device message", version: version)
        }
        if header.isEnvelope {
            guard header.schemaVersion == currentSchemaVersion else {
                throw WorkoutProtocolCompatibilityError(component: "device message", version: header.schemaVersion ?? 0)
            }
            guard header.kind == kind.rawValue else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Device message kind does not match its transport."))
            }
            return try decoder.decode(Incoming<T>.self, from: data).payload
        }
        return try decoder.decode(T.self, from: data)
    }
    private struct Outgoing<T: Encodable>: Encodable {
        let schemaVersion: Int
        let kind: WorkoutTransportKind
        let payload: T
    }
    private struct Incoming<T: Decodable>: Decodable { let payload: T }
    private struct Header: Decodable {
        let schemaVersion: Int?
        let kind: String?
        let isEnvelope: Bool
        private enum CodingKeys: String, CodingKey { case schemaVersion, kind, payload }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion)
            kind = try values.decodeIfPresent(String.self, forKey: .kind)
            isEnvelope = values.contains(.payload) || values.contains(.kind)
        }
    }
}
