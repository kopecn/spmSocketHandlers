# SocketHandlers - Project Specification

## Overview
A Swift Package Manager library providing a lightweight SwiftNIO wrapper for ASCII/text-based TCP socket communication. Exposes `NIOSocketHandlerServer` and `NIOSocketHandlerClient` as the primary public API surface, built on top of Apple's SwiftNIO for high-performance async networking.

**Package name:** `SocketHandlers`
**Swift tools version:** 6.1
**Minimum platform:** macOS 14
**License:** MIT

## Architecture

### Module Structure
```
SocketHandlers (Package)
├── NIOHandler (Library target — primary public API)
│   ├── Server/
│   │   ├── NIOHandlerServer.swift         — NIOSocketHandlerServer (final class, @unchecked Sendable)
│   │   └── NIOServerConnectionStateHandler.swift — Per-client channel state observer
│   ├── Client/
│   │   ├── NIOSocketHandlerClient.swift   — NIOSocketHandlerClient (class, @unchecked Sendable)
│   │   └── NIOClientConnectionStateHandler.swift — Client channel state observer
│   ├── MessageQueue/
│   │   └── MessageQueue.swift             — Priority queue with expiration + optional disk persistence
│   └── Support/
│       ├── NIOStringHandler.swift          — ByteBuffer → String tokenizer (ChannelInboundHandler)
│       ├── ServerConfiguration.swift       — Server config struct (Sendable)
│       ├── ClientConfiguration.swift       — Client config struct (Sendable)
│       ├── RetryPolicy.swift               — Reconnection retry policy (Sendable)
│       ├── RetryStrategy.swift             — Enum: exponentialBackoff | fixedDelay
│       ├── QoSClass.swift                  — DispatchQoS wrapper enum (Sendable)
│       └── Task+extensions.swift           — Task → EventLoopFuture bridge
├── SocketCommon (Internal target — shared types)
│   ├── SocketClientConnectionState.swift   — Client state enum (Sendable, Equatable)
│   ├── SocketServerListeningState.swift    — Server state enum (Sendable, Equatable)
│   ├── SocketHandlerError.swift            — Error enum
│   └── ClientID.swift                      — UUID | name identifier (Hashable, Identifiable)
└── SocketHandlersTests (Test target)
    ├── NIOHandlerTests.swift               — Stress tests (deterministic + variable timing)
    ├── NIOHandlerNetCatTests.swift          — Integration tests (netcat-based, env-gated)
    └── Support/                            — Test helpers, metrics, collectors
```

### External Dependencies
| Dependency | Product Used | Purpose |
|---|---|---|
| `spmFoundationTools` (private) | `FoundationInterfaces` | `MessageDuplex`, `MessageSendable`, `MessageReceivable` protocols |
| `swift-nio` | `NIOCore`, `NIOPosix` | Event loop, channels, bootstrap, ByteBuffer |
| `swift-log` | `Logging` | Structured logging |
| `OpenCombine` | `OpenCombine` | Reactive publishers (`CurrentValueSubject`) for state observation |
| `depermaid` | Plugin only | Mermaid dependency graph generation |

### Key Protocol Conformances
- **`MessageDuplex`** = `MessageSendable` + `MessageReceivable` — both Server and Client conform
- **`MessageReceivable`** requires: `setStringMessageHandler(_:)`, `setDataMessageHandler(_:)`, `handleMessage(_:) async`
- **`MessageSendable`** requires: `send(to:_:Data,_:Int,_:Bool) -> Bool`, `send(to:_:String,_:Int,_:Bool) -> Bool`

### Concurrency Model
- **Thread safety:** DispatchQueue serialization (`serverDispatchQueue` / `socketDispatchQueue`)
- **Sendability:** Both main classes use `@unchecked Sendable` with manual queue-based synchronization
- **NIO integration:** `EventLoopGroup` (owned or injected), `EventLoopFuture` for channel operations
- **Async bridge:** `Task.futureResult(on:)` extension bridges Swift concurrency → NIO futures
- **Message handling:** `NIOStringHandler` dispatches via `eventLoop.flatSubmit { Task { await handler.handleMessage(msg) } }`

### Data Flow
1. **Inbound:** TCP bytes → `ByteBuffer` → `NIOStringHandler` (tokenizes on `\n` or configurable delimiter) → `MessageReceivable.handleMessage(_:)`
2. **Outbound:** `send(_:)` → DispatchQueue async → `ByteBuffer` allocation → `channel.writeAndFlush()`
3. **Offline:** Messages queued in `MessageQueue` (priority-ordered, expiration-based) → flushed on reconnect

## Build & Development

### Commands
```bash
make build          # swift build -c release
make test           # swift test --no-parallel
make format         # swift-format with .swift-format.json config
make mermaid        # Generate dependency graph
make clean          # Remove .build/
make bump-patch     # Tag and push version bump
```

### Formatting
- **Tool:** swift-format with `.swift-format.json`
- **Indentation:** 4 spaces
- **Line length:** 120 characters
- **Key rules:** OrderedImports, UseTripleSlashForDocumentation, NoBlockComments, lineBreakBeforeEachArgument

### Testing
- Tests use Swift Testing (`@Test`) framework, not XCTest assertions
- `--no-parallel` required (tests bind to fixed ports)
- Netcat tests are env-gated: `RUN_NETCAT_CLIENT_TESTS=1` / `RUN_NETCAT_SERVER_TESTS=1`
- Stress tests validate 10k-15k message throughput with deterministic and variable timing

### Conventions
- Emoji prefixed log messages for visual scanning in console output
- `weak self` pattern used consistently in async closures to prevent retain cycles
- Configuration objects are value types (`struct`, `Sendable`) with static `.default` factories
- State enums provide `CustomStringConvertible` and custom `Equatable` (errors compare as equal regardless of payload)

## Design Philosophy

### Facade Pattern — Intentional Simplicity
The end-user API is deliberately a **single-object facade**: one `NIOSocketHandlerServer` to run a server,
one `NIOSocketHandlerClient` to connect to one. The consumer should never need to touch NIO channels,
event loops, byte buffers, or handler pipelines directly. This is the primary design goal.

This means the facade classes intentionally consolidate responsibilities (connection lifecycle,
message dispatch, queuing, metrics, state publishing) behind a single entry point. Internally,
these responsibilities can and should be decomposed into focused types — but the **public API
surface stays minimal**. Refactoring for SOLID applies to the internal architecture, not the
consumer-facing shape.

**Guiding rule:** If a refactor adds a type the end-user must instantiate or configure, it needs
strong justification. Internal extractions (used only inside the facade) are always welcome.

## Planned Features (from readme)
- Timeout and reconnect handling improvements
- Modbus/data stream tokenizer plugin support
- Community examples

## Improvement Checklist

Prioritized fixes derived from Swift 6, determinism, performance, and SOLID analysis.
Internal extractions only — public API surface stays as-is.

### Correctness (do first)
- [ ] **Fix `setupChildChannel` race condition** — `connectedClients`, `connectionQueue`,
      `connectionCountByClient` are mutated on the NIO event loop thread inside `setupChildChannel`
      but read/written on `serverDispatchQueue` everywhere else. Dispatch state mutation to
      `serverDispatchQueue` or move all state access to the event loop.
- [ ] **Fix `handleMessage` unsynchronized mutation** — `messagesReceived += 1` in both server
      (`NIOHandlerServer.swift:809`) and client (`NIOSocketHandlerClient.swift:706`) runs on the
      NIO event loop, not on the owning dispatch queue. Either dispatch to the queue or use
      `NIOLockedValueBox<Int>` / `ManagedAtomic<Int>`.

### Swift 6 Compliance
- [ ] **Eliminate `@unchecked Sendable` on `NIOSocketHandlerServer`** — replace DispatchQueue
      serialization with either a Swift actor or `NIOLockedValueBox` for mutable state so the
      compiler can verify sendability.
- [ ] **Eliminate `@unchecked Sendable` on `NIOSocketHandlerClient`** — same approach.
- [ ] **Eliminate `@unchecked Sendable` on `MessageQueue`** — internal `DispatchQueue` sync
      could be replaced with an actor or locked value box.
- [ ] **Make `NIOClientConnectionStateHandler` `final`** — it's a channel handler with no
      subclassing intent; `final` enables compiler optimizations and cleaner Sendable conformance.

### Determinism
- [ ] **Replace `Date()` with monotonic time** in `MessageQueue` expiration logic. Use
      `ContinuousClock.Instant` or `NIODeadline` instead of wall-clock `Date()` which is
      subject to NTP adjustments.
- [ ] **Make `send()` return delivery confirmation** — current `send()` always returns `true`
      before the write even happens. Consider an `async throws` overload or
      `EventLoopFuture<Void>` variant for callers that need confirmation.

### High-Speed Packet Handling
- [ ] **Bound `cumulationBuffer` in `NIOStringHandler`** — add a configurable max buffer size.
      If a peer sends data without delimiters, the buffer currently grows unbounded (memory +
      potential DoS). Drop or close the channel when exceeded.
- [ ] **Remove inline `cleanupExpiredMessages()` from hot path** — currently called on every
      `enqueue()`, `dequeue()`, `count`, and `peek()`. The cleanup timer already runs every 60s;
      remove the inline calls so queue operations stay O(1) amortized.
- [ ] **Eliminate per-send String allocation** — replace `message + "\n"` with two sequential
      writes (`writeString(message)` then `writeStaticString("\n")`) or pre-allocate the
      terminated string once.
- [ ] **Consider `ByteToMessageDecoder`** — NIO's built-in cumulation handler handles partial
      reads, buffer compaction, and edge cases that the manual `cumulationBuffer` approach
      currently does not.

### SOLID — Internal Extractions (public API unchanged)
- [ ] **Extract `MessageFramer` protocol** from `NIOStringHandler` — define a protocol for
      message framing/tokenization, make the newline handler one conformance. This enables
      future Modbus, length-prefixed, or binary framing without modifying existing code.
      Inject via configuration.
- [ ] **Extract `ConnectionPool`** (internal) — move `connectedClients`, `connectionQueue`,
      `connectionCountByClient` into a dedicated type used by `NIOSocketHandlerServer`.
- [ ] **Extract `Metrics`** (internal) — move `messagesSent`, `messagesReceived`,
      `connectionAttempts`, `successfulConnections`, timing fields into a `ConnectionMetrics`
      struct/class used internally by both server and client.
- [ ] **Inject `Logger`** — accept an optional `Logger` in the initializer rather than always
      creating one from a label string. Enables test-time log capture and custom log routing.
- [ ] **Inject `MessageQueue`** — accept an optional queue in the initializer or configuration
      so tests can provide a mock or pre-loaded queue.
