import XCTest
import SwiftData
import FormFlowCore
@testable import FormFlowiOS

@MainActor
final class AppStoreTests: XCTestCase {
    func testSavedPromptFromEarlierTemplateRequiresRebuildAndKeepsHistory() throws {
        let container = try makeContainer()
        let store = try makeStore(container)
        store.profile.goal = "General fitness"
        store.profile.strengthExperience = "New to this"
        store.profile.cardioExperience = "Not sure"
        store.profile.availableDays = [.monday]
        store.profile.trainingLocation = "Home"
        store.profile.equipment = "Bodyweight only"
        store.generatePrompt()
        XCTAssertFalse(store.isPromptOutdated)
        XCTAssertFalse(try makeStore(container).isPromptOutdated)

        let row = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WorkspaceRecord>()).first)
        var saved = try JSONDecoder().decode(WorkspaceSnapshot.self, from: row.payload)
        saved.promptTemplateVersion = nil // Represents the development format before templates were versioned.
        let oldText = saved.promptDraft
        row.payload = try JSONEncoder().encode(saved)
        try container.mainContext.save()
        let relaunched = try makeStore(container)
        XCTAssertTrue(relaunched.isPromptOutdated)
        XCTAssertEqual(relaunched.promptDraft, oldText)
        relaunched.generatePrompt()
        XCTAssertFalse(relaunched.isPromptOutdated)
        XCTAssertEqual(relaunched.savedPromptHistory.last?.text, oldText)
        XCTAssertNil(relaunched.savedPromptHistory.last?.templateVersion)
        XCTAssertFalse(try makeStore(container).isPromptOutdated)
    }

    func testDraftAndPrivacyChoicesSurviveStoreRecreation() throws {
        let container = try makeContainer()
        let store = try makeStore(container)
        store.profile.goal = "Build strength"
        store.profile.limitationsAnswer = .preferNotToSay
        store.profile.includeBioInPrompt = false
        store.onboardingStep = 4
        store.importText = "Unfinished response"
        store.saveDraft()
        XCTAssertNil(store.errorMessage)
        let restored = try makeStore(container)
        XCTAssertEqual(restored.profile, store.profile)
        XCTAssertEqual(restored.onboardingStep, 4)
        XCTAssertEqual(restored.importText, "Unfinished response")
        XCTAssertNil(restored.activePlan)
    }

    func testActivationSavesRevisionAndRestoresSchedule() throws {
        let container = try makeContainer()
        let store = try makeStore(container)
        store.loadExample()
        let plan = try XCTUnwrap(store.importResult?.plan)
        let start = Calendar.current.startOfDay(for: Date())
        store.activatePlan(plan, startDate: start)
        XCTAssertNil(store.errorMessage)
        let restored = try makeStore(container)
        XCTAssertEqual(restored.activePlan, plan)
        XCTAssertEqual(restored.activationDate, start)
        XCTAssertEqual(restored.planRevision, 1)
        XCTAssertFalse(restored.upcomingSessions(from: start, limit: 2).isEmpty)
    }

    func testChangedResponseCannotActivatePreviouslyReviewedPlan() throws {
        let container = try makeContainer()
        let store = try makeStore(container)
        store.loadExample()
        let oldCandidate = try XCTUnwrap(store.importResult?.plan)
        store.importText = "This is no longer the reviewed plan."
        store.activatePlan(oldCandidate, startDate: Date())
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.activePlan)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<ActivatedPlanRecord>()), 0)
    }

    func testReplacementPreservesPreviousActivationRevision() throws {
        let container = try makeContainer()
        let store = try makeStore(container)
        store.loadExample()
        let first = try XCTUnwrap(store.importResult?.plan)
        store.activatePlan(first, startDate: Date())
        var second = first
        second.name = "An updated training week"
        store.importText = String(decoding: try JSONEncoder().encode(second), as: UTF8.self)
        store.inspectImport()
        store.activatePlan(second, startDate: Date(), decision: .init(review: try store.reviewPlanImport(second), action: .newRevision))
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.activePlan?.name, second.name)
        let revisions = try container.mainContext.fetch(FetchDescriptor<ActivatedPlanRecord>())
        XCTAssertEqual(revisions.count, 2)
        let original = try XCTUnwrap(revisions.first { $0.sequence == 1 })
        XCTAssertEqual(try JSONDecoder().decode(WeeklyPlan.self, from: original.planData), first)
    }

    func testInvalidImportLeavesActivePlanUnchanged() throws {
        let container = try makeContainer()
        let store = try makeStore(container)
        store.loadExample()
        let plan = try XCTUnwrap(store.importResult?.plan)
        store.activatePlan(plan, startDate: Date())
        store.importText = "{\"schemaVersion\":999}"
        store.inspectImport()
        XCTAssertFalse(try XCTUnwrap(store.importResult).canActivate)
        XCTAssertEqual(store.activePlan, plan)
        XCTAssertEqual(try makeStore(container).activePlan, plan)
    }

    func testCorruptWorkspaceIsPreserved() throws {
        let container = try makeContainer()
        let data = Data("not valid saved data".utf8)
        container.mainContext.insert(WorkspaceRecord(payload: data))
        try container.mainContext.save()
        XCTAssertThrowsError(try makeStore(container))
        let record = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WorkspaceRecord>()).first)
        XCTAssertEqual(record.payload, data)
    }

    func testChangedPrivacyChoiceInvalidatesSavedPromptAcrossRelaunch() throws {
        let container = try makeContainer()
        let store = try makeStore(container)
        store.profile.goal = "General fitness"
        store.profile.strengthExperience = "New to this"
        store.profile.cardioExperience = "Not sure"
        store.profile.availableDays = [.monday]
        store.profile.trainingLocation = "Home"
        store.profile.equipment = "Bodyweight only"
        store.profile.includeBioInPrompt = true
        store.profile.height = "PRIVATE_HEIGHT_FOR_TEST"
        store.generatePrompt()
        XCTAssertFalse(store.isPromptOutdated)
        XCTAssertTrue(store.promptDraft.contains("PRIVATE_HEIGHT_FOR_TEST"))
        store.profile.includeBioInPrompt = false
        store.saveDraft()
        let restored = try makeStore(container)
        XCTAssertTrue(restored.isPromptOutdated)
        restored.generatePrompt()
        XCTAssertFalse(restored.isPromptOutdated)
        XCTAssertFalse(restored.promptDraft.contains("PRIVATE_HEIGHT_FOR_TEST"))
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = WorkspaceSchema.current
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    }

    private func makeStore(_ container: ModelContainer) throws -> AppStore {
        try AppStore(context: ModelContext(container), bridge: PlanBridge(isEnabled: false), healthEnabled: false)
    }
}
