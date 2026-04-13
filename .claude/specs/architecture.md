# SocketHandlers — Architecture

## Module Structure
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
│       ├── NIOStringHandler.swift          — ByteBuffer → String tokenizer (ChannelInboundHandler); closes channel when maxCumulationBufferSize exceeded
│       ├── ServerConfiguration.swift       — Server config struct (Sendable); includes tokenizer, maxCumulationBufferSize (1 MB default)
│       ├── ClientConfiguration.swift       — Client config struct (Sendable); includes tokenizer, maxCumulationBufferSize (1 MB default)
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
    ├── NIOHandlerTests.swift               — Stress tests (deterministic + variable timing) + basicMessageExchange
    ├── NIOHandlerNetCatTests.swift          — Integration tests (netcat-based, env-gated); NOTE: netcatEchoTest() is dead code (early return)
    └── Support/
        ├── TestConfiguration.swift         — Hardcoded ports (1234, 2345-2347) and timing constants
        ├── TestMetrics.swift               — Codable metrics struct (name, duration, throughput, counts)
        ├── Handler.swift                   — MessageReceivable test double (@unchecked Sendable)
        ├── MessageCollector.swift          — Actor-based thread-safe message accumulator
        ├── TaskFunctions.swift             — Async send/receive helpers (deterministic + variable latency)
        └── MetricsUtilities.swift          — saveMetrics(), timeIt(), timeItWithDuration() utilities
```

## External Dependencies
| Dependency | Product Used | Purpose |
|---|---|---|
| `spmFoundationTools` (private) | `FoundationInterfaces` | `MessageDuplex`, `MessageSendable`, `MessageReceivable` protocols |
| `swift-nio` | `NIOCore`, `NIOPosix` | Event loop, channels, bootstrap, ByteBuffer |
| `swift-log` | `Logging` | Structured logging |
| `OpenCombine` | `OpenCombine` | Reactive publishers (`CurrentValueSubject`) for state observation |
| `depermaid` | Plugin only | Mermaid dependency graph generation |

## Key Protocol Conformances
- **`MessageDuplex`** = `MessageSendable` + `MessageReceivable` — both Server and Client conform
- **`MessageReceivable`** requires: `setStringMessageHandler(_:)`, `setDataMessageHandler(_:)`, `handleMessage(_:) async`
- **`MessageSendable`** requires: `send(to:_:Data,_:Int,_:Bool) -> Bool`, `send(to:_:String,_:Int,_:Bool) -> Bool`
- **Beyond protocol:** both classes additionally expose `send(confirming: String) async throws` and `send(confirming: Data) async throws` — suspends until the write is flushed to the kernel; throws on disconnect or write failure; does not queue

## Concurrency Model
- **Thread safety:** DispatchQueue serialization (`serverDispatchQueue` / `socketDispatchQueue`)
- **Sendability:** Both main classes use `@unchecked Sendable` with manual queue-based synchronization
- **NIO integration:** `EventLoopGroup` (owned or injected), `EventLoopFuture` for channel operations
- **Async bridge:** `Task.futureResult(on:)` extension bridges Swift concurrency → NIO futures
- **Message handling:** `NIOStringHandler` dispatches via `eventLoop.flatSubmit { Task { await handler.handleMessage(msg) } }`

## Data Flow
1. **Inbound:** TCP bytes → `ByteBuffer` → `NIOStringHandler` (tokenizes on `\n` or configurable delimiter; closes channel if `maxCumulationBufferSize` exceeded) → `MessageReceivable.handleMessage(_:)`
2. **Outbound (fire-and-forget):** `send(_:)` → DispatchQueue async → `ByteBuffer` allocation → `channel.writeAndFlush(promise: nil)` — returns `true` immediately; delivery not confirmed
3. **Outbound (confirmed):** `send(confirming:) async throws` → suspends caller → DispatchQueue async → `channel.writeAndFlush()` → `whenComplete` resumes continuation
4. **Offline:** String messages queued in `MessageQueue` (priority-ordered, expiration-based) → flushed on reconnect. Data sends do not support offline queuing.
