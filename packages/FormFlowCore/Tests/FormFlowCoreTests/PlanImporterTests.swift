import Foundation
import XCTest
@testable import FormFlowCore

final class PlanImporterTests: XCTestCase {
    private func example() throws -> WeeklyPlan {
        try XCTUnwrap(PlanImporter.importText(PlanContract.exampleJSON).plan)
    }

    private func json(_ plan: WeeklyPlan) throws -> String {
        try XCTUnwrap(String(data: JSONEncoder().encode(plan), encoding: .utf8))
    }

    private func objectJSON(_ object: [String: Any]) throws -> String {
        try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8))
    }

    private func object() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(PlanContract.exampleJSON.utf8)) as? [String: Any])
    }

    func testBundledExampleAndCanonicalV2RoundTrip() throws {
        let result = PlanImporter.importText(PlanContract.exampleJSON)
        XCTAssertTrue(result.canActivate, result.issues.description)
        XCTAssertTrue(result.issues.isEmpty)
        let plan = try XCTUnwrap(result.plan)
        let roundTrip = PlanImporter.importText(try json(plan))
        XCTAssertTrue(roundTrip.canActivate)
        XCTAssertEqual(roundTrip.plan, plan)
    }

    func testSchemaCoversEveryMeasurementAndRejectsAdditionalFields() throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(PlanContract.schemaJSON.utf8)) as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let definitions = try XCTUnwrap(schema["$defs"] as? [String: Any])
        let exercise = try XCTUnwrap(definitions["exercise"] as? [String: Any])
        let properties = try XCTUnwrap(exercise["properties"] as? [String: Any])
        let measurement = try XCTUnwrap(properties["measurement"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(measurement["enum"] as? [String])), Set(MeasurementKind.allCases.map(\.rawValue)))
        XCTAssertEqual((exercise["allOf"] as? [Any])?.count, MeasurementKind.allCases.count + 1, "Measurement constraints plus the interval outer-set constraint.")
    }

    func testOneFencedObjectAndProseProduceSamePlan() {
        let raw = PlanImporter.importText(PlanContract.exampleJSON)
        for text in ["```json\n\(PlanContract.exampleJSON)\n```", "Here is the plan:\n```json\n\(PlanContract.exampleJSON)\n```\nReview it first.", "Here is the plan:\n\(PlanContract.exampleJSON)"] {
            let result = PlanImporter.importText(text)
            XCTAssertTrue(result.canActivate, result.issues.description)
            XCTAssertEqual(result.plan, raw.plan)
        }
    }

    func testAmbiguousIncompleteAndTrailingContentDoNotActivate() {
        let valid = PlanContract.exampleJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        for text in [valid + valid, "```json\n\(valid)\n```\n```json\n\(valid)\n```", String(valid.dropLast()), valid + "}", valid + "17", "```json\n\(valid) trailing text\n```", "[\(valid)]", "```swift\n\(valid)\n```"] {
            XCTAssertFalse(PlanImporter.importText(text).canActivate, text)
        }
    }

    func testBracesAndEscapedQuotesInsideInstructionsAreNotCandidates() throws {
        var plan = try example()
        plan.instructions = "A cue with {braces}, a \"quote\", a \\ slash, and a ``` fence."
        let result = PlanImporter.importText(try json(plan))
        XCTAssertTrue(result.canActivate)
        XCTAssertEqual(result.plan?.instructions, plan.instructions)
    }

    func testDuplicateKeysIncludingEscapedSpellingsAreRejected() {
        for text in [#"{"schemaVersion":2,"schemaVersion":1,"days":{}}"#, #"{"id":"one","\u0069d":"two","schemaVersion":2}"#] {
            let result = PlanImporter.importText(text)
            XCTAssertFalse(result.canActivate)
            XCTAssertTrue(result.issues.contains { $0.message.contains("repeats the key") })
        }
    }

    func testUTF8ByteLimitIsEnforcedBeforeParsing() {
        let result = PlanImporter.importText(String(repeating: "é", count: PlanImporter.maximumBytes / 2 + 1))
        XCTAssertFalse(result.canActivate)
        XCTAssertTrue(result.issues.contains { $0.message.contains("1 MiB") })
    }

    func testBackupsAndUnsupportedVersionsHaveActionableErrors() throws {
        let backup = PlanImporter.importText(#"{"version":1,"workoutLogs":{},"bodyLogs":[]}"#)
        XCTAssertFalse(backup.canActivate)
        XCTAssertTrue(backup.issues.contains { $0.message.contains("backup") })
        var plan = try example()
        plan.schemaVersion = 99
        let future = PlanImporter.importText(try json(plan))
        XCTAssertFalse(future.canActivate)
        XCTAssertEqual(future.issues.first?.path, "schemaVersion")
    }

    func testBooleansAreNotNumericVersionsOrTargets() throws {
        var value = try object()
        value["schemaVersion"] = true
        XCTAssertFalse(PlanImporter.importText(try objectJSON(value)).canActivate)
        let boolTarget = try json(example()).replacingOccurrences(of: "\"sets\":3", with: "\"sets\":true")
        XCTAssertFalse(PlanImporter.importText(boolTarget).canActivate)
    }

    func testUnknownPrescriptionFieldsAreNotSilentlyDiscarded() throws {
        var value = try object()
        value["intervals"] = [["work": 30, "recovery": 20]]
        let result = PlanImporter.importText(try objectJSON(value))
        XCTAssertFalse(result.canActivate)
        XCTAssertEqual(result.issues.first?.path, "intervals")
        let raw = try json(example())
        let nested = raw.replacingOccurrences(of: "\"target\":{", with: "\"target\":{\"pace\":5,")
        let nestedResult = PlanImporter.importText(nested)
        XCTAssertFalse(nestedResult.canActivate)
        XCTAssertTrue(nestedResult.issues.contains { $0.path.hasSuffix(".target.pace") })
    }

    func testIdentityRulesAllowSameExerciseAcrossDaysButNotDuplicateOccurrences() throws {
        var plan = try example()
        let exercise = plan.days[0].sessions[0].exercises[0]
        plan.days[1].sessions[0].exercises = [exercise]
        XCTAssertTrue(PlanImporter.importText(try json(plan)).canActivate)
        plan.days[0].sessions[0].exercises.append(exercise)
        let duplicateOccurrence = PlanImporter.importText(try json(plan))
        XCTAssertFalse(duplicateOccurrence.canActivate)
        XCTAssertTrue(duplicateOccurrence.issues.contains { $0.path.hasSuffix("instanceId") })
        plan.days[0].sessions[0].exercises.removeLast()
        plan.days[1].sessions[0].id = plan.days[0].sessions[0].id
        XCTAssertFalse(PlanImporter.importText(try json(plan)).canActivate)
        plan.days[1].sessions[0].id = "other"
        plan.days[1].weekday = plan.days[0].weekday
        XCTAssertFalse(PlanImporter.importText(try json(plan)).canActivate)
    }

    func testRequiredTargetsUnitsAndIncompatibleFieldsBlockActivation() throws {
        var plan = try example()
        plan.days[0].sessions[0].exercises[0].target.reps = nil
        XCTAssertFalse(PlanImporter.importText(try json(plan)).canActivate)
        plan = try example()
        plan.days[0].sessions[0].exercises[0].target.load = PlanQuantity(value: 20, unit: .km)
        XCTAssertFalse(PlanImporter.importText(try json(plan)).canActivate)
        plan = try example()
        plan.days[0].sessions[0].exercises[0].target.distance = QuantityRange(min: 10, max: 20, unit: .m)
        XCTAssertFalse(PlanImporter.importText(try json(plan)).canActivate)
        plan = try example()
        plan.days[0].sessions[0].exercises[0].target.effort = EffortTarget(kind: .rpe, min: 2, max: 3)
        XCTAssertFalse(PlanImporter.importText(try json(plan)).canActivate)
    }

    func testMeasurementMatrixAcceptsEverySupportedFamily() throws {
        for kind in MeasurementKind.allCases {
            var plan = try example()
            var target = ExerciseTarget(sets: 2, restSeconds: 30)
            switch kind {
            case .weightReps, .reps, .assistedReps: target.reps = RepRange(min: 5, max: 8)
            case .weightDistance, .distanceTime, .distance: target.distance = QuantityRange(min: 10, max: 20, unit: .m)
            case .duration, .durationCalories: target.duration = QuantityRange(min: 10, max: 20, unit: .min)
            case .completion: break
            }
            plan.days[0].sessions[0].exercises[0].measurement = kind
            plan.days[0].sessions[0].exercises[0].target = target
            let result = PlanImporter.importText(try json(plan))
            XCTAssertTrue(result.canActivate, "\(kind): \(result.issues)")
        }
    }

    func testBoundsAndReversedRangesBlockActivation() throws {
        var plan = try example()
        plan.days[0].sessions[0].exercises[0].target = ExerciseTarget(sets: 21, restSeconds: 901, reps: RepRange(min: 10, max: 8))
        let result = PlanImporter.importText(try json(plan))
        XCTAssertFalse(result.canActivate)
        for suffix in ["sets", "restSeconds", "reps"] { XCTAssertTrue(result.issues.contains { $0.path.hasSuffix(suffix) }) }
        plan = try example()
        plan.days[0].sessions = (1...4).map { index in
            var session = plan.days[0].sessions[0]; session.id = "session-\(index)"; return session
        }
        XCTAssertFalse(PlanImporter.importText(try json(plan)).canActivate)
        plan = try example()
        plan.days[0].sessions[0].exercises = (1...31).map { index in
            var exercise = plan.days[0].sessions[0].exercises[0]; exercise.instanceId = "exercise-\(index)"; return exercise
        }
        XCTAssertFalse(PlanImporter.importText(try json(plan)).canActivate)
    }

    func testUnsupportedPolicyIsPreservedWithManualWarning() throws {
        var plan = try example()
        let policy = PlanPolicyReference(id: "double-progression", version: 1, notes: "Requires review")
        plan.days[0].sessions[0].exercises[0].progressionPolicy = policy
        let result = PlanImporter.importText(try json(plan))
        XCTAssertTrue(result.canActivate)
        XCTAssertTrue(result.issues.contains { $0.severity == .warning && $0.message.contains("manual") })
        XCTAssertEqual(result.plan?.days[0].sessions[0].exercises[0].progressionPolicy, policy)
    }

    private func legacyJSON(exerciseCount: Int = 1) throws -> String {
        let exercise: [String: Any] = ["id":"carry", "name":"Suitcase carry", "prescription":"2 rounds of 20 metres per side", "sets":2, "rest":60, "measurement":"weight_distance", "category":"Strength", "guidance":["setup":"Stand tall.", "action":"Walk steadily.", "watch":"Stay comfortable.", "option":"Use less load."]]
        return try objectJSON(["schemaVersion":1, "id":"legacy-plan", "name":"Legacy plan", "description":"Original public description", "longRuns":["4.5 km", "4.8 km"], "longRunDay":"saturday", "days":["monday":["focus":"Carry practice", "estimate":"20–30 min", "sequenceNote":"Original session guidance", "warmup":["Easy walk"], "exercises":Array(repeating: exercise, count: exerciseCount)], "sunday":["exercises":[]]]])
    }

    func testLegacyPlanPreservesProseAndUnitsWithoutGuessingTargets() throws {
        let result = PlanImporter.importText(try legacyJSON())
        XCTAssertTrue(result.canActivate, result.issues.description)
        let plan = try XCTUnwrap(result.plan)
        let session = plan.days[0].sessions[0]
        let exercise = session.exercises[0]
        XCTAssertEqual(exercise.measurement, .weightDistance)
        XCTAssertNil(exercise.target.distance)
        XCTAssertEqual(exercise.target.sets, 2)
        XCTAssertEqual(session.estimatedMinutes, 0)
        XCTAssertTrue(exercise.instructions?.contains("20 metres per side") == true)
        XCTAssertTrue(exercise.instructions?.contains("Use less load") == true)
        XCTAssertTrue(session.instructions?.contains("20–30 min") == true)
        XCTAssertTrue(plan.instructions?.contains("4.8 km") == true)
        XCTAssertTrue(plan.days[1].sessions.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.severity == .warning && $0.message.contains("manual") })
        XCTAssertEqual(try JSONDecoder().decode(WeeklyPlan.self, from: JSONEncoder().encode(plan)), plan)
    }

    func testLegacyImportDoesNotTruncateFortyExercisesToV2CreationLimit() throws {
        let result = PlanImporter.importText(try legacyJSON(exerciseCount: 40))
        XCTAssertTrue(result.canActivate, result.issues.description)
        XCTAssertEqual(result.plan?.days[0].sessions[0].exercises.count, 40)
        XCTAssertEqual(Set(result.plan?.days[0].sessions[0].exercises.map(\.id) ?? []).count, 40)
    }

    func testLegacyUnknownDayAndFuturePrescriptionAreRejected() throws {
        let legacy = try legacyJSON()
        XCTAssertFalse(PlanImporter.importText(legacy.replacingOccurrences(of: "\"monday\"", with: "\"someday\"")).canActivate)
        XCTAssertFalse(PlanImporter.importText(legacy.replacingOccurrences(of: "\"sets\":2", with: "\"sets\":2,\"intervals\":[]")).canActivate)
        XCTAssertFalse(PlanImporter.importText(legacy.replacingOccurrences(of: "Stand tall.", with: "")).canActivate)
    }

    func testIncompleteRequiredFieldReportsItsPath() throws {
        var value = try object()
        value.removeValue(forKey: "name")
        let result = PlanImporter.importText(try objectJSON(value))
        XCTAssertFalse(result.canActivate)
        XCTAssertEqual(result.issues.first?.path, "name")
    }
}
