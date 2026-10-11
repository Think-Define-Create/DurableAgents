import XCTest

/// Drives Assistant on a real device. `-ui-sandbox` gives the app a fresh folder and its own keys,
/// so these tests never touch the person's chats. Replies come from Apple's on-device model.
@MainActor
final class AssistantUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-sandbox"]
        // The first launch asks for notifications. Any system alert gets "Allow".
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Full Access", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        XCTAssertTrue(app.buttons["bot.Assistant"].waitForExistence(timeout: 60), "the home screen did not show the first bot")
    }

    func testSendingClearsTheComposerAndTheBotRemembers() throws {
        openBot("Assistant")
        send("My sister's name is Ana and she lives in Lisbon. Reply with one short sentence.")
        XCTAssertTrue(composerIsEmpty(), "the text box kept the sent message")
        XCTAssertTrue(waitForReplies(1, timeout: 120), "no reply to the first message")

        send("What is my sister's name, and where does she live?")
        // The first reply already says Ana and Lisbon, so check the second one on its own.
        XCTAssertTrue(waitForReplies(2, timeout: 120), "no reply to the question")
        let answer = replies().last ?? ""
        XCTAssertTrue(answer.contains("Ana") && answer.contains("Lisbon"), "the bot lost the context: \(answer)")
        attachScreenshot("recall")
    }

    func testTwoBotsReplyAtTheSameTime() throws {
        createBot("Bea")
        openBot("Assistant")
        send("Write five sentences about a lighthouse keeper.")
        goBack()

        // Assistant is still replying. Bea's chat must stay usable meanwhile.
        openBot("Bea")
        let composer = app.textViews["composer"].exists ? app.textViews["composer"] : app.textFields["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        send("Say hello in three words.")
        XCTAssertTrue(waitForReplies(1, timeout: 120), "Bea did not reply while Assistant was busy")
        attachScreenshot("bea replied")
        goBack()

        openBot("Assistant")
        XCTAssertTrue(waitForReplies(1, timeout: 180), "Assistant's reply never landed")
        attachScreenshot("assistant replied")
    }

    func testDiagnosticsAllPassOnThisDevice() throws {
        app.buttons["Settings"].firstMatch.tap()
        let link = app.buttons["Diagnostics"].firstMatch
        if !link.waitForExistence(timeout: 5) {
            app.swipeUp()
        }
        link.tap()
        let run = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Run All Checks'")).firstMatch
        XCTAssertTrue(run.waitForExistence(timeout: 10))
        run.tap()
        let running = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Running'")).firstMatch
        XCTAssertTrue(running.waitForExistence(timeout: 10), "diagnostics did not start")
        // Every module runs, including the on-device model. Each check has its own time limit.
        XCTAssertTrue(run.waitForExistence(timeout: 900), "diagnostics did not finish in fifteen minutes")
        let failed = app.descendants(matching: .any)["diagnostics.failed"].firstMatch
        let passed = app.descendants(matching: .any)["diagnostics.passed"].firstMatch
        attachScreenshot("diagnostics")
        XCTAssertEqual(failed.value as? String, "0", "diagnostics reported failures; passed \(passed.value ?? "?")")
    }

    /// Four bots on Apple's on-device model. Each learns one fact in its own chat, Assistant asks the
    /// other three, the questions show up in their chats, and all of it survives an app restart.
    func testFourBotsTalkToEachOtherAndRemember() throws {
        for name in ["Bea", "Cal", "Dee"] { createBot(name) }

        // Each bot learns one thing in its own chat.
        tell("Bea", "My favorite color is green. Please remember that.")
        tell("Cal", "My dog's name is Rex. Please remember that.")
        tell("Dee", "I live in Lisbon. Please remember that.")

        // Assistant asks each of them. Every question shows as an exchange card with the other bot's answer.
        openBot("Assistant")
        // The trace marks each ask so a failure can be matched to the app's own log.
        let asks = [("Bea", "what my favorite color is", "green"), ("Cal", "what my dog's name is", "Rex"), ("Dee", "where I live", "Lisbon")]
        for ask in asks {
            let before = replies().count
            send("Ask \(ask.0) \(ask.1).")
            XCTAssertTrue(waitForReplies(before + 1, timeout: 180), "Assistant did not answer after asking \(ask.0)")
            // Look the card up by name: a long chat drops off-screen bubbles, so counting them is unreliable.
            let card = exchanges().last { $0.hasPrefix("Asked \(ask.0):") }
            XCTAssertNotNil(card, "no exchange card for \(ask.0); Assistant said: \(replies().last ?? "")")
            XCTAssertTrue(card?.contains(ask.2) ?? false, "\(ask.0) did not remember: \(card ?? "none")")
            XCTAssertTrue(replies().last?.contains(ask.2) ?? false, "Assistant did not pass on \(ask.0)'s answer: \(replies().last ?? "")")
        }
        attachScreenshot("assistant asked three bots")

        // Assistant remembers its own conversation with all three.
        let before = replies().count
        send("Summarize what you learned from the other bots in one sentence.")
        XCTAssertTrue(waitForReplies(before + 1, timeout: 180))
        let summary = replies().last ?? ""
        for fact in ["green", "Rex", "Lisbon"] {
            XCTAssertTrue(summary.contains(fact), "the summary forgot \(fact): \(summary)")
        }
        attachScreenshot("summary")
        goBack()

        // The question landed in Bea's own chat, after what she was told, and she knows who asked.
        openBot("Bea")
        let incoming = app.descendants(matching: .any).matching(identifier: "incoming").firstMatch
        XCTAssertTrue(incoming.waitForExistence(timeout: 10), "Assistant's question is not in Bea's chat")
        XCTAssertTrue(incoming.label.hasPrefix("Assistant asked"), incoming.label)
        let beaBefore = replies().count
        send("Which bot asked you a question, and what did it ask?")
        XCTAssertTrue(waitForReplies(beaBefore + 1, timeout: 180))
        let beaAnswer = replies().last ?? ""
        XCTAssertTrue(beaAnswer.contains("Assistant") && beaAnswer.lowercased().contains("color"), "Bea forgot the exchange: \(beaAnswer)")
        attachScreenshot("bea remembers")

        // Restart the app on the same sandbox. Nothing is lost.
        app.terminate()
        app.launchArguments = ["-ui-sandbox", "-ui-sandbox-keep"]
        app.launch()
        XCTAssertTrue(app.buttons["bot.Assistant"].waitForExistence(timeout: 60))
        openBot("Cal")
        let calBefore = replies().count
        send("What is my dog's name?")
        XCTAssertTrue(waitForReplies(calBefore + 1, timeout: 180))
        XCTAssertTrue(replies().last?.contains("Rex") ?? false, "Cal forgot after a restart: \(replies().last ?? "")")
        goBack()
        openBot("Assistant")
        XCTAssertTrue(exchanges().contains { $0.hasPrefix("Asked Dee:") && $0.contains("Lisbon") }, "exchange cards were lost on restart")
        let afterBefore = replies().count
        send("Without asking anyone again, what is my favorite color?")
        XCTAssertTrue(waitForReplies(afterBefore + 1, timeout: 180))
        XCTAssertTrue(replies().last?.contains("green") ?? false, "Assistant forgot after a restart: \(replies().last ?? "")")
        attachScreenshot("after restart")
    }

    // MARK: - Steps

    private func tell(_ bot: String, _ text: String) {
        openBot(bot)
        let before = replies().count
        send(text)
        if !waitForReplies(before + 1, timeout: 180) {
            attachScreenshot("\(bot) no answer")
            XCTFail("\(bot) did not answer. On screen: \(visibleText())")
        }
        goBack()
    }

    private func visibleText() -> String {
        app.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.joined(separator: " | ")
    }

    private func exchanges() -> [String] {
        app.descendants(matching: .any).matching(identifier: "exchange").allElementsBoundByIndex.map(\.label)
    }

    private func openBot(_ name: String) {
        let row = app.buttons["bot.\(name)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no bot named \(name)")
        row.tap()
        XCTAssertTrue(composer().waitForExistence(timeout: 20), "the chat for \(name) did not open")
    }

    private func createBot(_ name: String) {
        let button = app.buttons["New bot"].firstMatch
        let field = app.textFields["Name"].firstMatch
        // A tap during the back animation can be dropped, so try a few times.
        for _ in 0..<3 where !field.exists {
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            button.tap()
            _ = field.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(field.exists, "the New Bot sheet did not open")
        field.tap()
        field.typeText(name)
        app.buttons["Create"].firstMatch.tap()
        // Creating opens the new chat. Return home.
        if composer().waitForExistence(timeout: 10) {
            goBack()
        }
        XCTAssertTrue(app.buttons["bot.\(name)"].waitForExistence(timeout: 20))
    }

    private func send(_ text: String) {
        let field = composer()
        field.tap()
        field.typeText(text)
        app.buttons["send"].firstMatch.tap()
    }

    private func goBack() {
        app.buttons["Back"].firstMatch.tap()
    }

    private func composer() -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "composer").firstMatch
    }

    private func composerIsEmpty() -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let value = composer().value as? String ?? ""
            if value.isEmpty || value.hasPrefix("Ask ") { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    private func replies() -> [String] {
        app.descendants(matching: .any).matching(identifier: "message.reply").allElementsBoundByIndex.map(\.label)
    }

    /// Waits for the turn that was just sent: the typing bubble shows, then goes away. Counting bubbles
    /// does not work in a long chat, because the list drops bubbles that scrolled off screen.
    private func waitForReplies(_ count: Int, timeout: TimeInterval) -> Bool {
        let live = app.descendants(matching: .any).matching(identifier: "live").firstMatch
        _ = live.waitForExistence(timeout: 3)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !live.exists, !replies().isEmpty { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
