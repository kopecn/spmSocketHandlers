# SocketHandlers — Improvement Checklist

Prioritized fixes derived from Swift 6, determinism, performance, and SOLID analysis.
Internal extractions only — public API surface stays as-is.

## Correctness (do first)
- [x] **Fix `setupChildChannel` race condition** — all state mutations inside `setupChildChannel`
      now dispatched to `serverDispatchQueue.async`; only `syncOperations.addHandler` (NIO pipeline
      setup) remains on the event loop thread.
- [ ] **Fix `handleMessage` unsynchronized mutation** — `messagesReceived += 1` in both server
      and client runs on the NIO event loop, not on the owning dispatch queue. Either dispatch to
      the queue or use `NIOLockedValueBox<Int>` / `ManagedAtomic<Int>`.

## Swift 6 Compliance
- [ ] **Eliminate `@unchecked Sendable` on `NIOSocketHandlerServer`** — replace DispatchQueue
      serialization with either a Swift actor or `NIOLockedValueBox` for mutable state so the
      compiler can verify sendability.
- [ ] **Eliminate `@unchecked Sendable` on `NIOSocketHandlerClient`** — same approach.
- [ ] **Eliminate `@unchecked Sendable` on `MessageQueue`** — internal `DispatchQueue` sync
      could be replaced with an actor or locked value box.
- [ ] **Make `NIOClientConnectionStateHandler` `final`** — it's a channel handler with no
      subclassing intent; `final` enables compiler optimizations and cleaner Sendable conformance.
- [ ] **Make `NIOServerConnectionStateHandler` `final`** — same reasoning as client state handler.

## Determinism
- [ ] **Replace `Date()` with monotonic time** in `MessageQueue` expiration logic. Use
      `ContinuousClock.Instant` or `NIODeadline` instead of wall-clock `Date()` which is
      subject to NTP adjustments.
- [x] **Add delivery-confirmed send overloads** — `send(confirming: String) async throws` and
      `send(confirming: Data) async throws` added to both server and client. Suspends until
      `writeAndFlush` completes; throws on disconnect or write failure. Fire-and-forget
      `send(_:)` still returns `true` immediately by design.

## High-Speed Packet Handling
- [x] **Bound `cumulationBuffer` in `NIOStringHandler`** — `maxCumulationBufferSize` (default 1 MB)
      added to `ServerConfiguration` and `ClientConfiguration`; `NIOStringHandler` closes the
      channel with an error log when the limit is exceeded.
- [ ] **Remove inline `cleanupExpiredMessages()` from hot path** — currently called on every
      `enqueue()`, `dequeue()`, `count`, and `peek()`. The cleanup timer already runs every 60s;
      remove the inline calls so queue operations stay O(1) amortized.
- [ ] **Eliminate per-send String allocation** — replace `message + "\n"` with two sequential
      writes (`writeString(message)` then `writeStaticString("\n")`) or pre-allocate the
      terminated string once.
- [ ] **Consider `ByteToMessageDecoder`** — NIO's built-in cumulation handler handles partial
      reads, buffer compaction, and edge cases that the manual `cumulationBuffer` approach
      currently does not.

## SOLID — Internal Extractions (public API unchanged)
- [ ] **Extract `MessageFramer` protocol** from `NIOStringHandler` — define a protocol for
      message framing/tokenization, make the newline handler one conformance. This enables
      future Modbus, length-prefixed, or binary framing without modifying existing code.
      Inject via configuration.
- [ ] **Extract `ConnectionPool`** (internal) — move `connectedClients`, `connectionQueue`,
      `connectionCountByClient` into a dedicated type used by `NIOSocketHandlerServer`. The
      `setupChildChannel` dispatch fix addressed the race, but centralizing this state will
      make future correctness easier to verify.
- [ ] **Extract `Metrics`** (internal) — move `messagesSent`, `messagesReceived`,
      `connectionAttempts`, `successfulConnections`, timing fields into a `ConnectionMetrics`
      struct/class used internally by both server and client.
- [ ] **Inject `Logger`** — accept an optional `Logger` in the initializer rather than always
      creating one from a label string. Enables test-time log capture and custom log routing.
- [ ] **Inject `MessageQueue`** — accept an optional queue in the initializer or configuration
      so tests can provide a mock or pre-loaded queue.

## Error Handling & Logging
- [ ] **Replace `print()` with structured `Logger` in `MessageQueue`** — persistence failures
      use bare `print()` instead of the structured logger. Switch to `logger.error(...)`.
- [ ] **Add byte context to UTF-8 decode failure log** — `NIOStringHandler` logs a warning
      without including the offending bytes. Include a hex dump to make failures debuggable.
- [ ] **Guard against empty delimiter in `NIOStringHandler`** — `delimiter.utf8.first!`
      force-unwraps and will crash if an empty string is passed. Add a precondition or guard
      in the initializer.

## Testing
- [ ] **Add error path tests** — no tests exercise connection failure, timeout expiry, or
      disconnect-before-connect scenarios.
- [ ] **Add `NIOStringHandler` max-buffer test** — `maxCumulationBufferSize` is now wired up;
      add a test that verifies the channel is closed when the limit is exceeded (not just that
      data is dropped).
- [ ] **Add message ordering test** — verify messages arrive in send order under concurrent
      client load.
- [ ] **Add concurrent connections stress test** — existing stress tests only use a single
      client; add a scenario with N simultaneous clients.
- [ ] **Fix `netcatEchoTest()`** — function contains an early `return` and is completely dead
      code. Either implement it or delete it (`NIOHandlerNetCatTests.swift`).
- [ ] **Replace polling `waitForClientConnection()`** — current implementation polls every 100ms
      with a 15-second hardcoded timeout (`TaskFunctions.swift`). Replace with
      continuation-based signaling using `withCheckedContinuation`.
- [ ] **Deduplicate timing test helpers** — `serverTask` / `deterministicServerTask` and their
      timing variants are near-identical (`TaskFunctions.swift`). Extract the shared send/receive
      loop with a latency-provider parameter.

## Package & Build
- [ ] **Add Linux platform support to `Package.swift`** — the library is required to run on
      Linux (ARM + x86) but `Package.swift` only declares `.macOS(.v14)`. Add Linux support,
      audit for macOS-only APIs, and validate a Linux build. `OpenCombine` already targets
      Linux; `DispatchQueue` is available via `swift-corelibs-libdispatch`.
- [ ] **Resolve `spmFoundationTools` branch constraint** — `package(url:branch:"dev")` is less
      stable than a version tag. Pin to a tagged version once one is available.

## Documentation
- [x] **Add code examples to `readme.md`** — Client Usage Example and Server Usage Example
      sections added, including fire-and-forget and confirmed-send variants.
- [ ] **Expand `diags/Network Diagnostics.md`** — currently only a tcpdump reference. Add
      `lsof -i :<port>`, `netstat -an`, and application-level diagnostic notes.
