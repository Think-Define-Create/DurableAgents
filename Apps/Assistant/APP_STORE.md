# App Store checklist

This build is arranged for App Store distribution. It was not archived or uploaded from this environment.

- No `aps-environment` entitlement. Routines do not use remote push. Background modes are `fetch` and `processing` only.
- No downloaded native code, no JavaScript skill sandbox, and no subprocess. Skill scripts stay text with `executable: false`.
- Privacy manifest is `Assistant/PrivacyInfo.xcprivacy`. Tracking is off and collected-data types are empty. The accessed-API reasons are a starting list (UserDefaults, file timestamp, disk space) because SQLite and Foundation touch those areas. Generate a privacy report in Xcode and replace that list with the report before submission. This environment did not generate one.
- Usage description: Face ID / device passcode for high-risk approval. The app does not request camera, contacts, calendar, speech, or microphone access.
- No private APIs are called. iOS 27-only symbols listed in `UNVERIFIED.md` are not in the source.
- On-device mode is the default for a new library. It blocks network model providers and HTTP MCP. stdio MCP is unavailable on iOS.
- The event log is encrypted with a Keychain key. The memory index is derived from that log and is not a second export of the ciphertext.
- Export compliance: the package uses CryptoKit or swift-crypto for AES-GCM. Answer the encryption questions from that, not from a custom cipher.
- Background work is best effort. The UI says the next wake can be delayed or skipped. There is no claim of a fixed 30-minute heartbeat.
- Unattended catch-up journals `approval.policy` and does not auto-approve an external effect. A person still resolves the inbox.
- Signing is automatic. Register the bundle id `dev.thinkdefinecreate.Assistant`. There is no app group.
