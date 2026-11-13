# Agent workflow

- Commit your changes when a task is done, with a clear message. Do not push.
- `Void/Core` must stay plain Swift (Foundation only) so `swift test` runs on Linux. Run
  `swift test` after changing it.
- Anything that changes what's stored in CloudKit must follow `docs/sync-schema.md`, and
  both clients must change together: iOS (`Void/Core/SyncLibrary.swift`,
  `Void/Core/SyncCodec.swift`) and the website (`web/shared/library.mjs`,
  `web/shared/sync.mjs`). `Tests/fixtures/void-item-record.json` is decoded by both test suites.
- Run `npm test` from the root after changing `web/`, and `npm test` in `worker/` after
  changing the Worker.
- If an iOS Simulator is booted (`xcrun simctl list devices booted`), rebuild for it after
  changing the app:

  ```
  xcodebuild -project Void.xcodeproj -scheme Void -destination 'id=<booted UDID>' build
  ```
