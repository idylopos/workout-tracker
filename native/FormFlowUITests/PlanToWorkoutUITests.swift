import XCTest

final class PlanToWorkoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSamplePlanBecomesOneRecordedPartialWorkout() throws {
        let workspaceID = UUID().uuidString
        let app = launch(workspaceID: workspaceID)

        XCTContext.runActivity(named: "Review and activate the sample plan") { _ in
            tap("sample-plan", in: app)
            tap("import-review-week", in: app)
            XCTAssertTrue(app.navigationBars["Review your week"].waitForExistence(timeout: 5))
            tap("activate-plan", in: app)
            XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 5))
        }

        XCTContext.runActivity(named: "Enter actual values and explicitly complete one set") { _ in
            tap("scheduled-session-strength-a", in: app)
            tap("start-workout", in: app)
            tap("workout-set-0-0", in: app)

            let load = visibleElement("actual-load", in: app)
            XCTAssertTrue(isEmptyInput(load), "A new set must not invent an actual load from a plan target.")
            load.tap()
            load.typeText("12")

            let reps = visibleElement("actual-reps", in: app)
            XCTAssertTrue(isEmptyInput(reps), "A new set must not be marked performed by prefilling its rep target.")
            reps.tap()
            reps.typeText("8")
            tap("log-set", in: app)

            XCTAssertTrue(app.navigationBars["Your workout"].waitForExistence(timeout: 5))
            let savedValues = app.staticTexts["12 kg · 8 reps"].firstMatch
            requireVisible(savedValues, in: app)
            XCTAssertTrue(savedValues.exists)
        }

        XCTContext.runActivity(named: "Finish partially and inspect the saved history") { _ in
            tap("finish-workout", in: app)
            let partialAction = element("save-partial-workout", in: app)
            if partialAction.waitForExistence(timeout: 3) {
                partialAction.tap()
            } else {
                // System confirmation dialogs may expose the action label rather than its SwiftUI identifier.
                let labeledAction = app.buttons["Save partial workout"]
                XCTAssertTrue(labeledAction.waitForExistence(timeout: 3))
                labeledAction.tap()
            }
            XCTAssertTrue(app.navigationBars["Workout review"].waitForExistence(timeout: 5))
            tap("workout-close", in: app)

            let progressTab = app.tabBars.buttons["Progress"]
            XCTAssertTrue(progressTab.waitForExistence(timeout: 5))
            progressTab.tap()
            let historySummary = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "1 set", "Partial workout")).firstMatch
            requireVisible(historySummary, in: app)
            XCTAssertTrue(historySummary.exists, "History should retain one completed set and label the workout partial.")

            let historySession = app.staticTexts["Strength A"].firstMatch
            requireVisible(historySession, in: app)
            historySession.tap()
            XCTAssertTrue(app.navigationBars["Workout review"].waitForExistence(timeout: 5))
            let recordedValues = app.staticTexts["12 kg · 8 reps"].firstMatch
            requireVisible(recordedValues, in: app)
            XCTAssertTrue(recordedValues.exists)

            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Saved partial workout — actual load and reps"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    @MainActor
    func testProfileAnswersAndSectionResumeAfterRelaunch() throws {
        let workspaceID = UUID().uuidString
        let app = launch(workspaceID: workspaceID)
        let timeframe = "Build a steady routine over twelve weeks"

        tap("build-profile", in: app)
        XCTAssertTrue(app.navigationBars["Your goals"].waitForExistence(timeout: 5))
        tap("profile-main-goal", in: app)
        let goalOption = app.descendants(matching: .any).matching(identifier: "Build strength").firstMatch
        XCTAssertTrue(goalOption.waitForExistence(timeout: 5))
        goalOption.tap()

        let timeframeField = visibleElement("profile-goal-timeframe", in: app)
        timeframeField.tap()
        timeframeField.typeText(timeframe)
        tap("profile-next", in: app)
        XCTAssertTrue(app.navigationBars["Your starting point"].waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 10))
        tap("build-profile", in: app)
        XCTAssertTrue(app.navigationBars["Your starting point"].waitForExistence(timeout: 5), "The profile should resume at the saved section.")

        let back = app.buttons["Back"].firstMatch
        requireVisible(back, in: app)
        back.tap()
        XCTAssertTrue(app.navigationBars["Your goals"].waitForExistence(timeout: 5))
        let restoredTimeframe = visibleElement("profile-goal-timeframe", in: app)
        XCTAssertEqual(restoredTimeframe.value as? String, timeframe)
        let selectedGoal = visibleElement("profile-main-goal", in: app)
        let goalRestored = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Build strength", "Build strength")
        XCTAssertTrue(goalRestored.evaluate(with: selectedGoal), "The selected goal should survive relaunch.")
    }

    @MainActor
    func testWelcomeAndProfileActionsRemainReachableWithLargestText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-workspace", UUID().uuidString,
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 15))
        tap("build-profile", in: app)
        XCTAssertTrue(app.navigationBars["Your goals"].waitForExistence(timeout: 5))
        let goal = element("profile-main-goal", in: app)
        let form = try XCTUnwrap(app.collectionViews.allElementsBoundByIndex.last)
        for _ in 0..<12 {
            if goal.exists, goal.isHittable, form.frame.contains(CGPoint(x: goal.frame.midX, y: goal.frame.midY)) { break }
            form.swipeUp()
        }
        XCTAssertTrue(goal.exists && goal.isHittable)
        XCTAssertTrue(form.frame.contains(CGPoint(x: goal.frame.midX, y: goal.frame.midY)), "Scroll the goal control into the active Form before tapping.")
        goal.tap()
        let choice = app.descendants(matching: .any).matching(identifier: "Build strength").firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "The goal menu should open after tapping its visible control.")
        requireVisible(choice, in: app)
        choice.tap()
        tap("profile-next", in: app)
        XCTAssertTrue(app.navigationBars["Your starting point"].waitForExistence(timeout: 5))
        tap("profile-strength-experience", in: app)
        let returning = app.buttons["Returning after a break"].firstMatch
        requireVisible(returning, in: app)
        returning.tap()
        XCTAssertTrue(app.navigationBars["Your starting point"].waitForExistence(timeout: 5))
        let experience = visibleElement("profile-strength-experience", in: app)
        XCTAssertTrue(experience.label.contains("Returning after a break"))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Training profile — complete experience choice at largest accessibility text"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testSelectedProfileDeletionRequiresReviewAndConfirmation() throws {
        let app = launch(workspaceID: UUID().uuidString)
        let timeframe = "A private training goal"
        tap("build-profile", in: app)
        let field = visibleElement("profile-goal-timeframe", in: app)
        field.tap()
        field.typeText(timeframe)
        tap("Save & close", in: app)
        tap("Settings", in: app)
        tap("delete-selected-data", in: app)
        let review = visibleElement("review-deletion", in: app)
        XCTAssertFalse(review.isEnabled, "Deletion must begin with no categories selected.")
        try selectProfileDeletion(in: app)
        XCTAssertTrue(visibleElement("review-deletion", in: app).isEnabled)
        tap("review-deletion", in: app)
        let deletionPreview = XCTAttachment(screenshot: app.screenshot())
        deletionPreview.name = "Selected profile deletion — reviewed dependencies"
        deletionPreview.lifetime = .keepAlways
        add(deletionPreview)
        tap("delete-reviewed-data", in: app)
        let firstConfirmation = app.sheets.buttons["Delete reviewed data"].firstMatch
        XCTAssertTrue(firstConfirmation.waitForExistence(timeout: 5))
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 1) {
            cancel.tap()
        } else {
            // iOS 27 presents confirmationDialog as a popover, omitting its
            // explicit cancel row in favor of the accessible dismiss region.
            let dismissal = app.otherElements["PopoverDismissRegion"]
            XCTAssertTrue(dismissal.waitForExistence(timeout: 3))
            dismissal.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)).tap()
        }
        XCTAssertFalse(firstConfirmation.exists)
        XCTAssertTrue(element("delete-reviewed-data", in: app).exists, "Cancel must retain the preview without deleting.")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 10))
        tap("build-profile", in: app)
        XCTAssertEqual(visibleElement("profile-goal-timeframe", in: app).value as? String, timeframe)
        tap("Save & close", in: app)
        tap("Settings", in: app)
        tap("delete-selected-data", in: app)
        try selectProfileDeletion(in: app)
        tap("review-deletion", in: app)
        tap("delete-reviewed-data", in: app)
        let confirmation = app.sheets.buttons["Delete reviewed data"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 10))
        tap("build-profile", in: app)
        XCTAssertTrue(isEmptyInput(visibleElement("profile-goal-timeframe", in: app)), "Confirmed deletion must survive relaunch.")
    }

    @MainActor
    func testIncompleteBriefOpensMissingSectionAndCreatesSimplePrompt() throws {
        let app = launch(workspaceID: UUID().uuidString)
        tap("build-profile", in: app)
        tap("profile-main-goal", in: app)
        tap("General fitness", in: app)
        tap("profile-next", in: app)
        tap("profile-strength-experience", in: app)
        tap("New to this", in: app)
        tap("profile-cardio-experience", in: app)
        tap("Not sure", in: app)
        tap("profile-next", in: app)
        let monday = visibleElement("profile-day-monday", in: app)
        monday.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(monday.value as? String, "1")
        tap("profile-next", in: app)
        tap("profile-bodyweight", in: app)
        // Leave training location unanswered and all optional sections blank.
        for _ in 0..<4 { tap("profile-next", in: app) }
        XCTAssertTrue(app.navigationBars["Review brief"].waitForExistence(timeout: 5))
        let repair = visibleElement("brief-primary-action", in: app)
        XCTAssertTrue(repair.isEnabled)
        XCTAssertEqual(repair.label, "Complete missing answers")
        repair.tap()
        XCTAssertTrue(app.navigationBars["Your training space"].waitForExistence(timeout: 5))
        tap("profile-training-location", in: app)
        tap("Home", in: app)
        let returnAction = visibleElement("profile-next", in: app)
        XCTAssertEqual(returnAction.label, "Return to brief")
        returnAction.tap()
        XCTAssertTrue(app.navigationBars["Review brief"].waitForExistence(timeout: 5))
        let create = visibleElement("brief-primary-action", in: app)
        XCTAssertTrue(create.isEnabled)
        XCTAssertEqual(create.label, "Create and review prompt")
        create.tap()
        XCTAssertTrue(app.navigationBars["AI prompt"].waitForExistence(timeout: 5))
        let editor = visibleElement("Editable AI prompt", in: app)
        let prompt = try XCTUnwrap(editor.value as? String)
        XCTAssertTrue(prompt.contains("General fitness"))
        XCTAssertTrue(prompt.contains("Bodyweight / no equipment"))
        XCTAssertTrue(prompt.contains("Home"))
    }

    @MainActor
    private func selectProfileDeletion(in app: XCUIApplication) throws {
        let toggle = app.switches["delete-category-profile"]
        let form = try XCTUnwrap(app.collectionViews.allElementsBoundByIndex.last)
        let navigationBottom = app.navigationBars.firstMatch.frame.maxY
        for _ in 0..<8 {
            if toggle.exists, toggle.frame.minY > navigationBottom, toggle.frame.maxY < app.tabBars.firstMatch.frame.minY { break }
            form.swipeDown()
        }
        XCTAssertTrue(toggle.exists && toggle.isHittable)
        XCTAssertGreaterThan(toggle.frame.minY, navigationBottom, "Bring the complete category row below the navigation bar before selecting it.")
        // SwiftUI exposes the entire label row as the Switch frame. Tap the actual
        // trailing control, rather than the description in the row's center.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1", "The category must be selected before opening its deletion preview.")
    }

    @MainActor
    private func launch(workspaceID: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-workspace", workspaceID]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    @discardableResult
    private func visibleElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let result = element(identifier, in: app)
        requireVisible(result, in: app)
        return result
    }

    @MainActor
    private func tap(_ identifier: String, in app: XCUIApplication) {
        visibleElement(identifier, in: app).tap()
    }

    @MainActor
    private func requireVisible(_ target: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        if target.waitForExistence(timeout: 2), target.isHittable { return }
        for _ in 0..<12 {
            app.swipeUp()
            if target.exists && target.isHittable { return }
        }
        // A prior screen may have retained a lower scroll position while its contents changed.
        for _ in 0..<12 {
            app.swipeDown()
            if target.exists && target.isHittable { return }
        }
        XCTFail("Could not reach \(target) within the bounded scroll search.", file: file, line: line)
    }

    @MainActor
    private func isEmptyInput(_ field: XCUIElement) -> Bool {
        guard let value = field.value as? String else { return true }
        return value.isEmpty || value == field.placeholderValue
    }
}
