import XCTest
@testable import FormFlowCore

final class ProfileAndScheduleTests: XCTestCase {
    func testExcludedSensitiveAnswersNeverEnterPrompt() {
        var profile = readyProfile()
        profile.ageRange = "AGE_PRIVATE_123"
        profile.height = "HEIGHT_PRIVATE_123"
        profile.weight = "WEIGHT_PRIVATE_123"
        profile.usualSleep = "SLEEP_PRIVATE_123"
        profile.limitationsAnswer = .reported
        profile.limitations = "LIMITATION_PRIVATE_123"
        profile.clinicianInstructions = "CLINICIAN_PRIVATE_123"
        let prompt = PromptBuilder.build(profile: profile)
        for privateValue in [profile.ageRange, profile.height, profile.weight, profile.usualSleep,
                             profile.limitations, profile.clinicianInstructions] {
            XCTAssertFalse(prompt.contains(privateValue), "Leaked \(privateValue)")
        }
        XCTAssertTrue(prompt.contains("Not shared. Do not interpret this as no limitations."))
    }

    func testSelectedSensitiveAnswersAndContextAreIncluded() {
        var profile = readyProfile()
        profile.includeBioInPrompt = true
        profile.includeLimitationsInPrompt = true
        profile.includeClinicianInstructionsInPrompt = true
        profile.ageRange = "AGE_INCLUDED_456"
        profile.limitationsAnswer = .reported
        profile.limitations = "LIMITATION_INCLUDED_456"
        profile.clinicianInstructions = "CLINICIAN_INCLUDED_456"
        profile.recentRoutine = "RECENT_ROUTINE_456"
        profile.units = .imperial
        let prompt = PromptBuilder.build(profile: profile)
        for value in [profile.ageRange, profile.limitations, profile.clinicianInstructions, profile.recentRoutine] {
            XCTAssertTrue(prompt.contains(value))
        }
        XCTAssertTrue(prompt.contains("\"units\" : \"imperial\""))
        XCTAssertEqual(prompt, PromptBuilder.build(profile: profile))
    }

    func testSkippedBackgroundIsUnknownAndDoesNotBlockGeneration() {
        var profile = readyProfile()
        profile.limitationsAnswer = .unanswered
        profile.includeLimitationsInPrompt = true
        XCTAssertTrue(profile.canGeneratePrompt)
        let prompt = PromptBuilder.build(profile: profile)
        XCTAssertTrue(prompt.contains("Not answered yet"))
        XCTAssertFalse(prompt.contains("No known limitations"))
    }

    func testEachSensitiveFieldCanBeSharedWithoutTheOthers() {
        var baseline = readyProfile()
        baseline.ageRange = "PRIVATE_AGE_TOKEN"
        baseline.height = "PRIVATE_HEIGHT_TOKEN"
        baseline.weight = "PRIVATE_WEIGHT_TOKEN"
        baseline.usualSleep = "PRIVATE_SLEEP_TOKEN"
        baseline.limitationsAnswer = .reported
        baseline.limitations = "PRIVATE_LIMITATIONS_TOKEN"
        baseline.clinicianInstructions = "PRIVATE_CLINICIAN_TOKEN"
        let fields: [(WritableKeyPath<TrainingProfile, Bool>, String)] = [
            (\.includeAgeRangeInPrompt, baseline.ageRange), (\.includeHeightInPrompt, baseline.height),
            (\.includeWeightInPrompt, baseline.weight), (\.includeSleepInPrompt, baseline.usualSleep),
            (\.includeLimitationsInPrompt, baseline.limitations),
            (\.includeClinicianInstructionsInPrompt, baseline.clinicianInstructions)
        ]
        for (keyPath, selected) in fields {
            var profile = baseline
            profile[keyPath: keyPath] = true
            let prompt = PromptBuilder.build(profile: profile)
            XCTAssertTrue(prompt.contains(selected))
            for (_, other) in fields where other != selected {
                XCTAssertFalse(prompt.contains(other), "Sharing \(selected) also exposed \(other)")
            }
        }
    }

    func testLegacyProfileDecodesWithExactlyItsPreviousPrivacyChoices() throws {
        let previouslyIncluded = Data(#"{"goal":"Keep my goal","includeBioInPrompt":true,"includeLimitationsInPrompt":true}"#.utf8)
        let restored = try JSONDecoder().decode(TrainingProfile.self, from: previouslyIncluded)
        XCTAssertEqual(restored.goal, "Keep my goal")
        XCTAssertEqual(restored.sessionMinutes, 45)
        XCTAssertTrue(restored.includeAgeRangeInPrompt)
        XCTAssertTrue(restored.includeHeightInPrompt)
        XCTAssertTrue(restored.includeWeightInPrompt)
        XCTAssertTrue(restored.includeSleepInPrompt)
        XCTAssertTrue(restored.includeClinicianInstructionsInPrompt)
        let privateProfile = try JSONDecoder().decode(TrainingProfile.self, from: Data("{}".utf8))
        XCTAssertEqual(privateProfile, TrainingProfile())
    }

    func testGranularConsentOverridesLegacyGroupAndSurvivesRoundTrip() throws {
        let oldAndNew = Data(#"{"includeBioInPrompt":true,"includeHeightInPrompt":false,"includeLimitationsInPrompt":true,"includeClinicianInstructionsInPrompt":false}"#.utf8)
        let profile = try JSONDecoder().decode(TrainingProfile.self, from: oldAndNew)
        XCTAssertFalse(profile.includeHeightInPrompt)
        XCTAssertTrue(profile.includeAgeRangeInPrompt)
        XCTAssertFalse(profile.includeClinicianInstructionsInPrompt)
        XCTAssertTrue(profile.includeLimitationsInPrompt)
        XCTAssertEqual(try JSONDecoder().decode(TrainingProfile.self, from: JSONEncoder().encode(profile)), profile)
    }

    func testEssentialsAndReportedLimitationsNeedUsableContext() {
        XCTAssertFalse(TrainingProfile().canGeneratePrompt)
        var profile = readyProfile()
        XCTAssertTrue(profile.canGeneratePrompt)
        profile.equipment = "  \n "
        XCTAssertFalse(profile.canGeneratePrompt)
        profile.equipment = "Bodyweight only"
        profile.limitationsAnswer = .reported
        XCTAssertFalse(profile.canGeneratePrompt)
        profile.limitationsAnswer = .preferNotToSay
        XCTAssertTrue(profile.canGeneratePrompt)
        profile.sessionMinutes = -1
        XCTAssertFalse(profile.canGeneratePrompt)
    }

    func testMissingRequirementsIdentifyEditableFieldsWithoutRequiringOptionalBio() {
        var profile = TrainingProfile()
        XCTAssertEqual(profile.missingRequirements, [.goal, .strengthExperience, .cardioExperience, .availableDays, .trainingLocation, .equipment])
        profile.goal = "General fitness"
        profile.strengthExperience = "New to this"
        profile.cardioExperience = "Not sure"
        profile.availableDays = [.monday]
        profile.equipment = "Bodyweight only"
        XCTAssertEqual(profile.missingRequirements, [.trainingLocation])
        profile.trainingLocation = "Home"
        XCTAssertTrue(profile.canGeneratePrompt, "A simple brief may leave bio, constraints and optional background unknown.")
        XCTAssertTrue(profile.missingEssentials.isEmpty)
        XCTAssertFalse(profile.includeBioInPrompt)
    }

    func testConditionalMissingRequirementsKeepGoalAndLimitationDetailsActionable() {
        var profile = readyProfile()
        profile.goal = "Other"
        profile.secondaryGoals = "  "
        profile.limitationsAnswer = .reported
        profile.limitations = "\n"
        XCTAssertEqual(profile.missingRequirements, [.goalDescription, .limitationsDetails])
        profile.secondaryGoals = "Train for a hiking trip"
        profile.limitationsAnswer = .preferNotToSay
        XCTAssertTrue(profile.canGeneratePrompt)
    }

    func testMidweekActivationPreservesWeekdaysAndBothSessions() throws {
        let calendar = try calendar(timeZone: "Asia/Singapore")
        let wednesday = try date(2026, 9, 16, calendar: calendar)
        let plan = scheduleFixture()
        let schedule = PlanSchedule.upcoming(plan: plan, activationDate: wednesday, from: wednesday,
                                             limit: 3, calendar: calendar)
        XCTAssertEqual(schedule.map(\.session.id), ["friday", "monday-am", "monday-pm"])
        XCTAssertEqual(schedule.map { calendar.component(.weekday, from: $0.date) }, [6, 2, 2])
        XCTAssertEqual(Set(schedule.map(\.id)).count, 3)
        XCTAssertTrue(schedule.allSatisfy { $0.date >= wednesday })
    }

    func testScheduleAcrossDaylightSavingUsesLocalCalendarDates() throws {
        let calendar = try calendar(timeZone: "America/New_York")
        let saturday = try date(2026, 10, 31, calendar: calendar)
        let sunday = PlanSession(id: "sunday", name: "Sunday", kind: "strength", estimatedMinutes: 20, exercises: [])
        let monday = PlanSession(id: "monday", name: "Monday", kind: "strength", estimatedMinutes: 20, exercises: [])
        let plan = WeeklyPlan(id: "dst", name: "DST", days: [
            PlanDay(weekday: .sunday, sessions: [sunday]), PlanDay(weekday: .monday, sessions: [monday])
        ])
        let schedule = PlanSchedule.upcoming(plan: plan, activationDate: saturday, from: saturday, limit: 2, calendar: calendar)
        XCTAssertEqual(schedule.map { calendar.component(.day, from: $0.date) }, [1, 2])
        XCTAssertEqual(schedule.map { calendar.component(.hour, from: $0.date) }, [0, 0])
        XCTAssertEqual(schedule[1].date.timeIntervalSince(schedule[0].date), 25 * 60 * 60)
    }

    func testFutureActivationAndEmptySchedule() throws {
        let calendar = try calendar(timeZone: "Asia/Singapore")
        let today = try date(2026, 9, 1, calendar: calendar)
        let future = try date(2026, 10, 1, calendar: calendar)
        let schedule = PlanSchedule.upcoming(plan: scheduleFixture(), activationDate: future, from: today, limit: 1, calendar: calendar)
        XCTAssertEqual(schedule.first?.date, try date(2026, 10, 2, calendar: calendar))
        let empty = WeeklyPlan(id: "empty", name: "Empty", days: [])
        XCTAssertEqual(PlanSchedule.upcoming(plan: empty, activationDate: today, from: today), [])
    }

    private func readyProfile() -> TrainingProfile {
        var profile = TrainingProfile()
        profile.goal = "Build a consistent routine"
        profile.strengthExperience = "Novice"
        profile.cardioExperience = "Not sure"
        profile.availableDays = [.monday, .friday]
        profile.trainingLocation = "Home"
        profile.equipment = "Bodyweight only"
        return profile
    }

    private func scheduleFixture() -> WeeklyPlan {
        func session(_ id: String) -> PlanSession {
            PlanSession(id: id, name: id, kind: "strength", estimatedMinutes: 30, exercises: [])
        }
        return WeeklyPlan(id: "week", name: "Week", days: [
            PlanDay(weekday: .monday, sessions: [session("monday-am"), session("monday-pm")]),
            PlanDay(weekday: .friday, sessions: [session("friday")])
        ])
    }

    private func calendar(timeZone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: timeZone))
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day)))
    }
}
