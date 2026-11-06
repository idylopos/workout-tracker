import Foundation
import FormFlowCore

struct SavedPlanRevision: Identifiable, Equatable {
    let id: String
    let sequence: Int
    let createdAt: Date
    let activationDate: Date
    let plan: WeeklyPlan
    let sourceText: String
}

struct PlanImportReview: Equatable {
    let sourceText: String
    let candidate: WeeklyPlan
    let sourceVersion: Int?
    let matches: [SavedPlanRevision]
    let activeRevisionID: String?
    var exactMatches: [SavedPlanRevision] { matches.filter { $0.plan == candidate } }
    var requiresChoice: Bool { !matches.isEmpty }
    var canMakeIndependentCopy: Bool { sourceVersion == 2 }
}

enum PlanImportAction: String, CaseIterable {
    case keepExisting, newRevision, independentCopy
    var label: String {
        switch self {
        case .keepExisting: "Keep the existing schedule"
        case .newRevision: "Use as a new revision"
        case .independentCopy: "Create an independent copy"
        }
    }
}

struct PlanImportDecision: Equatable {
    let review: PlanImportReview
    let action: PlanImportAction
    let copyPlanID: String?
    init(review: PlanImportReview, action: PlanImportAction) {
        self.review = review; self.action = action
        copyPlanID = action == .independentCopy
            ? "\(review.candidate.id.prefix(45))-copy-\(UUID().uuidString.lowercased().prefix(12))" : nil
    }
}

enum PlanRevisionReviewError: LocalizedError {
    case changed, invalidSavedRevision, choiceRequired, copyUnavailable
    var errorDescription: String? {
        switch self {
        case .changed: "The response or saved plan revisions changed after this choice. Review the current matches and choose again."
        case .invalidSavedRevision: "This saved plan revision could not be read. Its original data has been preserved."
        case .choiceRequired: "This plan matches a saved plan. Choose whether to keep the existing schedule, create a new revision, or make an independent copy."
        case .copyUnavailable: "Convert this legacy plan to the current format and review it before making an independent copy."
        }
    }
}
