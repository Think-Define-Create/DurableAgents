import XCTest

/// Crash-and-resume through the fake outbox.
///
/// Run on an iOS 26 simulator or device from Xcode. This file is not part of `swift test`.
final class CrashResumeUITests: XCTestCase {
    func testCrashMidEmailResumesWithoutASecondSend() {
        let app = XCUIApplication()
        app.launchArguments = ["-UseScriptedModel", "-ResetJournal"]
        app.launch()

        let crash = app.buttons["crashNow"]
        XCTAssertTrue(crash.waitForExistence(timeout: 15))
        crash.tap()

        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "state != %d",
                XCUIApplication.State.runningForeground.rawValue
            ),
            object: app
        )
        _ = XCTWaiter.wait(for: [gone], timeout: 8)

        app.launchArguments = ["-UseScriptedModel"]
        app.launch()
        let banner = app.staticTexts["recoveryBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 15))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "emailReceipt").count, 1)
    }

    func testScheduleClosingShowsAnApprovalBanner() {
        let app = XCUIApplication()
        app.launchArguments = ["-UseScriptedModel", "-ResetJournal"]
        app.launch()

        let suggest = app.buttons["suggestClosing"]
        XCTAssertTrue(suggest.waitForExistence(timeout: 15))
        suggest.tap()
        XCTAssertTrue(app.buttons["approveButton"].waitForExistence(timeout: 10))
        app.buttons["approveButton"].tap()
        let done = app.staticTexts["Closing is on the calendar for 14 Harbor Lane."]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
    }
}
