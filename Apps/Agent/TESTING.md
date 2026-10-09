# First Mac run

These steps were not executed here. The machine that wrote this tree cannot compile Apple frameworks.

1. Open `Apps/Agent/Lumen.xcodeproj` in Xcode 26.
2. Scheme: Lumen. Destination: My Mac, or an iOS 26 simulator.
3. Signing: Automatic. Pick your team on the Lumen target and the LumenWidget target.
4. If the App Group `group.dev.thinkdefinecreate.Lumen` is red, click the capability once so Xcode registers it. If signing still fails, remove the App Group entitlement from both targets, run the app, and expect the widget to read an empty file. The chat does not need the group.
5. Press Run. You should see the onboarding title Lumen.
6. Continue, leave the key fields empty, Start. The agent list is empty.
7. New agent, name it Desk, leave the model on Offline demo, Create.
8. Send `hello`. A short reply should appear. The usage inspector stays at zero dollars.
9. Send `remind me to file the receipt`. The run should suspend. Approvals shows the reminder. Approve it. macOS will prompt for Reminders access the first time.
10. Stop the app from Xcode while a run is suspended (send the reminder text and do not approve). Run again. The list should show the recovered banner.
11. Settings, turn on On-device only, Save. Create an agent with OpenAI and send a message. The reply should refuse the cloud model without calling the network.
12. On macOS, Settings, Start loopback. The row shows `http://127.0.0.1:<port>/mcp`. `curl -D - http://127.0.0.1:<port>/mcp` should answer 405 to GET.
13. MCP sheet: an HTTP server with an empty allow list should attach zero tools.
14. Privacy, Build export, Share audit. The text starts with `hash-chain intact` on a store this app wrote.
15. Product, Test, with LumenUITests. The three tests cover onboarding, relaunch, and approval. They were not run here.

If a compile error names an Apple API, paste it back. The likely ones are listed in `UNVERIFIED.md`.
