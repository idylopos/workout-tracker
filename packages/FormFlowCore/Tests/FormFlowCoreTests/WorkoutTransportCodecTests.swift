import XCTest
@testable import FormFlowCore

final class WorkoutTransportCodecTests: XCTestCase {
    private struct Payload: Codable, Equatable { let value: String }

    func testEveryRemoteMessageKindHasVersionedRoundTripAndLegacyCompatibility() throws {
        let payload = Payload(value: "unchanged source")
        for kind in WorkoutTransportKind.allCases {
            let data = try WorkoutTransportCodec.encode(payload, kind: kind)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["schemaVersion"] as? Int, 1)
            XCTAssertEqual(json["kind"] as? String, kind.rawValue)
            XCTAssertEqual(try WorkoutTransportCodec.decode(Payload.self, from: data, kind: kind), payload)
            XCTAssertEqual(try WorkoutTransportCodec.decode(Payload.self, from: JSONEncoder().encode(payload), kind: kind), payload)
        }
    }

    func testFutureVersionRejectsBeforeDecodingUnknownBodyForEveryMessageKind() throws {
        for kind in WorkoutTransportKind.allCases {
            let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "kind": kind.rawValue, "payload": ["unknownFutureField": true]])
            XCTAssertThrowsError(try WorkoutTransportCodec.decode(Payload.self, from: data, kind: kind)) {
                XCTAssertEqual($0 as? WorkoutProtocolCompatibilityError, .init(component: "device message", version: 2))
            }
        }
        let declaredFutureLegacy = Data(#"{"schemaVersion":2,"value":"cannot use legacy fallback"}"#.utf8)
        XCTAssertThrowsError(try WorkoutTransportCodec.decode(Payload.self, from: declaredFutureLegacy, kind: .remoteStart))
    }

    func testMissingEnvelopeVersionAndMismatchedKindCannotBecomeLegacyPayload() throws {
        let missing = Data(#"{"kind":"remoteStart","payload":{"value":"no version"}}"#.utf8)
        XCTAssertThrowsError(try WorkoutTransportCodec.decode(Payload.self, from: missing, kind: .remoteStart))
        let data = try WorkoutTransportCodec.encode(Payload(value: "intent"), kind: .remoteStart)
        XCTAssertThrowsError(try WorkoutTransportCodec.decode(Payload.self, from: data, kind: .remoteStartProbe))
    }

    func testLegacyOperationGetsVersionOneAndFutureVersionNeverDecodesItsCommand() throws {
        let op = WorkoutOperation(sessionID: UUID(), originDeviceID: "watch", syncGeneration: "generation",
            expectedRevision: 0, command: .pause, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(op)) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        json.removeValue(forKey: "schemaVersion")
        XCTAssertEqual(try JSONDecoder().decode(WorkoutOperation.self, from: JSONSerialization.data(withJSONObject: json)), op)
        json["schemaVersion"] = 99
        json["command"] = ["futureCommand": ["unknown": true]]
        XCTAssertThrowsError(try JSONDecoder().decode(WorkoutOperation.self, from: JSONSerialization.data(withJSONObject: json))) {
            XCTAssertEqual($0 as? WorkoutProtocolCompatibilityError, .init(component: "workout operation", version: 99))
        }
    }

    func testNestedFutureOperationCannotBeAcknowledgedAsCurrentSnapshotOrProposal() throws {
        let session = try fixture()
        let op = WorkoutOperation(sessionID: session.id, originDeviceID: session.ownerDeviceID,
            syncGeneration: session.syncGeneration, expectedRevision: 0, command: .pause,
            createdAt: session.startedAt, schemaVersion: 2)
        let proposal = try WorkoutTransportCodec.encode(op, kind: .workoutProposal)
        XCTAssertThrowsError(try WorkoutTransportCodec.decode(WorkoutOperation.self, from: proposal, kind: .workoutProposal))
        let result = WorkoutReducer.apply(op, to: session, at: session.startedAt)
        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.session, session)
        XCTAssertEqual(result.issues.first?.code, "updateRequired")
        var invalid = session; invalid.pendingOperations = [op]
        XCTAssertFalse(WorkoutSessionValidator.validate(invalid).isEmpty)
        XCTAssertThrowsError(try JSONDecoder().decode(WorkoutSession.self, from: JSONEncoder().encode(invalid)))
    }

    private func fixture() throws -> WorkoutSession {
        let plan = try XCTUnwrap(PlanImporter.importText(PlanContract.exampleJSON).plan)
        return try WorkoutSession.start(prescription: XCTUnwrap(plan.days.flatMap(\.sessions).first), planID: plan.id,
            planRevisionID: "revision", ownerDeviceID: "watch", at: Date(timeIntervalSince1970: 1_800_000_000),
            timeZoneIdentifier: "UTC", syncGeneration: "generation")
    }
}
