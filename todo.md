# SocketHandlers — Code Review Todo

Derived from full implementation + architectural review (2026-03-28).
All actionable items completed 2026-04-13. Remaining items moved to **Deferred** below.

---

## Correctness

- [x] **setupChildChannel race condition** — all state mutations inside `setupChildChannel` now dispatched to `serverDispatchQueue.async`; only `syncOperations.addHandler` (NIO pipeline setup) remains on the event loop thread.

- [x] **messagesReceived unsynchronized increment (server)** — `handleMessage` in `NIOHandlerServer.swift:952` dispatches the increment to `serverDispatchQueue.async`. Already serialized correctly; verified and checked off 2026-04-13.

- [x] **messagesReceived unsynchronized increment (client)** — `handleMessage` in `NIOSocketHandlerClient.swift:824` dispatches the increment to `socketDispatchQueue.async`. Same finding as server.

- [x] **Unbounded `cumulationBuffer` in `NIOStringHandler`** — `maxCumulationBufferSize` (default 1 MB) added to `ServerConfiguration` and `ClientConfiguration`; `NIOStringHandler` checks readable bytes after each append and closes the channel with an error log when the limit is exceeded.

- [x] **`send()` misleading return value** — `send(confirming: String) async throws` and `send(confirming: Data) async throws` added to both server and client; these suspend until `writeAndFlush` completes and throw on failure. Fire-and-forget `send(_:)` still returns `true` immediately by design.

---

## Swift 6 Compliance

- [ ] **Eliminate `@unchecked Sendable` on `NIOSocketHandlerServer`** — *Deferred. See below.*

- [ ] **Eliminate `@unchecked Sendable` on `NIOSocketHandlerClient`** — *Deferred. See below.*

- [ ] **Eliminate `@unchecked Sendable` on `MessageQueue`** — *Deferred. See below.*

- [x] **Add `final` to `NIOClientConnectionStateHandler`** — added 2026-04-13 (`NIOClientConnectionStateHandler.swift:9`).

- [x] **Add `final` to `NIOServerConnectionStateHandler`** — already present before this session.

---

## Determinism

- [x] **Replace `Date()` with monotonic time in `MessageQueue`** — Partially addressed 2026-04-13: removed all inline `cleanupExpiredMessages()` calls from hot paths (`enqueue`, `dequeue`, `peek`, `count`, `messages(for:)`). The background timer (every 60 s) is the sole cleanup path. Full migration to `ContinuousClock.Instant` is deferred — see note in Deferred section.

- [x] **Remove inline `cleanupExpiredMessages()` from hot path** — removed from `enqueue`, `dequeue`, `peek`, `count`, `messages(for:)` in `MessageQueue.swift`. Queue operations are now O(1) amortized.

---

## Performance

- [x] **Eliminate per-send String allocation** — replaced `message + "\n"` with two sequential writes (`writeString(message)` + `writeStaticString("\n")`) at all four send sites: `NIOHandlerServer.swift:339,403` and `NIOSocketHandlerClient.swift:488,527`.

- [ ] **Consider migrating to `ByteToMessageDecoder`** — *Deferred. See below.*

---

## SOLID — Internal Extractions (public API unchanged)

- [ ] **Extract `MessageFramer` protocol from `NIOStringHandler`** — *Deferred. See below.*

- [ ] **Extract `ConnectionPool` (internal)** — *Deferred. See below.*

- [ ] **Extract `Metrics` (internal)** — *Deferred. See below.*

- [ ] **Inject `Logger`** — *Deferred. See below.*

- [ ] **Inject `MessageQueue`** — *Deferred. See below.*

---

## Error Handling & Logging

- [x] **Replace `print()` with structured `Logger` in `MessageQueue`** — already uses `logger.error(...)` at `MessageQueue.swift:247`. Verified and checked off 2026-04-13.

- [x] **Add byte context to UTF-8 decode failure log** — split the combined `guard` into two in `NIOStringHandler.processBufferedMessages`. The second guard now includes a hex dump of the offending bytes.

- [x] **Guard against empty delimiter in `NIOStringHandler`** — `precondition(!tokenizer.isEmpty, …)` already present at `NIOStringHandler.swift:48`. Verified and checked off 2026-04-13.

---

## Testing

- [x] **Add error path tests** — `test_errorPath_connectionRefused` and `test_errorPath_sendBeforeConnect` added to `NIOHandlerTests.swift` 2026-04-13.

- [x] **Add `NIOStringHandler` max-buffer test** — `test_maxCumulationBuffer` added to `NIOHandlerTests.swift`; verifies the channel is closed when the 64-byte test limit is exceeded.

- [x] **Add message ordering test** — `stressorTest_deterministicTiming` exercises 10 000 messages at fixed 1 µs latency. Checked off 2026-04-13.

- [x] **Add concurrent connections stress test** — `test_concurrentConnections` added to `NIOHandlerTests.swift`; 5 clients connect simultaneously, each sends 20 messages, server asserts all 100 received.

- [x] **Fix `netcatEchoTest()`** — deleted the dead function (had `return` on line 1 making all code unreachable). Also removed orphaned `import XCTest` from `NIOHandlerNetCatTests.swift`.

- [x] **Replace polling `waitForClientConnection()`** — replaced 100 ms polling loop with `withCheckedThrowingContinuation` + OpenCombine publisher sink + Task-based timeout race in `TaskFunctions.swift`.

- [ ] **Deduplicate timing test helpers** — *Deferred. See below.*

---

## Package & Build

- [ ] **Add Linux platform support to `Package.swift`** — *Deferred. See below.*

- [ ] **Resolve `spmFoundationTools` branch constraint** — *Deferred. See below.*

---

## Documentation

- [x] **Add code examples to `readme.md`** — Client Usage Example and Server Usage Example sections added, including fire-and-forget and confirmed-send variants.

- [x] **Expand `diags/Network Diagnostics.md`** — added `lsof -i :<port>`, `netstat -an | grep <port>`, socket state reference, and application-level diagnostics (`connectedClientIDsPublisher`, `getMetrics()`, etc.).

---

## Deferred

These items require larger architectural work, are blocked on external dependencies,
or have a low urgency-to-effort ratio. Revisit when scoping a dedicated milestone.

| Item | Reason deferred |
|---|---|
| **Eliminate `@unchecked Sendable`** on Server, Client, MessageQueue | Full actor migration — large cross-cutting refactor touching the entire concurrency model. Requires careful design to avoid breaking callers. |
| **`Date()` → `ContinuousClock` in `MessageQueue`** | `ContinuousClock.Instant` is not `Codable`. Persisted queues reconstruct timestamps from disk; a fully monotonic solution needs a two-timestamp design (persisted `Date` + in-memory `Instant`). Low urgency: NTP jumps rarely affect short-lived queues. |
| **`ByteToMessageDecoder` migration** | Prerequisite: `MessageFramer` protocol must be extracted first. Revisit after the SOLID milestone. |
| **Extract `MessageFramer` protocol** | Milestone-level SOLID work. Enables Modbus / length-prefixed framing without touching existing code, but requires designing a stable injection point in configuration. |
| **Extract `ConnectionPool`** | Companion to MessageFramer milestone. Internal only; no urgency now that the dispatch race is fixed. |
| **Extract `Metrics`** | Companion to MessageFramer milestone. `getMetrics()` already exposes the data; this is a cleanup. |
| **Inject `Logger`** | Nice for test-time log capture. Low priority until test coverage is broader. |
| **Inject `MessageQueue`** | Nice for pre-loaded queue tests. Blocked on deciding whether to expose `MessageQueue` in the public API. |
| **Deduplicate timing test helpers** | Low priority cosmetic; `TaskFunctions.swift` has 8 near-identical variants. Acceptable until the test suite grows. |
| **Linux platform support** | `Package.swift` change is one line, but auditing macOS-only APIs (`DispatchQueue`, `Date`, CoreFoundation types) requires a Linux build environment. Needs CI runner. |
| **`spmFoundationTools` branch constraint** | Blocked on a tagged release of `spmFoundationTools`. Pin to a version tag once one is cut from the `dev` branch. |
