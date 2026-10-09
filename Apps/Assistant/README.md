# Assistant

Assistant is the on-device shell for DurableAgents. The Xcode target is `AssistantApp`. Open `Apps/Assistant/Assistant.xcodeproj` and run it. Deployment is iOS 26 and macOS 26. The Swift package underneath still builds on Linux; this app does not.

The first launch creates one agent on the demo model, turns on device-only mode, and stores an encrypted event log plus a derived memory index under Application Support. There is no server, no push entitlement, and no `aps-environment` key.

Chat, soul documents, skills, memory, routines, MCP servers, approvals, and settings are in the sidebar. Shortcuts can ask, catch up due routines, and approve a standard-risk request. High-risk approvals stay in the app and ask for Face ID or a device passcode.

Routines are best effort. Background refresh and processing are scheduled when iOS allows them. Opening the app catches up from the journal. A notification goes through quiet hours, a daily cap, and a dedupe key before it is posted.

Skills are instruction-only. `scripts/` is text. Nothing is spawned and nothing is downloaded as native code.

Linux `swift test` does not compile this target. See `UNVERIFIED.md` for the Apple calls that were not type-checked here, and `APP_STORE.md` before submitting.
