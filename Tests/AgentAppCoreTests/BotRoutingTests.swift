import AgentAppCore
import DurableCore
import DurableStore
import Foundation
import ModelKit
import Testing

/// Answers with a closure and keeps every request it saw.
private final class ScriptBot: ModelProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [ModelRequest] = []
    private let reply: @Sendable (ModelRequest) -> [ModelStreamEvent]

    init(reply: @escaping @Sendable (ModelRequest) -> [ModelStreamEvent]) {
        self.reply = reply
    }

    var requests: [ModelRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        lock.lock()
        seen.append(request)
        lock.unlock()
        let events = reply(request) + [.stop(StopReason(raw: "end_turn"))]
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    static func says(_ text: String) -> ScriptBot {
        ScriptBot { _ in [.textDelta(text)] }
    }
}

/// Bots are told apart by their model name. All of them use the `.apple` route so tests stay offline.
private func botChoice(_ name: String) -> ProviderChoice {
    ProviderChoice(kind: .apple, model: name)
}

private func openSession(
    bots: [String: ScriptBot],
    context: ContextBuilder? = nil,
    extraTools: [Tool] = []
) async throws -> AgentSession {
    let store = InMemoryEventStore(storeID: "bots-" + UUID().uuidString)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return try await AgentSession.open(
        store: store,
        directoryURL: directory,
        foundationModelsLinked: true,
        apple: { choice in bots[choice.model] },
        instructions: "Base instructions.",
        context: context,
        extraTools: extraTools
    )
}

@Test func soulAndMemoryReachEveryKindOfTurn() async throws {
    let seen = TurnLog()
    let ada = ScriptBot { request in
        // The first call asks Bea; after the reply arrives, Ada answers.
        if request.messages.last?.role == .tool {
            return [.textDelta("Bea says hi")]
        }
        if request.messages.last?.text.contains("ask bea") == true {
            return [.toolCall(ProviderToolCall(id: "call_1", name: "bots_ask", argumentsJSON: #"{"bot":"Bea","message":"Say hi"}"#))]
        }
        return [.textDelta("ok")]
    }
    let bea = ScriptBot.says("hi from Bea")
    let session = try await openSession(
        bots: ["ada": ada, "bea": bea],
        context: { turn in
            await seen.add(turn)
            return "SOUL: be kind.\nMEMORY: the person likes tea."
        },
        extraTools: [Tool(name: "heartbeat.respond", effect: .pure) { _, _ in ToolReturn(output: .object(["outcome": .string("noReply")])) }]
    )
    let adaProfile = try await session.create(title: "Ada", provider: botChoice("ada"))
    _ = try await session.create(title: "Bea", provider: botChoice("bea"))

    let plain = try await session.send(adaProfile.id, text: "hello")
    #expect(plain.finalText == "ok")
    let asked = try await session.send(adaProfile.id, text: "please ask bea")
    #expect(asked.failure == nil)
    #expect(asked.finalText == "Bea says hi")

    // Every model call carried the context, for both bots.
    let calls = ada.requests + bea.requests
    #expect(calls.count == 4)
    for request in calls {
        #expect(request.instructions.hasPrefix("Base instructions."))
        #expect(request.instructions.contains("SOUL: be kind."))
        #expect(request.instructions.contains("MEMORY: the person likes tea."))
    }
    #expect(ada.requests.allSatisfy { $0.instructions.contains("Your name is Ada.") })

    // Bea answered with her own model, saw the message without the routing header, and knew who sent it.
    let beaCall = try #require(bea.requests.first)
    #expect(beaCall.instructions.contains("Your name is Bea."))
    #expect(beaCall.instructions.contains("Ada, another bot, sent you the last message."))
    #expect(beaCall.messages.first?.text == "Ada (another bot) asks: Say hi")
    #expect(!beaCall.tools.contains { $0.name == "bots_ask" })

    // Ada's tool result is Bea's reply.
    let transcript = try await session.transcript(for: adaProfile.id)
    #expect(transcript.contains { $0.role == "tool" && $0.text == "hi from Bea" })

    let kinds = await seen.kinds
    #expect(kinds.contains(.chat))
    #expect(kinds.contains(.botMessage(from: "Ada")))
}

@Test func toolNamesAreWireSafeAndOnlyUsefulToolsAreOffered() async throws {
    let ada = ScriptBot.says("ok")
    let session = try await openSession(
        bots: ["ada": ada],
        extraTools: [Tool(name: "heartbeat.respond", effect: .pure) { _, _ in ToolReturn(output: .null) }]
    )
    let profile = try await session.create(title: "Ada", provider: botChoice("ada"))
    _ = try await session.create(title: "Bea", provider: botChoice("bea"))
    _ = try await session.send(profile.id, text: "hello")
    let names = try #require(ada.requests.first).tools.map(\.name)
    #expect(names.allSatisfy { $0.range(of: #"^[a-zA-Z0-9_-]{1,64}$"#, options: .regularExpression) != nil })
    #expect(names.contains("calendar_read"))
    #expect(names.contains("bots_ask"))
    #expect(!names.contains("document_ocr"))
    #expect(!names.contains("heartbeat_respond"))
}

@Test func dottedToolCallsComeBackWithEngineNames() async throws {
    let ada = ScriptBot { request in
        if request.messages.last?.role == .tool {
            return [.textDelta("You have 1 event")]
        }
        return [.toolCall(ProviderToolCall(id: "call_1", name: "calendar_read", argumentsJSON: #"{"days":2}"#))]
    }
    let session = try await openSession(bots: ["ada": ada])
    let profile = try await session.create(title: "Ada", provider: botChoice("ada"))
    let sent = try await session.send(profile.id, text: "what's on my calendar")
    #expect(sent.failure == nil)
    #expect(sent.finalText == "You have 1 event")
    // The second request replays the call under its wire name, with the result.
    let second = try #require(ada.requests.last)
    #expect(second.messages.contains { $0.toolCalls.contains { $0.name == "calendar_read" } })
    #expect(second.messages.last?.toolName == "calendar_read")
}

@Test func routinesRunWithTheirBotsModelAndHeartbeat() async throws {
    let ada = ScriptBot.says("chat")
    let bea = ScriptBot { request in
        if request.messages.last?.role == .tool {
            return [.textDelta("sent")]
        }
        return [.toolCall(ProviderToolCall(id: "hb", name: "heartbeat_respond", argumentsJSON: #"{"outcome":"notify","text":"2 things due"}"#))]
    }
    let session = try await openSession(
        bots: ["ada": ada, "bea": bea],
        context: { _ in "SOUL: brief." },
        extraTools: [Tool(name: "heartbeat.respond", effect: .pure) { input, _ in
            ToolReturn(output: .object(["outcome": input["outcome"] ?? .null, "text": input["text"] ?? .null]))
        }]
    )
    // Ada sends first, so a routine conversation must not inherit Ada's model.
    let adaProfile = try await session.create(title: "Ada", provider: botChoice("ada"))
    let beaProfile = try await session.create(title: "Bea", provider: botChoice("bea"))
    _ = try await session.send(adaProfile.id, text: "hi")

    let prompt = "Routine morning for \(beaProfile.id).\nChecklist:\nSay what is due."
    let result = try await session.currentEngine().submitTurn(prompt, requestID: "routine-1", to: nil, budget: RoutingModelStep.turnBudget)
    #expect(result.failure == nil)
    let call = try #require(bea.requests.first)
    #expect(call.instructions.contains("This is a scheduled routine"))
    #expect(call.instructions.contains("SOUL: brief."))
    #expect(call.instructions.contains("Your name is Bea."))
    #expect(call.tools.contains { $0.name == "heartbeat_respond" })
    #expect(ada.requests.count == 1)
}

@Test func askingAMissingBotSaysWhoExists() async throws {
    let ada = ScriptBot { request in
        if request.messages.last?.role == .tool {
            return [.textDelta(request.messages.last?.text ?? "")]
        }
        return [.toolCall(ProviderToolCall(id: "c", name: "bots_ask", argumentsJSON: #"{"bot":"Zed","message":"hi"}"#))]
    }
    let session = try await openSession(bots: ["ada": ada, "bea": .says("x")])
    let profile = try await session.create(title: "Ada", provider: botChoice("ada"))
    _ = try await session.create(title: "Bea", provider: botChoice("bea"))
    let sent = try await session.send(profile.id, text: "ask zed")
    #expect(sent.finalText?.contains("There is no bot named Zed") == true)
}

@Test func botMessageHeaderRoundTrips() {
    let encoded = BotMessage.encode(to: "agent_b", from: "agent_a", text: "line one\nline two")
    let decoded = try? #require(BotMessage.decode(encoded))
    #expect(decoded?.to == "agent_b")
    #expect(decoded?.from == "agent_a")
    #expect(decoded?.text == "line one\nline two")
    #expect(BotMessage.decode("plain text") == nil)
    #expect(RoutinePrompt.agentID(in: "Light context. Skip bootstrap files.\nRoutine x for agent_1.\nChecklist:") == "agent_1")
    #expect(RoutinePrompt.agentID(in: "hello") == nil)
    #expect(RoutinePrompt.checklist(in: "Routine x for agent_1.\nChecklist:\nSay hi.\nCall heartbeat.respond. noReply means nothing to report.") == "Say hi.")
}

@Test func toolDatesReadLocalTimes() {
    let zone = TimeZone(identifier: "America/Phoenix")!
    let date = try? #require(ToolDates.parse("2026-10-11T15:00", timeZone: zone))
    #expect(date.map { ToolDates.describe($0, timeZone: zone) } == "Sun 2026-10-11 15:00")
    #expect(ToolDates.parse("2026-10-11T22:00:00Z") != nil)
    #expect(ToolDates.parse("2026-10-11 9:30 AM", timeZone: zone).map { ToolDates.describe($0, timeZone: zone) } == "Sun 2026-10-11 09:30")
    #expect(ToolDates.parse("soon") == nil)
    let morning = try? #require(ToolDates.parse("tomorrow at 9am"))
    #expect(morning.map { Calendar.current.component(.hour, from: $0) } == 9)
    #expect(morning.map { $0 > Date() } == true)
}

private actor TurnLog {
    private(set) var kinds: [TurnKind] = []

    func add(_ turn: TurnContext) {
        kinds.append(turn.kind)
    }
}

@Test func theOnDeviceModelSeesOnlyRelevantToolsAndAnswersAfterOne() async throws {
    let apple = ScriptBot { request in
        if request.messages.last?.role == .tool {
            return [.textDelta("assistant: Done")]
        }
        if request.tools.contains(where: { $0.name == "contacts_search" }) {
            return [.toolCall(ProviderToolCall(id: "c1", name: "contacts_search", argumentsJSON: #"{"name":"Ada"}"#))]
        }
        return [.textDelta("plain")]
    }
    let session = try await openSession(bots: ["apple-foundation": apple, "bea": .says("x")])
    let profile = try await session.create(title: "Ada", provider: .apple)
    _ = try await session.create(title: "Bea", provider: botChoice("bea"))

    _ = try await session.send(profile.id, text: "Remind me to call mom tomorrow")
    var names = try #require(apple.requests.last).tools.map(\.name)
    #expect(names.contains("notes_reminder"))
    #expect(!names.contains { $0.hasPrefix("calendar_") })
    #expect(!names.contains("bots_ask"))

    _ = try await session.send(profile.id, text: "What is my favorite color?")
    names = try #require(apple.requests.last).tools.map(\.name)
    #expect(names.isEmpty)

    let sent = try await session.send(profile.id, text: "What is Ada's phone number?")
    #expect(sent.finalText == "Done")
    let afterTool = try #require(apple.requests.last)
    #expect(afterTool.messages.last?.role == .tool)
    #expect(afterTool.tools.isEmpty)

    _ = try await session.send(profile.id, text: "Ask Bea about dinner")
    let asking = try #require(apple.requests.last { $0.messages.last?.text == "Ask Bea about dinner" })
    #expect(asking.tools.map(\.name) == ["bots_ask"])
    // The model answered "plain" without calling the tool. A direct request to Bea is sent anyway.
    let overview = try await session.overview(for: profile.id)
    #expect(overview.exchanges.values.contains { $0.toName == "Bea" && $0.message == "The person wants to know about dinner" })
}

@Test func aReminderWithoutATimeTakesTheTimeFromThePersonsMessage() async throws {
    let apple = ScriptBot { request in
        if request.messages.last?.role == .tool { return [.textDelta("Done")] }
        return [.toolCall(ProviderToolCall(id: "r1", name: "notes_reminder", argumentsJSON: #"{"title":"buy milk"}"#))]
    }
    let store = InMemoryEventStore(storeID: "remind-" + UUID().uuidString)
    let session = try await AgentSession.open(
        store: store,
        directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
        foundationModelsLinked: true,
        apple: { _ in apple },
        instructions: "Base."
    )
    let profile = try await session.create(title: "Ada", provider: .apple)
    let sent = try await session.send(profile.id, text: "Remind me to buy milk tomorrow at 9am")
    let events = try await store.read(stream: .conversation(ConversationID(raw: sent.conversationID)))
    let json = events.map { $0.payload.canonicalJSON() }.joined()
    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
    let expected = ToolDates.local(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!)
    #expect(json.contains(expected))
}

@Test func aBotMessageLandsInTheOtherBotsOwnChatWithItsHistory() async throws {
    let ada = ScriptBot { request in
        if request.messages.last?.role == .tool { return [.textDelta("Bea: \(request.messages.last?.text ?? "")")] }
        return [.toolCall(ProviderToolCall(id: "ask1", name: "bots_ask", argumentsJSON: #"{"bot":"Bea","message":"What is the code word?"}"#))]
    }
    let bea = ScriptBot { request in
        let said = request.messages.map(\.text).joined(separator: "\n")
        if request.messages.last?.text == "Ada (another bot) asks: What is the code word?" {
            return [.textDelta(said.contains("mango") ? "mango" : "no idea")]
        }
        return [.textDelta("noted")]
    }
    let session = try await openSession(bots: ["ada": ada, "bea": bea])
    let adaProfile = try await session.create(title: "Ada", provider: botChoice("ada"))
    let beaProfile = try await session.create(title: "Bea", provider: botChoice("bea"))

    _ = try await session.send(beaProfile.id, text: "The code word is mango.")
    let asked = try await session.send(adaProfile.id, text: "ask Bea for the code word")
    #expect(asked.finalText == "Bea: mango")

    // Bea's own chat shows Ada's message and Bea's reply after the person's earlier message.
    let beaChat = try await session.transcript(for: beaProfile.id)
    #expect(beaChat.map(\.role) == ["user", "assistant", "user", "assistant"])
    let incoming = try #require(BotMessage.decode(beaChat[2].text))
    #expect(incoming.from == adaProfile.id)
    #expect(incoming.text == "What is the code word?")
    #expect(beaChat[3].text == "mango")

    // Ada's screen knows who was asked what.
    let overview = try await session.overview(for: adaProfile.id)
    let exchange = try #require(overview.exchanges.values.first)
    #expect(exchange.toName == "Bea")
    #expect(exchange.toAgentID == beaProfile.id)
    #expect(exchange.message == "What is the code word?")
    #expect(try await session.overview(for: nil).previews[beaProfile.id]?.role == "assistant")

    // When the person talks to Bea next, Ada's message reads as a line from Ada, not a header.
    _ = try await session.send(beaProfile.id, text: "thanks")
    let next = try #require(bea.requests.last)
    #expect(next.messages.contains { $0.text == "Message from the bot named Ada: What is the code word?" })
    #expect(!next.instructions.contains("another bot, sent you"))
}

@Test func aBusyBotSaysSoInsteadOfInterrupting() async throws {
    let ada = ScriptBot { request in
        if request.messages.last?.role == .tool { return [.textDelta(request.messages.last?.text ?? "")] }
        return [.toolCall(ProviderToolCall(id: "ask1", name: "bots_ask", argumentsJSON: #"{"bot":"Bea","message":"hi"}"#))]
    }
    let bea = ScriptBot { request in
        if request.messages.last?.role == .tool { return [.textDelta("done")] }
        return [.toolCall(ProviderToolCall(id: "r1", name: "notes_reminder", argumentsJSON: #"{"title":"milk","due":"2030-01-01T09:00"}"#))]
    }
    let session = try await openSession(bots: ["ada": ada, "bea": bea])
    let adaProfile = try await session.create(title: "Ada", provider: botChoice("ada"))
    let beaProfile = try await session.create(title: "Bea", provider: botChoice("bea"))
    let waiting = try await session.send(beaProfile.id, text: "remind me about milk")
    #expect(waiting.resumeToken != nil)

    let asked = try await session.send(adaProfile.id, text: "ask Bea")
    #expect(asked.failure == nil)
    #expect(asked.finalText?.contains("busy") == true)
    #expect(try await session.transcript(for: beaProfile.id).allSatisfy { BotMessage.decode($0.text) == nil })
}

/// Holds its reply until the test opens it, so a turn stays in flight.
private actor HeldReply {
    private var open = false
    private var started = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        started = true
        watchers.forEach { $0.resume() }
        watchers = []
        if !open { await withCheckedContinuation { waiting.append($0) } }
    }

    func untilStarted() async {
        if !started { await withCheckedContinuation { watchers.append($0) } }
    }

    func release() {
        open = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

private struct SlowBot: ModelProvider {
    let held: HeldReply

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await held.hold()
                continuation.yield(.textDelta("slow answer"))
                continuation.yield(.stop(StopReason(raw: "end_turn")))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Test func twoBotsReplyAtTheSameTimeInTheirOwnChats() async throws {
    let held = HeldReply()
    let store = InMemoryEventStore(storeID: "bots-" + UUID().uuidString)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let bea = ScriptBot.says("quick answer")
    let session = try await AgentSession.open(
        store: store,
        directoryURL: directory,
        foundationModelsLinked: true,
        apple: { choice in choice.model == "ada" ? SlowBot(held: held) as any ModelProvider : bea },
        instructions: "Base instructions."
    )
    let ada = try await session.create(title: "Ada", provider: botChoice("ada"))
    let beaBot = try await session.create(title: "Bea", provider: botChoice("bea"))

    let slow = Task { try await session.send(ada.id, text: "think hard") }
    await held.untilStarted()

    // Ada is still mid-reply. Bea answers anyway, and the overview loads.
    let quick = try await session.send(beaBot.id, text: "hello")
    #expect(quick.finalText == "quick answer")
    _ = try await session.overview(for: beaBot.id)

    await held.release()
    #expect(try await slow.value.finalText == "slow answer")
    let adaChat = try await session.transcript(for: ada.id).map { $0.text }
    let beaChat = try await session.transcript(for: beaBot.id).map { $0.text }
    #expect(adaChat.contains("slow answer") && !adaChat.contains("quick answer"))
    #expect(beaChat.contains("quick answer") && !beaChat.contains("slow answer"))
    await session.close()
}

@Test func aBotIsMentionedOnlyByItsWholeName() {
    #expect(ToolRelevance.mentionsBot("Ask Cal about it", botNames: ["Cal"]))
    #expect(ToolRelevance.mentionsBot("what did cal say?", botNames: ["Cal"]))
    #expect(!ToolRelevance.mentionsBot("Add lunch to my calendar", botNames: ["Cal"]))
    #expect(!ToolRelevance.mentionsBot("I need help", botNames: ["Dee"]))
    #expect(ToolRelevance.mentionsBot("Tell Mr Lee hi", botNames: ["Mr Lee"]))
}

private actor FlakyOnce {
    private var failed = false
    func next() -> Bool {
        defer { failed = true }
        return !failed
    }
}

@Test func aFailedToolIsRetriedOnItsOwnAndTheReplyLands() async throws {
    let flaky = FlakyOnce()
    let tool = Tool(name: "notes.flaky", effect: .idempotent, summary: "fails once") { _, _ in
        if await flaky.next() { throw URLError(.timedOut) }
        return ToolReturn(output: .string("saved"))
    }
    let bot = ScriptBot { request in
        if request.messages.last?.role == .tool { return [.textDelta("all done")] }
        return [.toolCall(ProviderToolCall(id: "f1", name: "notes_flaky", argumentsJSON: "{}"))]
    }
    let session = try await openSession(bots: ["ada": bot], extraTools: [tool])
    let ada = try await session.create(title: "Ada", provider: botChoice("ada"))
    let sent = try await session.send(ada.id, text: "save it")
    #expect(sent.runStatus == "running")

    // Nothing pumps timers here. The session's own timer fires the retry.
    var chat: [String] = []
    for _ in 0..<60 {
        chat = try await session.transcript(for: ada.id).map { $0.text }
        if chat.contains("all done") { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(chat.contains("all done"))
    await session.close()
}

@Test func aToolCallWrittenAsTextBecomesARealCall() {
    let offered = ["memory.remember", "calendar.read"]
    let call = RoutingModelStep.toolCallWrittenAsText(#"memory_remember{fact: "My favorite color is green."}"#, offered: offered)
    #expect(call?.name == "memory.remember")
    #expect(call?.arguments.objectValue?["fact"]?.stringValue == "My favorite color is green.")
    #expect(RoutingModelStep.toolCallWrittenAsText(#"calendar.read{"days": 3}"#, offered: offered)?.name == "calendar.read")
    // Not offered, or plain prose, stays a reply.
    #expect(RoutingModelStep.toolCallWrittenAsText(#"web_fetch{url: "x"}"#, offered: offered) == nil)
    #expect(RoutingModelStep.toolCallWrittenAsText("Sure {not a call}", offered: offered) == nil)
}

@Test func askingANamedBotIsADirectRequest() {
    let names = ["Bea", "Cal"]
    let ask = RoutingModelStep.directBotRequest("Ask Cal what my dog's name is.", botNames: names)
    #expect(ask?.bot == "Cal")
    #expect(ask?.message == "The person wants to know what my dog's name is.")
    #expect(RoutingModelStep.directBotRequest("tell Bea: lunch is at noon", botNames: names)?.message == "The person says: lunch is at noon")
    #expect(RoutingModelStep.directBotRequest("Ask Calvin something", botNames: names) == nil)
    #expect(RoutingModelStep.directBotRequest("What did Cal say?", botNames: names) == nil)
}

@Test func theBotThePersonNamedWinsOverTheModelsChoice() async throws {
    let ada = ScriptBot { request in
        if request.messages.last?.role == .tool { return [.textDelta("relayed: \(request.messages.last?.text ?? "")")] }
        // The model copies its earlier call and picks Bea.
        return [.toolCall(ProviderToolCall(id: "x\(request.messages.count)", name: "bots_ask", argumentsJSON: #"{"bot":"Bea","message":"What is my favorite color?"}"#))]
    }
    let session = try await openSession(bots: ["ada": ada, "bea": .says("green"), "cal": .says("Rex")])
    let profile = try await session.create(title: "Ada", provider: botChoice("ada"))
    _ = try await session.create(title: "Bea", provider: botChoice("bea"))
    _ = try await session.create(title: "Cal", provider: botChoice("cal"))
    let sent = try await session.send(profile.id, text: "Ask Cal what my dog's name is.")
    #expect(sent.finalText == "relayed: Rex")
}

@Test func aStaleQuestionIsReplacedByThePersonsWords() async throws {
    let ada = ScriptBot { request in
        if request.messages.last?.role == .tool { return [.textDelta("relayed")] }
        // Right bot, but the question from the previous turn.
        return [.toolCall(ProviderToolCall(id: "s\(request.messages.count)", name: "bots_ask", argumentsJSON: #"{"bot":"Cal","message":"What is my favorite color?"}"#))]
    }
    let session = try await openSession(bots: ["ada": ada, "cal": .says("Rex")])
    let profile = try await session.create(title: "Ada", provider: botChoice("ada"))
    _ = try await session.create(title: "Cal", provider: botChoice("cal"))
    _ = try await session.send(profile.id, text: "Ask Cal what my dog's name is.")
    let overview = try await session.overview(for: profile.id)
    #expect(overview.exchanges.values.first?.message == "The person wants to know what my dog's name is.")
}

/// The parser Linux relies on, since its Foundation has no NSDataDetector.
@Test func simplePhrasesGiveADateWithoutTheSystemDetector() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Phoenix")!
    // Saturday 2026-10-10 15:00 in Phoenix.
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 15)))
    func local(_ text: String) -> String? {
        ToolDates.simpleNatural(text, now: now, calendar: calendar).map { ToolDates.describe($0, timeZone: calendar.timeZone) }
    }
    #expect(local("remind me tomorrow at 9am") == "Sun 2026-10-11 09:00")
    #expect(local("today at 5:30 pm") == "Sat 2026-10-10 17:30")
    #expect(local("call mom friday at noon") == "Fri 2026-10-16 12:00")
    #expect(local("at 9") == "Sun 2026-10-11 09:00")
    #expect(local("at 4pm") == "Sat 2026-10-10 16:00")
    #expect(local("tomorrow") == nil)
    #expect(local("buy 2 apples") == nil)
}
