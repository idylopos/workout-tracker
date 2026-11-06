import XCTest
@testable import FormFlowCore

final class PlanConstraintReviewTests: XCTestCase {
    private func plan() throws -> WeeklyPlan { try XCTUnwrap(PlanImporter.importText(PlanContract.exampleJSON).plan) }

    func testSuppliedDaysStillWarnWhenOtherEssentialsAreMissing() throws {
        var profile = TrainingProfile(); profile.availableDays = [.sunday]
        XCTAssertFalse(profile.canGeneratePrompt)
        let warnings = PlanConstraintReview.issues(plan: try plan(), profile: profile)
        XCTAssertTrue(warnings.contains { $0.path == "Monday" })
        XCTAssertTrue(warnings.allSatisfy { $0.severity == .warning })
    }

    func testUntouchedProfileDoesNotInventTimeOrDayConstraints() throws {
        var plan = try plan(); plan.days[0].sessions[0].estimatedMinutes = 90
        XCTAssertEqual(PlanConstraintReview.issues(plan: plan, profile: TrainingProfile()), [])
        var profile = TrainingProfile(); profile.hasReviewedAvailability = true
        XCTAssertFalse(profile.canGeneratePrompt)
        XCTAssertTrue(PlanConstraintReview.issues(plan: plan, profile: profile).contains { $0.message.contains("45 minutes") })
    }

    func testEnteredBudgetAndExplicitNoEquipmentAreCheckedIndependently() throws {
        var profile = TrainingProfile(); profile.sessionMinutes = 20; profile.equipment = "Bodyweight / no equipment"
        let warnings = PlanConstraintReview.issues(plan: try plan(), profile: profile)
        XCTAssertTrue(warnings.contains { $0.message.contains("20 minutes") })
        XCTAssertTrue(warnings.contains { $0.message.contains("bodyweight / no equipment") })
        profile.equipment = "Some equipment; ask me for details"
        XCTAssertFalse(PlanConstraintReview.issues(plan: try plan(), profile: profile).contains { $0.message.contains("equipment") })
    }

    func testUnknownEstimateAndBodyweightEquipmentDoNotCreateMismatch() throws {
        var plan = try plan()
        for day in plan.days.indices {
            for session in plan.days[day].sessions.indices {
                plan.days[day].sessions[session].estimatedMinutes = 0
                for exercise in plan.days[day].sessions[session].exercises.indices {
                    plan.days[day].sessions[session].exercises[exercise].equipment = ["Bodyweight"]
                }
            }
        }
        var profile = TrainingProfile(); profile.hasReviewedAvailability = true; profile.equipment = "Bodyweight / no equipment"
        XCTAssertEqual(PlanConstraintReview.issues(plan: plan, profile: profile), [])
    }

    func testAvailabilityProvenanceRoundTripsAndOldProfilePayloadStaysCompatible() throws {
        var profile = TrainingProfile(); profile.availableDays = [.monday]
        let oldData = try JSONEncoder().encode(profile)
        XCTAssertFalse(String(decoding: oldData, as: UTF8.self).contains("hasReviewedAvailability"))
        XCTAssertEqual(try JSONDecoder().decode(TrainingProfile.self, from: oldData), profile)
        profile.hasReviewedAvailability = true
        XCTAssertEqual(try JSONDecoder().decode(TrainingProfile.self, from: JSONEncoder().encode(profile)), profile)
    }
}
