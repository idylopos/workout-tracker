import XCTest
import SwiftData
import FormFlowCore
@testable import FormFlowiOS

@MainActor
final class PlanRevisionReviewTests: XCTestCase {
    private func container() throws -> ModelContainer {
        let schema = WorkspaceSchema.current
        return try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }
    private func store(_ container: ModelContainer, commit: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws -> AppStore {
        try AppStore(context: ModelContext(container), bridge: PlanBridge(isEnabled: false), healthEnabled: false, commit: commit)
    }
    private func activated(_ store: AppStore) throws -> WeeklyPlan {
        store.loadExample()
        let plan = try XCTUnwrap(store.importResult?.plan)
        XCTAssertTrue(store.activatePlan(plan, startDate: Date()), store.errorMessage ?? "")
        return plan
    }

    func testExactAndFencedReimportRequireChoiceAndKeepingDoesNotCreateRevision() throws {
        let c = try container(), store = try store(c), plan = try activated(store), originalID = store.activePlanRevisionID
        store.importText = "Here is the plan:\n```json\n\(PlanContract.exampleJSON)\n```"
        store.inspectImport()
        let review = try store.reviewPlanImport(plan)
        XCTAssertTrue(review.requiresChoice)
        XCTAssertEqual(review.exactMatches.count, 1)
        XCTAssertEqual(review.exactMatches.first?.id, originalID)
        XCTAssertFalse(store.activatePlan(plan, startDate: Date()))
        XCTAssertEqual(store.activePlanRevisionID, originalID)
        XCTAssertTrue(store.activatePlan(plan, startDate: Date(), decision: .init(review: review, action: .keepExisting)))
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(try store.savedPlanRevisions().count, 1)
        XCTAssertEqual(store.activePlanRevisionID, originalID)
    }

    func testIndependentCopySeparatesScheduleAndConsentWithoutChangingHistory() throws {
        let c = try container(), store = try store(c), original = try activated(store)
        let originalRevision = try XCTUnwrap(store.activePlanRevisionID), session = original.days[0].sessions[0]
        let oldSchedule = try XCTUnwrap(store.upcomingSessions(from: Date(), limit: 1).first)
        XCTAssertTrue(store.startWorkout(session))
        let workout = try XCTUnwrap(store.currentWorkout)
        XCTAssertTrue(store.progression.saveEnrollment(planID: original.id, planRevisionID: originalRevision,
            session: session, exercise: session.exercises[0], configuration: .init(policy: BuiltInProgressionPolicy.strength.reference, optedIn: true)))
        let decision = PlanImportDecision(review: try store.reviewPlanImport(original), action: .independentCopy)
        XCTAssertTrue(store.activatePlan(original, startDate: Date(), decision: decision), store.errorMessage ?? "")
        let copy = try XCTUnwrap(store.activePlan), copyRevision = try XCTUnwrap(store.activePlanRevisionID)
        XCTAssertEqual(copy.id, decision.copyPlanID)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.days, original.days)
        XCTAssertNotEqual(store.upcomingSessions(from: Date(), limit: 1).first?.id, oldSchedule.id)
        XCTAssertNil(store.progression.configuration(planRevisionID: copyRevision, sessionID: session.id, exerciseInstanceID: session.exercises[0].instanceId))
        XCTAssertEqual(store.currentWorkout, workout)
        let records = try store.savedPlanRevisions()
        XCTAssertEqual(records.first { $0.id == originalRevision }?.plan, original)
        let savedCopy = try XCTUnwrap(records.first { $0.id == copyRevision })
        XCTAssertEqual(PlanImporter.importText(savedCopy.sourceText).plan, copy)
    }

    func testNewRevisionPreservesFrozenEarlierPrescriptionAndLibraryIsReadOnly() throws {
        let c = try container(), store = try store(c), original = try activated(store)
        let firstRevision = try XCTUnwrap(store.activePlanRevisionID)
        var revised = original
        revised.days[0].sessions[0].exercises[0].target.reps = .init(min: 3, max: 5)
        XCTAssertTrue(store.replaceImportedPlan(revised))
        let review = try store.reviewPlanImport(revised)
        XCTAssertTrue(review.exactMatches.isEmpty)
        XCTAssertEqual(review.matches.map(\.id), [firstRevision])
        XCTAssertTrue(store.activatePlan(revised, startDate: Date(), decision: .init(review: review, action: .newRevision)))
        let currentID = store.activePlanRevisionID
        let all = try store.savedPlanRevisions()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.last?.plan, original)
        XCTAssertEqual(all.first?.plan, revised)
        XCTAssertTrue(store.reviewSavedPlanRevision(firstRevision))
        XCTAssertEqual(store.activePlanRevisionID, currentID)
        XCTAssertEqual(store.activePlan, revised)
        XCTAssertEqual(PlanImporter.importText(store.importText).plan, original)
        XCTAssertNil(store.importResult, "A saved revision still needs the ordinary check and review flow.")
        XCTAssertEqual(try self.store(c).savedPlanRevisions(), all)
    }

    func testDecisionIsRejectedAfterSourceChangesEvenWhenPlanIsEquivalent() throws {
        let c = try container(), store = try store(c), plan = try activated(store)
        let choice = PlanImportDecision(review: try store.reviewPlanImport(plan), action: .independentCopy)
        store.importText += "\n"
        store.inspectImport()
        XCTAssertFalse(store.activatePlan(plan, startDate: Date(), decision: choice))
        XCTAssertEqual(try store.savedPlanRevisions().count, 1)
        XCTAssertEqual(store.activePlan, plan)
    }

    func testDecisionIsRejectedAfterAnotherRevisionChangesTheSavedMatches() throws {
        let c = try container(), store = try store(c), plan = try activated(store)
        let review = try store.reviewPlanImport(plan)
        let stale = PlanImportDecision(review: review, action: .independentCopy)
        XCTAssertTrue(store.activatePlan(plan, startDate: Date(), decision: .init(review: review, action: .newRevision)))
        XCTAssertFalse(store.activatePlan(plan, startDate: Date(), decision: stale))
        XCTAssertEqual(try store.savedPlanRevisions().count, 2)
        XCTAssertEqual(store.activePlan?.id, plan.id)
    }

    func testLegacyRevisionCanBeReviewedWithoutFabricatingTypedCopyTargets() throws {
        let c = try container(), store = try store(c)
        store.importText = #"{"schemaVersion":1,"id":"legacy-plan","name":"Legacy plan","days":{"monday":{"focus":"Carry practice","estimate":"20–30 min","exercises":[{"id":"carry","name":"Suitcase carry","prescription":"2 rounds of 20 metres per side","sets":2,"rest":60,"measurement":"weight_distance","category":"Strength"}]}}}"#
        store.inspectImport()
        let plan = try XCTUnwrap(store.importResult?.plan)
        XCTAssertTrue(store.activatePlan(plan, startDate: Date()), store.errorMessage ?? "")
        let revisionID = try XCTUnwrap(store.activePlanRevisionID)
        let review = try store.reviewPlanImport(plan)
        XCTAssertFalse(review.canMakeIndependentCopy)
        XCTAssertFalse(store.activatePlan(plan, startDate: Date(), decision: .init(review: review, action: .independentCopy)))
        XCTAssertEqual(try store.savedPlanRevisions().count, 1)
        XCTAssertTrue(store.reviewSavedPlanRevision(revisionID))
        store.inspectImport()
        XCTAssertEqual(store.importResult?.sourceVersion, 1)
        XCTAssertNil(store.importResult?.plan?.days[0].sessions[0].exercises[0].target.distance)
    }

    func testIndependentCopyCommitFailurePreservesOriginalPlanAndDraftHistory() throws {
        let c = try container(), originalStore = try store(c), original = try activated(originalStore)
        let previous = try originalStore.savedPlanRevisions(), previousDrafts = try originalStore.savedPlanDrafts().count
        let failing = try store(c) { _ in throw NSError(domain: "PlanCopy", code: 1) }
        let review = try failing.reviewPlanImport(original)
        XCTAssertFalse(failing.activatePlan(original, startDate: Date(), decision: .init(review: review, action: .independentCopy)))
        XCTAssertEqual(failing.activePlan, original)
        let reopened = try store(c)
        XCTAssertEqual(try reopened.savedPlanRevisions(), previous)
        XCTAssertEqual(try reopened.savedPlanDrafts().count, previousDrafts)
    }
}
