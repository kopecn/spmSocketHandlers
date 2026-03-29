# SocketHandlers — Code Review Todo

Derived from full implementation + architectural review (2026-03-28).
Tackle one item at a time. The public API surface (`NIOSocketHandlerServer`, `NIOSocketHandlerClient`) must not change unless noted.

---

## Correctness (do first — these are data races or incorrect behavior)

- [ ] **setupChildChannel race condition** — `connectedClients`, `connectionQueue`, `connectionCountByClient`, and `lastID` are mutated on the NIO event loop thread inside `setupChildChannel` (`NIOHandlerServer.swift:462-467`) but read/written on `serverDispatchQueue` everywhere else. Dispatch all state mutations inside `setupChildChannel` onto `serverDispatchQueue`.

- [ ] **messagesReceived unsynchronized increment (server)** — `messagesReceived += 1` at `NIOHandlerServer.swift:809` runs on the NIO event loop thread, not on `serverDispatchQueue`. Dispatch to `serverDispatchQueue` or replace with `NIOLockedValueBox<Int>` / `ManagedAtomic<Int>`.

- [ ] **messagesReceived unsynchronized increment (client)** — `messagesReceived += 1` at `NIOSocketHandlerClient.swift:706` runs on the NIO event loop, not `socketDispatchQueue`. Same fix as server.

- [ ] **Unbounded `cumulationBuffer` in `NIOStringHandler`** — a peer that never sends the delimiter causes unbounded memory growth and potential DoS (`NIOStringHandler.swift:38-57`). Add a configurable max buffer size to `ServerConfiguration`/`ClientConfiguration`; close the channel when exceeded.

- [ ] **`send()` misleading return value** — both server and client `send()` return `true` synchronously before the async write completes (`NIOHandlerServer.swift:316`, `NIOSocketHandlerClient.swift:472`). Remove the boolean return value from the fire-and-forget overload, or add an `async throws` / `EventLoopFuture<Void>` overload for callers that need delivery confirmation.

---

## Swift 6 Compliance

- [ ] **Eliminate `@unchecked Sendable` on `NIOSocketHandlerServer`** — replace DispatchQueue-based manual serialization with a Swift actor or `NIOLockedValueBox` so the compiler can verify thread safety.

- [ ] **Eliminate `@unchecked Sendable` on `NIOSocketHandlerClient`** — same approach as server.

- [ ] **Eliminate `@unchecked Sendable` on `MessageQueue`** — replace internal `DispatchQueue` sync with an actor or `NIOLockedValueBox`.

- [ ] **Add `final` to `NIOClientConnectionStateHandler`** — no subclassing intent; `final` enables compiler optimizations and cleaner `Sendable` conformance (`NIOClientConnectionStateHandler.swift:9`).

- [ ] **Add `final` to `NIOServerConnectionStateHandler`** — same reasoning (`NIOServerConnectionStateHandler.swift:10`).

---

## Determinism

- [ ] **Replace `Date()` with monotonic time in `MessageQueue`** — `Date()` is wall-clock time and is subject to NTP adjustments, causing messages to expire prematurely or never (`MessageQueue.swift:45,59,215`). Use `ContinuousClock.Instant` or `NIODeadline` instead.

- [ ] **Remove inline `cleanupExpiredMessages()` from hot path** — called on every `enqueue()`, `dequeue()`, `peek()`, and `count` making each O(n) (`MessageQueue.swift:96,123,150,158`). The background cleanup timer already runs every 60s — remove the inline calls so queue operations stay O(1) amortized.

---

## Performance

- [ ] **Eliminate per-send String allocation** — `message + "\n"` creates a new heap String on every send (`NIOHandlerServer.swift:316`, `NIOSocketHandlerClient.swift:457`). Replace with two sequential writes: `writeString(message)` then `writeStaticString("\n")`.

- [ ] **Consider migrating to `ByteToMessageDecoder`** — NIO's built-in cumulation handler handles partial reads, buffer compaction, and edge cases that the manual `cumulationBuffer` approach in `NIOStringHandler` currently does not. Evaluate as a replacement once `MessageFramer` protocol is extracted.

---

## SOLID — Internal Extractions (public API unchanged)

- [ ] **Extract `MessageFramer` protocol from `NIOStringHandler`** — define a framing/tokenization protocol; make the newline tokenizer one conformance. Enables future Modbus, length-prefixed, or binary framing without modifying existing code. Inject via `ServerConfiguration`/`ClientConfiguration`. This is also the prerequisite for the `ByteToMessageDecoder` migration.

- [ ] **Extract `ConnectionPool` (internal)** — move `connectedClients`, `connectionQueue`, and `connectionCountByClient` out of `NIOSocketHandlerServer` into a dedicated internal type. Resolves the `setupChildChannel` race condition item above.

- [ ] **Extract `Metrics` (internal)** — move `messagesSent`, `messagesReceived`, `connectionAttempts`, `successfulConnections`, and timing fields into a shared `ConnectionMetrics` struct/class used by both server and client.

- [ ] **Inject `Logger`** — accept an optional `Logger` in `NIOSocketHandlerServer` and `NIOSocketHandlerClient` initializers instead of always constructing one from a label string. Enables test-time log capture and custom routing.

- [ ] **Inject `MessageQueue`** — accept an optional `MessageQueue` in the client initializer or `ClientConfiguration` so tests can provide a mock or pre-loaded queue.

---

## Error Handling & Logging

- [ ] **Replace `print()` with structured `Logger` in `MessageQueue`** — persistence failures at `MessageQueue.swift:245` use bare `print()` instead of the structured logger. Switch to `logger.error(...)`.

- [ ] **Add byte context to UTF-8 decode failure log** — `NIOStringHandler.swift:79` logs a warning without including the offending bytes. Include a hex dump to make failures debuggable.

- [ ] **Guard against empty delimiter in `NIOStringHandler`** — `delimiter.utf8.first!` force-unwraps and will crash if an empty string is passed. Add a precondition or guard in the initializer.

---

## Testing

- [ ] **Add error path tests** — no tests exercise connection failure, timeout expiry, or disconnect-before-connect scenarios.

- [ ] **Add `NIOStringHandler` max-buffer test** — once the buffer bound is added, verify the channel is closed when the limit is exceeded (not just that data is dropped).

- [ ] **Add message ordering test** — verify messages arrive in send order under concurrent client load.

- [ ] **Add concurrent connections stress test** — existing stress tests only use a single client; add a scenario with N simultaneous clients.

- [ ] **Fix `netcatEchoTest()`** — function contains an early `return` and is completely dead code. Either implement it or delete it (`NIOHandlerNetCatTests.swift`).

- [ ] **Replace polling `waitForClientConnection()`** — current implementation polls every 100ms with a 15-second hardcoded timeout (`TaskFunctions.swift`). Replace with continuation-based signaling using `withCheckedContinuation`.

- [ ] **Deduplicate timing test helpers** — `serverTask` / `deterministicServerTask` and their timing variants are near-identical (`TaskFunctions.swift`). Extract the shared send/receive loop with a latency-provider parameter.

---

## Package & Build

- [ ] **Add Linux platform support to `Package.swift`** — the library is required to run on Linux (ARM + x86) but `Package.swift` only declares `.macOS(.v14)`. Add Linux support, audit for macOS-only APIs, and validate a Linux build. `OpenCombine` already targets Linux; `DispatchQueue` is available via `swift-corelibs-libdispatch`.

- [ ] **Resolve `spmFoundationTools` branch constraint** — `package(url:branch:"dev")` is less stable than a version tag. Pin to a tagged version once one is available.

---

## Documentation

- [ ] **Add code examples to `readme.md`** — the readme has architecture diagrams but no usage snippet. Add a minimal server setup and client connect/send example.

- [ ] **Expand `diags/Network Diagnostics.md`** — currently only a tcpdump reference. Add `lsof -i :<port>`, `netstat -an`, and application-level diagnostic notes.
