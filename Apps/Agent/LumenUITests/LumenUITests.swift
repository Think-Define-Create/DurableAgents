import XCTest

@MainActor
final class LumenUITests: XCTestCase {
    func testOnboardingReachesTheAgentList() {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing")
        app.launch()
        XCTAssertTrue(app.staticTexts["Lumen"].waitForExistence(timeout: 10))
        app.buttons["onboarding.continue"].tap()
        app.buttons["onboarding.finish"].tap()
        XCTAssertTrue(app.buttons["agent.new"].waitForExistence(timeout: 10))
    }

    func testCrashAndResumeShowsRecoveredBanner() {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["onboarding.continue"].waitForExistence(timeout: 5) {
            app.buttons["onboarding.continue"].tap()
            app.buttons["onboarding.finish"].tap()
        }
        app.buttons["agent.new"].tap()
        let title = app.textFields["agent.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Resume")
        app.buttons["agent.create"].tap()
        let composer = app.textFields["composer.field"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("remind me to file the receipt")
        app.buttons["composer.send"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["banner.recovered"].waitForExistence(timeout: 15))
    }

    func testApprovalFlowResolvesTheInbox() {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["onboarding.continue"].waitForExistence(timeout: 5) {
            app.buttons["onboarding.continue"].tap()
            app.buttons["onboarding.finish"].tap()
        }
        if !app.buttons["inbox.approve"].exists {
            app.buttons["agent.new"].tap()
            let title = app.textFields["agent.title"]
            title.tap()
            title.typeText("Pay")
            app.buttons["agent.create"].tap()
            let composer = app.textFields["composer.field"]
            composer.tap()
            composer.typeText("remind me to approve the wire")
            app.buttons["composer.send"].tap()
        }
        XCTAssertTrue(app.buttons["inbox.approve"].waitForExistence(timeout: 15))
        app.buttons["inbox.approve"].tap()
    }
}
