import Foundation

public enum UnitPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case metric, imperial
    public var id: String { rawValue }
    public var label: String { self == .metric ? "Metric (kg, km)" : "Imperial (lb, mi)" }
}

public enum LimitationsAnswer: String, Codable, CaseIterable, Identifiable, Sendable {
    case unanswered, none, reported, preferNotToSay
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .unanswered: "Not answered yet"
        case .none: "No known limitations"
        case .reported: "I have limitations to describe"
        case .preferNotToSay: "Prefer not to share"
        }
    }
}

public enum TrainingProfileRequirement: String, Identifiable, Sendable {
    case goal, goalDescription, strengthExperience, cardioExperience, availableDays
    case sessionLength, trainingLocation, equipment, limitationsDetails
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .goal: "Your main goal"
        case .goalDescription: "A description of your goal"
        case .strengthExperience: "Your strength training experience"
        case .cardioExperience: "Your cardio experience"
        case .availableDays: "At least one available day"
        case .sessionLength: "A session length between 10 and 180 minutes"
        case .trainingLocation: "Where you train"
        case .equipment: "Your available equipment (or bodyweight only)"
        case .limitationsDetails: "A description of your limitations, or choose not to share"
        }
    }
}

/// Personal context lives separately from an imported, shareable training plan.
public struct TrainingProfile: Codable, Equatable, Sendable {
    public var goal = ""
    public var secondaryGoals = ""
    public var goalTimeframe = ""
    public var strengthExperience = ""
    public var cardioExperience = ""
    public var recentRoutine = ""
    public var currentCapabilities = ""
    public var trainingLocation = ""
    public var equipment = ""
    public var limitations = ""
    public var clinicianInstructions = ""
    public var ageRange = ""
    public var height = ""
    public var weight = ""
    public var usualSleep = ""
    public var otherActivity = ""
    public var preferences = ""
    public var dislikes = ""
    public var availableDays: [Weekday] = []
    public var sessionMinutes = 45
    public var hasReviewedAvailability = false
    public var units: UnitPreference = .metric
    public var limitationsAnswer: LimitationsAnswer = .unanswered
    public var includeLimitationsInPrompt = false
    public var includeClinicianInstructionsInPrompt = false
    public var includeAgeRangeInPrompt = false
    public var includeHeightInPrompt = false
    public var includeWeightInPrompt = false
    public var includeSleepInPrompt = false

    /// Compatibility convenience for callers from the first native slice.
    /// The UI exposes each sensitive field separately.
    public var includeBioInPrompt: Bool {
        get { includeAgeRangeInPrompt && includeHeightInPrompt && includeWeightInPrompt && includeSleepInPrompt }
        set {
            includeAgeRangeInPrompt = newValue
            includeHeightInPrompt = newValue
            includeWeightInPrompt = newValue
            includeSleepInPrompt = newValue
        }
    }

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case goal, secondaryGoals, goalTimeframe, strengthExperience, cardioExperience, recentRoutine
        case currentCapabilities, trainingLocation, equipment, limitations, clinicianInstructions
        case ageRange, height, weight, usualSleep, otherActivity, preferences, dislikes
        case availableDays, sessionMinutes, hasReviewedAvailability, units, limitationsAnswer
        case includeLimitationsInPrompt, includeBioInPrompt, includeClinicianInstructionsInPrompt
        case includeAgeRangeInPrompt, includeHeightInPrompt, includeWeightInPrompt, includeSleepInPrompt
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) throws -> String { try c.decodeIfPresent(String.self, forKey: key) ?? "" }
        goal = try text(.goal); secondaryGoals = try text(.secondaryGoals); goalTimeframe = try text(.goalTimeframe)
        strengthExperience = try text(.strengthExperience); cardioExperience = try text(.cardioExperience)
        recentRoutine = try text(.recentRoutine); currentCapabilities = try text(.currentCapabilities)
        trainingLocation = try text(.trainingLocation); equipment = try text(.equipment)
        limitations = try text(.limitations); clinicianInstructions = try text(.clinicianInstructions)
        ageRange = try text(.ageRange); height = try text(.height); weight = try text(.weight)
        usualSleep = try text(.usualSleep); otherActivity = try text(.otherActivity)
        preferences = try text(.preferences); dislikes = try text(.dislikes)
        availableDays = try c.decodeIfPresent([Weekday].self, forKey: .availableDays) ?? []
        sessionMinutes = try c.decodeIfPresent(Int.self, forKey: .sessionMinutes) ?? 45
        hasReviewedAvailability = try c.decodeIfPresent(Bool.self, forKey: .hasReviewedAvailability) ?? false
        units = try c.decodeIfPresent(UnitPreference.self, forKey: .units) ?? .metric
        limitationsAnswer = try c.decodeIfPresent(LimitationsAnswer.self, forKey: .limitationsAnswer) ?? .unanswered
        let oldBio = try c.decodeIfPresent(Bool.self, forKey: .includeBioInPrompt) ?? false
        includeLimitationsInPrompt = try c.decodeIfPresent(Bool.self, forKey: .includeLimitationsInPrompt) ?? false
        // Earlier versions grouped clinician instructions with limitations. Preserve that exact consent.
        includeClinicianInstructionsInPrompt = try c.decodeIfPresent(Bool.self, forKey: .includeClinicianInstructionsInPrompt) ?? includeLimitationsInPrompt
        includeAgeRangeInPrompt = try c.decodeIfPresent(Bool.self, forKey: .includeAgeRangeInPrompt) ?? oldBio
        includeHeightInPrompt = try c.decodeIfPresent(Bool.self, forKey: .includeHeightInPrompt) ?? oldBio
        includeWeightInPrompt = try c.decodeIfPresent(Bool.self, forKey: .includeWeightInPrompt) ?? oldBio
        includeSleepInPrompt = try c.decodeIfPresent(Bool.self, forKey: .includeSleepInPrompt) ?? oldBio
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        for (key, value) in [CodingKeys.goal: goal, .secondaryGoals: secondaryGoals, .goalTimeframe: goalTimeframe,
                             .strengthExperience: strengthExperience, .cardioExperience: cardioExperience,
                             .recentRoutine: recentRoutine, .currentCapabilities: currentCapabilities,
                             .trainingLocation: trainingLocation, .equipment: equipment, .limitations: limitations,
                             .clinicianInstructions: clinicianInstructions, .ageRange: ageRange, .height: height,
                             .weight: weight, .usualSleep: usualSleep, .otherActivity: otherActivity,
                             .preferences: preferences, .dislikes: dislikes] {
            try c.encode(value, forKey: key)
        }
        try c.encode(availableDays, forKey: .availableDays)
        try c.encode(sessionMinutes, forKey: .sessionMinutes)
        if hasReviewedAvailability { try c.encode(true, forKey: .hasReviewedAvailability) }
        try c.encode(units, forKey: .units)
        try c.encode(limitationsAnswer, forKey: .limitationsAnswer)
        try c.encode(includeLimitationsInPrompt, forKey: .includeLimitationsInPrompt)
        try c.encode(includeBioInPrompt, forKey: .includeBioInPrompt)
        try c.encode(includeClinicianInstructionsInPrompt, forKey: .includeClinicianInstructionsInPrompt)
        try c.encode(includeAgeRangeInPrompt, forKey: .includeAgeRangeInPrompt)
        try c.encode(includeHeightInPrompt, forKey: .includeHeightInPrompt)
        try c.encode(includeWeightInPrompt, forKey: .includeWeightInPrompt)
        try c.encode(includeSleepInPrompt, forKey: .includeSleepInPrompt)
    }

    public var missingRequirements: [TrainingProfileRequirement] {
        var missing: [TrainingProfileRequirement] = []
        if goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append(.goal) }
        if goal == "Other" && secondaryGoals.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append(.goalDescription)
        }
        if strengthExperience.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append(.strengthExperience)
        }
        if cardioExperience.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append(.cardioExperience)
        }
        if availableDays.isEmpty { missing.append(.availableDays) }
        if !(10...180).contains(sessionMinutes) { missing.append(.sessionLength) }
        if trainingLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append(.trainingLocation)
        }
        if equipment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append(.equipment)
        }
        if limitationsAnswer == .reported && limitations.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append(.limitationsDetails)
        }
        return missing
    }

    public var missingEssentials: [String] { missingRequirements.map(\.title) }

    public var canGeneratePrompt: Bool { missingEssentials.isEmpty }
}
