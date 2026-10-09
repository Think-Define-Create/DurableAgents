import XCTest

@MainActor
final class LumenUITests: XCTestCase {
    /// Onboarding shows only on a fresh install. On a device that already finished it, the
    /// agent list is the first screen.
    func testOnboardingReachesTheAgentList() {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing")
        app.launch()
        finishOnboardingIfShown(app)
        XCTAssertTrue(app.buttons["agent.new"].waitForExistence(timeout: 10))
    }

    func testCrashAndResumeShowsRecoveredBanner() {
        let app = XCUIApplication()
        app.launch()
        finishOnboardingIfShown(app)
        createAgent(app, title: "Resume")
        send(app, "remind me to file the receipt")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["banner.recovered"].waitForExistence(timeout: 15))
    }

    func testApprovalFlowResolvesTheInbox() {
        let app = XCUIApplication()
        app.launch()
        finishOnboardingIfShown(app)
        createAgent(app, title: "Pay")
        send(app, "remind me to approve the wire")
        openApprovals(app)
        let approve = app.buttons["inbox.approve"].firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 15))
        approve.tap()
    }

    /// On iPhone the split view shows the chat on top of the list, so go back first.
    private func openApprovals(_ app: XCUIApplication) {
        let open = app.buttons["inbox.open"]
        if !open.waitForExistence(timeout: 2) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
    }

    private func finishOnboardingIfShown(_ app: XCUIApplication) {
        let next = app.buttons["onboarding.continue"]
        guard next.waitForExistence(timeout: 5) else { return }
        next.tap()
        let finish = app.buttons["onboarding.finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        finish.tap()
    }

    private func createAgent(_ app: XCUIApplication, title: String) {
        let new = app.buttons["agent.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        new.tap()
        let field = app.textFields["agent.title"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(title)
        app.buttons["agent.create"].tap()
    }

    private func send(_ app: XCUIApplication, _ text: String) {
        let composer = app.textFields["composer.field"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText(text)
        app.buttons["composer.send"].tap()
    }
}
